;;; culcus.scm --- Cuculus host-eligibility & NAC opportunity dynamics
;;;
;;; SPECIFICATION
;;; =============
;;; Sources: docs/evr/NAC_sepv2.nlogo (authoritative equations)
;;;          docs/evr/EVR Token & System lifecycle - All Metrics.csv
;;;          ("Cuculus … Stanzi-Potenza, brood parasitism, sigmoid function")
;;;
;;; Cuculus (NetLogo: `culcus`) is a per-member administrative score that
;;; gates the right to *host* an opportunity in the Network of Apprenticeship
;;; & Craft (NAC) cycle. Its only feedback loops in the prototype are:
;;;
;;;   • host-eligibility:  culcus ≥ 30
;;;   • host-reward:       culcus' = culcus + 1  (per opportunity hosted)
;;;
;;; The richer dynamics tracked alongside culcus are:
;;;   • participation join probability,
;;;   • peer review (noisy) with EMA on perceived aptitude/disposition,
;;;   • reputation update (`local-public-rep`),
;;;   • aptitude growth from mentorship.
;;;
;;; All equations below mirror the NetLogo source verbatim.
;;;
;;; --- Host eligibility ----------------------------------------------------
;;;   eligible?(m)  ⇔  culcus(m) ≥ host-eligibility-threshold   ; default 30
;;;
;;; --- Host reward ---------------------------------------------------------
;;;   on opportunity hosted: culcus' = culcus + host-reward      ; default +1
;;;
;;; --- Join probability (per candidate, per opportunity) -------------------
;;;   Δa            = max(host-aptitude − my-aptitude, 0)
;;;   delta-weight  = 1 − 1 / (1 + Δa)                  ; ∈ [0, 1)
;;;   rep-weight    = sigmoid(rep-slope · (host-rep − mean-rep))   ; default slope 0.1
;;;   join-prob     = base-join + rep-weight · delta-weight        ; base-join 0.2
;;;
;;; --- Review noise --------------------------------------------------------
;;;   observed-score ~ N(true-value, σ)                            ; σ = 10
;;;
;;; --- Perception EMA (per review received) -------------------------------
;;;   reviewed-aptitude'    = (1−α)·reviewed-aptitude    + α·a-score   ; α = 0.1
;;;   reviewed-disposition' = (1−α)·reviewed-disposition + α·d-score
;;;
;;; --- Reputation update (per review received) ---------------------------
;;;   weight        = host-review-weight if target = current-host else 1
;;;   net-Δrep      = participation-rep-bump + ((d-score − 50) / 100) · weight
;;;   rep'          = rep + net-Δrep
;;; Centred at d-score = 50 (neutral): negative reviews drop rep, positive lift it.
;;;
;;; --- Aptitude growth (mentorship, non-host participants) ----------------
;;;   Δ      = host-aptitude − my-aptitude
;;;   gain   = base-growth + max(Δ, 0) · delta-growth-multiplier
;;;   apt'   = min(100, apt + gain)
;;;
;;; --- Brood-parasitism intuition (lifecycle CSV) -------------------------
;;; Cuculus naming alludes to brood parasitism: hosting capacity can be
;;; "raised" by the community (passive accumulation through participation),
;;; but a member's right to occupy hosting time is bounded and demurrage-
;;; eligible. The demurrage path is sketched but not implemented in the
;;; NetLogo prototype (see commented `decay-reputation`).
;;;
;;; This module is pure: no agent state, no RNG ownership. The simulator
;;; supplies noise via a sampler thunk so tests can pin a seed.

(define-module (docs evr algorithms culcus)
  #:use-module (srfi srfi-9)
  #:export (make-nac-params
            nac-params?
            default-nac-params
            host-eligible?
            host-reward
            join-probability
            review-noise-sample
            update-reviewed-ema
            reputation-update
            aptitude-growth
            sigmoid))

(define-record-type <nac-params>
  (make-nac-params host-eligibility-threshold host-reward-amount
                   base-join rep-slope review-noise-sigma
                   ema-alpha host-review-weight participation-rep-bump
                   base-growth delta-growth-multiplier
                   aptitude-cap)
  nac-params?
  (host-eligibility-threshold params-host-threshold)
  (host-reward-amount         params-host-reward)
  (base-join                  params-base-join)
  (rep-slope                  params-rep-slope)
  (review-noise-sigma         params-review-sigma)
  (ema-alpha                  params-ema-alpha)
  (host-review-weight         params-host-review-weight)
  (participation-rep-bump     params-participation-bump)
  (base-growth                params-base-growth)
  (delta-growth-multiplier    params-delta-growth-mult)
  (aptitude-cap               params-aptitude-cap))

(define default-nac-params
  (make-nac-params 30   1                   ; host-eligibility, host-reward
                   0.2  0.1  10.0           ; base-join, rep-slope, review σ
                   0.1  1.0  0.2            ; ema α, host-review-weight, rep-bump
                   0.2  0.1  100.0))        ; base-growth, Δ-growth mult, apt cap

(define (sigmoid x) (/ 1.0 (+ 1.0 (exp (- x)))))

(define (host-eligible? culcus params)
  (>= culcus (params-host-threshold params)))

(define (host-reward culcus params)
  (+ culcus (params-host-reward params)))

(define (join-probability host-reviewed-aptitude my-true-aptitude
                          host-rep mean-rep params)
  "Probability a candidate joins the host's opportunity.

Per NetLogo `simulate-opportunity`, the host aptitude consulted here is
the host's REVIEWED aptitude (peer perception), while the candidate's
own aptitude is its TRUE aptitude (self-knowledge). The asymmetry is
deliberate: candidates judge the host by reputation-of-skill, not by
ground truth they cannot observe."
  (let* ((delta-a      (max (- host-reviewed-aptitude my-true-aptitude) 0.0))
         (delta-weight (- 1.0 (/ 1.0 (+ 1.0 delta-a))))
         (rep-weight   (sigmoid (* (params-rep-slope params)
                                   (- host-rep mean-rep)))))
    (+ (params-base-join params)
       (* rep-weight delta-weight))))

(define (review-noise-sample true-value gaussian-sampler params)
  "GAUSSIAN-SAMPLER takes (mean, sigma) and returns a sample."
  (gaussian-sampler true-value (params-review-sigma params)))

(define (update-reviewed-ema prior observed params)
  (let ((a (params-ema-alpha params)))
    (+ (* (- 1.0 a) prior) (* a observed))))

(define (reputation-update rep d-score target-is-host? params)
  (let* ((weight   (if target-is-host?
                       (params-host-review-weight params)
                       1.0))
         (adjust   (* (/ (- d-score 50.0) 100.0) weight))
         (net      (+ (params-participation-bump params) adjust)))
    (+ rep net)))

(define (aptitude-growth my-true-aptitude host-true-aptitude params)
  "Mentorship-driven growth for a non-host participant.

Per NetLogo `simulate-opportunity`, growth is computed against the
host's TRUE aptitude (the actual mentorship signal), not its reviewed
aptitude. Compare with `join-probability`, which uses the host's
*reviewed* aptitude — the two consult different facets of the host."
  (let* ((delta (- host-true-aptitude my-true-aptitude))
         (gain  (+ (params-base-growth params)
                   (* (max delta 0.0)
                      (params-delta-growth-mult params)))))
    (min (params-aptitude-cap params)
         (+ my-true-aptitude gain))))
