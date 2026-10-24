;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-property-solver-invariants.scm — randomized checks of the Layer-A
;;; math against the actual solver, not one hand-picked rig.
;;;
;;; `test-kkt-verification.scm` checks the certificate's theorems hold on one
;;; fixed two-variable program. That is necessary but not sufficient: an
;;; implementation bug in CSR indexing, a Cholesky degenerate case, or a
;;; sign error that happens to cancel on that one rig would pass silently.
;;; This file generates many random small sparse programs — variable count,
;;; caps, desire targets, fragility terms all randomized from a fixed seed
;;; (reproducible) — and checks the same postconditions the certificate
;;; theorems predict must hold on EVERY one of them, not just the one this
;;; test suite happened to hand-pick.
;;;
;;; This is deliberately NOT a proof. It cannot be — see
;;; docs/formal/solver-certificate/README.md for why static verification of
;;; this layer (CSR/Cholesky/OMP/OSQP implementation correctness) is out of
;;; scope for that project. What it IS: a direct, cheap way to exercise
;;; exactly the implementation-bug surface formal proof doesn't reach,
;;; using the Layer-A theorems (already proved in Lean, or already carrying
;;; a `PROOF.`-style comment in solver.scm) as the test oracle instead of
;;; hand-picked expected values.
;;;
;;; Four properties checked per random program:
;;;
;;;   1. STRONG-CONVEXITY MODULUS IS A REAL LOWER BOUND. `strong-convexity-
;;;      modulus` (solver.scm:642-666) claims λ_min(H) ≥ σ, proved in
;;;      docs/formal/solver-certificate/SolverCertificate/StrongConvexity
;;;      Modulus.lean. Checked here via finite-difference directional
;;;      curvature along random unit vectors — the same central-difference
;;;      technique test-kkt-verification.scm already uses for the gradient,
;;;      extended one derivative further.
;;;
;;;   2. THE SOLVED POINT IS LOCALLY OPTIMAL. Perturb the solver's own
;;;      output in random feasible directions; the objective must not
;;;      improve (beyond noise). This is the cheapest possible check that
;;;      solve-native's output is what it claims to be, independent of
;;;      kkt-report's own internals (a bug shared between the solver and
;;;      its certifier would not be caught by kkt-report alone).
;;;
;;;   3. THE CERTIFIED GAP-BOUND ACTUALLY BOUNDS THE GAP. Generalizes
;;;      test-kkt-verification.scm's check 4 (one hand-picked rig, brute-
;;;      force ground truth) to every random rig, using the solver's own
;;;      converged point as the ground-truth proxy for x* instead of a
;;;      brute-force grid search (which does not scale past 2 variables).
;;;      kkt-report(x) is called at points OTHER than the solved optimum —
;;;      the theorem is about every feasible x, not just the one the
;;;      solver happens to return, and testing only at the optimum would
;;;      leave the bulk of `suboptimality_bound`'s claim unexercised.
;;;
;;;   4. THE BACKENDS AGREE. `solve-native` (reference Scheme), `solve-
;;;      native-c` (compiled), `solve-native-c-pd` (Mehrotra primal-dual)
;;;      and `solve-osqp` (external QP library) are four independent
;;;      implementations of the same claim. This is the one property here
;;;      that targets the OMP/OSQP-boundary bug class directly — a CSR
;;;      indexing slip or FFI marshalling error in exactly one backend
;;;      would show up as disagreement, which none of the other three
;;;      properties above can see (they each exercise one backend alone).
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-property-solver-invariants.scm

(use-modules (localchimera test planner prelude)
             (localchimera solve solver)
             (srfi srfi-1)
             (ice-9 format))

;; fixed seed: reproducible across runs, still exercises many distinct shapes
(define %state (seed->random-state 20260819))
(define (rnd lo hi) (+ lo (* (- hi lo) (random 1.0 %state))))
(define (rnd-int lo hi) (+ lo (random (+ 1 (- hi lo)) %state)))

