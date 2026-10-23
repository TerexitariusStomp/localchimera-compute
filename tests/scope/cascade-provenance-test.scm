;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; cascade-provenance-test.scm — contents survive a boxing → transform boundary.
;;;
;;; The containment cascade no longer moves contents by silent state mutation: it
;;; EMITS a consume event per content, sharing the container event's process. So
;;; matter that rides inside a box stays first-class in the event/resource graph —
;;; and the two algorithms that walk that graph keep working across the boundary:
;;;
;;;   track-trace  — the contained item's lineage threads to the process that
;;;                  consumed its container and the product that came out.
;;;   rollup       — the embodied SNLT of the contained item rolls into the cost
;;;                  of the produced thing instead of vanishing.
;;;
;;; Scenario: a crate contains a widget (5 h of embodied labour). A cook process
;;; consumes the crate and produces a meal. The widget is never named by any
;;; hand-written event — only the crate is — yet its labour must reach the meal.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/scope/cascade-provenance-test.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness)
             (playnet algorithms rollup) (playnet algorithms track-trace) (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Cascade Provenance")) store))
(define (~= a b) (and a b (< (abs (- a b)) 1e-6)))
(define (onhand obs id)
  (let ((r ($ obs 'get-resource id)))
    (and r (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

(with-vat vat
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── a recipe that gives the widget embodied labour: 5 h → 1 widget ────────
    (for-each (lambda (s) ($ rs 'add-resource-spec s))
      (list (make-resource-specification #:id "spec-widget" #:name "Widget"
                                         #:default-unit-of-resource %count-unit)
            (make-resource-specification #:id "spec-labor"  #:name "Labor"
                                         #:default-unit-of-resource %effort-unit)
            (make-resource-specification #:id "spec-crate"  #:name "Crate"
                                         #:default-unit-of-resource %count-unit)
            (make-resource-specification #:id "spec-meal"   #:name "Meal"
                                         #:default-unit-of-resource %count-unit)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-widget" #:name "Make widget"
                            #:has-duration (make-duration 5 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-w-labor" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 5 %effort-unit) #:recipe-input-of "rp-widget"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-w-out" #:action 'produce #:resource-conforms-to "spec-widget"
                         #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-widget"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-widget" #:name "Widget Recipe" #:primary-output "spec-widget"
                    #:recipe-processes (list "rp-widget")))

    ;; ── a crate (1) holding a widget (1), and a meal resource to fill ─────────
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-crate" #:name "Crate" #:conforms-to "spec-crate"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "kitchen"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-crate-widget" #:name "Widget in crate" #:conforms-to "spec-widget"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "kitchen" #:contained-in "r-crate"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-meal" #:name "Meal" #:conforms-to "spec-meal"
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:primary-accountable "kitchen"))

    ;; ── the boxing → transform boundary: cook consumes the crate, makes a meal.
    ;; Only the CRATE is named. The widget is drawn down by the cascade.
    ($ obs 'record-event
       (make-economic-event #:id "ev-cook-in" #:action 'consume #:input-of "P-cook" #:resource-inventoried-as "r-crate" #:resource-conforms-to "spec-crate"
         #:provider "kitchen" #:receiver "kitchen" #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-06-13T10:00:00Z"))
    ($ obs 'record-event
       (make-economic-event #:id "ev-cook-out" #:action 'produce #:output-of "P-cook" #:resource-inventoried-as "r-meal" #:resource-conforms-to "spec-meal"
         #:provider "kitchen" #:receiver "kitchen" #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-06-13T10:05:00Z"))

    (display "\n── the contained widget was drawn down (quantity sanity) ──\n")
    (check-pred "crate consumed to 0"  (~= (onhand obs "r-crate") 0))
    (check-pred "widget cascaded to 0" (~= (onhand obs "r-crate-widget") 0))

    ;; ── lineage: the cascade EVENTED the widget's consumption ─────────────────
    (define widget-events ($ obs 'events-for-resource "r-crate-widget"))
    (display "\n── the contained item is now first-class in the event graph ──\n")
    (check-pred "widget consumption was evented (was silent before)"
                (pair? widget-events))
    (check-pred "the cascade event is a consume by the cook process"
                (any (lambda (e) (and (eq? (economic-event-action e) 'consume)
                                      (equal? (economic-event-input-of e) "P-cook")
                                      (equal? (economic-event-resource-inventoried-as e) "r-crate-widget")))
                     widget-events))
    (check-pred "the widget now carries a previousEvent breadcrumb"
                (economic-resource-previous-event ($ obs 'get-resource "r-crate-widget")))

    ;; ── track-trace: from the hidden widget, reach the process and the meal ───
    ;; forward is `track` (what this became); `trace` is its backward dual
    ;; (what this came from) — the meal traces back to the widget it ate
    (define t (track "r-crate-widget" obs))
    (define tracked (map (lambda (n) (economic-event-resource-inventoried-as (assq-ref n 'event))) t))
    (display "\n── track-trace threads the widget across the boundary ──\n")
    (check-pred "track is non-empty" (pair? t))
    (check-pred "track includes the widget's own consumption" (and (member "r-crate-widget" tracked) #t))
    (check-pred "track reaches the meal the crate became" (and (member "r-meal" tracked) #t))
    (check-pred "and trace, from the meal, reaches back to the widget"
                (and (member "r-crate-widget"
                             (map (lambda (n) (economic-event-resource-inventoried-as (assq-ref n 'event)))
                                  (trace "r-meal" obs)))
                     #t))

    ;; ── rollup: the widget's embodied SNLT reaches the meal ───────────────────
    ;; min-SNLT(widget) = 5 h; the crate has no recipe (0). Without the evented
    ;; cascade the cook process would show ZERO input cost — the 5 h would vanish
    ;; inside the box. With it, the meal's actual cost is the widget's labour.
    (define actual (rollup-actual-cost "r-meal" obs rs))
    (display "\n── rollup recovers the contained item's embodied SNLT ──\n")
    (check-pred "actual cost of the meal = the widget's 5 h (recovered from inside the crate)"
                (~= (assq-ref actual 'total) 5.0))
    (check-pred "the widget's consumption is itemized in the cost rollup"
                (any (lambda (e) (equal? (assq-ref e 'spec-id) "spec-widget"))
                     (assq-ref actual 'by-event)))))

(test-summary!)
