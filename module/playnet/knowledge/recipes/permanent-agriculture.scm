;;; permanent-agriculture.scm — the closed nutrient loop, as measured in the field.
;;;
;;; Source: F. H. King, *Farmers of Forty Centuries; or, Permanent Agriculture in
;;; China, Korea and Japan* (1911), public domain, in the permaculture corpus
;;; (docs/corpus/permaculture/, `corpus fetch && corpus build`). Line citations
;;; below are `L####` against texts/king-farmers-of-forty-centuries/text.md and
;;; are stable — the converted text is written once and never re-flowed.
;;; The bring-over reading is docs/planning/food/permaculture-bring-over.md.
;;;
;;; WHY THIS BOOK. navdanya-farm.scm carries a soil-fertility regenerating stock
;;; whose per-crop draw coefficients are, by its own admission, "honest
;;; placeholders in the right ranks and magnitudes". King is where the measured
;;; ones come from: a soil chemist walked Meiji-era Japan, Korea and China and
;;; wrote down what was applied per acre, what was removed per acre, and by whom.
;;; That is precisely the nutrient half of the per-crop production function that
;;; docs/planning/food/agroecology-bring-over.md marked EXTERNAL.
;;;
;;; WHAT IS PROVED HERE. King's claim (L4592-L4600) is that these farmers return
;;; to the soil each year at least as much N, P and K as the crop removes — the
;;; metabolic rift held closed for forty centuries. `king-nutrient-balance`
;;; computes that ledger from his own tables, per acre per year:
;;;
;;;               N       P       K
;;;   applied   149.5    44.2   100.6
;;;   removed   171.6    24.7   104.3
;;;   balance   -22.1    19.5    -3.7
;;;
;;; Phosphorus comes back in clear surplus. Potassium lands within 3.5%, inside
;;; the precision of figures King calls "only approximations" (L4487) — and the
;;; straw, ash and canal-mud returns he describes elsewhere are potassium-bearing
;;; and absent from this four-line prescription. Nitrogen carries the one real
;;; deficit, 22 lb per acre per year, and King names the missing term in the same
;;; chapter: his totals exclude nitrogen taken "directly from the atmosphere
;;; through their long, extensive and persistent cultivation of soy beans and
;;; other legumes" (L4497-L4502). So the gap is not a hole in the accounting; it
;;; is a measurement, by subtraction, of what the legume contributes. The legume
;;; in the rotation is not a nicety — it is what balances the books.
;;;
;;; Units are King's own — pounds and acres — because converting his figures
;;; would add error to primary data for no gain. The planner reads unit strings
;;; without interpreting them.
;;;
;;; Loaded after planner.scm. Provides
;;;   *king-npk-removal*        — lb N/P/K per 1000 lb dry crop substance
;;;   *king-npk-per-acre-crop*  — lb N/P/K removed per acre at a stated yield
;;;   *king-nara-prescription*  — the Nara Experiment Station fertilisation table
;;;   *king-compost-house*      — a dimensioned compost works
;;;   (king-nutrient-balance …) — applied vs removed, per acre per year
;;;   (permanent-agriculture-records …) → (values resources procs flows)

;; ── Nutrient removal per 1000 lb of DRY crop substance (grain + straw) ───────
;; King L4570-L4584, computed by him from Hopkins, *Soil Fertility and Permanent
;; Agriculture*, p.154, assuming 11% water in matured grain and 15% in straw.
;; This is a PRODUCTION-FUNCTION coefficient: it says what a unit of yield costs
;; the soil, which is the term a plan needs in order to know whether a cropping
;; pattern mines its own ground.
;;
;; Read the legumes against the cereals. Soy beans remove 30.8 lb N per 1000 lb
;; where rice removes 9.9 — and yet a legume rotation RESTORES nitrogen, because
;; most of what it removes it first fixed from the air. Removal is not the same
;; measurement as depletion; the fixation term below is the difference.
(define-module (playnet knowledge recipes permanent-agriculture)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet knowledge dsl shorthand) #:select (rp in out wrk in/u out/u wrk/u))
  #:use-module (playnet vf schemas)
  #:export (*king-npk-removal* *king-npk-per-acre-crop* *king-nara-prescription*
            *king-nara-annual-applied* *king-nara-annual-material*
            *king-japan-mean-applied* *king-compost-house* *king-rotation*
            king-crop-removal king-nutrient-balance permanent-agriculture-records))

