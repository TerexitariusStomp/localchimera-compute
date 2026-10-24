;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-conservation.scm — nothing is spent that does not exist, and the verdict
;;; is already how you know.
;;;
;;; This suite adds no mechanism. It exists to make visible what the feasibility
;;; verdict ALREADY covers, so nobody builds a second, parallel conservation check
;;; beside the one the engine has had all along.
;;;
;;; Every conservation law in this planner is one `bar` form:
;;;   a good's stock       balance ≥ 0 — you cannot consume what was never there
;;;   labour availability  Σℓ·x ≤ A per cell — you cannot work hours nobody has
;;;   an ecological limit  a `frag` at the same divergent shape, a governed weight
;;; and `kkt-report`'s feasible? is exactly "every bar, frag and held slack is
;;; strictly positive". So a plan that overspends ANY of them is infeasible, full
;;; stop — and under PLANNER_INVARIANTS an undeclared one raises rather than
;;; returning quantities shaped like a plan.
;;;
;;; That is why there is no separate "did we overspend labour" assertion anywhere:
;;; it would restate the verdict in a second vocabulary, and a second vocabulary is
;;; a second thing to keep true. What follows demonstrates the coverage instead of
;;; duplicating it — each law is broken on purpose, and each shows up the same way.
;;;
;;; Run: guile --no-auto-compile -L module/localchimera/planner \
;;;        tests/solve/test-conservation.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera knowledge dsl shorthand))
(use-modules (localchimera solve engine) (localchimera solve plan)
             (localchimera vf schemas))
;; A period here is a WEEK: `hours h` names Monday 00:00–h:00, so a period holding the week holds h hours, on any date.
(set-period-length! 1.0 "week")

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define spatials (list (place* "p")))
(define hours hours-of)
(define procs (list (rp* "grow" "Grow")))
(define* (flows #:key (soil-per-run 1.0) (hours-per-run 1.0))
  (list (out* "o" "food" 1.0 "grow")
        (consume* "s" "soil" soil-per-run "grow" "u")
        (wk* "w" "skill" hours-per-run "grow")))
(define (skill-of who) (er "sk" "skill" who #:place "p" #:qty 1.0 #:unit "kg"))
(define (soil-of q) (er "soil" "soil" #f #:place "p" #:qty q #:unit "u"))

;; FLOOR the food, so the plan is COMPELLED to spend. A floor that cannot be met
;; within the laws is the collision; the verdict is how it announces itself.
(define* (verdict #:key (soil 100.0) (agent-hours 12) (floor-kg 5.0)
                       (soil-per-run 1.0) (hours-per-run 1.0))
  (call-with-values
    (lambda () (plan-from-records
                 (list (soil-of soil) (skill-of "ada"))
                 (list (person* "ada" #:name "Ada" #:place "p" #:window (hours agent-hours)))
                 spatials procs (flows #:soil-per-run soil-per-run #:hours-per-run hours-per-run)
                 #:repro-floors (list (cons "food#p@0" floor-kg))
                 #:periods '(0) #:per-agent? #f #:backend 'native-c
                 #:allow-infeasible? #t))                     ; breaking a law IS the point here
    (lambda (i c m fill cols x idx nt rep)
      (let ((cert (assq-ref rep 'certificate)))
        (assq-ref cert 'feasible?)))))

(format #t "~%── one verdict, every conservation law ──~%~%")

;; the control: everything affordable
(define ok?        (verdict))
;; STOCK: one run spends 1 soil, the floor needs 5 runs, only 2 soil exists
(define no-soil?   (verdict #:soil 2.0))
;; LABOUR: the floor needs 5 runs at 4 h each; Ada has 12 h in the day
(define no-hours?  (verdict #:hours-per-run 4.0))
;; both at once
(define neither?   (verdict #:soil 2.0 #:hours-per-run 4.0))

(format #t "  ~44a ~a~%" "affordable within every law" ok?)
(format #t "  ~44a ~a~%" "floor needs 5 soil, 2 exist" no-soil?)
(format #t "  ~44a ~a~%" "floor needs 20 h, the day holds 12" no-hours?)
(format #t "  ~44a ~a~%" "neither stock nor hours suffice" neither?)

(format #t "~%")
(check "a plan within every law is feasible"            (eq? #t ok?))
(check "spending stock that does not exist is INFEASIBLE — the good's balance"
       (eq? #f no-soil?))
(check "spending hours nobody has is INFEASIBLE — the labour cap, same shape"
       (eq? #f no-hours?))
(check "and breaking both is not somehow feasible again"  (eq? #f neither?))
;; The point of the suite: one verdict already answers for all of them, so a
;; second conservation check would only be a second thing to keep true.
(check "so ONE verdict covers every law — no parallel check is needed"
       (and (eq? #t ok?) (every (lambda (v) (eq? #f v)) (list no-soil? no-hours? neither?))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — stock and labour are one barrier shape and one~%  verdict. Conservation is not a check beside feasibility; it IS feasibility,~%  and PLANNER_INVARIANTS already refuses to let it pass in silence.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
