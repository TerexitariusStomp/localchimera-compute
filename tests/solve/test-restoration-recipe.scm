;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-restoration-recipe.scm — recovery is LABOUR, and the plan schedules it.
;;;
;;; A bay whose reef is ALREADY past its tip: condition 60 where 100 is the wall.
;;; The question a crossed boundary raises is not only "stop taking" — it is "what
;;; would it cost to come back", and that is a question about labour.
;;;
;;; Restoration is therefore a RECIPE, not a property of the boundary. Two
;;; processes rebuild the reef's condition, and the difference between them is
;;; the whole point:
;;;
;;;   REGROWTH   — nature's own work. Produces condition at a rate nature sets,
;;;                capped per period, for almost no labour. Most of the recovery
;;;                comes from here.
;;;   RESTORATION — human work. Produces more condition per run, and costs real
;;;                hours that compete with fishing and with everything else.
;;;
;;; So irreversibility needs no flag: a boundary is one-way exactly when no recipe
;;; produces its condition. Absorbing is the ABSENCE of a recipe, and what can be
;;; restored is just what the recipe library says can be restored — derived, like
;;; everything else, rather than asserted on a profile.
;;;
;;; The plan must feed the household EVERY period (fishing draws the reef down)
;;; and stand the reef back above its wall by the last one. Nothing tells it to
;;; restore; it is simply the cheapest way to still be feasible at the end.
;;;
;;; This is the oven's maintenance, read at the scale of a bay: localchimera.typ has
;;; "a durable's CONDITION is a stock GOOD; wear is a `consume` flow, maintenance
;;; a `produce` flow" — and §The categories of social reproduction says the body's
;;; floors, the soil's envelope and the tool's condition are ONE barrier at three
;;; scales. A reef is that same object.
;;;
;;; Run: guile --no-auto-compile -L module/localchimera/planner \
;;;        tests/solve/test-restoration-recipe.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve plan)
             (localchimera vf schemas)
             (localchimera knowledge dsl shorthand)
             (localchimera vf formulas stocks))

