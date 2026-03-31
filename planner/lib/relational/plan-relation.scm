;;; plan-relation.scm — Relational planning orchestrator
;;;
;;; Demands sorted by priority: earliest due first, locally-satisfiable first.
;;; Highest-priority demands get first pick (max-first CLP/FD labeling).
;;; Lowest-priority demands sacrifice first (become purchase signals).
;;; Buffer conservation floors protect safety stock at every allocation.

(use-modules (playnet kanren-constraints)
             (srfi srfi-1))

(define *epsilon-plan* 1e-9)


;;; ── Demand priority ───────────────────────────────────────────────────────────
;;; The old planner classified demands:
;;;   0: locally-satisfiable (inventory covers it)
;;;   1: transport-candidate (needs cross-location transport)
;;;   2: producible-with-imports (has recipe, needs external inputs)
;;;   3: external-dependency (no recipe, must purchase)
;;; Then sorted by due date within each class.
;;;
;;; The relational version: same classification from facts, same sort.
;;; The search conjunction processes demands in this order.
;;; First demand gets first pick of inventory. Last demand sacrifices.

(define (classify-demand facts spec-id)
  "Classify a demand by how easily it can be satisfied."
  (let ((has-inventory (any (lambda (f)
                              (and (eq? (car f) 'inventory)
                                   (equal? (caddr f) spec-id)
                                   (> (cadddr f) 0)))
                            facts))
        (has-recipe (any (lambda (f)
                           (and (eq? (car f) 'recipe)
                                (equal? (cadddr f) spec-id)))
                         facts)))
    (cond (has-inventory 0)   ;; locally-satisfiable
          (has-recipe 2)      ;; producible
          (else 3))))         ;; external

(define (prioritize-demands demands facts)
  "Sort demands: highest priority first (lowest class, earliest due)."
  (sort demands
    (lambda (a b)
      (let ((ca (classify-demand facts (assq-ref a 'spec-id)))
            (cb (classify-demand facts (assq-ref b 'spec-id))))
        (if (not (= ca cb))
            (< ca cb)
            ;; Same class: earlier due date first
            (let ((da (or (assq-ref a 'due) 9999999999))
                  (db (or (assq-ref b 'due) 9999999999)))
              (< da db)))))))


;;; ── plan-o ────────────────────────────────────────────────────────────────────

(define* (plan-o ctx plan #:key (max-depth 10))
  "Relate open demands to a complete PLAN.
   Demands sorted by priority — highest first gets first pick.
   Lowest priority sacrifices first (implicit from conjunction order)."
  (let* ((raw-demands (extract-open-demands (ctx-ps ctx)))
         (demands (prioritize-demands raw-demands (ctx-facts ctx)))
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


;;; ── all-demands-o ─────────────────────────────────────────────────────────────

(define* (all-demands-o ctx demands plans sums-in sums-out #:key (max-depth 10))
  "Solve demands in priority order, threading shared allocation sums."
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
  "Lift facts, build ctx, run the planner."
  (let* ((facts (lift-planning-facts recipe-store observer))
         (ctx (make-plan-ctx facts plan-store observer location-store plan-id)))
    (run-plan n #f (plan)
      (plan-o ctx plan #:max-depth max-depth))))
