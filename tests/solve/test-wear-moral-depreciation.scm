;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-wear-moral-depreciation.scm — depreciation is a BLEND of repair and rebuild.
;;;
;;; Each use wears the oven, and that wear splits in two: a REPARABLE part, made
;;; good by repair (cheap), and an IRREPARABLE part, made good only by replacement
;;; (the build cost). Repair and rebuild are NOT substitutes for the same wear —
;;; there is no `min` between them; they cover DIFFERENT shares of it. So a
;;; product's per-use depreciation is a blend:
;;;
;;;     depreciation/use  =  δ_rep · (repair rate)  +  δ_irr · (build rate)
;;;
;;; Each condition component is its own stock good — `Cond_rep|oven` (produced by
;;; the repair recipe) and `Cond_str|oven` (produced only by the build recipe) —
;;; so the blend falls straight out of good-labour-content, each component summed
;;; like any consumed input. Within a component the cheapest method would win
;;; (moral depreciation, Capital I.15); between the two it is a blend, by the split.
;;;
;;; The all-REPARABLE limit (δ_irr=0) is the repair rate — repairs spreading the
;;; value over a longer life. The all-REBUILD limit (δ_rep=0) is classical
;;; depreciation at the build rate. The real case sits between, set by the split.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-wear-moral-depreciation.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve report)
             (localchimera solve compile))

;; bake wears the oven; condition has two components with their own suppliers:
;;   fix   : repair  =   5 Cond_rep for  1 h  → 0.2 h/unit   (the repair rate)
;;   build : rebuild = 100 Cond_str for 50 h  → 0.5 h/unit   (the build  rate)
(define rep-rate   0.2)
(define build-rate 0.5)

(define (oven drep dirr)
  (compile-recipe
    (list (rp "bake" "Bake") (rp "fix" "Repair") (rp "build" "Rebuild"))
    (list (out "b1" "bread" 1.0 "bake") (wrk "b2" 0.1 "bake")
          (in  "b3" "Cond_rep|oven" drep "bake")                              ; reparable wear
          (in  "b4" "Cond_str|oven" dirr "bake")                              ; irreparable wear
          (out "f1" "Cond_rep|oven" 5.0 "fix")   (wrk "f2" 1.0 "fix")          ; repair supplies reparable
          (out "g1" "Cond_str|oven" 100.0 "build") (wrk "g2" 50.0 "build"))))  ; build supplies structural

(define (bread-ell drep dirr)
  (declare-world! #:templates (oven drep dirr))
  (cdr (assoc "bread" (good-labour-content))))

;; total wear 0.5 per loaf, 80% reparable / 20% irreparable
(define blend     (bread-ell 0.4 0.1))   ; 0.1 + 0.4·0.2 + 0.1·0.5 = 0.23
(define all-rep   (bread-ell 0.5 0.0))   ; 0.1 + 0.5·0.2           = 0.20  (repairs spread the value)
(define all-build (bread-ell 0.0 0.5))   ; 0.1 + 0.5·0.5           = 0.35  (classical depreciation)

(format #t "~%── depreciation is a blend: δ_rep·repair + δ_irr·build ──~%")
(format #t "  all-reparable (δ_irr=0)   ℓ̂(bread) = ~,3f   (repair rate 0.2)~%" all-rep)
(format #t "  blend (0.4 rep / 0.1 irr) ℓ̂(bread) = ~,3f   (0.4·0.2 + 0.1·0.5)~%" blend)
(format #t "  all-rebuild (δ_rep=0)     ℓ̂(bread) = ~,3f   (build rate 0.5)~%" all-build)

(define (~= a b) (< (abs (- a b)) 1e-6))
(let* ((c1 (~= all-rep   (+ 0.1 (* 0.5 rep-rate))))                       ; 0.20
       (c2 (~= all-build (+ 0.1 (* 0.5 build-rate))))                     ; 0.35
       (c3 (~= blend     (+ 0.1 (* 0.4 rep-rate) (* 0.1 build-rate))))    ; 0.23 — the blend, exactly
       (c4 (and (< all-rep blend) (< blend all-build)))                   ; blend sits between the limits
       (ok (and c1 c2 c3 c4)))
  (format #t "~%  [~a] all-reparable limit = bake + wear×repair        = 0.200   (~,3f)~%" (if c1 "✓" "✗") all-rep)
  (format #t "  [~a] all-rebuild  limit = bake + wear×build         = 0.350   (~,3f)~%" (if c2 "✓" "✗") all-build)
  (format #t "  [~a] BLEND = bake + δ_rep×repair + δ_irr×build       = 0.230   (~,3f)~%" (if c3 "✓" "✗") blend)
  (format #t "  [~a] blend sits between the limits (~,3f < ~,3f < ~,3f)~%" (if c4 "✓" "✗") all-rep blend all-build)
  (format #t "~%  ~a the blend falls out of two condition goods — no `min` between repair and rebuild, no cap~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
