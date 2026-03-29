;;; transition.scm — Scope transition economics (CPM to social plan)
;;;
;;; Translated from src/lib/observation/transition.ts
;;; 24 functions for modeling the transition from market wages to
;;; commune claim capacities, tracking flow fractions, substitution ratios,
;;; and dollar wage phase-out.

(use-modules (srfi srfi-1))


;; ═════════════════════════════════════════════════════════════════════════
;; Flow fractions: social vs market input/output classification
;; ═════════════════════════════════════════════════════════════════════════

(define (compute-flow-fractions total-input-qty social-input-qty
                                total-output-qty social-output-qty
                                confirmed-receipt-qty)
  "Compute social/market flow ratios.
   Returns alist: social-input, social-output, confirmed, transition-depth."
  (let* ((si (if (> total-input-qty 0) (/ social-input-qty total-input-qty) 0))
         (so (if (> total-output-qty 0) (/ social-output-qty total-output-qty) 0))
         (cf (if (> total-output-qty 0) (/ confirmed-receipt-qty total-output-qty) 0)))
    `((social-input . ,si)
      (social-output . ,so)
      (confirmed . ,cf)
      (transition-depth . ,(* so cf)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Worker hours & wages
;; ═════════════════════════════════════════════════════════════════════════

(define (extract-worker-hours work-events)
  "Sum effort hours by provider agent from work events.
   Returns alist of (agent-id . hours)."
  (let ((hours (make-hash-table)))
    (for-each
      (lambda (e)
        (when (and (eq? (economic-event-action e) 'work)
                   (economic-event-provider e)
                   (economic-event-effort-quantity e))
          (let ((agent (economic-event-provider e))
                (h (measure-has-numerical-value (economic-event-effort-quantity e))))
            (hash-set! hours agent (+ (hash-ref hours agent 0) h)))))
      work-events)
    (hash-map->list cons hours)))

(define (compute-wage-rate-normalized hourly-rates)
  "Normalize each rate by group average. hourly-rates: alist of (agent . rate).
   Returns alist of (agent . normalized-rate)."
  (let* ((rates (map cdr hourly-rates))
         (avg (if (null? rates) 1 (/ (apply + rates) (length rates)))))
    (map (lambda (pair) (cons (car pair) (/ (cdr pair) avg)))
         hourly-rates)))

(define (compute-dollar-wages-per-worker total-dollar-wages hours-worked
                                         wage-rate-normalized)
  "Distribute total wages by weighted hours.
   hours-worked: alist (agent . hours). wage-rate-normalized: alist (agent . norm).
   Returns alist (agent . dollar-wage)."
  (let* ((weighted-hours
           (map (lambda (h)
                  (let ((norm (or (assoc-ref wage-rate-normalized (car h)) 1)))
                    (cons (car h) (* (cdr h) norm))))
                hours-worked))
         (total-weighted (fold (lambda (p acc) (+ acc (cdr p))) 0 weighted-hours)))
    (map (lambda (wh)
           (cons (car wh)
                 (if (> total-weighted 0)
                     (* total-dollar-wages (/ (cdr wh) total-weighted))
                     0)))
         weighted-hours)))

(define (compute-validated-hours hours-worked confirmed-output-fraction)
  "validated_hours[i] = confirmed_fraction * hours[i].
   Returns alist (agent . validated-hours)."
  (map (lambda (h) (cons (car h) (* confirmed-output-fraction (cdr h))))
       hours-worked))

(define (compute-claim-capacities validated-hours available-claimable-pool
                                   total-social-svc solidarity-supplements)
  "claim[i] = validated_hours[i] * (pool / total_svc) + solidarity[i].
   solidarity-supplements: alist (agent . amount).
   Returns alist (agent . claim-capacity)."
  (let ((ratio (if (> total-social-svc 0) (/ available-claimable-pool total-social-svc) 0)))
    (map (lambda (vh)
           (let ((solidarity (or (assoc-ref solidarity-supplements (car vh)) 0)))
             (cons (car vh) (+ (* (cdr vh) ratio) solidarity))))
         validated-hours)))


;; ═════════════════════════════════════════════════════════════════════════
;; Real wages & substitution
;; ═════════════════════════════════════════════════════════════════════════

(define (compute-effective-net-market-wage dollar-wage uncovered-essential-expenses)
  "effective = dollar_wage - uncovered_expenses."
  (- dollar-wage uncovered-essential-expenses))

(define (compute-real-wages average-claim-per-validated-hour
                           average-dollar-wage-per-hour
                           claim-purchasing-power dollar-purchasing-power)
  "Returns alist: social-real-wage, market-real-wage."
  `((social-real-wage . ,(* average-claim-per-validated-hour claim-purchasing-power))
    (market-real-wage . ,(* average-dollar-wage-per-hour dollar-purchasing-power))))

(define (compute-substitution-ratio social-real-wage confirmed-output-fraction
                                    market-real-wage)
  "composition = (social_rw * confirmed) / market_rw. 0 when denom=0."
  (if (= market-real-wage 0) 0
      (/ (* social-real-wage confirmed-output-fraction) market-real-wage)))

(define (compute-dollar-wage-phase-out-factor communal-satisfaction-ratio
                                              target-communal-ratio)
  "max(0, 1 - csr/target). 0 when csr >= target (fully phased out)."
  (max 0 (- 1 (if (> target-communal-ratio 0)
                   (/ communal-satisfaction-ratio target-communal-ratio)
                   0))))


;; ═════════════════════════════════════════════════════════════════════════
;; Collective metrics
;; ═════════════════════════════════════════════════════════════════════════

(define (compute-total-social-value claim-capacity claim-purchasing-power
                                    communal-need-coverage)
  "total_social_value = (claim * pp) + communal_coverage."
  (+ (* claim-capacity claim-purchasing-power) communal-need-coverage))

(define (compute-communal-satisfaction-ratio total-social-value
                                             effective-net-market-wage)
  "csr = total_social_value / effective_net_market_wage. 0 when denom <= 0."
  (if (<= effective-net-market-wage 0) 0
      (/ total-social-value effective-net-market-wage)))

(define (compute-dollar-balance market-revenue social-cash-revenue subsidy
                                market-input-cost social-input-cash-cost
                                other-costs contribution-sent)
  "Net financial position."
  (- (+ market-revenue social-cash-revenue subsidy)
     (+ market-input-cost social-input-cash-cost other-costs contribution-sent)))

(define (compute-collective-metrics market-revenue market-input-cost
                                    subsidy-received avg-claim-capacity
                                    avg-communal-coverage claim-purchasing-power)
  "Returns alist: scope-net-external, local-provision-value."
  `((scope-net-external . ,(- market-revenue market-input-cost subsidy-received))
    (local-provision-value . ,(+ (* avg-claim-capacity claim-purchasing-power)
                                 avg-communal-coverage))))


;; ═════════════════════════════════════════════════════════════════════════
;; Top-level report assembler
;; ═════════════════════════════════════════════════════════════════════════

(define (compute-scope-transition-report config)
  "Assemble full transition report from config alist.
   config keys: work-events, total-dollar-wages, hourly-rates,
                total-input-qty, social-input-qty, total-output-qty,
                social-output-qty, confirmed-receipt-qty,
                available-claimable-pool, total-social-svc,
                solidarity-supplements, claim-purchasing-power,
                dollar-purchasing-power, uncovered-expenses,
                target-communal-ratio, communal-need-coverage,
                market-revenue, market-input-cost, subsidy."
  (let* ((ff (compute-flow-fractions
               (assq-ref config 'total-input-qty)
               (assq-ref config 'social-input-qty)
               (assq-ref config 'total-output-qty)
               (assq-ref config 'social-output-qty)
               (assq-ref config 'confirmed-receipt-qty)))
         (hours (extract-worker-hours (assq-ref config 'work-events)))
         (norm-rates (compute-wage-rate-normalized (or (assq-ref config 'hourly-rates) '())))
         (dollar-wages (compute-dollar-wages-per-worker
                         (or (assq-ref config 'total-dollar-wages) 0)
                         hours norm-rates))
         (validated (compute-validated-hours hours (assq-ref ff 'confirmed)))
         (claims (compute-claim-capacities
                   validated
                   (or (assq-ref config 'available-claimable-pool) 0)
                   (or (assq-ref config 'total-social-svc) 0)
                   (or (assq-ref config 'solidarity-supplements) '()))))
    `((flow-fractions . ,ff)
      (worker-hours . ,hours)
      (dollar-wages . ,dollar-wages)
      (validated-hours . ,validated)
      (claim-capacities . ,claims))))
