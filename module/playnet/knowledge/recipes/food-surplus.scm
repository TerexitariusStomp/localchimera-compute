;;; food-surplus.scm — Food reclamation / surplus redistribution recipe
;;;
;;; Single-step "Collect & Sort Produce" recipe used by the SF foodnet
;;; surplus scenario. Donors hold raw produce surplus; logistics scopes
;;; (e.g. Food Runners) run this recipe to turn raw produce + reefer-van
;;; time + volunteer hours into sorted produce delivered to recipient
;;; kitchens.
;;;
;;; In reality this is two steps (pickup, then sort). They're collapsed
;;; into one process here because the resource transformations are still
;;; modeled correctly with one step, and it keeps the demand explosion
;;; readable for the federation tests that consume this recipe.
;;;
;;; Originally inlined in tests/solve/food-surplus-scenario-test.scm.
;;; Extracted so the recipe is reusable across federation scenarios and
;;; lives alongside the other recipes under knowledge/recipes/.

;; ─── Resource specifications ────────────────────────────────────────────────

;; The legal crossings these recipes trip are read off their own records
;; (legal/crossings.scm): the produce is food RECEIVED under an exchange with nothing
;; going back — `recover-surplus` — and the sorted produce is food HANDED OVER
;; under an exchange with nothing coming back — `share-food`. Each recipe states
;; the two exchanges (handover.scm); no tag says it.
(define-module (playnet knowledge recipes food-surplus)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module ((playnet knowledge recipes handover) #:select (state-exchange!))
  #:export (food-surplus-produce-spec food-surplus-sorted-produce-spec
            food-surplus-reefer-van-spec food-surplus-volunteer-spec
            seed-food-surplus-donor-specs seed-food-surplus-recipient-specs
            seed-food-surplus-recipe food-surplus-collected-spec
            seed-food-surplus-3step-recipe))

