;;; humisoil-recipe.scm — HumiSoil soil-amendment recipe
;;;
;;; HumiSoil is a high-humus soil restoration product made by fermenting
;;; organic biomass with a food-grade liquid microbial catalyst under tarp
;;; for ~6 months. Process populates archaea and photosynthetic microbes;
;;; near-zero emissions because those microbes consume ammonia/methane/H2S.
;;;
;;; The nutrient content of the product is NOT typed here: only the biomass
;;; feedstock's composition is authored (knowledge/catalogues/substances.scm), and prepped
;;; → windrow → HumiSoil all DERIVE from it as the matter wire chains
;;; `derive-contains` to a fixpoint. Faithful to the process's near-zero-emissions
;;; claim, the C/N/P/K that enter as biomass leave in the HumiSoil (water is what
;;; evaporates), so the carbon loop closes — see test-humisoil-recipe.scm.
;;;
;;; Three-step recipe:
;;;   rp-prep    — chip/grind raw biomass
;;;   rp-windrow — apply catalyst spray, build M-shape windrow at 65%
;;;                moisture, cover with tarp
;;;   rp-ferment — 180-day tarp-sealed fermentation → HumiSoil

(define-module (playnet planner knowledge recipes humisoil)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:export (*humisoil-spec-names* *humisoil-spec-units* seed-humisoil-specs
            seed-humisoil-recipe)
  #:use-module (srfi srfi-1))


(define *humisoil-spec-names*
  '(("spec-biomass"          . "Organic Biomass")
    ("spec-catalyst"         . "Microbial Catalyst (liquid, food-grade)")
    ("spec-water"            . "Water")
    ("spec-prepped-biomass"  . "Prepped Biomass (chipped/ground)")
    ("spec-covered-windrow"  . "Covered Windrow")
    ("spec-humisoil"         . "HumiSoil")
    ("spec-tarp"             . "Tarp")
    ("spec-loader"           . "Front-End Loader")
    ("spec-chipper"          . "Chipper/Grinder")
    ("spec-trommel-sprayer"  . "Trommel Sprayer")))

(define *humisoil-spec-units*
  '(("spec-biomass"          . "kg")
    ("spec-catalyst"         . "liters")
    ("spec-water"            . "liters")
    ("spec-prepped-biomass"  . "kg")
    ("spec-covered-windrow"  . "kg")
    ("spec-humisoil"         . "kg")
    ("spec-tarp"             . "each")
    ("spec-loader"           . "each")
    ("spec-chipper"          . "each")
    ("spec-trommel-sprayer"  . "each")))

(define (seed-humisoil-specs recipe-store)
  "Add HumiSoil resource specifications to a recipe store."
  (for-each
    (lambda (pair)
      (let* ((id   (car pair))
             (name (cdr pair))
             (unit (or (assoc-ref *humisoil-spec-units* id) "each")))
        ($ recipe-store 'add-resource-spec
           (make-resource-specification #:id id #:name name #:default-unit-of-resource unit))))
    *humisoil-spec-names*))

(define (seed-humisoil-recipe recipe-store)
  "Seed the HumiSoil 3-step production recipe.
   Indicative quantities are per ~1000 kg input-biomass batch; the planner
   scales linearly for actual demand."

  ;; ── Step 1: Prep — chip/grind raw biomass ────────────────────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-prep" #:name "Biomass Prep"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-prep" #:name "Chip/grind biomass"
                          #:process-conforms-to "pspec-prep" #:process-classified-as '("tag:material-handling")
                          #:has-duration (make-duration 4 "hours")))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-prep-biomass-in" #:action 'consume #:resource-conforms-to "spec-biomass"
                       #:resource-quantity (make-measure 1000 "kg") #:recipe-input-of "rp-prep"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-prep-loader-use" #:action 'use #:resource-conforms-to "spec-loader"
                       #:resource-quantity (make-measure 1 "each") #:recipe-input-of "rp-prep"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-prep-chipper-use" #:action 'use #:resource-conforms-to "spec-chipper"
                       #:resource-quantity (make-measure 1 "each") #:recipe-input-of "rp-prep"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-prep-work" #:action 'work #:effort-quantity (make-measure 4 "hours")
                       #:recipe-input-of "rp-prep"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-prep-out" #:action 'produce #:resource-conforms-to "spec-prepped-biomass"
                       #:resource-quantity (make-measure 950 "kg") #:recipe-output-of "rp-prep"))

  ;; ── Step 2: Windrow — catalyst spray, M-shape, tarp at 65% moisture ──────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-windrow" #:name "Windrow Formation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-windrow" #:name "Build M-windrow & seal under tarp"
                          #:process-conforms-to "pspec-windrow" #:process-classified-as '("tag:material-handling")
                          #:has-duration (make-duration 2 "hours")))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-prepped-in" #:action 'consume #:resource-conforms-to "spec-prepped-biomass"
                       #:resource-quantity (make-measure 950 "kg") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-catalyst-in" #:action 'consume #:resource-conforms-to "spec-catalyst"
                       #:resource-quantity (make-measure 30 "liters") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-water-in" #:action 'consume #:resource-conforms-to "spec-water"
                       #:resource-quantity (make-measure 600 "liters") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-loader-use" #:action 'use #:resource-conforms-to "spec-loader"
                       #:resource-quantity (make-measure 1 "each") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-trommel-use" #:action 'use #:resource-conforms-to "spec-trommel-sprayer"
                       #:resource-quantity (make-measure 1 "each") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-tarp-use" #:action 'use #:resource-conforms-to "spec-tarp"
                       #:resource-quantity (make-measure 1 "each") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-work" #:action 'work
                       #:effort-quantity (make-measure 2 "hours") #:recipe-input-of "rp-windrow"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-windrow-out" #:action 'produce #:resource-conforms-to "spec-covered-windrow"
                       #:resource-quantity (make-measure 1580 "kg") #:recipe-output-of "rp-windrow"))

  ;; ── Step 3: Ferment — 180 days under tarp → HumiSoil ─────────────────────
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-ferment" #:name "Tarp Fermentation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-ferment" #:name "Ferment under tarp (6 months)"
                          #:process-conforms-to "pspec-ferment" #:process-classified-as '("tag:fermentation")
                          #:has-duration (make-duration 180 "days")))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-ferment-in" #:action 'consume #:resource-conforms-to "spec-covered-windrow"
                       #:resource-quantity (make-measure 1580 "kg") #:recipe-input-of "rp-ferment"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-ferment-work" #:action 'work
                       #:effort-quantity (make-measure 1 "hours") #:recipe-input-of "rp-ferment"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-ferment-out" #:action 'produce #:resource-conforms-to "spec-humisoil"
                       #:resource-quantity (make-measure 1200 "kg") #:recipe-output-of "rp-ferment"))

  ;; ── Bundle ───────────────────────────────────────────────────────────────
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-humisoil" #:name "HumiSoil Production" #:primary-output "spec-humisoil"
                  #:recipe-processes (list "rp-prep" "rp-windrow" "rp-ferment"))))
