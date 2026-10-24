;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-culcus.scm — Culcus / NAC scoring math unit tests
;;;
;;; Sources: docs/evr/NAC_sepv2.nlogo (authoritative equations)
;;; Run: guile --no-auto-compile -q -L module -L . \
;;;        -l docs/evr/algorithms/tests/test-culcus.scm

(use-modules (localchimera test harness)
             (docs evr algorithms culcus))

(define (~= a b) (< (abs (- a b)) 1e-9))
(define (~~ a b) (< (abs (- a b)) 1e-3))
(define P default-nac-params)

(display "\n── Culcus: host eligibility ──\n")
(check "culcus = 30 is eligible"      (host-eligible? 30 P))
(check "culcus = 29 is not eligible"  (not (host-eligible? 29 P)))
(check "culcus = 50 (initial) eligible" (host-eligible? 50 P))

(display "\n── Culcus: host reward ──\n")
(check "host-reward adds 1"         (= 51 (host-reward 50 P)))
(check "host-reward is +1 every time"
       (= 53 (host-reward (host-reward (host-reward 50 P) P) P)))

(display "\n── Culcus: join probability ──\n")
;; equal aptitude, equal rep ⇒ delta-weight=0 ⇒ join-prob = base-join (0.2)
(check "equal aptitude & rep ⇒ join-prob = 0.2"
       (~= 0.2 (join-probability 50 50 50 50 P)))
;; If host has strictly higher aptitude AND higher rep, prob > 0.2.
(check "higher host aptitude+rep raises join-prob"
       (> (join-probability 80 50 70 50 P) 0.2))
;; If host has lower aptitude (Δa = max(...,0)=0), prob = 0.2 regardless of rep.
(check "lower host aptitude ⇒ join-prob clamps at base"
       (~= 0.2 (join-probability 30 50 90 50 P)))
;; Numerical spot check: host-a=70, my-a=50, host-rep=60, mean=50.
;;   Δa = 20, delta-weight = 1 − 1/21 ≈ 0.95238
;;   rep-diff = 10, rep-weight = 1/(1+e^-1) ≈ 0.73106
;;   join-prob ≈ 0.2 + 0.69625 = 0.89625
(check "spot value (70,50,60,50) ≈ 0.89625"
       (~~ 0.89625 (join-probability 70 50 60 50 P)))
(check "join-prob ∈ [0.2, 1.2)" ; upper-bound is 0.2 + 1·1, asymptotic
       (let ((p (join-probability 1e6 0 1e6 0 P)))
         (and (>= p 0.2) (< p 1.2))))

(display "\n── Culcus: review-noise sampler hook ──\n")
;; Inject a deterministic identity sampler to verify the wiring.
(check "noise sampler called with (mean, σ)"
       (= 50
          (review-noise-sample 50
                               (lambda (μ σ) (+ μ (- σ σ))) ; ignores σ
                               P)))
(check "default σ is 10 from params"
       (review-noise-sample 0
                            (lambda (μ σ) (= σ 10.0))
                            P))

(display "\n── Culcus: perception EMA (α = 0.1) ──\n")
(check "EMA toward 100 from 50 yields 55"
       (~= 55.0 (update-reviewed-ema 50 100 P)))
(check "EMA fixed point at observed value"
       (~= 100.0 (update-reviewed-ema 100 100 P)))
(check "EMA convergence after many steps"
       (let loop ((v 50) (n 200))
         (if (zero? n)
             (~~ 100.0 v)
             (loop (update-reviewed-ema v 100 P) (- n 1)))))

(display "\n── Culcus: reputation update ──\n")
;; neutral d=50, target NOT host: Δrep = 0.2 + 0 = 0.2
(check "neutral non-host review ⇒ +participation-bump"
       (~= 50.2 (reputation-update 50 50 #f P)))
;; positive d=80, target NOT host: Δrep = 0.2 + (30/100)·1 = 0.5
(check "positive non-host review (d=80) ⇒ +0.5"
       (~= 50.5 (reputation-update 50 80 #f P)))
;; negative d=20, NOT host: Δrep = 0.2 + (-30/100)·1 = -0.1
(check "negative non-host review (d=20) ⇒ -0.1"
       (~= 49.9 (reputation-update 50 20 #f P)))
;; host with default host-review-weight=1.0 ⇒ same magnitude as non-host
(check "host vs non-host with weight=1.0 are equal at default"
       (~= (reputation-update 50 80 #t P)
           (reputation-update 50 80 #f P)))

(display "\n── Culcus: aptitude growth (mentorship) ──\n")
;; equal aptitude, Δ=0: gain = base-growth (0.2)
(check "equal aptitude ⇒ base growth 0.2"
       (~= 50.2 (aptitude-growth 50 50 P)))
;; Δ=20: gain = 0.2 + 20·0.1 = 2.2
(check "Δ=20 ⇒ +2.2"
       (~= 52.2 (aptitude-growth 50 70 P)))
;; Δ<0 saturates at base growth (no penalty for being above host)
(check "host below me ⇒ still get base 0.2"
       (~= 70.2 (aptitude-growth 70 50 P)))
;; Cap at 100
(check "growth caps at aptitude-cap (100)"
       (= 100 (aptitude-growth 99 200 P)))

(display "\n── Culcus: sigmoid sanity ──\n")
(check "sigmoid(0) = 0.5"  (~= 0.5 (sigmoid 0)))
(check "sigmoid monotone"  (< (sigmoid -1) (sigmoid 0) (sigmoid 1)))

(test-summary!)
