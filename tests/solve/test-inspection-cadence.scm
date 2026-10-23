;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-inspection-cadence.scm — inspection frequency of SPECIFICATION-CONFORMANCE,
;;; emergent from a convex trade-off (social-means §"Inspection", the a* formula).
;;;
;;; A conformance edge — a worker still holds "electrician", a convection-oven still
;;; bakes as an "oven", a batch still meets the food-spec — is a CLAIM THAT DRIFTS
;;; (skills atrophy, machines fall out of cal, stock spoils) at rate κ. Re-verifying
;;; it is labour ℓ. Skip the check a fraction of the time and the expected MISS falls
;;; convexly, g(a) = e^{−κa}; a miss on an edge the plan LEANS ON costs D = φ·H (the
;;; harm × horizon = the edge's reliance, its shadow price in the plan). The plan
;;; picks the inspection intensity a ∈ [0,1] that minimises
;;;
;;;     J(a) = ℓ·a  +  D·e^{−κa}          (check cost  +  expected miss-harm)
;;;
;;; whose optimum is  a* = (1/κ)·ln(κ·D/ℓ), clamped to [0,1]  (social-means §1091).
;;; We prove this EMERGES (a numerical minimiser is the independent oracle — no
;;; plugging the formula into itself), then read off what it MEANS:
;;;   • inspect what you lean on — a* rises with reliance D (the dual);
;;;   • below a reliance floor (D ≤ ℓ/κ) you don't inspect at all;
;;;   • SUBSTITUTION relaxes inspection — redundancy splits the reliance, so a
;;;     well-substituted conformance is checked less (ties to effective-skills);
;;;   • under a shared inspection BUDGET the plan water-fills onto the load-bearing
;;;     conformances and drops the marginal ones — the heterogeneous allocation a
;;;     flat a* can't give.
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-inspection-cadence.scm

(use-modules (srfi srfi-1) (ice-9 format))

(define (clamp x lo hi) (max lo (min hi x)))
(define (miss a kappa) (exp (- (* kappa a))))
(define (J a ell kappa D) (+ (* ell a) (* D (miss a kappa))))   ; check cost + expected miss-harm

;; the closed form under test (social-means §1091), with a shared shadow-price λ on
;; inspection labour (λ = 1 = unconstrained; λ > 1 = a binding inspection budget).
(define (a-star D ell kappa lambda)
  (clamp (* (/ 1.0 kappa) (log (/ (* kappa D) (* lambda ell)))) 0.0 1.0))

;; INDEPENDENT oracle: minimise J over [0,1] on a fine grid (J is convex in a).
(define (argmin-J ell kappa D)
  (let loop ((i 0) (best 0.0) (bestv +inf.0))
    (if (> i 100000)
        best
        (let* ((a (/ i 100000.0)) (v (J a ell kappa D)))
          (if (< v bestv) (loop (+ i 1) a v) (loop (+ i 1) best bestv))))))

(define (≈ a b tol) (< (abs (- a b)) tol))

(format #t "~%── inspection cadence a* emerges from the check-cost vs miss-harm trade-off ──~%")

;; ── (1) the emergent argmin matches the closed form a*, and it CLAMPS ──
(define cases   ; (kappa D ell)
  '((1.0  2.7   1.0)     ; interior
    (0.5  8.0   1.0)     ; slower drift, high reliance
    (2.0  3.0   0.5)     ; fast drift, cheap check
    (1.0  1.0   1.0)     ; D = ℓ/κ exactly → a* = 0 (miss-harm never beats the check)
    (1.0  100.0 1.0)))   ; overwhelming reliance → a* clamps to 1
(define c1
  (every (lambda (c)
           (let* ((k (car c)) (D (cadr c)) (l (caddr c))
                  (emp (argmin-J l k D)) (frm (a-star D l k 1.0)))
             (format #t "  κ=~4,2f D=~6,2f ℓ=~4,2f  →  argmin ~5,3f   a* ~5,3f~%" k D l emp frm)
             (≈ emp frm 2.0e-3)))
         cases))
(format #t "  [~a] the emergent inspection intensity matches a* (clamped) at every point~%"
        (if c1 "✓" "✗"))

;; ── (2) inspect what you lean on — a* rises with reliance D; floor below D = ℓ/κ ──
(define ell 1.0) (define kappa 1.0)                  ; floor at D = ℓ/κ = 1.0
(define reliances '(0.5 1.0 2.0 4.0 8.0))
(define as (map (lambda (D) (a-star D ell kappa 1.0)) reliances))
(format #t "~%  reliance D   ~a~%" (string-join (map (lambda (D) (format #f "~5,1f" D)) reliances) "  "))
(format #t "  a*(D)        ~a~%" (string-join (map (lambda (a) (format #f "~5,3f" a)) as) "  "))
(define c2a (equal? as (sort as <)))                            ; monotonically rising in reliance
(define c2b (and (= (car as) 0.0) (= (cadr as) 0.0)))           ; D ≤ ℓ/κ ⇒ don't inspect
(define c2c (> (car (reverse as)) (car as)))                    ; you DO inspect the load-bearing edge
(format #t "  [~a] a* rises with reliance (inspect what you lean on)~%" (if c2a "✓" "✗"))
(format #t "  [~a] below the reliance floor D ≤ ℓ/κ, a* = 0 (a barely-used claim isn't worth checking)~%" (if c2b "✓" "✗"))

;; ── (3) SUBSTITUTION relaxes inspection — redundancy splits the reliance ──
;; A demand D leans on ONE sole-source conformance ⇒ reliance D. Give it a live
;; substitute (effective-skills: two edges satisfy the spec) and the plan can route
;; to either, so each carries HALF the reliance ⇒ each is inspected less.
(define D-sole 2.5)                                  ; interior (a* < 1) so the redundancy effect is visible, not hidden above the clamp
(define a-sole (a-star D-sole ell kappa 1.0))
(define a-redundant (a-star (/ D-sole 2.0) ell kappa 1.0))
(format #t "~%  sole-source edge   (reliance ~,1f): a* = ~,3f~%" D-sole a-sole)
(format #t "  with a substitute  (reliance ~,1f each): a* = ~,3f~%" (/ D-sole 2.0) a-redundant)
(define c3 (< a-redundant a-sole))
(format #t "  [~a] a well-SUBSTITUTED conformance is inspected less — redundancy and inspection co-determine~%"
        (if c3 "✓" "✗"))

;; ── (4) a shared inspection BUDGET → water-fill onto the load-bearing edges ──
;; N conformance edges, reliances D_i, one labour budget B. Minimise Σ D_i e^{−κa_i}
;; s.t. Σ ℓ a_i ≤ B. KKT: κ D_i e^{−κ a_i} = λ ℓ interior ⇒ a_i = a-star(D_i,ℓ,κ,λ),
;; λ set so the budget binds. Bisect λ (Σℓa_i is monotone decreasing in λ).
(define edges '(9.0 4.0 2.0 0.6))                    ; four conformances the plan relies on, unequally
(define (spend lam) (fold + 0.0 (map (lambda (D) (* ell (a-star D ell kappa lam))) edges)))
(define B 1.5)                                        ; tight: less than the unconstrained Σ
(define lam*
  (let bisect ((lo 1.0) (hi 1.0e6) (i 0))             ; λ ≥ 1; grows until the budget binds
    (if (> i 200) (/ (+ lo hi) 2.0)
        (let* ((mid (/ (+ lo hi) 2.0)) (s (spend mid)))
          (cond ((< (abs (- s B)) 1.0e-6) mid)
                ((> s B) (bisect mid hi (+ i 1)))     ; overspending ⇒ raise the price λ
                (else    (bisect lo mid (+ i 1))))))))
(define alloc (map (lambda (D) (a-star D ell kappa lam*)) edges))
(define unconstrained (map (lambda (D) (a-star D ell kappa 1.0)) edges))
(format #t "~%  edge reliance D        ~a~%" (string-join (map (lambda (D) (format #f "~5,1f" D)) edges) "  "))
(format #t "  a* unconstrained       ~a   (Σℓa = ~,2f)~%"
        (string-join (map (lambda (a) (format #f "~5,3f" a)) unconstrained) "  ") (spend 1.0))
(format #t "  a* under budget B=~,1f   ~a   (Σℓa = ~,2f)~%" B
        (string-join (map (lambda (a) (format #f "~5,3f" a)) alloc) "  ") (spend lam*))
(define c4a (≈ (spend lam*) B 1.0e-3))                          ; the budget binds
(define c4b (equal? alloc (reverse (sort alloc <))))           ; allocation ordered by reliance (high→low)
(define c4c (and (> (car alloc) 0.0) (= (car (reverse alloc)) 0.0)))  ; load-bearing kept, marginal dropped
(format #t "  [~a] the budget binds (Σℓa = B)~%" (if c4a "✓" "✗"))
(format #t "  [~a] inspection concentrates on the load-bearing conformances; the marginal one is dropped~%"
        (if c4c "✓" "✗"))

(define ok (and c1 c2a c2b c2c c3 c4a c4b c4c))
(format #t "~%  ~a inspection frequency of conformance is a convex trade-off: a* emerges, scales with reliance,~%" (if ok "✓" "✗"))
(format #t "    relaxes under substitution, and water-fills a shared budget onto what the plan leans on~%~%")
(exit (if ok 0 1))
