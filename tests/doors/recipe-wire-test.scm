;;; recipe-wire-test.scm — the recipe table: the recipe-store serialized into
;;; the shape app.html's plan drill-down reads. Seed a two-step recipe in a
;;; scope and assert the wire carries the chain, the flows, and the deliverable.
;;;
;;; Run:  tools/test/run-suite.sh tests/doors/recipe-wire-test.scm
;;; (or via the blake3 dev-test shell — see [[reference_blake3_test_profile]])

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet vf formulas flows) #:select (row-action)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (playnet doors service) (playnet doors plan-wire)
             ((playnet doors record-rows) #:select (record-context))
             (playnet wire rows)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define mem-store (make-memory-store))
(define-values (vat1 scope1)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Recipe Wire Test"))
    mem-store))

(with-vat vat1
  (let ((rs ($ scope1 'recipe-store)))
    ;; specs
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-veg" #:name "Vegetables"
                                    #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-stove" #:name "Stove"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-meal" #:name "Cooked Meal"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-shop" #:name "Shopping"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-cook" #:name "Cooking"))
    ;; step 1: Shop (seq 0) → produces veg
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-shop" #:name "Shop" #:process-conforms-to "pspec-shop"
                            #:has-duration (make-duration 0.4 %effort-unit) #:sequence-group 0))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-veg-out" #:action 'produce #:resource-conforms-to "spec-veg"
                         #:resource-quantity (make-measure 2 "kg") #:recipe-output-of "rp-shop" #:is-primary #t))
    ;; step 2: Cook (seq 1) → consumes veg, uses stove + labour-hours, produces meal
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-cook" #:name "Cook" #:process-conforms-to "pspec-cook"
                            #:has-duration (make-duration 0.6 %effort-unit) #:sequence-group 1))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-veg-in" #:action 'consume #:resource-conforms-to "spec-veg"
                         #:resource-quantity (make-measure 2 "kg") #:recipe-input-of "rp-cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-stove-use" #:action 'use #:resource-conforms-to "spec-stove"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-input-of "rp-cook"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-meal-out" #:action 'produce #:resource-conforms-to "spec-meal"
                         #:resource-quantity (make-measure 4 %count-unit) #:recipe-output-of "rp-cook" #:is-primary #t))
    ($ rs 'add-recipe
       (make-recipe #:id "rp-cooked-meal" #:name "Cooked meal" #:primary-output "spec-meal"
                    #:recipe-processes (list "rp-shop" "rp-cook")))
    (check-pred "recipe-store seeded" #t)))

;;; ── the wire ────────────────────────────────────────────────────────────────
;; the scope's recipes as the page reads them, read back as plain alists
(define* (scope-recipes->wire scope-root #:optional (responses '()))
  (let* ((rs  ($ scope-root 'recipe-store))
         (ctx (record-context "test" rs #f #f #f #f #:responses responses)))
    (wire->plain (map (lambda (r) (wire-row* (wire-table-ref 'recipe) r ctx)) ($ rs 'all-recipes)))))
(define wire (with-vat vat1 (scope-recipes->wire scope1)))
(define rcp  (find (lambda (r) (equal? (assq-ref r 'id) "rp-cooked-meal")) wire))

(check-pred "a recipe was serialized" (and rcp #t))
(check "recipe name" (assq-ref rcp 'name) "Cooked meal")
(check "deliverable spec (produces)" (assq-ref rcp 'produces) "spec-meal")

(define steps (assq-ref rcp 'steps))
(check "two steps" (length steps) 2)
(check "steps in sequence order: Shop first" (assq-ref (car steps) 'name) "Shop")
(check "steps in sequence order: Cook second" (assq-ref (cadr steps) 'name) "Cook")
(check "Cook duration carried" (assq-ref (cadr steps) 'hours) 0.6)
;; the RecipeProcess's own store id, stable across recipes — a face keying a
;; graph node on it draws a step shared by two recipes once, not twice.
(check "a step carries its own process id" (assq-ref (cadr steps) 'id) "rp-cook")

(define cook (cadr steps))
(define cook-in  (assq-ref cook 'in))
(define cook-out (assq-ref cook 'out))
(check "Cook has two inputs (veg, stove)" (length cook-in) 2)
(check "Cook has one output (meal)" (length cook-out) 1)

(define veg-in (find (lambda (f) (equal? (assq-ref f 'spec) "spec-veg")) cook-in))
(check "veg input qty" (assq-ref veg-in 'q) 2)
(check "veg input unit" (assq-ref veg-in 'u) "kg")
(check "veg input action is a string" (assq-ref veg-in 'action) "consume")
(check "veg input carries a name" (assq-ref veg-in 'name) "Vegetables")

(define stove-in (find (lambda (f) (equal? (assq-ref f 'spec) "spec-stove")) cook-in))
(check "stove input action" (assq-ref stove-in 'action) "use")

(define meal-out (car cook-out))
(check "meal output action" (assq-ref meal-out 'action) "produce")
(check "meal output is primary" (assq-ref meal-out 'primary) #t)
(check "meal output qty" (assq-ref meal-out 'q) 4)

;;; ── the barbell's standing, computed elsewhere and threaded through the wire —
;;; absent (no runs yet) reads as "" / '(), never a fabricated character.
(check "no standing yet reads as the empty string" (assq-ref rcp 'standing) "")
(check "no observed channels yet" (assq-ref rcp 'profile) '())
(check "no record yet: it yields the whole of what the weather allows (1)" (assq-ref rcp 'yield) 1)
(check "no standing read: no margin claimed" (assq-ref rcp 'margin) "")

;; the observer log behind the cooking flow: five days, each a (day capture
;; stresses tuples) row, STRESSES the ((channel . stress) …) the run is filed
;; under, a channel one of the recipe's own flows — the shape
;; economy/recipe-standing.scm scope-standing leaves under `runs`.
(define stove-runs
  (list (list "2026-03-01" 90.0 '(((work . "skill-cook") . 2)) '((work "skill-cook" 10.0 9.0)))
        (list "2026-03-02" 60.0 '(((work . "skill-cook") . 4)) '((work "skill-cook" 10.0 6.0)))
        (list "2026-03-03" 35.0 '(((work . "skill-cook") . 6)) '((work "skill-cook" 10.0 3.5)))
        (list "2026-03-04" 15.0 '(((work . "skill-cook") . 8)) '((work "skill-cook" 10.0 1.5)))
        (list "2026-03-05" 10.0 '(((work . "skill-cook") . 9)) '((work "skill-cook" 10.0 1.0)))))
;; ONE record per recipe, as scope-standing hands it to the solve and the face
;; alike: rows in solve/recipe-response.scm's own shape, the curves the plan reads
(define (record id rows yield runs)
  `((id . ,id) (output . "meal")
    (curves . ,(map (lambda (row) (cons (assq-ref row 'channel) (assq-ref row 'curve))) rows))
    (rows . ,rows) (yield . ,yield) (runs . ,runs)))
(define standings
  (list (record "rp-cooked-meal"
                '(((channel . (consume . "water")) (word . antifragile) (n . 4)
                   (curve . ((1 . 20.0) (5 . 35.0) (9 . 95.0)))
                   (bend . ((kind . gain) (gap . 22.5) (from . 1) (at . 5) (to . 9)))
                   (points . ()) (licensed . #f))
                  ((channel . (work . "skill-cook")) (word . fragile) (n . 5)
                   (curve . ((2 . 90.0) (4 . 60.0) (6 . 35.0) (8 . 15.0) (9 . 10.0)))
                   (bend . ((kind . harm) (gap . 17.0) (from . 2) (at . 4) (to . 9)))
                   (points . ())
                   (licensed . ((slope . -12.0) (accel . -2.1) (se . 0.3)))))
                0.6 stove-runs)))
(define wire-standing (with-vat vat1 (scope-recipes->wire scope1 standings)))
(define rcp-standing (find (lambda (r) (equal? (assq-ref r 'id) "rp-cooked-meal")) wire-standing))
(check "the recipe's position rides the wire" (assq-ref rcp-standing 'standing) "observed")
(check "what it yields under the weather live now rides as the plain fraction it is" (assq-ref rcp-standing 'yield) 0.6)
(define profile (assq-ref rcp-standing 'profile))
(check "one profile row per channel" (length profile) 2)
(check "a channel is one of the recipe's own flows, wired by its action and spec"
       (map (lambda (c) (assq-ref c 'channel)) profile) '("consume · water" "work · skill-cook"))
(check "the furthest-reaching recipe for its output has no margin" (assq-ref rcp-standing 'margin) "")
(check "a channel says how far its record reaches: the heaviest stress it has a run under"
       (map (lambda (c) (assq-ref c 'reach)) profile) '(9 9))
(define water (find (lambda (c) (equal? (assq-ref c 'channel) "consume · water")) profile))
(check "a stressor's word" (assq-ref water 'word) "antifragile")
(check "the curve the plan reads, one reading per stress level"
       (assq-ref water 'curve) '(((s . 1) (c . 20.0)) ((s . 5) (c . 35.0)) ((s . 9) (c . 95.0))))
(check "the three levels the word was read off, and the gap between them"
       (assq-ref water 'bend) '((kind . "gain") (gap . 22.5) (from . 1) (at . 5) (to . 9)))
(check "no statistic attached (probability-free)" (assq-ref water 'confident) #f)
(check "…and its numbers wired as 0, never absent" (list (assq-ref water 'accel) (assq-ref water 'se)) '(0 0))
(check "a channel with no matching run in the log wires an empty list, never absent" (assq-ref water 'points) '())
(define stove (find (lambda (c) (equal? (assq-ref c 'channel) "work · skill-cook")) profile))
(check "a fragile stressor's word" (assq-ref stove 'word) "fragile")
(check "the fitted statistic attached under a licensed regime" (assq-ref stove 'confident) #t)
(check "its acceleration" (assq-ref stove 'accel) -2.1)
(check "its standard error" (assq-ref stove 'se) 0.3)
;; the observer log itself, on the wire: one row per run, each naming its
;; own day and the raw claim(s) `observed-capture` divided to get its capture
(define stove-pts (assq-ref stove 'points))
(check "one wire row per run" (length stove-pts) 5)
(define stove-p0 (car stove-pts))
(check "a point's day" (assq-ref stove-p0 'when) "2026-03-01")
(check "a point's severity" (assq-ref stove-p0 's) 2)
(check "…and its capture" (assq-ref stove-p0 'c) 90.0)
(define stove-claims (assq-ref stove-p0 'claims))
(check "one claim behind this run" (length stove-claims) 1)
(define stove-claim0 (car stove-claims))
(check "the claim's action" (assq-ref stove-claim0 'action) "work")
(check "…its spec" (assq-ref stove-claim0 'spec) "skill-cook")
(check "…what was intended (already scaled by what the weather allowed)" (assq-ref stove-claim0 'intended) 10.0)
(check "…and what was realized" (assq-ref stove-claim0 'realized) 9.0)

;;; ── a record whose runs were all calm: it has run, and has met no stress yet
(define calm-runs (list (list "2026-03-01" 100.0 '(((work . "skill-cook") . 0.0)) '((work "skill-cook" 10.0 10.0)))))
(define calm-rows '(((channel . (work . "skill-cook")) (word . unobserved) (n . 1)
                     (curve . ((0.0 . 100.0))) (bend . #f) (points . ()) (licensed . #f))))
(define (wire-of responses)
  (find (lambda (r) (equal? (assq-ref r 'id) "rp-cooked-meal"))
        (with-vat vat1 (scope-recipes->wire scope1 responses))))
(define rcp-forming (wire-of (list (record "rp-cooked-meal" calm-rows 0.62 calm-runs))))
(check "every run so far was calm: experimental" (assq-ref rcp-forming 'standing) "experimental")
(check "…with its yield, and a reach of nothing" (list (assq-ref rcp-forming 'yield) (assq-ref (car (assq-ref rcp-forming 'profile)) 'reach)) '(0.62 0.0))
(check "never pressed, and nothing beside it has been: the need rests on a record yet to be pressed"
       (assq-ref rcp-forming 'margin) "bare")
(check "a recipe the standing knows and that never ran: no standing, no rows, the whole yield"
       (let ((w (wire-of (list (record "rp-cooked-meal" '() 1.0 '())))))
         (list (assq-ref w 'standing) (assq-ref w 'profile) (assq-ref w 'yield)))
       '("" () 1.0))

;;; ── the margin, off the very records the solve takes
(define (meal-rows . curve)
  `(((channel . (work . "skill-cook")) (word . unobserved) (n . ,(length curve))
     (curve . ,curve) (bend . #f) (points . ()) (licensed . #f))))
(define (margin-with . records) (assq-ref (wire-of records) 'margin))
(check "beside a recipe for the same output whose record reaches further: needs rest on that one first"
       (margin-with (record "rp-cooked-meal" (meal-rows '(0 . 100.0) '(3 . 90.0)) 1.0 calm-runs)
                    (record "rp-canteen" (meal-rows '(0 . 100.0) '(7 . 80.0)) 1.0 calm-runs))
       "bounded")
(check "the furthest-reaching recipe for its output: no margin"
       (margin-with (record "rp-cooked-meal" (meal-rows '(0 . 100.0) '(7 . 80.0)) 1.0 calm-runs)
                    (record "rp-canteen" (meal-rows '(0 . 100.0) '(3 . 90.0)) 1.0 calm-runs))
       "")

;;; ── plan-results->dial-plan: a solve result → the dial's plan shape ──────────
;; Honest coverage from (demand, material): want 12 meals, produced 9 → 78%-ish.
(define solve-alist
  `((met      . 0.75)
    (material . (((action . produce) (conforms-to . "spec-meal") (quantity . 9)
                  (at-location . "home") (when . "2026-08-17T00:00") (output-of . "rp-cook"))
                 ((action . produce) (conforms-to . "spec-veg")  (quantity . 4)
                  (at-location . "home") (when . "2026-08-17T00:00") (output-of . "rp-grow-veg"))
                 ((action . consume) (conforms-to . "spec-veg")  (quantity . 4)
                  (at-location . "home") (when . "2026-08-17T00:00") (input-of . "rp-cook"))
                 ;; a haul: two rows of one run, the pickup at the origin and its dropoff where it lands
                 ((action . pickup) (conforms-to . "spec-meal") (quantity . 2)
                  (at-location . "home") (when . "2026-08-17T23:59") (input-of . "rp-deliver"))
                 ((action . dropoff) (conforms-to . "spec-meal") (quantity . 2)
                  (at-location . "market") (when . "2026-08-18T00:30") (output-of . "rp-deliver"))))
    (work     . (((action . work) (conforms-to . "skill-cook") (effort . 3.0) (input-of . "rp-cook")
                  (provider . "ana") (at-location . "home") (when . "2026-08-17T00:00") (until . "2026-08-17T23:59"))
                 ((action . work) (conforms-to . "skill-cook") (effort . 1.5) (input-of . "rp-cook")
                  (provider . "bo") (at-location . "home") (when . "2026-08-18T00:00") (until . "2026-08-18T23:59"))))
    (social   . ((direct-labour . 4.5)))))
(define demand '(("spec-meal" "home" 0 12)))   ; the cached demand: 12 meals wanted

(define dp (with-vat vat1 (plan-results->dial-plan scope1 demand solve-alist)))
(define dp-needs (assq-ref dp 'needs))
(define meal-need (find (lambda (n) (equal? (assq-ref n 'id) "spec-meal")) dp-needs))

(check "dial-plan carries the overall coverage" (assq-ref dp 'coverage) 0.75)
(check "dial-plan carries the direct-labour total" (assq-ref dp 'labourH) 4.5)
(check "a need row for the demanded spec" (and meal-need #t) #t)
(check "per-need met = produced/target (9/12)" (assq-ref meal-need 'met) 0.75)
(check "need labelled by spec name" (assq-ref meal-need 'label) "Cooked Meal")
(check "need links the recipe that makes it" (assq-ref meal-need 'recipeId) "rp-cooked-meal")
(check "runs = produced / yield (9/4 → 2)" (assq-ref meal-need 'runs) 2)
(check "labour attributed to the spec its process makes" (assq-ref meal-need 'labourH) 4.5)

;; The live current-plan solve caches under an EMPTY caller demand (the fold's
;; rows are merged inside the socialized plan-fn), so the need rows come off the
;; alist's own `demand` — the rows the solve ran on, keyed "spec#place@t".
(define dp-live (with-vat vat1 (plan-results->dial-plan scope1 '()
                                 (cons '(demand . (("spec-meal#home@0" . 8) ("spec-meal#park@1" . 4)))
                                       solve-alist))))
(define live-need (find (lambda (n) (equal? (assq-ref n 'id) "spec-meal")) (assq-ref dp-live 'needs)))
(check "empty caller demand: a need row per spec the solve ran on" (and live-need #t) #t)
(check "…its want sums the located rows (8+4)" (assq-ref live-need 'want) 12.0)
(check "…met = produced/target off the same rows" (assq-ref live-need 'met) 0.75)
;; and when both are present the alist's rows win: they are the superset
(define dp-both (with-vat vat1 (plan-results->dial-plan scope1 '(("spec-veg" "home" 0 100))
                                 (cons '(demand . (("spec-meal#home@0" . 12))) solve-alist))))
(check "alist rows beat the caller's: the solve ran on the merged set"
       (map (lambda (n) (assq-ref n 'id)) (assq-ref dp-both 'needs)) '("spec-meal"))

;;; ── the SCHEDULE: space-time coordinates survive the wire ────────────────────
;; The aggregate views above sum places and moments away; the schedule board
;; reads them as they are — who works what where at which clock moment, and
;; every material flow at its own cell.
(define sched (assq-ref dp 'schedule))
;; the plan carries its rows as they are, work and material in one list; the
;; commitment-record table (doors/record-rows.scm) writes each at the edge,
;; joining through the scope's stores — the one vocabulary a commitment is read in
(define sctx (with-vat vat1 (record-context "s1" ($ scope1 'recipe-store) ($ scope1 'agent-store) ($ scope1 'observer)
                                            ($ scope1 'plan-store) ($ scope1 'process-registry)
                                            #:material (filter (lambda (r) (not (eq? (row-action r) 'work))) sched)
                                            #:places ($ scope1 'spatial-thing-store))))
(define srows (with-vat vat1 (map (lambda (r) (wire-row* (wire-table-ref 'commitment-record) r sctx)) sched)))
(define swork (filter (lambda (r) (equal? (assoc-ref r "action") "work")) srows))
(define smat  (filter (lambda (r) (not (equal? (assoc-ref r "action") "work"))) srows))
(check "schedule present with both sides" (and (pair? swork) (pair? smat)) #t)
(define ana (find (lambda (w) (equal? (assoc-ref w "provider") "ana")) swork))
(check "a work row names its provider"      (and ana #t) #t)
(check "…their place"                       (assoc-ref ana "at") "home")
(check "…their clock moment, verbatim"      (assoc-ref ana "when") "2026-08-17T00:00")
(check "…their effort"                      (assoc-ref ana "effort") 3.0)
(check "…the skill, label-resolved"         (string? (assoc-ref ana "specName")) #t)
(check "…and the label, composed once"      (string? (assoc-ref ana "label")) #t)
(define mv (find (lambda (m) (equal? (assoc-ref m "action") "pickup")) smat))
(check "a pickup row keeps its VF action"   (and mv (assoc-ref mv "action")) "pickup")
(check "…and its own moment"                (assoc-ref mv "when") "2026-08-17T23:59")
(check "…and the place its dropoff lands it" (assoc-ref mv "to") "market")
(define mp (find (lambda (m) (and (equal? (assoc-ref m "action") "produce")
                                  (equal? (assoc-ref m "proc") "rp-cook"))) smat))
(check "a produce row carries its process"  (and mp #t) #t)
(check "…its place and quantity"            (list (assoc-ref mp "at") (assoc-ref mp "qty")) '("home" 9))

(test-summary!)