(define *pass* 0) (define *fail* 0)
(define (check-pred name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define SEASONS '(0 1 2 3))
(define TIP     100.0)     ; the wall the reef sits below
(define START    60.0)     ; already crossed — the state of the world we inherit
(define FOOD     40.0)     ; kcal the household needs each season

;; A period here is a WEEK: the roster's window every day is 56 h a period, the
;; labour this restoration was sized on, and the same on any date.
(set-period-length! 1.0 "week")
(define win (all-week-window "09:00" "17:00"))
(define agents (list (person* "ada" #:name "Ada" #:place "bay" #:window win)))
(define spatials (list (place* "bay")))

;; the reef's condition as a regenerating stock: a level that carries in time
(define reef (make-regenerating-stock "reef-condition" "Reef condition" "bay" START))
(clear-regenerating-stocks!)
(register-regenerating-stock! reef)

(define resources
  (cons (er "sk" "skill-sea" "ada" #:place "bay" #:unit "kg")
        (regenerating-stock-resources)))

(define procs
  (list (rp* "fish"    "Fish the reef")
        (rp* "regrow"  "Natural regrowth")
        (rp* "restore" "Reef restoration")))

(define flows
  (list
   ;; FISH: draws the reef down, feeds the household
   (out* "k" "kcal" 10.0 "fish" "kcal")
   (stock-draw-flow  "d" "reef-condition" 2.0 "fish" "fishing wears the reef")
   (wk* "w" "skill-sea" 1.0 "fish")
   ;; REGROWTH: nature's work — rate-capped, almost no labour
   (stock-restore-flow "r1" "reef-condition" 3.0 "regrow" "the reef rebuilding itself")
   (consume* "rc" "regrowth-rate" 1.0 "regrow" "unit")
   (wk* "rw" "skill-sea" 0.01 "regrow")
   ;; RESTORATION: human work — more condition per run, real hours
   (stock-restore-flow "r2" "reef-condition" 6.0 "restore" "planting, clearing, tending")
   (wk* "sw" "skill-sea" 3.0 "restore")))

;; nature's rate: one regrowth run per season, no more
(define regrowth-cap (map (lambda (t) (cons (format #f "regrowth-rate#bay@~a" t) 1.0)) SEASONS))
;; the household eats every season; the reef must stand back above its wall by the last
(define floors
  (append (map (lambda (t) (cons (format #f "kcal#bay@~a" t) FOOD)) SEASONS)
          (list (cons (format #f "reef-condition#bay@~a" (last SEASONS)) TIP))))

(define (run label recovery-target?)
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:periods SEASONS
                 #:storable (regenerating-stock-storables)
                 #:eco-caps regrowth-cap
                 #:repro-floors (if recovery-target?
                                    floors
                                    (map (lambda (t) (cons (format #f "kcal#bay@~a" t) FOOD)) SEASONS))
                 #:per-agent? #f #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (let* ((act (lambda (p t) (let ((i (hash-ref idx (format #f "p|~a|bay@~a" p t) #f)))
                                  (if i (vector-ref x i) 0.0))))
             (restore-runs (map (lambda (t) (act "restore" t)) SEASONS))
             (restore-hours (* 3.0 (fold + 0.0 restore-runs)))
             (regrow-runs  (map (lambda (t) (act "regrow" t)) SEASONS))
             (feasible (assq-ref (assq-ref report 'certificate) 'feasible?)))
        (format #t "  ~a~%" label)
        ;; the SUM is printed unrounded beside the per-season rounding, because
        ;; it is the number the checks below read: rounding it away is how a
        ;; failure on another machine read as `(0.0 0.0 0.0 0.0)` and looked
        ;; like a passing case.
        (format #t "    natural regrowth runs : ~a  (Σ ~,4f)~%"
                (map (lambda (v) (round v)) regrow-runs) (fold + 0.0 regrow-runs))
        (format #t "    restoration runs      : ~a   (~,1f h of labour)~%"
                (map (lambda (v) (round v)) restore-runs) restore-hours)
        (format #t "    feasible              : ~a~%" feasible)
        (list restore-hours (fold + 0.0 regrow-runs) feasible)))))

(format #t "~%── a reef already past its tip (~,0f of ~,0f), fished every season ──~%" START TIP)
(define without (run "no recovery target — just keep eating:" #f))
(define with-t  (run "recovery target: stand above the wall by the last season:" #t))

;; "no restoration" reads as a small residual rather than a hard zero: an interior
;; -log barrier never sits exactly at its bound, so every column carries a little
;; activity. An order of magnitude below the targeted plan is the honest test.
(check-pred "with no target, the plan spends essentially no restoration labour"
            (< (first without) (* 0.2 (first with-t))))

;; ── what "nearly free" actually buys ────────────────────────────────────────
;; Regrowth costs 0.01 h and produces condition nobody has asked for, so with no
;; recovery target the plan leaves the reef alone: cheap is not a reason to do
;; work that serves nothing, and a plan that ran it anyway would be spending the
;; commons' hours to move a number.
;;
;; Where "nearly free" is felt is in the ORDER the plan reaches for the two
;; recipes. Under a target it takes nature's whole allowance — every season's
;; cap, all four of them — before spending one human hour, and human work covers
;; only what is left. That is the arithmetic, and it is exact:
;;
;;   fishing draws  4 runs/season × 2.0 × 4 seasons        = 32
;;   the wall asks  60 → 100                               = 40
;;   so the plan must produce                                72 condition
;;   nature gives   3.0 × 4 runs (its cap)                 = 12
;;   people give    6.0 × 10 runs → 30.0 h                 = 60
;;
;; The old check here read "regrowth runs either way", which was true only while
;; the path floor left every column a surplus large enough to look deliberate.
;; With the floor derived from the certified gap that surplus is gone, and what
;; the fixture actually demonstrates is the priority, not the ubiquity.
(check-pred "with nothing to restore, the plan lets the reef be"
            (< (second without) 0.1))
(check-pred "under a target, nature's whole allowance is taken first"
            (> (second with-t) 3.9))          ; the cap is 1/season over 4 seasons
(check-pred "…and human labour covers exactly the remainder"
            (< (abs (- (first with-t) 30.0)) 0.5))
(check-pred "a recovery target makes the plan SCHEDULE restoration labour"
            (> (first with-t) 1.0))
(check-pred "…and the recovery plan is a real plan" (eq? #t (third with-t)))
;; The point: no rule said "restore". Recovery is what staying feasible COSTS
;; once the boundary is due back above its wall — the same arithmetic that makes
;; crop rotation emerge in soil-recurrence-test, read at the scale of a bay.
(check-pred "restoration is labour the plan chose, not a property it was given"
            (> (first with-t) (first without)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — recovery is LABOUR the plan schedules, and what can be\n  restored is exactly what a recipe produces. Absorbing = no recipe.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
