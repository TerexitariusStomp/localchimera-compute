;;; land-transformation-scales.scm — water-harvesting earthworks, at any scale.
;;;
;;; ── WHERE THE NUMBERS COME FROM, AND WHERE THEY DO NOT ──────────────────────
;;;
;;; This file keeps two kinds of knowledge strictly apart.
;;;
;;; LEADS come from Andrew Millison's field documentation
;;; (youtube.com/@amillison, ingested as captions). Footage is very good at
;;; telling you what EXISTS — that half-moons hold the Sahel, that villages in
;;; Maharashtra rebuilt their water table in a 45-day competition — and very
;;; poor at telling you how big to dig. A search across ~560 KB of transcript
;;; finds four statements of the form "N units deep". So nothing here is
;;; measured from video. `*land-transformation-leads*` records what the footage
;;; pointed AT, with a timestamp, and that is all it is for.
;;;
;;; SPECIFICATIONS come from FAO's design manual (Critchley & Siegert 1991,
;;; CC BY-NC-SA 3.0 IGO), which is where the leads terminate. It dimensions each
;;; technique: radius, bund length, impounded area, earthwork volume per
;;; structure, structures per hectare, slope limits, catchment ratios.
;;; `*earthwork-specs*` is sourced entirely from it, cited by section.
;;;
;;; The division is the point. A recipe asserts that if you move this much
;;; earth you get that much water, and that assertion has to rest on an
;;; engineering manual, not on a narrator. The video's contribution is that we
;;; knew to go and look — real, worth recording, and not a coefficient.
;;;
;;; Discovery path, reproducible:
;;;   node tools/corpus/corpus.mjs leads permaculture     # → "half-moon", "contour bund"
;;;   node tools/corpus/corpus.mjs query permaculture "semi-circular bunds dimensions" \
;;;        --source fao-water-harvesting-manual
;;;
;;; Reading: docs/planning/food/permaculture-bring-over.md §5.
;;;
;;; Loaded after planner.scm. Provides
;;;   *land-transformation-leads*  — what to research, and where it was heard
;;;   *earthwork-specs*            — FAO design parameters, buildable
;;;   *restoration-offsite-factor* — spillover, ANCHOR (see below)
;;;   (earthwork-ref …) (earthwork-for-slope …) (earthworks-for-area …)
;;;   (land-transformation-records #:technique #:area-ha …)

;; ════════════════════════════════════════════════════════════════════════════
;; 1. LEADS — what the footage pointed at. NOT coefficients.
;; ════════════════════════════════════════════════════════════════════════════
;;
;; Each row is a place the documentation showed working at a given scale, with
;; the technique it named and where to hear it. These are research anchors and
;; scenario settings: they say "a village-scale scheme of about this size exists
;; in about this rainfall, go and find its evaluation". They are deliberately
;; NOT wired into any flow.
;;
;; The `binds` column is the observation worth keeping. What stops the work
;; changes as it scales — a household is bounded by roof area, a village by the
;; labour-days it can raise, a state by administrative reach — so scaling is not
;; repetition, and a model carrying only one of those constraints cannot move
;; between these scales.
(define-module (playnet planner knowledge recipes land-transformation-scales)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet planner knowledge dsl shorthand) #:select (rp in out wrk in/u out/u wrk/u))
  #:use-module (playnet planner vf schemas)
  #:export (*land-transformation-leads* row-field lead-ref
            *restoration-offsite-factor* *restoration-coupling* *earthwork-specs*
            *diversion-ditch-m3-per-100m* *max-rangeland-c-ca* earthwork-ref
            earthwork-for-slope earthworks-for-area *labour-days-per-m3-onsite*
            *labour-days-per-m3-carried* *workday-hours* earthwork-labour-hours
            land-transformation-records))

