;;; billings.scm --- Billings reputation score (EVR arbitration)
;;;
;;; SPECIFICATION
;;; =============
;;; Source: docs/evr/billings-overview.md
;;;
;;; Domain: a per-member scalar in [0, 1] used to gate the right to *initiate*
;;; arbitration of a Dilemma. Voting power is NOT a function of the Billings
;;; score — score only controls submission. This is an explicit no-feedback-loop
;;; invariant of the design.
;;;
;;; Baseline: every new member starts at 0.5.
;;;
;;; Score update (sigmoid-bounded delta):
;;;   sigmoid(v)  = 1 / (1 + exp(-k * (v - x0)))   ; k = 10, x0 = 0.5
;;;   v'          = clamp(v + Δ · sigmoid(v), 0, 1)
;;; The sigmoid factor softens both reward and penalty as v approaches the
;;; extremes, so scores neither saturate at 1 nor collapse to 0 from a single
;;; event. The unsigned magnitudes (Δ_success, Δ_fail, δ_support, ε_idle) are
;;; system parameters; this module exposes them as a record so the simulator
;;; and production wiring can supply their own.
;;;
;;; Event taxonomy:
;;;   'success      successful suggestion        => +Δ_success
;;;   'fail         failed, unsupported          => -Δ_fail
;;;   'support      QR-cosigned someone else     => +δ_support
;;;   'idle         time-based passive bump      => +ε_idle
;;;
;;; Arbitration threshold (attention-scaled):
;;;   threshold(views) = min(base · log(views + 1), 0.95)   ; base = 0.4
;;; A Dilemma with no views sits just below baseline (0.4 < 0.5), letting any
;;; single member at baseline initiate. Each additional view compounds
;;; logarithmically; the cap at 0.95 prevents an unwinnable threshold.
;;;
;;; Score pooling / cosigning:
;;;   can-initiate?(scores, views) = (Σ scores) ≥ threshold(views)
;;; Multiple members combine Billings scores to clear a high-attention
;;; threshold. The retry path for a failed Dilemma requires 3 cosigners.
;;;
;;; Exponential attention escalation (rounds):
;;;   round-threshold(n) = 3^n         ; round n ∈ {1, 2, ...}
;;; Models the prototype's "more rounds = more attention" mechanic; not
;;; folded into `threshold` above because it represents engagement-window
;;; depth rather than view count.
;;;
;;; Out of scope here: identity, persistence, the QR transport, retry-window
;;; timers, sybil resistance. This module is pure: state in, state out.

(define-module (docs evr algorithms billings)
  #:use-module (srfi srfi-9)
  #:export (make-billings-params
            billings-params?
            default-billings-params
            sigmoid
            apply-delta
            update-score
            arbitration-threshold
            can-initiate?
            round-threshold
            baseline-score))

(define baseline-score 0.5)

(define-record-type <billings-params>
  (make-billings-params delta-success delta-fail delta-support epsilon-idle
                        sigmoid-k sigmoid-x0
                        base-threshold threshold-cap
                        cosigners-required)
  billings-params?
  (delta-success      params-delta-success)
  (delta-fail         params-delta-fail)
  (delta-support      params-delta-support)
  (epsilon-idle       params-epsilon-idle)
  (sigmoid-k          params-sigmoid-k)
  (sigmoid-x0         params-sigmoid-x0)
  (base-threshold     params-base-threshold)
  (threshold-cap      params-threshold-cap)
  (cosigners-required params-cosigners-required))

(define default-billings-params
  (make-billings-params 0.10 0.10 0.02 0.005   ; Δ_success Δ_fail δ_support ε_idle
                        10.0 0.5               ; sigmoid k, x0
                        0.4 0.95               ; threshold base, cap
                        3))                    ; retry cosigners

(define (clamp x lo hi)
  (cond ((< x lo) lo) ((> x hi) hi) (else x)))

(define (sigmoid v params)
  (let ((k  (params-sigmoid-k  params))
        (x0 (params-sigmoid-x0 params)))
    (/ 1.0 (+ 1.0 (exp (- (* k (- v x0))))))))

(define (apply-delta v delta params)
  "Apply DELTA (signed magnitude) shaped by sigmoid(v); clamp to [0,1]."
  (clamp (+ v (* delta (sigmoid v params))) 0.0 1.0))

(define (event-delta event params)
  (case event
    ((success) (params-delta-success params))
    ((fail)    (- (params-delta-fail params)))
    ((support) (params-delta-support params))
    ((idle)    (params-epsilon-idle  params))
    (else (error "billings: unknown event" event))))

(define (update-score v event params)
  "Return v' after applying EVENT under PARAMS."
  (apply-delta v (event-delta event params) params))

(define (arbitration-threshold views params)
  "Attention-scaled threshold; min(base · log(views+1), cap)."
  (min (* (params-base-threshold params)
          (log (+ views 1)))
       (params-threshold-cap params)))

(define (can-initiate? scores views params)
  "True iff combined SCORES clear the attention-scaled threshold."
  (>= (apply + scores)
      (arbitration-threshold views params)))

(define (round-threshold n)
  "Exponential escalation across engagement rounds (3^n)."
  (expt 3 n))
