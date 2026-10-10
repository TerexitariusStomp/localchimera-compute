;;; test-rollover-pricing.scm — End-to-end rollover-premium pricing
;;;
;;; Exercises the six-piece MVP pipeline:
;;;   1. ACDC timestamp-range queries (series-for-schema, by-*-in-range)
;;;   2. ^index-oracle writes external-index-observation credentials
;;;   3. <covariance-view> + compute-correlation produce ρ(S, I)
;;;   4. DAF factor-as-expression reads ρ at rollover time
;;;   5. ^rollover-scheduler tick refreshes the extractable premium
;;;   6. compute-attributed-premium applies the bound:
;;;        P_extract ≈ ρ² · N(1-R) + B(1-R) − C
;;;
;;; Run:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/voice/test-rollover-pricing.scm

(use-modules (playnet test harness))
(use-modules (playnet algorithms correlation) (playnet ddmrp buffers) (playnet algorithms option-premium) (playnet algorithms rollover-scheduler) (playnet vf schemas) (playnet ddmrp records)
             (playnet credentials work) (playnet keri acdc) (playnet voice index-oracle) (playnet keri acdc) (playnet keri acdc-store)
             (goblins)
             (srfi srfi-1))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))

(define vat (spawn-vat))


;; ═════════════════════════════════════════════════════════════════════════
;; 1. Pure correlation primitives
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Pure Pearson correlation ──\n")

(check "pearson-rho identical series = 1"
       (approx= (pearson-rho '(1 2 3 4 5) '(1 2 3 4 5)) 1.0))

(check "pearson-rho scaled series = 1"
       (approx= (pearson-rho '(1 2 3 4 5) '(2 4 6 8 10)) 1.0))

(check "pearson-rho anti-correlated = -1"
       (approx= (pearson-rho '(1 2 3 4 5) '(5 4 3 2 1)) -1.0))

(check "pearson-rho zero-variance returns 0 (no division by zero)"
       (= (pearson-rho '(1 2 3) '(7 7 7)) 0))

(check "pearson-rho length mismatch returns 0"
       (= (pearson-rho '(1 2) '(1 2 3)) 0))

(check "pearson-rho empty returns 0"
       (= (pearson-rho '() '()) 0))


;; ═════════════════════════════════════════════════════════════════════════
;; 2. correlate-pairs with timestamp bucketing
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── correlate-pairs ──\n")

