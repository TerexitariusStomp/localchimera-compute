;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; beenius-wax.scm — the Beenius "infinity wax" maker journey, as ValueFlows
;;; @defines beenius-wax
;;;
;;; Source: https://hub.solarpunknow.world/beenius-maker-journey
;;;
;;; Beenius Infinity Wax is a four-ingredient modelling compound — beeswax for
;;; body, lanolin for pliability, colophony (tree resin) for grip, kaolin for
;;; substance and a matte finish — kneaded into balls that join sticks into
;;; structures. Sticks are cut to Fibonacci lengths (5, 8, 13, 21 cm) so short
;;; ones sum to long ones and nobody measures while building.
;;;
;;; The whole journey is four recipes, and the fourth is the point:
;;;   recipe-beenius-wax        — melt, blend, pour, cool → a 610 g wax block
;;;   recipe-beenius-sticks     — saw bamboo into a Fibonacci stick set
;;;   recipe-beenius-kit        — block + sticks used → a standing structure
;;;   recipe-beenius-recover    — the structure down again → wax and sticks back
;;;   recipe-beenius-remelt     — recovered wax → a wax block again
;;;
;;; "Infinity" is a CYCLE in the recipe graph, not an adjective. rp-bn-recover
;;; produces spec-bn-recovered-wax, rp-bn-remelt turns that back into the same
;;; spec-bn-wax-block the build consumes, and a batch that comes out wrong is
;;; corrected by remelting rather than discarded. The only virgin beeswax the
;;; planner ever has to draw is the top-up for handling losses — so a commune
;;; that already holds a block plans its next structure with a make-up flow of
;;; ~30 g, not 500 g.
;;;
;;; Sticks close too: the build USES the stick set (it comes out again) and
;;; bamboo regrows on a harvest cycle rather than a rotation.
;;;
;;; The formula is a starting point, not a constant — the maker journey tunes it
;;; by feel (more beeswax firms a soft batch, more lanolin softens a hard one,
;;; more colophony grips at the cost of brittleness, less kaolin destiffens) and
;;; invites local substitution for every ingredient. Those are re-weighings of
;;; the same four flows and re-runs of the same one process.

(define-module (playnet knowledge recipes beenius-wax)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (playnet knowledge recipes transport)
  #:export (*beenius-specs* *beenius-substitutable* seed-beenius-specs bn-use bn-out
            bn-add! seed-beenius-wax-recipe seed-beenius-sticks-recipe
            seed-beenius-build-recipe seed-beenius-remelt-recipe seed-beenius-journey)
  #:use-module (srfi srfi-1))


(define *beenius-specs*
  ;; (id name unit). Every ingredient invites a local substitute — a climate-
  ;; appropriate resin, a plant wax, a plant-based lanolin stand-in, a local white
  ;; clay — which *beenius-substitutable* below marks on the spec itself.
  '(("spec-bn-beeswax"       "Beeswax (pure)"                            "g")
    ("spec-bn-lanolin"       "Lanolin"                                   "g")
    ("spec-bn-colophony"     "Colophony (tree resin)"                    "g")
    ("spec-bn-kaolin"        "Kaolin Clay"                               "g")
    ("spec-bn-melt-base"     "Molten Lanolin & Colophony Base"           "g")
    ("spec-bn-melt-clear"    "Clear Molten Wax Blend"                    "g")
    ("spec-bn-melt-charged"  "Kaolin-Charged Molten Wax"                 "g")
    ("spec-bn-wax-block"     "Beenius Infinity Wax Block"                "g")
    ("spec-bn-recovered-wax" "Recovered Infinity Wax (used, with grit)"  "g")
    ("spec-bn-bamboo"        "Bamboo Skewer Stock (30 cm)"               "each")
    ("spec-bn-stick-set"     "Fibonacci Stick Set (5/8/13/21 cm)"        "each")
    ("spec-bn-offcuts"       "Bamboo Offcuts"                            "each")
    ("spec-bn-wax-handling-loss" "Wax Handling Loss (hands, floor, grit)" "g")
    ("spec-bn-structure"     "Beenius Structure (built)"                 "each")
    ("spec-bn-baking-paper"  "Baking Paper"                              "each")
    ("spec-bn-scales"        "Kitchen Scales"                            "each")
    ("spec-bn-glass"         "Heat-Resistant Glass Jar"                  "each")
    ("spec-bn-water-bath"    "Pot & Water Bath"                          "each")
    ("spec-bn-heat"          "Cooking Heat"                              "kWh")
    ("spec-bn-hand-guard"    "Hand Protection"                           "each")
    ("spec-bn-mitre-box"     "Mitre Box & Dozuki Saw"                    "each")
    ("spec-bn-sieve"         "Straining Sieve"                           "each")))

