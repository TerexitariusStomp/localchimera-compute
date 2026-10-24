;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-frag-budget.scm — a CUMULATIVE fragility budget across the horizon (Time coordinate).
;;;
;;; Slice 2, the "max is a no-op" half of the monotone envelope: a fragility barrier on a spec's
;;; TOTAL draw summed across every period, not a per-period cap. The carbon-budget shape — the
;;; plan may emit in any period, but the horizon total is what strains toward the tip.
;;;
;;; Two periods, a recipe that draws `co2` to make `widget`, demand in BOTH periods (16 total).
;;; A loose per-period cap keeps co2 available; the `eco-budget` on co2 (s_tip = 10) binds the SUM.
;;; Proves: with the budget the horizon total eases off below s_tip (never crosses) and falls well
;;; under the unbudgeted total (which meets the full 16 demand); the draw spreads across periods;
;;; and build-located emits exactly one aggregate (kind-3) form for the whole horizon.
;;;
;;; Run:  guile --no-auto-compile -L module/localchimera/planner tests/solve/test-frag-budget.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve world)
             (localchimera solve compile)
             (localchimera solve solver))

(define s-tip 10.0)   ; = quantile_0.5 of [8,12]; the budget is over TWO periods' total co2 draw
(define (count-kind C k) (let ((kv (ckind C)) (n (cnt C)) (a 0))
                           (do ((i 0 (+ i 1))) ((= i n) a) (when (= (vector-ref kv i) k) (set! a (+ a 1))))))
(define (emit-recipe)
  (compile-recipe (list (rp "emit" "Emit"))
                  (list (out "o1" "widget" 1.0 "emit") (wrk "o2" 0.1 "emit")
                        (in "o3" "co2" 1.0 "emit"))))   ; co2 drawn 1:1 with widget output

(define (run budget?)
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods '(0 1)
                  #:templates (emit-recipe))
  (hash-set! *A* (cell "town" 0) 10000.0) (hash-set! *A* (cell "town" 1) 10000.0)
  (hash-set! *cap* (lg "co2" (cell "town" 0)) 100.0)            ; loose per-period availability (does not bind)
  (hash-set! *cap* (lg "co2" (cell "town" 1)) 100.0)
  (hash-set! *demand* (lg "widget" (cell "town" 0)) 8.0)        ; want 8 + 8 = 16 total across the horizon
  (hash-set! *demand* (lg "widget" (cell "town" 1)) 8.0)
  (when budget? (hash-set! *frag-budget* "co2" (list 8.0 12.0 0.5 50.0)))   ; CUMULATIVE budget: total co2 ≤ ~s_tip=10
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0))))
             (d0 (V "p|emit|town@0")) (d1 (V "p|emit|town@1")))
        (list d0 d1 (+ d0 d1) (count-kind (flatten forms) 3))))))

(define free (run #f))         ; no budget: meets the full 16 demand
(define cap  (run #t))         ; budget: horizon total bound below s_tip
(define (d0 r)(first r))(define (d1 r)(second r))(define (tot r)(third r))(define (n3 r)(fourth r))

(format #t "~%── cumulative fragility budget over 2 periods · s_tip=~a, demand 8+8=16 ──~%" s-tip)
(format #t "  unbudgeted: period0 ~,3f  period1 ~,3f  total ~,3f  (frag forms ~a)~%" (d0 free) (d1 free) (tot free) (n3 free))
(format #t "  budgeted:   period0 ~,3f  period1 ~,3f  total ~,3f  (frag forms ~a)~%" (d0 cap) (d1 cap) (tot cap) (n3 cap))

(let* ((c1 (> (tot free) 14.0))                          ; unbudgeted meets ~all of the 16 demand
       (c2 (= 0 (n3 free)))                              ; …and emits no fragility form
       (c3 (= 1 (n3 cap)))                               ; ONE aggregate frag form for the whole horizon
       (c4 (< (tot cap) s-tip))                          ; budget never crossed
       (c5 (> (- s-tip (tot cap)) 0.05))                 ; …eased off BEFORE the tip (real margin, fixed-weight)
       (c6 (< (tot cap) (- (tot free) 4.0)))             ; budget meaningfully cuts the horizon total
       (c7 (and (> (d0 cap) 0.5) (> (d1 cap) 0.5)))      ; draw still spread across BOTH periods
       (ok (and c1 c2 c3 c4 c5 c6 c7)))
  (format #t "~%  [~a] unbudgeted draws freely (~,1f, demand met and then some), no frag form~%" (if (and c1 c2) "✓" "✗") (tot free))
  (format #t "  [~a] one aggregate frag form binds the horizon total~%" (if c3 "✓" "✗"))
  (format #t "  [~a] total eases off BEFORE the budget tip (~,3f < ~a, margin ~,3f)~%" (if (and c4 c5) "✓" "✗") (tot cap) s-tip (- s-tip (tot cap)))
  (format #t "  [~a] budget cuts the total well below the unbudgeted draw~%" (if c6 "✓" "✗"))
  (format #t "  [~a] the remaining draw is spread across both periods~%" (if c7 "✓" "✗"))
  (format #t "~%  ~a a cumulative budget: one barrier on the spec's TOTAL draw across the horizon — the Time coordinate, max-is-a-no-op~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
