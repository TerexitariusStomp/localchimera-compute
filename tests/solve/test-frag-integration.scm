;;; test-frag-integration.scm — all the fragility mechanisms in one solve, plus edge cases.
;;;
;;; Closes gap 7: nothing exercised the mechanisms TOGETHER, or the edges.
;;;   (A) MULTI-MECHANISM — one plan carrying a cumulative budget (co2) with an observed prior, a
;;;       per-spec rate (nitrogen), AND a container roll-up (the Amazon's trees), each binding its own
;;;       limit independently in a single solve.
;;;   (B) EDGE: observed prior already PAST the tip ⇒ no headroom ⇒ the draw is blocked (0).
;;;   (C) EDGE: an empty catalogue ⇒ an empty policy (no spurious forms).
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-integration.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet solve solver))
(use-modules (playnet knowledge catalogues eco))

(define (recipes)
  (compile-recipe
    (list (rp "emit" "Emit") (rp "fert" "Fertilize") (rp "log" "Log"))
    (list (out "a1" "widget" 1.0 "emit") (wrk "a2" 0.001 "emit") (in "a3" "co2" 1.0 "emit")
          (out "b1" "grain"  1.0 "fert") (wrk "b2" 0.001 "fert") (in "b3" "nitrogen" 1.0 "fert")
          (out "c1" "timber" 1.0 "log")  (wrk "c2" 0.001 "log")  (in "c3" "tree" 1.0 "log"))))
(define (want! good w) (hash-set! *demand* (lg good (cell "amazon" 0)) 500.0)
                       (hash-set! *desire-weight* (lg good (cell "amazon" 0)) 8000.0))
(define x-of #f)
(define (solve!) (call-with-values build-located
                   (lambda (forms labform ncol cols goods raws idx)
                     (set! x-of (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
                     idx)))
(define (V idx k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x-of i) 0.0)))

;; ── (A) all mechanisms at once ──
(define (setup!)
  (declare-world! #:places '(("amazon" 0.0 0.0)) #:templates (recipes))
  (hash-set! *A* (cell "amazon" 0) 1e8)
  (hash-set! *cap* (lg "tree" (cell "amazon" 0)) 10000.0)            ; trees available (the Amazon's stock)
  (hash-set! *frag-budget* "co2" (list 400.0 500.0 0.0 10.0))       ; carbon budget, tip 400
  (hash-set! *frag-spec*   "nitrogen" (list 62.0 82.0 0.5 5.0))     ; nitrogen rate, tip 72
  (hash-set! *contained* "amazon" '("tree"))
  (hash-set! *frag-container* "amazon" (list 40.0 60.0 0.5 50.0))   ; Amazon container, tip 50
  (want! "widget" 8000.0) (want! "grain" 8000.0) (want! "timber" 8000.0))
(setup!)
(hash-set! *frag-prior* "co2" 100.0)                                ; observed: 100 GtCO2 already spent ⇒ effective tip 300
(define A-idx (solve!))
(define a-co2 (V A-idx "p|emit|amazon@0")) (define a-n (V A-idx "p|fert|amazon@0")) (define a-tree (V A-idx "p|log|amazon@0"))

;; ── (B) prior already past the tip ⇒ draw blocked ──
(setup!)
(hash-set! *frag-prior* "co2" 500.0)                                ; 500 > tip 400 ⇒ negative headroom
(define B-idx (solve!))
(define b-co2 (V B-idx "p|emit|amazon@0"))

;; ── (C) empty catalogue ⇒ empty policy ──
(define empty-pol (call-with-values (lambda () (catalogue->policy '())) list))

(format #t "~%── all mechanisms in one solve, + edges ──~%")
(format #t "  (A) co2 ~,1f (budget 400 − prior 100 = 300)   nitrogen ~,1f (rate 72)   trees ~,1f (container 50)~%" a-co2 a-n a-tree)
(format #t "  (B) prior 500 > tip 400 ⇒ co2 draw ~,3f (blocked)~%" b-co2)
(format #t "  (C) empty catalogue → policy ~a~%" empty-pol)

(let* ((a1 (< a-co2 300.0)) (a1b (> a-co2 50.0))     ; co2 budget binds at the prior-reduced tip
       (a2 (< a-n 72.0))    (a2b (> a-n 5.0))         ; nitrogen rate binds
       (a3 (< a-tree 50.0)) (a3b (> a-tree 5.0))      ; container binds
       (b1 (< b-co2 0.01))                            ; prior past the tip blocks the draw
       (c1 (equal? empty-pol '(() () ())))            ; empty catalogue ⇒ empty policy
       (ok (and a1 a1b a2 a2b a3 a3b b1 c1)))
  (format #t "~%  [~a] (A) three independent fragilities bind in ONE solve (co2<300, N<72, trees<50)~%" (if (and a1 a1b a2 a2b a3 a3b) "✓" "✗"))
  (format #t "  [~a] (A) the observed prior reduced the carbon tip from 400 to 300~%" (if a1 "✓" "✗"))
  (format #t "  [~a] (B) a prior past the tip leaves no headroom — the draw is blocked (~,3f)~%" (if b1 "✓" "✗") b-co2)
  (format #t "  [~a] (C) an empty catalogue yields an empty policy — no spurious forms~%" (if c1 "✓" "✗"))
  (format #t "~%  ~a the mechanisms compose in one convex solve, and the edges behave~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
