;;; option-premium.scm — Price VF Plans as options
;;;
;;; Each Plan the planner proposes is a put option on the resources it
;;; would restructure.  The premium per rollover cycle is driven primarily
;;; by the VOLATILITY of the plan's perceived exercise-probability, not
;;; by the expected direction of success/failure.
;;;
;;; Four public functions:
;;;   compute-plan-underlier  — S(P), total value of what the plan consumes
;;;   compute-plan-strike     — K(P), total cost to execute the plan
;;;   compute-plan-volatility — V(P), blended buffer + governance volatility
;;;   compute-plan-premium    — BSM-inspired premium from S, K, V, dt, r

;; series-stddev lives in correlation.scm — it was the only thing correlation
;; needed from here, which made the two a genuine cycle rather than an
;; ordering problem.
(define-module (playnet planner algorithms option-premium)
  #:use-module ((playnet planner formulas actions) #:select (using-up-actions transferring-actions effort-actions))
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner ddmrp records)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner algorithms correlation)
  #:export (cumulative-normal *consuming-input-actions* sum-recipe-flows
            compute-plan-underlier *all-input-actions* compute-plan-strike series-mean
            coefficient-of-variation governance-reversal-rate compute-plan-volatility
            record-premium-transfer! compute-plan-volatility/live compute-plan-premium
            compute-attributed-premium compute-attributed-premium/live)
  #:use-module (srfi srfi-1))



;; ────────────────────────���────────────────────────────────────────────
;; cumulative-normal — Abramowitz & Stegun 26.2.17
;; Accurate to ~7.5×10⁻⁸.  Pure arithmetic, no external dependencies.
;; ─────────────────────────────────────────────────────────────────────

(define (cumulative-normal x)
  (let* ((neg? (< x 0))
         (z (abs x))
         (b1 0.319381530)
         (b2 -0.356563782)
         (b3 1.781477937)
         (b4 -1.821255978)
         (b5 1.330274429)
         (p  0.2316419)
         (c  0.3989422804014327)  ; 1/√(2π)
         (t  (/ 1.0 (+ 1.0 (* p z))))
         (pdf (* c (exp (* -0.5 z z))))
         (cdf (- 1.0 (* pdf (+ (* b1 t)
                               (* b2 t t)
                               (* b3 t t t)
                               (* b4 t t t t)
                               (* b5 t t t t t))))))
    (if neg? (- 1.0 cdf) cdf)))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-underlier — S(P)
;;
;; Total value of the resources a plan's recipes would consume or
;; transfer.  Walks each recipe's input flows, sums qty × price.
;; ─────────────────────────────────────────────────────────────────────

(define *consuming-input-actions*            ; a stock used up, or handed over
  (append using-up-actions transferring-actions))

