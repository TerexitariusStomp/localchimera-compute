;;; navdanya-farm.scm — a REAL bounded scope: a Navdanya-style smallholding in
;;; the Doon Valley, planned robustly against the region's monsoon futures. This
;;; is W1 (inscribe a real in-natura scope) made concrete, standing on the real
;;; data in knowledge/doon-valley.scm + docs/planning/food/agroecology-bring-over.md.
;;;
;;; Loaded after planner.scm + solve/robust.scm + worlds/doon-valley.scm. Provides
;;;   (navdanya-farm-records #:land-ha … #:household …)  → (values resources procs flows)
;;;   *navdanya-biofertilizers*  — the real on-farm input recipes (§3), as data.
;;;   navdanya-food-floor        — a household's seasonal subsistence grain floor.
;;;
;;; SCOPE (honest): the SCENARIO-sensitive staple rotation — rice, maize, finger
;;; millet, pulses, wheat — with real Uttarakhand yields (worlds/doon-valley.scm). The
;;; farm's ~40 other ledger crops (vegetables/spices, agroecology-bring-over §1.1)
;;; are real primary data but lack per-ha yields, so they're out of the yield
;;; model for now (extend when GAEZ/FAOSTAT per-crop yields land — §9.1).

;; The KHARIF (monsoon-season) staples the scenarios actually move — each a
;; first-stage grow proc. Wheat is RABI (winter, largely irrigated ⇒ not
;; monsoon-sensitive), so it's a separate season, not in this scenario set.
(define *navdanya-staples* '("rice" "maize" "ragi" "pulses"))

;; A household's seasonal SUBSISTENCE floor on food (kg grain). Reproduction of
;; labour-power: FAO/ICMR ~ a person needs ~180 kg cereal-equiv/yr; a season
;; (~1/2 yr of the kharif staples) ⇒ ~90 kg/person. Defended in EVERY monsoon
;; future by the robust `bar` floor — the whole point.
(define (navdanya-food-floor household) (* 90.0 household))   ; kg / season

;; The real regenerative INPUT recipes (agroecology-bring-over §3.1) — kept as
;; data (name . inputs→output, per-acre rate). They close the metabolic-rift loop
;; (on-farm dung/waste → soil fertility) — the loop the soil-fertility REGENERATING
;; STOCK below now carries through time (planner/formulas/stocks.scm): each rebuilds the
;; `soil-fertility` condition a `produce` flow, exactly as the biofertiliser prose
;; describes. (Soil is the durable-condition pattern generalised — the "next
;; structural step" the earlier note pointed at, now done; see soil-recurrence-test.)
(define *navdanya-biofertilizers*
  '((amrit-pani  . "10 kg cow-dung + 0.25 kg ghee + 0.5 kg honey (or 1 kg jaggery) + 200 L water → ~200 L, per acre, then mulch")
    (jeevamrit   . "200 L water + 10 kg cow-dung + 10 L cow-urine + 2 kg legume-flour + 2 kg jaggery + 1 fistful soil → ready day 3, per acre")
    (fym-compost . "pit 10×3×3 ft; manure:green:dry = 25:25:50 → ~3 months")))

;; ── SOIL FERTILITY as a REGENERATING STOCK (planner/formulas/stocks.scm) ──────────────
;; The topsoil the farm stands on is a CONDITION it can MINE or TEND: a carried
;; level, drawn down as crops grow and rebuilt by the biofertilisers above (and by
;; a legume, which FIXES nitrogen — cropping that RESTORES). This is what closes
;; the metabolic-rift loop the biofertiliser recipes only described: the recurrence
;;     SOC[t+1] = SOC[t] − draw(cropping) + restore(compost, legume, fallow)
;; carried year to year by the storable spine (the same one the granary uses).
;;
;; Grounded, first-pass: the starting level is the REAL SoilGrids state — topsoil
;; organic carbon 34.3 g/kg, 0–30 cm (data/process-eco.scm; the very number the
;; `topsoil` fragility watches). The per-crop draws are ordered by agronomy — rice/
;; maize are heavy feeders that export residue, finger millet is frugal, and a pulse
;; is NET-NEGATIVE (biological N-fixation), which is WHY a legume rotation rebuilds
;; a mined field. Exact per-crop SOC/N budgets (FAO/IPNI nutrient-removal, RothC
;; turnover) are the calibration follow-on, alongside the per-crop yield functions
;; (§9.1) — the same EXTERNAL-data gap. The MECHANISM here is exact; the coefficients
;; are honest placeholders in the right ranks and magnitudes (Δ SOC ≈ t C·ha⁻¹·yr⁻¹).
(define *navdanya-soil-init* 34.3)         ; SOC g/kg — the fertility index, from SoilGrids (doon)
(define *navdanya-soil-floor* 20.0)        ; SOC g/kg below which the topsoil degrades (a tended floor)
(define *navdanya-crop-draw*               ; fertility index drawn per hectare-season
  '(("rice"   .  2.4)                       ; paddy — heavy feeder, high residue export
    ("maize"  .  2.2)
    ("wheat"  .  1.8)
    ("ragi"   .  1.0)                       ; finger millet — frugal, a soil-sparing staple
    ("pulses" . -1.2)))                     ; LEGUME — fixes N: a NET restore while it feeds (the rotation)
(define (navdanya-crop-draw crop) (or (assoc-ref *navdanya-crop-draw* crop) 1.5))
;; Biofertiliser REBUILD rate — SOC index rebuilt per unit applied (a batch/acre).
;; Jeevamrit/FYM return dung-carbon and microbial biomass to the soil; ranked below
;; the annual crop draw so tending is a real, bounded effort, not a free refill.
(define *navdanya-regen-rate* 1.6)         ; SOC index per compost batch (FYM/jeevamrit, per ha-season)

;; Build the farm as VF records for a plan: `land-ha` hectares, staples each a
;; grow recipe (consume 1 ha, produce `food` at its real yield), one place.
;; `reserve` kg of stored food = a GRANARY carried into the season (banked from
;; prior good years — antifragility: a good year's surplus, not consumed, becomes
;; the buffer that survives the tail). It's just a starting on-hand stock of the
;; `food` good (*init*), available in every future — inert surplus in a good year,
;; the difference between life and famine in the tail. RUIN-robust with reserves
;; raises the guaranteed carrying capacity; the same food machinery, no new parts.
(define* (navdanya-farm-records #:key (land-ha 2.0) (place "doon-farm") (reserve 0.0))
  (let* ((resources
          (cons (make-economic-resource #:id "land" #:conforms-to "land" #:classified-as '()
                  #:accounting-quantity (make-measure land-ha "ha") #:onhand-quantity (make-measure land-ha "ha") #:current-location place)
                (if (> reserve 0.0)
                    (list (make-economic-resource #:id "granary" #:conforms-to "food" #:classified-as '()
                            #:accounting-quantity (make-measure reserve "kg") #:onhand-quantity (make-measure reserve "kg") #:current-location place))
                    '())))
         (procs (map (lambda (c) (make-recipe-process #:id c #:name (string-append "Grow " c)))
                     *navdanya-staples*))
         (flows (append-map
                 (lambda (c)
                   (list (make-recipe-flow #:id (string-append c "-land") #:action 'consume
                                           #:resource-conforms-to "land"
                                           #:resource-quantity (make-measure 1.0 "ha")
                                           #:recipe-input-of c)
                         (make-recipe-flow #:id (string-append c "-food") #:action 'produce #:resource-conforms-to "food"
                           #:resource-quantity (make-measure (assoc-ref *doon-valley-crop-yields* c) "kg") #:recipe-output-of c #:is-primary #t)))
                 *navdanya-staples*)))
    (values resources procs flows)))

;; ── Deep time: a farm across a SEQUENCE of seasons ───────────────────────────
;; Land as a RENEWABLE per-period capacity — `use`d, not consumed, its service
;; Svc|land returning each season (a stationary durable). Food is storable across
;; years. A `weather` list gives each year's USABLE land (ha) — a drought shrinks
;; it. With the floor due EVERY year, the plan banks the good years of its own
;; accord to hold the drought. This reuses the durable-capacity (Svc, capped
;; per-cell), storage-through-time, and reproduction-floor machinery WHOLE — no
;; new parts; the t0-harvest model was just one wiring of it.
(define* (plan-navdanya-years #:key (household 10) (place "doon-farm")
                                    (weather '(2.0 2.0 0.2)))   ; usable ha per year; a small year is a drought
  (let* ((years (iota (length weather)))
         (yield (assoc-ref *doon-valley-crop-yields* "rice"))
         (resources (list (make-economic-resource #:id "land" #:image (list "stationary") #:conforms-to "land" #:classified-as (list "stationary")
                            #:accounting-quantity (make-measure 100.0 "ha") #:onhand-quantity (make-measure 100.0 "ha") #:current-location place)))
         (procs (list (make-recipe-process #:id "grow" #:name "Grow")))
         (flows (list (make-recipe-flow #:id "gl" #:action 'use #:resource-conforms-to "land"
                                        #:resource-quantity (make-measure 1.0 "ha")
                                        #:recipe-input-of "grow")
                      (make-recipe-flow #:id "gf" #:action 'produce #:resource-conforms-to "food"
                                        #:resource-quantity (make-measure yield "kg")
                                        #:recipe-output-of "grow" #:is-primary #t)))
         (floor (navdanya-food-floor household))
         (eco-caps  (map (lambda (t ha) (cons (lg (svc-good "land") (cell place t))
                                              (stock->flow ha t)))      ; usable ha × the season's hours
                             years weather))     ; per-year usable land
         (floors    (map (lambda (t)    (cons (lg "food" (cell place t)) floor)) years)))
    (call-with-values
      (lambda () (plan-from-records resources '()
                   (list (make-spatial-thing #:id place #:lat 30.32 #:long 78.03)) procs flows
                   #:periods years #:storable '("food") #:eco-caps eco-caps #:repro-floors floors #:per-agent? #f))
      (lambda (i c material f cols x idx nt rep)
        (map (lambda (t)                                             ; ha grown each year
               (let ((k (process-col "grow" (cell place t))))
                 (* yield (if (hash-ref idx k #f) (vector-ref x (hash-ref idx k)) 0.0))))
             years)))))

;; Robust plan for the farm over the Doon Valley monsoon scenarios. The farm sits
;; INSIDE its bioregion (the SpatialThing tree place ⊂ bioregion ⊂ biosphere), and
;; when #:scenarios is left #f it INHERITS the shed's climate futures by the walk up
;; the containment tree (bioregions.scm) — the generic onboarding: placement, not
;; per-farm wiring, supplies the weather. Pass #:scenarios to override (e.g. the
;; tail-robust set). Returns the report alist (with 'first-stage-plan, in ha).
(define* (plan-navdanya-farm #:key (land-ha 2.0) (household 5) (place "doon-farm")
                                   (bioregion "doon-shed") (scenarios #f) (reserve 0.0))
  (call-with-values (lambda () (navdanya-farm-records #:land-ha land-ha #:place place #:reserve reserve))
    (lambda (resources procs flows)
      (let* ((spatials (list (make-spatial-thing #:id "biosphere" #:lat 0.0 #:long 0.0)
                             (make-spatial-thing #:id bioregion #:name "Doon Valley watershed"
                                                 #:lat 30.32 #:long 78.03 #:contained-in "biosphere")
                             (make-spatial-thing #:id place #:name "Navdanya-style farm" #:lat 30.32
                                                 #:long 78.03 #:contained-in bioregion)))
             ;; inherit from the bioregion unless overridden: seed the shed with the
             ;; region's monsoon scenarios, then resolve them by containment.
             (scen (or scenarios
                       (begin (attach-bioregion-scenarios! bioregion *doon-valley-scenarios*)
                              (scope-bioregion-scenarios spatials)))))
        (call-with-values
          (lambda ()
            (plan-from-records resources '() spatials procs flows
              #:scenarios scen
              #:first-stage-procs *navdanya-staples*
              #:repro-floors (list (cons (string-append "food#" place "@0") (navdanya-food-floor household)))
              #:demand (list (cons (string-append "food#" place "@0") (* 6.0 (navdanya-food-floor household))))  ; surplus for market
              #:per-agent? #f))
          (lambda (ints coms material fill cols x idx ntot report) report))))))
