;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-osqp-frag-exclusion.scm — the `solve` dispatcher actually excludes
;;; OSQP whenever a `frag` term is present, not just documents that it should.
;;;
;;; solver.scm's `solve` dispatcher (§6) carries two hand-written exclusions —
;;; one in the `osqp` backend case, one in `auto`'s qc-free/sparse branch —
;;; each citing the same reproduction: OSQP has no log-barrier, so a
;;; fragility term becomes a hard cap AT its tip instead of a pull felt
;;; before it (measured there: tip 10, true optimum 9.0840, OSQP returns
;;; 10.0001 and reports converged).
;;;
;;; `tests/solve/test-property-solver-invariants.scm`'s cross-backend
;;; property check found this exact failure mode directly — by calling
;;; `solve-osqp` itself, bypassing the dispatcher entirely, which is a
;;; correct thing for a low-level backend-agreement check to do but proves
;;; nothing about whether `solve`'s ROUTING actually protects a normal
;;; caller. Nothing else in the suite calls `solve` (the public entry
;;; point) with a fragility-carrying program and confirms it does NOT ride
;;; the tip — this file closes that gap, three ways:
;;;
;;;   1. `*backend* 'osqp`, explicitly requested, on a frag rig: the result
;;;      must match `solve-native`'s optimum, not OSQP's tip-riding one —
;;;      proving the reroute actually happened, not just that OSQP was
;;;      asked nicely.
;;;   2. `*backend* 'auto` (the actual default in production) on the same
;;;      rig: same check, for the path most callers actually take.
;;;   3. The reroute is LOUD by design ("made LOUDLY rather than silently"
;;;      — solver.scm:2456) — captured here so a refactor that silently
;;;      drops the warning while still functionally rerouting is also
;;;      caught, not just a silent behavior change.
;;;
;;; And the negative control every routing test needs: on a NON-frag rig,
;;; `*backend* 'osqp` must actually reach OSQP (checked via `*osqp-last*`,
;;; only ever set by `solve-osqp` itself) — otherwise a dispatcher that
;;; always skips OSQP for any reason would pass 1-3 vacuously.
;;;
;;; The frag rig (tip 10, want 9.0839543) is test-frag-farstart.scm's own —
;;; the exact reproduction solver.scm's comments cite, reused rather than
;;; re-derived.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-osqp-frag-exclusion.scm

(use-modules (playnet test planner prelude)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))

(define want 9.0839543)                       ; test-frag-farstart.scm's known optimum
(define tip-riding 10.0001)                   ; what OSQP alone does to this rig (solver.scm:2482 comment)
(define (frag-rig) (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)
                          (mk-frag 10.0 (list (cons 0 -1.0)) 50.0)
                          (mk-bar 0.0 '((0 . 1.0)))))
(define (plain-rig) (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 8.0 300.0)
                           (mk-bar 20.0 '((0 . -1.0)))
                           (mk-bar 0.0 '((0 . 1.0)))))

(define (x0-at v) (vector v))

;; ── 1. explicit 'osqp backend reroutes on a frag rig ────────────────────────
(set-backend! 'osqp)
(let* ((x #f)
       (out (with-error-to-string
              (lambda ()
                (set! x (call-with-values (lambda () (solve (frag-rig) '() (x0-at 5.0))) list)))))
       (got (vector-ref (car x) 0)))
  (check (format #f "explicit osqp backend on frag rig: got ~,4f, near the true optimum ~,4f" got want)
         (< (abs (- got want)) 0.05))
  (check (format #f "…and NOT riding the tip at ~,4f" tip-riding)
         (> (abs (- got tip-riding)) 0.5))
  (check "the reroute is announced (not silent)"
         (and (string-contains out "using native-c") #t)))

;; ── 2. the default 'auto backend reroutes likewise ──────────────────────────
(set-backend! 'auto)
(let* ((x (call-with-values (lambda () (solve (frag-rig) '() (x0-at 5.0))) list))
       (got (vector-ref (car x) 0)))
  (check (format #f "auto backend on frag rig: got ~,4f, near the true optimum ~,4f" got want)
         (< (abs (- got want)) 0.05))
  (check (format #f "…and NOT riding the tip at ~,4f" tip-riding)
         (> (abs (- got tip-riding)) 0.5)))

;; ── 3. negative control: OSQP is actually reached on a non-frag rig ────────
;; Otherwise checks 1-2 would pass even if the dispatcher skipped OSQP for
;; some unrelated reason (or always, which would make this whole file test
;; nothing about frag specifically).
(when (osqp-available?)
  (set! *osqp-last* #f)
  (set-backend! 'osqp)
  (call-with-values (lambda () (solve (plain-rig) '() (x0-at 1.0))) list)
  (check "explicit osqp backend on a NON-frag rig actually reaches solve-osqp"
         (pair? *osqp-last*)))

(set-backend! 'auto)   ; leave dispatcher state as found
(check-done "  The dispatcher's frag/OSQP exclusion is enforced, not just documented.~%")
