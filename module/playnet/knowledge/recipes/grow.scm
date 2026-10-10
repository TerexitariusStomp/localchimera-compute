;;; grow.scm — a crop grow recipe whose product's COMPOSITION IS THE RECIPE.
;;;
;;; The point of this recipe is the metabolic-rift question done in proper
;;; ValueFlows: a carrot's nutrients are not a number typed into a table — they
;;; are what the grow PROCESS drew from the soil. So this recipe consumes the
;;; nutrient substances (soil-N, soil-P, soil-K) and atmospheric carbon (CO₂),
;;; with water and labour, and produces the crop plus the runoff stream that
;;; bleeds nutrients back out. The crop's composition is then DERIVED off these
;;; flows (knowledge/catalogues/substances.scm `derive-contains`):
;;;
;;;     embodied-in-crop[e]  =  Σ consumed[e]  −  Σ runoff[e]
;;;     crop-fraction[e]     =  embodied-in-crop[e] / crop-yield
;;;
;;; — conservation made constructive. Change the recipe (more fertiliser, more
;;; runoff) and the crop's composition changes with it: the variable-composition
;;; problem faced at the recipe level, not flattened into one fixed per-type row.
;;;
;;; Quantities are per ~100 kg-carrot batch; the planner scales linearly. They
;;; are chosen so the derived nitrogen fraction (0.040) DIFFERS from the
;;; *contains* fallback (0.026) — the recipe, not the table, speaks.
;;;
;;; Mass-balance (per batch), all in kg of element:
;;;   N: consume soil-n 5.0  →  crop 4.0  +  runoff (20×0.050)=1.0
;;;   P: consume soil-p 1.0  →  crop 0.56 +  runoff (20×0.022)=0.44
;;;   K: consume soil-k 2.0  →  crop 1.40 +  runoff (20×0.030)=0.60
;;;   C: consume co2 44.0 (≈12.0 kg C) → crop 12.0   (runoff carries no carbon)

(define-module (playnet knowledge recipes grow)
  #:use-module ((playnet utils units) #:select (%effort-unit))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet knowledge catalogues substances) #:select (sunlight-for water-for food-macros))
  #:use-module (goblins)
  #:export (*grow-spec-names* *grow-spec-units* seed-grow-specs seed-grow-recipe))

(define *grow-spec-names*
  '(("carrot"      . "Carrot")
    ("crop-runoff" . "Crop Runoff")
    ("soil-n"      . "Soil Nitrogen (plant-available)")
    ("soil-p"      . "Soil Phosphorus (plant-available)")
    ("soil-k"      . "Soil Potassium (plant-available)")
    ("grow-water"  . "Irrigation Water")
    ("grow-labour" . "Grower Hours")))

(define *grow-spec-units*
  '(("carrot" . "kg") ("crop-runoff" . "kg")
    ("soil-n" . "kg") ("soil-p" . "kg") ("soil-k" . "kg")
    ("grow-water" . "liters") ("grow-labour" . "hours")))

(define (seed-grow-specs recipe-store)
  "Register the grow recipe's resource specifications. The substance specs CO₂
   etc. come from knowledge/catalogues/substances.scm's `substance-specs` — seed those too."
  (for-each
   (lambda (pair)
     (let ((id (car pair)) (name (cdr pair)))
       ($ recipe-store 'add-resource-spec
          (make-resource-specification
           #:id id #:name name #:default-unit-of-resource (or (assoc-ref *grow-spec-units* id) "each")))))
   *grow-spec-names*))

(define (seed-grow-recipe recipe-store)
  "Seed the single-step carrot grow recipe: soil-N/P/K + CO₂ + water + labour →
   carrot (primary) + crop-runoff. The crop's nutrient content is derivable from
   these flows; nothing about the carrot's composition is asserted directly."
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-grow" #:name "Crop Cultivation"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-grow" #:name "Grow carrots"
                          #:process-conforms-to "pspec-grow" #:process-classified-as '("tag:cultivation")
                          #:has-duration (make-duration 3 %effort-unit)))

  ;; ── consume: the nutrient draw from soil + air, plus water ────────────────
  (for-each
   (lambda (flow)
     ($ recipe-store 'add-recipe-flow
        (make-recipe-flow #:id (car flow) #:action 'consume #:resource-conforms-to (cadr flow)
                          #:resource-quantity (make-measure (caddr flow) (cadddr flow))
                          #:recipe-input-of "rp-grow")))
   `(("rf-grow-soiln" "soil-n"     5.0  "kg")
     ("rf-grow-soilp" "soil-p"     1.0  "kg")
     ("rf-grow-soilk" "soil-k"     2.0  "kg")
     ("rf-grow-co2"   "co2"       44.0  "kg")
     ;; the water a hundred kilograms of carrot transpire at least (catalogues/substances.scm water-for)
     ("rf-grow-water" "grow-water" ,(water-for "carrot" 100.0) "liters")
     ;; the light a hundred kilograms of carrot store, at the share a crop keeps
     ;; (catalogues/substances.scm sunlight-for): the first law on the energy leaf, stated
     ("rf-grow-sun"   "sunlight"   ,(sunlight-for "carrot" 100.0) "kWh")))

  ;; ── work: grower labour ───────────────────────────────────────────────────
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-grow-work" #:action 'work #:resource-conforms-to "grow-labour"
                       #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-grow"))

  ;; ── produce: the crop (primary) and the runoff that bleeds nutrients out ───
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-grow-carrot" #:action 'produce #:resource-conforms-to "carrot"
                       #:resource-quantity (make-measure 100 "kg") #:recipe-output-of "rp-grow" #:is-primary #t))  ; primary
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-grow-runoff" #:action 'produce #:resource-conforms-to "crop-runoff"
                       #:resource-quantity (make-measure 20 "kg") #:recipe-output-of "rp-grow"))
  ;; the water the crop drew and does not keep leaves as the vapour it transpired
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-grow-vapour" #:action 'produce #:resource-conforms-to "h2o-g"
                       #:resource-quantity (make-measure (- (water-for "carrot" 100.0) (* 100.0 (or (assoc-ref (or (food-macros "carrot") '()) "water") 0.0))) "kg") #:recipe-output-of "rp-grow"))

  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-grow-carrot" #:name "Carrot Cultivation" #:primary-output "carrot"
                  #:recipe-processes (list "rp-grow"))))