(define *king-npk-removal*                  ; crop . (N P K), lb per 1000 lb dry substance
  '(("wheat"     13.873  2.312   8.382)
    ("oats"      13.666  2.254   9.580)
    ("corn"      13.719  2.149   6.676)
    ("soy-beans" 30.807  4.070  14.147)
    ("cow-peas"  25.490  2.745  19.216)
    ("clover"    23.529  2.941  17.647)
    ("alfalfa"   29.411  2.647  14.118)
    ("beets"     19.213  3.462  30.192)
    ("potatoes"  15.556  3.210  22.222)
    ("timothy"   14.117  1.765  13.922)
    ("rice"       9.949  1.129   6.089)))

;; Removal per ACRE at a stated yield — King L4545-L4560, from the same Hopkins
;; table. Kept alongside the per-1000-lb figures because these are what the
;; balance is actually struck in, and deriving one from the other needs a
;; grain:straw ratio the book does not state.
(define *king-npk-per-acre-crop*            ; (crop yield unit) . (N P K), lb per acre
  '((("corn"      100 "bushels") 148   23    71)
    (("oats"      100 "bushels")  97   16    68)
    (("wheat"      50 "bushels")  96   16    58)
    (("soy-beans"  25 "bushels") 159   21    73)
    (("rice"      100 "bushels") 155   18    95)
    (("timothy"     3 "tons")     72    9    71)
    (("clover"      4 "tons")    160   20   120)
    (("cow-peas"    3 "tons")    130   14    98)
    (("alfalfa"     8 "tons")    400   36   192)
    (("cotton"   7000 "lb")      168   29.4  82)
    (("potatoes"  400 "bushels")  84   17.3 120)
    (("sugar-beets" 20 "tons")   100   18   157)))

;; ── The Nara Experiment Station prescription ────────────────────────────────
;; King L8206-L8240. A prefecture's official recommendation for the barley/rice
;; double crop, with the material weight and its N, P, K content, per acre.
;; These are RECIPES in the strict sense the planner means: named inputs, stated
;; quantities, a named output, and (below) an observed yield.
;;
;; Note what the fertiliser list is made of. Compost, night soil, green manure
;; and pressed-seed cake are all RETURNS — residues, human excreta, and a crop
;; grown to be turned under. Superphosphate is the single purchased input, and
;; it carries no nitrogen at all. The loop is closed by design, not by scarcity.
(define *king-nara-prescription*
  '(("naked-barley"
     (("manure-compost"  6613  33.0  7.4  33.8)
      ("rape-seed-cake"   330  16.7  2.8   3.5)
      ("night-soil"      4630  26.4  2.6  10.2)
      ("superphosphate"   132   0.0  9.9   0.0))
     (yield 49 "bushels"))
    ("paddy-rice"
     (("manure-compost"  5291  26.4  5.9  27.1)
      ("green-manure-soy" 3306 19.2  1.1  19.6)
      ("soy-bean-cake"    397  27.8  1.7   6.4)
      ("superphosphate"   198   0.0 12.8   0.0))
     (yield 50 "bushels"))))

