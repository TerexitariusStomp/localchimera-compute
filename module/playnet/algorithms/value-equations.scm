;;; value-equations.scm — Income distribution via contribution scoring
;;;
;;; A ValueEquation is a list of (weight . scorer) pairs.
;;; A scorer is (event) -> number. Income is distributed proportional to scores.

(define-module (playnet algorithms value-equations)
  #:use-module ((playnet vf formulas actions) #:select (using-up-actions nonconsuming-input-actions))
  #:use-module (playnet algorithms track-trace)
  #:use-module (playnet vf schemas)
  #:use-module (playnet utils store-utils)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:export (effort-scorer resource-scorer equal-scorer make-depreciation-scorer
            effort-equation equal-equation make-hybrid-equation score-event
            distribute-income distribute-multiple-income)
  #:use-module (srfi srfi-1))


;; ═════════════════════════════════════════════════════════════════════════
;; Built-in scorers
;; ═════════════════════════════════════════════════════════════════════════

(define (effort-scorer event)
  "Score by effort hours."
  (if (economic-event-effort-quantity event)
      (measure-has-numerical-value (economic-event-effort-quantity event))
      0))

(define (resource-scorer event)
  "Score by resource qty consumed (consume/use/cite only)."
  (if (and (memq (economic-event-action event) (append using-up-actions nonconsuming-input-actions))
           (economic-event-resource-quantity event))
      (measure-has-numerical-value (economic-event-resource-quantity event))
      0))

(define (equal-scorer event)
  "Equal weight for every contributor."
  1)

(define* (make-depreciation-scorer sne-index lifespans #:optional observer)
  "DEPRECATED. Scorer for 'use' events: (duration / lifespan) * SNE(tool-spec).
   Superseded by the convex engine's condition-good model, which is canonical:
   a durable's CONDITION is a stock good `Cond|durable`, per-recipe wear is a
   `consume` of it, and depreciation rolls into the product via good-labour-content
   — so lifespan is EMERGENT (condition ÷ per-recipe wear), responsive to use and
   maintenance, not a static per-spec number, and MORAL depreciation falls out of
   the `min` over condition's producers. See planner.scm ~806, test-wear-maintenance.scm,
   and test-wear-moral-depreciation.scm. Kept only for the legacy relational scorer."
  (lambda (event)
    (if (not (eq? (economic-event-action event) 'use)) 0
        (let* ((spec (economic-event-resource-conforms-to event))
               (sne (and spec (hashmap-ref sne-index spec 0)))
               (lifespan (and spec (hashmap-ref lifespans spec #f)))
               ;; Duration from event timestamps
               (dur-hours (if (and (economic-event-has-beginning event)
                                   (economic-event-has-end event))
                              (/ (- (iso-datetime->epoch (economic-event-has-end event))
                                    (iso-datetime->epoch (economic-event-has-beginning event)))
                                 3600)
                              ;; Fallback to effort quantity
                              (if (economic-event-effort-quantity event)
                                  (measure-has-numerical-value (economic-event-effort-quantity event))
                                  0))))
          (if (and sne lifespan (> lifespan 0))
              (* (/ dur-hours lifespan) sne)
              0)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Value equation: weighted sum of scorers
;; ═════════════════════════════════════════════════════════════════════════

(define (effort-equation)
  "100% effort scoring."
  `((1.0 . ,effort-scorer)))

(define (equal-equation)
  "100% equal scoring."
  `((1.0 . ,equal-scorer)))

(define* (make-hybrid-equation sne-index lifespans #:optional observer)
  "DEPRECATED (depreciation term). 60% effort + 40% depreciation. The depreciation
   half uses the legacy per-spec lifespan; the canonical depreciation is the convex
   engine's condition-good rollup (see make-depreciation-scorer above)."
  `((0.6 . ,effort-scorer)
    (0.4 . ,(make-depreciation-scorer sne-index lifespans observer))))


;; ═════════════════════════════════════════════════════════════════════════
;; Income distribution
;; ═════════════════════════════════════════════════════════════════════════

(define (score-event event equation)
  "Compute weighted score for a single event."
  (fold (lambda (component acc)
          (let ((weight (car component))
                (scorer (cdr component)))
            (+ acc (* weight (scorer event)))))
        0 equation))

(define (distribute-income income-event-id observer equation)
  "Trace backward from income event, score contributors, distribute proportionally.
   Returns alist: ((total-income . n) (distributions . list-of-alists))."
  (let* ((income-event ($ observer 'get-event income-event-id))
         (income-qty (if (and income-event (economic-event-resource-quantity income-event))
                         (measure-has-numerical-value (economic-event-resource-quantity income-event))
                         0))
         ;; Trace backward to find all contributing events
         (trace-nodes (trace income-event-id observer))
         (contributing-events
           (filter-map (lambda (node) (assq-ref node 'event)) trace-nodes))
         ;; Score each
         (scored (map (lambda (e)
                        (cons e (score-event e equation)))
                      contributing-events))
         (total-score (fold (lambda (pair acc) (+ acc (cdr pair))) 0 scored)))
    `((total-income . ,income-qty)
      (distributions .
        ,(map (lambda (pair)
                (let* ((e (car pair)) (score (cdr pair))
                       (share (if (> total-score 0) (/ score total-score) 0))
                       (amount (* income-qty share)))
                  `((event-id . ,(economic-event-id e))
                    (agent . ,(or (economic-event-provider e) (economic-event-receiver e)))
                    (score . ,score) (share . ,share) (amount . ,amount))))
              scored)))))

(define (distribute-multiple-income income-event-ids observer equation)
  "Map distribute-income over multiple income events."
  (map (lambda (id) (distribute-income id observer equation))
       income-event-ids))
