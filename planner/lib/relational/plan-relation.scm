;;; plan-relation.scm — Relational planning orchestrator
;;;
;;; The planner is neutral. It takes demands and searches for plans.
;;; Demand priority is a social decision — the commune provides it
;;; via an optional ordering function. The planner doesn't classify.
;;;
;;; No sums threading — allocation uses global sum constraints in CLP(FD).
;;; The claim registry lives in the N field of the cstate vector.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *epsilon-plan* 1e-9)


;;; ── plan-o ────────────────────────────────────────────────────────────────────

(define* (plan-o ctx plan #:key (max-depth 10) (demand-order #f))
  "Relate open demands to a complete PLAN."
  (let* ((raw (extract-open-demands (ctx-ps ctx)))
         (demands (if demand-order (sort raw demand-order) raw)))
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


;;; ── Standard demand orderings (policy — provided by the commune) ──────────────

(define (by-due-date a b)
  "Earlier due date first."
  (let ((da (or (assq-ref a 'due) 9999999999))
        (db (or (assq-ref b 'due) 9999999999)))
    (< da db)))

(define (by-local-first facts)
  "Locally-satisfiable demands first, then producible, then external."
  (lambda (a b)
    (let ((ca (demand-class facts (assq-ref a 'spec-id)))
          (cb (demand-class facts (assq-ref b 'spec-id))))
      (if (not (= ca cb)) (< ca cb)
          (by-due-date a b)))))

(define (demand-class facts spec-id)
  "0 = has inventory, 2 = has recipe, 3 = external."
  (cond
    ((any (lambda (f) (and (eq? (car f) 'inventory)
                           (equal? (caddr f) spec-id)
                           (> (cadddr f) 0))) facts) 0)
    ((any (lambda (f) (and (eq? (car f) 'recipe)
                           (equal? (cadddr f) spec-id))) facts) 2)
    (else 3)))


;;; ── all-demands-o ─────────────────────────────────────────────────────────────

(define* (all-demands-o ctx demands plans #:key (max-depth 10))
  "Solve all demands via map-goal-o. Claims accumulate in the N field."
  (map-goal-o demands
    (lambda (d result)
      (let* ((spec (assq-ref d 'spec-id))
             (qty (assq-ref d 'quantity))
             (due (let ((v (assq-ref d 'due)))
                    (cond ((not v) (current-time))
                          ((number? v) v)
                          (else (iso-datetime->epoch v)))))
             (loc (assq-ref d 'at-location)))
        (fresh (plan-term)
          (demand-o ctx spec qty due plan-term
                    #:depth max-depth #:at-location loc)
          (== result (list d plan-term)))))
    plans))


;;; ── relational-plan ───────────────────────────────────────────────────────────

(define* (relational-plan n recipe-store plan-store observer
                          #:key (location-store #f) (plan-id "rp")
                                (max-depth 10) (demand-order #f)
                                (live-registry #f))
  "Lift facts, build indexes, run the planner."
  (let* ((facts (lift-planning-facts recipe-store observer plan-store #f live-registry))
         (indexes (build-indexes facts))
         (ctx (make-plan-ctx facts plan-store observer location-store plan-id indexes)))
    (run-plan n '() (plan)
      (plan-o ctx plan #:max-depth max-depth #:demand-order demand-order))))
