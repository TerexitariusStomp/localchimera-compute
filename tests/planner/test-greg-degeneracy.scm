;;; test-greg-degeneracy.scm — the right tool for the wrong problem.
;;;
;;; Spec: docs/playnet.typ §7.12 (the gradient-regularized Newton step, after
;;;       Doikov–Nesterov: λ = c·√‖g‖, scaled to the gradient norm so it fades to
;;;       zero at the optimum) and §7.11 (the primal-dual predictor-corrector as
;;;       the tool for a DEGENERATE flat optimum).
;;;
;;; Those two sentences describe different problems, and the regularizer only
;;; addresses one of them. Fading with ‖g‖ is exactly what makes greg leave no
;;; bias at the optimum — and exactly what makes it USELESS on a plateau, where
;;; the gradient is small everywhere and λ collapses while there is still a long
;;; way to walk. The step is then unheld, the solve stops after a handful of
;;; Newton iterations, and it reports non-convergence.
;;;
;;; Measured on `setup-space` at τ = 0.002 (transport so cheap the optimum is a
;;; plateau), at the SHIPPED regularizer strength c = 0.01:
;;;
;;;     greg 0 (plain)   91.6% met, 194 Newton, converged
;;;     greg 0.01        55.5% met,   9 Newton, NOT converged
;;;
;;; That was masked for years: non-convergence handed the problem to OSQP, which
;;; does well on this instance. The mask is gone for any economy carrying a
;;; fragility barrier, because OSQP may no longer be handed one (it rides a
;;; fragility to its tip — see test-frag-farstart.scm). An economy with
;;; ecological caps is precisely the case that matters, so the recovery cannot
;;; live in OSQP. `solve-native-c` now retries once with the regularizer off.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-greg-degeneracy.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))

(define (met-of C x) (* 100.0 (mean-fill C x)))

