;;; test-recert-discrete.scm — the DISCRETE recert interval (Slice 3).
;;;
;;; The continuous a* prices inspection as a linear cost ℓ·a, so there is no reason to
;;; batch and the "interval" is just 1/a*.  But a real recert is a lumpy EVENT costing a
;;; fixed K (convening the auditor, the exam apparatus, the travel — overhead
;;; independent of thoroughness).  With K, batching into periodic checks is optimal: the
;;; claim is verified, drifts at κ, and is re-verified every T periods, the miss
;;; accruing between checks.  The average cost rate over a cycle,
;;;
;;;     C(T) = K/T  +  D·[1 − (1−e^{−κT})/(κT)]        (fixed check + accrued miss)
;;;
;;; is minimised at the renewal / age-replacement (EOQ-form) interval
;;;
;;;     T* = sqrt(2·K / (D·κ))     (small-κT: the miss accrues ~linearly)  — inspect every T*.
;;;
;;; We prove T* is a genuine minimiser (an independent numerical argmin is the oracle —
;;; the closed form is never plugged into itself), then read off what it MEANS: unlike
;;; 1/a* it RISES with the fixed cost K (a dear audit is run less often but fully), and
;;; falls with reliance D and drift κ — the new comparative static the continuous model
;;; cannot express.
;;;
;;; Run:  guile -L module/playnet/planner tests/planner/test-recert-discrete.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner formulas cadence))

;; exact average cost rate of a check every T periods.
(define (cost-rate T D kappa K)
  (+ (/ K T) (* D (- 1.0 (/ (- 1.0 (exp (- (* kappa T)))) (* kappa T))))))
;; INDEPENDENT oracle: minimise C(T) over a fine grid of T ∈ (0, 20].
(define (argmin-T D kappa K)
  (let loop ((i 1) (best 1.0e-4) (bestv +inf.0))
    (if (> i 200000) best
        (let* ((T (* i 1.0e-4)) (v (cost-rate T D kappa K)))
          (if (< v bestv) (loop (+ i 1) T v) (loop (+ i 1) best bestv))))))
(define (rel a b) (/ (abs (- a b)) (+ 1.0e-9 (abs b))))
(define (rising? xs)  (equal? xs (sort xs <)))
(define (falling? xs) (equal? xs (sort xs >)))

(format #t "~%── the discrete recert interval T* = sqrt(2K/(Dκ)) emerges from a renewal trade-off ──~%")

;; S1 — T* matches the independent argmin in the small-κT regime where the leading-order
;; (linear-miss) form holds. It is a LOWER bound that tightens as κT → 0: the true miss
;; accrues sub-linearly, so the exact optimum sits just above sqrt(2K/(Dκ)).
(define cases '((10.0 0.05 1.0) (20.0 0.05 1.0) (10.0 0.02 1.0) (40.0 0.05 1.0)))  ; (D κ K), κT* ≲ 0.1
(define s1
  (every (lambda (c)
           (let* ((D (car c)) (k (cadr c)) (K (caddr c))
                  (frm (recert-interval-discrete D k K)) (emp (argmin-T D k K)))
             (format #t "  D=~5,1f κ=~5,3f K=~4,1f  →  T* ~6,3f   argmin ~6,3f   (κT*=~4,2f)~%"
                     D k K frm emp (* k frm))
             (and (< (rel frm emp) 0.05) (<= frm emp))))   ; within 5% AND a lower bound (tightens as κT→0)
         cases))
(format #t "  [~a] S1 T*=sqrt(2K/(Dκ)) matches the numerical argmin in the small-κT regime (a tight lower bound)~%" (if s1 "✓" "✗"))

;; S2 — the NEW static: T* RISES with the fixed audit cost K (the continuous 1/a* can't see K).
(define s2 (map (lambda (K) (argmin-T 10.0 0.1 K)) '(1.0 2.0 4.0)))
(format #t "~%  fixed cost K = 1 2 4  →  T* = ~a~%" (map (lambda (t)(format #f "~,2f" t)) s2))
(define c2 (rising? s2))
(format #t "  [~a] S2 a dearer audit is run LESS often but fully (T* rises with K) — new vs continuous~%" (if c2 "✓" "✗"))

;; S3 — falls with reliance D (inspect what you lean on, more often).
(define s3 (map (lambda (D) (argmin-T D 0.1 1.0)) '(5.0 10.0 20.0)))
(format #t "  reliance D = 5 10 20  →  T* = ~a~%" (map (lambda (t)(format #f "~,2f" t)) s3))
(define c3 (falling? s3))
(format #t "  [~a] S3 heavier reliance ⇒ shorter interval (recert the load-bearing edge more often)~%" (if c3 "✓" "✗"))

;; S4 — falls with drift κ (a fast-drifting conformance is checked more often).
(define s4 (map (lambda (k) (argmin-T 10.0 k 1.0)) '(0.05 0.10 0.20)))
(format #t "  drift κ = .05 .10 .20  →  T* = ~a~%" (map (lambda (t)(format #f "~,2f" t)) s4))
(define c4 (falling? s4))
(format #t "  [~a] S4 faster drift ⇒ shorter interval~%" (if c4 "✓" "✗"))

;; S5 — the discrete interval is a genuinely distinct object from the continuous 1/a*:
;; it carries the fixed cost K, which the continuous form has no argument for at all
;; (inspection-intensity takes only D, ℓ, κ). Raising K stretches the discrete interval.
(define d-lo (recert-interval-discrete 10.0 0.1 1.0))
(define d-hi (recert-interval-discrete 10.0 0.1 4.0))
(format #t "~%  same D=10, κ=.1:  discrete T*(K=1)=~,2f   T*(K=4)=~,2f  (continuous 1/a* has no K argument)~%"
        d-lo d-hi)
(define c5 (> d-hi d-lo))
(format #t "  [~a] S5 discrete T* moves with the audit's fixed cost K — the static the continuous form omits~%" (if c5 "✓" "✗"))

(define ok (and s1 c2 c3 c4 c5))
(format #t "~%  ~a the 'inspect every T* periods' schedule: a renewal interval sqrt(2K/(Dκ)), rising with the~%" (if ok "✓" "✗"))
(format #t "    audit's fixed cost, falling with reliance and drift — the discrete reading of first-class inspection~%~%")
(exit (if ok 0 1))
