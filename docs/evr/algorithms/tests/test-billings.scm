;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-billings.scm — Billings score unit tests
;;;
;;; Source spec: docs/evr/billings-overview.md
;;; Run: guile --no-auto-compile -q -L module -L . \
;;;        -l docs/evr/algorithms/tests/test-billings.scm

(use-modules (localchimera test harness)
             (docs evr algorithms billings))

(define (~= a b) (< (abs (- a b)) 1e-9))
(define (~~ a b) (< (abs (- a b)) 1e-3))

(display "\n── Billings: sigmoid ──\n")
;; sigmoid(0.5) = 0.5 with x0=0.5; sigmoid is monotone increasing.
(check "sigmoid at midpoint = 0.5"
       (~= (sigmoid 0.5 default-billings-params) 0.5))
(check "sigmoid(1) > sigmoid(0)"
       (> (sigmoid 1.0 default-billings-params)
          (sigmoid 0.0 default-billings-params)))
(check "sigmoid(0) ≈ 0.0067 (k=10, x0=0.5)"
       (~~ (sigmoid 0.0 default-billings-params) 0.00669))
(check "sigmoid(1) ≈ 0.9933"
       (~~ (sigmoid 1.0 default-billings-params) 0.99331))

(display "\n── Billings: apply-delta clamping ──\n")
(check "clamp at upper bound"
       (= 1.0 (apply-delta 1.0 0.5 default-billings-params)))
(check "clamp at lower bound"
       (= 0.0 (apply-delta 0.0 -0.5 default-billings-params)))
(check "no movement on zero delta"
       (~= 0.5 (apply-delta 0.5 0.0 default-billings-params)))

(display "\n── Billings: event taxonomy ──\n")
(check "success raises score"
       (> (update-score 0.5 'success default-billings-params) 0.5))
(check "fail lowers score"
       (< (update-score 0.5 'fail default-billings-params) 0.5))
(check "support raises score (smaller than success)"
       (let ((s (update-score 0.5 'success default-billings-params))
             (q (update-score 0.5 'support default-billings-params)))
         (and (> q 0.5) (< q s))))
(check "idle raises score (smallest)"
       (let ((q (update-score 0.5 'support default-billings-params))
             (i (update-score 0.5 'idle    default-billings-params)))
         (and (> i 0.5) (< i q))))

(display "\n── Billings: arbitration threshold ──\n")
;; threshold(0) = 0.4·log(1) = 0
(check "zero views ⇒ zero threshold"
       (~= 0.0 (arbitration-threshold 0 default-billings-params)))
;; threshold(e-1) = 0.4 · 1 = 0.4 (the documented base)
(check "e−1 views ⇒ base threshold 0.4"
       (~~ 0.4 (arbitration-threshold (- (exp 1.0) 1.0)
                                      default-billings-params)))
(check "threshold capped at 0.95"
       (~= 0.95 (arbitration-threshold 1e9 default-billings-params)))
(check "threshold monotone in views"
       (< (arbitration-threshold 5  default-billings-params)
          (arbitration-threshold 50 default-billings-params)))

(display "\n── Billings: cosigning ──\n")
(check "single baseline cosigner clears low-attention dilemma"
       (can-initiate? '(0.5) 0 default-billings-params))
(check "single baseline cannot clear high attention"
       (not (can-initiate? '(0.5) 100 default-billings-params)))
(check "three baseline cosigners can pool past 0.95 cap"
       (can-initiate? '(0.5 0.5 0.5) 1e9 default-billings-params))

(display "\n── Billings: round threshold ──\n")
(check "round 1 = 3"   (= 3   (round-threshold 1)))
(check "round 2 = 9"   (= 9   (round-threshold 2)))
(check "round 3 = 27"  (= 27  (round-threshold 3)))
(check "exponential"   (= (round-threshold 5) (* 3 (round-threshold 4))))

(display "\n── Billings: invariants ──\n")
(check "score stays in [0,1] under any sequence"
       (let loop ((v 0.5) (n 200) (ok? #t))
         (if (zero? n) ok?
             (let* ((events '(success fail support idle))
                    (e (list-ref events (modulo n 4)))
                    (v* (update-score v e default-billings-params)))
               (loop v* (- n 1) (and ok? (<= 0 v* 1)))))))
(check "baseline score is 0.5"
       (~= 0.5 baseline-score))

(test-summary!)