(define *land-transformation-leads*
  '((household
     (scale-ha   0.02)
     (rain-mm    380)
     (technique  "taanka")
     (binds      catchment)
     (site       "Bakri village, Thar Desert, Rajasthan — built with Gravis")
     (heard      "[F7pyGgBmzDY] 06:37")
     (research   "GRAVIS taanka programme evaluations; CGWB artificial-recharge manual"))

    (homestead
     (scale-ha   0.71)
     (rain-mm    900)
     (technique  "street runoff harvesting")
     (binds      catchment)
     (site       "Desert streetside harvesting at 25 years, Tucson")
     (heard      "[TCkoAvRWDLQ] 06:22")
     (research   "Lancaster, Rainwater Harvesting for Drylands (in-copyright, manifest)"))

    (field
     (scale-ha   1.0)
     (rain-mm    350)
     (technique  "half-moon")           ; = FAO's semi-circular bund, engineered
     (binds      labour)
     (site       "Great Green Wall sites, Senegal and Niger — WFP")
     (heard      "[xbBdIG--b58] 02:32")
     (research   "FAO water-harvesting manual §5.4 — LANDED, see *earthwork-specs*"))

    (farm
     (scale-ha   7.3)
     (rain-mm    900)
     (technique  "agroforestry conversion")
     (binds      labour)
     (site       "Smallholder transition, Cauvery basin")
     (heard      "[T2fLQnGKZ7Y] 04:10")
     (research   "ICRAF agroforestry species/spacing databases"))

    (village
     (scale-ha   1600.0)
     (rain-mm    375)
     (technique  "contour trench + farm pond + percolation tank")
     (binds      labour)
     (site       "Paani Foundation Water Cup villages, Maharashtra")
     (heard      "[-8nqnOcoLqE] 09:01")
     (research   "Paani Foundation Water Cup published results; IWMI Maharashtra studies"))

    (landscape
     (scale-ha   107.0)
     (rain-mm    900)
     (technique  "tank desilting")
     (binds      machinery)
     (site       "Lake desilting, Cauvery basin")
     (heard      "[T2fLQnGKZ7Y] 12:40")
     (research   "Tamil Nadu / Karnataka tank rehabilitation programme reports"))

    (region
     (scale-ha   300000.0)
     (rain-mm    350)
     (technique  "half-moon + zai, at programme scale")
     (binds      reach)
     (site       "Great Green Wall / WFP resilience projects, Niger")
     (heard      "[xbBdIG--b58] 10:56")
     (research   "WFP Niger programme evaluations; Great Green Wall status reports"))))

;; Leads and specs are the same shape — a keyed row of (field value) pairs — so
;; they read through one accessor. `assoc` covers both symbol and string keys.
(define (row-field rows key field)
  "FIELD of the row named KEY in ROWS, or #f."
  (let ((row (assoc key rows)))
    (and row (and=> (assq field (cdr row)) cadr))))

(define (lead-ref tier key) (row-field *land-transformation-leads* tier key))

;; The spillover claim — restoring a hectare benefits neighbouring land through
;; downstream infiltration and wind protection, stated in the Niger footage as a
;; factor of three ([xbBdIG--b58] 11:26). Kept as ANCHOR, NOT as a measured
;; coefficient: it is a programme's summary figure quoted in an interview, and
;; the primary evaluation that would substantiate it is on the research list.
;;
;; The claim has TWO halves, and they need different machinery. Splitting them
;; is what stops the factor being applied twice.
;;
;; DOWNSTREAM INFILTRATION needs no coefficient — it needs the limit held at the
;; right SCALE. `groundwater` is a `within` fragility over the shed
;; (knowledge/doon-shed.scm), so draws and restores from every place at or under
;; the watershed meet in one pooled budget: water sunk on an upslope plot
;; relieves the barrier a downslope well is held by, because they are the same
;; barrier. Nothing to add here, and nothing to multiply.
;;
;; This was wrong once and is worth recording as wrong. Declared instead as a
;; per-spec RATE — which is what a bioregion's limits used to be — each plot
;; gets its own private envelope and the shed feels nothing as the table falls:
;; two farms pumping under one shed drew identically with and without the shed's
;; barrier. That is precisely the distributed-draw failure playnet.typ
;; §"Shared budgets" says the pooled budget exists to catch, so the scale is not
;; a modelling nicety here; it is the whole mechanism.
;;
;; WIND PROTECTION AND SURFACE SHELTER is the half that genuinely needs an
;; edge: restored vegetation shelters neighbouring ground from erosion, which is
;; pressure on `topsoil` rather than on water. That is spec-to-spec, which is
;; exactly *eco-couple*'s shape (C[k][j]: drawing agent j stresses agent k),
;; and it rides the same `propagate` path the container roll-up uses.
;;
;; The coefficient is NOT known. What Niger reports is a single summary figure
;; for both halves together, quoted in an interview, and splitting it between
;; them takes the primary evaluation that is still on the research list. So the
;; factor below is recorded, flagged, and deliberately NOT wired into any solve.
;; A number that cannot be attributed to one mechanism should not silently act
;; through one.
(define *restoration-offsite-factor* 3.0)   ; ANCHOR — [xbBdIG--b58] 11:26, both halves together

