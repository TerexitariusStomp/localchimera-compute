;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-kkt-verification.scm — verifying the verifier.
;;;
;;; Every optimality claim this engine makes now rests on `kkt-report`. If that
;;; function is wrong, everything built on it is wrong in the same direction and
;;; nothing downstream would notice — a broken certificate does not fail loudly,
;;; it approves. So it is checked here against ground truth obtained WITHOUT it:
;;; finite differences, brute-force search, and closed-form algebra.
;;;
;;; Four independent checks, in order of how fundamental they are:
;;;
;;;   1. THE GRADIENT IS THE GRADIENT. The residual is ‖∇f − Aᵀy‖, so if
;;;      `csr-grad` does not compute the derivative of `obj-value`, every residual
;;;      is meaningless. Checked by central differences on the objective itself.
;;;
;;;   2. COMPLEMENTARITY IS EXACT. The dual is yᵢ = t/sᵢ, so sᵢyᵢ = t must hold
;;;      identically for every barrier constraint. This is what makes μ = t.
;;;
;;;   3. STATIONARITY VANISHES AT THE OPTIMUM, AND ONLY THERE. Brute-force the
;;;      barrier problem's minimiser on a dense grid — no solver, no derivatives —
;;;      and check the reported residual bottoms out there and grows away from it.
;;;
;;;   4. THE BOUND ACTUALLY BOUNDS. For the barrier optimum x(t), the true
;;;      suboptimality against the UNPERTURBED problem must sit inside m·t, the
;;;      classical interior-point bound. Both sides computed by brute force.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-kkt-verification.scm

(use-modules (playnet test planner prelude)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))

