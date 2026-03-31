;;; plan-relation.scm — Relational planning orchestrator
;;;
;;; The planner is neutral. It takes demands and searches for plans.
;;; Demand priority is a social decision — the commune provides it
;;; via an optional ordering function. The planner doesn't classify.
;;;
;;; Default: no ordering — demands processed as given, search explores all.
;;; With ordering: highest-priority demands get first pick of inventory.
;;; The ordering is a heuristic (biases run-plan 1), not a constraint
;;; (run-plan* finds all plans regardless of order).

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *epsilon-plan* 1e-9)


;;; ── plan-o ────────────────────────────────────────────────────────────────────

(define* (plan-o ctx plan #:key (max-depth 10) (demand-order #f))
  "Relate open demands to a complete PLAN.
   DEMAND-ORDER: optional (a b → bool) comparator for demand priority.
   If provided, demands are sorted — highest priority gets first pick.
   If #f, demands are processed in natural order."
  (let* ((raw (extract-open-demands (ctx-ps ctx)))
         (demands (if demand-order (sort raw demand-order) raw))
         (facts (ctx-facts ctx))
         (initial-sums
           (map (lambda (f) (cons (cadr f) 0))
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


;;; ── Standard demand orderings (policy — provided by the commune) ──────────────

(define (by-due-date a b)
  "Earlier due date first."
  (let ((da (or (assq-ref a 'due) 9999999999))
        (db (or (assq-ref b 'due) 9999999999)))
    (< da db)))

(define (by-local-first facts)
  "Locally-satisfiable demands first, then producible, then external.
   Returns a comparator closed over FACTS."
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

(define* (all-demands-o ctx demands plans sums-in sums-out #:key (max-depth 10))
  "Solve demands in given order, threading shared allocation sums."
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
                                (max-depth 10) (demand-order #f))
  "Lift facts, build indexes, run the planner."
  (let* ((facts (lift-planning-facts recipe-store observer plan-store))
         (indexes (build-indexes facts))
         (ctx (make-plan-ctx facts plan-store observer location-store plan-id indexes)))
    (run-plan n #f (plan)
      (plan-o ctx plan #:max-depth max-depth #:demand-order demand-order))))