;; The coupling the wind-protection half WOULD use, once a coefficient exists.
;; Shape only: (k-spec . ((j-spec . c) …)) for #:eco-couple. Left empty rather
;; than seeded with a guess — an empty coupling changes nothing, whereas an
;; invented one changes every plan and looks like evidence.
(define *restoration-coupling* '())   ; EXTERNAL — awaiting the Niger evaluation

;; ════════════════════════════════════════════════════════════════════════════
;; 2. SPECIFICATIONS — FAO 1991, the manual the leads terminate in.
;; ════════════════════════════════════════════════════════════════════════════
;;
;; Critchley & Siegert, *Water Harvesting: A Manual for the Design and
;; Construction of Water Harvesting Schemes for Plant Production*, FAO 1991.
;; In the corpus as `fao-water-harvesting-manual`; citations are section numbers
;; and `L####` against texts/fao-water-harvesting-manual/text.md.
;;
;; Semi-circular bunds ARE the Sahel half-moon, specified. The manual gives two
;; standard designs, and the difference between them is the whole reason a
;; specification beats a description: the same technique at radius 6 m and at
;; radius 20 m has entirely different earthwork budgets per hectare, and the
;; choice between them is set by land slope and by what you intend to grow.
;;
;; Fields, per structure unless stated:
;;   radius-m           the semi-circle's radius
;;   bund-length-m      length of earth bund
;;   impounded-m2       area held behind the bund
;;   earthworks-m3      soil moved per structure
;;   per-ha             structures per hectare
;;   earthworks-ha-m3   soil moved per hectare
;;   max-slope-pct      the slope limit the design is valid to
;;   c-ca               catchment : cultivated area ratio
;;   tip-spacing-m      distance between the tips of one structure
;;   row-gap-m          distance to the next structure
(define *earthwork-specs*
  '(("semi-circular-bund-a"
     (technique        "semi-circular bund (half-moon), small design")
     (radius-m         6)
     (bund-length-m    19)
     (impounded-m2     57)
     (earthworks-m3    2.4)
     (per-ha           73)
     (earthworks-ha-m3 175)
     (max-slope-pct    1.0)
     (c-ca             1.4)
     (tip-spacing-m    12)
     (row-gap-m        3)
     (overflow         #f)      ; design "a" needs no overflow provision
     (cite             "FAO 1991 §5.4, Table 21 — L3966-L4108"))

    ("semi-circular-bund-b"
     (technique        "semi-circular bund (half-moon), large design")
     (radius-m         20)
     (bund-length-m    63)
     (impounded-m2     630)
     (earthworks-m3    26.4)
     (per-ha           4)
     (earthworks-ha-m3 105)
     (max-slope-pct    2.0)
     (c-ca             3.0)
     (tip-spacing-m    40)
     (row-gap-m        10)
     (overflow         #t)
     (cite             "FAO 1991 §5.4, Table 21 — L3966-L4108"))))

;; A diversion ditch, where the small design needs one, adds this much soil per
;; 100 m of ditch (FAO §5.4, note under Table 21).
(define *diversion-ditch-m3-per-100m* 62.5)

;; The manual's general guidance for rangeland and fodder schemes: catchment no
;; more than three times the cultivated area (FAO §5.4.1, L3948). Above that the
;; structure has to carry an overflow, which is why design "b" has one.
(define *max-rangeland-c-ca* 3.0)

(define (earthwork-ref key field) (row-field *earthwork-specs* key field))

(define (earthwork-for-slope slope-pct)
  "The lowest-earthwork spec valid at SLOPE-PCT, or #f if the slope exceeds
   every design the manual covers."
  (let ((valid (filter (lambda (s) (<= slope-pct (earthwork-ref (car s) 'max-slope-pct)))
                       *earthwork-specs*)))
    (and (pair? valid)
         (car (fold (lambda (s best)
                      (if (< (earthwork-ref (car s) 'earthworks-ha-m3)
                             (earthwork-ref (car best) 'earthworks-ha-m3))
                          s best))
                    (car valid) (cdr valid))))))

(define* (earthworks-for-area key area-ha #:key (ditch-m 0.0))
  "Cubic metres of soil moved to treat AREA-HA with spec KEY."
  (let ((per-ha (earthwork-ref key 'earthworks-ha-m3)))
    (and per-ha (+ (* per-ha area-ha)
                   (* (/ ditch-m 100.0) *diversion-ditch-m3-per-100m*)))))

;; ════════════════════════════════════════════════════════════════════════════
;; 3. The recipe — one process, sized from the specification
;; ════════════════════════════════════════════════════════════════════════════
;;
;; Slow, spread, sink, as consume/produce flows. Land and labour go in; treated
;; land and impounded water come out.
;;
;; Every quantity below is computed from *earthwork-specs*. The tier is a
;; SCENARIO — how much area to treat, on what slope — not a source of
;; coefficients.
;;
;; ── LABOUR, from the manual rather than from an estimate ────────────────────
;; FAO §5.7 Table 24 (L4653-L4710) states volume moved AND person-days per
;; hectare for contour stone bunds, across two bund spacings and two stone
;; sizes, split by whether the material is already lying in the field or has to
;; be carried. Every one of those six rows divides out to the same pair of
;; numbers, which is what makes them worth trusting as a rate rather than as
;; four separate readings:
;;
;;   material already on site   2.0 person-days per m3
;;   material carried in        3.0 person-days per m3
;;
;; The carrying premium is a full 50%, which is the manual's real lesson here:
;; on this kind of work, moving the material costs half again as much as
;; placing it, so where the stone or spoil already lies changes the labour bill
;; more than any choice of design does.
;;
;; These are STONE bunds, and the recipe's other designs move earth — so this
;; is the manual's own figure applied one technique across, not a measurement of
;; digging. It replaces a bare guess with a sourced rate at the right magnitude,
;; and is marked ANCHOR for that reason.
(define *labour-days-per-m3-onsite* 2.0)      ; FAO 1991 §5.7 Table 24 — L4653
(define *labour-days-per-m3-carried* 3.0)     ; FAO 1991 §5.7 Table 24 — L4700
(define *workday-hours* 8.0)                  ; person-day → hours, stated not assumed

(define* (earthwork-labour-hours soil-m3 #:key (carried? #f))
  "Hours to move SOIL-M3, at the manual's person-day rate."
  (* soil-m3 *workday-hours*
     (if carried? *labour-days-per-m3-carried* *labour-days-per-m3-onsite*)))

(define* (land-transformation-records #:key (technique "semi-circular-bund-a")
                                            (area-ha 1.0)
                                            (rain-mm 350)
                                            (place "scheme")
                                            (ditch-m 0.0)
                                            ;; whether the material has to be carried to the line —
                                            ;; a 50% labour premium in the manual's own figures
                                            (carried? #f))
  (let* ((soil-m3   (or (earthworks-for-area technique area-ha #:ditch-m ditch-m) 0.0))
         (hours     (earthwork-labour-hours soil-m3 #:carried? carried?))
         (per-ha    (or (earthwork-ref technique 'per-ha) 0))
         (impounded (or (earthwork-ref technique 'impounded-m2) 0))
         (c-ca      (or (earthwork-ref technique 'c-ca) 1.0))
         ;; Water reaching the structures: the cultivated area plus the
         ;; catchment feeding it, times the season's rain. 1 mm on 1 ha = 10 m3.
         (water-m3  (* area-ha (+ 1.0 c-ca) 10.0 rain-mm))
         (resources
          (list (make-economic-resource #:id "untreated-land" #:conforms-to "land" #:classified-as '()
                  #:accounting-quantity (make-measure area-ha "ha") #:onhand-quantity (make-measure area-ha "ha")
                  #:current-location place)
                (make-economic-resource #:id "seasonal-rainfall" #:conforms-to "water" #:classified-as '()
                  #:accounting-quantity (make-measure water-m3 "m3") #:onhand-quantity (make-measure water-m3 "m3")
                  #:current-location place)))

         (procs (list (rp "build-earthworks" "Build water-harvesting earthworks")))

         (flows
          (list (in/u "e-land"  "untreated-land" area-ha "ha" "build-earthworks")
                (in/u "e-water" "seasonal-rainfall" water-m3 "m3" "build-earthworks")
                (wrk "e-work"  hours "build-earthworks")
                (out/u "e-land-out" "treated-land" area-ha "ha" "build-earthworks")
                ;; ── the RESTORE half of the recharge envelope ──────────────
                ;; What the bunds hold does not stay on the surface: the whole
                ;; design intent is that impounded water soaks in. So this is a
                ;; `produce` of `groundwater` — the very spec worlds/doon-shed.scm
                ;; declares a fragility on and calls a "recharge envelope",
                ;; grounded in WRI Aqueduct baseline water stress. A crop that
                ;; irrigates DRAWS it; earthworks RESTORE it, and the two net
                ;; against one barrier (proved in the symmetry test).
                ;;
                ;; Bounded by the rain actually consumed. Recharge does not
                ;; CREATE water, it redirects runoff underground — so the
                ;; infiltrated volume can never exceed what fell on the
                ;; catchment. Without this min a cheap restore process is run
                ;; without limit against a soft barrier; the bound is physical,
                ;; not a cost, which is why it holds however cheap labour gets.
                (out/u "e-recharge" "groundwater"
                       (min (* per-ha area-ha impounded (/ rain-mm 1000.0))
                            water-m3)
                       "m3" "build-earthworks"))))
    (values resources procs flows)))
