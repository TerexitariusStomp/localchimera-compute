;;; cold-chain.scm — Cold-chain food network recipe
;;;
;;; A 5-step pipeline (Receive → Pre-Cool → Sort & Inspect → Pack → Deliver)
;;; that exercises the rich VF substrate: HACCP critical control points,
;;; classifier taxonomies (temp-class, allergen, food-class, diet),
;;; positioning-analysis customer-tolerance times, and capability-tagged
;;; vehicles + storage compartments.
;;;
;;; Originally inlined in tests/federation/test-food-cold-chain-vf.scm.
;;; Extracted so the recipe and its spec library are reusable, and so
;;; all recipe seed data lives under knowledge/recipes/.

;; ─── Customer tolerance / positioning analysis ──────────────────────────────
;; Urgency input the harmony layer can read. Perishables get short tolerance,
;; dry pantry long.

(define-module (playnet knowledge recipes cold-chain)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (playnet ddmrp records)
  #:use-module ((playnet knowledge recipes transport)
                #:select (pickup-flow dropoff-flow use-flow work-flow*))
  #:use-module (goblins)
  #:use-module ((playnet knowledge recipes handover) #:select (state-exchange!))
  #:export (pa-perishable pa-dairy pa-frozen pa-pantry spec-leafy-greens spec-dairy
            spec-frozen-meals-soy spec-frozen-meals-nut spec-dry-pantry
            spec-reefer-van spec-cargo-van spec-frozen-bay spec-chilled-bay
            spec-ambient-shelf spec-cc-handling spec-cc-raw spec-cc-received
            spec-cc-sorted spec-cc-packed cold-chain-food-specs
            cold-chain-vehicle-specs cold-chain-storage-specs cold-chain-skill-specs
            cold-chain-stage-good-specs
            pspec-receive pspec-pre-cool pspec-sort-inspect
            pspec-pack pspec-deliver cold-chain-process-specs seed-cold-chain-specs
            seed-cold-chain-recipe))

(define pa-perishable
  (make-positioning-analysis
    2 #f #f 'medium 'high 'medium #t #t
    "Leafy greens — 2-day tolerance after pickup"))

(define pa-dairy
  (make-positioning-analysis
    3 #f #f 'medium 'medium 'medium #t #t
    "Dairy — 3-day tolerance"))

(define pa-frozen
  (make-positioning-analysis
    14 #f #f 'high 'low 'low #f #t
    "Frozen meals — 14-day tolerance"))

(define pa-pantry
  (make-positioning-analysis
    30 #f #f 'high 'low 'low #f #f
    "Dry pantry — 30-day tolerance"))

;; ─── Food specifications (classifier-rich) ──────────────────────────────────
;; The classifier namespace `vf:*` is just a convention — VF puts no
;; constraint on the strings. A federation member from another system can
;; inspect the prefix and route accordingly.
;;
;; What a jurisdiction may answer is the HANDOVER: every good in this network is
;; destined for a recipient, and the delivery stage hands it over under an
;; exchange with nothing coming back (handover.scm), which legal/crossings.scm reads
;; as `share-food`. A configuration that SELLS states money coming back on the
;; same exchange (compliance-food.scm) and meets a different bill from the same
;; fold. Nothing here names a permit, an authority, or a jurisdiction.

