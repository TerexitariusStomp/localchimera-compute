;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; stone-paper.scm — stone (mineral) paper production recipe
;;; @defines stone-paper
;;;
;;; Stone paper is a sheet of ground calcium carbonate held together by a small
;;; fraction of thermoplastic resin. Its production line is a plastics line, not
;;; a pulp line: quarry fines are ground and surface-coated, compounded with HDPE
;;; into a masterbatch, extruded through a flat die, calendered/stretched into a
;;; web, then corona-treated and sheeted. The tree-free, bleach-free, effluent-free
;;; character claimed by Taiwan Lung Meng (https://taiwanlm.com/en) is expressed
;;; here as an ABSENCE: no pulpwood, no process water, no bleach and no wastewater
;;; flow appears anywhere in the chain. What the chain does consume is mineral,
;;; resin and electricity.
;;;
;;; Five-step recipe, per ~1000 kg finished paper:
;;;   rp-sp-crush     — crush limestone/marble quarry fines
;;;   rp-sp-grind     — grind to ~1–3 µm and stearate-coat the powder
;;;   rp-sp-compound  — twin-screw compound 80% CaCO₃ / 18% HDPE / 2% additive
;;;                     → pellets; reclaimed regrind re-enters HERE
;;;   rp-sp-extrude   — flat-die extrude, calender and biaxially stretch → web
;;;   rp-sp-finish    — corona-treat, slit and sheet → stone paper + edge trim
;;;
;;; The loop is the interesting form, and it runs through a SECOND recipe rather
;;; than back on itself: rp-sp-finish produces edge trim, recipe-stone-paper-reclaim
;;; granulates trim (and post-use sheet) into spec-sp-regrind, and rp-sp-compound
;;; consumes exactly that spec. So the planner satisfies part of the resin and
;;; mineral demand from the line's own scrap and from sheet coming back at end of
;;; life — the sheet grinds to masterbatch, not to fibre sludge — while the
;;; production chain itself stays a straight five-step order.
;;;
;;; Grades are ratios, not new chains: the 80/18/2 split here is the general
;;; packaging grade; a stiffer grade moves mass from resin to mineral without
;;; changing a single process.
;;;
;;; The BIO GRADE is that same claim carried one step further. Swapping HDPE for a
;;; biodegradable polyester (PBS, PLA-PBAT, PHA) re-weighs the compound to 65/33/2
;;; — the mid-range of CN103131145B's 50–75% filler / 20–40% polymer window — and
;;; leaves every unit operation where it stands. The mineral half of the line is
;;; literally shared: recipe-stone-paper-bio runs rp-sp-crush and rp-sp-grind, the
;;; same two processes, and forks only at the compounder, where a biopolymer melts
;;; at 120–190 °C instead of HDPE's window. Polyester carries more of the mass
;;; because it tolerates less filler than HDPE does, so the bio grade buys its
;;; end-of-life with resin.
;;;
;;; That purchase is the whole point, and the two end-of-life recipes COMPETE:
;;;
;;;   recipe-stone-paper-reclaim   sheet → regrind → back into rp-sp-compound
;;;   recipe-stone-paper-compost   bio sheet → mineral residue → soil
;;;
;;; Reclamation returns 98% of the sheet as compounder feed and needs a compounder
;;; to return it to; composting returns the 65% that was always mineral, as a
;;; calcitic soil amendment, and needs a windrow. Which one a plan reaches for is
;;; therefore a question about DISTANCE, and the planner answers it as one:
;;; tests/solve/test-stone-paper-siting.scm puts two hubs at different ranges
;;; from one compounding line and lets the solve pick a grade for each.
;;;
;;; The bio grade draws no regrind, because a plan chooses it exactly where the
;;; compounder that regrind feeds is out of reach.

(define-module (playnet knowledge recipes stone-paper)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (playnet knowledge recipes transport)
  #:export (*stone-paper-specs* seed-stone-paper-specs sp-use sp-out sp-add!
            seed-stone-paper-recipe seed-stone-paper-reclaim-recipe
            seed-stone-paper-bio-recipe seed-stone-paper-compost-recipe)
  #:use-module (srfi srfi-1))


(define *stone-paper-specs*
  ;; (id name unit class …). Machines carry "stationary": they stay put and the
  ;; material moves through them.
  '(("spec-sp-quarry-fines"  "Limestone/Marble Quarry Fines"                        "kg")
    ("spec-sp-crushed-stone" "Crushed Carbonate Stone"                              "kg")
    ("spec-sp-stearic-acid"  "Stearic Acid (surface-treatment coating)"             "kg")
    ("spec-sp-caco3-powder"  "Coated Calcium Carbonate Powder (~1–3 µm)"            "kg")
    ("spec-sp-hdpe"          "HDPE Resin"                                           "kg")
    ("spec-sp-additive"      "Process Additive Pack (lubricant, stabiliser, brightener)" "kg")
    ("spec-sp-masterbatch"   "Stone Paper Masterbatch Pellets"                      "kg")
    ("spec-sp-web"           "Stone Paper Web (stretched roll stock)"               "kg")
    ("spec-sp-trim"          "Stone Paper Edge Trim"                                "kg")
    ("spec-sp-regrind"       "Stone Paper Regrind (granulated, compounder-ready)"   "kg")
    ("spec-stone-paper"      "Stone Paper"                                          "kg")
    ("spec-sp-electricity"   "Electricity"                                          "kWh")
    ("spec-sp-crusher"       "Jaw Crusher"                            "each" "stationary")
    ("spec-sp-mill"          "Classifier Mill / Coating Mill"         "each" "stationary")
    ("spec-sp-compounder"    "Twin-Screw Compounder & Pelletiser"     "each" "stationary")
    ("spec-sp-extruder"      "Flat-Die Extruder & Calender Stack"     "each" "stationary")
    ("spec-sp-stretcher"     "Biaxial Stretching Frame"               "each" "stationary")
    ("spec-sp-converter"     "Corona Treater / Slitter / Sheeter"     "each" "stationary")
    ;; ── the bio grade: the same line, a biodegradable polyester in the binder slot
    ("spec-sp-biopolymer"      "Biodegradable Polyester Resin (PBS / PLA-PBAT / PHA)" "kg")
    ("spec-sp-bio-masterbatch" "Bio-Grade Masterbatch Pellets"                        "kg")
    ("spec-sp-bio-web"         "Bio-Grade Stone Paper Web"                            "kg")
    ("spec-sp-bio-trim"        "Bio-Grade Stone Paper Edge Trim"                      "kg")
    ("spec-stone-paper-bio"    "Stone Paper (bio grade)"                              "kg")
    ("spec-sp-mineral-residue" "Calcitic Mineral Residue (soil amendment)"            "kg")
    ("spec-sp-windrow"         "Compost Windrow & Turner"               "each" "stationary")))

