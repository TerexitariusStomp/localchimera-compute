;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-pd-finiteness.scm — a plan must be made of numbers.
;;;
;;; Spec: docs/localchimera.typ §7.11 (the primal-dual predictor-corrector clears the
;;;       degenerate flat optimum that stalls a plain path-follower).
;;;
;;; Mehrotra's predictor-corrector is exactly the right tool for a DEGENERATE
;;; optimum — a flat plateau where many allocations score alike. But on a badly
;;; flat instance it can run to its iteration cap and return NON-FINITE
;;; activities instead of a plan. Measured on the near-free-transport fixture
;;; (`setup-space` at τ = 0.002, where transport is so cheap the optimum is a
;;; plateau): 80 iterations, 12 NaNs in the activity vector, mean-fill NaN —
;;; while the primal path-follower returns a finite plan on the same problem.
;;;
;;; Nothing downstream checks. A NaN plan is not a loud failure: it is a
;;; number-shaped absence that flows into the rollup, into credit, and into every
;;; report, comparing false against every threshold it meets. The certificate is
;;; worth nothing if the vector it certifies is not real.
;;;
;;; So `solve-native-c-pd` now verifies its result and falls back to the primal
;;; core when the step has diverged. This test pins BOTH halves: the guard fires
;;; on the degenerate fixture, and it does not interfere on a well-posed one.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-pd-finiteness.scm

(use-modules (localchimera test planner prelude)
             (localchimera solve engine) (localchimera test planner worked-example)
             (localchimera solve solver)
             (srfi srfi-1)
             (ice-9 format))

(define (finite? v) (and (real? v) (= v v) (< (abs v) 1e300)))
(define (non-finite-count v)
  (let lp ((i 0) (n 0))
    (if (= i (vector-length v)) n
        (lp (+ i 1) (if (finite? (vector-ref v i)) n (+ n 1))))))

(define (built tau)
  "Build the space fixture at TAU and return (forms labform x0 C)."
  (setup-space tau)
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((x0 (ensure-feasible forms labform (located-warm cols ncol idx)
                                 solve-native-c-core)))
        (list forms labform x0 (flatten forms))))))

(define (pd-result tau)
  (let ((b (built tau)))
    ;; FOUR values: the plan, the iteration count, the duality gap, and the DUAL
    ;; itself. The certificate travels with the plan (test-certificate.scm), and
    ;; the dual with the gap — a residual measured against a reconstructed dual
    ;; reads eight orders too large (§ task 18). Bound loosely so a future value
    ;; added here does not break this test a third time.
    (call-with-values (lambda () (solve-native-c-pd (car b) (cadr b) (caddr b)))
      (lambda (x iters . rest) (list x iters (cadddr b) (and (pair? rest) (car rest)))))))

(display "\n── a degenerate flat optimum must still yield a real plan ──\n")

(let* ((r    (pd-result 0.002))
       (x    (car r))
       (bad  (non-finite-count x))
       (met  (* 100.0 (mean-fill (caddr r) x))))
  (format #t "  τ = 0.002 (near-free transport ⇒ plateau)\n")
  (format #t "    non-finite activities: ~a of ~a\n" bad (vector-length x))
  (format #t "    mean-fill:             ~,1f%\n" met)
  (check "the returned plan is entirely finite — the guard caught the divergence"
         (= bad 0))
  (check "…and its mean-fill is therefore a real number"
         (finite? met))
  (check "…and it delivers something rather than nothing"
         (> met 0.0)))

(display "\n── and the guard does not disturb a well-posed solve ──\n")

(let* ((r   (pd-result 0.04))
       (x   (car r))
       (bad (non-finite-count x))
       (met (* 100.0 (mean-fill (caddr r) x))))
  (format #t "  τ = 0.04 (transport priced ⇒ well-posed)\n")
  (format #t "    non-finite activities: ~a of ~a\n" bad (vector-length x))
  (format #t "    mean-fill:             ~,1f%   iters ~a\n" met (cadr r))
  (check "a well-posed problem is finite as it always was" (= bad 0))
  (check "converges in a handful of primal-dual steps (no fallback needed)"
         (< (cadr r) 40))
  ;; RELATIONAL, not a magnitude. "25.0" was whatever this fixture happened to
  ;; deliver the day it was written; what the test means is "the primal-dual does
  ;; as well as the plain step here", and that survives any change to the fixture.
  (let ((primal (call-with-values
                    (lambda () (let ((b (built 0.04)))
                                 (solve-native-c-core (car b) (cadr b) (caddr b))))
                  (lambda (x . _) (* 100.0 (mean-fill (cadddr (built 0.04)) x))))))
    (format #t "    primal core on the same fixture: ~,1f%\n" primal)
    (check "and delivers what the plain step delivers, on the same fixture"
           (> met (* 0.95 primal)))))

;; The general property, stated once: whatever route `solve` takes — primal,
;; primal-dual, OSQP, or a fallback between them — the vector it hands back is a
;; plan, and a plan is made of numbers.
(display "\n── the property, over every backend ──\n")
(for-each
  (lambda (backend)
    (set! *backend* backend)
    (let* ((b (built 0.002))
           (x (car (call-with-values
                     (lambda () (solve (car b) (cadr b) (caddr b))) list))))
      (check (format #f "~a returns a finite plan on the degenerate fixture" backend)
             (= (non-finite-count x) 0))))
  '(native native-c native-pd auto))
(set! *backend* 'auto)

(check-done "  A plan is made of numbers, by every route into the solver.~%")