;; King's own totals for the year, L8236-L8246: ~10 tons of material per acre
;; carrying 149.5 lb N, 44.2 lb P, 100.6 lb K, for 49 bushels of barley and 50
;; of rice. Held here as stated rather than recomputed, so a drift between the
;; sum and the source is visible instead of silently absorbed.
(define *king-nara-annual-applied* '(149.5 44.2 100.6))   ; lb per acre: N P K
(define *king-nara-annual-material* 20897)                ; lb per acre of material

;; The national mean, L4520-L4525: across Japan's 21,321 square miles of
;; cultivated land, not less than 56 lb N, 13 lb P, 37 lb K per acre per year;
;; excluding the newly-farmed Hokkaido, 60, 14 and 40. The Nara prescription is
;; therefore roughly 2.5× the national average — an experiment-station optimum,
;; not typical practice. Treat it as an upper anchor.
(define *king-japan-mean-applied* '(60.0 14.0 40.0))      ; lb per acre: N P K

;; ── The compost works, dimensioned ──────────────────────────────────────────
;; King L4479-L4494, from a Nara Experiment Station circular. A building sized
;; to a landholding: it is infrastructure with a service area, which makes it a
;; capacity-capped durable rather than a consumable.
(define *king-compost-house*
  '((serves-acres    . 2.5)
    (floor-ft        . (12 . 18))
    (wall-thickness-ft . 1.0)
    (floor-material  . "clay, lime and sand, rendered watertight")
    (roof            . "thatched with straw")
    (capacity-tons   . (16 . 20))
    (value-yen       . 60)
    (stack-height-ft . 5.0)
    (layer-ft        . 1.0)          ; material laid and firmed one foot at a time
    (soil-cap-inches . 1.2)          ; then 1.2 in of soil or mud over the surface
    (cure-weeks-summer . 5)
    (cure-weeks-winter . 7)
    (turning         . "forked over and transferred to the opposite side")))

;; ── The five-year rotation ──────────────────────────────────────────────────
;; King L8248-L8258. Winter crop first, rice every summer. Years three and five
;; put a legume in the winter slot; year four returns rape ash. Nitrogen enters
;; this sequence twice from the air, which is what the balance below turns on.
(define *king-rotation*
  '((1 winter "naked-barley"      summer "paddy-rice")
    (2 winter "naked-barley"      summer "paddy-rice")
    (3 winter "green-manure-soy"  summer "paddy-rice")   ; genge / Astragalus sinicus
    (4 winter "rape"              summer "paddy-rice")   ; seed saved, stem ash returned
    (5 winter "windsor-bean"      summer "paddy-rice")))

;; ── The ledger ──────────────────────────────────────────────────────────────
;; What the Nara double crop removes per acre per year, against what it applies.
;; Barley is scored against King's wheat row (his table has no barley, and the
;; two are close enough that he treats naked barley as a wheat analogue);
;; rice is scored directly. Yields are the Station's own observed figures.
(define (king-crop-removal crop yield-bushels)
  "Lb of N, P, K removed per acre by YIELD-BUSHELS of CROP, scaled from King's
per-acre table (L4545-L4560) at the yield that table is stated for."
  ;; One path, not two: the tabulated row is scaled linearly to the yield asked
  ;; for, and a yield that happens to match the table scales by 1. Removal is
  ;; proportional to what leaves the field, which is why the scaling is honest
  ;; over the range King's own yields span.
  (and=> (find (lambda (e) (equal? (caar e) crop)) *king-npk-per-acre-crop*)
         (lambda (row)
           (let ((factor (/ (exact->inexact yield-bushels) (cadr (car row)))))
             (map (lambda (v) (* v factor)) (cdr row))))))

