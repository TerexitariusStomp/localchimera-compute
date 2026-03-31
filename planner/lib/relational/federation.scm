;;; federation.scm — Streamed interleaving federation
;;;
;;; Each scope produces a lazy stream of plans (via run-plan*).
;;; The federation merges these streams with mplus — fair interleaving.
;;; Proportional sacrifice emerges from the interleaving: as one scope's
;;; stream advances past its greedy plan, it yields resources to others.
;;;
;;; The residual (total unmet demand) shrinks with each interleaving step.
;;; Well-decoupled federations (DDMRP buffers at boundaries) converge fast
;;; because buffer-safe plans are at the front of each stream.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Hierarchy
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-parent-o facts child parent)
  (in-list-o `(scope-parent ,child ,parent) facts))

(define (peer-scopes-o facts scope-a scope-b)
  (fresh (parent)
    (scope-parent-o facts scope-a parent)
    (scope-parent-o facts scope-b parent)
    (=/= scope-a scope-b)))

(define (build-hierarchy-o facts scope-ids parent-map children-of plan-order)
  (project (facts scope-ids parent-map)
    (let ((result (build-hierarchy-impl scope-ids parent-map)))
      (fresh ()
        (== children-of (car result))
        (== plan-order (cdr result))))))

(define (build-hierarchy-impl scope-ids parent-map)
  (let ((ch (make-hash-table)) (visited (make-hash-table)) (order '()))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (let dfs ((ids scope-ids))
      (for-each (lambda (id)
                  (unless (hash-ref visited id #f)
                    (hash-set! visited id #t)
                    (dfs (hash-ref ch id '()))
                    (set! order (cons id order))))
                ids))
    (cons (hash-map->list cons ch) (reverse order))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Scope plan streams
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-plan-stream scope-id ctx)
  "Lazy stream of plans for a scope. Cheapest first (SNE-sorted facts).
   Each plan includes its residuals (purchase terms = deficits)."
  (let ((ns #f))  ;; no netter — CLP(FD) allocation
    ((fresh (plan)
       (plan-o ctx plan #:max-depth 5))
     (empty-cstate ns))))

(define (stream-take-1 $)
  "Force one answer from a stream. Returns (answer . rest-stream) or #f."
  (cond
    ((null? $) #f)
    ((procedure? $) (stream-take-1 ($)))  ;; force suspension
    (else (cons (car $) (cdr $)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Residual computation
;;; ══════════════════════════════════════════════════════════════════════════════

(define (plan-residual plan)
  "Total unmet demand in a plan. Sum of all purchase quantities."
  (if (not (list? plan)) 0
      (fold (lambda (entry acc)
              (if (and (pair? entry) (pair? (cadr entry))
                       (eq? (caadr entry) 'purchase))
                  (+ acc (caddr (cadr entry)))
                  acc))
            0 plan)))

(define (plan-deficits plan scope-id)
  "Extract deficit signals from a plan."
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'purchase)
             `((scope . ,scope-id)
               (spec . ,(cadadr entry))
               (qty . ,(caddr (cadr entry))))))
        plan)))

