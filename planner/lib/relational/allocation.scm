;;; allocation.scm — Pure relational allocation
;;;
;;; Replaces netter-goals.scm. Allocation from inventory facts.
;;; Uses CLP(FD) for cross-demand constraints, direct computation
;;; for the common case where quantities are ground.
;;;
;;; The key insight: inventory quantities and demand quantities are always
;;; ground (lifted from concrete data). The allocation is deterministic:
;;; take = min(available, needed). No enumeration needed.
;;;
;;; CLP(FD) enters when demands COMPETE for shared resources — the domain
;;; narrowing tracks what's left after each allocation.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── allocate-o ────────────────────────────────────────────────────────────────

(define (allocate-o facts spec-id qty remaining allocated)
  "Allocate QTY of SPEC-ID from inventory facts.
   REMAINING = unmet quantity. ALLOCATED = list of (resource-id amount) pairs.
   Greedy: takes as much as possible from each resource in order."
  (let ((resources (filter (lambda (f)
                             (and (eq? (car f) 'inventory)
                                  (equal? (caddr f) spec-id)
                                  (> (cadddr f) 0)))
                           facts)))
    (allocate-from-o qty resources remaining allocated)))

(define (allocate-from-o qty resources remaining allocated)
  "Fold allocation across inventory resources. QTY must be ground (integer)."
  (if (null? resources)
      ;; No more resources — whatever's left is remaining
      (fresh () (== remaining qty) (== allocated '()))
      (let* ((r (car resources))
             (rid (cadr r))
             (inv-qty (cadddr r))
             (take (min inv-qty qty))
             (rest-qty (- qty take)))
        (if (= take 0)
            ;; Nothing to take from this resource — skip
            (allocate-from-o qty (cdr resources) remaining allocated)
            ;; Take what we can, recurse with reduced quantity
            (fresh (rest-alloc)
              (allocate-from-o rest-qty (cdr resources) remaining rest-alloc)
              (== allocated (cons (list rid take) rest-alloc)))))))