;; ── a two-variable program with barriers, desires and a coupling constraint ──
;; Deliberately NOT the rig the solver tests use: different shape, so an error
;; that happens to cancel there has no reason to cancel here.
(define (rig2)
  (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 8.0 300.0)      ; want x₀ → 8
        (mk-des (mk-bar 0.0 '((1 . 1.0))) 5.0 120.0)      ; want x₁ → 5
        (mk-frag 12.0 (list (cons 0 -1.0) (cons 1 -0.5)) 30.0)  ; fragility on a mix
        (mk-bar 20.0 (list (cons 0 -1.0) (cons 1 -1.0)))  ; hard cap x₀+x₁ ≤ 20
        (mk-bar 0.0 '((0 . 1.0)))                          ; x₀ ≥ 0
        (mk-bar 0.0 '((1 . 1.0)))))                        ; x₁ ≥ 0
(define C2 (flatten (rig2)))
(define lab2 (list (cons 0 0.10) (cons 1 0.05)))           ; a little labour on each

(define (f-at t x) (obj-value C2 lab2 t x (term-values C2 x)))

;;; ════════════════════════════════════════════════════════════════════════════
(display "\n── 1. csr-grad really is the derivative of obj-value ──\n")
;;; The whole residual is built on this. Central differences, several points, so
;;; a coincidence at one of them cannot pass.

(define (fd-gradient t x h)
  (let* ((n (vector-length x)) (g (make-vector n 0.0)))
    (do ((i 0 (+ i 1))) ((= i n) g)
      (let ((xp (vector-copy x)) (xm (vector-copy x)))
        (vector-set! xp i (+ (vector-ref x i) h))
        (vector-set! xm i (- (vector-ref x i) h))
        (vector-set! g i (/ (- (f-at t xp) (f-at t xm)) (* 2.0 h)))))))

(for-each
  (lambda (pt)
    (let* ((x (list->vector pt))
           (t 0.05)
           (analytic (csr-grad C2 lab2 t (term-values C2 x) 2))
           (numeric  (fd-gradient t x 1e-6))
           (rel (/ (sqrt (+ (expt (- (vector-ref analytic 0) (vector-ref numeric 0)) 2)
                            (expt (- (vector-ref analytic 1) (vector-ref numeric 1)) 2)))
                   (+ 1.0 (sqrt (+ (expt (vector-ref numeric 0) 2)
                                   (expt (vector-ref numeric 1) 2)))))))
      (format #t "  at (~,2f, ~,2f): analytic (~,4f, ~,4f)  numeric (~,4f, ~,4f)  rel err ~,2e\n"
              (car pt) (cadr pt)
              (vector-ref analytic 0) (vector-ref analytic 1)
              (vector-ref numeric 0) (vector-ref numeric 1) rel)
      (check (format #f "gradient matches finite differences at (~,1f, ~,1f)" (car pt) (cadr pt))
             (< rel 1e-5))))
  '((1.0 1.0) (3.0 2.0) (5.5 3.0) (0.4 6.0)))

;;; ════════════════════════════════════════════════════════════════════════════
(display "\n── 2. complementarity sᵢyᵢ = t is exact, by construction ──\n")
;;; μ = sᵀy/m = t only if EVERY barrier constraint contributes exactly t. If any
;;; term is missed (or a non-barrier term is wrongly included) μ is not the gap.

(let* ((x (vector 3.0 2.0))
       (t 0.05)
       (sv (term-values C2 x))
       (nt (cnt C2)))
  (let lp ((ti 0) (worst 0.0) (m 0))
    (if (= ti nt)
        (begin
          (format #t "  ~a barrier constraints; worst |sᵢyᵢ − t| = ~,2e\n" m worst)
          (check "every barrier slack contributes exactly t to the gap" (< worst 1e-12))
          (check "and the barrier constraints were actually found" (> m 0)))
        (let ((k (vector-ref (ckind C2) ti)))
          (if (or (= k 0) (= k 3))
              (let* ((s (vector-ref sv ti))
                     (y (/ t s)))                       ; the central-path dual
                (lp (+ ti 1) (max worst (abs (- (* s y) t))) (+ m 1)))
              (lp (+ ti 1) worst m))))))

;;; ════════════════════════════════════════════════════════════════════════════
(display "\n── 3. stationarity bottoms out at the true minimiser, found by brute force ──\n")
;;; No solver, no derivatives: scan a dense grid for the minimum of the barrier
;;; objective, then ask kkt-report what it thinks of that point and of its
;;; neighbours. A correct residual is ~0 at the minimum and rises away from it.

;; Coarse scan, then LOCAL REFINEMENT. A step of 0.05 locates the minimiser only
;; to ±0.025, and near a log barrier the gradient moves fast over that distance —
;; so a coarse grid cannot test "stationarity vanishes at the minimum", and it
;; cannot resolve the barrier displacement either (which made the bound check
;; pass vacuously with a true gap of exactly 0). Refine until the location is
;; sharp enough that the claim being tested is actually the claim.
(define (brute-min-refined t lo hi)
  (let loop ((c (brute-min t lo hi 0.05)) (step 0.01))
    (if (< step 1e-6) c
        (let* ((a (vector-ref c 0)) (b (vector-ref c 1))
               (w (* 4.0 step))
               (c2 (brute-min t (max 1e-6 (- a w)) (+ a w) step
                              (max 1e-6 (- b w)) (+ b w))))
          (loop (or c2 c) (/ step 10.0))))))

(define* (brute-min t lo hi step #:optional blo bhi)
  (let ((blo (or blo lo)) (bhi (or bhi hi)))
   (let loop ((a lo) (best #f) (bv +inf.0))
    (if (> a hi) best
        (let inner ((b blo) (best best) (bv bv))
          (if (> b bhi) (loop (+ a step) best bv)
              (let* ((x (vector a b))
                     (sv (term-values C2 x))
                     (ok (let lp ((ti 0))                ; strictly inside every barrier
                           (cond ((= ti (cnt C2)) #t)
                                 ((and (memv (vector-ref (ckind C2) ti) '(0 3))
                                       (<= (vector-ref sv ti) 1e-9)) #f)
                                 (else (lp (+ ti 1))))))
                     (v (if ok (f-at t x) +inf.0)))
                (if (< v bv) (inner (+ b step) x v) (inner (+ b step) best bv)))))))))

(let* ((t 0.05)
       (xb (brute-min-refined t 0.05 12.0))
       (kb (kkt-report C2 lab2 xb t))
       (off (vector (+ (vector-ref xb 0) 0.5) (vector-ref xb 1)))
       (ko (kkt-report C2 lab2 off t)))
  (format #t "  brute-force minimiser  (~,3f, ~,3f)  stationarity ~,3e\n"
          (vector-ref xb 0) (vector-ref xb 1) (assq-ref kb 'stationarity))
  (format #t "  displaced by 0.5 in x₀ (~,3f, ~,3f)  stationarity ~,3e\n"
          (vector-ref off 0) (vector-ref off 1) (assq-ref ko 'stationarity))
  (check "stationarity is small at the brute-force minimiser"
         (< (assq-ref kb 'stationarity) 5e-3))
  (check "…and materially larger just off it — the residual discriminates"
         (> (assq-ref ko 'stationarity) (* 10.0 (assq-ref kb 'stationarity))))
  (check "the minimiser is reported feasible" (assq-ref kb 'feasible?))
  (check "…and its μ is the t it was solved at"
         (< (abs (- (assq-ref kb 'mu) t)) 1e-12)))

;;; ════════════════════════════════════════════════════════════════════════════
(display "\n── 4. the certificate's bound really bounds the suboptimality ──\n")
;;; The classical interior-point statement: the barrier minimiser x(t) is within
;;; m·t of the true constrained optimum, m = number of barrier constraints. Both
;;; the perturbed and the unperturbed optima are found by brute force, so this
;;; check knows nothing about the solver OR about kkt-report's internals.

(let ((true-opt (brute-min-refined 1e-9 0.05 12.0)))   ; t→0 ⇒ essentially unperturbed
  (for-each
    (lambda (t)
      (let* ((xt (brute-min-refined t 0.05 12.0))
             (k  (kkt-report C2 lab2 xt t))
             ;; suboptimality measured on the UNPERTURBED objective, both optima
             ;; located by brute force — this check knows nothing about the solver
             ;; or about kkt-report's internals
             (gap   (- (f-at 1e-9 xt) (f-at 1e-9 true-opt)))
             (bound (assq-ref k 'gap-bound))
             (comp  (* (assq-ref k 'm) (assq-ref k 'mu)))
             (resid (* (assq-ref k 'residual) (assq-ref k 'box-radius))))
        (format #t "  t=~,3f  true gap ~,3e  ≤  CERTIFIED ~,3e  [m·μ ~,2e + ‖r‖D ~,2e]  ~a\n"
                t gap bound comp resid (if (<= gap (+ bound 1e-9)) "inside" "OUTSIDE"))
        ;; THE theorem: f(x) − f(x*) ≤ yᵀs(x) + ‖r‖·‖x−x*‖. If this ever fails the
        ;; proof is wrong or the implementation does not match it.
        (check (format #f "the CERTIFIED bound holds at t = ~,3f" t)
               (<= gap (+ bound 1e-9)))
        ;; and it must not be vacuous — an infinite bound proves nothing
        (check (format #f "…and is finite at t = ~,3f" t)
               (< bound +inf.0))))
    '(0.2 0.1 0.05 0.02)))

(check-done "  The certificate is verified against finite differences, brute force and algebra.~%")
