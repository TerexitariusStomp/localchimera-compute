;;; federation.scm — Recursive streamed federation
;;;
;;; The protocol is the same at every level of the hierarchy:
;;;
;;;   scope-stream : scope → lazy stream of (plan . residual)
;;;
;;; A leaf scope's stream is a miniKanren search over local facts.
;;; A parent scope's stream is an interleaving of its children's streams.
;;; The root never sees leaf-level facts — only its children's streams.
;;;
;;; Each level: pull one plan per child, match laterally, advance the
;;; child with the largest deficit. Same objective recursively:
;;; minimize residual, protect buffers, prefer lowest SNE.

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
  "Returns alist: scope-id → (children . list)."
  (let ((ch (make-hash-table)))
    (for-each (lambda (id) (hash-set! ch id '())) scope-ids)
    (for-each (lambda (id)
                (let ((parent (assoc-ref parent-map id)))
                  (when (and parent (member parent scope-ids))
                    (hash-set! ch parent (cons id (hash-ref ch parent '()))))))
              scope-ids)
    (hash-map->list cons ch)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; The universal protocol: scope-stream
;;; ══════════════════════════════════════════════════════════════════════════════
;;;
;;; Every scope — leaf or parent — produces the same thing:
;;;   a lazy stream of federation-result alists, each containing:
;;;     (plan . ...)              — what this scope decided
;;;     (deficits . ...)          — what it still needs
;;;     (surpluses . ...)         — what it can offer
;;;     (residual . number)       — total unmet demand
;;;
;;; Consumers of the stream don't know or care whether the scope
;;; is a leaf (miniKanren search) or a parent (interleaved children).

(define (scope-stream facts scope-id ctx-map children-of)
  "Universal: produce a lazy stream for SCOPE-ID.
   Leaf scopes search locally. Parent scopes interleave children."
  (let ((children (or (assoc-ref children-of scope-id) '())))
    (if (null? children)
        ;; Leaf: miniKanren search over local facts
        (leaf-stream scope-id ctx-map)
        ;; Parent: interleave children's streams
        (parent-stream facts scope-id children ctx-map children-of))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Leaf stream — miniKanren search, lazily
;;; ══════════════════════════════════════════════════════════════════════════════

(define (leaf-stream scope-id ctx-map)
  "Lazy plan stream for a leaf scope. Each element is a federation-result."
  (let* ((ctx (assoc-ref ctx-map scope-id))
         (raw-stream (if ctx
                         ((fresh (plan) (plan-o ctx plan #:max-depth 5))
                          (empty-cstate #f))
                         '())))
    ;; Wrap each raw miniKanren state into a federation-result
    (stream-map-lazy
      (lambda (state)
        (let* ((plan (reify-from-state state))
               (defs (extract-deficits plan scope-id))
               (surps (extract-surpluses plan scope-id))
               (resid (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 defs)))
          `((scope . ,scope-id) (plan . ,plan)
            (deficits . ,defs) (surpluses . ,surps)
            (residual . ,resid))))
      raw-stream)))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Parent stream — interleave children, match laterally
;;; ══════════════════════════════════════════════════════════════════════════════

(define (parent-stream facts scope-id children ctx-map children-of)
  "Lazy federation stream for a parent scope.
   Recursively creates child streams, interleaves them."
  (let* (;; Each child gets its own stream (recursively — children may be parents too)
         (child-streams
           (map (lambda (cid)
                  (cons cid (scope-stream facts cid ctx-map children-of)))
                children))
         ;; Pull first result from each child
         (initial (pull-from-all child-streams)))
    (if (not initial)
        '()  ;; no children produced results
        ;; Generate federation results lazily
        (federation-search-stream facts scope-id initial *max-steps*))))

(define *max-steps* 50)

(define (federation-search-stream facts scope-id state steps)
  "Lazy stream of federation results. Each step advances one child."
  (let* ((result (evaluate-federation facts scope-id state)))
    (if (or (<= steps 0) (= (assq-ref result 'residual) 0))
        ;; Terminal: return this result as a single-element stream
        (list result)
        ;; Non-terminal: this result, then lazily try advancing
        (cons result
              (lambda ()  ;; suspension — only computed when pulled
                (let ((advanced (advance-worst-child state
                                  (assq-ref result 'unmatched))))
                  (if (not advanced)
                      '()  ;; all children's streams exhausted
                      (federation-search-stream facts scope-id
                                                advanced (- steps 1)))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Federation evaluation — match children's results at this level
;;; ══════════════════════════════════════════════════════════════════════════════

(define (evaluate-federation facts scope-id state)
  "Given current child results, compute this level's federation result."
  (let* (;; Aggregate deficits and surpluses from all children
         (all-defs (append-map (lambda (s)
           (or (assq-ref (cadr s) 'deficits) '())) state))
         (all-surps (append-map (lambda (s)
           (or (assq-ref (cadr s) 'surpluses) '())) state))
         ;; Match laterally at this level
         (match-result (match-at-level facts all-defs all-surps))
         (matches (car match-result))
         (unmatched (cdr match-result))
         (residual (fold (lambda (d a) (+ a (assq-ref d 'qty))) 0 unmatched))
         ;; This scope's combined plan
         (child-plans (map (lambda (s) (cons (car s) (assq-ref (cadr s) 'plan)))
                           state)))
    `((scope . ,scope-id)
      (plan . ,child-plans)
      (deficits . ,unmatched)       ;; what THIS level can't resolve
      (surpluses . ,(remaining-surpluses all-surps matches))
      (lateral-matches . ,matches)
      (residual . ,residual)
      (unmatched . ,unmatched))))

(define (remaining-surpluses surpluses matches)
  "Surpluses after matches have consumed some."
  (fold (lambda (m sups)
          (map (lambda (s)
            (if (and (equal? (assq-ref s 'scope) (assq-ref m 'from))
                     (equal? (assq-ref s 'spec) (assq-ref m 'spec)))
                (cons (cons 'qty (- (assq-ref s 'qty) (assq-ref m 'qty)))
                      (filter (lambda (p) (not (eq? (car p) 'qty))) s))
                s))
            sups))
        surpluses matches))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Lateral matching (peer enforcement via parent facts)
;;; ══════════════════════════════════════════════════════════════════════════════

(define (match-at-level facts deficits surpluses)
  "Match deficits with surpluses. Returns (matches . unmatched)."
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
                                 (> (assq-ref s 'qty) 0)))
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
                             s)) sups)))
                  (loop (cdr defs) new-sups
                        (cons match matches) unmatched))))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Stream utilities
;;; ══════════════════════════════════════════════════════════════════════════════

(define (stream-map-lazy f stream)
  "Lazily map F over a miniKanren stream."
  (cond
    ((null? stream) '())
    ((procedure? stream) (lambda () (stream-map-lazy f (stream))))
    (else (cons (f (car stream))
                (stream-map-lazy f (cdr stream))))))

(define (stream-take-1 $)
  "Force one answer. Returns (answer . rest) or #f."
  (cond
    ((null? $) #f)
    ((procedure? $) (stream-take-1 ($)))
    (else (cons (car $) (cdr $)))))

(define (pull-from-all child-streams)
  "Pull one result from each child stream. Returns ((cid result stream) ...) or #f."
  (let loop ((cs child-streams) (acc '()))
    (if (null? cs) (reverse acc)
        (let* ((cid (caar cs)) (stream (cdar cs))
               (pulled (stream-take-1 stream)))
          (if (not pulled)
              (loop (cdr cs) (cons (list cid '() '()) acc))
              (loop (cdr cs)
                    (cons (list cid (car pulled) (cdr pulled)) acc)))))))

(define (advance-worst-child state unmatched-deficits)
  "Advance the child with the largest unmatched deficit by one stream step."
  (if (null? unmatched-deficits) #f
      (let* ((worst-scope (assq-ref
               (car (sort unmatched-deficits
                      (lambda (a b) (> (assq-ref a 'qty) (assq-ref b 'qty)))))
               'scope))
             ;; Find this child in state and advance its stream
             (entry (find (lambda (s) (equal? (car s) worst-scope)) state)))
        (if (not entry) #f
            (let* ((stream (caddr entry))
                   (next (stream-take-1 stream)))
              (if (not next) #f
                  (map (lambda (s)
                    (if (equal? (car s) worst-scope)
                        (list worst-scope (car next) (cdr next))
                        s))
                    state)))))))


;;; ══════════════════════════════════════════════════════════════════════════════
;;; Helpers
;;; ══════════════════════════════════════════════════════════════════════════════

(define (reify-from-state state)
  "Extract plan from miniKanren state."
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

(define (extract-deficits plan scope-id)
  (if (not (list? plan)) '()
      (filter-map (lambda (entry)
        (and (pair? entry) (pair? (cadr entry))
             (eq? (caadr entry) 'purchase)
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
           ;; Find the root (scope with no parent, or the first scope)
           (root (or (find (lambda (id) (not (assoc-ref parent-map id))) scope-ids)
                     (car scope-ids)))
           ;; Build the recursive stream from the root
           (root-stream (scope-stream facts root ctx-map children-of))
           ;; Pull the best result
           (best (stream-take-1 root-stream)))
      (== result (if best (car best)
                     `((scope . ,root) (plan . ()) (residual . 0)))))))
