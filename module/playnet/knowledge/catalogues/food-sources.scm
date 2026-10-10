;;; catalogues/food-sources.scm — where each food's composition is READ from.
;;;
;;; A food spec's nutrient composition is not authored here: it is read off
;;; USDA FoodData Central, SR Legacy release (public domain), one row per
;;; food, pinned by the release archive's sha256 and sliced into
;;; knowledge/data/fdc-sr-legacy.scm by tools/fdc-snapshot.scm. What IS
;;; authored here is the binding — which FDC food stands for which spec — and
;;; the map from the catalogue's nutrient ids to FDC's nutrient ids, which is
;;; where a catalogue row that FDC states as several (total n-3 = ALA + EPA +
;;; DHA + DPA) is summed. A spec bound here gets its row by construction; a
;;; spec bound nowhere carries nothing, and the menu guard says so.
;;;
;;; FDC states amounts per 100 g in the catalogue's own units (g, mg, µg,
;;; kcal); the composition table is per UNIT of the spec, and a unit is a
;;; kilogram unless the binding says otherwise — salt is a gram, since a day's
;;; salt is four to six of them and a column measured in kilograms would live
;;; in a band two thousandths wide, below what a solve resolves.
;;;
;;; Two nutrients SR Legacy does not carry for these foods — iodine and biotin
;;; — keep a HAND overlay below, each figure marked, so their floors have
;;; somewhere to stand until a source with rows replaces them.

(define-module (playnet knowledge catalogues food-sources)
  #:use-module (srfi srfi-1)
  #:use-module (playnet knowledge data fdc-sr-legacy)   ; %fdc-slice — the pinned USDA rows this module binds
  #:export (*fdc-composition* *food-sources* *fdc-nutrients* *food-nutrition-hand* fdc-nutrient-ids food-source-id
            food-amounts food-macros *food-macros-hand*))

;; spec id → (fdc-id why [grams-per-unit]) — the unit is a kilogram unless stated
(define *food-sources*
  '(("grain"        . (168890 . "Wheat, hard red winter — the grain as harvested"))
    ("spec-wheat"   . (168890 . "the same wheat, under the federation seed's spec id"))
    ("flour"        . (168893 . "Wheat flour, whole-grain — the mill's output"))
    ("bread"        . (172688 . "Bread, whole-wheat, commercially prepared — the bake's output"))
    ("beans"        . (175193 . "Beans, kidney, all types, mature seeds, raw — a dry pulse"))
    ("greens"       . (168421 . "Kale, raw — a leafy green"))
    ("carrot"       . (170393 . "Carrots, raw"))
    ("dairy"        . (171265 . "Milk, whole, 3.25% milkfat, with added vitamin D"))
    ("spec-milk"    . (171265 . "the same milk, under the federation seed's spec id"))
    ("eggs"         . (171287 . "Egg, whole, raw, fresh"))
    ("fish"         . (175119 . "Fish, mackerel, Atlantic, raw — a fatty sea fish; the release states vitamin D for it, and none for wild salmon"))
    ("fish-stock"   . (175119 . "the same mackerel, in the sea: a harvest moves it and makes nothing"))
    ("flax"         . (169414 . "Seeds, flaxseed"))
    ("walnuts"      . (170187 . "Nuts, walnuts, english"))
    ("rapeseed-oil" . (172336 . "Oil, canola — rapeseed oil"))
    ("soy"          . (174270 . "Soybeans, mature seeds, raw"))
    ("salt"         . (173468 . "Salt, table — sodium has a floor, and a table without salt makes bread the salt shaker; the bread town counts it by the GRAM, its spec's unit, and reads the row at that scale"))))
(define (food-source-id s) (car s))

;; catalogue nutrient id → the FDC nutrient ids summed into it (same unit)
(define *fdc-nutrients*
  '(("energy"    1008) ("protein" 1003) ("fibre" 1079)
    ("omega-3"   1404 1278 1272 1280)          ; ALA + EPA + DHA + DPA, g
    ("lysine"    1214)
    ("iron"      1089) ("calcium" 1087) ("zinc" 1095) ("iodine" 1100)
    ("sodium"    1093) ("potassium" 1092) ("magnesium" 1090) ("selenium" 1103)
    ("choline"   1180) ("folate" 1177) ("vit A" 1106)
    ("vit B1"    1165) ("vit B2" 1166) ("vit B3" 1167) ("vit B5" 1170)
    ("vit B6"    1175) ("vit B7" 1176) ("vit B12" 1178)
    ("vit C"     1162) ("vit D" 1114) ("vit E" 1109) ("vit K" 1185)))
