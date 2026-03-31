;;; demand-relation.scm — Core demand relation, fully relational
;;;
;;; Allocation via CLP(FD) domain constraints (allocation.scm).
;;; Scale computation via project (ground arithmetic — both recipe output
;;; and remaining quantity are always concrete by this point).
;;; No imperative netter. No allocation hashmap.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *default-depth* 10)


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term
                   #:key (depth *default-depth*) (visited '()))
  "Relate a demand to a plan-term. Fully relational."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated)
        (allocate-o (ctx-facts ctx) spec-id qty remaining allocated)
        ;; remaining is always ground here (computed by allocate-from-o)
        (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth (cons spec-id visited)))))

(define (after-allocation ctx spec-id qty due remaining allocated
                          plan-term depth visited)
  "After allocation: satisfied, produce, or purchase.
   REMAINING is always ground (computed by allocate-from-o)."
  (project (remaining)
    (if (= remaining 0)
        (== plan-term `(satisfied ,spec-id ,qty ,allocated))
        (conde
          ((produce-branch ctx spec-id remaining due plan-term depth visited))
          ((== plan-term `(purchase ,spec-id ,remaining)))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term depth visited)
  "Find a recipe producing SPEC-ID, compute scale, recurse on inputs."
  (let ((facts (ctx-facts ctx)))
    (fresh (rid rname)
      (recipe-o facts rid rname spec-id)
      (project (rid remaining)
        (let* ((chain-fact (find (lambda (f)
                                   (and (eq? (car f) 'chain) (equal? (cadr f) rid)))
                                 facts))
               (pids (and chain-fact (caddr chain-fact)))
               (last-pid (and pids (pair? pids) (last pids)))
               (out-flow (and last-pid
                              (find (lambda (f)
                                      (and (eq? (car f) 'flow)
                                           (equal? (cadr f) last-pid)
                                           (eq? (caddr f) 'output)
                                           (equal? (cadddr f) spec-id)))
                                    facts)))
               (out-qty (if out-flow (list-ref out-flow 4) 1))
               (scale (if (and out-qty (> out-qty 0))
                          (ceiling (/ remaining out-qty))
                          remaining))
               (inputs (collect-consuming-inputs facts rid scale due)))
          (fresh (sub-plans)
            (solve-inputs-o ctx inputs sub-plans (- depth 1) visited)
            (== plan-term `(produce ,spec-id ,rid ,scale ,sub-plans))))))))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────

(define (solve-inputs-o ctx inputs sub-plans depth visited)
  (if (null? inputs)
      (== sub-plans '())
      (let* ((input (car inputs))
             (in-spec (car input))
             (in-qty (inexact->exact (ceiling (cadr input))))
             (needed-by (caddr input)))
        (fresh (sub-plan rest-plans)
          (demand-o ctx in-spec in-qty needed-by sub-plan
                    #:depth depth #:visited visited)
          (solve-inputs-o ctx (cdr inputs) rest-plans depth visited)
          (== sub-plans (cons (list in-spec sub-plan) rest-plans))))))
