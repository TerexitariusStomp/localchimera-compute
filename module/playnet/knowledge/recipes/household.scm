;;; household.scm — the daily work of keeping a dwelling and its people livable,
;;; as recipes.
;;;
;;; Cleaning, dusting, vacuuming, mopping, dishes, laundry, cooking, childcare
;;; and eldercare/sick-care: the work that is done every week in every dwelling
;;; and appears in no product's cost. Written as ordinary ValueFlows it stops
;;; being invisible — it draws hours from the same time budget as any other
;;; labour, it engages means (a vacuum, a machine, a sink) that a household can
;;; hold in common, and it has a MATERIAL account. Cooking and care are the
;;; family docs/planning/food/reproduction-of-labour-power.md §4 names by name as
;;; still missing once the rest of this file is a recipe — see "cooking and
;;; care" below.
;;;
;;; ── the thesis this file encodes ─────────────────────────────────────────────
;;; Housework makes no new matter. It MOVES dirt: off the floor, off the plate,
;;; out of the cloth, into a waste stream and a drain. So every material flow here
;;; comes out as what it went in as —
;;;
;;;     water in  →  greywater out       (equal mass, carries no tracked element)
;;;     soap in   →  spent surfactant out (equal mass, identically composed)
;;;     soil in   →  household waste out  (equal mass, identically composed)
;;;
;;; — and conservation holds by CONSTRUCTION, with no dilution fraction anybody
;;; had to type. The deliverable of a cleaning process is a STATE (a floor
;;; cleaned, a load of dishes washed), and a state is not matter: those specs get
;;; empty composition rows in catalogues/substances.scm, stated rather than left silent.
;;;
;;; ── where the dirt comes from ────────────────────────────────────────────────
;;; `rp-hh-living` — a household-week of simply living — produces the soil load,
;;; the soiled dishes and the dirty laundry, and consumes nothing. It is a
;;; BOUNDARY process in the sense catalogues/substances.scm means (matter on one side only):
;;; the grease, skin, street dust and food residue enter the household's ledger
;;; from bodies and from outside, and this is where the accounting starts. It is
;;; also the demand generator — a plan for a week of housework is driven by a
;;; week of living, not by a wish.
;;;
;;; It is the one process here with NO stated duration, deliberately: it is an
;;; aggregate over a household-week rather than an operation somebody performs,
;;; so it makes no claim a schedule could read. It also consumes nothing, so it
;;; is not a link in any chain — and every other process states its hours, which
;;; is exactly the condition `chain-duration-gaps` reports on: nothing here
;;; consumes another process's output while staying silent about its length.
;;;
;;; ── the choice the plan gets to make ─────────────────────────────────────────
;;; Dishes come in two recipes for one deliverable: by hand (0.5 h of somebody's
;;; life, 25 L, no power) and by machine (0.15 h of loading, 12 L, 1 kWh, and two
;;; hours of a machine's time that nobody has to be present for). The planner
;;; picks between them under whatever is scarce — labour hours, water, power, or
;;; the machine itself when one dishwasher serves several households. That
;;; comparison is the reason to write domestic work down at all.
;;;
;;; ── scope declarations a caller wants ────────────────────────────────────────
;;; `#:storable` for the consumables and the waste streams (soap, water,
;;; greywater, waste, soil-load) — they sit between bands. The STATES
;;; (floor-cleaned, dishes-washed) are deliberately NOT storable: a floor cleaned
;;; last week is not a floor cleaned this week, and the fail-closed default says
;;; so. Laundry-clean IS storable (a clean shirt keeps); laundry-dry likewise.
;;; The durables are held resources, not flows — see `seed-household-kit!`.
;;;
;;; ── provenance ───────────────────────────────────────────────────────────────
;;; [DRAFT] Every number below is an ordinary-practice figure, chosen to be
;;; recognisable rather than measured: 80 m²/h vacuuming at 800 W; a basin wash of
;;; twelve place settings in 25 L; a modern eco dishwasher cycle at ~12 L, ~1 kWh,
;;; ~2 h; a 5 kg 40 °C laundry load at ~50 L, ~0.7 kWh, ~1.75 h. A household with
;;; a water meter and a plug monitor replaces any of them without touching the
;;; mechanism. The soil-load figures (what a household-week actually deposits) are
;;; the softest numbers here and are flagged as such in the docs twin.

;;; ─── specs ───────────────────────────────────────────────────────────────────
;;; (id name unit) — `spec-water` is shared with the HumiSoil chain, in liters.
(define-module (playnet knowledge recipes household)
  #:use-module ((playnet utils units) #:select (%count-unit %effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:export (*household-specs* *household-kit* household-spec-unit seed-household-specs
            hh-consume hh-water hh-power hh-produce hh-work hh-use hh-process
            hh-wet-flows hh-pure-care hh-def hh-defs-processes hh-defs-flows hh-seed-defs!
            household-living-defs household-recipe-defs household-processes
            household-flows household-living-flows seed-household-recipes
            *household-waste-streams* *household-bin-runs* %hh-sort-batch
            %hh-sort-cleaning %hh-pfand-bottles %hh-pfand-rate
            household-waste-recipe-defs household-waste-processes
            household-waste-flows seed-household-waste-recipes seed-household-kit!
            household-care-recipe-defs household-care-processes
            household-care-flows seed-household-care-recipes))