(define (plan-surpluses plan scope-id)
  "Extract surplus from satisfied demands (allocated > needed)."
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'satisfied)
             (let* ((pt (cadr entry))
                    (alloc (cadddr pt))
                    (needed (caddr pt))
                    (total (if (list? alloc)
                               (fold (lambda (a acc) (+ acc (cadr a))) 0 alloc)
                               0))
                    (surplus (- total needed)))
               (and (> surplus 0)
                    `((scope . ,scope-id) (spec . ,(cadr pt)) (qty . ,surplus))))))
        plan)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching (same as before — peer enforcement)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (match-deficits-surpluses facts deficits surpluses)
  "Greedy match with peer enforcement. Returns (matches . unmatched-deficits)."
  (let* ((parent-facts (filter (lambda (f) (eq? (car f) 'scope-parent)) facts))
         (parent-of (lambda (id)
           (let ((p (find (lambda (f) (equal? (cadr f) id)) parent-facts)))
             (and p (caddr p))))))
    (let loop ((defs deficits) (sups surpluses) (matches '()) (unmatched '()))
      (if (null? defs)
          (cons (reverse matches) (reverse unmatched))
          (let* ((d (car defs))
                 (ds (assq-ref d 'scope)) (dsp (assq-ref d 'spec)) (dq (assq-ref d 'qty))
                 (m (find (lambda (s)
                            (and (equal? (assq-ref s 'spec) dsp)
                                 (not (equal? (assq-ref s 'scope) ds))
                                 (> (assq-ref s 'qty) 0)
                                 (let ((dp (parent-of ds))
                                       (sp (parent-of (assq-ref s 'scope))))
                                   (and dp sp (equal? dp sp)))))
                          sups)))
            (if (not m)
                (loop (cdr defs) sups matches (cons d unmatched))
                (let* ((sq (assq-ref m 'qty)) (q (min dq sq))
                       (match `((from . ,(assq-ref m 'scope)) (to . ,ds)
                                (spec . ,dsp) (qty . ,q)))
                       (new-sups (map (lambda (s)
                         (if (eq? s m)
                             (cons (cons 'qty (- sq q))
                                   (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                             s))
                         sups)))
                  (loop (cdr defs) new-sups (cons match matches) unmatched))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Streamed federation — the core
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; Each scope produces a lazy plan stream. The federation interleaves them.
;;; At each step:
;;;   1. Pull current best plan from each scope's stream
;;;   2. Collect deficits and surpluses across all scopes
;;;   3. Match laterally
;;;   4. If residual = 0: done (all demands satisfied across federation)
;;;   5. If residual > 0: advance the scope with the largest deficit
;;;      by one stream step (try its next plan, which yields more resources)
;;;   6. Repeat
;;;
;;; The interleaving IS the proportional sacrifice: each scope's stream
;;; advances past its greedy plan, yielding resources to peers. The mplus
;;; swapping ensures fair exploration. Well-buffered scopes have short
;;; streams (buffer-safe plan is at the front). Under-buffered scopes have
;;; longer streams. The total residual shrinks at each step.

(define *max-federation-steps* 100)

(define (federate-streams facts scope-entries)
  "Streamed federation. SCOPE-ENTRIES: list of (scope-id . ctx).
   Returns the best federation result found within step budget."
  (let* (;; Initialize: get first plan from each scope's stream
         (initial-streams
           (map (lambda (entry)
                  (let ((sid (car entry)) (ctx (cdr entry)))
                    (cons sid (scope-plan-stream sid ctx))))
                scope-entries))
         ;; Pull first plan from each stream
         (initial-state (pull-all-plans initial-streams)))
    (if (not initial-state) '()  ;; no scopes produced plans
        (let ((best (search-federation facts initial-state *max-federation-steps*)))
          best))))

(define (pull-all-plans scope-streams)
  "Pull one plan from each scope's stream. Returns ((sid plan stream) ...) or #f."
  (let loop ((streams scope-streams) (acc '()))
    (if (null? streams)
        (reverse acc)
        (let* ((sid (caar streams)) (stream (cdar streams))
               (result (stream-take-1 stream)))
          (if (not result)
              ;; This scope has no plans — include with empty plan
              (loop (cdr streams)
                    (cons (list sid '() '()) acc))
              ;; Reify the plan from the state
              (let* ((state (car result))
                     (rest-stream (cdr result))
                     (plan (reify-plan state)))
                (loop (cdr streams)
                      (cons (list sid plan rest-stream) acc))))))))

(define (reify-plan state)
  "Extract plan value from a miniKanren state (var 0)."
  (let* ((S (cstate-S state))
         (v (walk* (var 0) S))
         (R (reify-s v '())))
    (walk* v R)))

(define (reify-s v subst)
  (let ((v (walk v subst)))
    (cond
     ((var? v)
      (cons (cons v (string->symbol (string-append "_." (number->string (length subst)))))
            subst))
     ((pair? v) (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))

(define (search-federation facts state steps-remaining)
  "Search for the federation plan with lowest total residual.
   STATE: list of (scope-id plan stream) triples.
   Advances the scope with the largest deficit at each step."
  (let* ((plans (map (lambda (s) (cons (car s) (cadr s))) state))
         ;; Collect all deficits and surpluses
         (all-deficits (append-map (lambda (s)
           (plan-deficits (cadr s) (car s))) state))
         (all-surpluses (append-map (lambda (s)
           (plan-surpluses (cadr s) (car s))) state))
         ;; Match laterally
         (match-result (match-deficits-surpluses facts all-deficits all-surpluses))
         (matches (car match-result))
         (unmatched (cdr match-result))
         ;; Total residual
         (residual (fold (lambda (d acc) (+ acc (assq-ref d 'qty))) 0 unmatched)))
    ;; Build result
    (let ((result `((scope-plans . ,plans)
                    (lateral-matches . ,matches)
                    (unmatched-deficits . ,unmatched)
                    (total-residual . ,residual))))
      (cond
        ;; Perfect: no residual
        ((= residual 0) result)
        ;; Budget exhausted: return best found
        ((<= steps-remaining 0) result)
        ;; Try advancing the scope with the largest deficit
        (else
         (let* ((worst-scope (and (pair? unmatched)
                                   (assq-ref (car (sort unmatched
                                     (lambda (a b) (> (assq-ref a 'qty)
                                                      (assq-ref b 'qty)))))
                                   'scope)))
                ;; Advance that scope's stream by one step
                (advanced (and worst-scope
                               (advance-scope state worst-scope))))
           (if (not advanced)
               result  ;; can't advance — stream exhausted
               (let ((next-result (search-federation facts advanced
                                    (- steps-remaining 1))))
                 ;; Keep the better result
                 (if (< (assq-ref next-result 'total-residual) residual)
                     next-result
                     result)))))))))

(define (advance-scope state scope-id)
  "Advance one scope's stream by one step. Returns updated state or #f."
  (let loop ((entries state) (acc '()))
    (if (null? entries) #f
        (let ((entry (car entries)))
          (if (not (equal? (car entry) scope-id))
              (loop (cdr entries) (cons entry acc))
              ;; This is the scope to advance
              (let* ((stream (caddr entry))
                     (next (stream-take-1 stream)))
                (if (not next)
                    #f  ;; stream exhausted
                    (let ((new-plan (reify-plan (car next)))
                          (new-stream (cdr next)))
                      (append (reverse acc)
                              (list (list scope-id new-plan new-stream))
                              (cdr entries))))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Entry point
;;; ══════════════════════════════════════════════════════════════════════════════

(define (plan-federation-o facts scope-ids parent-map scope-ctxs result)
  "Streamed federation: each scope produces a lazy plan stream,
   the federation interleaves them for proportional sacrifice.
   SCOPE-CTXS: alist of (scope-id . ctx)."
  (project (facts scope-ids parent-map scope-ctxs)
    (let* (;; Build hierarchy for ordering
           (hierarchy (build-hierarchy-impl scope-ids parent-map))
           (plan-order (cdr hierarchy))
           ;; Order scope-ctxs by plan-order (children first)
           (ordered-ctxs (filter-map (lambda (id)
                                       (assoc id scope-ctxs))
                                     plan-order))
           ;; Run streamed federation
           (fed-result (federate-streams facts ordered-ctxs)))
      (== result (cons `(plan-order . ,plan-order) fed-result)))))