(define *beenius-substitutable*
  '("spec-bn-beeswax" "spec-bn-lanolin" "spec-bn-colophony" "spec-bn-kaolin"
    "spec-bn-bamboo"))

(define (seed-beenius-specs recipe-store)
  "Add Beenius infinity-wax resource specifications to a recipe store."
  (seed-spec-rows! recipe-store *beenius-specs*
                   #:substitutable? (lambda (id) (member id *beenius-substitutable*))))

;; ─── flow shorthands ────────────────────────────────────────────────────────
;; consume/work come from recipes/transport.scm, the library's shared builders.
;; A tool here is `use`d one-at-a-time for the step, and `produce` has no shared
;; builder, so both get a local one-liner.
(define (bn-use id spec qty unit proc)
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-input-of proc))
(define (bn-out id spec qty unit proc)
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-output-of proc))
(define (bn-add! rs . flows)
  (for-each (lambda (f) ($ rs 'add-recipe-flow f)) flows))

(define (seed-beenius-wax-recipe recipe-store)
  "Seed the wax-making arm: weigh → melt → blend → knead in kaolin → pour & cool.
   Quantities are the Berlin base blend: 500 g beeswax, 30 g lanolin, 20 g
   colophony, 60 g kaolin → a 610 g block."

  ;; ── Step 1: Weigh — everything measured before any heat ──────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-weigh" #:name "Weighing"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-weigh" #:name "Weigh all four components"
                          #:process-conforms-to "pspec-bn-weigh" #:process-classified-as '("tag:preparation")
                          #:has-duration (make-duration 0.17 %effort-unit)))
  (bn-add! recipe-store
    (bn-use "rf-bn-weigh-scales-use" "spec-bn-scales" 1 %count-unit "rp-bn-weigh")
    (work-flow* "rf-bn-weigh-work" 0.17 #f "rp-bn-weigh"))

  ;; ── Step 2: Melt — lanolin and resin first, they need the higher heat ────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-melt" #:name "Water-Bath Melting"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-melt-base"
                          #:name "Melt lanolin & colophony in a water bath"
                          #:process-conforms-to "pspec-bn-melt" #:process-classified-as '("tag:melting")
                          #:has-duration (make-duration 0.17 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-melt-lanolin-in" "spec-bn-lanolin" 30 "g" "rp-bn-melt-base")
    (consume-flow* "rf-bn-melt-resin-in" "spec-bn-colophony" 20 "g" "rp-bn-melt-base")
    (bn-use "rf-bn-melt-glass-use" "spec-bn-glass" 1 %count-unit "rp-bn-melt-base")
    (bn-use "rf-bn-melt-bath-use" "spec-bn-water-bath" 1 %count-unit "rp-bn-melt-base")
    (bn-use "rf-bn-melt-guard-use" "spec-bn-hand-guard" 1 %count-unit "rp-bn-melt-base")
    (consume-flow* "rf-bn-melt-heat-in" "spec-bn-heat" 0.2 "kWh" "rp-bn-melt-base")
    (work-flow* "rf-bn-melt-work" 0.17 #f "rp-bn-melt-base")
    (bn-out "rf-bn-melt-out" "spec-bn-melt-base" 50 "g" "rp-bn-melt-base"))

  ;; ── Step 3: Blend — beeswax in, hold until it runs clear ─────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-blend" #:name "Wax Blending"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-blend"
                          #:name "Add beeswax; hold until the melt runs clear"
                          #:process-conforms-to "pspec-bn-blend" #:process-classified-as '("tag:melting")
                          #:has-duration (make-duration 0.17 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-blend-melt-in" "spec-bn-melt-base" 50 "g" "rp-bn-blend")
    (consume-flow* "rf-bn-blend-beeswax-in" "spec-bn-beeswax" 500 "g" "rp-bn-blend")
    (bn-use "rf-bn-blend-bath-use" "spec-bn-water-bath" 1 %count-unit "rp-bn-blend")
    (consume-flow* "rf-bn-blend-heat-in" "spec-bn-heat" 0.3 "kWh" "rp-bn-blend")
    (work-flow* "rf-bn-blend-work" 0.17 #f "rp-bn-blend")
    (bn-out "rf-bn-blend-out" "spec-bn-melt-clear" 550 "g" "rp-bn-blend"))

  ;; ── Step 4: Kaolin — off the heat, worked in as the melt cools ───────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-kaolin" #:name "Kaolin Incorporation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-kaolin" #:name "Work kaolin in off the heat"
                          #:process-conforms-to "pspec-bn-kaolin" #:process-classified-as '("tag:blending")
                          #:has-duration (make-duration 0.17 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-kaolin-melt-in" "spec-bn-melt-clear" 550 "g" "rp-bn-kaolin")
    (consume-flow* "rf-bn-kaolin-clay-in" "spec-bn-kaolin" 60 "g" "rp-bn-kaolin")
    (bn-use "rf-bn-kaolin-guard-use" "spec-bn-hand-guard" 1 %count-unit "rp-bn-kaolin")
    (work-flow* "rf-bn-kaolin-work" 0.17 #f "rp-bn-kaolin")
    (bn-out "rf-bn-kaolin-out" "spec-bn-melt-charged" 610 "g" "rp-bn-kaolin"))

  ;; ── Step 5: Pour & cool — onto baking paper, to firm-but-kneadable ───────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-cast" #:name "Pouring & Cooling"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-cast"
                          #:name "Pour onto baking paper and cool to kneadable"
                          #:process-conforms-to "pspec-bn-cast" #:process-classified-as '("tag:forming")
                          #:has-duration (make-duration 0.5 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-cast-melt-in" "spec-bn-melt-charged" 610 "g" "rp-bn-cast")
    (bn-use "rf-bn-cast-paper-use" "spec-bn-baking-paper" 1 %count-unit "rp-bn-cast")
    (work-flow* "rf-bn-cast-work" 0.08 #f "rp-bn-cast")
    (bn-out "rf-bn-cast-out" "spec-bn-wax-block" 610 "g" "rp-bn-cast"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-beenius-wax" #:name "Beenius Infinity Wax" #:primary-output "spec-bn-wax-block"
                  #:recipe-processes (list "rp-bn-weigh" "rp-bn-melt-base" "rp-bn-blend"
                        "rp-bn-kaolin" "rp-bn-cast"))))

(define (seed-beenius-sticks-recipe recipe-store)
  "Seed the stick arm: 20 bamboo skewers sawn into a 40-piece Fibonacci set
   (10 each of 5, 8, 13 and 21 cm) plus offcuts."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-cut" #:name "Stick Cutting"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-cut"
                          #:name "Saw bamboo to 5/8/13/21 cm in a mitre box"
                          #:process-conforms-to "pspec-bn-cut" #:process-classified-as '("tag:woodworking")
                          #:has-duration (make-duration 0.67 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-cut-bamboo-in" "spec-bn-bamboo" 20 %count-unit "rp-bn-cut")
    (bn-use "rf-bn-cut-saw-use" "spec-bn-mitre-box" 1 %count-unit "rp-bn-cut")
    (work-flow* "rf-bn-cut-work" 0.67 #f "rp-bn-cut")
    (bn-out "rf-bn-cut-out" "spec-bn-stick-set" 1 %count-unit "rp-bn-cut")
    (bn-out "rf-bn-cut-offcuts-out" "spec-bn-offcuts" 20 %count-unit "rp-bn-cut"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-beenius-sticks" #:name "Fibonacci Stick Set" #:primary-output "spec-bn-stick-set"
                  #:recipe-processes (list "rp-bn-cut"))))

(define (seed-beenius-build-recipe recipe-store)
  "Seed the building arm: a block and a stick set become a structure — and the
   structure gives both back.

   The build CONSUMES the block and the stick set, and the structure embodies
   them: a joint is a rolled ball with two sticks pressed in, and while it stands
   the wax is IN it — not standing beside it, available for a second structure.
   Coming apart again is what rp-bn-recover is, and the cycle is the two
   processes together rather than a property of either.

   Reading the block as merely OCCUPIED said the wax never entered the structure,
   which the element ledger reports as matter from nowhere: the structure solved
   to 0.0000 carbon while 580 g of 73%-carbon wax came out of it, and the whole
   seven-process loop reduced to one contradiction. (It hid itself, too — a
   process with substance on one side only reads as a system BOUNDARY, so the
   sweep that would have caught it skipped exactly this process.)

   The handling loss is a NAMED OUTPUT now, because that is what conservation
   means here: ~30 g of wax rubbed into hands, floor and grit leaves the loop at
   recovery, and 610 g in against 580 g out with nothing named was the 30 g the
   remelt then bought again as virgin beeswax."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-build" #:name "Structure Building"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-build"
                          #:name "Roll balls, press sticks in, raise a structure"
                          #:process-conforms-to "pspec-bn-build" #:process-classified-as '("tag:assembly")
                          #:has-duration (make-duration 1 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-build-wax-in" "spec-bn-wax-block" 610 "g" "rp-bn-build")
    (consume-flow* "rf-bn-build-sticks-in" "spec-bn-stick-set" 1 %count-unit "rp-bn-build")
    (work-flow* "rf-bn-build-work" 1 #f "rp-bn-build")
    (bn-out "rf-bn-build-out" "spec-bn-structure" 1 %count-unit "rp-bn-build"))

  ;; Taking it down is where the material comes back.
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-recover" #:name "Disassembly & Recovery"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-recover"
                          #:name "Take the structure down; pick wax off the sticks"
                          #:process-conforms-to "pspec-bn-recover" #:process-classified-as '("tag:disassembly")
                          #:has-duration (make-duration 0.33 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-recover-structure-in" "spec-bn-structure" 1 %count-unit "rp-bn-recover")
    (work-flow* "rf-bn-recover-work" 0.33 #f "rp-bn-recover")
    (bn-out "rf-bn-recover-wax-out" "spec-bn-recovered-wax" 580 "g" "rp-bn-recover")
    ;; the 30 g the docstring has always described, as a flow: a loss is a named
    ;; output, or it is matter the books cannot follow
    (bn-out "rf-bn-recover-loss-out" "spec-bn-wax-handling-loss" 30 "g" "rp-bn-recover")
    (bn-out "rf-bn-recover-sticks-out" "spec-bn-stick-set" 1 %count-unit "rp-bn-recover"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-beenius-kit" #:name "Beenius Build" #:primary-output "spec-bn-structure"
                  #:recipe-processes (list "rp-bn-build")))
  ;; Recovery is its own recipe: it hands back the same stick set the build draws
  ;; on, so keeping the two in one recipe would make the chain chase its own tail.
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-beenius-recover" #:name "Beenius Recovery" #:primary-output "spec-bn-recovered-wax"
                  #:recipe-processes (list "rp-bn-recover"))))

(define (seed-beenius-remelt-recipe recipe-store)
  "Seed the infinity arm: recovered wax strained, topped up and re-cast into the
   same spec-bn-wax-block the build draws on.

   580 g recovered + 30 g make-up beeswax → 610 g block. The make-up flow is the
   ONLY virgin input a commune that already owns a block ever plans for, and it
   is also the correction path: a batch that came out too soft or too brittle
   goes through here with its adjustment weighed in rather than being thrown out."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bn-remelt" #:name "Wax Remelting"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bn-remelt"
                          #:name "Remelt, strain grit, top up and re-cast"
                          #:process-conforms-to "pspec-bn-remelt" #:process-classified-as '("tag:melting")
                          #:has-duration (make-duration 0.75 %effort-unit)))
  (bn-add! recipe-store
    (consume-flow* "rf-bn-remelt-recovered-in" "spec-bn-recovered-wax" 580 "g" "rp-bn-remelt")
    (consume-flow* "rf-bn-remelt-topup-in" "spec-bn-beeswax" 30 "g" "rp-bn-remelt")
    (bn-use "rf-bn-remelt-bath-use" "spec-bn-water-bath" 1 %count-unit "rp-bn-remelt")
    (bn-use "rf-bn-remelt-glass-use" "spec-bn-glass" 1 %count-unit "rp-bn-remelt")
    (bn-use "rf-bn-remelt-sieve-use" "spec-bn-sieve" 1 %count-unit "rp-bn-remelt")
    (bn-use "rf-bn-remelt-paper-use" "spec-bn-baking-paper" 1 %count-unit "rp-bn-remelt")
    (consume-flow* "rf-bn-remelt-heat-in" "spec-bn-heat" 0.3 "kWh" "rp-bn-remelt")
    (work-flow* "rf-bn-remelt-work" 0.33 #f "rp-bn-remelt")
    (bn-out "rf-bn-remelt-out" "spec-bn-wax-block" 610 "g" "rp-bn-remelt"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-beenius-remelt" #:name "Beenius Wax Remelt" #:primary-output "spec-bn-wax-block"
                  #:recipe-processes (list "rp-bn-remelt"))))

(define (seed-beenius-journey recipe-store)
  "Seed the whole maker journey: specs, wax, sticks, build/recover, remelt."
  (seed-beenius-specs recipe-store)
  (seed-beenius-wax-recipe recipe-store)
  (seed-beenius-sticks-recipe recipe-store)
  (seed-beenius-build-recipe recipe-store)
  (seed-beenius-remelt-recipe recipe-store))