;; The binder slot takes whichever biodegradable polyester a region can actually
;; get — PBS, a PLA-PBAT blend, PHA — so the spec is substitutable, exactly as the
;; Beenius ingredients are. The 65/33/2 ratio is what stays fixed.
(define (seed-stone-paper-specs recipe-store)
  "Add stone-paper resource specifications to a recipe store."
  (seed-spec-rows! recipe-store *stone-paper-specs*
                   #:substitutable? (lambda (id) (string=? id "spec-sp-biopolymer"))))

;; ─── flow shorthands ────────────────────────────────────────────────────────
;; consume/work come from recipes/transport.scm, the library's shared builders.
;; `use` here is always one machine for the step (no hours), and `produce` has no
;; shared builder, so both get a local one-liner. add-flows! saves repeating the
;; store call around every flow.
(define (sp-use id spec qty unit proc)
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-input-of proc))
(define (sp-out id spec qty unit proc)
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty unit) #:recipe-output-of proc))
(define (sp-add! rs . flows)
  (for-each (lambda (f) ($ rs 'add-recipe-flow f)) flows))

(define (seed-stone-paper-recipe recipe-store)
  "Seed the 5-step stone-paper production recipe.
   Quantities are per ~1000 kg of finished sheet; the planner scales linearly."

  ;; ── Step 1: Crush — quarry fines to feed stone ───────────────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-crush" #:name "Stone Crushing"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-crush" #:name "Crush limestone/marble quarry fines"
                          #:process-conforms-to "pspec-sp-crush" #:process-classified-as '("tag:mineral-processing")
                          #:has-duration (make-duration 2 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-crush-fines-in" "spec-sp-quarry-fines" 830 "kg" "rp-sp-crush")
    (sp-use "rf-sp-crush-crusher-use" "spec-sp-crusher" 1 %count-unit "rp-sp-crush")
    (consume-flow* "rf-sp-crush-power-in" "spec-sp-electricity" 25 "kWh" "rp-sp-crush")
    (work-flow* "rf-sp-crush-work" 2 #f "rp-sp-crush")
    (sp-out "rf-sp-crush-out" "spec-sp-crushed-stone" 820 "kg" "rp-sp-crush"))

  ;; ── Step 2: Grind & coat — ~1–3 µm powder, stearate-treated ──────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-grind" #:name "Fine Grinding & Surface Coating"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-grind" #:name "Grind to ~1–3 µm and stearate-coat"
                          #:process-conforms-to "pspec-sp-grind" #:process-classified-as '("tag:mineral-processing")
                          #:has-duration (make-duration 4 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-grind-stone-in" "spec-sp-crushed-stone" 820 "kg" "rp-sp-grind")
    (consume-flow* "rf-sp-grind-stearate-in" "spec-sp-stearic-acid" 8 "kg" "rp-sp-grind")
    (sp-use "rf-sp-grind-mill-use" "spec-sp-mill" 1 %count-unit "rp-sp-grind")
    (consume-flow* "rf-sp-grind-power-in" "spec-sp-electricity" 130 "kWh" "rp-sp-grind")
    (work-flow* "rf-sp-grind-work" 3 #f "rp-sp-grind")
    (sp-out "rf-sp-grind-out" "spec-sp-caco3-powder" 800 "kg" "rp-sp-grind"))

  ;; ── Step 3: Compound — 80 / 18 / 2 into pellets; regrind re-enters here ──
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-compound" #:name "Masterbatch Compounding"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-compound" #:name "Twin-screw compound & pelletise"
                          #:process-conforms-to "pspec-sp-compound" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 3 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-compound-powder-in" "spec-sp-caco3-powder" 800 "kg" "rp-sp-compound")
    (consume-flow* "rf-sp-compound-hdpe-in" "spec-sp-hdpe" 130 "kg" "rp-sp-compound")
    (consume-flow* "rf-sp-compound-additive-in" "spec-sp-additive" 20 "kg" "rp-sp-compound"))
  ;; the loop: 50 kg of the 1000 kg run is regrind, which the reclamation recipe
  ;; makes from this line's own trim and from sheet returned at end of life
  (sp-add! recipe-store
    (consume-flow* "rf-sp-compound-regrind-in" "spec-sp-regrind" 50 "kg" "rp-sp-compound")
    (sp-use "rf-sp-compound-machine-use" "spec-sp-compounder" 1 %count-unit "rp-sp-compound")
    (consume-flow* "rf-sp-compound-power-in" "spec-sp-electricity" 220 "kWh" "rp-sp-compound")
    (work-flow* "rf-sp-compound-work" 3 #f "rp-sp-compound")
    (sp-out "rf-sp-compound-out" "spec-sp-masterbatch" 1000 "kg" "rp-sp-compound"))

  ;; ── Step 4: Extrude — flat die, calender, biaxial stretch → web ──────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-extrude" #:name "Sheet Extrusion & Stretching"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-extrude" #:name "Flat-die extrude, calender, biaxially stretch"
                          #:process-conforms-to "pspec-sp-extrude" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 4 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-extrude-pellets-in" "spec-sp-masterbatch" 1000 "kg" "rp-sp-extrude")
    (sp-use "rf-sp-extrude-extruder-use" "spec-sp-extruder" 1 %count-unit "rp-sp-extrude")
    (sp-use "rf-sp-extrude-stretcher-use" "spec-sp-stretcher" 1 %count-unit "rp-sp-extrude")
    (consume-flow* "rf-sp-extrude-power-in" "spec-sp-electricity" 380 "kWh" "rp-sp-extrude")
    (work-flow* "rf-sp-extrude-work" 4 #f "rp-sp-extrude")
    (sp-out "rf-sp-extrude-out" "spec-sp-web" 1000 "kg" "rp-sp-extrude"))

  ;; ── Step 5: Finish — corona, slit, sheet → paper + trim regrind ──────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-finish" #:name "Converting & Finishing"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-finish" #:name "Corona-treat, slit and sheet"
                          #:process-conforms-to "pspec-sp-finish" #:process-classified-as '("tag:converting")
                          #:has-duration (make-duration 3 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-finish-web-in" "spec-sp-web" 1000 "kg" "rp-sp-finish")
    (sp-use "rf-sp-finish-converter-use" "spec-sp-converter" 1 %count-unit "rp-sp-finish")
    (consume-flow* "rf-sp-finish-power-in" "spec-sp-electricity" 60 "kWh" "rp-sp-finish")
    (work-flow* "rf-sp-finish-work" 5 #f "rp-sp-finish")
    (sp-out "rf-sp-finish-out" "spec-stone-paper" 950 "kg" "rp-sp-finish")
    (sp-out "rf-sp-finish-trim-out" "spec-sp-trim" 50 "kg" "rp-sp-finish"))

  ;; ── Bundle ───────────────────────────────────────────────────────────────
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-stone-paper" #:name "Stone Paper Production" #:primary-output "spec-stone-paper"
                  #:recipe-processes (list "rp-sp-crush" "rp-sp-grind" "rp-sp-compound"
                        "rp-sp-extrude" "rp-sp-finish"))))

(define (seed-stone-paper-reclaim-recipe recipe-store)
  "Seed the end-of-life arm: edge trim and used sheet grind back to compounder feed.
   Both processes land on spec-sp-regrind — the same spec rp-sp-compound already
   consumes — so reclaimed material substitutes for virgin mineral and resin with
   no change to the production chain."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-reclaim" #:name "Stone Paper Reclamation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-reclaim" #:name "Granulate used sheet into regrind"
                          #:process-conforms-to "pspec-sp-reclaim" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 2 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-reclaim-paper-in" "spec-stone-paper" 1000 "kg" "rp-sp-reclaim")
    (sp-use "rf-sp-reclaim-mill-use" "spec-sp-mill" 1 %count-unit "rp-sp-reclaim")
    (consume-flow* "rf-sp-reclaim-power-in" "spec-sp-electricity" 45 "kWh" "rp-sp-reclaim")
    (work-flow* "rf-sp-reclaim-work" 2 #f "rp-sp-reclaim")
    (sp-out "rf-sp-reclaim-out" "spec-sp-regrind" 980 "kg" "rp-sp-reclaim"))
  ;; the line's own edge trim takes the same path, in the quantity one run makes
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-trim-grind" #:name "Granulate edge trim"
                          #:process-conforms-to "pspec-sp-reclaim" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 1 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-trim-grind-in" "spec-sp-trim" 50 "kg" "rp-sp-trim-grind")
    (sp-use "rf-sp-trim-grind-mill-use" "spec-sp-mill" 1 %count-unit "rp-sp-trim-grind")
    (consume-flow* "rf-sp-trim-grind-power-in" "spec-sp-electricity" 3 "kWh" "rp-sp-trim-grind")
    (work-flow* "rf-sp-trim-grind-work" 0.5 #f "rp-sp-trim-grind")
    (sp-out "rf-sp-trim-grind-out" "spec-sp-regrind" 50 "kg" "rp-sp-trim-grind"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-stone-paper-reclaim" #:name "Stone Paper Reclamation"
                  #:primary-output "spec-sp-regrind" #:recipe-processes (list "rp-sp-trim-grind" "rp-sp-reclaim"))))

(define (seed-stone-paper-bio-recipe recipe-store)
  "Seed the bio grade: 65% CaCO₃ / 33% biodegradable polyester / 2% additive.

   The first two steps ARE the HDPE grade's — rp-sp-crush and rp-sp-grind appear in
   both recipes by id, because grinding limestone to 1–3 µm is the same work whatever
   binder meets it downstream. Only compounding, extrusion and finishing fork, and
   they fork on ratio and melt window rather than on equipment: the same compounder,
   the same flat die, the same stretcher, the same converter.

   Quantities are per ~1000 kg of finished sheet. The mineral steps run at their own
   scale — the bio compound draws 650 kg of powder where the HDPE compound draws 800
   — and the planner scales each process to what the one downstream of it asks for.

   Seed after seed-stone-paper-recipe: the shared process specs come from there.

   Source for the ratio window and the 120–190 °C compounding temperature:
   CN103131145B (50–75% inorganic filler, 20–40% biodegradable polymer)."

  ;; ── Compound — 65 / 33 / 2, no regrind inflow ────────────────────────────
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-spb-compound" #:name "Twin-screw compound & pelletise (bio grade)"
                          #:process-conforms-to "pspec-sp-compound" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 3 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-spb-compound-powder-in" "spec-sp-caco3-powder" 650 "kg" "rp-spb-compound")
    (consume-flow* "rf-spb-compound-resin-in" "spec-sp-biopolymer" 330 "kg" "rp-spb-compound")
    (consume-flow* "rf-spb-compound-additive-in" "spec-sp-additive" 20 "kg" "rp-spb-compound")
    (sp-use "rf-spb-compound-machine-use" "spec-sp-compounder" 1 %count-unit "rp-spb-compound")
    ;; a 120–190 °C melt window draws less than HDPE's
    (consume-flow* "rf-spb-compound-power-in" "spec-sp-electricity" 200 "kWh" "rp-spb-compound")
    (work-flow* "rf-spb-compound-work" 3 #f "rp-spb-compound")
    (sp-out "rf-spb-compound-out" "spec-sp-bio-masterbatch" 1000 "kg" "rp-spb-compound"))

  ;; ── Extrude — the same die and frame, a cooler melt ──────────────────────
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-spb-extrude" #:name "Flat-die extrude, calender, biaxially stretch (bio grade)" #:process-conforms-to "pspec-sp-extrude" #:process-classified-as '("tag:polymer-processing")
                          #:has-duration (make-duration 4 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-spb-extrude-pellets-in" "spec-sp-bio-masterbatch" 1000 "kg" "rp-spb-extrude")
    (sp-use "rf-spb-extrude-extruder-use" "spec-sp-extruder" 1 %count-unit "rp-spb-extrude")
    (sp-use "rf-spb-extrude-stretcher-use" "spec-sp-stretcher" 1 %count-unit "rp-spb-extrude")
    (consume-flow* "rf-spb-extrude-power-in" "spec-sp-electricity" 340 "kWh" "rp-spb-extrude")
    (work-flow* "rf-spb-extrude-work" 4 #f "rp-spb-extrude")
    (sp-out "rf-spb-extrude-out" "spec-sp-bio-web" 1000 "kg" "rp-spb-extrude"))

  ;; ── Finish — corona, slit, sheet → bio sheet + bio trim ──────────────────
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-spb-finish" #:name "Corona-treat, slit and sheet (bio grade)"
                          #:process-conforms-to "pspec-sp-finish" #:process-classified-as '("tag:converting")
                          #:has-duration (make-duration 3 %effort-unit)))
  (sp-add! recipe-store
    (consume-flow* "rf-spb-finish-web-in" "spec-sp-bio-web" 1000 "kg" "rp-spb-finish")
    (sp-use "rf-spb-finish-converter-use" "spec-sp-converter" 1 %count-unit "rp-spb-finish")
    (consume-flow* "rf-spb-finish-power-in" "spec-sp-electricity" 60 "kWh" "rp-spb-finish")
    (work-flow* "rf-spb-finish-work" 5 #f "rp-spb-finish")
    (sp-out "rf-spb-finish-out" "spec-stone-paper-bio" 950 "kg" "rp-spb-finish")
    (sp-out "rf-spb-finish-trim-out" "spec-sp-bio-trim" 50 "kg" "rp-spb-finish"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-stone-paper-bio" #:name "Stone Paper Production (bio grade)"
                  #:primary-output "spec-stone-paper-bio"
                  #:recipe-processes (list "rp-sp-crush" "rp-sp-grind" "rp-spb-compound"
                        "rp-spb-extrude" "rp-spb-finish"))))

(define (seed-stone-paper-compost-recipe recipe-store)
  "Seed the bio grade's end of life: sheet and trim windrow down to mineral residue.

   This is the RIVAL of recipe-stone-paper-reclaim, and the two differ in what they
   hand back and what they need to hand it back to. Reclamation returns 98% of the
   sheet as compounder feed, and needs a compounder within reach to feed. Composting
   returns the 650 kg that was mineral all along — calcitic residue, a liming soil
   amendment — and needs a windrow, which a hub can turn with a fork.

   Ninety days is the windrow's own clock: the polyester mineralises to CO₂ and
   biomass on it, and the carbonate simply stays."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-sp-compost" #:name "Stone Paper Composting"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-sp-compost" #:name "Windrow used bio sheet to mineral residue"
                          #:process-conforms-to "pspec-sp-compost" #:process-classified-as '("tag:composting")
                          #:has-duration (make-duration 90 "days")))
  (sp-add! recipe-store
    (consume-flow* "rf-sp-compost-paper-in" "spec-stone-paper-bio" 1000 "kg" "rp-sp-compost")
    (sp-use "rf-sp-compost-windrow-use" "spec-sp-windrow" 1 %count-unit "rp-sp-compost")
    (consume-flow* "rf-sp-compost-power-in" "spec-sp-electricity" 12 "kWh" "rp-sp-compost")
    (work-flow* "rf-sp-compost-work" 3 #f "rp-sp-compost")
    (sp-out "rf-sp-compost-out" "spec-sp-mineral-residue" 650 "kg" "rp-sp-compost"))
  ;; the line's own bio trim takes the same path, in the quantity one run makes
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-spb-trim-compost" #:name "Windrow bio edge trim"
                          #:process-conforms-to "pspec-sp-compost" #:process-classified-as '("tag:composting")
                          #:has-duration (make-duration 90 "days")))
  (sp-add! recipe-store
    (consume-flow* "rf-spb-trim-compost-in" "spec-sp-bio-trim" 50 "kg" "rp-spb-trim-compost")
    (sp-use "rf-spb-trim-compost-windrow-use" "spec-sp-windrow" 1 %count-unit "rp-spb-trim-compost")
    (consume-flow* "rf-spb-trim-compost-power-in" "spec-sp-electricity" 1 "kWh" "rp-spb-trim-compost")
    (work-flow* "rf-spb-trim-compost-work" 0.5 #f "rp-spb-trim-compost")
    (sp-out "rf-spb-trim-compost-out" "spec-sp-mineral-residue" 33 "kg" "rp-spb-trim-compost"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-stone-paper-compost" #:name "Stone Paper Composting"
                  #:primary-output "spec-sp-mineral-residue"
                  #:recipe-processes (list "rp-spb-trim-compost" "rp-sp-compost"))))