(define *household-specs*
  '(;; labour
    ("skill-hh-domestic"     "Domestic labour (housework)"          "hours")
    ("skill-hh-cooking"      "Cooking (meal preparation)"           "hours")
    ("skill-hh-childcare"    "Childcare"                            "hours")
    ("skill-hh-eldercare"    "Eldercare and care of the sick"       "hours")
    ;; cooking and care — the two DRAFT rows household-substance's own
    ;; comment (docs/planning/food/reproduction-of-labour-power.md §6) names as
    ;; still open; see "cooking and care" below
    ("spec-hh-food-raw"      "Raw food, unprepared"                 "kg")
    ("spec-hh-meal-cooked"   "A meal, cooked and ready to eat"       "meal")
    ("spec-hh-child-minded"  "A child, minded"                      "hours")
    ("spec-hh-care-given"    "Eldercare or sick-care, given"        "hours")
    ;; consumables and streams
    ("drinking-water"        "Drinking water"                       "L")   ; the litre a body's floor is met from (catalogues/substances.scm water-form?)
    ("spec-hh-soap"          "All-purpose soap"                     "kg")
    ("spec-hh-soap-spent"    "Spent surfactant (in wastewater)"     "kg")
    ("spec-hh-greywater"     "Greywater"                            "liters")
    ("spec-hh-soil-load"     "Household soil (dust, grease, food residue)" "kg")
    ("spec-hh-waste"         "Household cleaning waste (binned)"    "kg")
    ("spec-hh-drain-solids"  "Soil carried off in the wastewater"   "kg")
    ;; the means — durables a process `use`s, never consumes
    ("spec-hh-vacuum"        "Vacuum cleaner"                       "each")
    ("spec-hh-mop"           "Mop and bucket"                       "each")
    ("spec-hh-cloths"        "Cleaning cloth set"                   "each")
    ("spec-hh-brush"         "Bathroom brush and scourer"           "each")
    ("spec-hh-sink"          "Kitchen sink (double basin)"          "each")
    ("spec-hh-dishwasher"    "Dishwasher"                           "each")
    ("spec-hh-washer"        "Washing machine"                      "each")
    ("spec-hh-drying-rack"   "Drying rack / line"                   "each")
    ;; the states — what the work delivers
    ("spec-hh-floor-cleaned" "Floor vacuumed"                       "m2")
    ("spec-hh-floor-washed"  "Floor mopped"                         "m2")
    ("spec-hh-surface-dusted" "Surfaces dusted"                     "m2")
    ("spec-hh-bathroom-clean" "Bathroom cleaned"                    "each")
    ("spec-hh-dishes-soiled" "Soiled dishes (a load of 12 settings)" "load")
    ("spec-hh-dishes-washed" "Washed dishes (a load of 12 settings)" "load")
    ("spec-hh-laundry-dirty" "Dirty laundry"                        "kg")
    ("spec-hh-laundry-clean" "Laundry washed (wet)"                 "kg")
    ("spec-hh-laundry-dry"   "Laundry washed and dry"               "kg")
    ("spec-hh-laundry-ironed" "Laundry ironed"                      "kg")
    ("spec-hh-rooms-tidy"    "Room tidied"                          "each")
    ("spec-hh-bed-made"      "Bed made with fresh linen"            "each")
    ("spec-hh-windows-cleaned" "Windows cleaned"                    "m2")
    ("spec-hh-plants-watered" "Houseplants watered"                 "each")
    ("spec-hh-iron"          "Iron and board"                       "each")
    ;; ── the waste arm ──────────────────────────────────────────────────────
    ("spec-hh-discards"      "The day's discards (unsorted)"        "kg")
    ("spec-hh-organics"      "Organic waste (Biotonne)"             "kg")
    ("spec-hh-paper"         "Paper and card (Blaue Tonne)"         "kg")
    ("spec-hh-glass"         "Waste glass (Glascontainer)"          "kg")
    ("spec-hh-packaging"     "Packaging: plastics and metals (Gelbe Tonne)" "kg")
    ("spec-hh-residual"      "Residual waste (Restmüll)"            "kg")
    ("spec-hh-organics-collected"  "Organic waste, presented for collection"   "kg")
    ("spec-hh-paper-collected"     "Paper and card, presented for collection"  "kg")
    ("spec-hh-glass-collected"     "Waste glass, taken to the bottle bank"     "kg")
    ("spec-hh-packaging-collected" "Packaging, presented for collection"       "kg")
    ("spec-hh-residual-collected"  "Residual waste, presented for collection"  "kg")
    ("spec-hh-deposit-bottles" "Deposit bottles and cans (Pfand)"   "each")
    ("spec-hh-bin"           "Wheelie bin"                          "each")
    ("spec-eur"              "Euro"                                 "EUR")))

;;; the durables, as one kit: (spec-id . how many one household holds)
(define *household-kit*
  '(("spec-hh-vacuum" . 1) ("spec-hh-mop" . 1) ("spec-hh-cloths" . 2)
    ("spec-hh-brush" . 1) ("spec-hh-sink" . 1) ("spec-hh-dishwasher" . 1)
    ("spec-hh-washer" . 1) ("spec-hh-drying-rack" . 2)))

(define (household-spec-unit id)
  (let ((row (assoc id *household-specs*)))
    (if row (caddr row) %count-unit)))

