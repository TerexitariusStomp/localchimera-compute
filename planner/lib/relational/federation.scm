;;; federation.scm — Recursive streamed federation
;;;
;;; The protocol is the same at every level:
;;;
;;;   scope-stream : scope → lazy stream of federation-result
;;;
;;;   federation-result = ((scope . id)
;;;                        (plan . ...)
;;;                        (deficits . ...)
;;;                        (surpluses . ...)
;;;                        (residual . number))
;;;
;;; Leaf: miniKanren search over local facts.
;;; Parent: interleave children's streams + lateral matching.
;;; Consumers don't know or care which kind they're pulling from.

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

(define (build-hierarchy facts scope-ids parent-map)
  "scope-id → list of child-ids."
  (let ((ch (make-hash-table)))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (hash-map->list cons ch)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; scope-stream — the universal protocol
;;; ══════════════════════════════════════════════════════════════════════════════

(define (scope-stream facts scope-id ctx-map children-of)
  (scope-stream* facts scope-id ctx-map children-of '()))

(define (scope-stream* facts scope-id ctx-map children-of visited)
  "Produce a lazy stream of federation-results for SCOPE-ID.
   VISITED guards against cycles in the scope-parent graph."
  (if (member scope-id visited)
      '()  ;; cycle detected — stop
      (let ((children (or (assoc-ref children-of scope-id) '()))
            (visited* (cons scope-id visited)))
        (if (null? children)
            (leaf-stream scope-id ctx-map)
            (parent-stream facts scope-id children ctx-map children-of visited*)))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Leaf stream
;;; ══════════════════════════════════════════════════════════════════════════════

(define (leaf-stream scope-id ctx-map)
  "Lazy stream of federation-results from a miniKanren search."
  (let* ((ctx (assoc-ref ctx-map scope-id))
         (raw (if ctx
                  ((fresh (plan) (plan-o ctx plan #:max-depth 5))
                   (empty-cstate #f))
                  '())))
    (stream-map-lazy
      (lambda (state)
        (let* ((plan (reify-from-state state))
               (defs (extract-deficits plan scope-id))
               (surps (extract-surpluses plan scope-id))
               (resid (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 defs)))
          `((scope . ,scope-id) (plan . ,plan)
            (deficits . ,defs) (surpluses . ,surps)
            (residual . ,resid))))
      raw)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Parent stream
;;; ══════════════════════════════════════════════════════════════════════════════

(define *max-steps* 50)

(define (parent-stream facts scope-id children ctx-map children-of visited)
  "Lazy stream: interleave children's streams + lateral matching."
  (let* ((child-streams
           (map (lambda (cid)
                  (cons cid (scope-stream* facts cid ctx-map children-of visited)))
                children))
         (initial (pull-from-all child-streams)))
    (if (null? initial)
        '()
        (search-stream facts scope-id initial *max-steps*))))

(define (search-stream facts scope-id state steps)
  "Lazy stream of improving federation-results."
  (let ((result (evaluate-state facts scope-id state)))
    (if (or (<= steps 0) (= (assq-ref result 'residual) 0))
        (list result)
        (cons result
              (lambda ()
                (let ((advanced (advance-worst state result)))
                  (if (not advanced) '()
                      (search-stream facts scope-id advanced (- steps 1)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Evaluate: match children's results at this level
;;; ══════════════════════════════════════════════════════════════════════════════

(define (evaluate-state facts scope-id state)
  "state = list of (child-id federation-result rest-stream).
   Returns a federation-result for this scope."
  (let* (;; Each child's deficits, re-attributed to the CHILD (not the leaf)
         ;; so that advance-worst can find the right child to advance
         (child-defs
           (append-map (lambda (s)
             (let* ((cid (car s))
                    (child-result (cadr s))
                    (raw-defs (or (and (pair? child-result)
                                       (assq-ref child-result 'deficits))
                                  '())))
               ;; Re-attribute deficits to this child's ID
               (map (lambda (d) (cons (cons 'child cid) d)) raw-defs)))
             state))
         (child-surps
           (append-map (lambda (s)
             (let* ((child-result (cadr s))
                    (raw-surps (or (and (pair? child-result)
                                        (assq-ref child-result 'surpluses))
                                   '())))
               raw-surps))
             state))
         ;; Match laterally
         (match-result (match-at-level child-defs child-surps))
         (matches (car match-result))
         (unmatched (cdr match-result))
         (residual (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 unmatched))
         ;; Combined plan
         (child-plans (map (lambda (s)
           (let ((cr (cadr s)))
             (cons (car s) (if (pair? cr) (assq-ref cr 'plan) '()))))
           state)))
    `((scope . ,scope-id)
      (plan . ,child-plans)
      (deficits . ,unmatched)
      (surpluses . ,(subtract-matched child-surps matches))
      (lateral-matches . ,matches)
      (residual . ,residual))))

(define (subtract-matched surpluses matches)
  "Reduce surpluses by matched quantities. Fully consumed surpluses are removed."
  (fold (lambda (m sups)
    (filter-map (lambda (s)
      (if (and (equal? (assq-ref s 'scope) (assq-ref m 'from))
               (equal? (assq-ref s 'spec) (assq-ref m 'spec)))
          (let ((new-qty (- (assq-ref s 'qty) (assq-ref m 'qty))))
            (if (<= new-qty 0) #f  ;; fully consumed — remove
                (cons (cons 'qty new-qty)
                      (filter (lambda (p) (not (eq? (car p) 'qty))) s))))
          s))
      sups))
    surpluses matches))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching
;;; ══════════════════════════════════════════════════════════════════════════════

(define (match-at-level deficits surpluses)
  "Match deficits with surpluses (same spec, different scope).
   Returns (matches . unmatched-deficits)."
  (let loop ((defs deficits) (sups surpluses) (matches '()) (unmatched '()))
    (if (null? defs)
        (cons (reverse matches) (reverse unmatched))
        (let* ((d (car defs))
               (dsp (assq-ref d 'spec)) (dq (assq-ref d 'qty))
               (d-scope (or (assq-ref d 'child) (assq-ref d 'scope)))
               (m (find (lambda (s)
                          (and (equal? (assq-ref s 'spec) dsp)
                               (not (equal? (assq-ref s 'scope) d-scope))
                               (> (assq-ref s 'qty) 0)))
                        sups)))
          (if (not m)
              (loop (cdr defs) sups matches (cons d unmatched))
              (let* ((sq (assq-ref m 'qty)) (q (min dq sq))
                     (match `((from . ,(assq-ref m 'scope)) (to . ,d-scope)
                              (spec . ,dsp) (qty . ,q)))
                     (new-sups (map (lambda (s)
                       (if (eq? s m)
                           (cons (cons 'qty (- sq q))
                                 (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                           s))
                       sups)))
                (if (>= q dq)
                    ;; Fully matched — drop deficit
                    (loop (cdr defs) new-sups (cons match matches) unmatched)
                    ;; Partially matched — reduce deficit, keep looking
                    (let ((remaining-d (cons (cons 'qty (- dq q))
                                             (filter (lambda (p) (not (eq? (car p) 'qty))) d))))
                      (loop (cons remaining-d (cdr defs)) new-sups
                            (cons match matches) unmatched)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Advance: move the worst child's stream forward one step
;;; ══════════════════════════════════════════════════════════════════════════════

(define (advance-worst state result)
  "Advance the child whose deficit is largest."
  (let ((unmatched (or (assq-ref result 'deficits) '())))
    (if (null? unmatched) #f
        ;; Find the child-id to advance (from the 'child tag on deficits)
        (let* ((sorted (sort unmatched
                  (lambda (a b) (> (assq-ref a 'qty) (assq-ref b 'qty)))))
               (worst-child (or (assq-ref (car sorted) 'child)
                                (assq-ref (car sorted) 'scope))))
          (advance-child state worst-child)))))

(define (advance-child state child-id)
  "Pull next result from CHILD-ID's stream. Returns updated state or #f."
  (let loop ((entries state) (acc '()))
    (if (null? entries) #f
        (let ((entry (car entries)))
          (if (not (equal? (car entry) child-id))
              (loop (cdr entries) (cons entry acc))
              (let* ((stream (caddr entry))
                     (next (stream-take-1 stream)))
                (if (not next) #f
                    (append (reverse acc)
                            (list (list child-id (car next) (cdr next)))
                            (cdr entries)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Stream utilities
;;; ══════════════════════════════════════════════════════════════════════════════

(define (stream-map-lazy f $)
  (cond
    ((null? $) '())
    ((procedure? $) (lambda () (stream-map-lazy f ($))))
    (else (cons (f (car $)) (stream-map-lazy f (cdr $))))))

(define (stream-take-1 $)
  (cond
    ((null? $) #f)
    ((procedure? $) (stream-take-1 ($)))
    (else (cons (car $) (cdr $)))))

(define (stream-take-best $)
  "Force the entire stream, return the last (most improved) result."
  (let loop (($ $) (last #f))
    (cond
      ((null? $) last)
      ((procedure? $) (loop ($) last))
      (else (loop (cdr $) (car $))))))

(define (pull-from-all child-streams)
  "Pull one federation-result from each child's stream.
   Returns list of (child-id result rest-stream) triples."
  (let loop ((cs child-streams) (acc '()))
    (if (null? cs) (reverse acc)
        (let* ((cid (caar cs)) (stream (cdar cs))
               (pulled (stream-take-1 stream)))
          (loop (cdr cs)
                (cons (if pulled
                          (list cid (car pulled) (cdr pulled))
                          (list cid '() '()))
                      acc))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Helpers
;;; ══════════════════════════════════════════════════════════════════════════════

(define (reify-from-state state)
  (let* ((S (cstate-S state))
         (v (walk* (var 0) S))
         (R (reify-s v '())))
    (walk* v R)))

(define (reify-s v subst)
  (let ((v (walk v subst)))
    (cond
     ((var? v) (cons (cons v (string->symbol
                    (string-append "_." (number->string (length subst))))) subst))
     ((pair? v) (reify-s (cdr v) (reify-s (car v) subst)))
     (else subst))))

(define (extract-deficits plan scope-id)
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'unmet)
             `((scope . ,scope-id) (spec . ,(cadadr entry))
               (qty . ,(caddr (cadr entry))))))
        plan)))

(define (extract-surpluses plan scope-id)
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'satisfied)
             (let* ((pt (cadr entry))
                    (alloc (cadddr pt))
                    (needed (caddr pt))
                    (total (if (list? alloc)
                               (fold (lambda (a acc) (+ acc (cadr a))) 0 alloc) 0))
                    (surplus (- total needed)))
               (and (> surplus 0)
                    `((scope . ,scope-id) (spec . ,(cadr pt)) (qty . ,surplus))))))
        plan)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Entry point
;;; ══════════════════════════════════════════════════════════════════════════════

(define (plan-federation-o facts scope-ids parent-map ctx-map result)
  "Recursive streamed federation. Same protocol at every level."
  (project (facts scope-ids parent-map ctx-map)
    (let* ((children-of (build-hierarchy facts scope-ids parent-map))
           (root (or (find (lambda (id) (not (assoc-ref parent-map id))) scope-ids)
                     (and (pair? scope-ids) (car scope-ids))))
           (root-stream (if root
                            (scope-stream facts root ctx-map children-of)
                            '()))
           (best (stream-take-best root-stream)))
      (== result (if best best
                     `((scope . ,(or root "none")) (plan . ()) (residual . 0)))))))
