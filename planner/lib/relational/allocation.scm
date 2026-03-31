;;; allocation.scm — Buffer-aware relational allocation via CLP(FD)
;;;
;;; The five-pass imperative orchestration (reserve → guard → defer →
;;; retry → sacrifice) collapses into one constraint:
;;;
;;;   sum-of-takes <= inventory - conservation-floor
;;;
;;; The conservation floor is TOR for buffered specs, 0 for unbuffered.
;;; The search naturally finds plans that protect buffers. If no
;;; buffer-safe plan exists, it falls through to buffer-draining plans
;;; (the "sacrifice" behavior) via conde ordering.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))


;;; ── Running-sum alist helpers ─────────────────────────────────────────────────

(define (sums-ref sums rid)
  (let ((pair (assoc rid sums))) (if pair (cdr pair) 0)))

(define (sums-set sums rid val)
  (cons (cons rid val)
        (filter (lambda (p) (not (equal? (car p) rid))) sums)))


;;; ── Conservation floor lookup ─────────────────────────────────────────────────

(define (conservation-floor facts spec-id)
  "TOR for buffered specs, 0 for unbuffered. Protects buffer safety stock."
  (let ((bz (find (lambda (f)
                    (and (eq? (car f) 'buffer-zone)
                         (equal? (cadr f) spec-id)))
                  facts)))
    (if bz (caddr bz) 0)))  ;; caddr = TOR field


;;; ── allocate-o ────────────────────────────────────────────────────────────────

(define (allocate-o facts spec-id qty remaining allocated sums-in sums-out)
  "Buffer-aware allocation. Won't drain below conservation floor (TOR)
   unless no buffer-safe plan exists."
  (let ((resources (filter (lambda (f)
                             (and (eq? (car f) 'inventory)
                                  (equal? (caddr f) spec-id)
                                  (> (cadddr f) 0)))
                           facts))
        (floor (conservation-floor facts spec-id)))
    ;; Try buffer-safe allocation first, then unrestricted as fallback
    (conde
      ;; Branch 1: respect conservation floor (buffer-safe)
      ((allocate-from-o qty resources remaining allocated sums-in sums-out floor))
      ;; Branch 2: ignore floor (sacrifice — only reached if branch 1 can't
      ;; satisfy the demand, and the search interleaves to explore this)
      ((allocate-from-o qty resources remaining allocated sums-in sums-out 0)))))

(define (allocate-from-o qty resources remaining allocated sums-in sums-out floor)
  "Post allocation constraints per resource with conservation floor."
  (if (null? resources)
      (fresh ()
        (== remaining qty)
        (== allocated '())
        (== sums-out sums-in))
      (let* ((r (car resources))
             (rid (cadr r))
             (inv-qty (cadddr r))
             (available (max 0 (- inv-qty floor)))  ;; respect conservation floor
             (old-sum (sums-ref sums-in rid)))
        (fresh (take new-sum rest-remaining rest-alloc sums-mid)
          ;; take ∈ [0, min(available, qty)]
          (rangeo take 0 (min available qty))
          ;; Running sum: total taken from this resource across all demands
          (+fd old-sum take new-sum)
          (<=fd new-sum inv-qty)  ;; hard cap: can't exceed physical inventory
          ;; remaining = qty - take
          (-fd qty take rest-remaining)
          ;; Label (max-first: try taking the most first)
          (labelfd take #:order 'max)
          ;; Recurse
          (allocate-from-o rest-remaining (cdr resources) remaining rest-alloc
                            (sums-set sums-in rid new-sum) sums-mid floor)
          ;; Build allocation list
          (project (take)
            (if (= take 0)
                (fresh () (== allocated rest-alloc) (== sums-out sums-mid))
                (fresh ()
                  (== allocated (cons (list rid take) rest-alloc))
                  (== sums-out sums-mid))))))))
