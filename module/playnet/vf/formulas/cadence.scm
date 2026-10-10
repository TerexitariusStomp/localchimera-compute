;;; cadence.scm — how often to check a thing that is relied on: the continuous
;;; intensity a*, the discrete interval T*, and the recert schedule a plan's loads give.
;;;
;;; The discrete interval first; the continuous model and the schedule follow it.
;;;
;; DISCRETE cadence (Slice 3).  The continuous a* prices inspection as a linear cost
;; ℓ·a with no reason to batch.  But a real recert is a lumpy EVENT costing a fixed
;; FIXED-COST K — convening the auditor, the exam apparatus, the travel — overhead
;; independent of thoroughness.  With K, batching into periodic events is optimal, and
;; the average cost rate  K/T + D·[1 − (1−e^{−κT})/(κT)]  (a check every T periods; the
;; miss accrues between checks as the freshness decays at κ) is minimized at the
;; renewal / age-replacement (EOQ-form) interval
;;     T* = sqrt(2·K / (D·κ))          (small-κT: the miss accrues ~linearly)
;; — inspect every T* periods.  Unlike 1/a* it carries a NEW comparative static: T*
;; RISES with the fixed cost K (a dear audit is run less often but fully), and falls
;; with reliance D and with drift κ.  This is the "inspect every T* periods" reading —
;; a genuine periodic schedule, not the continuous fraction reinterpreted.

(define-module (playnet vf formulas cadence)
  #:export (recert-interval-discrete inspection-intensity edge-reliance reliance->valid-until conformance-recert-schedule))

(define* (recert-interval-discrete reliance kappa fixed-cost)
  "The DISCRETE recert interval T* = sqrt(2·K/(D·κ)) — inspect every T* periods when a
   check is a lumpy event costing FIXED-COST K.  RELIANCE = D = φH (the edge load,
   post-harm).  #f when there is nothing to check (reliance/κ/K ≤ 0)."
  (and (> reliance 0.0) (> kappa 0.0) (> fixed-cost 0.0)
       (sqrt (/ (* 2.0 fixed-cost) (* reliance kappa)))))

;; ── Close the credential loop: the plan's reliance sets the recert cadence ──────
;; The exact mirror of `custody-cred-live?` (facts/validity).  That predicate READS a conformance
;; credential's `valid-until` to gate the edge's liveness in the solve; these DERIVE
;; that `valid-until` from how hard the plan leans on the edge — so the loop closes:
;; the plan's own reliance stamps the expiry the same predicate then enforces.
;;
;; `a*` (social-means §1091) is the emergent per-period inspection INTENSITY; its
;; reciprocal is the recert INTERVAL (inspect every 1/a* periods).  A heavily-relied
;; edge (high reliance D) ⇒ high a* ⇒ short interval; below the reliance floor
;; D ≤ λℓ/κ, a* = 0 and the credential is OPEN (no `valid-until`) — a barely-used claim
;; is never worth recertifying.  This is the SAME closed form the independent argmin
;; oracle in test-inspection-cadence.scm checks; λ ≥ 1 is the shared-inspection-budget
;; shadow price (1 = unconstrained, > 1 = a binding inspection budget, from the KKT
;; water-fill).  Pure over reals and plain alists — record-free, like its neighbours.
(define* (inspection-intensity reliance ell kappa #:optional (lam 1.0))
  "a* = clamp((1/κ)·ln(κ·D / (λ·ℓ)), 0, 1): the emergent per-period inspection
   intensity for an edge relied on by RELIANCE (its dual), drifting at KAPPA, checked
   at labour cost ELL, under inspection-budget shadow price LAM."
  (if (or (<= reliance 0.0) (<= ell 0.0) (<= kappa 0.0) (<= lam 0.0)) 0.0
      (max 0.0 (min 1.0 (* (/ 1.0 kappa) (log (/ (* kappa reliance) (* lam ell))))))))

(define* (edge-reliance throughput #:optional (harm 1.0))
  "The reliance the plan puts on a conformance edge = the THROUGHPUT it routes through
   it, valued at the per-miss HARM — the `D = φH` of a* (social-means §1091: the harm
   × horizon, \"a miss on an edge the plan leans on\").  Read OFF the solve (the edge's
   load in the optimal x), so it is endogenous: it rises as production leans harder and
   FALLS when a substitute carries part of the load — the effective-skills closure
   splitting the reliance (the P4 co-determination, now feeding the credential).

   Why the throughput and not the confidence barrier's slack-dual w/s: the inspection
   first-order condition pins that slack at s ≈ wρ/(κℓ), nearly INDEPENDENT of how hard
   the plan leans — because inspection can always buy more freshness, so the barrier's
   marginal value settles at the check cost ℓ, not the reliance.  The load the plan
   actually routes through the edge is what a silent miss would cost, so it is the
   reliance the recert cadence must track."
  (* harm (max 0.0 throughput)))

(define* (reliance->valid-until reliance ell kappa now period-span #:optional (lam 1.0))
  "Derive a conformance credential's `valid-until` from the plan's reliance on its
   edge: NOW + (1/a*)·PERIOD-SPAN seconds — the recert interval — or #f (an OPEN
   credential, never recertify) when reliance is below the floor (a* = 0).  NOW,
   PERIOD-SPAN and the result are epoch seconds."
  (let ((a* (inspection-intensity reliance ell kappa lam)))
    (and (> a* 0.0) (+ now (* (/ 1.0 a*) period-span)))))

(define* (conformance-recert-schedule loads #:key (now 0) (period-span 604800.0)
                                            (ell 1.0) (kappa 1.0) (lam 1.0) (harm 1.0)
                                            (mode 'continuous) (fixed-cost 1.0))
  "Derive a recert `valid-until` per conformance edge from the LOADS the plan routes
   through them — LOADS = ((edge . hours) …), read off a live solve (each edge's
   scheduled throughput).  For each: reliance = edge-reliance(hours, harm), then the
   interval by MODE — 'continuous ⇒ reliance->valid-until (1/a*, OPEN below the floor);
   'discrete ⇒ recert-interval-discrete (T* = sqrt(2·FIXED-COST/(D·κ)), a periodic
   event).  Returns ((edge . valid-until) …) preserving order; a marginal edge carries
   #f (continuous) or a very long interval (discrete).  PERIOD-SPAN is the seconds a
   plan-period spans; ELL/KAPPA/LAM/HARM/FIXED-COST are the governed inspection dials
   (HARM defaults to 1; a caller passes the conformance profile's steepness)."
  (map (lambda (kv)
         (let ((D (edge-reliance (cdr kv) harm)))
           (cons (car kv)
                 (case mode
                   ((discrete)
                    (let ((T (recert-interval-discrete D kappa fixed-cost)))
                      (and T (+ now (* T period-span)))))
                   (else
                    (reliance->valid-until D ell kappa now period-span lam))))))
       loads))