(define pairs-a '((1000 . 10) (2000 . 20) (3000 . 30) (4000 . 40)))
(define pairs-b '((1000 . 1)  (2000 . 2)  (3000 . 3)  (4000 . 4)))

(let ((r (correlate-pairs pairs-a pairs-b #:bucket-seconds 1000)))
  (check "perfectly aligned daily samples → ρ=1"
         (approx= (assq-ref r 'rho) 1.0))
  (check "4 aligned buckets"
         (= (assq-ref r 'n) 4))
  (check "sigma-a tracks the scale of A"
         (> (assq-ref r 'sigma-a) 0)))

;; Mismatched timestamps; only overlap buckets count.
(let ((r (correlate-pairs
           '((1000 . 1) (2000 . 2) (3000 . 3))
           '((2000 . 2) (3000 . 3) (4000 . 4))
           #:bucket-seconds 1000)))
  (check "non-overlapping tails dropped; 2 aligned buckets"
         (= (assq-ref r 'n) 2)))


;; ═════════════════════════════════════════════════════════════════════════
;; 3. ACDC timestamp-range queries + ^index-oracle
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── ^index-oracle + ACDC range queries ──\n")

(define acdc-store (with-vat vat (spawn-acdc-store)))
(define support-oracle
  (with-vat vat (spawn-index-oracle acdc-store "gov-aid" "support:plan-X")))
(define index-oracle
  (with-vat vat (spawn-index-oracle acdc-store "mkt-aid" "market:slabs-abx")))

;; Seed 10 daily samples starting at ts=1_700_000_000.
;; Support climbs linearly; the index tracks it with mild noise
;; (i.e. high but not perfect ρ).
;; t0 chosen so t0..t0+15d falls strictly inside the DAF valid window
;; declared below (2024-01-01 .. 2026-12-31). 1735689600 = 2025-01-01.
(define t0 1735689600)
(define seconds-per-day 86400)

(with-vat vat
  (let loop ((i 0))
    (when (< i 10)
      (let ((ts (+ t0 (* i seconds-per-day))))
        ($ support-oracle 'observe (+ 100 (* i 5)) ts)
        ($ index-oracle   'observe (+ 140 (* i 6) (- (modulo i 3) 1)) ts))
      (loop (+ i 1)))))

(check "series-for-schema returns 20 observations total"
       (= 20 (length (with-vat vat
                       ($ acdc-store 'series-for-schema
                          *schema-playnet-external-index-observation*)))))

(check "by-claim-in-range filters by index-uri AND timestamp"
       (= 5 (length (with-vat vat
                      ($ acdc-store 'by-claim-in-range
                         *schema-playnet-external-index-observation*
                         'index-uri "market:slabs-abx"
                         (+ t0 (* 5 seconds-per-day))
                         (+ t0 (* 9 seconds-per-day)))))))

(check "series is ascending by timestamp"
       (with-vat vat
         (let* ((s ($ support-oracle 'series))
                (tss (map cred-timestamp s)))
           (equal? tss (sort tss <)))))


;; ═════════════════════════════════════════════════════════════════════════
;; 4. <covariance-view> end-to-end
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── covariance-view over credential streams ──\n")

(define support-stream
  (credential-stream->pairs-fn support-oracle observation-value))
(define index-stream
  (credential-stream->pairs-fn index-oracle observation-value))

(define view
  (make-covariance-view 'plan-X-vs-abx
                        support-stream index-stream
                        seconds-per-day 'pearson))

(define corr (with-vat vat (compute-correlation view)))

(check "covariance-view produces ρ close to 1 (noisy tracker)"
       (> (assq-ref corr 'rho) 0.95))

(check "all 10 buckets aligned"
       (= 10 (assq-ref corr 'n)))

(check "σ_I (index stddev) is positive and nonzero"
       (> (assq-ref corr 'sigma-b) 0))


;; ═════════════════════════════════════════════════════════════════════════
;; 5. DAF factor-as-expression reading ρ
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── DAF with correlation-driven factor ──\n")

(define rho-driven-factor
  (lambda (as-of spec-id at-location)
    ;; The thunk is called from inside aggregate-adjustment-factors,
    ;; which is itself running inside a vat turn. Do NOT re-enter
    ;; (with-vat ...) here — nested turn entry on the same vat breaks
    ;; message delivery.
    (let* ((r (compute-correlation view #:to-ts as-of))
           (rho (assq-ref r 'rho)))
      ;; Multiplier: 1 + ρ²  (toy formula, exercises the contract)
      (+ 1.0 (* rho rho)))))

(define correlation-daf
  (make-demand-adjustment-factor
    "daf-rho" "spec-premium" #f 'demand 'red
    rho-driven-factor
    "2024-01-01T00:00:00Z" "2026-12-31T00:00:00Z"
    #f "correlation-driven" #t))

(define agg
  (with-vat vat
    (aggregate-adjustment-factors (list correlation-daf)
                                   (+ t0 (* 10 seconds-per-day))
                                   "spec-premium")))

(check "DAF with thunk factor evaluates close to 2 (1 + ρ² ≈ 1 + 1)"
       (approx= (assq-ref agg 'demand) 2.0 0.1))

;; Misbehaving factor-expression gets coerced to 1.0 — never derails ddmrp.
(define bad-daf
  (make-demand-adjustment-factor
    "daf-bad" "spec-premium" #f 'demand 'red
    (lambda (_a _s _l) (error "kaboom"))
    "2024-01-01T00:00:00Z" "2026-12-31T00:00:00Z"
    #f "misbehaving" #t))

(check "misbehaving factor-thunk coerces to 1.0"
       (approx= (assq-ref
                  (with-vat vat
                    (aggregate-adjustment-factors (list bad-daf)
                                                   (+ t0 (* 10 seconds-per-day))
                                                   "spec-premium"))
                  'demand)
                1.0))


;; ═════════════════════════════════════════════════════════════════════════
;; 6. Bound attributed premium
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── compute-attributed-premium (the bound) ──\n")

;; Doc example — private SLABS-style numbers:
;;   B = 130, N = 35, R = 0.25, C = 10
;;   ρ = 0.8 → P = 97.5 + 0.64·26.25 − 10 = 104.3

(let ((r (compute-attributed-premium #:B 130 #:N 35 #:R 0.25 #:C 10 #:rho 0.8)))
  (check "ρ=0.8 extractable ≈ 104.3"
         (approx= (assq-ref r 'extractable) 104.3 0.01))
  (check "bondholder-term = B(1-R) = 97.5"
         (approx= (assq-ref r 'bondholder-term) 97.5))
  (check "derivative-term = ρ²·N(1-R) = 16.8"
         (approx= (assq-ref r 'derivative-term) 16.8 0.01))
  (check "credible? #t when B(1-R) ≥ C"
         (eq? (assq-ref r 'credible?) #t))
  (check "attribution = ρ² = 0.64"
         (approx= (assq-ref r 'attribution) 0.64)))

(let ((r (compute-attributed-premium #:B 130 #:N 35 #:R 0.25 #:C 10 #:rho 0.1)))
  (check "ρ=0.1 derivative-term collapses (~0.26)"
         (approx= (assq-ref r 'derivative-term) 0.26 0.01))
  (check "ρ=0.1 extractable drops to ~87.76"
         (approx= (assq-ref r 'extractable) 87.76 0.01)))

(let ((r (compute-attributed-premium #:B 10 #:N 35 #:R 0.5 #:C 100 #:rho 0.9)))
  (check "non-credible (C > B(1-R)) zeros out extractable"
         (= (assq-ref r 'extractable) 0))
  (check "credible? is #f"
         (eq? (assq-ref r 'credible?) #f)))


;; ═════════════════════════════════════════════════════════════════════════
;; 7. compute-attributed-premium/live — ρ pulled from the view
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── compute-attributed-premium/live ──\n")

(define live-result
  (with-vat vat
    (compute-attributed-premium/live view
      #:B 130 #:N 35 #:R 0.25 #:C 10)))

(check "live premium returns rho"
       (> (assq-ref live-result 'rho) 0.95))

(check "live premium returns σ_I"
       (> (assq-ref live-result 'sigma-index) 0))

(check "live premium returns sample-size = 10"
       (= (assq-ref live-result 'sample-size) 10))

(check "live premium extractable close to the ρ=1 upper bound (~113)"
       (> (assq-ref live-result 'extractable) 110))


;; ═════════════════════════════════════════════════════════════════════════
;; 8. ^rollover-scheduler: tick-driven premium refresh
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── ^rollover-scheduler ──\n")

(define log-entries '())

(define scheduler
  (with-vat vat
    (spawn-rollover-scheduler view
      #:B 130 #:N 35 #:R 0.25 #:C 10
      #:on-tick (lambda (r as-of)
                  (set! log-entries
                        (cons (list as-of
                                    (assq-ref r 'rho)
                                    (assq-ref r 'extractable))
                              log-entries))))))

;; First tick on the initial well-correlated window.
(define tick1
  (with-vat vat ($ scheduler 'tick (+ t0 (* 10 seconds-per-day)))))

;; Now pump flat support (loses correlation) for 5 more days.
(with-vat vat
  (let loop ((i 10))
    (when (< i 15)
      (let ((ts (+ t0 (* i seconds-per-day))))
        ($ support-oracle 'observe 150 ts)           ; constant
        ($ index-oracle   'observe (+ 200 (* 3 i)) ts))  ; climbing
      (loop (+ i 1)))))

(define tick2
  (with-vat vat ($ scheduler 'tick (+ t0 (* 15 seconds-per-day)))))

(check "scheduler tick-count monotonic"
       (= 2 (with-vat vat ($ scheduler 'tick-count))))

(check "scheduler last-result set after tick"
       (not (eq? #f (with-vat vat ($ scheduler 'last-result)))))

(check "second tick has strictly lower ρ (support de-correlates from index)"
       (< (assq-ref tick2 'rho) (assq-ref tick1 'rho)))

(check "second tick has lower extractable premium"
       (< (assq-ref tick2 'extractable) (assq-ref tick1 'extractable)))

(check "on-tick callback fired twice"
       (= 2 (length log-entries)))

(check "scheduler.params reports captured bound inputs"
       (let ((p (with-vat vat ($ scheduler 'params))))
         (and (= 130 (assq-ref p 'B))
              (= 35  (assq-ref p 'N))
              (= 0.25 (assq-ref p 'R))
              (= 10  (assq-ref p 'C)))))


;; ═════════════════════════════════════════════════════════════════════════
;; 9. Credibility collapse at runtime (parameter stress)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n── Credibility stress ──\n")

(define non-credible-scheduler
  (with-vat vat
    (spawn-rollover-scheduler view
      #:B 5 #:N 35 #:R 0.5 #:C 100
      #:on-tick #f)))

(define stress-tick
  (with-vat vat
    ($ non-credible-scheduler 'tick (+ t0 (* 10 seconds-per-day)))))

(check "high ρ does not rescue a non-credible threat"
       (= 0 (assq-ref stress-tick 'extractable)))

(check "non-credible tick reports credible? = #f"
       (eq? (assq-ref stress-tick 'credible?) #f))


(display "\n")
(test-summary!)