(define spec-leafy-greens
  (make-resource-specification
    #:id "spec-leafy-greens" #:name "Leafy Greens"
    #:resource-classified-as '("vf:food-class:produce"
      "vf:temp-class:chilled"
      "vf:perishability:high"
      "vf:diet:vegan")
    #:default-unit-of-resource "kg" #:positioning-analysis pa-perishable))

(define spec-dairy
  (make-resource-specification
    #:id "spec-dairy-milk" #:name "Dairy Milk"
    #:resource-classified-as '("vf:food-class:dairy"
      "vf:temp-class:chilled"
      "vf:perishability:medium"
      "vf:allergen:contains-milk")
    #:default-unit-of-resource "L" #:positioning-analysis pa-dairy))

(define spec-frozen-meals-soy
  (make-resource-specification
    #:id "spec-frozen-meals-soy" #:name "Frozen Meals (Soy)"
    #:resource-classified-as '("vf:food-class:prepared"
      "vf:temp-class:frozen"
      "vf:perishability:low"
      "vf:allergen:contains-soy"
      "vf:allergen-free:nut")
    #:default-unit-of-resource %count-unit #:positioning-analysis pa-frozen))

(define spec-frozen-meals-nut
  (make-resource-specification
    #:id "spec-frozen-meals-nut" #:name "Frozen Meals (Pesto)"
    #:resource-classified-as '("vf:food-class:prepared"
      "vf:temp-class:frozen"
      "vf:perishability:low"
      "vf:allergen:contains-nut")
    #:default-unit-of-resource %count-unit #:positioning-analysis pa-frozen))

(define spec-dry-pantry
  (make-resource-specification
    #:id "spec-dry-pantry" #:name "Dry Pantry Goods"
    #:resource-classified-as '("vf:food-class:dry"
      "vf:temp-class:ambient"
      "vf:perishability:low"
      "vf:allergen-free:nut")
    #:default-unit-of-resource "kg" #:positioning-analysis pa-pantry))

;; ─── Vehicle specifications ─────────────────────────────────────────────────
;; Classifier list is a capability advertisement: "I am compatible with X",
;; not "I am exactly X". A reefer van CAN carry chilled, frozen, or ambient.

(define spec-reefer-van
  (make-resource-specification
    #:id "spec-reefer-van" #:name "Refrigerated Van"
    #:resource-classified-as '("vf:vehicle"
      "vf:temp-class:chilled"
      "vf:temp-class:frozen"
      "vf:temp-class:ambient")
    ;; A van is a VAN: defaultUnitOfResource counts the thing, and the hours a
    ;; run occupies it for are the `use` flow's effort. Denominating the stock
    ;; itself in hours says the fleet IS a quantity of time, and the service cap
    ;; (stock × the hours it stands available) would then take that length twice.
    #:default-unit-of-resource %count-unit))

(define spec-cargo-van
  (make-resource-specification
    #:id "spec-cargo-van" #:name "Ambient Cargo Van"
    #:resource-classified-as '("vf:vehicle"
      "vf:temp-class:ambient")
    #:default-unit-of-resource %effort-unit))

;; ─── Storage compartment specifications ─────────────────────────────────────
;; Modeled as `'use`-able resources measured in cubic-meter-hours.

(define spec-frozen-bay
  (make-resource-specification
    #:id "spec-frozen-bay-m3h" #:name "Frozen Compartment (m³·h)"
    #:resource-classified-as '("vf:storage" "vf:temp-class:frozen")
    #:default-unit-of-resource "m3h"))

(define spec-chilled-bay
  (make-resource-specification
    #:id "spec-chilled-bay-m3h" #:name "Chilled Compartment (m³·h)"
    #:resource-classified-as '("vf:storage" "vf:temp-class:chilled")
    #:default-unit-of-resource "m3h"
    ;; a compartment keeps its contents in place: using it is a hold through TIME,
    ;; the one field the engine (spec-stationary?) and the lint (free-motion) read
    #:keep-in-place #t))

(define spec-ambient-shelf
  (make-resource-specification
    #:id "spec-ambient-shelf-m3h" #:name "Ambient Shelf (m³·h)"
    #:resource-classified-as '("vf:storage" "vf:temp-class:ambient")
    #:default-unit-of-resource "m3h"))

(define cold-chain-food-specs
  (list spec-leafy-greens spec-dairy spec-frozen-meals-soy
        spec-frozen-meals-nut spec-dry-pantry))

(define cold-chain-vehicle-specs
  (list spec-reefer-van spec-cargo-van))

(define cold-chain-storage-specs
  (list spec-frozen-bay spec-chilled-bay spec-ambient-shelf))

;; ─── Handling labour ─────────────────────────────────────────────────────────
;; One skill, shared by receive/sort/pack — the pipeline's own reason to
;; distinguish inspection labour from packing labour hasn't shown up yet, so
;; one spec says so rather than three identical ones.

(define spec-cc-handling
  (make-resource-specification
    #:id "spec-cc-handling" #:name "Cold-chain Handling" #:default-unit-of-resource %effort-unit))

(define cold-chain-skill-specs (list spec-cc-handling))

;; ─── Intermediate goods ──────────────────────────────────────────────────────
;; Same greens, one id per stage — food-chain-seed.scm's own convention
;; ("each transform hands its output on as the next stage's input"), needed
;; here because get-process-chain (knowledge/recipes/store.scm) orders a recipe's
;; processes by matching one's OUTPUT spec against another's INPUT spec: five
;; processes all consuming AND producing the identical spec-leafy-greens read
;; as a complete graph with an edge each way between every pair, which is a
;; cycle to that sort, not a chain. Only rp-pre-cool keeps its spec unchanged
;; end to end — the one stage that is genuinely a HOLD (pickup/use-bay/
;; dropoff, recipe-hold's own shape) rather than a transform, and it sits
;; safely between two differently-named neighbours.
;;
;; spec-cc-raw carries the intake and spec-leafy-greens carries the outlet —
;; kept distinct even though it is physically the same batch throughout, the
;; same reason food-chain-seed.scm's own intake/outlet default to different
;; ids: sharing one id at both ends of the chain would have rp-deliver's
;; output match rp-receive's input, closing the graph into the very cycle
;; the per-stage ids above exist to avoid.
(define spec-cc-raw
  (make-resource-specification
    #:id "spec-cc-raw" #:name "Leafy Greens (as received, uninspected)"
    #:resource-classified-as '("vf:food-class:produce" "vf:temp-class:chilled") #:default-unit-of-resource "kg"))

(define spec-cc-received
  (make-resource-specification
    #:id "spec-cc-received" #:name "Leafy Greens (received)"
    #:resource-classified-as '("vf:food-class:produce" "vf:temp-class:chilled") #:default-unit-of-resource "kg"))

(define spec-cc-sorted
  (make-resource-specification
    #:id "spec-cc-sorted" #:name "Leafy Greens (sorted)"
    #:resource-classified-as '("vf:food-class:produce" "vf:temp-class:chilled") #:default-unit-of-resource "kg"))

(define spec-cc-packed
  (make-resource-specification
    #:id "spec-cc-packed" #:name "Leafy Greens (packed)"
    #:resource-classified-as '("vf:food-class:produce" "vf:temp-class:chilled") #:default-unit-of-resource "kg"))

(define cold-chain-stage-good-specs
  (list spec-cc-raw spec-cc-received spec-cc-sorted spec-cc-packed))

;; ─── Process specifications with HACCP critical control points ──────────────
;; The DDMRP `is-control-point` flag doubles as the HACCP CCP marker.

(define pspec-receive
  (make-process-specification
    #:id "pspec-receive" #:name "Receive & Inspect" #:is-control-point #t))   ;; CCP1 — receiving inspection

(define pspec-pre-cool
  (make-process-specification
    #:id "pspec-pre-cool" #:name "Pre-Cool to 4°C" #:is-control-point #t #:buffer-type 'time))  ;; CCP2 — temperature, time-buffered

(define pspec-sort-inspect
  (make-process-specification
    #:id "pspec-sort-inspect" #:name "Sort & Inspect" #:is-control-point #t #:is-divergent-point #t))  ;; CCP + divergent (pass/reject branch)

(define pspec-pack
  (make-process-specification
    #:id "pspec-pack" #:name "Pack"))

(define pspec-deliver
  (make-process-specification
    #:id "pspec-deliver" #:name "Deliver"))

(define cold-chain-process-specs
  (list pspec-receive pspec-pre-cool pspec-sort-inspect
        pspec-pack pspec-deliver))

;; ─── Seed functions ─────────────────────────────────────────────────────────

(define (seed-cold-chain-specs recipe-store)
  "Add all cold-chain food / vehicle / storage / skill resource specs to
   RECIPE-STORE."
  (for-each (lambda (s) ($ recipe-store 'add-resource-spec s))
            (append cold-chain-food-specs
                    cold-chain-vehicle-specs
                    cold-chain-storage-specs
                    cold-chain-skill-specs
                    cold-chain-stage-good-specs)))

(define (seed-cold-chain-recipe recipe-store)
  "Seed the 5-step cold-chain greens recipe (process specs + recipe-processes
   + recipe). Assumes seed-cold-chain-specs has been called on the same store
   so that spec-leafy-greens is already registered."
  (for-each (lambda (ps) (state-exchange! recipe-store "rx-cc-given" "Chilled food, delivered as a gift")
  ($ recipe-store 'add-process-spec ps))
            cold-chain-process-specs)

  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-receive" #:name "Receive"
                          #:process-conforms-to "pspec-receive"
                          #:has-duration (make-duration 0.25 %effort-unit)))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-pre-cool" #:name "Pre-Cool"
                          #:process-conforms-to "pspec-pre-cool"
                          #:has-duration (make-duration 0.5 %effort-unit)))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sort" #:name "Sort & Inspect"
                          #:process-conforms-to "pspec-sort-inspect"
                          #:has-duration (make-duration 0.75 %effort-unit)))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-pack" #:name "Pack"
                          #:process-conforms-to "pspec-pack"
                          #:has-duration (make-duration 0.25 %effort-unit)))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-deliver" #:name "Deliver"
                          #:process-conforms-to "pspec-deliver"
                          #:has-duration (make-duration 0.5 %effort-unit)))

  ;; ── flows: 100 kg of greens threaded through the pipeline, one distinct
  ;; spec per stage (food-chain-seed.scm's own convention — see
  ;; cold-chain-stage-good-specs above for why). receive/sort/pack/deliver
  ;; are ordinary transforms (consume the stage's intake, produce its
  ;; outlet); only rp-pre-cool is a genuine HOLD, pickup/use/dropoff of the
  ;; SAME spec — the chilled bay's own declared storage-compartment
  ;; quantity (m3·h) is what makes it one: docs/playnet.typ's
  ;; storage-is-transport-through-time doctrine reads that `use` via
  ;; engine.scm's `proc-temporal?` and tiles the arc through TIME rather
  ;; than SPACE. Nothing here marks any process "storage" itself.
  (let ((batch 100.0) (unit "kg"))
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-receive-in" #:action 'consume #:resource-conforms-to "spec-cc-raw"
                         #:resource-quantity (make-measure batch unit) #:recipe-input-of "rp-receive"))
    ($ recipe-store 'add-recipe-flow
       (work-flow* "rf-receive-work" 0.25 "spec-cc-handling" "rp-receive"))
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-receive-out" #:action 'produce #:resource-conforms-to "spec-cc-received"
                         #:resource-quantity (make-measure batch unit) #:recipe-output-of "rp-receive" #:is-primary #t))

    ($ recipe-store 'add-recipe-flow
       (pickup-flow "rf-precool-in" "spec-cc-received" batch unit "rp-pre-cool"))
    ;; the chilled bay itself: a direct draw in its own compound unit
    ;; (m3·h), not a count-and-duration `use` — the compartment's stock IS
    ;; already capacity-time, the same reading spec-reefer-van's plain
    ;; "each" (below) is NOT, so each keeps its own denomination rather than
    ;; forcing one shape on both.
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-precool-bay" #:action 'use #:resource-conforms-to "spec-chilled-bay-m3h"
                         #:resource-quantity (make-measure 1.0 "m3h")
                         #:recipe-input-of "rp-pre-cool"))
    ($ recipe-store 'add-recipe-flow
       (dropoff-flow "rf-precool-out" "spec-cc-received" batch unit "rp-pre-cool" #:primary #f))

    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-sort-in" #:action 'consume #:resource-conforms-to "spec-cc-received"
                         #:resource-quantity (make-measure batch unit) #:recipe-input-of "rp-sort"))
    ($ recipe-store 'add-recipe-flow
       (work-flow* "rf-sort-work" 0.75 "spec-cc-handling" "rp-sort"))
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-sort-out" #:action 'produce #:resource-conforms-to "spec-cc-sorted"
                         #:resource-quantity (make-measure batch unit) #:recipe-output-of "rp-sort" #:is-primary #t))

    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-pack-in" #:action 'consume #:resource-conforms-to "spec-cc-sorted"
                         #:resource-quantity (make-measure batch unit) #:recipe-input-of "rp-pack"))
    ($ recipe-store 'add-recipe-flow
       (work-flow* "rf-pack-work" 0.25 "spec-cc-handling" "rp-pack"))
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-pack-out" #:action 'produce #:resource-conforms-to "spec-cc-packed"
                         #:resource-quantity (make-measure batch unit) #:recipe-output-of "rp-pack" #:is-primary #t))

    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-deliver-in" #:action 'consume #:resource-conforms-to "spec-cc-packed"
                         #:resource-quantity (make-measure batch unit) #:recipe-input-of "rp-deliver"))
    ($ recipe-store 'add-recipe-flow
       (use-flow "rf-deliver-van" "spec-reefer-van" 1 0.5 "rp-deliver"))
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id "rf-deliver-out" #:action 'produce #:resource-conforms-to "spec-leafy-greens"
                         #:resource-quantity (make-measure batch unit) #:recipe-output-of "rp-deliver" #:recipe-clause-of "rx-cc-given" #:is-primary #t)))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-cold-chain-greens"
                  #:name "Cold-chain greens pipeline"
                  #:primary-output "spec-leafy-greens"
                  #:recipe-processes (list "rp-receive" "rp-pre-cool" "rp-sort"
                        "rp-pack" "rp-deliver")
                  #:recipe-exchanges (list "rx-cc-given"))))
