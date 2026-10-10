;;; test-robust-multiscenario.scm — diversity is a DERIVED result of robust planning.
;;;
;;; Claim (docs/planning/solve/robust-multiscenario.md): the planner needs NO new solver
;;; machinery to plan under uncertainty. A two-stage stochastic program is just a
;;; different assembly of the SAME forms — scenario-replicated recourse columns,
;;; first-stage columns SHARED across scenarios (non-anticipativity = free), a
;;; reproduction `bar` floor present once per scenario (robust), and desires
;;; p-weighted (expected). We prove it end-to-end on the real solver.
;;;
;;; The world: one unit of land, two crops.
;;;   • A (HYV):         yield 4.0 in a normal year, 0.0 in a drought (collapses).
;;;   • B (traditional): yield 1.3 normal, 1.2 drought (robust).
;;;   Scenarios: normal p=0.7, drought p=0.3.  Reproduction floor F = 1.0.
;;;
;;; Two solves, sharing the first-stage land columns:
;;;   1. DETERMINISTIC — the naive planner replaces the random yield with its MEAN
;;;      (certainty-equivalent) and solves ONE world. Mean yield A=2.8 > B=1.27, so
;;;      it plants ≈ all A — a monoculture. Evaluated against the drought it never
;;;      modelled, its food → 0: starvation.
;;;   2. ROBUST — both scenarios, with the floor `food_s ≥ F` in EACH. The drought
;;;      floor 1.2·x_B ≥ 1 forces x_B ≳ 0.83: diversification, floor met in BOTH.
;;;
;;; Diversity is not assumed — it FALLS OUT of defending the reproduction floor
;;; under uncertainty (the dual on the drought floor prices the resilience of B).
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-robust-multiscenario.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve solver))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (solve-x forms x0)
  (call-with-values (lambda () (solve-native forms '() x0)) (lambda (x . _) x)))

;; ── world data ───────────────────────────────────────────────────────────────
(define yA-normal 4.0) (define yA-drought 0.0)
(define yB-normal 1.3) (define yB-drought 1.2)
(define p-normal 0.7)  (define p-drought 0.3)
(define F 1.0)         ; reproduction floor (subsistence) — must hold
(define D 4.0)         ; desire target (want as much food as possible)
(define W 1000.0)      ; desire weight

;; shared FIRST-STAGE columns: 0 = x_A (land to A), 1 = x_B (land to B)
(define land-cap (mk-bar 1.0 '((0 . -1.0) (1 . -1.0))))   ; x_A + x_B ≤ 1
(define xA>=0    (mk-bar 0.0 '((0 .  1.0))))
(define xB>=0    (mk-bar 0.0 '((1 .  1.0))))
(define first-stage (list land-cap xA>=0 xB>=0))

;; ═══════════════════════════════════════════════════════════════════════════
;; 1. DETERMINISTIC — certainty-equivalent (mean yields), ONE world.
;;    vars: 0 x_A, 1 x_B, 2 food_mean
;; ═══════════════════════════════════════════════════════════════════════════
(define yA-mean (+ (* p-normal yA-normal) (* p-drought yA-drought)))   ; 2.8
(define yB-mean (+ (* p-normal yB-normal) (* p-drought yB-drought)))   ; 1.27
(define det-forms
  (append first-stage
          (list (mk-bar 0.0 (list (cons 0 yA-mean) (cons 1 yB-mean) (cons 2 -1.0))) ; food_mean ≤ mean production
                (mk-bar 0.0 '((2 . 1.0)))                                           ; food_mean ≥ 0
                (mk-des (mk-bar 0.0 '((2 . 1.0))) D W))))                            ; want more food
(define xd (solve-x det-forms (vector 0.3 0.3 0.5)))
(define det-xA (vector-ref xd 0)) (define det-xB (vector-ref xd 1))
;; evaluate the deterministic plan against the DROUGHT it never modelled:
(define det-drought-food (+ (* yA-drought det-xA) (* yB-drought det-xB)))

(format #t "~%DETERMINISTIC (mean-yield) plan:  x_A=~,3f  x_B=~,3f~%" det-xA det-xB)
(format #t "  → drought food = ~,3f   (floor F=~,1f)  ~a~%"
        det-drought-food F (if (< det-drought-food F) "*** STARVES ***" "ok"))

;; ═══════════════════════════════════════════════════════════════════════════
;; 2. ROBUST — two scenarios, first-stage columns SHARED, floor in EACH.
;;    vars: 0 x_A, 1 x_B, 2 food_normal, 3 food_drought
;; ═══════════════════════════════════════════════════════════════════════════
(define (scenario-forms food-idx yA yB prob)
  (list (mk-bar 0.0 (list (cons 0 yA) (cons 1 yB) (cons food-idx -1.0)))  ; food_s ≤ production_s
        (mk-bar 0.0 (list (cons food-idx 1.0)))                          ; food_s ≥ 0
        (mk-bar (- F) (list (cons food-idx 1.0)))                        ; ROBUST FLOOR: food_s ≥ F
        (mk-des (mk-bar 0.0 (list (cons food-idx 1.0))) D (* prob W))))  ; p-weighted desire
(define rob-forms
  (append first-stage
          (scenario-forms 2 yA-normal  yB-normal  p-normal)     ; shares cols 0,1
          (scenario-forms 3 yA-drought yB-drought p-drought)))  ; shares cols 0,1  ← non-anticipativity
(define xr (solve-x rob-forms (vector 0.2 0.6 0.5 0.5)))
(define rob-xA (vector-ref xr 0)) (define rob-xB (vector-ref xr 1))
(define rob-food-normal  (vector-ref xr 2))
(define rob-food-drought (vector-ref xr 3))

(format #t "~%ROBUST (2-scenario) plan:         x_A=~,3f  x_B=~,3f~%" rob-xA rob-xB)
(format #t "  → normal food  = ~,3f   drought food = ~,3f   (floor F=~,1f)~%"
        rob-food-normal rob-food-drought F)

;; ── assertions ───────────────────────────────────────────────────────────────
(format #t "~%── assertions ──~%")
(check "deterministic plants a MONOCULTURE of A (x_A > 0.9)"      (> det-xA 0.9))
(check "deterministic barely grows B (x_B < 0.1)"                (< det-xB 0.1))
(check "deterministic plan STARVES in drought (food < floor)"    (< det-drought-food F))

(check "robust DIVERSIFIES into B (x_B > 0.75)"                  (> rob-xB 0.75))
(check "robust still grows some A where safe (x_A > 0.05)"       (> rob-xA 0.05))
(check "robust is NOT a degenerate all-B monoculture (x_B < 0.95)" (< rob-xB 0.95))
(check "robust meets the floor in the NORMAL year"              (>= rob-food-normal  (* 0.99 F)))
(check "robust meets the floor in the DROUGHT year"            (>= rob-food-drought (* 0.99 F)))
(check "so diversity is DERIVED, not assumed (robust x_B ≫ deterministic x_B)"
       (> rob-xB (+ det-xB 0.5)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — robust multi-scenario planning works on the~%  existing solver; diversity emerges from defending the reproduction floor.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