(define food-surplus-produce-spec
  (make-resource-specification
    #:id "spec-produce" #:name "Fresh Produce" #:resource-classified-as '("food") #:default-unit-of-resource "kg"))

(define food-surplus-sorted-produce-spec
  (make-resource-specification
    #:id "spec-sorted-produce" #:name "Sorted Produce" #:resource-classified-as '("food") #:default-unit-of-resource "kg"))

(define food-surplus-reefer-van-spec
  (make-resource-specification
    ;; counted in VANS — cf. cold-chain.scm's twin of this spec. The hours a run
    ;; occupies one for live on the `use` flow's effortQuantity, not here.
    #:id "spec-reefer-van" #:name "Refrigerated Van" #:default-unit-of-resource %count-unit))

(define food-surplus-volunteer-spec
  (make-resource-specification
    #:id "spec-volunteer-hours" #:name "Volunteer Driver Hours" #:default-unit-of-resource %effort-unit))

;; ─── Seed functions ─────────────────────────────────────────────────────────

(define (seed-food-surplus-donor-specs recipe-store)
  "Donors only need the raw produce spec. Their inventory speaks as surplus."
  ($ recipe-store 'add-resource-spec food-surplus-produce-spec))

(define (seed-food-surplus-recipient-specs recipe-store)
  "Recipients demand sorted produce — what actually arrives after pickup
   and inspection."
  ($ recipe-store 'add-resource-spec food-surplus-sorted-produce-spec))

(define (seed-food-surplus-recipe recipe-store)
  "Seed the logistics-scope recipe: raw produce + reefer van + volunteer
   hours → sorted produce (90% yield, 10% shrinkage from quality rejects).
   1.5 hour single-step process."
  ($ recipe-store 'add-resource-spec food-surplus-produce-spec)
  ($ recipe-store 'add-resource-spec food-surplus-sorted-produce-spec)
  ($ recipe-store 'add-resource-spec food-surplus-reefer-van-spec)
  ($ recipe-store 'add-resource-spec food-surplus-volunteer-spec)
  ;; both ends are gifts: the produce is received from another operation with
  ;; nothing going back, and the sorted produce is given with nothing coming back
  (state-exchange! recipe-store "rx-collect-received" "Surplus produce, received as a gift")
  (state-exchange! recipe-store "rx-collect-given" "Sorted produce, given")

  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-collect-sort" #:name "Collect & Sort Produce"
                          #:has-duration (make-duration 1.5 %effort-unit)))

  ;; Consume raw produce
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-produce-in" #:action 'consume #:resource-conforms-to "spec-produce"
                       #:resource-quantity (make-measure 100 "kg") #:recipe-input-of "rp-collect-sort" #:recipe-clause-of "rx-collect-received"))
  ;; Use reefer van for the run
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-van-use" #:action 'use #:resource-conforms-to "spec-reefer-van"
                       ;; ONE van, occupied for the run's 1.5 h — the pair a `use`
                       ;; is: COUNT in resourceQuantity, HOURS in effortQuantity.
                       #:resource-quantity (make-measure 1 %count-unit) #:effort-quantity (make-measure 1.5 %effort-unit)
                       #:recipe-input-of "rp-collect-sort"))
  ;; Volunteer driver labor
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-driver-work" #:action 'work
                       #:resource-conforms-to "spec-volunteer-hours"
                       #:effort-quantity (make-measure 1.5 %effort-unit)
                       #:recipe-input-of "rp-collect-sort"))
  ;; Produce sorted produce (90% yield)
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-sorted-out" #:action 'produce #:resource-conforms-to "spec-sorted-produce"
                       #:resource-quantity (make-measure 90 "kg") #:recipe-output-of "rp-collect-sort" #:recipe-clause-of "rx-collect-given"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-collect-produce" #:name "Collect & Sort Produce" #:primary-output "spec-sorted-produce"
                  #:recipe-processes (list "rp-collect-sort") #:recipe-exchanges (list "rx-collect-received" "rx-collect-given"))))

;; ─── 3-step variant: Pickup → Sort → Deliver ────────────────────────────────
;; The realistic decomposition. Used by federation tests that need to
;; exercise topological-chain ordering and per-step capacity constraints.

(define food-surplus-collected-spec
  (make-resource-specification
    #:id "spec-collected" #:name "Collected Produce" #:default-unit-of-resource "kg"))

(define (seed-food-surplus-3step-recipe recipe-store)
  "Seed the realistic 3-step pipeline: Pickup (0.5h) → Sort (0.75h) →
   Deliver (0.25h). Recipient demand drives delivery, which back-chains
   through sort (90% yield) to pickup of raw produce. Assumes the basic
   logistics specs (produce, sorted-produce, reefer-van, volunteer-hours)
   are already registered — call seed-food-surplus-recipe first or seed
   them yourself."
  ($ recipe-store 'add-resource-spec food-surplus-collected-spec)
  ;; the pipeline's two ends, as in the one-step recipe: received as a gift at
  ;; pickup, given at delivery
  (state-exchange! recipe-store "rx-cd-received" "Surplus produce, received as a gift")
  (state-exchange! recipe-store "rx-cd-given" "Sorted produce, delivered as a gift")

  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-pickup" #:name "Pickup"))
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sort" #:name "Sort & Inspect"))
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-deliver" #:name "Deliver"))

  ;; Step 1: Pickup (0.5h) — raw produce in, collected produce out
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-cd-pickup" #:name "Pickup from donor"
                          #:process-conforms-to "pspec-pickup" #:has-duration (make-duration 0.5 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-produce-in" #:action 'consume #:resource-conforms-to "spec-produce"
                       #:resource-quantity (make-measure 100 "kg") #:recipe-input-of "rp-cd-pickup" #:recipe-clause-of "rx-cd-received"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-van-pickup" #:action 'use #:resource-conforms-to "spec-reefer-van"
                       #:resource-quantity (make-measure 1 %count-unit) #:effort-quantity (make-measure 0.5 %effort-unit)
                       #:recipe-input-of "rp-cd-pickup"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-labor-pickup" #:action 'work
                       #:resource-conforms-to "spec-volunteer-hours"
                       #:effort-quantity (make-measure 0.5 %effort-unit) #:recipe-input-of "rp-cd-pickup"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-collected-out" #:action 'produce #:resource-conforms-to "spec-collected"
                       #:resource-quantity (make-measure 100 "kg") #:recipe-output-of "rp-cd-pickup"))

  ;; Step 2: Sort & inspect (0.75h) — 90% yield, 10% rejected
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-cd-sort" #:name "Sort & inspect"
                          #:process-conforms-to "pspec-sort" #:has-duration (make-duration 0.75 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-collected-in" #:action 'consume #:resource-conforms-to "spec-collected"
                       #:resource-quantity (make-measure 100 "kg") #:recipe-input-of "rp-cd-sort"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-labor-sort" #:action 'work
                       #:resource-conforms-to "spec-volunteer-hours"
                       #:effort-quantity (make-measure 0.75 %effort-unit) #:recipe-input-of "rp-cd-sort"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-sorted-out" #:action 'produce #:resource-conforms-to "spec-sorted-produce"
                       #:resource-quantity (make-measure 90 "kg") #:recipe-output-of "rp-cd-sort"))

  ;; Step 3: Deliver (0.25h)
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-cd-deliver" #:name "Deliver to recipient"
                          #:process-conforms-to "pspec-deliver" #:has-duration (make-duration 0.25 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-sorted-in" #:action 'consume #:resource-conforms-to "spec-sorted-produce"
                       #:resource-quantity (make-measure 90 "kg") #:recipe-input-of "rp-cd-deliver"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-van-deliver" #:action 'use #:resource-conforms-to "spec-reefer-van"
                       #:resource-quantity (make-measure 1 %count-unit) #:effort-quantity (make-measure 0.25 %effort-unit)
                       #:recipe-input-of "rp-cd-deliver"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-labor-deliver" #:action 'work
                       #:resource-conforms-to "spec-volunteer-hours"
                       #:effort-quantity (make-measure 0.25 %effort-unit)
                       #:recipe-input-of "rp-cd-deliver"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cd-delivered-out" #:action 'produce #:resource-conforms-to "spec-sorted-produce"
                       #:resource-quantity (make-measure 90 "kg") #:recipe-output-of "rp-cd-deliver" #:recipe-clause-of "rx-cd-given" #:stage "pspec-deliver"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-collect-deliver" #:name "Full Collection & Delivery Pipeline" #:primary-output "spec-sorted-produce"
                  #:recipe-processes (list "rp-cd-pickup" "rp-cd-sort" "rp-cd-deliver") #:recipe-exchanges (list "rx-cd-received" "rx-cd-given"))))
