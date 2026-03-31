;;; plan-relation.scm — Relational planning orchestrator
;;;
;;; Lifts all data (recipes + inventory) to plain tuples at session start,
;;; then searches fully relationally. No netter, no project for allocation.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *epsilon-plan* 1e-9)


;;; ── plan-o ────────────────────────────────────────────────────────────────────

(define* (plan-o ctx plan #:key (max-depth 10))
  "Relate open demands to a complete PLAN."
  (let ((demands (extract-open-demands (ctx-ps ctx))))
    (all-demands-o ctx demands plan #:max-depth max-depth)))

(define (extract-open-demands plan-store)
  (filter-map
    (lambda (i)
      (let ((rq (intent-resource-quantity i)))
        (and rq (> (measure-has-numerical-value rq) *epsilon-plan*)
             `((spec-id . ,(intent-resource-conforms-to i))
               (quantity . ,(inexact->exact (round (measure-has-numerical-value rq))))
               (unit . ,(measure-has-unit rq))
               (due . ,(or (intent-due i) #f))
               (at-location . ,(intent-at-location i))))))
    ($ plan-store 'open-intents)))


;;; ── all-demands-o ─────────────────────────────────────────────────────────────

(define* (all-demands-o ctx demands plans #:key (max-depth 10))
  "Solve demands simultaneously. CLP(FD) domains track allocations."
  (if (null? demands)
      (== plans '())
      (let* ((d (car demands))
             (spec (assq-ref d 'spec-id))
             (qty (assq-ref d 'quantity))
             (due (let ((v (assq-ref d 'due)))
                    (cond ((not v) (current-time))
                          ((number? v) v)
                          (else (iso-datetime->epoch v))))))
        (fresh (plan-term rest-plans)
          (demand-o ctx spec qty due plan-term #:depth max-depth)
          (all-demands-o ctx (cdr demands) rest-plans #:max-depth max-depth)
          (== plans (cons (list d plan-term) rest-plans))))))


;;; ── relational-plan (convenience) ─────────────────────────────────────────────

(define* (relational-plan n recipe-store plan-store observer
                          #:key (location-store #f) (plan-id "rp")
                                (max-depth 10))
  "Run the relational planner. Lifts all data, searches with CLP(FD).
   N = #f for all plans, N = 1 for first valid plan."
  (let* ((facts (lift-planning-facts recipe-store observer))
         (ctx (make-plan-ctx facts plan-store observer location-store plan-id)))
    (run-plan n #f (plan)
      (plan-o ctx plan #:max-depth max-depth))))