(define (sum-recipe-flows recipe-store recipe-id price-of action-filter)
  "Walk a recipe's processes, sum (qty × price) for flows matching action-filter."
  (let ((procs ($ recipe-store 'processes-for-recipe recipe-id)))
    (fold
      (lambda (rp acc)
        (let* ((pid (recipe-process-id rp))
               (flows-pair ($ recipe-store 'flows-for-process pid))
               (inputs (car flows-pair)))
          (+ acc
             (fold
               (lambda (f flow-acc)
                 (let ((action (recipe-flow-action f)))
                   (if (action-filter action)
                       (let* ((spec (recipe-flow-resource-conforms-to f))
                              (rq (recipe-flow-resource-quantity f))
                              (eq (recipe-flow-effort-quantity f)))
                         (cond
                           ((and (eq? action 'work) eq)
                            (+ flow-acc
                               (* (measure-has-numerical-value eq)
                                  (price-of "labor" (measure-has-unit eq)))))
                           ((and spec rq)
                            (+ flow-acc
                               (* (measure-has-numerical-value rq)
                                  (price-of spec (measure-has-unit rq)))))
                           (else flow-acc)))
                       flow-acc)))
               0 inputs))))
      0 procs)))

(define* (compute-plan-underlier recipe-store plan-recipe-ids
                                 #:key (price-of (lambda (spec unit) 0)))
  "S(P): sum of (input-quantity × unit-price) across all consume/transfer
   flows in the plan's recipes.  price-of: (spec-id unit) → number."
  (fold
    (lambda (rid acc)
      (+ acc (sum-recipe-flows recipe-store rid price-of
                               (lambda (a) (memq a *consuming-input-actions*)))))
    0 plan-recipe-ids))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-strike — K(P)
;;
;; Total execution cost: materials + labor.  For work flows, uses
;; effort-quantity × labor-rate.  For consume flows, uses the same
;; price-of as underlier.
;; ─────────────────────────────────────────────────────────────────────

(define *all-input-actions*                  ; …and the effort and occupation besides
  (append using-up-actions transferring-actions effort-actions))

(define* (compute-plan-strike recipe-store plan-recipe-ids
                              #:key (price-of (lambda (spec unit) 0)))
  "K(P): total cost to execute the plan — materials + labor."
  (fold
    (lambda (rid acc)
      (+ acc (sum-recipe-flows recipe-store rid price-of
                               (lambda (a) (memq a *all-input-actions*)))))
    0 plan-recipe-ids))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-volatility — V(P)
;;
;; Blended from two signal sources:
;;   1. Buffer-signal: coefficient of variation of onhand across snapshots
;;   2. Governance-signal: rate of support-direction reversals
;; ─────────────────────────────────────────────────────────────────────

(define (series-mean values)
  (if (null? values) 0
      (/ (fold + 0 values) (length values))))

(define (coefficient-of-variation values)
  "CV = stddev / |mean|.  Returns 0 if mean is zero."
  (let ((m (series-mean values))
        (s (series-stddev values)))
    (if (= m 0) 0 (/ s (abs m)))))

(define (governance-reversal-rate tallies)
  "Count direction-changes in a boolean support series.
   tallies: list of #t/#f (majority-support per cycle).
   Returns reversals / (n-1), normalized to [0, 1]."
  (if (or (null? tallies) (null? (cdr tallies)))
      0
      (let loop ((rest (cdr tallies))
                 (prev (car tallies))
                 (reversals 0))
        (if (null? rest)
            (/ reversals (- (length tallies) 1))
            (loop (cdr rest)
                  (car rest)
                  (if (not (equal? (car rest) prev))
                      (+ reversals 1)
                      reversals))))))

(define* (compute-plan-volatility snapshot-series governance-tallies
                                  #:key (buffer-weight 0.5)
                                        (governance-weight 0.5))
  "V(P): blended volatility from buffer-snapshot variance and governance
   signal reversals.
   snapshot-series: list of lists-of-numbers (onhand values per spec).
   governance-tallies: list of booleans (majority-support per cycle).
   Returns annualized volatility as a decimal (e.g. 0.35 = 35%)."
  (let* ((v-buffer
           (if (null? snapshot-series) 0
               (/ (fold + 0 (map coefficient-of-variation snapshot-series))
                  (length snapshot-series))))
         (v-governance
           (governance-reversal-rate governance-tallies)))
    (sqrt (+ (* buffer-weight (* v-buffer v-buffer))
             (* governance-weight (* v-governance v-governance))))))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-premium — BSM-inspired option pricing
;;
;; Two modes:
;;   'approximate — Premium ≈ S × V² × √dt  (the options reading)
;;   'bsm        — Full Black-Scholes put formula
;; ─────────────────────────────────────────────────────────────────────

;; ─────────────────────────────────────────────────────────────────────
;; record-premium-transfer! — double-entry premium payment
;;
;; Records the same transfer event in both scopes' observers. Each
;; observer processes only the resources it holds: the provider's
;; observer decrements, the receiver's increments.
;; ─────────────────────────────────────────────────────────────────────

(define (record-premium-transfer! provider-obs receiver-obs
                                  lower-event raise-event)
  "Double-entry premium transfer via paired lower/raise events.
   provider-obs records the lower (decrement); receiver-obs records
   the raise (increment). Both events should reference the same
   commitment and carry the same quantity."
  ($ provider-obs 'record-event lower-event)
  ($ receiver-obs 'record-event raise-event))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-volatility/live — query actors directly
;;
;; Wraps compute-plan-volatility with live snapshot-store queries.
;; Governance tallies are passed as a pre-computed boolean list since
;; ballot-store does not yet expose a time-series API.
;; ─────────────────────────────────────────────────────────────────────

(define* (compute-plan-volatility/live snapshot-store spec-ids governance-tallies
                                       #:key (window-from #f) (window-to #f)
                                             (buffer-weight 0.5)
                                             (governance-weight 0.5))
  "V(P) from live snapshot-store queries + pre-computed governance tallies.
   spec-ids: list of ResourceSpecification IDs to track.
   Returns volatility as decimal."
  (let ((snapshot-series
          (map (lambda (spec-id)
                 (let ((snaps ($ snapshot-store 'for-spec spec-id
                                 window-from window-to)))
                   (map buffer-snapshot-onhand snaps)))
               spec-ids)))
    (compute-plan-volatility snapshot-series governance-tallies
                             #:buffer-weight buffer-weight
                             #:governance-weight governance-weight)))


;; ─────────────────────────────────────────────────────────────────────
;; compute-plan-premium — BSM-inspired option pricing
;; ─────────────────────────────────────────────────────────────────────

(define* (compute-plan-premium S K V dt
                               #:key (r 0.0) (mode 'approximate))
  "Premium per rollover cycle.
   S: underlier value, K: strike/execution cost, V: volatility (decimal),
   dt: time in years (e.g. 30/365), r: risk-free/accumulation rate.
   mode: 'approximate or 'bsm."
  (case mode
    ((approximate)
     (* S V V (sqrt dt)))
    ((bsm)
     (if (or (<= V 0) (<= dt 0) (<= S 0) (<= K 0))
         (max 0 (- (* K (exp (* (- r) dt))) S))
         (let* ((sqrt-dt (sqrt dt))
                (d1 (/ (+ (log (/ S K))
                          (* (+ r (/ (* V V) 2)) dt))
                       (* V sqrt-dt)))
                (d2 (- d1 (* V sqrt-dt))))
           (- (* K (exp (* (- r) dt)) (cumulative-normal (- d2)))
              (* S (cumulative-normal (- d1)))))))
    (else (error "Unknown mode for compute-plan-premium" mode))))


;; ─────────────────────────────────────────────────────────────────────
;; compute-attributed-premium — an extractable bound
;;
;;   P_extract ≈ ρ² · N(1-R)  +  B(1-R)  −  C
;;
;; ρ is the OLS-R² attribution: the variance-share of the financial
;; index that the movement can credibly claim to drive. ρ² scales the
;; derivative-layer amplifier N(1-R) because a counterparty whose P&L
;; depends on the index only pays attribution-weighted protection.
;; The bondholder term B(1-R) is unaffected — underlying holders pay
;; on default regardless of attribution. C is the debtors' aggregate
;; default cost; credibility requires B(1-R) ≥ C, else the threat
;; collapses and no premium is extractable.
;; ─────────────────────────────────────────────────────────────────────

(define* (compute-attributed-premium #:key (B 0) (N 0) (R 0) (C 0) (rho 0))
  "An extractable rollover premium.
     B   : bondholder / underlying face value
     N   : net derivative notional (naked protection sellers' exposure)
     R   : recovery rate on default (0..1)
     C   : debtors' aggregate default cost (credibility floor)
     rho : correlation between movement support and the financial index
   Returns an alist:
     (extractable      . number)  ; P_extract, clipped at 0
     (bondholder-term  . number)  ; B(1-R)
     (derivative-term  . number)  ; ρ²·N(1-R)
     (credibility-cost . number)  ; C
     (credible?        . boolean) ; B(1-R) >= C
     (attribution      . number)) ; ρ²
   If not credible, extractable = 0 regardless of derivative layer."
  (let* ((lgd-b (* B (- 1 R)))
         (lgd-n (* N (- 1 R)))
         (rho2  (* rho rho))
         (deriv (* rho2 lgd-n))
         (credible? (>= lgd-b C))
         (raw   (+ lgd-b deriv (- C)))
         (extract (if credible? (max 0 raw) 0)))
    `((extractable      . ,extract)
      (bondholder-term  . ,lgd-b)
      (derivative-term  . ,deriv)
      (credibility-cost . ,C)
      (credible?        . ,credible?)
      (attribution      . ,rho2))))


(define* (compute-attributed-premium/live view #:key (B 0) (N 0) (R 0) (C 0)
                                          (from-ts #f) (to-ts #f))
  "Pull ρ from a <covariance-view> and apply the bound.
   Returns compute-attributed-premium's alist, enriched with
   (rho . number) (sigma-index . number) (sample-size . n)
   (window-from-ts . seconds) (window-to-ts . seconds).
   Must be called within the vat hosting VIEW's stream sources."
  (let* ((corr (compute-correlation view #:from-ts from-ts #:to-ts to-ts))
         (rho  (assq-ref corr 'rho))
         (result (compute-attributed-premium #:B B #:N N #:R R #:C C #:rho rho)))
    (append result
            `((rho            . ,rho)
              (sigma-index    . ,(assq-ref corr 'sigma-b))
              (sample-size    . ,(assq-ref corr 'n))
              (window-from-ts . ,(assq-ref corr 'from-ts))
              (window-to-ts   . ,(assq-ref corr 'to-ts))))))