;; ── random rig generator ─────────────────────────────────────────────────
;; n variables, x ≥ 0 each, one shared hard cap (keeps the feasible region
;; bounded so solve-native's box-radius argument has something to bite on),
;; a desire per variable toward a random target, and — half the time — one
;; fragility term over a random pair, so both curved-form kinds get covered.
(define (random-rig n)
  (let* ((cap (rnd 8.0 30.0))
         (nonneg (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) (iota n)))
         (shared-cap (mk-bar cap (map (lambda (i) (cons i -1.0)) (iota n))))
         (desires (map (lambda (i)
                         (mk-des (mk-bar 0.0 (list (cons i 1.0)))
                                 (rnd 1.0 (/ cap n)) (rnd 5.0 300.0)))
                       (iota n)))
         (frag (if (and (> n 1) (< (random 1.0 %state) 0.5))
                   (let ((i (rnd-int 0 (- n 1))) (j (rnd-int 0 (- n 1))))
                     (list (mk-frag (* 0.6 cap)
                                    (list (cons i -1.0) (cons j -0.5)) (rnd 5.0 40.0))))
                   '())))
    (append nonneg (list shared-cap) desires frag)))

(define (random-labform n)
  (map (lambda (i) (cons i (rnd 0.01 0.5))) (iota n)))

;; a strictly-interior seed: small and uniform, well inside x ≥ 0 and the
;; shared cap regardless of its randomized value (cap is always ≥ 8, seed
;; sum is n · 0.05 ≪ 8)
(define (interior-seed n) (make-vector n 0.05))

;; unit vector in a uniformly random direction (Gaussian-ish via Box-Muller
;; would be more uniform on the sphere, but for a curvature spot-check
;; normalized-uniform-in-a-box is more than sufficient — it still samples
;; every axis and every sign)
(define (random-unit n)
  (let* ((raw (list->vector (map (lambda (_) (rnd -1.0 1.0)) (iota n))))
         (norm (sqrt (let lp ((i 0) (a 0.0)) (if (= i n) a (lp (+ i 1) (+ a (expt (vector-ref raw i) 2))))))))
    (if (< norm 1e-9) (random-unit n)               ; vanishingly unlikely, re-roll
        (let ((u (make-vector n 0.0)))
          (do ((i 0 (+ i 1))) ((= i n) u) (vector-set! u i (/ (vector-ref raw i) norm)))))))

(define (vadd a b s) (let* ((n (vector-length a)) (r (make-vector n))) ; a + s·b
  (do ((i 0 (+ i 1))) ((= i n) r) (vector-set! r i (+ (vector-ref a i) (* s (vector-ref b i)))))))

(define %n-rigs 10)
(define %n-directions 6)

(display "\n── property: strong-convexity-modulus is a real curvature lower bound ──\n")
(for-each
  (lambda (n)
    (let* ((forms (random-rig n)) (C (flatten forms)) (lab (random-labform n))
           (t 0.05) (x (interior-seed n)) (sv (term-values C x))
           (sigma (strong-convexity-modulus C n sv t)))
      (for-each
        (lambda (_)
          (let* ((v (random-unit n)) (h 1e-4)
                 (gp (csr-grad C lab t (term-values C (vadd x v h)) n))
                 (gm (csr-grad C lab t (term-values C (vadd x v (- h))) n))
                 ;; directional second derivative along v via central difference
                 ;; of the gradient's projection onto v: (∇f(x+hv)-∇f(x-hv))·v / 2h
                 (curv (/ (let lp ((i 0) (a 0.0))
                            (if (= i n) a
                                (lp (+ i 1) (+ a (* (- (vector-ref gp i) (vector-ref gm i))
                                                    (vector-ref v i))))))
                          (* 2.0 h))))
            (check (format #f "n=~a: curvature ~,4f ≥ reported σ=~,4f along a random direction" n curv sigma)
                   (>= curv (- sigma 1e-2)))))
        (iota %n-directions))))
  (map (lambda (_) (rnd-int 2 5)) (iota %n-rigs)))

(display "\n── property: solve-native's output is locally optimal ──\n")
(for-each
  (lambda (n)
    (let* ((forms (random-rig n)) (C (flatten forms)) (lab (random-labform n))
           (x0 (interior-seed n)))
      (call-with-values (lambda () (solve-native forms lab x0))
        (lambda (x . rest)
          (let* ((k (kkt-report C lab x))
                 (fx (obj-value C lab 1e-6 x (term-values C x))))
            (check (format #f "n=~a: solved point is reported feasible" n)
                   (assq-ref k 'feasible?))
            (for-each
              (lambda (_)
                (let* ((v (random-unit n)) (h 1e-4)
                       (xp (vadd x v h))
                       (svp (term-values C xp))
                       (ok (let lp ((ti 0))                   ; stays feasible under the step
                             (cond ((= ti (cnt C)) #t)
                                   ((and (memv (vector-ref (ckind C) ti) '(0 3))
                                         (< (vector-ref svp ti) 0.0)) #f)
                                   (else (lp (+ ti 1))))))
                       (fxp (and ok (obj-value C lab 1e-6 xp svp))))
                  (when ok
                    (check (format #f "n=~a: a small feasible step does not improve the objective" n)
                           (>= fxp (- fx 1e-3))))))
              (iota %n-directions)))))))
  (map (lambda (_) (rnd-int 2 5)) (iota %n-rigs)))

(display "\n── property: the certified gap-bound actually bounds the gap ──\n")
;; x* proxy: the solver's own converged point. Not brute-force ground truth,
;; but a sound one-directional check either way — if a REPORTED bound at some
;; other feasible x turns out smaller than x's true distance to this x_best,
;; the bound is unsound regardless of whether x_best is the true optimum.
(for-each
  (lambda (n)
    (let* ((forms (random-rig n)) (C (flatten forms)) (lab (random-labform n))
           (seed (interior-seed n)))
      (call-with-values (lambda () (solve-native forms lab seed))
        (lambda (xbest . rest)
          (let ((fbest (obj-value C lab 1e-9 xbest (term-values C xbest))))
            (for-each
              (lambda (frac)
                ;; a convex combination of two feasible points (the interior
                ;; seed and the solved optimum) stays feasible: every `bar`/
                ;; `frag` slack is affine in x, and both endpoints satisfy it.
                (let* ((xm (vadd seed (vadd xbest (vneg seed) 1.0) frac))
                       (svm (term-values C xm))
                       (fm (obj-value C lab 1e-9 xm svm))
                       (k (kkt-report C lab xm))
                       (bound (assq-ref k 'gap-bound))
                       (gap (- fm fbest)))
                  (check (format #f "n=~a frac=~,1f: certified bound is finite" n frac)
                         (< bound +inf.0))
                  (check (format #f "n=~a frac=~,1f: true gap ~,3e ≤ certified ~,3e" n frac gap bound)
                         (<= gap (+ bound 1e-6)))))
              '(0.3 0.6 0.9)))))))
  (map (lambda (_) (rnd-int 2 5)) (iota %n-rigs)))

(display "\n── property: the backends agree ──\n")
;; Four independent implementations of the same claim. Wrapped in `catch` so
;; one backend's failure is reported as a failed check, not a crash that
;; loses every other result in the run.
(define (try-solve name thunk)
  (catch #t
    (lambda () (call-with-values thunk (lambda (x . rest) (cons #t x))))
    (lambda (key . args) (cons #f (format #f "~a: ~a ~a" name key args)))))

;; OSQP has no log-barrier: a `frag` term becomes a hard cap at its tip
;; instead of a soft pull felt before it. `solve.scm`'s own dispatcher
;; (`solve`, lines 2450-2465/2496-2507) already documents this and routes
;; around `solve-osqp` whenever a `frag` term is present — reproduced there
;; with a measured example (x = 10.00013 on a tip of 10, reported solved).
;; Calling `solve-osqp` directly on a frag-carrying rig is not a fair
;; cross-backend comparison — it is asking OSQP to solve a DIFFERENT
;; program than the other three backends see — so this test mirrors the
;; same exclusion the dispatcher already encodes, rather than rediscovering
;; it as a false positive.
(define (has-frag? forms) (find (lambda (f) (eq? (f-kind f) 'frag)) forms))

(for-each
  (lambda (n)
    (let* ((forms (random-rig n)) (C (flatten forms)) (lab (random-labform n))
           (x0 (interior-seed n))
           (ref (try-solve "native" (lambda () (solve-native forms lab x0))))
           (c   (try-solve "native-c" (lambda () (solve-native-c forms lab x0))))
           (pd  (try-solve "native-c-pd" (lambda () (solve-native-c-pd forms lab x0))))
           ;; OSQP is an optional native library: absent (osqp-available? → #f)
           ;; the comparison is skipped, not failed — same convention as
           ;; test-osqp-frag-exclusion.scm's negative control.
           (osq (and (osqp-available?) (not (has-frag? forms))
                     (try-solve "osqp" (lambda () (solve-osqp forms lab n x0))))))
      (check (format #f "n=~a: reference backend solves" n) (car ref))
      (when (car ref)
        (let ((fref (obj-value C lab 1e-9 (cdr ref) (term-values C (cdr ref)))))
          (for-each
            (lambda (pair)
              (let ((label (car pair)) (result (cdr pair)))
                (when result                      ; #f for osqp when unavailable or on a frag rig
                  (check (format #f "n=~a: ~a backend solves" n label) (car result))
                  (when (car result)
                    (let* ((x (cdr result)) (kb (kkt-report C lab x))
                           (f (obj-value C lab 1e-9 x (term-values C x))))
                      (check (format #f "n=~a: ~a backend's solution is feasible" n label)
                             (assq-ref kb 'feasible?))
                      (check (format #f "n=~a: ~a backend's objective ~,4f agrees with reference ~,4f" n label f fref)
                             (< (abs (- f fref)) (+ 1e-3 (* 1e-3 (abs fref))))))))))
            (list (cons "native-c" c) (cons "native-c-pd" pd) (cons "osqp" osq)))))))
  (map (lambda (_) (rnd-int 2 5)) (iota %n-rigs)))

(check-done "  Property-based sweep passed: no random program broke a Layer-A postcondition.~%")
