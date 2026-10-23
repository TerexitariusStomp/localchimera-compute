;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-closed-day-labour.scm — a day nobody works is a day nothing is made.
;;;
;;; A world that declares no partition stands on the standing one, laid from
;;; TODAY (engine standing-partition). A crew whose availability window is
;;; closed today therefore offers no hours, and the per-agent roster comes out
;;; empty. A declared roster routes labour through Lab|skill|cell GOODS however
;;; many people have hours (engine *roster-labour?*), so a skill nobody supplies
;;; is an unsourced input and the prune removes every column that needs it —
;;; the rule that already stops a recipe whose soil nobody has. Read off the
;;; roster's length instead, labour fell back to the aggregate per-cell cap,
;;; where an absent entry is an uncapped one: the plan baked a day's bread with
;;; nobody at work, and emitted no work.
;;;
;;; The window is built from today's weekday, so the suite reads the same on
;;; every day of the week. Fixture: (playnet test planner bread).
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/scope/test-closed-day-labour.scm

(use-modules (playnet test harness)
             (playnet vf schemas) (playnet vf beyond schedules) (srfi srfi-11)
             (playnet scope live)
             (playnet test planner bread)
             ((playnet utils clock) #:select (now instant->civil))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define week '(monday tuesday wednesday thursday friday saturday sunday))
(define today-dow
  (string->symbol (string-downcase (instant->civil (inexact->exact (round (now))) "%A"))))
(define (window days)
  (make-availability-window #f #f
    (list (make-day-schedule days (list (make-time-range "09:00" "17:00")))) #f))
(define (crew w)
  (map (lambda (id) (make-agent #:id id #:type 'person #:primary-location "town" #:classified-as '()
                                #:availability-window w)) '("farmer" "ada" "bob")))

(define (solve agents)
  (let ((vat (spawn-vat #:name "closed-day")))
    (with-vat vat
      (let-values (((scope ps als) (spawn-bread-scope #:agents agents)))
        (plan-scope->alist scope #:demand '(("bread#town@0" . 8.0))
                           #:reproduce? #f #:backend 'native-c)))))
(define (bake-runs r) (or (assoc-ref (or (assq-ref r 'first-stage-plan) '()) "bake") 0))

(display "\n── a crew at work today bakes the day's bread ──\n")
(define open (solve (crew (window week))))
(check "the demand is met" (> (assq-ref open 'met) 0.9))
(check "…by people: the plan emits work" (pair? (assq-ref open 'work)))

(display "\n── the same crew, closed today: nothing is made ──\n")
(define closed (solve (crew (window (delete today-dow week)))))
(check "nobody is at work: the plan emits no work" (null? (assq-ref closed 'work)))
(check "…so no bread is baked" (< (bake-runs closed) 0.01))
(check "…and the demand stands unmet, honestly" (< (assq-ref closed 'met) 0.01))

(display "\n── a scope with no people at all: the same answer, by the same rule ──\n")
;; plan-scope declares the roster regime (#:per-agent? 'roster): a live scope's
;; labour is its people's, so with nobody in it, work has no source
(define empty (solve '()))
(check "no roster, no work" (null? (assq-ref empty 'work)))
(check "…no bread" (< (bake-runs empty) 0.01))
(check "…and the demand stands unmet" (< (assq-ref empty 'met) 0.01))

(test-summary!)
