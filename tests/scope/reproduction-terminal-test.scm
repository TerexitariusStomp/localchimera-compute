;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; reproduction-terminal-test.scm — the reproduction floor holds THROUGH the
;;; live entry point's LAST period, not only its first.
;;;
;;; docs/planning/solve/time-and-uncertainty.md (R3) named a real risk: a live
;;; multi-period solve could drain a storable to zero at its FINAL period,
;;; because nothing obviously defends the terminal day the way the Doon-Valley
;;; tests' hand-enumerated #:repro-floors happened to (their floors ran to the
;;; last season because the caller wrote one in for every season). scope-
;;; consumption (live.scm) already folds a person's nutrition floor over EVERY
;;; period of the solve's horizon automatically — plan-scope's own #:reproduce?
;;; pass, not a caller remembering to enumerate one. This proves that holds
;;; through the REAL live entry point (plan-scope over a scope-root vat),
;;; discriminating the terminal period specifically: land to grow food exists
;;; ONLY on day one, so anything eaten on the LAST day was necessarily CARRIED
;;; there — a plan that stopped defending the floor after day one would leave
;;; it unfed, and it does not.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/scope/reproduction-terminal-test.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test harness)
             (ice-9 match) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1) (ice-9 format) (ice-9 match))
(use-modules (playnet knowledge catalogues subsistence)
             ((playnet knowledge catalogues substances) #:select (nutrient-content)))

(define PLACE "farm")
;; the farm's table: a body's band is fed whole by exactly this set
;; (subsistence-consumption-test proves it at the engine door), and grain alone
;; starves a body of vitamin K under its energy ceiling
(define TABLE '("grain" "beans" "greens" "rapeseed-oil" "fish" "dairy"))
;; three days, Mon 3 Aug 2026 → Wed 5 Aug 2026 — set-daily-horizon! lays out
;; period t = start+t days, so period 2's real date is hardcoded below rather
;; than recomputed, matching exactly what the engine derives internally.
(define DAY0 "2026-08-03") (define DAY2 "2026-08-05")
(define win (all-week-window "00:00" "23:59"))

(define (records+vat)
  (let ((mem (make-memory-store)))
    (call-with-values
      (lambda () (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "One farm, one season")) mem))
      (lambda (vat scope)
        (with-vat vat
          (let ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
                (as ($ scope 'agent-store)) (sts ($ scope 'spatial-thing-store)))
            ($ sts 'add-location (make-spatial-thing #:id PLACE #:name "The farm" #:lat 40.0
                                                     #:long -74.0))
            (for-each (lambda (id nm u) ($ rs 'add-resource-spec (make-resource-specification #:id id
                                                                                              #:name nm
                                                                                              #:default-unit-of-resource u)))
                      (append TABLE '("land" "skill-grow")) (append TABLE '("Land" "Growing")) (append (map (const "kg") TABLE) '("ha" "hours")))
            ($ rs 'add-process-spec (make-process-specification #:id "ps-grow" #:name "Growing"))
            ;; one raising process per food on the table, each an hour's work and a
            ;; hectare of the land for ten kilograms — the grain's is "grow", the
            ;; one the assertions below read
            (for-each
             (lambda (food)
               (let ((pid (if (equal? food "grain") "grow" (string-append "grow-" food))))
                 ($ rs 'add-recipe-process (make-recipe-process #:id pid
                                                                #:name (string-append "Grow " food)
                                                                #:process-conforms-to "ps-grow"
                                                                #:has-duration (make-duration 1.0 %effort-unit)
                                                                #:sequence-group 0))
                 ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-w")
                                                          #:action 'work
                                                          #:resource-conforms-to "skill-grow"
                                                          #:effort-quantity (make-measure 1.0 %effort-unit)
                                                          #:recipe-input-of pid))
                 ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-l")
                                                          #:action 'consume
                                                          #:resource-conforms-to "land"
                                                          #:resource-quantity (make-measure 1.0 "ha")
                                                          #:recipe-input-of pid))
                 ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append pid "-o")
                                                          #:action 'produce
                                                          #:resource-conforms-to food
                                                          #:resource-quantity (make-measure 10.0 "kg")
                                                          #:recipe-output-of pid #:is-primary #t))
                 ($ rs 'add-recipe (make-recipe #:id (string-append "r-" pid)
                                                #:name (string-append "Grow " food)
                                                #:primary-output food #:recipe-processes (list pid)))))
             TABLE)
            ($ as 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada"
                                         #:primary-location PLACE #:classified-as '()
                                         #:availability-window win))
            ($ obs 'seed-resource (make-economic-resource #:id "sk-ada" #:name "Ada can grow" #:conforms-to "skill-grow"
                                    #:accounting-quantity (make-measure 24.0 %effort-unit) #:onhand-quantity (make-measure 24.0 %effort-unit) #:primary-accountable "ada"))))
        (cons vat scope)))))

;; the total PRODUCED of one spec, at one date — one fold, both readings below.
(define (produced-at material spec date)
  ;; matched by DATE PREFIX: a commitment's hasBeginning carries the clock
  ;; moment of its band since spans became timed ("2026-08-03T00:00", and the
  ;; 23:59 window boundary even splits a day into sub-bands) — the DAY is what
  ;; this test reasons about
  (fold (lambda (c a) (if (and (eq? (commitment-action c) 'produce)
                                (equal? (commitment-resource-conforms-to c) spec)
                                (let ((b (commitment-has-beginning c)))
                                  (and (string? b) (string-prefix? date b))))
                           (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))
;; the harvest, in the energy it carries: every food on the table grown that day,
;; each at its own kcal/kg off the composition table
(define (grown-at material date)
  (fold (lambda (food a) (+ a (* (produced-at material food date) (or (assoc-ref (nutrient-content food 1) "energy") 0))))
        0.0 TABLE))
(define (fed-at material nut date) (produced-at material (string-append nut "|ada") date))  ; a nutrient, from the eat recipe

;; land exists ONLY at day 0 (#:eco-caps below), so anything eaten later must
;; have been carried from that one harvest.
(define (run)
  (let* ((vs (records+vat)) (vat (car vs)) (scope (cdr vs)))
    (with-vat vat
      (call-with-values
        (lambda () (plan-scope scope #:reproduce? #t
                     #:horizon (cons DAY0 3)
                     #:eco-caps (list (cons (string-append "land#" PLACE "@0") 1.0))
                     #:storable TABLE #:backend 'native-c))
        (lambda (ints coms material fill x ntot report)
          (list (grown-at material DAY0) (grown-at material DAY2)
                (fed-at material "energy" DAY0) (fed-at material "energy" DAY2)
                (assq-ref (assq-ref report 'certificate) 'feasible?)))))))

(define ctx (agent->subsistence-ctx (make-agent #:id "ada" #:type 'person #:name "Ada"
                                                #:primary-location PLACE #:classified-as '()
                                                #:availability-window win)))
(define energy-floor (assoc-ref (subsistence-floors ctx) "energy"))
(define one-day-kcal energy-floor)   ; a day's harvest, in the energy Ada is owed

(match-let (((grown0 grown2 fed0 fed2 feasible?) (run)))

(format #t "~%── land exists ONLY on day one; the last day's food must have been carried ──~%~%")
(format #t "  Ada's daily energy floor: ~,0f kcal~%~%" energy-floor)
(format #t "  grown day0 ~,0f kcal · grown day2 ~,0f kcal · fed day0 ~,0f kcal · fed day2 ~,0f kcal · feasible? ~a~%"
        grown0 grown2 fed0 fed2 feasible?)

(check-pred "the plan is a real plan (feasible)" (eq? #t feasible?))
(check-pred "nothing grows on the LAST day — land does not exist there"
            (< grown2 1.0))
(check-pred "day0's harvest covers more than day0 alone — it was grown to be CARRIED"
            (> grown0 (* 1.5 one-day-kcal)))
(check-pred "day0 itself is fed to the floor" (>= fed0 (* 0.97 energy-floor)))
(check-pred "…and so is the LAST day — fed from food nothing could have grown there"
            (>= fed2 (* 0.97 energy-floor)))

(format #t "~%  ~a the reproduction pass — plan-scope's own #:reproduce? fold, no caller~%  enumerating a floor per period — carries a person's floor through the LAST~%  period of a live horizon. R3's first, cheaper option, proved through the real~%  entry point end to end, not only asserted of it.~%~%"
        (if (and (eq? #t feasible?) (< grown2 1.0) (> grown0 (* 1.5 one-day-kcal))
                 (>= fed0 (* 0.97 energy-floor)) (>= fed2 (* 0.97 energy-floor)))
            "✓" "✗")))

(test-summary!)
