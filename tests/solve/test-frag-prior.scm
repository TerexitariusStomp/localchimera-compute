;;; test-frag-prior.scm — the observed baseline: the barrier reads where the WORLD already is.
;;;
;;; The planner curve is memoryless; the OBSERVER holds the world's current state and feeds it in
;;; each solve (here via `eco-prior` / `*frag-prior*`). The frag baseline becomes s_tip − prior, so
;;; the plan's draw is INCREMENTAL from the observed position — past degradation is already baked in.
;;; This is the irreversibility "memory": it lives in the world, read each solve, NOT in the planner.
;;;
;;; One recipe draws `co2` to make `widget`; a frag cap on co2 (tip 10) and strong demand (20). With a
;;; nonzero observed prior P, the remaining headroom is 10 − P, and the plan eases off below THAT, never
;;; letting prior + draw cross the true tip. Proves: (a) prior tightens the draw; (b) the draw stays
;;; under the remaining headroom; (c) prior + draw never crosses the true tip; (d) prior=0 recovers the
;;; full-headroom behaviour.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-prior.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet solve compile)
             (playnet solve solver))

(define s-tip 10.0)   ; co2 tip = quantile_0.5 of [8,12]
(define (emit-recipe)
  (compile-recipe (list (rp "emit" "Emit"))
                  (list (out "o1" "widget" 1.0 "emit") (wrk "o2" 0.1 "emit")
                        (in "o3" "co2" 1.0 "emit"))))   ; co2 drawn 1:1 with widget

(define (run prior)
  (declare-world! #:places '(("town" 0.0 0.0)) #:templates (emit-recipe))
  (hash-set! *A* (cell "town" 0) 10000.0)
  (hash-set! *frag-cap* (lg "co2" (cell "town" 0)) (list 8.0 12.0 0.5 50.0))    ; tip 10, fixed weight 50
  (when (> prior 0.0) (hash-set! *frag-prior* (lg "co2" (cell "town" 0)) prior)) ; the OBSERVED draw already committed
  (hash-set! *demand* (lg "widget" (cell "town" 0)) 20.0)                        ; want well past the tip
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (V "p|emit|town@0")))))   ; the incremental co2 draw this solve

(define d0 (run 0.0))    ; full headroom
(define d4 (run 4.0))    ; observer says 4 already spent ⇒ headroom 6

(format #t "~%── observed baseline · true tip s_tip=~a ──~%" s-tip)
(format #t "  prior 0: incremental draw ~,3f                         (headroom ~a)~%" d0 s-tip)
(format #t "  prior 4: incremental draw ~,3f  (prior+draw = ~,3f)   (headroom ~a)~%" d4 (+ 4.0 d4) (- s-tip 4.0))

(let* ((c1 (< d0 s-tip))                       ; prior 0: eases off below the full tip
       (c2 (< d4 (- s-tip 4.0)))               ; prior 4: eases off below the REMAINING headroom (10−4=6)
       (c3 (< (+ 4.0 d4) s-tip))               ; prior + draw never crosses the TRUE tip
       (c4 (< d4 (- d0 1.0)))                  ; the observed prior meaningfully tightens the draw
       (c5 (> (- (- s-tip 4.0) d4) 0.05))      ; …and still eases off BEFORE the remaining headroom (margin)
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] prior 0 eases off below the full tip (~,3f < ~a)~%" (if c1 "✓" "✗") d0 s-tip)
  (format #t "  [~a] prior 4 eases off below the REMAINING headroom (~,3f < ~,1f)~%" (if (and c2 c5) "✓" "✗") d4 (- s-tip 4.0))
  (format #t "  [~a] prior + draw never crosses the true tip (~,3f < ~a)~%" (if c3 "✓" "✗") (+ 4.0 d4) s-tip)
  (format #t "  [~a] the observed prior tightens the incremental draw (~,3f < ~,3f)~%" (if c4 "✓" "✗") d4 d0)
  (format #t "~%  ~a the barrier reads where the WORLD already is — draw is incremental from the observed position~%~%"
          (if ok "✓" "✗"))
  (exit (if ok 0 1)))
