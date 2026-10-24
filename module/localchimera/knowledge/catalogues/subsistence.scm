;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; catalogues/subsistence.scm — the reproduction of labour-power, made executable.
;;;
;;; The CONSUMPTION side of the reproduction of labour-power (localchimera.typ §The
;;; categories of social reproduction · "Means of consumption"): a person's
;;; nutritional means of subsistence is a stack of two-sided fragility bands — a
;;; deficiency floor (EAR/RDA) and a toxicity ceiling (UL), weight w — and each of
;;; the determinants of the value of labour-power is a LAYER folded over a
;;; species base, ordered essential→contingent. "The value of labour-power is
;;; determined by the labour-time necessary for its reproduction" — so the day's
;;; committed labour RAISES the floor (L3). "The number and extent of [the worker's]
;;; so-called necessary wants … depend … on the habits and degree of comfort … the
;;; historical and moral element" — L4, governance-set, may only raise.
;;;
;;; This is the ONE canonical model: ui/app/nutrition-catalogue.ts is generated
;;; from its tables (tools/emit/nutrition-emit.scm), and it is read by BOTH the live solve (scope-consumption → plan-scope #:bands, each
;;; nutrient's two walls as one row) and the fragility wire, so the dial and the
;;; plan agree. Plain defines (include-able,
;;; like the other knowledge files; also primitive-load-able for tests).

;; a nutrient band: (spec group unit rda ul w).  ul = #f ⇒ ceiling-free (a floor
;; only — "more is fine"). rda = the adequate deficiency floor.
(define-module (localchimera knowledge catalogues subsistence)
  #:use-module ((localchimera vf facts agent-tags) #:select (tag-values))
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf schemas)
  #:export (sub-nut sub-spec sub-group sub-unit sub-rda sub-ul sub-w subsistence-clamped
            ratified-standard sub-lift sub-floor-under-ceiling
            subsistence-species-base sub-shift sub-set sub-set* sub-add ctx-ref *follows* sub-follow
            sub-shift* *geo-shifts* subsistence-L1-geography *sex-shifts*
            *band-max-age* *band-rda* *band-ul* band-index band-cell life-stage-band
            subsistence-L2-lifestage subsistence-L2-diet *diet-shifts* diet-floor-shifts
            subsistence-L2c-body *reference-body* *eer-rows* reference-body eer energy-ceiling-ratio sub-energy-ceiling
            *altitude-shifts* altitude-shift-rows *winter-sun-lat* *winter-sun-shift* winter-sun?
            *work-intensity* work-intensity-weight work-intensity-of-tags effective-labour-hours
            *self-conditions* self-condition-rows subsistence-L5-self
            *elder-age* *adult-shifts* adult-shift-rows adult-lifestage-shifts activity-factor
            %sweat-na-mmol/l %sweat-acclim-mmol/l %na-mg-per-mmol %sweat-l/h-per-degc
            %sweat-anchor-degc %sweat-anchor-l/h sweat-na-mmol/l %catalogue-module
            shed-derived-degc shed-derived-figure shed-rain-mm-day *region-working-degc* working-degc sweat-l/h
            %hot-latitude %cold-latitude %high-latitude region-for-lat
            sweat-sodium-mg subsistence-L3-activity subsistence-L4-cultural
            subsistence-profile subsistence-bands subsistence-floors subsistence-caps
            sub-reserve reserve-nutrients
            subsistence-catalogue-tables))

