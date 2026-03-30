;;; allocation.scm — Pure relational allocation via CLP(FD) deferred labeling
;;;
;;; Each take amount is a CLP(FD) variable. Constraints are posted,
;;; propagation narrows domains, labeling resolves when needed.
;;; Shared running-sum variables prevent double-allocation across demands.
;;;
;;; NOTE: labeling strategy is currently min-first (default).
;;; For future optimization, could use max-first or proportional heuristics
;;; without changing the constraint structure.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── Running-sum alist helpers ─────────────────────────────────────────────────

(define (sums-ref sums rid)
  "Get the current running-sum variable/value for resource RID."
  (let ((pair (assoc rid sums)))
    (if pair (cdr pair) 0)))

(define (sums-set sums rid val)
  "Set the running-sum for RID."
  (cons (cons rid val)
        (filter (lambda (p) (not (equal? (car p) rid))) sums)))


;;; ── allocate-o ────────────────────────────────────────────────────────────────

(define (allocate-o facts spec-id qty remaining allocated sums-in sums-out)
  "Allocate QTY of SPEC-ID from inventory. Posts CLP(FD) constraints.
   SUMS-IN/SUMS-OUT: running-sum alist tracking total taken per resource.
   REMAINING and ALLOCATED are logic variables unified by constraints."
  (let ((resources (filter (lambda (f)
                             (and (eq? (car f) 'inventory)
                                  (equal? (caddr f) spec-id)
                                  (> (cadddr f) 0)))
                           facts)))
    (allocate-from-o qty resources remaining allocated sums-in sums-out)))

(define (allocate-from-o qty resources remaining allocated sums-in sums-out)
  "Post allocation constraints across matching resources, then label."
  (if (null? resources)
      ;; No more resources — remaining = full qty, nothing allocated
      (fresh ()
        (== remaining qty)
        (== allocated '())
        (== sums-out sums-in))
      (let* ((r (car resources))
             (rid (cadr r))
             (inv-qty (cadddr r))
             (old-sum (sums-ref sums-in rid)))
        (fresh (take new-sum rest-remaining rest-alloc sums-mid)
          ;; CLP(FD) constraints: take ∈ [0, min(inv-qty, qty)]
          (rangeo take 0 (min inv-qty qty))
          ;; Constraints (order-independent — propagators re-fire when take is labeled)
          (+fd old-sum take new-sum)
          (<=fd new-sum inv-qty)
          (-fd qty take rest-remaining)
          ;; Label take (max-first: try taking the most first for efficiency)
          ;; NOTE: change to #:order 'min for different search strategy
          (labelfd take #:order 'max)
          ;; Recurse on remaining resources with reduced quantity
          (allocate-from-o rest-remaining (cdr resources) remaining rest-alloc
                            (sums-set sums-in rid new-sum) sums-mid)
          ;; Build allocation list (skip zero takes)
          (project (take)
            (if (= take 0)
                (fresh () (== allocated rest-alloc) (== sums-out sums-mid))
                (fresh ()
                  (== allocated (cons (list rid take) rest-alloc))
                  (== sums-out sums-mid))))))))
