;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; brandenburg-farm.scm — a REAL bounded scope in the Berlin/Brandenburg shed, the
;;; structural twin of navdanya-farm.scm (Doon). Same builders, same robust machinery,
;;; DIFFERENT DATA: a temperate market-garden farm on the sandy soils around Berlin,
;;; planned against the region's real continental futures (berlin.scm). This is the
;;; "spin up any region with the same infrastructure" claim made concrete a third time —
;;; the farm inherits its weather and its ecological limits from WHERE IT SITS, not from
;;; per-farm wiring (bioregions.scm containment).
;;;
;;; Loaded after planner.scm + solve/robust.scm + knowledge/berlin.scm. Provides
;;;   (brandenburg-farm-records #:land-ha … #:place … #:reserve …) → (values res procs flows)
;;;   (plan-brandenburg-farm    #:land-ha #:household #:scenarios …) → the report alist.
;;;
;;; SCOPE (honest): the SCENARIO-sensitive grain staples — winter wheat, winter barley,
;;; maize — with real German national yields (berlin.scm). Potato (the region's biggest
;;; food crop by tonnage) and winter rye (Brandenburg's signature sandy-soil grain, which
;;; has no OWID yield grapher — like Doon's ragi) are real ledger crops kept OUT of the
;;; "food kg" floor pool for now: potato is fresh-weight (not comparable to dry grain),
;;; rye awaits a yield source (§ the same GAEZ/FAOSTAT gap doon notes). Extend when landed.

;; The grain staples the scenarios actually move — each a first-stage grow proc. Chosen
;; comparable in the "food kg" pool (dry grain), spanning the drought-fragility spread:
;; maize is the high-yield but most drought-fragile (Ky 0.57), the small grains are the
;; drought-steadier hedge (wheat 0.64, barley 0.66) — the bet the robust plan diversifies.
(define *brandenburg-staples* '("wheat" "barley" "maize"))

;; A household's seasonal SUBSISTENCE floor on food (kg grain) — reproduction of
;; labour-power, the SAME region-agnostic figure the Doon farm defends: FAO/ICMR ~180 kg
;; cereal-equiv/person/yr ⇒ ~90 kg/person for a growing season. Defended in EVERY future
;; by the robust `bar` floor — the whole point of planning against the record, not the mean.
(define (brandenburg-food-floor household) (* 90.0 household))   ; kg / season

;; ── SOIL FERTILITY as a REGENERATING STOCK (planner/formulas/stocks.scm), grounded ────────────
;; The starting level is the REAL SoilGrids state at the shed — topsoil organic carbon
;; 23.5 g/kg (data/process-eco.scm; the very number the `topsoil` fragility watches).
;; Brandenburg's sands are CARBON-POOR (cf. Doon 34.3), so the mining floor bites sooner —
;; which is exactly why the regenerative rotation (a legume undersow, clover/lupin — the
;; regional analog of Navdanya's pulses) matters here. Per-crop draws ranked by agronomy;
;; exact SOC/N budgets are the calibration follow-on (the same EXTERNAL-data gap).
(define *brandenburg-soil-init* 23.5)        ; SOC g/kg — from SoilGrids (berlin)
(define *brandenburg-soil-floor* 15.0)       ; SOC g/kg below which the sandy topsoil degrades
(define *brandenburg-crop-draw*              ; fertility index drawn per hectare-season
  '(("maize"  .  2.4)                        ; silage maize — heavy feeder, high residue export
    ("wheat"  .  1.8)
    ("barley" .  1.4)                        ; frugaler small grain
    ("potato" .  2.6)                        ; intensive root crop — heavy on light soils
    ("clover" . -1.4)))                      ; LEGUME undersow — fixes N: a net restore (the rotation)
(define (brandenburg-crop-draw crop) (or (assoc-ref *brandenburg-crop-draw* crop) 1.5))
(define *brandenburg-regen-rate* 1.6)        ; SOC index per compost/manure batch (per ha-season)

;; The REAL limiting factor on Brandenburg's sands is SUMMER WATER, not land. Per-ha
;; seasonal irrigation demand (relative units, 1 ≈ 1000 m³/ha): maize is ~2× as thirsty
;; as the small grains — deep summer demand on droughty sand — while barley, harvested
;; earliest, escapes the driest weeks. This is the agronomy behind the shed's `groundwater`
;; fragility (Aqueduct 0.48 "High"): the crop that drives the harvest is also the one that
;; drives the draw. A scarce shed water budget therefore forces a rotation — you cannot
;; simply plant the whole field to thirsty maize even though its yield is highest.
(define *brandenburg-crop-water*
  '(("maize" . 4.0) ("wheat" . 2.2) ("barley" . 1.8) ("potato" . 3.6)))
(define (brandenburg-crop-water crop) (or (assoc-ref *brandenburg-crop-water* crop) 2.0))

;; Build the farm as VF records: `land-ha` hectares AND `water` (the shed's summer water
;; budget, units of 1000 m³) — two scarce inputs. Each grain staple is a grow recipe that
;; consumes 1 ha + its water demand and produces `food` at its real yield. `reserve` kg of
;; stored food = a granary carried in (a good year's banked surplus — the antifragile
;; buffer that survives the tail). Same shape as navdanya-farm-records; the water input +
;; the yields table (*berlin-crop-yields*) are what make this the Brandenburg scope.
(define* (brandenburg-farm-records #:key (land-ha 2.0) (water 6.0) (labour-h 2.0)
                                        (place "brandenburg-farm") (reserve 0.0))
  (let* ((resources
          (cons* (make-economic-resource #:id "land" #:conforms-to "land" #:classified-as '()
                   #:accounting-quantity (make-measure land-ha "ha") #:onhand-quantity (make-measure land-ha "ha") #:current-location place)
                 (make-economic-resource #:id "water" #:conforms-to "water" #:classified-as '()   ; the shed's scarce summer water
                   #:accounting-quantity (make-measure water "km3") #:onhand-quantity (make-measure water "km3") #:current-location place)
                 ;; a farm needs FARMERS — the grower's labour, held as a skill ER (the
                 ;; same `farming` skill the grow flows draw). Ample, so WATER, not labour,
                 ;; is the binding constraint (the drought story). This is what makes the
                 ;; offline model require labour to produce, CONSISTENT with the live seed
                 ;; (seed-berlin-commune!) — no free food in either.
                 (make-economic-resource #:id "skill-farming" #:conforms-to "farming" #:classified-as '()
                   #:accounting-quantity (make-measure 400.0 %effort-unit) #:onhand-quantity (make-measure 400.0 %effort-unit) #:primary-accountable "berlin-grower")
                (if (> reserve 0.0)
                    (list (make-economic-resource #:id "granary" #:conforms-to "food" #:classified-as '()
                            #:accounting-quantity (make-measure reserve "kg") #:onhand-quantity (make-measure reserve "kg") #:current-location place))
                    '())))
         (procs (map (lambda (c) (make-recipe-process #:id c #:name (string-append "Grow " c)))
                     *brandenburg-staples*))
         (flows (append-map
                 (lambda (c)
                   (list (make-recipe-flow #:id (string-append c "-work") #:action 'work
                                           #:resource-conforms-to "farming"
                                           #:effort-quantity (make-measure labour-h %effort-unit)
                                           #:recipe-input-of c)
                         (make-recipe-flow #:id (string-append c "-land") #:action 'consume
                                           #:resource-conforms-to "land"
                                           #:resource-quantity (make-measure 1.0 "ha")
                                           #:recipe-input-of c)
                         (make-recipe-flow #:id (string-append c "-water") #:action 'consume
                                           #:resource-conforms-to "water"
                                           #:resource-quantity (make-measure (brandenburg-crop-water c) "km3")
                                           #:recipe-input-of c)
                         (make-recipe-flow #:id (string-append c "-food") #:action 'produce #:resource-conforms-to "food"
                           #:resource-quantity (make-measure (assoc-ref *berlin-crop-yields* c) "kg") #:recipe-output-of c #:is-primary #t)))
                 *brandenburg-staples*)))
    (values resources procs flows)))

;; Robust plan for the farm over Berlin's real continental futures. The farm sits INSIDE
;; its bioregion (place ⊂ berlin ⊂ biosphere); with #:scenarios left #f it INHERITS the
;; shed's climate futures by the walk up the containment tree (bioregions.scm) — the
;; generic onboarding: placement, not per-farm wiring, supplies the weather. Pass
;; #:scenarios to override (e.g. the certainty-equivalent naive baseline). Returns the
;; report alist (with 'first-stage-plan, in ha). Mirrors plan-navdanya-farm exactly.
(define* (plan-brandenburg-farm #:key (land-ha 2.0) (water 6.0) (household 5) (place "brandenburg-farm")
                                      (bioregion "berlin") (scenarios #f) (reserve 0.0))
  (call-with-values (lambda () (brandenburg-farm-records #:land-ha land-ha #:water water #:place place #:reserve reserve))
    (lambda (resources procs flows)
      (let* ((spatials (list (make-spatial-thing #:id "biosphere" #:lat 0.0 #:long 0.0)
                             (make-spatial-thing #:id bioregion #:name "Berlin/Brandenburg"
                                                 #:lat 52.52 #:long 13.40 #:contained-in "biosphere")
                             (make-spatial-thing #:id place #:name "Brandenburg market-garden farm"
                                                 #:lat 52.48 #:long 13.40 #:contained-in bioregion)))
             ;; the grower who works the fields (holds the `farming` skill via the
             ;; skill-farming ER in the records) — a farm needs farmers, offline as live.
             (win (map (lambda (d) (cons d (cons 0 24))) '("mon" "tue" "wed" "thu" "fri" "sat" "sun")))
             (agents (list (make-agent #:id "berlin-grower" #:type 'person
                                       #:name "Brandenburg grower" #:primary-location place
                                       #:classified-as '() #:availability-window win)))
             ;; inherit from the bioregion unless overridden: seed the shed with the
             ;; region's futures, then resolve them by containment.
             (scen (or scenarios
                       (begin (attach-bioregion-scenarios! bioregion *berlin-scenarios*)
                              (scope-bioregion-scenarios spatials)))))
        (call-with-values
          (lambda ()
            (plan-from-records resources agents spatials procs flows
              #:scenarios scen
              #:first-stage-procs *brandenburg-staples*
              #:repro-floors (list (cons (string-append "food#" place "@0") (brandenburg-food-floor household)))
              #:demand (list (cons (string-append "food#" place "@0") (* 6.0 (brandenburg-food-floor household))))  ; surplus for market
              #:per-agent? #t))   ; explicit skilled worker supplies the labour (matches live)
          (lambda (ints coms material fill cols x idx ntot report) report))))))