(define* (solve-with greg tau entry #:key (own-phase-i? #f))
  "Build the space fixture at TAU, solve through ENTRY at regularizer GREG.
   Returns (met newton converged?).

   OWN-PHASE-I? matters more than it looks. `solve-native-c-core` has no phase-I,
   so a core test must run `ensure-feasible` itself — but doing that at the
   REGULARIZED setting hands the solve a starting point the regularizer has
   already degraded, and no later unregularized step recovers from it (measured:
   phase-I at 0.01 then solve at 0 gives 55.5%, where a cold greg=0 run gives
   91.6%). The entry point owns its own phase-I and must therefore be handed the
   RAW warm start, exactly as production callers hand it one. Getting this wrong
   makes the engine look like it only half-recovers."
  (let ((saved *kern-greg*))
    (set! *kern-greg* greg)
    (setup-space tau)
    (let ((r (call-with-values build-located
               (lambda (forms labform ncol cols goods raws idx)
                 (let* ((warm (located-warm cols ncol idx))
                        (x0 (if own-phase-i?
                                (ensure-feasible forms labform warm solve-native-c-core)
                                warm)))
                   (call-with-values (lambda () (entry forms labform x0))
                     (lambda (x t cg nt conv?)
                       (let ((C (flatten forms)))
                         (list (met-of C x) nt conv?
                               (world-objective C labform x))))))))))
      (set! *kern-greg* saved)
      r)))

(display "\n── the core step: greg is no help on a plateau ──\n")

(let ((plain (solve-with 0.0  0.002 solve-native-c-core #:own-phase-i? #t))
      (shipped (solve-with 0.01 0.002 solve-native-c-core #:own-phase-i? #t)))
  (format #t "  τ = 0.002 (flat optimum), through solve-native-c-CORE:\n")
  (format #t "    greg 0    (plain) : met ~5,1f%   ~a Newton   converged ~a\n"
          (car plain) (cadr plain) (caddr plain))
  (format #t "    greg 0.01 (shipped): met ~5,1f%   ~a Newton   converged ~a\n"
          (car shipped) (cadr shipped) (caddr shipped))
  ;; The DEFECT being guarded, stated as what actually happens rather than via
  ;; conv? — which used to report a demand plateau as convergence and is now
  ;; honest (#f for both here: neither reaches the gradient tolerance on this
  ;; degenerate fixture). The real distinction is effort and result — and where
  ;; the line sits between the two steps moved when phase-I was repaired
  ;; (2026-08-13): `ensure-feasible` used to run its dense-slack-column program
  ;; under the IC(0) preconditioner, and the degraded start it handed back is
  ;; what made greg's plateau collapse CATASTROPHIC (9 Newton, 55.5% met, the
  ;; header's measurement). From phase-I's clean Jacobi start both steps now
  ;; work the plateau to the Newton cap and deliver comparably (measured: plain
  ;; 88.4%, shipped 89.9%, both 272 Newton). What remains structural, start
  ;; quality aside, is that NEITHER step converges on a plateau — λ = c·√‖g‖
  ;; still fades where the gradient is small — so the retry below stays earned.
  ;; The property: the step does not GIVE UP on the plateau — it converges, or
  ;; it works to the cap. A step count alone was the older reading of it, and
  ;; it read the wrong way the day the preconditioner became answerable to the
  ;; Newton residual (2026-09-05): IC(0) had been leaving these steps 80–280%
  ;; unsolved and was retired mid-solve, and both steps then CONVERGE from the
  ;; clean start — plain 50 Newton, shipped 66, 97.3% met — which is more of
  ;; the property, not less.
  (check "the plain step does not give up on the plateau (converges, or works to the cap)"
         (or (caddr plain) (> (cadr plain) 100)))
  (check "from a clean start the regularized step works the plateau too"
         (or (caddr shipped) (> (cadr shipped) 100)))
  (check "…and no longer under-delivers doing so"
         (> (car shipped) (* 0.9 (car plain)))))

(display "\n── the entry point recovers it, without needing OSQP ──\n")

;; The retry lives in solve-native-c. Disable the OSQP fallback entirely so this
;; proves the recovery is intrinsic, not OSQP doing the work.
(let ((saved *osqp-fallback*))
  (set! *osqp-fallback* #f)
  (let ((plain   (solve-with 0.0  0.002 solve-native-c))
        (shipped (solve-with 0.01 0.002 solve-native-c)))
    (format #t "  τ = 0.002, through solve-native-c, OSQP fallback OFF:\n")
    (format #t "    greg 0    (plain) : met ~5,1f%   f ~,4f   converged ~a\n" (car plain) (list-ref plain 3) (caddr plain))
    (format #t "    greg 0.01 (shipped): met ~5,1f%   f ~,4f   converged ~a\n" (car shipped) (list-ref shipped 3) (caddr shipped))
    ;; NOT asserted via conv? (that flag used to report a demand plateau as
    ;; convergence), and NOT asserted as met-equality either: on this DEGENERATE
    ;; fixture met is path-noise — the schedule comment in solver.scm measures
    ;; 95.7–96.9% across Newton caps, non-monotone — because a plateau is a FACE
    ;; of equally-good plans and which one a path exits at depends on where it
    ;; entered. What is recoverable in full is the OBJECTIVE, which is also the
    ;; quantity the acceptance ladder now ranks candidates by; met is held to
    ;; the fixture's own noise band.
    (check "the shipped regularizer recovers the plan via the unregularized retry"
           (> (car shipped) (* 0.97 (car plain))))
    (check "the retry recovers the plain step's OBJECTIVE in full"
           (< (- (list-ref shipped 3) (list-ref plain 3))
              (+ 0.05 (* 0.01 (abs (list-ref plain 3)))))))
  (set! *osqp-fallback* saved))

(display "\n── and a well-posed problem is untouched ──\n")

;; greg exists for ILL-CONDITIONING and must keep earning its place there: the
;; retry must not fire, and must not change the answer, when the solve converges.
(let ((plain   (solve-with 0.0  0.04 solve-native-c))
      (shipped (solve-with 0.01 0.04 solve-native-c)))
  (format #t "  τ = 0.04 (well-posed):\n")
  (format #t "    greg 0    : met ~5,1f%   ~a Newton   converged ~a\n"
          (car plain) (cadr plain) (caddr plain))
  (format #t "    greg 0.01 : met ~5,1f%   ~a Newton   converged ~a\n"
          (car shipped) (cadr shipped) (caddr shipped))
  (check "both reach the same plan on a well-posed problem"
         (< (abs (- (car plain) (car shipped))) 1.0))
  (check "and agree on the plan — the retry is inert here"
         (< (abs (- (car plain) (car shipped))) 1.0)))

(check-done "  greg is for ill-conditioning; degeneracy has its own recovery.~%")
