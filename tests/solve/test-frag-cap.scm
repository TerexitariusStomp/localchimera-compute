;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-frag-cap.scm — the FRAGILITY barrier (frag) on an ecological cap, end to end.
;;;
;;; Slice 1 of the ecological possibility-tension. An eco draw used to be a HARD wall
;;; (`mk-bar cap`): the t-swept barrier rides right up to the cap (t → 0.02). The white
;;; paper's *fragility profile* is instead a FIXED-weight divergent barrier `φ = −w·log u`
;;; on the normalised distance-to-tip `u = (s_tip − draw)/(s_tip − s*)`, with the tip placed
;;; precautionarily inside the science range [lo,hi] at quantile_α. The federation feels it
;;; BEFORE the limit and eases off "by its own arithmetic"; the limit is NEVER crossed.
;;;
;;; This drives a `frag` cap through a real `solve-native` for the first time and proves:
;;;   (a) pull (w/s) RISES as the draw approaches the tip;
;;;   (b) the optimum EASES OFF before the cap (draw < s_tip strictly; heavier w backs off more);
;;;   (c) the draw NEVER crosses s_tip across a sweep of desire strengths;
;;;   (d) frag vs the hard bar: same geometry, the bar rides the wall, frag stands well back;
;;;   (e) integration: build-located emits exactly one kind-3 (frag) form, slack = s_tip − draw.
;;;
;;; The barrier reads the RAW distance-to-tip s = s_tip − draw (no (s_tip−s*) normalisation —
;;; that is a display convention, inert for the optimum; raw s makes the dual w/s correct directly).
;;;
;;; Closed form (labour-free, swept bars inactive): with desire g→D and tip s_tip,
;;;   x* = 15 − √(25 + 200·w/wd)   for D=20, s_tip=10, s*=0.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-cap.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver))

(define D 20.0)        ; a desire that wants the drawing activity well PAST the tip
(define s-tip 10.0)    ; = quantile_0.5 of [8,12]
;; the FRAGILITY barrier on the raw draw (x[0] draws at rate 1): slack s = s_tip − x
(define (frag-form w) (mk-frag s-tip (list (cons 0 -1.0)) w))
;; the HARD-cap counterpart, same geometry: slack = s_tip − x
(define (bar-form)    (mk-bar s-tip (list (cons 0 -1.0))))

