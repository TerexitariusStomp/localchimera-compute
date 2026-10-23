;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-rollup-costvar.scm — Standard/actual cost rollup and variance
;;;
;;; Ported from: old/planner/src/lib/tests/rollup.test.ts
;;;
;;; Intent: Verify standard cost rollup from recipe BOM, actual cost from
;;; observed events, and cost variance computation.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-rollup-costvar.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet algorithms rollup) (playnet scope root) (playnet vf schemas))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup + All tests in single with-vat
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup & Tests: Rollup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Rollup Test"))
    store))

;; SNLT-based rollup: costs are in hours of embodied labor.
;; Wood is produced by a recipe taking 1h labor per board.
;; Nails are produced by a recipe taking 0.1h labor per nail.
;; Building a table consumes wood + nails + 2h direct labor.
;;   SNLT(table) per unit = 1·1 (wood) + 10·0.1 (nails) + 2 (labor) = 4 hours.

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── Setup ──────────────────────────────────────────────────

    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wood" #:name "Wood"
                                    #:default-unit-of-resource "board"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-nail" #:name "Nail" #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-labor" #:name "Labor"
                                    #:default-unit-of-resource %effort-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-table" #:name "Table"
                                    #:default-unit-of-resource %count-unit))

    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-mill-wood" #:name "Mill Wood"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-make-nails" #:name "Make Nails"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-build" #:name "Build Table"))

    ;; Recipe processes
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-mill-wood" #:name "Mill Wood" #:process-conforms-to "pspec-mill-wood"
                            #:has-duration (make-duration 1 %effort-unit)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-make-nails" #:name "Make Nails" #:process-conforms-to "pspec-make-nails"
                            #:has-duration (make-duration 1 %effort-unit)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-build" #:name "Build Table" #:process-conforms-to "pspec-build"
                            #:has-duration (make-duration 2 %effort-unit)))

    ;; Wood recipe: 1h labor → 1 board
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-labor" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 1 %effort-unit) #:recipe-input-of "rp-mill-wood"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-out" #:action 'produce #:resource-conforms-to "spec-wood"
                         #:resource-quantity (make-measure 1 "board") #:recipe-output-of "rp-mill-wood"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-wood" #:name "Wood Recipe" #:primary-output "spec-wood"
                    #:recipe-processes (list "rp-mill-wood")))

    ;; Nail recipe: 1h labor → 10 nails  ⇒ SNLT(nail) = 0.1h/each
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-nails-labor" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 1 %effort-unit) #:recipe-input-of "rp-make-nails"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-nails-out" #:action 'produce #:resource-conforms-to "spec-nail"
                         #:resource-quantity (make-measure 10 %count-unit) #:recipe-output-of "rp-make-nails"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-nail" #:name "Nail Recipe" #:primary-output "spec-nail"
                    #:recipe-processes (list "rp-make-nails")))

    ;; Table recipe: single build process consuming wood + nails + 2h labor
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-build-wood" #:action 'consume #:resource-conforms-to "spec-wood"
                         #:resource-quantity (make-measure 1 "board") #:recipe-input-of "rp-build"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-build-nails" #:action 'consume #:resource-conforms-to "spec-nail"
                         #:resource-quantity (make-measure 10 %count-unit) #:recipe-input-of "rp-build"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-build-labor" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 2 %effort-unit) #:recipe-input-of "rp-build"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-build-out" #:action 'produce #:resource-conforms-to "spec-table"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-build"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-table" #:name "Table Recipe" #:primary-output "spec-table"
                    #:recipe-processes (list "rp-build")))

    (check-pred "setup ok" #t)

    ;; ── 1. Standard cost rollup (in SNLT hours) ─────────────────
    ;;   Build stage: 1 board × SNLT(wood)=1h
    ;;                + 10 nails × SNLT(nail)=0.1h
    ;;                + 2 hours direct labor          = 4 hours

    (display "\n── Standard cost rollup ──\n")

    (let ((result (rollup-standard-cost "recipe-table" rs)))
      (check-pred "total standard cost (hours)"
                  (approx= (assq-ref result 'total) 4))
      (let ((stages (assq-ref result 'by-stage)))
        (check "one stage" (length stages) 1)
        (let ((build-stage (car stages)))
          (check-pred "Build Table cost (hours)"
                      (approx= (assq-ref build-stage 'cost) 4)))))

    ;; ── 2. Scaled standard cost ────────────────────────────────

    (display "\n── Scaled standard cost ──\n")

    (let ((result (rollup-standard-cost "recipe-table" rs #:scale-factor 2)))
      (check-pred "scaled total = 8 hours"
                  (approx= (assq-ref result 'total) 8)))

    ;; ── 3. Actual cost from events ─────────────────────────────

    (display "\n── Actual cost rollup ──\n")

    ;; Seed table resource
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-table" #:name "My Table" #:conforms-to "spec-table"
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:primary-accountable "agent-workshop"))

    ;; Record actual events
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-wood" #:action 'consume #:input-of "proc-build" #:resource-conforms-to "spec-wood"
         #:provider "agent-workshop" #:receiver "agent-workshop"
         #:resource-quantity (make-measure 1 "board") #:has-point-in-time "2026-03-01T08:00:00Z"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-nails" #:action 'consume #:input-of "proc-build" #:resource-conforms-to "spec-nail"
         #:provider "agent-workshop" #:receiver "agent-workshop"
         #:resource-quantity (make-measure 12 %count-unit) #:has-point-in-time "2026-03-01T09:00:00Z"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-labor" #:action 'work #:input-of "proc-build" #:resource-conforms-to "spec-labor"
         #:provider "agent-workshop" #:receiver "agent-workshop" #:effort-quantity (make-measure 3 %effort-unit) #:has-point-in-time "2026-03-01T09:00:00Z"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-table" #:action 'produce #:output-of "proc-build"
         #:resource-inventoried-as "r-table" #:resource-conforms-to "spec-table"
         #:provider "agent-workshop" #:receiver "agent-workshop"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-01T12:00:00Z"))

    ;; Actual cost in SNLT hours from rollup-actual-cost:
    ;;   1 wood × 1h + 12 nails × 0.1h + 3h direct labor = 1 + 1.2 + 3 = 5.2 hours
    (let ((result (rollup-actual-cost "r-table" obs rs)))
      (check-pred "actual total = 5.2 hours"
                  (approx= (assq-ref result 'total) 5.2))
      (check-pred "has 3 input events"
                  (= 3 (length (assq-ref result 'by-event)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Cost variance (pure, no actors needed)
;;;
;;; Ported from: "costVariance under/over budget"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Cost variance ──\n")

(let* ((std-result '((total . 100)))
       (act-under  '((total . 80)))
       (act-over   '((total . 150))))
  (let ((v (cost-variance std-result act-under)))
    (check "under: variance=20" (assq-ref v 'variance) 20)
    (check "under: pct=20%" (assq-ref v 'variance-pct) 20))
  (let ((v (cost-variance std-result act-over)))
    (check "over: variance=-50" (assq-ref v 'variance) -50)
    (check "over: pct=-50%" (assq-ref v 'variance-pct) -50)))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