(define* (sub-nut spec group unit rda ul w #:optional (reserve #f)) (list spec group unit rda ul w reserve))
(define (sub-spec n)  (list-ref n 0))
(define (sub-group n) (list-ref n 1))
(define (sub-unit n)  (list-ref n 2))
(define (sub-rda n)   (list-ref n 3))
(define (sub-ul n)    (list-ref n 4))
(define (sub-w n)     (list-ref n 5))
;; the body's STORE of the nutrient, in days of intake: how long a surplus eaten today
;; feeds the floor tomorrow. #f: a turnover of hours to days, so every period eats its
;; own. A stated reserve lets the plan feed a person through a lean stretch from a
;; fat one — reproduction as conservation, the body an enclosure that leaks — and
;; the carry is honest while the horizon is shorter than the store (`reserve-nutrients`).
(define (sub-reserve n) (and (> (length n) 6) (list-ref n 6)))
(define (reserve-nutrients)
  "((nutrient . days) …): every nutrient the body stores, with its store's time
   constant in days. A person's good of it carries from period to period through a
   store-shaped recipe that leaks 1 − e^(−p/τ) per period (catalogues/thermal.scm
   relaxation-records, live.scm scope-reserves): the body an enclosure that leaks."
  (filter-map (lambda (n) (and (sub-reserve n) (cons (sub-spec n) (sub-reserve n))))
              (subsistence-species-base)))

;; ── L0 · SPECIES FLOOR — the physically-indispensable (the "minimum limit").
;; DRI-style (US IOM), sex-neutral adult base; life-stage brackets it. The floor the
;; whole stack rests on; the browser's copy is generated from it.
(define (subsistence-species-base)
  (sub-follow (list (sub-nut "drinking-water" "macronutrients" "L" 3.2 #f 8)  ; total water adequate intake, F 2.7 / M 3.7 (IOM 2005, NBK56068 t4); the id keeps clear of the ecological "water" stock — this is the litres a body drinks
        (sub-nut "energy"  "macronutrients" "kcal" 2200 #f   9 45)   ; adipose: a 70 kg adult holds ~100 000 kcal of fat, six weeks of intake (Cahill 1970, NEJM 282:668)
        (sub-nut "protein" "macronutrients" "g"    50   #f   9)
        (sub-nut "fibre"   "macronutrients" "g"    28   #f   4)
        (sub-nut "omega-3" "macronutrients" "g"    1.35 #f   5)   ; total n-3 (ALA + EPA + DHA) against the ALA adequate intake — no ceiling set (IOM 2005, NBK56068 t4)
        (sub-nut "lysine"  "macronutrients" "g"    0    #f   7)   ; FOLLOWS protein (*follows*): the scoring pattern's 51 mg per g protein (IOM 2005) — the rda here is written by the rule, never by hand
        (sub-nut "iron"    "minerals" "mg" 8    45   8 120)   ; ferritin and haemosiderin: months of stores
        (sub-nut "calcium" "minerals" "mg" 1000 2500 6 365)   ; bone: the year-scale store
        (sub-nut "zinc"    "minerals" "mg" 9    40   6)
        (sub-nut "iodine"  "minerals" "ug" 150  1100 6 60)    ; the thyroid holds some months' worth
        (sub-nut "sodium"  "minerals" "mg" 1500 2300 5)   ; two-sided EXCESS example
        (sub-nut "potassium" "minerals" "mg" 3000 #f  6)  ; adequate intake, F 2600 / M 3400 (NASEM 2019); no UL — no toxicological indicator for food potassium
        (sub-nut "magnesium" "minerals" "mg" 370  #f  6)  ; F 320 / M 420; the DRI UL (350 mg) covers a PHARMACOLOGICAL agent only, never food and water — so, like folate, none here
        (sub-nut "selenium"  "minerals" "ug" 55   400 5)
        (sub-nut "choline" "vitamins" "mg" 490  3500 6)   ; adequate intake, F 425 / M 550; conditionally essential — the body makes some, never enough
        (sub-nut "folate"  "vitamins" "ug" 400  #f   7 90)    ; hepatic folate, three to four months (Herbert 1962)   ; the DRI folate UL (1000 ug) is for SYNTHETIC folic acid from supplements/fortification only — food folate carries no UL (IOM 1998), and this table meets FOOD
        (sub-nut "vit A"   "vitamins" "ug" 800  3000 6 90)    ; hepatic retinyl esters, months
        (sub-nut "vit B1"  "vitamins" "mg" 1.15 #f   5)   ; thiamin, F 1.1 / M 1.2
        (sub-nut "vit B2"  "vitamins" "mg" 1.2  #f   5)   ; riboflavin, F 1.1 / M 1.3
        (sub-nut "vit B3"  "vitamins" "mg" 15   #f   5)   ; niacin equivalents, F 14 / M 16; the UL (35 mg) is for SYNTHETIC niacin from supplements and fortificants only — food niacin carries none (IOM 1998)
        (sub-nut "vit B5"  "vitamins" "mg" 5    #f   4)   ; pantothenic acid, adequate intake
        (sub-nut "vit B6"  "vitamins" "mg" 1.3  100  6)
        (sub-nut "vit B7"  "vitamins" "ug" 30   #f   4)   ; biotin, adequate intake
        (sub-nut "vit B12" "vitamins" "ug" 2.4  #f   7 1000)  ; the liver's 2–5 mg last years
        (sub-nut "vit C"   "vitamins" "mg" 85   2000 5 30)    ; a 1.5 g body pool; scurvy after one to three months without (Hodges 1971)
        (sub-nut "vit D"   "vitamins" "ug" 15   100  6 60)    ; adipose 25(OH)D, weeks to months
        (sub-nut "vit E"   "vitamins" "mg" 15   1000 5)   ; α-tocopherol; the UL is for any form of supplemental α-tocopherol — kept, since a plan reading an oil-heavy menu should see the wall
        (sub-nut "vit K"   "vitamins" "ug" 105  #f   5))))   ; adequate intake, F 90 / M 120; no UL

;; ── a nutrient that FOLLOWS another. Lysine is the limiting amino acid of every
;; cereal, and the DRI states it as a PATTERN, not a table: 51 mg of lysine per
;; gram of protein required (the protein-quality scoring pattern, IOM 2005, for
;; ages 1 and up). So its floor is a ratio on the protein floor wherever that
;; floor stands — after the sex split, the band, the diet, the day's labour, the
;; ratified standard — and the rule runs LAST, once, in both stacks. Stating a
;; lysine table beside the protein table would be the same numbers twice; a
;; ratio that drifted from the pattern would be a bug this shape cannot have.
;; What the rule buys: a grain-only menu meets its protein floor with lysine
;; short (whole wheat carries ~4.6 % lysine in its protein, the pattern asks
;; 5.1 %), and the plan sees it because the food table carries lysine per kg.
;; (spec source ratio) — the followed nutrient's rda × ratio becomes the spec's.
(define *follows* '(("lysine" "protein" 0.051)))
(define (sub-follow prof)
  (fold (lambda (r p)
          (let ((src (find (lambda (n) (equal? (sub-spec n) (cadr r))) p)))
            (if src (sub-set p (car r) #:rda (* (caddr r) (sub-rda src))) p)))
        prof *follows*))

;; scale a nutrient's rda / ul / w by multipliers (default 1) — never touches an
;; absent (#f) ceiling.
(define* (sub-shift prof spec #:key (rda 1) (ul 1) (w 1))
  (map (lambda (n)
         (if (equal? (sub-spec n) spec)
             (sub-nut spec (sub-group n) (sub-unit n)
                      (* (sub-rda n) rda)
                      (and (sub-ul n) (* (sub-ul n) ul))
                      (* (sub-w n) w)
                      (sub-reserve n))
             n))
       prof))

;; SET a nutrient's rda / ul outright. The shifts above are ratios against the
;; adult base, which is the right shape for a climate or an activity nudge; a
;; life-stage bracket is not a nudge but a DIFFERENT TABLE — the DRI publishes
;; absolute values per age band, and stating them as ratios would obscure both the
;; number and its source. #f leaves a field alone; an absent ceiling stays absent.
(define* (sub-set prof spec #:key (rda #f) (ul #f) (w #f))
  (map (lambda (n)
         (if (equal? (sub-spec n) spec)
             (sub-nut spec (sub-group n) (sub-unit n)
                      (or rda (sub-rda n))
                      (if ul ul (sub-ul n))
                      (or w (sub-w n))
                      (sub-reserve n))
             n))
       prof))
(define (sub-set* prof rows) (fold (lambda (r p) (apply sub-set p r)) prof rows))

;; ADD an absolute amount to a nutrient's floor, and to its ceiling with it.
;; A sweat loss is a QUANTITY THE BODY LOST, not a ratio of what it needed — and
;; the ceiling has to travel with the floor, because a chronic-disease-risk limit
;; derived for a sedentary population is not a limit for someone who has just
;; sweated six grams out. Raising the floor through a fixed ceiling would leave an
;; empty band and an unsatisfiable plan.
(define (sub-add prof spec amount)
  (map (lambda (n)
         (if (equal? (sub-spec n) spec)
             (sub-nut spec (sub-group n) (sub-unit n)
                      (+ (sub-rda n) amount)
                      (and (sub-ul n) (+ (sub-ul n) amount))
                      (sub-w n))
             n))
       prof))

(define (ctx-ref ctx k default) (let ((v (assq-ref ctx k))) (if (eq? v #f) default v)))

;; apply a SEQUENCE of shifts, each ("spec" #:rda x #:ul y #:w z) with any subset —
;; so the layers below read as data tables instead of nested sub-shift chains.
(define (sub-shift* prof shifts) (fold (lambda (s p) (apply sub-shift p s)) prof shifts))

;; ── L1 · GEOGRAPHY / CLIMATE — "natural wants vary according to the climatic and
;; other physical conditions." Shifts (never lowers below) the species floor.
;;
;; ── WHAT THE LITERATURE ACTUALLY SAYS (searched 2026-08-08) ──────────────
;; Unlike L0 and L2, this layer has NO DRI-equivalent authority behind it, and it
;; is worth being exact about that rather than letting the numbers look sourced.
;;
;; ENERGY IN THE COLD. FAO/WHO/UNU (Human Energy Requirements, 2004) measures BMR
;;   under thermoneutral conditions and publishes NO climate adjustment at all —
;;   so there is no consensus multiplier to cite. The quantitative literature is
;;   the IOM's "Nutritional Needs in Cold and High-Altitude Environments" (1996),
;;   and its finding is not the one the naive reading expects: the increase is
;;   dominated by CLOTHING (heavy arctic clothing raises the energy cost of
;;   movement by 10–16 %, from friction between layers and restricted movement)
;;   and by terrain (snow, loads), NOT by metabolic thermoregulation. Field
;;   figures are 45–62 kcal/kg/d for troops at −18 °F to −25 °F.
;;   So `("energy" #:rda 1.12)` sits in the right band — but for the clothing-and-
;;   terrain reason, not the "burning fuel to stay warm" one, and it describes
;;   people WORKING outdoors, not people living in a cold city.
;;
;; SODIUM IN THE HEAT. Sweat losses over a work shift in heat run 4.8–6 g sodium
;;   (10–15 g salt), higher unacclimatised; acclimation lowers sweat sodium by
;;   ~15–25 mmol/L. Against a 1500 mg/d AI that is a FOURFOLD requirement, not the
;;   ×1.2 below. The ×1.2 is defensible for ambient hot-arid living and badly
;;   understates anyone doing physical work in heat.
;;
;; THE INTERACTION, and why the ×1.2 below stays as it is. Both findings are about
;; climate MEETING ACTIVITY, and raising ×1.2 to ×4 here would over-provision every
;; sedentary person in a hot region to fix a case that is not L1's. The sweat term
;; belongs where the two meet, and it now lives in L3 (`*sweat-sodium-mg/h*`),
;; which reads `region` beside `labour-hours`. So ×1.2 keeps its honest job: the
;; AMBIENT cost of living somewhere hot and dry, at rest.
;;
;; (An earlier draft of this note said the stack could not express the interaction
;; at all. That was wrong: every layer here receives the full ctx, so any layer may
;; read any field, and composition was already multiplicative. Nothing structural
;; was in the way — L3 simply never read `region`.)
;;
;; [DRAFT] every multiplier below. They are ratified governance dials, and unlike
;;   L0/L2 they are not transcriptions of a published table.
(define *geo-shifts*
  '(("cold"    ("energy" #:rda 1.12) ("vit D" #:rda 1.3 #:w 1.2))
    ("hotArid" ("sodium" #:rda 1.2 #:ul 1.15) ("energy" #:rda 1.05))
    ("inland"  ("iodine" #:w 1.4))
    ("highLatitude" ("vit D" #:rda 1.4 #:w 1.3))))

;; ALTITUDE. Above about 2 500 m the thinner air costs energy (the IOM 1996
;; cold-and-altitude report puts basal metabolism 10–30 % up on acute exposure
;; at 4 000 m and above) and the body answers hypoxia by making more red cells,
;; which is iron. The rows are read off the person's elevation — the location
;; fix carries it, nobody is asked — and the highest threshold at or below the
;; elevation wins. [DRAFT] the multipliers, like every L1 figure.
(define *altitude-shifts*
  '((4000 ("energy" #:rda 1.15) ("iron" #:rda 1.3 #:w 1.3))
    (2500 ("energy" #:rda 1.05) ("iron" #:rda 1.15 #:w 1.2))))
(define (altitude-shift-rows m)
  (let ((r (and (number? m) (find (lambda (r) (>= m (car r))) *altitude-shifts*))))
    (if r (cdr r) '())))
;; WINTER SUN. Skin makes no vitamin D when the sun sits low: beyond about 35°
;; of latitude the winter months yield none (Webb, Kline & Holick 1988), so the
;; floor leans on food for a season. The half-year is the dark one for the
;; hemisphere — November to February north, May to August south — read off the
;; latitude and the month, both derived. [DRAFT] the multiplier.
(define *winter-sun-lat* 35)
(define *winter-sun-shift* '(("vit D" #:rda 1.3 #:w 1.2)))
(define (winter-sun? lat month)
  (and (number? lat) (number? month) (>= (abs lat) *winter-sun-lat*)
       (if (>= lat 0) (or (>= month 11) (<= month 2)) (and (>= month 5) (<= month 8)))))
(define (subsistence-L1-geography prof ctx)
  (sub-shift* prof
    (append (or (assoc-ref *geo-shifts* (ctx-ref ctx 'region "temperate")) '())
            (altitude-shift-rows (ctx-ref ctx 'altitude-m #f))
            (if (winter-sun? (ctx-ref ctx 'lat #f) (ctx-ref ctx 'month #f)) *winter-sun-shift* '()))))

;; ── L2 · LIFE-STAGE / GENERATIONAL — age × sex, pregnancy/lactation fold the
;; developing dependent's floor into the reproducer's own.
(define *sex-shifts*
  `(("F" ("iron" #:rda 2.25) ("protein" #:rda 0.92) ("vit C" #:rda 0.88) ("vit A" #:rda 0.875) ("zinc" #:rda 0.89) ("omega-3" #:rda ,(/ 1.1 1.35))
         ("drinking-water" #:rda ,(/ 2.7 3.2)) ("potassium" #:rda ,(/ 2600.0 3000.0)) ("magnesium" #:rda ,(/ 320.0 370.0)) ("vit K" #:rda ,(/ 90.0 105.0))
         ("vit B1" #:rda ,(/ 1.1 1.15)) ("vit B2" #:rda ,(/ 1.1 1.2)) ("vit B3" #:rda ,(/ 14.0 15.0)) ("choline" #:rda ,(/ 425.0 490.0)))
    ("M" ("protein" #:rda 1.12) ("vit C" #:rda 1.06) ("vit A" #:rda 1.125) ("zinc" #:rda 1.22) ("omega-3" #:rda ,(/ 1.6 1.35))
         ("drinking-water" #:rda ,(/ 3.7 3.2)) ("potassium" #:rda ,(/ 3400.0 3000.0)) ("magnesium" #:rda ,(/ 420.0 370.0)) ("vit K" #:rda ,(/ 120.0 105.0))
         ("vit B1" #:rda ,(/ 1.2 1.15)) ("vit B2" #:rda ,(/ 1.3 1.2)) ("vit B3" #:rda ,(/ 16.0 15.0)) ("choline" #:rda ,(/ 550.0 490.0)))))
;; ── CHILDHOOD AND ADOLESCENCE — the brackets the adult base cannot express.
;; A growing body is not a small adult: its calcium and its energy per kilo run
;; HIGHER than an adult's while its protein and iron run lower, and no scaling of
;; one adult number reproduces that shape. So each band is its own DRI table,
;; SET rather than scaled, applied after the sex shift and overwriting it — DRI
;; publishes no sex split below 9, and states both above it.
;;
;; Bands: 0–0.5, 0.5–1, 1–3, 4–8, 9–13, 14–18.
;;
;; INFANCY IS A DIFFERENT REGIME and is marked as one. Almost every infant figure
;; is an ADEQUATE INTAKE, not an RDA — "for healthy breast-fed infants, an AI is
;; the mean intake", i.e. an observation of what nourished infants get, not a
;; requirement derived from need. Only iron and zinc at 7–12 months are RDAs.
;; Fibre has no infant value at all. So a plan provisioning an infant from these
;; numbers is matching a population's observed intake, and the two-sided band
;; around it is much less informative than an adult's. Present so an infant is not
;; silently given a toddler's floor; not to be read as firmly as the rest.
;;
;; ── PROVENANCE, checked 2026-08-08 against the published tables ──────────
;; [DATA · 2026-09-23] the rows for water, potassium, magnesium, selenium,
;;   vitamins E and K, the B group (B1 B2 B3 B5 B6 B7) and choline were read
;;   from Health Canada's mirror of the same NASEM/IOM summary tables (reference
;;   values for vitamins / elements / macronutrients, and their UL tables):
;;     · water AI (L)  0.7/0.8/1.3/1.7/(2.1 F, 2.4 M)/(2.3 F, 3.3 M)/(2.7 F, 3.7 M)
;;     · K AI (mg)     400/860/2000/2300/(2300 F, 2500 M)/(2300 F, 3000 M)/(2600 F, 3400 M)
;;     · Mg rda        30/75/80/130/240/(360 F, 410 M)/(320 F, 420 M); UL pharmacological only
;;     · Se rda        15/20/20/30/40/55/55; UL 45/60/90/150/280/400/400
;;     · E rda (mg)    4/5/6/7/11/15/15; UL —/—/200/300/600/800/1000
;;     · K AI (µg)     2/2.5/30/55/60/75/(90 F, 120 M)
;;     · B1            0.2/0.3/0.5/0.6/0.9/(1.0 F, 1.2 M)/(1.1 F, 1.2 M)
;;     · B2            0.3/0.4/0.5/0.6/0.9/(1.0 F, 1.3 M)/(1.1 F, 1.3 M)
;;     · B3 (NE)       2/4/6/8/12/(14 F, 16 M)/(14 F, 16 M); UL synthetic only
;;     · B5 AI         1.7/1.8/2/3/4/5/5 · B7 AI (µg) 5/6/8/12/20/25/30
;;     · B6            0.1/0.3/0.5/0.6/1.0/(1.2 F, 1.3 M)/1.3, 51+ (1.5 F, 1.7 M); UL —/—/30/40/60/80/100
;;     · choline AI    125/150/200/250/375/(400 F, 550 M)/(425 F, 550 M); UL —/—/1000/1000/2000/3000/3500
;;     · pregnancy: water 3.0, K 2900, Mg 360 (19–50), Se 60, B1 1.4, B2 1.4, B3 18,
;;       B5 6, B6 1.9, choline 450 · lactation: water 3.8, K 2800, Se 70, B1 1.4,
;;       B2 1.6, B3 17, B5 7, B6 2.0, B7 35, choline 550
;;   Lysine has no table of its own: it follows protein (see *follows*).
;; [DATA · VERIFIED] Every rda and every mineral ul below was read back from the
;;   NASEM/IOM DRI summary tables and matches exactly:
;;     · minerals rda  — DRI Tables (NBK545442, App. J): Ca 700/1000/1300/1300,
;;       Fe 7/10/8/(15 F, 11 M), Zn 3/5/8/(9 F, 11 M), I 90/90/120/150
;;     · vitamins rda  — DRI Summary Tables (NBK56068 t2): A 300/400/600/(700 F,
;;       900 M), C 15/25/45/(65 F, 75 M), D 15 throughout, folate 150/200/300/400,
;;       B12 0.9/1.2/1.8/2.4
;;     · protein/fibre — (NBK56068 t4): protein 13/19/34/(46 F, 52 M);
;;       fibre 19/25/(26 F, 31 M)/(26 F, 38 M)
;;     · mineral ul    — (NBK56068 t8): Ca 2500/2500/3000/3000, Fe 40/40/40/45,
;;       Zn 7/12/23/34, I 200/300/600/900
;;   The adult column is unchanged by this file and still reproduces L0×sex exactly.
;;     · vitamin ul   — (NBK56068 t7): A 600/900/1700/2800, C 400/650/1200/1800,
;;       D 63/75/100/100, folate 300/400/600/800
;;     · infant AIs    — (NBK545442 App. J; NBK56068 t2): Ca 200/260, Fe 0.27/11,
;;       Zn 2/3, I 110/130, A 400/500, C 40/50, D 10/10, folate 65/80, B12 0.4/0.5
;;   One divergence worth a steward's eye: the vit D ul of 63 µg for 1–3 is the
;;   IOM figure; EFSA sets 50 µg for 1–10. This file is IOM-based throughout, so
;;   63 is internally consistent — but it is a choice, not a fact.
;; [DRAFT] `energy` is an EER, which depends on body size and activity; the
;;   figures here are moderate-activity mid-band. L3 then scales energy and protein
;;   by the day's committed labour on top, which is the right order — the band says
;;   what a body of this age needs at rest, the activity layer says what it did.
;;   Infancy (under 1) is absent, not estimated.
;; (nutrient rda ul) — a #f ceiling leaves the base's alone.
;; ── the table, printed the way the DRI prints it ─────────────────────────
;; One row per NUTRIENT, one column per band. The source tables are nutrient ×
;; life-stage and the question a reader actually has is "what happens to iron as
;; a body grows" — which a band-major layout buries across six blocks and this
;; one answers on a line. It also makes the striking facts legible: iron 0.27 at
;; three months and 11 at nine (a newborn runs on stores; breast milk is
;; iron-poor until they deplete), and calcium peaking in adolescence ABOVE the
;; adult figure.
;;
;; A cell is either one value for both sexes, or (F . M) where the DRI splits.
;; A #f ceiling means none is established for that band.
(define *band-max-age* '(0.5 1 3 8 13 18))    ; the column edges, ascending

;;                    ≤0.5    ≤1      ≤3     ≤8     ≤13          ≤18
(define *band-rda*
  `(("energy"      520     680     1200   1600   (1900 . 2100) (2200 . 2800))
    ("protein"     9.1     11      13     19     34            (46   . 52))
    ("fibre"       0       0       19     25     (26   . 31)   (26   . 38))
    ("omega-3"     0.5     0.5     0.7    0.9    (1.0  . 1.2)  (1.1  . 1.6))   ; the ALA adequate intake column (NBK56068 t4)
    ("drinking-water" 0.7  0.8     1.3    1.7    (2.1  . 2.4)  (2.3  . 3.3))   ; total water AI, litres (NBK56068 t4)
    ("iron"        0.27    11      7      10     8             (15   . 11))
    ("calcium"     200     260     700    1000   1300          1300)
    ("zinc"        2       3       3      5      8             (9    . 11))
    ("iodine"      110     130     90     90     120           150)
    ("sodium"      110     370     800    1000   1200          1500)
    ("potassium"   400     860     2000   2300   (2300 . 2500) (2300 . 3000))  ; AI throughout (NASEM 2019)
    ("magnesium"   30      75      80     130    240           (360  . 410))
    ("selenium"    15      20      20     30     40            55)
    ("vit C"       40      50      15     25     45            (65   . 75))
    ("vit A"       400     500     300    400    600           (700  . 900))
    ("vit D"       10      10      15     15     15            15)
    ("vit E"       4       5       6      7      11            15)
    ("vit K"       2       2.5     30     55     60            75)             ; AI throughout
    ("vit B1"      0.2     0.3     0.5    0.6    0.9           (1.0  . 1.2))
    ("vit B2"      0.3     0.4     0.5    0.6    0.9           (1.0  . 1.3))
    ("vit B3"      2       4       6      8      12            (14   . 16))
    ("vit B5"      1.7     1.8     2      3      4             5)              ; AI throughout
    ("vit B6"      0.1     0.3     0.5    0.6    1.0           (1.2  . 1.3))
    ("vit B7"      5       6       8      12     20            25)             ; AI throughout
    ("folate"      65      80      150    200    300           400)
    ("vit B12"     0.4     0.5     0.9    1.2    1.8           2.4)
    ("choline"     125     150     200    250    375           (400  . 550))))  ; AI throughout

;;                    ≤0.5    ≤1      ≤3     ≤8     ≤13    ≤18
(define *band-ul*
  `(("iron"        40      40      40     40     40     45)
    ("calcium"     1000    1500    2500   2500   3000   3000)
    ("zinc"        4       5       7      12     23     34)
    ("iodine"      #f      #f      200    300    600    900)
    ("sodium"      #f      #f      1200   1500   1800   2300)
    ("vit C"       #f      #f      400    650    1200   1800)
    ("vit A"       600     600     600    900    1700   2800)
    ("vit D"       25      38      63     75     100    100)
    ("selenium"    45      60      90     150    280    400)
    ("vit E"       #f      #f      200    300    600    800)
    ("vit B6"      #f      #f      30     40     60     80)
    ("choline"     #f      #f      1000   1000   2000   3000)
    ("folate"      #f      #f      #f     #f     #f     #f)))   ; synthetic-only UL: absent for food folate at every age (see the species base)

(define (band-index age)
  "The column AGE falls in, or #f for an adult (19+)."
  (let loop ((es *band-max-age*) (i 0))
    (cond ((null? es) #f)
          ((<= age (car es)) i)
          (else (loop (cdr es) (+ i 1))))))

(define (band-cell row i sex)
  "Column I of ROW, resolving an (F . M) split by SEX."
  (let ((v (list-ref row (+ i 1))))
    (if (pair? v) (if (equal? sex "M") (cdr v) (car v)) v)))

(define (life-stage-band age sex)
  "The rows for AGE as `sub-set*` shifts, or #f for an adult. Assembled from the
   two tables above, so a nutrient is stated once and read twice."
  (let ((i (band-index age)))
    (and i
         (map (lambda (r)
                (let* ((spec (car r))
                       (ulr  (assoc spec *band-ul*)))
                  (list spec #:rda (band-cell r i sex)
                             #:ul  (and ulr (band-cell ulr i sex)))))
              *band-rda*))))

(define (subsistence-L2-lifestage prof ctx)
  (let* ((sex (ctx-ref ctx 'sex "F")) (age (ctx-ref ctx 'age 30))
         (band (life-stage-band age sex)))
    (if band
        ;; a growing body: its own table, replacing the adult numbers outright
        (sub-set* prof band)
        (adult-lifestage-shifts prof ctx sex age))))

;; The adult conditions, as ratios on the sex-shifted base, per sex: after
;; menopause iron falls back to the male figure (8/18) while calcium and
;; vitamin D rise for both; a pregnancy folds the dependent's floor into the
;; carrier's (iron to 27 mg from either base, folate ×1.5, energy, protein and
;; ALA up); lactation lifts energy, vitamins A and C, iodine and ALA. A row is
;; stated once per sex so the ratio names its own base.
(define *elder-age* 51)
(define *adult-shifts*
  `(("elder"
     ("F" ("iron" #:rda ,(/ 8.0 18.0)) ("calcium" #:rda 1.2) ("vit D" #:rda ,(/ 20.0 15.0)) ("vit B6" #:rda ,(/ 1.5 1.3)))
     ("M" ("calcium" #:rda 1.2) ("vit D" #:rda ,(/ 20.0 15.0)) ("vit B6" #:rda ,(/ 1.7 1.3))))
    ("pregnant"
     ("F" ("iron" #:rda ,(/ 27.0 18.0)) ("folate" #:rda 1.5) ("energy" #:rda 1.13) ("protein" #:rda 1.4) ("omega-3" #:rda ,(/ 1.4 1.1))
          ("drinking-water" #:rda ,(/ 3.0 2.7)) ("potassium" #:rda ,(/ 2900.0 2600.0)) ("magnesium" #:rda ,(/ 360.0 320.0)) ("selenium" #:rda ,(/ 60.0 55.0))
          ("vit B1" #:rda ,(/ 1.4 1.1)) ("vit B2" #:rda ,(/ 1.4 1.1)) ("vit B3" #:rda ,(/ 18.0 14.0)) ("vit B5" #:rda 1.2) ("vit B6" #:rda ,(/ 1.9 1.3)) ("choline" #:rda ,(/ 450.0 425.0)))
     ("M" ("iron" #:rda ,(/ 27.0 8.0))  ("folate" #:rda 1.5) ("energy" #:rda 1.13) ("protein" #:rda 1.4) ("omega-3" #:rda ,(/ 1.4 1.1))
          ("drinking-water" #:rda ,(/ 3.0 3.7)) ("potassium" #:rda ,(/ 2900.0 3400.0)) ("magnesium" #:rda ,(/ 360.0 420.0)) ("selenium" #:rda ,(/ 60.0 55.0))
          ("vit B1" #:rda ,(/ 1.4 1.2)) ("vit B2" #:rda ,(/ 1.4 1.3)) ("vit B3" #:rda ,(/ 18.0 16.0)) ("vit B5" #:rda 1.2) ("vit B6" #:rda ,(/ 1.9 1.3)) ("choline" #:rda ,(/ 450.0 550.0))))
    ("lactating"
     ("F" ("energy" #:rda 1.2) ("vit A" #:rda 1.85) ("vit C" #:rda 1.6) ("iodine" #:rda ,(/ 290.0 150.0)) ("omega-3" #:rda ,(/ 1.3 1.1))
          ("drinking-water" #:rda ,(/ 3.8 2.7)) ("potassium" #:rda ,(/ 2800.0 2600.0)) ("selenium" #:rda ,(/ 70.0 55.0))
          ("vit B1" #:rda ,(/ 1.4 1.1)) ("vit B2" #:rda ,(/ 1.6 1.1)) ("vit B3" #:rda ,(/ 17.0 14.0)) ("vit B5" #:rda 1.4) ("vit B6" #:rda ,(/ 2.0 1.3)) ("vit B7" #:rda ,(/ 35.0 30.0)) ("choline" #:rda ,(/ 550.0 425.0)))
     ("M" ("energy" #:rda 1.2) ("vit A" #:rda 1.85) ("vit C" #:rda 1.6) ("iodine" #:rda ,(/ 290.0 150.0)) ("omega-3" #:rda ,(/ 1.3 1.1))
          ("drinking-water" #:rda ,(/ 3.8 3.7)) ("potassium" #:rda ,(/ 2800.0 3400.0)) ("selenium" #:rda ,(/ 70.0 55.0))
          ("vit B1" #:rda ,(/ 1.4 1.2)) ("vit B2" #:rda ,(/ 1.6 1.3)) ("vit B3" #:rda ,(/ 17.0 16.0)) ("vit B5" #:rda 1.4) ("vit B6" #:rda ,(/ 2.0 1.3)) ("vit B7" #:rda ,(/ 35.0 30.0))))))
(define (adult-shift-rows condition sex)
  (or (assoc-ref (or (assoc-ref *adult-shifts* condition) '()) sex) '()))
(define (adult-lifestage-shifts prof ctx sex age)
    (sub-shift* prof
      (append (or (assoc-ref *sex-shifts* sex) '())
              (if (>= age *elder-age*) (adult-shift-rows "elder" sex) '())
              (if (ctx-ref ctx 'pregnant #f) (adult-shift-rows "pregnant" sex) '())
              (if (ctx-ref ctx 'lactating #f) (adult-shift-rows "lactating" sex) '()))))

;; ── L3 · ACTIVITY / LABOUR — the value of labour-power IS its reproduction time:
;; the day's committed labour scales the energy & protein floor.
(define (activity-factor labour-hours)
  (+ 1 (* 0.5 (max 0 (min 1.4 (/ (- (or labour-hours 0) 4) 6))))))
;; HOW HARD. An hour of digging and an hour of bookkeeping are the same hour
;; and very different kilocalories: the DRI's physical-activity levels span
;; sedentary to very active at roughly 1.0 : 1.1 : 1.25 : 1.5 on the whole
;; day, which over the worked hours alone is the wider spread below. The
;; class weights the committed hours before the curve above reads them, and
;; the sweat term reads the same weighted hours (sweat rises with work rate
;; at a fixed temperature). The class is the work's own fact: a recipe
;; process states it — a "work:heavy" tag on the process, the class of its
;; ValueFlows effort quantity — and a person is never asked; an hour whose
;; work states no class is the unweighted, moderate one.
;; [DRAFT] the weights.
(define *work-intensity* '(("light" . 0.6) ("moderate" . 1.0) ("heavy" . 1.5) ("very-heavy" . 2.0)))
(define (work-intensity-weight id) (or (assoc-ref *work-intensity* (or id "moderate")) 1.0))
(define (work-intensity-of-tags tags)
  "The intensity class a recipe process carries among TAGS as \"work:<class>\", or #f."
  (find (lambda (c) (assoc c *work-intensity*)) (tag-values (or tags '()) "work")))
(define (effective-labour-hours ctx)
  "The day's committed hours weighted by how hard they are."
  (* (or (ctx-ref ctx 'labour-hours 0) 0) (work-intensity-weight (ctx-ref ctx 'labour-intensity #f))))
;; ── WHERE CLIMATE AND LABOUR MEET ────────────────────────────────────────
;; Sweat sodium is the one requirement neither layer can state alone: it is a
;; product of how hot it is AND how hard you worked, and it is the largest
;; single-nutrient swing in this whole catalogue. Every layer here receives the
;; full ctx, so L3 reads `region` alongside `labour-hours` and the interaction
;; costs no new machinery — an earlier version of this file claimed the stack
;; could not express it, which was simply wrong.
;;
;; The loss is ADDITIVE (grams out of the body), not a ratio, so `sub-add` rather
;; than `sub-shift`.
;;
;; The rate is DERIVED, not tabulated, because only one point of it is measured.
;; Sweat sodium is a product of two things that are each sourced:
;;
;;     mg Na per hour  =  sweat L/h  ×  sweat [Na⁺] mmol/L  ×  23 mg/mmol
;;
;; [DATA] Sweat rate rises roughly LINEARLY with ambient temperature, about
;;   0.04 L/h per °C at fixed work intensity (the 60→84 °F step raises it ~47 %).
;; [DATA] Work in heat costs 4.8–6 g sodium over a shift (10–15 g salt), higher
;;   unacclimatised; acclimation lowers sweat [Na⁺] by ~15–25 mmol/L.
;; [DRAFT] Sweat [Na⁺] 45 mmol/L unacclimated. The working TEMPERATURE is no
;;   longer a draft table: the shed states it from its own ERA5 record.
;;
;; So the hot case ANCHORS the curve and the slope carries it to the others,
;; instead of three numbers each invented separately. Check it against the
;; anchor: 35 °C ⇒ 0.65 L/h × 45 × 23 = 673 mg/h, ×8 h = 5.4 g — inside the
;; measured 4.8–6 g. And the slope then says temperate and cold are far LOWER
;; than a first guess: ~50 and ~0 mg/h, where an earlier draft of this file put
;; them at 150 and 60. Deriving them corrected them downward.
(define %sweat-na-mmol/l    45.0)   ; unacclimated
(define %sweat-acclim-mmol/l 20.0)  ; what acclimation takes off (mid of 15–25)
(define %na-mg-per-mmol     23.0)
(define %sweat-l/h-per-degc 0.04)   ; the measured slope
(define %sweat-anchor-degc  35.0)   ; the hot-work case the anchor was measured in
(define %sweat-anchor-l/h   0.65)   ; ⇒ 5.4 g over an 8 h shift, in the measured band

;; ── ACCLIMATION. A body that has worked this heat for a week or two reabsorbs
;; sodium before it reaches the skin: the same litres of sweat carry 15–25 mmol/L
;; less. That is a third of the concentration, so a settled worker and a new
;; arrival in the same field have measurably different floors, and the catalogue
;; now says so instead of noting it in a comment. Unacclimated is the DEFAULT —
;; it is the higher floor, and assuming everyone is seasoned would under-feed
;; exactly the person most at risk (the new arrival, in their first hot fortnight).
(define (sweat-na-mmol/l acclimated?)
  (if acclimated? (- %sweat-na-mmol/l %sweat-acclim-mmol/l) %sweat-na-mmol/l))

;; ── HOW WARM IT IS WHERE THE WORK HAPPENS.
;; The shed KNOWS. Every bioregion carries its own ERA5 record, and its generated
;; file states the mean of its warmest quarter (bioclim BIO10, data/emit-derived.scm),
;; so berlin.scm's real 19.9 °C is what this curve reads for anyone working in
;; Berlin — no transcription, no second table, nothing to drift.
;;
;; It takes no registration call, because the name is fixed by the generator and
;; the lookup is LAZY: resolved at the moment a floor is computed, not at load.
;; So the catalogue and the sheds have no load-order relation at all, and a shed
;; that has not been loaded simply falls through.
;;
;; What it falls through TO is the coarse region table — [DRAFT], and always was —
;; which still answers for a context standing in no shed: a synthetic test, an
;; unplaced scope, a figure entered by hand.
;; The generated table is a MODULE per shed — (localchimera knowledge worlds
;; <shed>-derived) — so the lookup names it. `#:ensure #f` matters: resolve-module
;; otherwise INVENTS an empty module for a shed that has none, and an invented
;; module answers "no such variable" the same way a real one does, which reads as
;; a fall-through and is one. Asking for a module that must already exist keeps
;; the distinction between "this shed has no table" and "this shed is unknown".
(cond-expand
 (guile
  (define (shed-derived-figure shed name)
    "The shed's derived NAME (\"warm-quarter-degc\", \"annual-mean-degc\", …), off its
     generated table module, or #f where the shed has none."
    ;; autoload the table (a shed's module is loaded on first ask) and invent none
    (let ((m (resolve-module (list 'localchimera 'knowledge 'worlds
                                   (string->symbol (string-append shed "-derived")))
                             #t #:ensure #f))
          (sym (string->symbol (string-append "*" shed "-derived-" name "*"))))
      (and m (module-defined? m sym) (module-ref m sym)))))
 (else
  ;; the browser build links no per-shed table modules, so every shed falls through
  ;; to the coarse region table below — the answer for a context standing in no shed
  (define (shed-derived-figure shed name) #f)))
(define (shed-derived-degc shed) (shed-derived-figure shed "warm-quarter-degc"))
;; what falls on the shed's fields in a day of the growing season: the record's
;; season rain (mm, per scenario class) over the season's months at 30.4 days each;
;; #f where the shed states no record. What a farm's shine rains (world.scm).
(define* (shed-rain-mm-day shed #:key (scenario "normal"))
  (let ((rain (and shed (shed-derived-figure shed "scenario-rain")))
        (season (and shed (shed-derived-figure shed "season"))))
    (and rain season (pair? season) (assoc-ref rain scenario)
         (/ (assoc-ref rain scenario) (* 30.4 (length season))))))

;; The climate region a position implies — latitude alone, the coarse table the
;; geography layer reads: within 30° of the equator is hot, from 50° cold, from 60° high
;; latitude, the rest temperate. The three figures are emitted to the browser, so the
;; app derives a fix's region by the same rule.
(define %hot-latitude 30.0)
(define %cold-latitude 50.0)
(define %high-latitude 60.0)
(define (region-for-lat lat)
  (let ((a (abs lat)))
    (cond ((>= a %high-latitude) "highLatitude")
          ((>= a %cold-latitude) "cold")
          ((<= a %hot-latitude) "hotArid")
          (else "temperate"))))

(define *region-working-degc*   ; [DRAFT] fallback — used only when no shed is known
  '(("hotArid" . 35.0) ("temperate" . 20.0) ("inland" . 20.0)
    ("cold" . 5.0) ("highLatitude" . 5.0)))

(define (working-degc ctx)
  "The temperature this person works at. A stated figure wins; then the shed they
   are in; then the coarse region table; then temperate."
  (or (ctx-ref ctx 'working-degc #f)
      (and=> (ctx-ref ctx 'shed #f) shed-derived-degc)
      (assoc-ref *region-working-degc* (ctx-ref ctx 'region "temperate"))
      20.0))

(define (sweat-l/h degc)
  "Sweat rate at DEGC, from the anchor and the slope. Floored at zero — below
   about 18 °C the linear fit runs negative, which means the curve has left its
   measured range, not that a body reclaims sodium."
  (max 0.0 (+ %sweat-anchor-l/h (* %sweat-l/h-per-degc (- degc %sweat-anchor-degc)))))

(define* (sweat-sodium-mg degc hours #:optional (acclimated? #f))
  "Sodium lost to sweat over HOURS of committed labour at DEGC."
  (* (sweat-l/h degc) (sweat-na-mmol/l acclimated?) %na-mg-per-mmol (max 0 (or hours 0))))

(define (subsistence-L3-activity prof ctx)
  (let* ((hours (effective-labour-hours ctx))
         (af    (activity-factor hours))
         (sweat (sweat-sodium-mg (working-degc ctx) hours
                                 (ctx-ref ctx 'acclimated #f)))
         (litres (* (sweat-l/h (working-degc ctx)) (max 0 (or hours 0))))
         (p     (sub-shift (sub-shift prof "energy" #:rda af) "protein" #:rda af)))
    ;; the same litres that carried the salt out are litres to drink back
    (if (> sweat 0) (sub-add (sub-add p "sodium" sweat) "drinking-water" litres) p)))

;; ── L4 · HISTORICAL-MORAL — the ratified standard lifts the floor above bare
;; physiology to the society's decent life. Governance-set, may only RAISE (≥1),
;; never past a toxicity ceiling. Bare survival is standard = 1.
;; ── L5 · SELF — what only this person knows about this body, stated by
;; them and kept private unless they choose otherwise. A named condition is a
;; row set here, sourced where a source exists and marked where it is a
;; clinical rule of thumb; the person states the condition, never the number.
;; The layer runs after the ratified standard, before the follow rule, and it
;; may LOWER a floor: a kidney that cannot clear protein makes the population
;; floor a harm, and the self layer is the one place the tables yield to the
;; body. (id label row …) — a row is (spec #:rda k …) as the other layers
;; write it, or (spec #:add amount) for an absolute step.
(define *self-conditions*
  '(("smoker"          "smokes"                                          ("vit C" #:add 35))                                         ; IOM 2000: smokers +35 mg/d
    ("alcohol"         "drinks regularly"                                ("vit B1" #:rda 1.3) ("folate" #:rda 1.2) ("vit B6" #:rda 1.2) ("magnesium" #:rda 1.2))   ; [DRAFT]
    ("heavy-menses"    "heavy menstrual loss"                            ("iron" #:rda 1.5))                                         ; [DRAFT] the female shift is the average loss
    ("infection"       "fever or infection"                              ("energy" #:rda 1.13) ("protein" #:rda 1.2))                ; [DRAFT] ~13 % per °C of fever
    ("healing"         "healing a wound or fracture"                     ("energy" #:rda 1.2) ("protein" #:rda 1.5) ("vit C" #:rda 2) ("zinc" #:rda 1.5))   ; [DRAFT]
    ("burn"            "recovering from a major burn"                    ("energy" #:rda 1.5) ("protein" #:rda 2))                   ; [DRAFT] the upper clinical range
    ("malabsorption"   "malabsorption: coeliac, Crohn's, after surgery"  ("iron" #:rda 1.5) ("zinc" #:rda 1.5) ("vit B12" #:rda 1.5) ("vit D" #:rda 1.5) ("folate" #:rda 1.3) ("vit A" #:rda 1.3))   ; [DRAFT]
    ("kidney"          "chronic kidney disease"                          ("protein" #:rda 0.75) ("potassium" #:rda 0.75) ("sodium" #:rda 0.8))   ; [DRAFT] restriction; the potassium ceiling a clinician sets is not a row here
    ("acid-reducers"   "long-term acid reducers or metformin"            ("vit B12" #:rda 1.5) ("iron" #:rda 1.3) ("magnesium" #:rda 1.2))   ; [DRAFT]
    ("sun-scarce"      "little sun on the skin: indoors, covered, or dark skin far from the equator" ("vit D" #:rda 1.5 #:w 1.3))   ; [DRAFT]
    ("partial-feeding" "breastfeeding partly, with other food"           ("energy" #:rda 0.92) ("vit A" #:rda 0.75) ("vit C" #:rda 0.85) ("iodine" #:rda 0.75) ("drinking-water" #:rda 0.85) ("omega-3" #:rda 0.92))))   ; [DRAFT] halfway back from the exclusive-feeding lift
(define (self-condition-rows id) (let ((c (assoc id *self-conditions*))) (if c (cddr c) '())))
(define (sub-self prof rows)
  (fold (lambda (r p) (if (eq? (cadr r) #:add) (sub-add p (car r) (caddr r)) (apply sub-shift p r))) prof rows))
(define (subsistence-L5-self prof ctx)
  (sub-self prof (append-map self-condition-rows (ctx-ref ctx 'self '()))))

;; THE RATIFIED STANDARD, stated once. A scope's ratified standard lifts the floors
;; its people are held to above bare adequacy, in every catalogue that carries an L4
;; layer (this one, housing.scm, rest.scm) and in the one it will carry next. It has
;; one rule: it only raises. Below 1, absent or not a number, it is 1.
(define (ratified-standard x) (if (and (number? x) (> x 1)) x 1))

;; A LIFT raises a floor by FACTOR as far as the floor's own ceiling allows and stops
;; there: a floor lifted through its ceiling is a plan no one can meet, and one left
;; unlifted because the lift would cross it is a floor lower than the standard asks.
;; It never lowers a floor, and rebuilds the row with `sub-set`'s own fields, so what
;; else a row carries (the body's store of a nutrient) rides through. ONLY names the
;; rows the layer is for (housing lifts gradients, never a gate).
(define* (sub-lift prof factor #:key (only (lambda (n) #t)))
  (if (> factor 1)
      (map (lambda (n)
             (if (only n)
                 (let* ((raised (* (sub-rda n) factor))
                        (to (if (sub-ul n) (max (sub-rda n) (min raised (sub-ul n))) raised)))
                   (sub-nut (sub-spec n) (sub-group n) (sub-unit n) to (sub-ul n) (sub-w n) (sub-reserve n)))
                 n))
           prof)
      prof))

(define (subsistence-L4-cultural prof ctx)
  (sub-lift prof (ratified-standard (ctx-ref ctx 'standard 1))))

;; the person's composed reproduction profile — L0 base, then the layers folded
;; essential→contingent. (L5 self / measured biomarkers stays CLIENT-side & private.)
(define (subsistence-profile-raw ctx)
  (sub-energy-ceiling
   (sub-follow
    (subsistence-L5-self
    (subsistence-L4-cultural
      (subsistence-L3-activity
        (subsistence-L2c-body
          (subsistence-L2-diet
            (subsistence-L2-lifestage
              (subsistence-L1-geography (subsistence-species-base) ctx) ctx) ctx) ctx) ctx) ctx) ctx))
   ctx))

;; A FLOOR NEVER STANDS ABOVE ITS OWN CEILING. The layers compose by lifting a
;; floor (a diet, a life stage, a stack of conditions the person states about
;; themselves), and none of them lifts the ceiling with it, so a stack can carry a
;; floor through its tolerable upper limit — iron lifted 1.5 × 1.5 × 1.3 stands at
;; 52.65 against a limit of 45. An empty band is a plan nobody can meet, and the
;; solve would answer with an infeasibility that names no one. So the floor is held
;; at its ceiling, and `subsistence-clamped` names the nutrients it was held for,
;; so the finding is said and never a silent change.
(define (sub-floor-under-ceiling prof)
  (fold (lambda (n p) (if (and (sub-ul n) (> (sub-rda n) (sub-ul n)))
                          (sub-set p (sub-spec n) #:rda (sub-ul n))
                          p))
        prof prof))
(define (subsistence-clamped ctx)
  "The nutrients whose composed floor stood above their ceiling for CTX, and was held at it."
  (filter-map (lambda (n) (and (sub-ul n) (> (sub-rda n) (sub-ul n)) (sub-spec n)))
              (subsistence-profile-raw ctx)))
(define (subsistence-profile ctx)
  (sub-floor-under-ceiling (subsistence-profile-raw ctx)))

;; ── L2b · DIET — what a person will not eat raises what the rest must carry:
;; non-haem iron is absorbed less well, so a vegetarian's iron floor is 1.8×
;; and a vegan's zinc 1.5× (IOM 2001). Read off the person's own diet: tags on
;; ctx (`diet`, as agent->subsistence-ctx carries them), in the shift shape the
;; other layers use. A diet only raises; nutrition.ts folds the same generated rows.
(define *diet-shifts*                 ; diet id → shift rows
  '(("vegetarian" ("iron" #:rda 1.8))
    ("vegan"      ("iron" #:rda 1.8) ("zinc" #:rda 1.5))))
(define (diet-floor-shifts tags)
  "The shift rows the diet: tags among TAGS carry — each diet's rows once."
  (append-map (lambda (name) (or (assoc-ref *diet-shifts* name) '()))
              (tag-values (or tags '()) "diet")))
(define (subsistence-L2-diet prof ctx)
  (sub-shift* prof (diet-floor-shifts (ctx-ref ctx 'diet '()))))

;; ── L2c · BODY — the two floors the tables state for a REFERENCE body, read
;; for this one. The DRI publishes no energy RDA: it publishes an equation, the
;; Estimated Energy Requirement, in age, sex, height and weight, and every
;; energy figure above is that equation at the reference body of the band
;; (IOM 2005, DRI reference heights and weights). Protein is stated per
;; kilogram (0.8 g/kg for an adult), and the 46 g and 56 g are that rate at
;; 57 kg and 70 kg. So a stated height and weight RESCALE those two floors —
;; energy by the equation's ratio at this body against the reference body of
;; the same age and sex, protein by the weight ratio — and every other layer
;; and table stays as written: the sex split, the band, the cold, the
;; pregnancy fold, the day's labour all compose multiplicatively on top.
;; Lysine follows protein, so it moves with the weight. The micronutrient
;; tables are flat per life stage in the DRI and are left alone. Both fields
;; must be stated, else the layer is the identity; either alone says little.
;;
;; [DATA] reference body per band (kg, m), F and M — the DRI's own reference
;;   heights and weights: infants 6/0.62, 9/0.71; 1–3 12/0.86; 4–8 20/1.15;
;;   9–13 F 37/1.44 M 36/1.44; 14–18 F 54/1.63 M 61/1.74; adult F 57/1.63 M 70/1.76.
;; [DATA] the EER (kcal/d), low-active physical-activity coefficient — the
;;   rest the labour layer scales on top of:
;;   men 19+     662 − 9.53·age + 1.11·(15.91·kg + 539.6·m)
;;   women 19+   354 − 6.91·age + 1.12·( 9.36·kg + 726·m)
;;   boys 3–18   88.5 − 61.9·age + 1.13·(26.7·kg + 903·m) + 20 (25 from 9)
;;   girls 3–18  135.3 − 30.8·age + 1.16·(10.0·kg + 934·m) + 20 (25 from 9)
;;   under 3     89·kg − 100 + 20
;; (max-age kgF mF kgM mM); #f is the adult row
(define *reference-body*
  '((0.5 6 0.62 6 0.62) (1 9 0.71 9 0.71) (3 12 0.86 12 0.86) (8 20 1.15 20 1.15)
    (13 37 1.44 36 1.44) (18 54 1.63 61 1.74) (#f 57 1.63 70 1.76)))
;; (sex min-age intercept age-term pa kg-term m-term growth pa-top) — the first
;; row whose min-age ≤ age wins; under 3 is the infant rule. PA is the low-active
;; coefficient the floor stands on; PA-TOP is the same equation's VERY ACTIVE one
;; (IOM 2005: men 1.48, women 1.45, boys 1.42, girls 1.56), the most a body of
;; this age, sex and size burns in a day — what the energy ceiling reads.
(define *eer-rows*
  '(("F" 19 354   -6.91 1.12  9.36 726   0  1.45) ("F" 9 135.3 -30.8 1.16 10.0 934 25 1.56) ("F" 3 135.3 -30.8 1.16 10.0 934 20 1.56)
    ("M" 19 662   -9.53 1.11 15.91 539.6 0  1.48) ("M" 9  88.5 -61.9 1.13 26.7 903 25 1.42) ("M" 3  88.5 -61.9 1.13 26.7 903 20 1.42)))
(define (reference-body age sex)
  "The DRI reference body for AGE and SEX: (kg . m)."
  (let ((r (or (find (lambda (r) (and (car r) (<= age (car r)))) *reference-body*)
               (last *reference-body*))))
    (if (equal? sex "M") (cons (list-ref r 3) (list-ref r 4)) (cons (list-ref r 1) (list-ref r 2)))))
(define* (eer sex age kg m #:key (activity 'low))
  "The estimated energy requirement of a body, kcal/d: low-active (the floor's
   reading) or, with #:activity 'top, very active — the same equation at its
   highest published coefficient."
  (let ((r (find (lambda (r) (and (equal? (car r) sex) (>= age (cadr r)))) *eer-rows*)))
    (if r
        (+ (list-ref r 2) (* (list-ref r 3) age)
           (* (if (eq? activity 'top) (list-ref r 8) (list-ref r 4)) (+ (* (list-ref r 5) kg) (* (list-ref r 6) m)))
           (list-ref r 7))
        (+ (* 89 kg) -100 20))))
(define (subsistence-L2c-body prof ctx)
  (let ((kg (ctx-ref ctx 'weight-kg #f)) (cm (ctx-ref ctx 'height-cm #f)))
    (if (and (number? kg) (number? cm) (> kg 0) (> cm 0))
        (let* ((sex (ctx-ref ctx 'sex "F")) (age (ctx-ref ctx 'age 30))
               (ref (reference-body age sex))
               ;; a ratio, bounded: a mistyped figure cannot halve or double a floor past what a body can be
               (clamp (lambda (k) (max 0.6 (min 1.8 k))))
               (ke (clamp (/ (eer sex age kg (/ cm 100.0)) (eer sex age (car ref) (cdr ref)))))
               (kp (clamp (/ kg (car ref)))))
          (sub-shift (sub-shift prof "energy" #:rda ke) "protein" #:rda kp))
        prof)))

;; ── the ENERGY CEILING — a body can take only so much. The DRI publishes no
;; UL for energy because energy is not a toxin: what a body eats past what it
;; burns it stores, and a plan that feeds a body twice its need to reach some
;; other floor has not fed it, it has found a way round the floor. The ceiling
;; is therefore the most this body could BURN in a day: the EER at its very
;; active coefficient, over the low-active one the floor stands on, as a ratio
;; on the floor wherever the layers left it (the day's labour, the climate,
;; the standard all lift both edges together). Under three the equation has
;; no activity term; the child's ratio is the youngest row's of the sex. Read
;; for the stated body where one is stated, else the band's reference body.
;; The rule runs LAST, once, in both stacks, like the follow rule: the base
;; states no energy ceiling by hand, and one that drifted from the equation
;; would be a bug this shape cannot have.
(define (energy-ceiling-ratio ctx)
  (let* ((sex (ctx-ref ctx 'sex "F")) (age (max 3 (ctx-ref ctx 'age 30)))
         (kg (ctx-ref ctx 'weight-kg #f)) (cm (ctx-ref ctx 'height-cm #f))
         (body (if (and (number? kg) (number? cm) (> kg 0) (> cm 0)) (cons kg (/ cm 100.0)) (reference-body age sex))))
    (/ (eer sex age (car body) (cdr body) #:activity 'top) (eer sex age (car body) (cdr body)))))
(define (sub-energy-ceiling prof ctx)
  (let ((e (find (lambda (n) (equal? (sub-spec n) "energy")) prof)))
    (if e (sub-set prof "energy" #:ul (* (sub-rda e) (energy-ceiling-ratio ctx))) prof)))

;; the reproduction BANDS for the planner: ((spec rda ul w) …) — each nutrient's
;; two walls and their steepness, the catalogue's own row handed to the solve
;; whole (plan-scope #:bands): the deficiency edge a hard floor (a deficit on the
;; nutrient's on-hand, held by its ≥0 balance), the toxicity edge a fixed-weight
;; `frag` on its delivered net, ul #f ⇒ no ceiling. One object; the dial draws
;; the same band.
(define (subsistence-bands ctx)
  (map (lambda (n) (list (sub-spec n) (sub-rda n) (sub-ul n) (sub-w n))) (subsistence-profile ctx)))
;; the two edges as views of the band, for readers that want one side
(define (subsistence-floors ctx)
  (map (lambda (b) (cons (car b) (cadr b))) (subsistence-bands ctx)))
(define (subsistence-caps ctx)
  (filter-map (lambda (b) (and (caddr b) (cons (car b) (cons (caddr b) (cadddr b))))) (subsistence-bands ctx)))

;; ── THE TABLES, AS ONE VALUE ─────────────────────────────────────────────
;; Every table the browser's nutrition layers fold over is stated HERE and
;; nowhere else: tools/emit/nutrition-emit.scm reads this alist and writes
;; ui/app/nutrition-catalogue.ts, and `make check-nutrition-fresh` refuses a
;; stale copy — the same shape the protocol declaration keeps with
;; seam-wire.ts. The formulas (activity, sweat) stay code on both sides; the
;; numbers they read are tables here too.
(define (subsistence-catalogue-tables)
  `((species-base . ,(subsistence-species-base))
    (sex-shifts . ,*sex-shifts*)
    (elder-age . ,*elder-age*)
    (adult-shifts . ,*adult-shifts*)
    (geo-shifts . ,*geo-shifts*)
    (diet-shifts . ,*diet-shifts*)
    (follows . ,*follows*)
    (reference-body . ,*reference-body*)
    (eer-rows . ,*eer-rows*)
    (work-intensity . ,*work-intensity*)
    (altitude-shifts . ,*altitude-shifts*)
    (winter-sun-lat . ,*winter-sun-lat*)
    (winter-sun-shift . ,*winter-sun-shift*)
    (self-conditions . ,*self-conditions*)
    (band-max-age . ,*band-max-age*)
    (band-rda . ,*band-rda*)
    (band-ul . ,*band-ul*)
    (region-working-degc . ,*region-working-degc*)
    (region-latitudes . (,%hot-latitude ,%cold-latitude ,%high-latitude))))