;; solve x[0] against {desire→D, <cap>, x≥0}; return (x0 u pull) for frag, x0 for bar.
(define (solve-frag w wd)
  (let ((forms (list (mk-des (mk-bar 0.0 '((0 . 1.0))) D wd) (frag-form w) (mk-bar 0.0 '((0 . 1.0))))))
    (call-with-values (lambda () (solve-native forms '() (vector 0.5)))
      (lambda (x t . _)
        (let* ((sv (term-values (flatten forms) x)) (x0 (vector-ref x 0)) (u (vector-ref sv 1)))  ; frag is form index 1
          (list x0 u (/ w (max 1e-12 u))))))))
(define (solve-bar wd)
  (let ((forms (list (mk-des (mk-bar 0.0 '((0 . 1.0))) D wd) (bar-form) (mk-bar 0.0 '((0 . 1.0))))))
    (call-with-values (lambda () (solve-native forms '() (vector 0.5)))
      (lambda (x t . _) (vector-ref x 0)))))
;; same frag problem, but from a chosen warm start x0 (to exercise phase-I feasibility recovery)
(define (solve-frag/x0 w wd x0v)
  (let ((forms (list (mk-des (mk-bar 0.0 '((0 . 1.0))) D wd) (frag-form w) (mk-bar 0.0 '((0 . 1.0))))))
    (call-with-values (lambda () (solve-native forms '() (vector x0v)))
      (lambda (x t . _) (vector-ref x 0)))))
(define (drw r) (first r)) (define (slk r) (second r)) (define (pll r) (third r))

;; ── (a) pull rises as the draw nears the tip (fixed w, two desire strengths) ──
(define a-weak   (solve-frag 50.0 100.0))     ; x≈3.82,  u≈0.618, pull≈81
(define a-strong (solve-frag 50.0 5000.0))    ; x≈9.80,  u≈0.020, pull≈2551
;; ── (b) eases off before the cap; heavier w backs off more (fixed desire) ──
(define b-light (solve-frag 50.0  1000.0))    ; x≈9.08
(define b-heavy (solve-frag 200.0 1000.0))    ; x≈6.94
;; ── (c) never crosses, desire sweep ──
(define sweep (map (lambda (wd) (drw (solve-frag 50.0 wd))) '(100.0 1000.0 5000.0 20000.0 100000.0)))
;; ── (d) frag vs hard bar, same geometry ──
(define d-frag (drw b-light))                 ; ≈9.08
(define d-bar  (solve-bar 1000.0))            ; ≈9.9996 (rides the wall)
;; ── (f) feasibility recovery: a warm start PAST the tip is pulled back by phase-I ──
(define f-recovered (solve-frag/x0 50.0 1000.0 15.0))   ; x0 draws 15 > tip 10 (infeasible) → must recover to ≈9.08

;; ── (e) integration: a recipe that DRAWS a frag-capped raw, through build-located ──
(define (emit-recipe)
  (compile-recipe (list (rp "emit" "Emit"))
                  (list (out "o1" "widget" 1.0 "emit") (wrk "o2" 0.1 "emit")
                        (in "o3" "co2" 1.0 "emit"))))    ; co2 consumed, never produced ⇒ a raw
(define (count-kind C k) (let ((kv (ckind C)) (n (cnt C)) (a 0))
                           (do ((i 0 (+ i 1))) ((= i n) a) (when (= (vector-ref kv i) k) (set! a (+ a 1))))))
(define (index-kind C k) (let ((kv (ckind C)) (n (cnt C)))
                           (let loop ((i 0)) (cond ((= i n) #f) ((= (vector-ref kv i) k) i) (else (loop (+ i 1)))))))
(define intg
  (begin
    (declare-world! #:places '(("town" 0.0 0.0)) #:templates (emit-recipe))
    (hash-set! *frag-cap* (lg "co2" (cell "town" 0)) (list 8.0 12.0 0.5 50.0))   ; (lo hi alpha w) ⇒ s_tip=10, const=s_tip
    (hash-set! *A* (cell "town" 0) 10000.0)
    (hash-set! *demand* (lg "widget" (cell "town" 0)) 20.0)
    (call-with-values build-located
      (lambda (forms labform ncol cols goods raws idx)
        (let* ((C (flatten forms))
               (n3 (count-kind C 3)) (i3 (index-kind C 3))
               (const3 (and i3 (vector-ref (cconst C) i3)))
               (s0 (and i3 (vector-ref (term-values C (make-vector ncol 0.0)) i3))))  ; slack at x=0 (healthy) = s_tip
          (list n3 const3 s0))))))

(format #t "~%── fragility barrier (frag) on an eco cap · tip s_tip=~a ──~%" s-tip)
(format #t "  (a) desire↑:  wd=100  → draw ~6,3f  pull ~8,2f~%" (drw a-weak)   (pll a-weak))
(format #t "      desire↑:  wd=5000 → draw ~6,3f  pull ~8,2f~%" (drw a-strong) (pll a-strong))
(format #t "  (b) ease-off: w=50  → draw ~6,3f (margin ~,3f)~%" (drw b-light) (- s-tip (drw b-light)))
(format #t "      ease-off: w=200 → draw ~6,3f (margin ~,3f)~%" (drw b-heavy) (- s-tip (drw b-heavy)))
(format #t "  (c) sweep draws: ~a~%" (map (lambda (v) (/ (round (* v 1000)) 1000.0)) sweep))
(format #t "  (d) frag draw ~,3f  vs  hard-bar draw ~,4f  (bar rides the wall)~%" d-frag d-bar)
(format #t "  (e) build-located: kind-3 forms = ~a, const = ~a, healthy slack = ~a~%"
        (first intg) (second intg) (third intg))

(let* ((c-a1 (> (drw a-strong) (drw a-weak)))                       ; stronger desire ⇒ larger draw
       (c-a2 (> (pll a-strong) (pll a-weak)))                       ; pull strictly rises
       (c-a3 (> (pll a-strong) (* 5.0 (pll a-weak))))               ; rises sharply near the tip
       (c-b1 (< (drw b-light) s-tip))                               ; strictly inside the cap
       (c-b2 (< (drw b-heavy) s-tip))
       (c-b3 (< (drw b-heavy) (drw b-light)))                       ; heavier weight backs off further
       (c-b4 (> (- s-tip (drw b-light)) 0.3))                       ; visible margin
       (c-b5 (> (- s-tip (drw b-heavy)) 2.0))
       (c-c  (every (lambda (x) (and (>= x 0.0) (< x s-tip))) sweep)) ; never crosses, ever
       (c-d1 (> d-bar (- s-tip 0.05)))                              ; the hard bar rides the wall
       (c-d2 (< d-frag (- d-bar 0.5)))                              ; frag stands a clear margin back
       (c-d3 (< d-frag s-tip))
       (c-e1 (= 1 (first intg)))                                    ; exactly one frag form emitted
       (c-e2 (and (second intg) (< (abs (- (second intg) s-tip)) 1e-9)))  ; const = s_tip (no normalisation)
       (c-e3 (and (third intg)  (< (abs (- (third intg)  s-tip)) 1e-9)))  ; healthy (x=0) slack = s_tip − 0 = s_tip
       (c-f1 (< f-recovered s-tip))                                ; phase-I pulled the past-the-tip start back inside
       (c-f2 (< (abs (- f-recovered d-frag)) 0.05))                ; …to the SAME optimum the feasible start finds
       (ok (and c-a1 c-a2 c-a3 c-b1 c-b2 c-b3 c-b4 c-b5 c-c c-d1 c-d2 c-d3 c-e1 c-e2 c-e3 c-f1 c-f2)))
  (format #t "~%  [~a] (a) possibility-pull rises as the draw approaches the tip~%" (if (and c-a1 c-a2 c-a3) "✓" "✗"))
  (format #t "  [~a] (b) eases off BEFORE the cap; heavier weight backs off more~%" (if (and c-b1 c-b2 c-b3 c-b4 c-b5) "✓" "✗"))
  (format #t "  [~a] (c) the draw NEVER crosses the tip across the desire sweep~%" (if c-c "✓" "✗"))
  (format #t "  [~a] (d) frag stands back where the hard bar rides the wall~%" (if (and c-d1 c-d2 c-d3) "✓" "✗"))
  (format #t "  [~a] (e) build-located emits one frag form, const = healthy slack = s_tip~%" (if (and c-e1 c-e2 c-e3) "✓" "✗"))
  (format #t "  [~a] (f) phase-I recovers a start past the tip (x0=15 → ~,3f < ~a)~%" (if (and c-f1 c-f2) "✓" "✗") f-recovered s-tip)
  (format #t "~%  ~a a fragility barrier felt before the limit, never crossed — the frag kind, end to end~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
