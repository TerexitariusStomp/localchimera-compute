;;; plan-relation.scm — Relational planning orchestrator
;;;
;;; Initializes running-sum variables from inventory, threads through demands.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *epsilon-plan* 1e-9)


;;; ── plan-o ────────────────────────────────────────────────────────────────────

(define* (plan-o ctx plan #:key (max-depth 10))
  "Relate open demands to a complete PLAN. Initializes shared allocation sums."
  (let* ((demands (extract-open-demands (ctx-ps ctx)))
         (facts (ctx-facts ctx))
         ;; Initialize running sums: each resource starts at 0
         (initial-sums
           (map (lambda (f) (cons (cadr f) 0))  ;; (resource-id . 0)
                (filter (lambda (f) (eq? (car f) 'inventory)) facts))))
    (fresh (sums-final)
      (all-demands-o ctx demands plan initial-sums sums-final
                     #:max-depth max-depth))))

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

(define* (all-demands-o ctx demands plans sums-in sums-out #:key (max-depth 10))
  "Solve demands, threading shared allocation sums."
  (if (null? demands)
      (fresh () (== plans '()) (== sums-out sums-in))
      (let* ((d (car demands))
             (spec (assq-ref d 'spec-id))
             (qty (assq-ref d 'quantity))
             (due (let ((v (assq-ref d 'due)))
                    (cond ((not v) (current-time))
                          ((number? v) v)
                          (else (iso-datetime->epoch v))))))
        (fresh (plan-term rest-plans sums-mid)
          (demand-o ctx spec qty due plan-term sums-in sums-mid
                    #:depth max-depth)
          (all-demands-o ctx (cdr demands) rest-plans sums-mid sums-out
                         #:max-depth max-depth)
          (== plans (cons (list d plan-term) rest-plans))))))


;;; ── relational-plan ───────────────────────────────────────────────────────────

(define* (relational-plan n recipe-store plan-store observer
                          #:key (location-store #f) (plan-id "rp")
                                (max-depth 10))
  "Lift facts, build ctx, run the planner. N plans returned."
  (let* ((facts (lift-planning-facts recipe-store observer))
         (ctx (make-plan-ctx facts plan-store observer location-store plan-id)))
    (run-plan n #f (plan)
      (plan-o ctx plan #:max-depth max-depth))))