(define (seed-household-specs recipe-store)
  "Register the household specs. `spec-water` comes from the HumiSoil spec set;
   seed that too (or call `seed-household-recipes`, which registers it here)."
  (for-each
   (lambda (row)
     ($ recipe-store 'add-resource-spec
        (make-resource-specification #:id (car row) #:name (cadr row) #:resource-classified-as '("household")
                                     #:default-unit-of-resource (caddr row))))
   *household-specs*)
  ($ recipe-store 'add-resource-spec
     (make-resource-specification #:id "spec-water" #:name "Water" #:resource-classified-as '("household")
                                  #:default-unit-of-resource "liters"))
  ;; the euro carries the medium-of-exchange flag, like a pooled maintenance
  ;; fund's dollars: the deposit refund is money coming back, and the
  ;; planner should read it as money rather than as a commodity. The unit is
  ;; the ISO code "EUR" — the same string the gateway's claimable spec-eur
  ;; (server/gateway.scm) carries, so one spec id means one unit everywhere.
  ($ recipe-store 'add-resource-spec
     (make-resource-specification #:id "spec-eur" #:name "Euro" #:resource-classified-as '("household")
                                  #:default-unit-of-resource "EUR" #:substitutable #t #:medium-of-exchange #t)))

;;; ─── flow helpers ────────────────────────────────────────────────────────────
;;; Each states exactly the fields its action needs, so a missing quantity is a
;;; typo rather than a silent opt-out. A `use` carries BOTH: how many of the
;;; means are engaged, and for how long.
(define (hh-consume id spec qty proc)
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to spec #:resource-quantity (make-measure qty (household-spec-unit spec))
                    #:recipe-input-of proc))
(define (hh-water id qty proc)          ; water is shared with HumiSoil, in liters
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to "spec-water" #:resource-quantity (make-measure qty "liters")
                    #:recipe-input-of proc))
(define (hh-power id kwh proc)          ; electricity is shared with stone-paper
  (make-recipe-flow #:id id #:action 'consume #:resource-conforms-to "spec-sp-electricity" #:resource-quantity (make-measure kwh "kWh")
                    #:recipe-input-of proc))
(define* (hh-produce id spec qty proc #:key (primary #f))
  (make-recipe-flow #:id id #:action 'produce #:resource-conforms-to spec
                    #:resource-quantity (make-measure qty (household-spec-unit spec))
                    #:recipe-output-of proc #:is-primary primary))
(define* (hh-work id hours proc #:key (skill "skill-hh-domestic"))
  (make-recipe-flow #:id id #:action 'work #:resource-conforms-to skill #:effort-quantity (make-measure hours %effort-unit)
                    #:recipe-input-of proc))
(define (hh-use id spec count hours proc)
  (make-recipe-flow #:id id #:action 'use #:resource-conforms-to spec #:resource-quantity (make-measure count %count-unit) #:effort-quantity (make-measure hours %effort-unit)
                    #:recipe-input-of proc))

(define* (hh-process id name hours #:key (tags '("tag:housework")))
  (make-recipe-process #:id id #:name name #:process-conforms-to "pspec-hh-domestic" #:process-classified-as tags
                       #:has-duration (and hours (make-duration hours %effort-unit))))

;;; The wet trio: whatever water, soap and soil a task draws comes back out as
;;; greywater, spent surfactant and waste, mass for mass. Returns the flows.
(define* (hh-wet-flows prefix proc #:key (water 0) (soap 0) (soil 0) (soil-to 'drain))
  (append
   (if (> water 0)
       (list (hh-water (string-append prefix "-water") water proc)
             (hh-produce (string-append prefix "-grey") "spec-hh-greywater" water proc))
       '())
   (if (> soap 0)
       (list (hh-consume (string-append prefix "-soap") "spec-hh-soap" soap proc)
             (hh-produce (string-append prefix "-spent") "spec-hh-soap-spent" soap proc))
       '())
   ;; where the soil GOES is a property of the task, not of the dirt: a mop
   ;; bucket and a sink of plates empty into the drain, a vacuum bag and a duster
   ;; into the bin. Both streams are the same soil, identically composed, so the
   ;; balance is untouched and the difference is only in which downstream chain
   ;; picks it up — a sewer, or the Restmüll.
   (if (> soil 0)
       (list (hh-consume (string-append prefix "-soil") "spec-hh-soil-load" soil proc)
             (hh-produce (string-append prefix "-waste")
                         (if (eq? soil-to 'bin) "spec-hh-waste" "spec-hh-drain-solids")
                         soil proc))
       '())))

;;; A recipe as DATA: (process flows recipe-wrapper). The seeders below push
;;; these into a store, and a caller with no store — the convex planner's own
;;; harness, which never spawns a vat — reads the same lists straight out of
;;; `household-processes` / `household-flows`. One definition, both worlds.
(define (hh-def proc flows recipe-id recipe-name primary)
  (list proc flows
        (make-recipe #:id recipe-id #:name recipe-name #:primary-output primary
                     #:recipe-processes (list (recipe-process-id proc)))))
(define (hh-defs-processes defs) (map car defs))
(define (hh-defs-flows defs) (append-map cadr defs))
(define (hh-seed-defs! rs defs)
  ($ rs 'add-process-spec
     (make-process-specification #:id "pspec-hh-domestic" #:name "Domestic Labour"))
  (for-each (lambda (d)
              ($ rs 'add-recipe-process (car d))
              (for-each (lambda (f) ($ rs 'add-recipe-flow f)) (cadr d))
              ($ rs 'add-recipe (caddr d)))
            defs))

;;; ─── the recipes ─────────────────────────────────────────────────────────────
;;; ── living: where the dirt enters the ledger (boundary — no inputs) ─────────
;;; One household-week for three people. No duration: an aggregate over a week
;;; of living, not an operation anybody performs.
;;;
;;; IT IS HELD APART FROM THE TASK COLUMNS ON PURPOSE. Cleaning consumes soil,
;;; so a planner handed `rp-hh-living` as an ordinary column will happily RUN it
;;; — manufacturing dirt in order to have dirt to clean, and reporting a tidy
;;; flat either way. Living is not an activity a household elects; it is the
;;; exogenous fact the housework answers. So it belongs on the STOCK side: a
;;; caller seeds a week of its outputs as on-hand and plans the tasks against
;;; them. `seed-household-recipes` puts it in the store as a catalogue entry
;;; (the store is a catalogue, and the sweep wants to see the boundary), while
;;; `household-processes` — what a solve is handed — deliberately omits it.
(define household-living-defs
  (list
  (let ((p (hh-process "rp-hh-living" "A household-week of living" #f
                       #:tags '("tag:housework" "tag:boundary"))))
    (hh-def p
             (list (hh-produce "rf-hh-liv-soil" "spec-hh-soil-load" 5.0 "rp-hh-living"
                               #:primary #t)
                   (hh-produce "rf-hh-liv-dishes" "spec-hh-dishes-soiled" 14 "rp-hh-living")
                   (hh-produce "rf-hh-liv-laundry" "spec-hh-laundry-dirty" 8 "rp-hh-living")
                   ;; and the discards: ~8 kg a person a week, the German
                   ;; household average, plus the week's deposit containers
                   (hh-produce "rf-hh-liv-discards" "spec-hh-discards" 24 "rp-hh-living")
                   (hh-produce "rf-hh-liv-pfand" "spec-hh-deposit-bottles" 12 "rp-hh-living"))
             "recipe-hh-living" "A week of living" "spec-hh-soil-load"))))

;;; ─── the tasks: the columns a plan actually chooses among ────────────────────
(define household-recipe-defs
  (list
  ;; ── drinking water: the litre a body's floor reads, drawn from the tap. Water is
  ;; the molecule (catalogues/substances.scm), so the drawn form carries its litre per kilogram
  ;; with nothing stated twice; without an act that produces it the floor stands on
  ;; no form and the scope is told so ([diet]).
  (let ((p (hh-process "rp-hh-draw-water" "Draw drinking water" 0.01)))
    (hh-def p
            (list (hh-work "rf-hh-dw-work" 0.01 "rp-hh-draw-water")
                  (hh-water "rf-hh-dw-in" 1 "rp-hh-draw-water")
                  (hh-produce "rf-hh-dw-out" "drinking-water" 1 "rp-hh-draw-water" #:primary #t))
            "recipe-hh-draw-water" "Drinking water" "drinking-water"))

  ;; ── vacuum: 60 m² in 45 min, 800 W ─────────────────────────────────────────
  (let ((p (hh-process "rp-hh-vacuum" "Vacuum the floors" 0.75)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-vac-work" 0.75 "rp-hh-vacuum")
                    (hh-use "rf-hh-vac-machine" "spec-hh-vacuum" 1 0.75 "rp-hh-vacuum")
                    (hh-power "rf-hh-vac-power" 0.6 "rp-hh-vacuum")
                    (hh-produce "rf-hh-vac-out" "spec-hh-floor-cleaned" 60 "rp-hh-vacuum"
                                #:primary #t))
              (hh-wet-flows "rf-hh-vac" "rp-hh-vacuum" #:soil 0.25 #:soil-to 'bin))
             "recipe-hh-vacuum" "Vacuuming" "spec-hh-floor-cleaned"))

  ;; ── dusting: 30 m² of surface in half an hour, cloths only ─────────────────
  (let ((p (hh-process "rp-hh-dust" "Dust the surfaces" 0.5)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-dust-work" 0.5 "rp-hh-dust")
                    (hh-use "rf-hh-dust-cloth" "spec-hh-cloths" 1 0.5 "rp-hh-dust")
                    (hh-produce "rf-hh-dust-out" "spec-hh-surface-dusted" 30 "rp-hh-dust"
                                #:primary #t))
              (hh-wet-flows "rf-hh-dust" "rp-hh-dust" #:soil 0.05 #:soil-to 'bin))
             "recipe-hh-dust" "Dusting" "spec-hh-surface-dusted"))

  ;; ── mopping: 40 m² of hard floor, a bucket of 8 L and 20 g of soap ─────────
  (let ((p (hh-process "rp-hh-mop" "Mop the hard floors" 0.5)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-mop-work" 0.5 "rp-hh-mop")
                    (hh-use "rf-hh-mop-kit" "spec-hh-mop" 1 0.5 "rp-hh-mop")
                    (hh-produce "rf-hh-mop-out" "spec-hh-floor-washed" 40 "rp-hh-mop"
                                #:primary #t))
              (hh-wet-flows "rf-hh-mop" "rp-hh-mop" #:water 8 #:soap 0.02 #:soil 0.15))
             "recipe-hh-mop" "Mopping" "spec-hh-floor-washed"))

  ;; ── bathroom: 45 min, brush and cloth, 5 L and 30 g of soap ────────────────
  (let ((p (hh-process "rp-hh-bathroom" "Clean the bathroom" 0.75)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-bath-work" 0.75 "rp-hh-bathroom")
                    (hh-use "rf-hh-bath-brush" "spec-hh-brush" 1 0.75 "rp-hh-bathroom")
                    (hh-use "rf-hh-bath-cloth" "spec-hh-cloths" 1 0.75 "rp-hh-bathroom")
                    (hh-produce "rf-hh-bath-out" "spec-hh-bathroom-clean" 1 "rp-hh-bathroom"
                                #:primary #t))
              (hh-wet-flows "rf-hh-bath" "rp-hh-bathroom" #:water 5 #:soap 0.03 #:soil 0.1))
             "recipe-hh-bathroom" "Bathroom cleaning" "spec-hh-bathroom-clean"))

  ;; ── dishes by hand: one load of twelve settings, a basin of 25 L ───────────
  ;; Half an hour of somebody's life, and no electricity at all.
  (let ((p (hh-process "rp-hh-dishes-hand" "Wash the dishes by hand" 0.5)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-dh-work" 0.5 "rp-hh-dishes-hand")
                    (hh-use "rf-hh-dh-sink" "spec-hh-sink" 1 0.5 "rp-hh-dishes-hand")
                    (hh-consume "rf-hh-dh-in" "spec-hh-dishes-soiled" 1 "rp-hh-dishes-hand")
                    (hh-produce "rf-hh-dh-out" "spec-hh-dishes-washed" 1 "rp-hh-dishes-hand"
                                #:primary #t))
              (hh-wet-flows "rf-hh-dh" "rp-hh-dishes-hand"
                            #:water 25 #:soap 0.015 #:soil 0.25))
             "recipe-hh-dishes-hand" "Dishwashing by hand" "spec-hh-dishes-washed"))

  ;; ── dishes by machine: the same load, 9 min of a person, 2 h of a machine ──
  ;; The `use` states both quantities: ONE dishwasher, engaged for the whole
  ;; two-hour cycle — so a second load in the same band needs a second machine.
  (let ((p (hh-process "rp-hh-dishes-machine" "Run the dishwasher" 2)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-dm-work" 0.15 "rp-hh-dishes-machine")
                    (hh-use "rf-hh-dm-machine" "spec-hh-dishwasher" 1 2 "rp-hh-dishes-machine")
                    (hh-power "rf-hh-dm-power" 1.0 "rp-hh-dishes-machine")
                    (hh-consume "rf-hh-dm-in" "spec-hh-dishes-soiled" 1 "rp-hh-dishes-machine")
                    (hh-produce "rf-hh-dm-out" "spec-hh-dishes-washed" 1 "rp-hh-dishes-machine"
                                #:primary #t))
              (hh-wet-flows "rf-hh-dm" "rp-hh-dishes-machine"
                            #:water 12 #:soap 0.018 #:soil 0.25))
             "recipe-hh-dishes-machine" "Dishwashing by machine" "spec-hh-dishes-washed"))

  ;; ── laundry: a 5 kg load at 40 °C — 1¾ h of machine, 15 min of a person ────
  (let ((p (hh-process "rp-hh-laundry" "Wash a load of laundry" 1.75)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-lw-work" 0.25 "rp-hh-laundry")
                    (hh-use "rf-hh-lw-machine" "spec-hh-washer" 1 1.75 "rp-hh-laundry")
                    (hh-power "rf-hh-lw-power" 0.7 "rp-hh-laundry")
                    (hh-consume "rf-hh-lw-in" "spec-hh-laundry-dirty" 5 "rp-hh-laundry")
                    (hh-produce "rf-hh-lw-out" "spec-hh-laundry-clean" 5 "rp-hh-laundry"
                                #:primary #t))
              (hh-wet-flows "rf-hh-lw" "rp-hh-laundry"
                            #:water 50 #:soap 0.06 #:soil 0.1))
             "recipe-hh-laundry" "Laundry" "spec-hh-laundry-clean"))

  ;; ── line-drying: 12 h on a rack, 9 min of hanging and taking down ──────────
  ;; A twelve-hour process with a quarter-hour of labour: the rack is occupied
  ;; the whole time and nobody is. Longer than a sub-day band, so the planner
  ;; carries it as a journey through time — wet in at one band, dry out later.
  (let ((p (hh-process "rp-hh-dry" "Hang the laundry to dry" 12)))
    (hh-def p
             (list (hh-work "rf-hh-ld-work" 0.15 "rp-hh-dry")
                   (hh-use "rf-hh-ld-rack" "spec-hh-drying-rack" 1 12 "rp-hh-dry")
                   (hh-consume "rf-hh-ld-in" "spec-hh-laundry-clean" 5 "rp-hh-dry")
                   (hh-produce "rf-hh-ld-out" "spec-hh-laundry-dry" 5 "rp-hh-dry"
                               #:primary #t))
             "recipe-hh-dry" "Line-drying" "spec-hh-laundry-dry"))

  ;; ── ironing: 3 kg in half an hour, 1 kW of iron ────────────────────────────
  (let ((p (hh-process "rp-hh-iron" "Iron the laundry" 0.5)))
    (hh-def p
             (list (hh-work "rf-hh-ir-work" 0.5 "rp-hh-iron")
                   (hh-use "rf-hh-ir-iron" "spec-hh-iron" 1 0.5 "rp-hh-iron")
                   (hh-power "rf-hh-ir-power" 0.5 "rp-hh-iron")
                   (hh-consume "rf-hh-ir-in" "spec-hh-laundry-dry" 3 "rp-hh-iron")
                   (hh-produce "rf-hh-ir-out" "spec-hh-laundry-ironed" 3 "rp-hh-iron"
                               #:primary #t))
             "recipe-hh-iron" "Ironing" "spec-hh-laundry-ironed"))

  ;; ── tidying: putting things back, room by room. No means, no materials —
  ;; the purest case of the file's point, a task that is labour and nothing else.
  (let ((p (hh-process "rp-hh-tidy" "Tidy a room" 0.25)))
    (hh-def p
             (list (hh-work "rf-hh-td-work" 0.25 "rp-hh-tidy")
                   (hh-produce "rf-hh-td-out" "spec-hh-rooms-tidy" 1 "rp-hh-tidy"
                               #:primary #t))
             "recipe-hh-tidy" "Tidying" "spec-hh-rooms-tidy"))

  ;; ── bed linen: 10 min a bed, and it FEEDS the laundry chain — the sheets
  ;; that come off are 2 kg of the dirty laundry the wash recipe consumes.
  (let ((p (hh-process "rp-hh-bedlinen" "Change the bed linen" 0.15)))
    (hh-def p
             (list (hh-work "rf-hh-bl-work" 0.15 "rp-hh-bedlinen")
                   (hh-consume "rf-hh-bl-in" "spec-hh-laundry-ironed" 2 "rp-hh-bedlinen")
                   (hh-produce "rf-hh-bl-out" "spec-hh-bed-made" 1 "rp-hh-bedlinen"
                               #:primary #t)
                   (hh-produce "rf-hh-bl-dirty" "spec-hh-laundry-dirty" 2 "rp-hh-bedlinen"))
             "recipe-hh-bedlinen" "Changing the bed" "spec-hh-bed-made"))

  ;; ── windows: 10 m² of glass in half an hour ────────────────────────────────
  (let ((p (hh-process "rp-hh-windows" "Clean the windows" 0.5)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-wn-work" 0.5 "rp-hh-windows")
                    (hh-use "rf-hh-wn-cloth" "spec-hh-cloths" 1 0.5 "rp-hh-windows")
                    (hh-produce "rf-hh-wn-out" "spec-hh-windows-cleaned" 10 "rp-hh-windows"
                                #:primary #t))
              (hh-wet-flows "rf-hh-wn" "rp-hh-windows" #:water 3 #:soap 0.005 #:soil 0.05))
             "recipe-hh-windows" "Window cleaning" "spec-hh-windows-cleaned"))

  ;; ── the houseplants: six minutes and 5 L, which leave with the plants ──────
  ;; Water is the only input, and it goes into leaves and air rather than a
  ;; drain: nothing tracked crosses, so the ledger is silent and correct.
  (let ((p (hh-process "rp-hh-plants" "Water the houseplants" 0.1)))
    (hh-def p
             (list (hh-work "rf-hh-pl-work" 0.1 "rp-hh-plants")
                   (hh-water "rf-hh-pl-water" 5 "rp-hh-plants")
                   ;; what the pots drink the leaves breathe out: the water leaves as the vapour it
                   ;; becomes, lifted by the room's own warmth (0.678 kWh a kilogram at 25 °C,
                   ;; catalogues/substances.scm latent-heat-kwh-per-kg)
                   (make-recipe-flow #:id "rf-hh-pl-vapour" #:action 'produce
                                     #:resource-conforms-to "h2o-g"
                                     #:resource-quantity (make-measure 5 "kg")
                                     #:recipe-output-of "rp-hh-plants")
                   (make-recipe-flow #:id "rf-hh-pl-warmth" #:action 'consume #:resource-conforms-to "ambient-heat" #:resource-quantity (make-measure 3.4 "kWh")
                                     #:recipe-input-of "rp-hh-plants")
                   (hh-produce "rf-hh-pl-out" "spec-hh-plants-watered" 1 "rp-hh-plants"
                               #:primary #t))
             "recipe-hh-plants" "Watering the plants" "spec-hh-plants-watered"))))

;; the TASKS, which is what a solve is handed — `rp-hh-living` is not among them
;; (see its comment above: a planner given it will make dirt in order to clean it)
(define household-processes (hh-defs-processes household-recipe-defs))
(define household-flows (hh-defs-flows household-recipe-defs))
;; the week's mess, for a caller that wants to seed it as stock rather than solve it
(define household-living-flows (hh-defs-flows household-living-defs))

(define (seed-household-recipes recipe-store)
  "Seed the household's domestic-work recipes: living (the boundary process that
   makes the dirt), vacuuming, dusting, mopping, the bathroom, dishes by hand and
   by machine, laundry, line-drying, ironing, tidying, bed linen, windows and the
   plants."
  (seed-household-specs recipe-store)
  (hh-seed-defs! recipe-store (append household-living-defs household-recipe-defs)))

;;; ─── the waste arm: sorting, the bins, the bottle bank, the Pfand ────────────
;;; What leaves a dwelling is as much of housework as what happens inside it, and
;;; it is the arm with the most structure: a stream split, four weekly trips, and
;;; one that pays.
;;;
;;; ── the split ────────────────────────────────────────────────────────────────
;;; `rp-hh-sort` separates the day's discards into the streams the kerbside
;;; scheme collects, and takes the cleaning waste with it — soil off the floor is
;;; residual waste, and the two rows are composed identically, so it joins that
;;; stream without disturbing the balance.
;;;
;;; Conservation across a SPLIT works the same way as everywhere else here, with
;;; no element number typed: `spec-hh-discards` is declared in catalogues/substances.scm as
;;; the weighted mixture of exactly these five streams in exactly these
;;; proportions, so what the sort produces is what the discards were. Change a
;;; yield below and the row is the one other place to change.
;;;
;;; ── the streams ──────────────────────────────────────────────────────────────
;;; (spec suffix · share of discards · label). The split follows the German
;;; kerbside scheme — Biotonne, Blaue Tonne, Gelbe Tonne, Restmüll, with glass to
;;; a Glascontainer and deposit containers back to the shop. A scope with a
;;; different scheme edits this one table and the matching *contains* row.
(define *household-waste-streams*
  '(("organics"  0.40 "Biotonne")
    ("paper"     0.20 "Blaue Tonne")
    ("glass"     0.12 "Glascontainer")
    ("packaging" 0.13 "Gelbe Tonne")
    ("residual"  0.15 "Restmüll")))

;;; What one trip carries and what it costs. Glass is the odd one: no bin at the
;;; door, so it is a walk to the container and the longest trip of the four.
(define *household-bin-runs*
  ;; (stream  kg-per-run  hours  name)
  '(("organics"  10 0.1  "Take the Biotonne down")
    ("paper"      8 0.1  "Take the paper bin down")
    ("packaging"  6 0.1  "Take the packaging bin down")
    ("residual"  10 0.1  "Take the residual bin down")
    ("glass"     10 0.3  "Walk the glass to the bottle bank")))

(define %hh-sort-batch 8.0)     ; kg of discards one sort run handles
(define %hh-sort-cleaning 0.2)  ; kg of binned cleaning waste it takes along
(define %hh-pfand-bottles 20)   ; containers one return trip carries
(define %hh-pfand-rate 0.25)    ; € each — the German deposit on a can or PET bottle

(define household-waste-recipe-defs
  (append
  ;; ── sorting ────────────────────────────────────────────────────────────────
  (list
   (let ((p (hh-process "rp-hh-sort" "Sort the discards into streams" 0.2)))
    (hh-def p
             (append
              (list (hh-work "rf-hh-so-work" 0.2 "rp-hh-sort")
                    (hh-consume "rf-hh-so-in" "spec-hh-discards" %hh-sort-batch "rp-hh-sort")
                    (hh-consume "rf-hh-so-cleaning" "spec-hh-waste" %hh-sort-cleaning
                                "rp-hh-sort"))
              (map (lambda (row)
                     (let* ((stream (car row))
                            (share (cadr row))
                            (qty (+ (* share %hh-sort-batch)
                                    ;; the cleaning waste is residual waste
                                    (if (string=? stream "residual") %hh-sort-cleaning 0))))
                       (hh-produce (string-append "rf-hh-so-" stream)
                                   (string-append "spec-hh-" stream) qty "rp-hh-sort"
                                   #:primary (string=? stream "organics"))))
                   *household-waste-streams*))
             "recipe-hh-sort" "Sorting the waste" "spec-hh-organics")))

  ;; ── the trips: each stream out to where it is collected ────────────────────
  ;; A run moves matter and changes nothing about it, so the collected spec is
  ;; declared identical to the stream and the balance is exact by construction.
  ;; What the run really costs is the walk down and the bin, and that is what
  ;; makes "who takes the bins out" a question a plan can answer.
  (map
   (lambda (row)
     (let* ((stream (car row)) (kg (cadr row)) (hours (caddr row)) (name (cadddr row))
            (pid (string-append "rp-hh-bin-" stream))
            (p (hh-process pid name hours)))
       (hh-def p
                (list (hh-work (string-append "rf-hh-bin-" stream "-work") hours pid)
                      (hh-use (string-append "rf-hh-bin-" stream "-bin")
                              "spec-hh-bin" 1 hours pid)
                      (hh-consume (string-append "rf-hh-bin-" stream "-in")
                                  (string-append "spec-hh-" stream) kg pid)
                      (hh-produce (string-append "rf-hh-bin-" stream "-out")
                                  (string-append "spec-hh-" stream "-collected") kg pid
                                  #:primary #t))
                (string-append "recipe-hh-bin-" stream) name
                (string-append "spec-hh-" stream "-collected"))))
   *household-bin-runs*)

  ;; ── the deposit return: the one household task that pays ───────────────────
  ;; Twenty containers at 25 cents is €5 for twenty-four minutes — and stating it
  ;; as a recipe is what lets a plan see it as work with a wage rather than as
  ;; thrift.
  ;;
  ;; The containers are COUNTED, not weighed — Pfand is 25 cents a bottle — so
  ;; they carry no composition: a mass fraction against a count is meaningless
  ;; (the skewer lesson, open-threads §2.3). The sweep does not list the gap,
  ;; because `rp-hh-living` produces them and a produced spec is treated as
  ;; derivable; a mass per container is what would close it, and until somebody
  ;; states one the bottles are outside the matter ledger by unit, not by
  ;; oversight. They carry no tracked element in either direction, so nothing
  ;; downstream is misled.
  (list
   (let ((p (hh-process "rp-hh-pfand" "Return the deposit containers" 0.4)))
    (hh-def p
             (list (hh-work "rf-hh-pf-work" 0.4 "rp-hh-pfand")
                   (hh-consume "rf-hh-pf-in" "spec-hh-deposit-bottles"
                               %hh-pfand-bottles "rp-hh-pfand")
                   (make-recipe-flow #:id "rf-hh-pf-out" #:action 'produce #:resource-conforms-to "spec-eur"
                                     #:resource-quantity (make-measure (* %hh-pfand-bottles %hh-pfand-rate) "EUR") #:recipe-output-of "rp-hh-pfand" #:is-primary #t))
             "recipe-hh-pfand" "Deposit return" "spec-eur")))))

(define household-waste-processes (hh-defs-processes household-waste-recipe-defs))
(define household-waste-flows (hh-defs-flows household-waste-recipe-defs))

(define (seed-household-waste-recipes recipe-store)
  "Seed the waste arm: sorting the discards into streams, the bin runs that put
   each stream out for collection, and the deposit return. The discards
   themselves come from `rp-hh-living` in `seed-household-recipes`."
  (seed-household-specs recipe-store)
  (hh-seed-defs! recipe-store household-waste-recipe-defs))

;;; ─── cooking and care: the reproductive labour never listed ────────────
;;; docs/planning/food/reproduction-of-labour-power.md §4 names the gap by name:
;;; "cooking, care of the sick and old, and child-minding are not yet one
;;; family of recipes" — cleaning, dishes and laundry, above, already are.
;;; This closes it at the same DRAFT weight as the rest of the file: real
;;; recipes a plan can choose among, illustrative numbers a household with
;;; its own measure replaces without touching the mechanism.
;;;
;;; Cooking draws material — raw food becomes a meal, the transformation the
;;; nutrient catalogue's `eat` recipe is silent about (it reads bare food, the
;;; way `spec-water`'s litre is read bare of who drew it). A cooked meal is a
;;; STATE, not a new nutrient: `spec-hh-meal-cooked` carries an empty
;;; composition row (catalogues/substances.scm), the same convention `spec-hh-floor-
;;; cleaned` and every other delivered state in this file already stand on.
;;;
;;; Care is labour and nothing else — the purest case the file's own header
;;; names, `rp-hh-tidy`'s shape: an hour of a body minded or nursed is an hour
;;; delivered 1:1 from an hour worked, no means, no materials. This is where
;;; §2a's line falls: giving care is SNLT (another person's hour can stand in
;;; for it), receiving care while ill is SNIRT (the sick person's own time,
;;; agent-time.scm's away: tag) — two sides of the same act, each read on its
;;; own ledger. Childcare and eldercare are named as two skills, not one, so a
;;; scope that wants to see who holds which reads them apart — neither
;;; carries a floor of its own here, and WHO owes what inside a household
;;; (§6) stays open; this states only that the hours are real and drawn from
;;; the same time budget as any other work. `hh-pure-care`, below, is the one
;;; shape both are built from.
;; The pure-care shape: an hour of a body minded or nursed, delivered 1:1 from
;; an hour worked under its own skill line — no means, no materials, the
;; purest case `rp-hh-tidy`'s own shape names. One generator, so the NEXT care
;; category this family gains (companionship, tutoring, …) gets the shape
;; right by construction instead of by copying childcare's or eldercare's.
(define (hh-pure-care rid rf-prefix name skill spec-out recipe-id)
  (let ((p (hh-process rid name 1.0 #:tags '("tag:housework" "tag:care"))))
    (hh-def p
             (list (hh-work (string-append rf-prefix "-work") 1.0 rid #:skill skill)
                   (hh-produce (string-append rf-prefix "-out") spec-out 1.0 rid #:primary #t))
             recipe-id name spec-out)))

(define household-care-recipe-defs
  (list
  ;; ── cooking: 45 min for a family meal, a modest gas/electric draw. The
  ;; water boils into steam — rp-hh-plants' own point, not the sink's: it
  ;; leaves as vapour, not greywater (hh-wet-flows is for a task that
  ;; drains, and cooking does not), so the balance is h2o-g out for the
  ;; water in, the ambient heat its evaporation spends — rp-hh-plants' own
  ;; rate, 0.68 kWh/kg ─────────────────────────────────────────────────────
  (let ((p (hh-process "rp-hh-cook" "Cook a meal" 0.75 #:tags '("tag:housework" "tag:care"))))
    (hh-def p
             (list (hh-work "rf-hh-ck-work" 0.75 "rp-hh-cook" #:skill "skill-hh-cooking")
                   (hh-consume "rf-hh-ck-in" "spec-hh-food-raw" 1.5 "rp-hh-cook")
                   (hh-water "rf-hh-ck-water" 2 "rp-hh-cook")
                   (hh-power "rf-hh-ck-power" 0.8 "rp-hh-cook")
                   (make-recipe-flow #:id "rf-hh-ck-vapour" #:action 'produce
                                     #:resource-conforms-to "h2o-g"
                                     #:resource-quantity (make-measure 2 "kg")
                                     #:recipe-output-of "rp-hh-cook")
                   (make-recipe-flow #:id "rf-hh-ck-warmth" #:action 'consume #:resource-conforms-to "ambient-heat" #:resource-quantity (make-measure 1.36 "kWh")
                                     #:recipe-input-of "rp-hh-cook")
                   (hh-produce "rf-hh-ck-out" "spec-hh-meal-cooked" 4 "rp-hh-cook"
                               #:primary #t))
             "recipe-hh-cook" "Cooking" "spec-hh-meal-cooked"))

  ;; ── childcare and eldercare/sick-care: the same shape, each its own skill ──
  (hh-pure-care "rp-hh-mind-child" "rf-hh-cc" "Mind a child"
                "skill-hh-childcare" "spec-hh-child-minded" "recipe-hh-mind-child")
  (hh-pure-care "rp-hh-care" "rf-hh-cr" "Care for someone sick or old"
                "skill-hh-eldercare" "spec-hh-care-given" "recipe-hh-care")))

(define household-care-processes (hh-defs-processes household-care-recipe-defs))
(define household-care-flows (hh-defs-flows household-care-recipe-defs))

(define (seed-household-care-recipes recipe-store)
  "Seed cooking, childcare and eldercare/sick-care alongside the rest of the
   household's own work."
  (seed-household-specs recipe-store)
  (hh-seed-defs! recipe-store household-care-recipe-defs))

;;; ─── the kit as resources a household (or a block) HOLDS ─────────────────────
;;; The durables are `use`d, so what matters is how many exist and who holds
;;; them. Seeded once for the holder, they are a pool: one dishwasher shared by
;;; four households is four households' worth of demand against two hours of
;;; machine time each, and the plan says whether that fits.
(define* (seed-household-kit! obs #:key (place "berlin") (holder "commune-berlin")
                                        (sets 1))
  "Seed SETS of the household kit into HOLDER's holdings at PLACE. SETS is how
   many simultaneous households the means can serve."
  (for-each
   (lambda (row)
     (let* ((spec (car row))
            (qty (* sets (cdr row)))
            (m (make-measure qty %count-unit)))
       ($ obs 'record-resource
          (make-economic-resource
           #:id (string-append spec "-pool") #:name (or (and=> (assoc spec *household-specs*) cadr) spec) #:conforms-to spec #:classified-as '("household" "kit") #:accounting-quantity m #:onhand-quantity m
           #:current-location place #:primary-accountable holder))))
   *household-kit*))