;; the COMPOSITION a food is made of, per 100 g in the release: what the chemistry
;; layer derives a food's elements and its formation enthalpy from (catalogues/substances.scm
;; food-macros): water, the three macronutrients, ash, and phosphorus. Sliced
;; beside the catalogue's nutrients; none is a floor.
(define *fdc-composition*
  '(("water" 1051) ("protein" 1003) ("fat" 1004) ("carbohydrate" 1005) ("ash" 1007) ("phosphorus" 1091)))
(define (fdc-nutrient-ids)
  (delete-duplicates (apply append (map cdr (append *fdc-nutrients* *fdc-composition*)))))

;; macronutrients per kilogram STATED by hand for a form the release does not carry,
;; so its formation and entropy derive the same way: [DRAFT] fodder, good hay
;; (NRC 2001 order of magnitude: 8 % protein, 2 % fat, the rest fibre and starch,
;; 5 % ash, 15 % moisture), the herd's feed and no person's food
(define *food-macros-hand*
  '(("fodder" . (("water" . 0.15) ("protein" . 0.08) ("fat" . 0.02) ("carbohydrate" . 0.70)
                 ("ash" . 0.05) ("phosphorus" . 0.002) ("potassium" . 0.017) ("kcal" . 2000.0)))
    ;; the oilseed, two fifths oil, a fifth protein: what a press draws its oil's carbon from
    ("rapeseed" . (("water" . 0.07) ("protein" . 0.21) ("fat" . 0.42) ("carbohydrate" . 0.25)
                   ("ash" . 0.045) ("phosphorus" . 0.007) ("potassium" . 0.008) ("kcal" . 5620.0)))
    ;; the cake the press leaves, five eighths of the seed: its protein and starch, a little oil
    ("rapeseed-meal" . (("water" . 0.11) ("protein" . 0.34) ("fat" . 0.03) ("carbohydrate" . 0.41)
                        ("ash" . 0.07) ("phosphorus" . 0.011) ("potassium" . 0.013) ("kcal" . 3270.0)))))
;; the HAND overlay: per kg, only for what the source does not carry.
;; [DRAFT] iodine — SR Legacy states none: sea fish at the low end of FAO/WHO's
;; 300–3000 µg/kg; milk and eggs from the NIH ODS fact sheet (~85 µg a cup,
;; ~26 µg an egg), the two foods most diets actually take it from;
;; [DRAFT] biotin, USDA-order figures carried over from the earlier hand table.
;; drinking water is no hand row: every water form (catalogues/substances.scm `water-form?`)
;; carries its litre per kilogram, derived from its molecule row.
(define *food-nutrition-hand*
  '(("fish"    . (("iodine" . 350) ("vit B7" . 50))) ("dairy" . (("iodine" . 350) ("vit B7" . 30))) ("eggs" . (("iodine" . 500) ("vit B7" . 200)))
    ("grain"   . (("vit B7" . 60)))  ("flour" . (("vit B7" . 60)))  ("bread" . (("vit B7" . 60)))
    ("beans"   . (("vit B7" . 100))) ("greens" . (("vit B7" . 5)))
    ("flax"    . (("vit B7" . 60)))  ("walnuts" . (("vit B7" . 20))) ("soy" . (("vit B7" . 300)))))

;; ── reading the release ──────────────────────────────────────────────────────
(define (food-amounts food)
  "The release's rows for FOOD, ((fdc-nutrient-id . amount-per-100g) …), or '()
   where the release carries none."
  (let ((src (assoc-ref *food-sources* food)))
    (or (and src (and=> (assv (food-source-id src) (assq-ref %fdc-slice 'foods)) caddr)) '())))
(define (food-macros food)
  "FOOD's composition per KILOGRAM off the release, kilograms of each of water,
   protein, fat, carbohydrate, ash, phosphorus and potassium, and its kilocalories;
   #f for a food the release does not carry. Per kilogram like every table, whatever
   unit a scope counts the food in (salt's gram): the scope reads it at its own
   scale (catalogues/substances.scm `unit-scale`). The ids are *fdc-composition*'s and the
   catalogue's, named once."
  (let ((amounts (food-amounts food)))
    (define hand (assoc-ref *food-macros-hand* food))
    (define (per-kg name scale)              ; per 100 g → per kg, in kilograms (SCALE 1e-3 for g, 1e-6 for mg)
      (* (apply + (map (lambda (id) (or (assv-ref amounts id) 0)) (or (assoc-ref *fdc-composition* name) (assoc-ref *fdc-nutrients* name) '())))
         10.0 scale))
    (or hand
        (and (pair? amounts)
         `(("water" . ,(per-kg "water" 1e-3)) ("protein" . ,(per-kg "protein" 1e-3))
           ("fat" . ,(per-kg "fat" 1e-3)) ("carbohydrate" . ,(per-kg "carbohydrate" 1e-3))
           ("ash" . ,(per-kg "ash" 1e-3)) ("phosphorus" . ,(per-kg "phosphorus" 1e-6))
           ("potassium" . ,(per-kg "potassium" 1e-6)) ("kcal" . ,(per-kg "energy" 1.0)))))))
