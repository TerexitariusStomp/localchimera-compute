;;; demand-relation.scm — Core demand relation for the relational planner
;;;
;;; Facts are plain tuples queried via in-list-o + unification.
;;; project used only for arithmetic (scale, scheduling).
;;; Depth-bounded like transitive-o to prevent divergence.

(use-modules (playnet kanren-planning)
             (srfi srfi-1))

(define *epsilon* 1e-9)
(define *default-depth* 10)


;;; ── demand-o ──────────────────────────────────────────────────────────────────

(define* (demand-o ctx spec-id qty due plan-term
                   #:key (depth *default-depth*) (visited '()))
  "Relate a demand to a plan-term. Explores all recipes via conde."
  (if (or (= depth 0) (member spec-id visited))
      fail
      (fresh (remaining allocated)
        (net-demand-o ctx spec-id qty remaining allocated)
        (after-netting ctx spec-id qty due remaining allocated
                       plan-term depth (cons spec-id visited)))))

(define (after-netting ctx spec-id qty due remaining allocated
                       plan-term depth visited)
  (project (remaining allocated)
    (if (< remaining *epsilon*)
        (== plan-term `(satisfied ,spec-id ,qty ,allocated))
        (conde
          ((produce-branch ctx spec-id remaining due plan-term depth visited))
          ((== plan-term `(purchase ,spec-id ,remaining)))))))


;;; ── produce-branch ────────────────────────────────────────────────────────────

(define (produce-branch ctx spec-id remaining due plan-term depth visited)
  "Find a recipe producing SPEC-ID, compute inputs, recurse."
  (let ((facts (ctx-facts ctx)))
    (fresh (rid rname)
      ;; Pure relational: which recipe produces this spec?
      (recipe-o facts rid rname spec-id)
      ;; Arithmetic via project: scale and schedule
      (project (rid remaining)
        (let* ((scale (compute-scale facts rid spec-id remaining))
               (inputs (collect-consuming-inputs facts rid scale due)))
          (fresh (sub-plans)
            (solve-inputs-o ctx inputs sub-plans (- depth 1) visited)
            (== plan-term `(produce ,spec-id ,rid ,scale ,sub-plans))))))))


;;; ── solve-inputs-o ────────────────────────────────────────────────────────────

(define (solve-inputs-o ctx inputs sub-plans depth visited)
  "Recursively solve a list of (spec-id qty needed-by) demands."
  (if (null? inputs)
      (== sub-plans '())
      (let* ((input (car inputs))
             (in-spec (car input))
             (in-qty (cadr input))
             (needed-by (caddr input)))
        (fresh (sub-plan rest-plans)
          (demand-o ctx in-spec in-qty needed-by sub-plan
                    #:depth depth #:visited visited)
          (solve-inputs-o ctx (cdr inputs) rest-plans depth visited)
          (== sub-plans (cons (list in-spec sub-plan) rest-plans))))))
