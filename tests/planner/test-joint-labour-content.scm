;;; test-joint-labour-content.scm — the engine's value rollup under JOINT PRODUCTION.
;;;
;;; A recipe that yields wool AND mutton has ONE labour cost. `good-labour-content`
;;; splits that gross effort across the co-products by RELATIVE STANDALONE SNLT —
;;; each output's share ∝ qty × what a single-output recipe would charge for it —
;;; and a co-product with no standalone recipe takes the mean anchor. The split
;;; conserves the joint total, so nothing rides free and nothing is counted twice.
;;; This is the policy the credit pool prices claims by (algorithms/rollup.scm);
;;; the engine's reported ℓ̂ and a claim's price are therefore one number.
;;;
;;; Run:  guile -L module tests/planner/test-joint-labour-content.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile))

(define (world procs flows)
  (declare-world! #:places '(("town" 0.0 0.0))
                  #:templates (compile-recipe procs flows))
  (good-labour-content))

(define (ell content spec) (cdr (or (assoc spec content) (cons spec #f))))
(define (close? a b) (< (abs (- a b)) 1e-9))

;; A. anchored on both sides: shear (1.5 h → wool 1, mutton 2), wool alone 2 h/unit, mutton alone 0.5 h/unit
(define A (world (list (rp "shear" "Shear") (rp "wa" "Wool alone") (rp "ma" "Mutton alone"))
                 (list (wrk "s0" 1.5 "shear") (out "s1" "wool" 1.0 "shear") (out "s2" "mutton" 2.0 "shear")
                       (wrk "w0" 2.0 "wa") (out "w1" "wool" 1.0 "wa")
                       (wrk "m0" 1.0 "ma") (out "m1" "mutton" 2.0 "ma"))))
;; weights wool 1×2 = 2, mutton 2×0.5 = 1 ⇒ wool gets 1.0 h (1.0/unit), mutton 0.5 h (0.25/unit)
(define a-wool (ell A "wool")) (define a-mutton (ell A "mutton"))

;; B. mutton has no standalone recipe: it takes wool's anchor, no longer riding free
(define B (world (list (rp "shear" "Shear") (rp "wa" "Wool alone"))
                 (list (wrk "s0" 1.5 "shear") (out "s1" "wool" 1.0 "shear") (out "s2" "mutton" 2.0 "shear")
                       (wrk "w0" 2.0 "wa") (out "w1" "wool" 1.0 "wa"))))
;; weights wool 1×2 = 2, mutton 2×2 = 4 ⇒ wool 0.5 h (0.5/unit), mutton 1.0 h (0.5/unit)
(define b-wool (ell B "wool")) (define b-mutton (ell B "mutton"))

;; C. sole output, self-consumed seed: sow 9 h → grain 10, eats grain 1. The seed is charged as an
;;    input and the charge spread over the GROSS 10 (Leontief): ℓ = (9 + ℓ)/10 ⇒ 1.0/unit;
;;    and the joint price flows downstream: felt = 1 h + 2 × wool
(define C (world (list (rp "sow" "Sow") (rp "shear" "Shear") (rp "wa" "Wool alone") (rp "ma" "Mutton alone") (rp "felt" "Felt"))
                 (list (wrk "g0" 9.0 "sow") (out "g1" "grain" 10.0 "sow") (in "g2" "grain" 1.0 "sow")
                       (wrk "s0" 1.5 "shear") (out "s1" "wool" 1.0 "shear") (out "s2" "mutton" 2.0 "shear")
                       (wrk "w0" 2.0 "wa") (out "w1" "wool" 1.0 "wa")
                       (wrk "m0" 1.0 "ma") (out "m1" "mutton" 2.0 "ma")
                       (wrk "f0" 1.0 "felt") (in "f1" "wool" 2.0 "felt") (out "f2" "felt" 1.0 "felt"))))
(define c-grain (ell C "grain")) (define c-felt (ell C "felt"))

(format #t "~%── joint production in the value rollup ──~%")
(format #t "  A anchored:   wool ~,3f  mutton ~,3f   (Σ = ~,3f of 1.5 h)~%" a-wool a-mutton (+ a-wool (* 2 a-mutton)))
(format #t "  B unanchored: wool ~,3f  mutton ~,3f   (Σ = ~,3f of 1.5 h)~%" b-wool b-mutton (+ b-wool (* 2 b-mutton)))
(format #t "  C net seed:   grain ~,3f ; felt ~,3f~%" c-grain c-felt)

(let* ((c1 (and (close? a-wool 1.0) (close? a-mutton 0.25)))
       (c2 (close? (+ a-wool (* 2 a-mutton)) 1.5))
       (c3 (and (close? b-wool 0.5) (close? b-mutton 0.5)))
       (c4 (close? (+ b-wool (* 2 b-mutton)) 1.5))
       (c5 (< (abs (- c-grain 1.0)) 1e-4))   ; a self-loop converges geometrically (×0.1 a pass) under the pass cap
       (c6 (close? c-felt 3.0))
       (ok (and c1 c2 c3 c4 c5 c6)))
  (format #t "~%  [~a] anchored split ∝ qty × standalone SNLT (wool 1.0, mutton 0.25)~%" (if c1 "✓" "✗"))
  (format #t "  [~a] the split conserves the joint total (Σ = 1.5)~%" (if c2 "✓" "✗"))
  (format #t "  [~a] a co-product with no standalone recipe takes the mean anchor (0.5 / 0.5)~%" (if c3 "✓" "✗"))
  (format #t "  [~a] … and still conserves the total~%" (if c4 "✓" "✗"))
  (format #t "  [~a] a sole output keeps the Leontief charge over its gross quantity (seed grain 1.0)~%" (if c5 "✓" "✗"))
  (format #t "  [~a] the joint price rides downstream (felt = 1 + 2·wool = 3.0)~%" (if c6 "✓" "✗"))
  (format #t "~%~a~%" (if ok "PASS" "FAIL"))
  (exit (if ok 0 1)))
