;;; test-ladder-rescue.scm — the solve returns the best plan anyone produced,
;;; never the seed it started from.
;;;
;;; A spanning-structure program (a 72 h run's output landing two bands
;;; downstream, storage chains between) leaves the capped Newton path short of
;;; centring, and every candidate — native by phase-I's own relaxation noise
;;; (~1e-5, the s* every downstream point inherits), OSQP by its ADMM eps —
;;; used to fail a 1e-9 feasibility judgment. The ladder then discarded them
;;; ALL and returned the PHASE-I SEED: fill 0.18 with demand 5, while OSQP's
;;; discarded plan held 1.000. Three fixes, each pinned here:
;;;
;;;   · %feasible-tol states the solver family's own floor (3e-5 of form
;;;     scale), not a float-noise fiction four orders below what phase-I
;;;     itself achieves
;;;   · OSQP converges to 1e-6, so a rescue plan lands INSIDE that band
;;;   · when no certificate bound is finite (unbounded box + one flat
;;;     direction — the common located shape), tied candidates rank by the
;;;     WORLD objective (des/qc/held/frag + κ·labour, no bar terms: a bar is
;;;     a constraint, and its guarded φ scores 1e12 per BINDING constraint —
;;;     exactly where an optimum sits)
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-ladder-rescue.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PLACE "yard")
(define procs (list (rp* "F" "Ferment" 72) (rp* "B" "Bottle" 2)))
(define flows (list (consume* "f-in" "mash" 1.0 "F") (out* "f-out" "brew" 1.0 "F") (wk* "f-w" "skill-f" 6.0 "F")
                    (consume* "b-in" "brew" 1.0 "B") (out* "b-out" "bottled" 1.0 "B") (wk* "b-w" "skill-b" 2.0 "B")))
(define (held id spec q) (er id spec #f #:place PLACE #:qty q #:unit "kg"))
(define (skill id sk who) (er id sk who #:place PLACE #:unit %count-unit))
(define agents (list (person* "fio" #:place PLACE #:window (all-week-window "00:00" "24:00"))
                     (person* "bo"  #:place PLACE #:window (all-week-window "00:00" "24:00"))))
(define spatials (list (place* PLACE)))

(define* (fill-at want at q #:key (per-agent? #f))
  (call-with-values
    (lambda ()
      (plan-from-records
       (list (held "mash-1" "mash" 100.0)
             (skill "s1" "skill-f" "fio") (skill "s2" "skill-b" "bo"))
       agents spatials procs flows
       #:horizon (cons "2026-03-03" 4)
       #:storable '("brew" "bottled")
       #:agent-skills (lambda (a) (if (string=? (agent-id a) "fio") '("skill-f") '("skill-b")))
       #:demand (list (cons (format #f "~a#~a@~a" want PLACE at) q))
       #:per-agent? per-agent? #:backend 'native-c #:allow-infeasible? #t))
    (lambda args (list-ref args 3))))

(format #t "~%── the measured case: demand at scale, through the default backend ──~%")
(check "five units of a spanning run's output are DELIVERED, not 0.18 of them"
       (> (fill-at "brew" 2 5.0) 0.9))
(check "two units likewise" (> (fill-at "brew" 2 2.0) 0.9))
(check "…and the chained product at scale" (> (fill-at "bottled" 2 5.0) 0.9))

(format #t "~%── per-agent EMP: the frozen start, thawed ──~%")
;; qc forms gate the OSQP rescue, so the per-agent path exposed the deeper bug
;; naked: phase-I's point is exterior by its relaxation floor, and outside the
;; wall the guarded barrier is FLAT (phi = 1e12, phi' = 0) — a fixed point of
;; the whole Newton path. The attempts now solve the program relaxed by the
;; start's own deficit (strictly interior there), certified against the true
;; one. Before: one unit of five, both attempts returning the seed untouched.
(check "five units deliver through per-agent EMP labour too"
       (> (fill-at "brew" 2 5.0 #:per-agent? #t) 0.9))

(format #t "~%── honesty holds: what cannot exist is still not promised ──~%")
(check "demanded before the run can finish, the fill is still ~zero"
       (< (fill-at "brew" 1 5.0) 0.1))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