(define (king-nutrient-balance)
  "The Nara prescription's annual ledger, per acre: applied vs removed by the
barley/rice double crop. Returns an alist. Phosphorus closes in surplus and
potassium within 3.5%; nitrogen runs a 22 lb deficit, which is the biological
fixation King's totals exclude (L4497-L4502) — the legume, doing the arithmetic."
  (let* ((barley (king-crop-removal "wheat" 49))          ; naked barley ≈ wheat
         (rice   (king-crop-removal "rice" 50))
         (removed (map + barley rice))
         (applied *king-nara-annual-applied*)
         (gap (map - applied removed)))
    (list (cons 'applied applied)
          (cons 'removed removed)
          (cons 'balance gap)                              ; positive = returned in surplus
          (cons 'nitrogen-from-fixation (max 0.0 (- (car removed) (car applied)))))))

;; ── The same thing as ValueFlows records ────────────────────────────────────
;; One acre under the Nara double crop, with the nutrient loop made explicit:
;; cropping DRAWS the soil's N stock, and compost, night soil and green manure
;; RETURN it. This is navdanya-farm.scm's soil-fertility stock pattern with
;; King's measured coefficients in place of placeholders, and with the returning
;; flows named as processes a plan can actually choose to run or skip.
(define* (permanent-agriculture-records #:key (acres 1.0) (place "nara-farm"))
  (let* ((resources
          (list (make-economic-resource #:id "land" #:conforms-to "land" #:classified-as '()
                  #:accounting-quantity (make-measure acres "acre") #:onhand-quantity (make-measure acres "acre")
                  #:current-location place)
                ;; Soil nitrogen as a carried level, in King's units. The farm
                ;; can mine this or tend it; which one it does is the plan.
                (make-economic-resource #:id "soil-n" #:conforms-to "nutrient" #:classified-as '()
                  #:accounting-quantity (make-measure (* acres 60.0) "lb") #:onhand-quantity (make-measure (* acres 60.0) "lb")
                  #:current-location place)))

         (procs
          (list (rp "compost" "Prepare compost stack")
                (rp "collect-night-soil" "Collect and return night soil")
                (rp "green-manure" "Grow and turn under a legume green manure")
                (rp "grow-barley" "Winter crop: naked barley")
                (rp "grow-rice" "Summer crop: paddy rice")))

         (flows
          (list
           ;; Compost: organic matter plus the soil or mud capping each layer,
           ;; five weeks in summer. Labour is King's "so large an amount"
           ;; (L5300) rendered as an estimate — see the bring-over doc, ANCHOR.
           (in/u "c-om"   "organic-matter" 5000.0 "lb" "compost")
           (in/u "c-mud"  "soil-or-mud"    1600.0 "lb" "compost")
           (wrk "c-work" 40.0 "compost")
           (out/u "c-out"  "manure-compost" 6613.0 "lb" "compost")

           ;; Night soil: the return flow that closes the human end of the loop.
           (in/u "ns-raw"  "night-soil-raw" 4630.0 "lb" "collect-night-soil")
           (wrk "ns-work" 12.0 "collect-night-soil")
           (out/u "ns-out"  "night-soil"     4630.0 "lb" "collect-night-soil")

           ;; Green manure: the one process that produces nitrogen without
           ;; consuming any. It is where the ledger's shortfall is made up.
           (in/u "gm-land" "land" 1.0 "acre" "green-manure")
           (wrk "gm-work" 15.0 "green-manure")
           (out/u "gm-out"  "green-manure-soy" 3306.0 "lb" "green-manure")
           (out/u "gm-n"    "soil-n" 19.2 "lb" "green-manure")

           ;; Winter barley, fertilised to the Station prescription.
           (in/u "b-land"    "land"            1.0 "acre" "grow-barley")
           (in/u "b-compost" "manure-compost"  6613.0 "lb" "grow-barley")
           (in/u "b-cake"    "rape-seed-cake"   330.0 "lb" "grow-barley")
           (in/u "b-ns"      "night-soil"      4630.0 "lb" "grow-barley")
           (in/u "b-sp"      "superphosphate"   132.0 "lb" "grow-barley")
           (in/u "b-n"       "soil-n"            96.0 "lb" "grow-barley")
           (wrk "b-work"    120.0 "grow-barley")
           (out/u "b-out"     "barley" 49.0 "bushels" "grow-barley")

           ;; Summer rice, likewise.
           (in/u "r-land"    "land"            1.0 "acre" "grow-rice")
           (in/u "r-compost" "manure-compost"  5291.0 "lb" "grow-rice")
           (in/u "r-gm"      "green-manure-soy" 3306.0 "lb" "grow-rice")
           (in/u "r-cake"    "soy-bean-cake"    397.0 "lb" "grow-rice")
           (in/u "r-sp"      "superphosphate"   198.0 "lb" "grow-rice")
           (in/u "r-n"       "soil-n"            77.5 "lb" "grow-rice")
           (wrk "r-work"    160.0 "grow-rice")
           (out/u "r-out"     "rice" 50.0 "bushels" "grow-rice"))))
    (values resources procs flows)))
