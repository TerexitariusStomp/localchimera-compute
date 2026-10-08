;;; eco-catalogue.scm — the federation's fragility catalogue.
;;;
;;; Real planetary-boundary AND climate-tipping-point figures, expressed as fragility profiles and
;;; custodied by the tension-registry (§2.0.8 of the white paper). DRAFT FIGURES: every number here is
;;; transcribed from the cited primary literature, to be RATIFIED at the UC level — the ranges, the
;;; consequence weights, and the precaution dial α are political-economic choices, NOT engineering
;;; constants. The code carries them only so governance has something concrete to amend.
;;;
;;; ── TWO FRAMEWORKS, ONE FRAG ─────────────────────────────────────────────────────────────────────
;;; The catalogue draws on two independently-developed Earth-system frameworks:
;;;
;;;   1. PLANETARY BOUNDARIES (Rockström/Steffen/Richardson, Stockholm Resilience Centre + PIK) — nine
;;;      control variables defining a "safe operating space," each with a (precautionary, human-CHOSEN)
;;;      boundary value and a zone of increasing risk up to a high-risk end. Mostly gradual; several
;;;      RECOVERABLE (cut the flux, the system heals). [*planetary-boundaries*]
;;;
;;;   2. CLIMATE TIPPING POINTS (Lenton/Armstrong McKay, global-tipping-points.org) — specific Earth
;;;      subsystems (ice sheets, AMOC, Amazon …) with a global-warming THRESHOLD (a physical FACT, not
;;;      a setpoint) beyond which they shift state, often self-amplifying and IRREVERSIBLE. [*climate-tipping-points*]
;;;
;;; These are different SCIENCE but the SAME object in our machinery — a fragility profile φ(s)=−w·log s
;;; evaluated on a draw pushed through the coupling graph (space) and the timeline (time). Every
;;; distinction between the two frameworks is a dial the frag already has:
;;;   · range [lo,hi]  — a tip's THRESHOLD UNCERTAINTY  vs  a boundary's designed RISK GRADIENT
;;;   · precaution α   — WHERE in the range the operative tip sits: irreversible tip → α=0 (worst plausible
;;;                      threshold); recoverable boundary → α≈0.5 (central)
;;;   · steepness w    — a sharp bifurcation (large w) vs a gentle boundary gradient (smaller w)
;;;   · time envelope  — recoverable → instantaneous/cumulative; irreversible → ratchet (commitment)
;;;   · coupling graph — a driven state (co2 → warming → element) and tip→tip cascades
;;; So a nitrogen boundary and an ice-sheet collapse are one frag at different settings. See
;;; docs/planning/solve/possibility-tensions-unified.md.
;;;
;;; ── UNITS & FAIR SHARE ───────────────────────────────────────────────────────────────────────────
;;; A profile binds only if the federation's recipes draw on the named spec in the SAME unit as the
;;; threshold. The global commons are NOT federation-controlled: a carbon "budget" here is the
;;; federation's fair SHARE of the global remaining budget; beyond it the federation bears WITNESS.
;;; Several limits are on a DRIVEN STATE the federation does not draw directly (warming °C, aragonite Ω):
;;; these are coupled from the controllable flux (co2) via the cascade, so the published threshold stays
;;; in its native unit and the ONE physical conversion (e.g. TCRE) lives in ONE explicit coupling.
;;;
;;; ── PRECAUTION POLICY (default α) ────────────────────────────────────────────────────────────────
;;; IRREVERSIBLE tipping points place the tip at the LOWER, most-cautious end (α=0). RECOVERABLE
;;; boundaries use the central estimate (α=0.5). For a planetary boundary the published BOUNDARY value
;;; is ALREADY precautionary, so we take [boundary, high-risk] as the range and let α spend the designed
;;; buffer — we do NOT also push α=0 (that would stack two safety margins). α is ratified per agent.

;; ─────────────────────────────────────────────────────────────────────────────────────────────────
;; WITNESS TABLE 1 — NINE PLANETARY BOUNDARIES
;; Source: Richardson, Steffen, Rockström et al. 2023, "Earth beyond six of nine planetary boundaries,"
;; Science Advances 9, eadh2458, Table 1; updates from the PIK Planetary Health Check (2024/2025).
;; Record: (name control-variable boundary risk-upper current unit transgressed? source)
;; ─────────────────────────────────────────────────────────────────────────────────────────────────
(define-module (playnet planner knowledge catalogues eco)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas stocks)
  #:use-module (playnet planner formulas cadence)
  #:use-module (playnet planner knowledge catalogues compiler)   ; catalogue->wire / catalogue->policy — shared with conformance-catalogue.scm
  #:re-export (catalogue->wire catalogue->policy)
  #:export (*planetary-boundaries* *climate-tipping-points* *limit-reversibility*
            limit-reversibility-row reversibility-character reversibility-years
            reversibility-implies *tcre* *warming-now* *planetary-catalogue*
            tipping-character-of
            witnessed-tipping-characters limit-roster roster-of-verdict
            limit-attenuation-rate <migrated-limit> %make-migrated-limit
            migrated-limit? migrated-spec migrated-place migrated-stock migrated-rate
            migrated-weight limit-tip-of migrate-limit migrated-limits migrated-gate
            migrated-proc-id migrated->resources migrated->storables migrated->procs
            migrated->flows migrated->stock-frag migrated->caps
            limit-monitoring-cadence monitored-alpha)
  #:use-module ((playnet utils records) #:select (vf-record-accessor vf-record-constructor vf-record-predicate vf-record-type)))

(cond-expand (guile) (else
  (define (string-contains s pat)          ; the first index of PAT in S, or #f (Hoot has no srfi-13)
    (let ((n (string-length s)) (m (string-length pat)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) pat) i)
              (else (loop (+ i 1)))))))))


;; a type is its name — the same object on both sides of the load seam

(define *planetary-boundaries*
  (list
   '("climate change"            "atmospheric CO2"          350.0   450.0   417.0  "ppm"        #t "Richardson 2023 (2022 value); retained from Rockström 2009 / Steffen 2015")
   '("climate change"            "radiative forcing"          1.0     1.5     2.91 "W/m^2"      #t "Richardson 2023 (2022 value)")
   '("biosphere — genetic"       "extinction rate"           10.0   100.0   100.0  "E/MSY"      #t "Richardson 2023; >100, retained from Steffen 2015")
   '("biosphere — functional"    "HANPP"                     10.0    20.0    30.0  "% Holocene NPP" #t "Richardson 2023 (new metric, replaced BII)")
   '("land-system change"        "forest cover remaining"    75.0    54.0    60.0  "% potential" #t "Richardson 2023; retained from Steffen 2015 (tropical 85/temperate 50/boreal 85)")
   '("freshwater — blue"         "streamflow deviations"     10.2    50.0    18.2  "% land area" #t "Richardson 2023 (new control variable)")
   '("freshwater — green"        "soil-moisture deviations"  11.1    50.0    15.8  "% land area" #t "Richardson 2023 (new control variable)")
   '("biogeochemical — N"        "intentional N fixation"    62.0    82.0   190.0  "Tg N/yr"     #t "Richardson 2023; boundary retained from Steffen 2015")
   '("biogeochemical — P global" "P flow to ocean"           11.0   100.0    22.6  "Tg P/yr"     #t "Richardson 2023; retained from Steffen 2015")
   '("biogeochemical — P regional" "P applied to soils"       6.2    11.2    17.5  "Tg P/yr"     #t "Richardson 2023; retained from Steffen 2015")
   '("ocean acidification"       "aragonite saturation"       2.86    2.86    2.84 "Omega_arag"  #t "PIK Planetary Health Check 2025 (preind base revised 3.57; boundary=80%); newly transgressed. Richardson 2023 had 2.75 / 2.80 (NOT transgressed).")
   '("atmospheric aerosols"      "interhemispheric AOD diff"  0.10    0.25    0.076 "AOD"        #f "Richardson 2023 (new global boundary); regionally exceeded")
   '("stratospheric ozone"       "O3 column"                276.0   261.0   284.6  "DU"         #f "Richardson 2023 (2020 value); only Antarctic spring transgressed")
   '("novel entities"            "untested synthetics released" 0.0    0.0     1.0  "qualitative" #t "Richardson 2023; quantified & declared transgressed")))

;; ─────────────────────────────────────────────────────────────────────────────────────────────────
;; WITNESS TABLE 2 — SIXTEEN CLIMATE TIPPING ELEMENTS
;; Source: Armstrong McKay, Staal, Abrams, Winkelmann, Sakschewski, Loriani, Fetzer, Cornell, Rockström
;; & Lenton 2022, "Exceeding 1.5°C global warming could trigger multiple climate tipping points,"
;; Science 377, eabn7950, Table 1 (also carried into the Global Tipping Points Report 2023).
;; Record: (name abbr min-°C central-°C max-°C timescale-yr character)
;; FIVE elements have a central threshold at or below ~1.5°C — the paper's headline: 1.5°C is not "safe".
;; ─────────────────────────────────────────────────────────────────────────────────────────────────
(define *climate-tipping-points*
  (list
   ;; core (global)
   '("Greenland Ice Sheet"            GrIS 0.8 1.5 3.0 10000 "irreversible/committed; slow")
   '("West Antarctic Ice Sheet"       WAIS 1.0 1.5 3.0  2000 "irreversible; slow; partly committed")
   '("Labrador–Irminger / SPG convection" LABC 1.1 1.8 3.8 10 "abrupt (decadal), hysteresis")
   '("East Antarctic Subglacial Basins" EASB 2.0 3.0 6.0 2000 "irreversible; slow")
   '("Amazon Rainforest dieback"      AMAZ 2.0 3.5 6.0   100 "largely irreversible; century-scale")
   '("Boreal Permafrost collapse"     PFTP 3.0 4.0 6.0    50 "irreversible carbon release ~175–350 GtC")
   '("Atlantic Overturning (AMOC)"    AMOC 1.4 4.0 8.0    50 "abrupt, strong hysteresis; widest range")
   '("Arctic Winter Sea Ice"          AWSI 4.5 6.3 8.7    20 "abrupt; low hysteresis (reversible)")
   '("East Antarctic Ice Sheet"       EAIS 5.0 7.5 10.0 10000 "irreversible; very slow")
   ;; regional (impact)
   '("Low-latitude Coral Reefs"       REEF 1.0 1.5 2.0    10 "fast; abrupt mass mortality")
   '("Boreal Permafrost abrupt thaw"  PFAT 1.0 1.5 2.3   200 "abrupt local thaw feedback")
   '("Barents Sea Ice abrupt loss"    BARI 1.5 1.6 1.7    25 "abrupt; narrowest range")
   '("Mountain Glaciers"              GLCR 1.5 2.0 3.0   200 "largely irreversible (human timescale)")
   '("Sahel / W-African Monsoon"      SAHL 2.0 2.8 3.5    50 "abrupt greening shift")
   '("Boreal Forest (southern dieback)" BORF 1.4 4.0 5.0 100 "gradual dieback")
   '("Boreal Forest (northern expansion)" TUND 1.5 4.0 7.2 100 "gradual northward expansion")))

;; ─────────────────────────────────────────────────────────────────────────────────────────────────
;; WITNESS TABLE 3 — REVERSIBILITY OF THE LIMITS THE PLANNER CONSTRAINS
;;
;; Which of the engine's two forms a limit belongs in — a FRAGILITY whose prior only rises, or a
;; regenerating STOCK whose level can be rebuilt — turns on one physical question: does the control
;; variable come back if the draw stops or reverses, and over what time?
;;
;; That question is NOT answerable from α. This file's own header calls the α values
;; "political-economic choices, NOT engineering constants": α says where in a published range the
;; operative tip stands. Reading it as a physical property conflates the two categories the catalogue
;; separates — and the entries show why. "warming" carries α=0 annotated "irreversible", but what is
;; irreversible are the ELEMENTS crossing 1.5 °C commits us to; warming tracks cumulative CO2.
;; "ocean-acidification" carries α=0 with no reversibility claim recorded at all.
;;
;; So the fact is recorded here, on its own table, cited, and DRAFT — to be ratified at the UC level
;; exactly like the ranges and the weights. Tables 1 and 2 are witness; this is witness too.
;;
;; Record: (spec character recovery-years source note)
;;   character 'reversible              — eases on its own once the draw is cut
;;             'reversible-with-removal — comes back only under ACTIVE removal, i.e. under labour
;;             'slowly-reversible       — returns, but over centuries: beyond any plan's reach
;;             'irreversible            — absorbing on human timescales; no recipe returns it
;;   recovery-years — order of magnitude for a substantial return, once the driver is removed
;; ─────────────────────────────────────────────────────────────────────────────────────────────────
(define *limit-reversibility*
  (list
   '("warming" reversible-with-removal 100
     "IPCC AR6 WG1 SPM D.1.8 + Ch.4/5: the Zero Emissions Commitment is ~0 (MacDougall et al. 2020, Biogeosciences, ZECMIP) — surface temperature STABILISES when emissions cease and declines only under net-negative CO2."
     "Not absorbing, and not free: the return is bought with removal labour, which is what a restoration recipe prices. Sea-level rise and deep-ocean heat, by contrast, are committed for centuries-millennia and belong with the witnessed elements.")
   '("ocean-acidification" reversible-with-removal 100
     "IPCC AR6 WG1 Ch.5 (Box 5.3): SURFACE ocean carbonate chemistry tracks atmospheric CO2 and recovers on centennial timescales under CO2 removal; deep-ocean and sediment carbonate compensation take ~10^4 yr."
     "The constrained variable is surface aragonite Ω, which is the recoverable one. Read as reversible only in that sense.")
   '("nitrogen" reversible 30
     "Richardson et al. 2023 treats N as a per-period RATE boundary — the transgression is the flux, not a stock. Legacy N already in groundwater lags the cut by decades (Van Meter, Basu et al. 2016, Environ. Res. Lett. 11:035014)."
     "Cut the flux and the boundary eases; the lag is the legacy pool draining, not a threshold held open.")
   '("phosphorus" slowly-reversible 200
     "Richardson et al. 2023 (rate boundary). Legacy P in agricultural soils persists for decades to centuries (Sharpley et al. 2013, J. Environ. Qual. 42:1308); P delivered to ocean sediment is lost on geological timescales."
     "The slowest of the four: the flux stops quickly, the soil pool does not. Classed apart from nitrogen deliberately.")))

;; NO cutoff turns `recovery-years` into a category. A slow return is still a return, and its slowness
;; is already expressible where it belongs — in the restore RATE of the stock that carries it, where a
;; plan prices it against everything else and finds restoration barely worth it on its own arithmetic.
;; A threshold here would decide that by fiat instead, and would be a number nobody could source.
;; So `recovery-years` rides as information; only the witnessed character decides the form.

(define (limit-reversibility-row spec) (assoc spec *limit-reversibility*))
(define (reversibility-character spec)
  (let ((r (limit-reversibility-row spec))) (and r (list-ref r 1))))
(define (reversibility-years spec)
  (let ((r (limit-reversibility-row spec))) (and r (list-ref r 2))))
;; the form the science implies, independent of how the limit is currently carried
(define (reversibility-implies spec)
  (let ((c (reversibility-character spec)))
    (cond ((not c) 'unrecorded)
          ((eq? c 'irreversible) 'fragility)   ; nothing returns it — a prior that only rises is honest
          (else 'stock))))                     ; it returns; how fast is the restore rate's business

;; ─────────────────────────────────────────────────────────────────────────────────────────────────
;; THE SOLVER CATALOGUE — fragility AGENTS the planner actually constrains, derived from the witness
;; tables above. Only limits the federation can DRAW in a matched unit enter here; the rest of the two
;; witness tables are governance/witness data (the federation bears witness, cannot yet draw on them).
;;
;;   a fragility agent : (spec kind lo hi alpha w "source")
;;     kind 'budget — a CUMULATIVE limit over the horizon (a stock/budget), summed across periods
;;     kind 'rate   — a PER-PERIOD flux limit, applied at every cell the spec is drawn
;;   a coupling      : (couple k-spec j-spec c "source") — drawing j stresses agent k by c (cascade C)
;; ─────────────────────────────────────────────────────────────────────────────────────────────────
(define *tcre* 0.00045)    ; °C of warming per GtCO2 (IPCC AR6 best estimate 0.45°C/1000 GtCO2; range 0.27–0.63)
(define *warming-now* 1.3) ; observed global warming above preindustrial, ~2024 (IPCC AR6 / WMO)

(define *planetary-catalogue*
  (list
   ;; ── CLIMATE as a driven state: co2 (the controllable flux) → warming (°C) ───────────────────────
   ;;   The federation draws co2 (GtCO2, fair share). Warming is co2 × TCRE — ONE explicit conversion.
   '(couple "warming" "co2" 0.00045
     "TCRE = 0.45°C / 1000 GtCO2 (IPCC AR6 WG1 2021, best estimate; range 0.27–0.63)")
   ;; The tipping-point barrier, in NATIVE °C of REMAINING headroom from current warming (~1.3°C, 2024).
   ;;   FOUR elements sit at central 1.5°C (GrIS, WAIS, REEF, PFAT) and LABC at 1.8 — Armstrong McKay 2022;
   ;;   these five already have their threshold RANGE reaching current warming (~1.1°C in the paper).
   ;;   tip = 1.5°C − 1.3°C now = 0.2°C marginal headroom (→ ~444 GtCO2 at TCRE, consistent w/ IPCC 400–500).
   ;;   hi = 1.7°C − 1.3 = 0.4°C. α=0 (irreversible: assume the cautious end). Highest consequence weight.
   ;;   Elements whose LOW end is already below 1.3°C (GrIS 0.8, WAIS/REEF/PFAT 1.0) are treated as
   ;;   already-COMMITTED — witnessed in *climate-tipping-points*, not a forward solver barrier.
   '("warming" budget 0.2 0.4 0.0 10.0
     "Armstrong McKay et al. 2022 (Science) Table 1 — 1.5°C cluster; remaining headroom from ~1.3°C (2024)"
     "warming" "climate change" "°C headroom")
   ;; ── OCEAN ACIDIFICATION — the SAME co2, a real cascade (replaces the old illustrative coefficient) ─
   ;;   Aragonite Ω fell 3.44→2.80 over ~2400 GtCO2 since preindustrial ⇒ ≈0.00027 Ω/GtCO2. Boundary 2.75,
   ;;   current 2.80 ⇒ ≈0.05 Ω headroom ⇒ ~185 GtCO2 — TIGHTER than warming; the same draw, a second wall.
   '(couple "ocean-acidification" "co2" 0.00027
     "ΔΩarag/Δco2 ≈ (3.44−2.80)/2400 GtCO2 (Richardson 2023 Ω; Friedlingstein GCB cumulative). Order-of-magnitude — calibrate at UC.")
   '("ocean-acidification" budget 0.05 0.69 0.0 8.0
     "Aragonite boundary 2.75 (80% of preind 3.44), current 2.80 ⇒ 0.05 Ω headroom (Richardson 2023 / PIK PHC 2024)"
     "acidification" "ocean acidification" "Ω headroom")
   ;; ── BIOGEOCHEMICAL FLOWS — fluxes the federation draws DIRECTLY (per-period rate boundaries) ──────
   ;;   Recoverable ⇒ α=0.5. Both already far transgressed globally (N 190, P 17.5) — the boundary is the
   ;;   target the federation steers BACK toward, not a ceiling it approaches from below.
   '("nitrogen" rate 62.0 82.0 0.5 5.0
     "Richardson et al. 2023 / Steffen et al. 2015 — boundary 62 (62–82) Tg N/yr; current ~190 (transgressed)"
     "N" "biogeochemical flows" "Tg N/yr")
   '("phosphorus" rate 6.2 11.2 0.5 5.0
     "Richardson et al. 2023 / Steffen et al. 2015 — regional boundary 6.2 (6.2–11.2) Tg P/yr; current ~17.5 (transgressed)"
     "P" "biogeochemical flows" "Tg P/yr")))

;; `catalogue->wire` (the fragility wire the browser's wheel reads) and
;; `catalogue->policy` (a solve's own split into spec-frag/budget/couple) moved
;; to `catalogue.scm` (2026-09-15) — the shared compiler every governed
;; catalogue reads, `conformance-catalogue.scm` included. Re-exported above so
;; nothing importing this module noticed the move.

;; ── THE LIMIT ROSTER — the form each limit is carried in, against the form the
;;    science implies ──────────────────────────────────────────────────────────
;;
;;   FRAGILITY  headroom = tip − *frag-prior*, and the prior only ever rises.
;;              Right where crossing is a commitment.
;;   STOCK      headroom IS a carried level, S[t+1] = S[t] − draw + restore
;;              (stocks.scm). Right where the limit returns, because only here can
;;              restoration labour buy headroom back.
;;
;; Witness table 3 says which each limit IS; this says which each is CARRIED AS.
;; Where they disagree the roster names it, and the verdict is the whole point of
;; keeping the two facts apart: `migrate` is outstanding work, `overstated` is a
;; model that could schedule labour against a physical fact.
;;
;; STOCK? is (lambda (spec) → boolean), passed in so this stays a pure function of
;; the catalogue. Each row: (spec alpha envelope carried-as reversibility
;; implied-form verdict).

;; a witnessed element's character phrase → 'irreversible | 'reversible | 'other
(define (tipping-character-of phrase)
  (cond ((not (string? phrase)) 'other)
        ((string-contains phrase "reversible")
         (if (string-contains phrase "irreversible") 'irreversible 'reversible))
        (else 'other)))

(define (witnessed-tipping-characters)
  (map (lambda (e) (list (car e) (tipping-character-of (list-ref e 6))))
       *climate-tipping-points*))

(define* (limit-roster entries #:optional (stock? (lambda (spec) #f)))
  (filter-map
   (lambda (e)
     (and (pair? e) (not (eq? (car e) 'couple)) (>= (length e) 6)
          (let* ((spec    (car e))
                 (carried (if (stock? spec) 'stock 'fragility))
                 (implied (reversibility-implies spec))
                 (verdict (cond ((eq? implied 'unrecorded)            'unjudged)
                                ((eq? implied carried)                'coherent)
                                ((and (eq? implied 'stock)
                                      (eq? carried 'fragility))       'migrate)
                                (else                                 'overstated))))
            ;; α rides as the governed number it is — bucketing it into a category
            ;; would invent a threshold no one could source, and nothing here needs one.
            (list spec (list-ref e 4) (cadr e) carried
                  (or (reversibility-character spec) 'unrecorded) implied verdict))))
   entries))

(define (roster-of-verdict roster v) (filter (lambda (r) (eq? (list-ref r 6) v)) roster))

;; ── THE MIGRATION: a limit's headroom AS a regenerating stock ─────────────────
;;
;; A fragility says "you have this much left" with a prior that only rises. A
;; stock says the same thing as a LEVEL, and a level can be rebuilt. Migrating
;; costs the drawing side nothing: recipes already `consume` the spec, so the
;; same flows that spent headroom against a barrier now spend it against a stock.
;; What is added is the other direction.
;;
;; The witnessed character does not stay a label a classifier reads — it BECOMES
;; the mechanism, which is the whole reason to record it:
;;
;;   reversible / slowly-reversible  nature returns it. An attenuation process
;;                                   produces headroom at tip/recovery-years per
;;                                   year, rate-capped, for no labour. Nitrogen's
;;                                   legacy pool draining and phosphorus's soil
;;                                   pool are the same process at rates ~7× apart,
;;                                   and neither number is chosen here — both come
;;                                   off witness table 3.
;;   reversible-with-removal         nature returns nothing on this horizon (the
;;                                   Zero Emissions Commitment is ~0: warming
;;                                   STABILISES, it does not fall). No attenuation
;;                                   process exists, so the only way back is a
;;                                   removal recipe someone staffs.
;;   irreversible                    nothing produces it. No stock, and the limit
;;                                   stays a fragility, where a rising prior is
;;                                   the honest shape.
;;
;; What this deliberately does NOT emit is the REMOVAL recipe. Its labour cost is
;; a technology fact a scope knows about its own capture plant or its own effluent
;; works — not something a planetary catalogue can assert for everyone. So removal
;; enters as ordinary scope data, priced like any other recipe, exactly as the
;; reef's restoration does in restoration-recipe-test. The catalogue supplies the
;; stock and nature's share; the federation supplies its own hands.

(define (limit-attenuation-rate spec tip period-years)
  "Headroom nature returns per period, from witness table 3. #f where it returns
   none — a statement about the physics, not a rate that happens to be zero."
  (let ((c (reversibility-character spec)) (y (reversibility-years spec)))
    (and (memq c '(reversible slowly-reversible)) y (> y 0)
         (* tip (/ period-years y)))))

;; ONE migrated limit. Everything else about it is derivable from these four, so
;; the projections below build the records a solve wants without threading state.
(define <migrated-limit>
  (vf-record-type 'MigratedLimit
    '((immutable spec) (immutable place) (immutable stock) (immutable rate)
      (immutable weight))))   ; the profile's governance w — carried so the level's
                              ; ≥0 balance stays FELT AT THE OPTIMUM rather than
                              ; silently reverting to the swept bar every good has
(define %make-migrated-limit (vf-record-constructor <migrated-limit>))
(define migrated-limit?  (vf-record-predicate <migrated-limit>))
(define migrated-spec    (vf-record-accessor <migrated-limit> 'spec))
(define migrated-place   (vf-record-accessor <migrated-limit> 'place))
(define migrated-stock   (vf-record-accessor <migrated-limit> 'stock))
(define migrated-rate    (vf-record-accessor <migrated-limit> 'rate))   ; #f ⇒ removal only
(define migrated-weight  (vf-record-accessor <migrated-limit> 'weight))

(define (limit-tip-of entry)
  (+ (list-ref entry 2) (* (list-ref entry 4) (- (list-ref entry 3) (list-ref entry 2)))))

;; one catalogue entry → its migration, or #f where the limit does not return and
;; so stays a fragility. This is the whole of the decision; the rest is projection.
(define* (migrate-limit entry #:key (place "earth") (period-years 1.0) (headroom-of #f))
  (and (pair? entry) (not (eq? (car entry) 'couple)) (>= (length entry) 6)
       (let ((spec (car entry)) (tip (limit-tip-of entry)))
         (and (eq? 'stock (reversibility-implies spec))
              (%make-migrated-limit
               spec place
               (make-regenerating-stock
                spec (string-append spec " headroom") place
                (if headroom-of (headroom-of spec tip) tip)
                (if (>= (length entry) 10) (list-ref entry 9) "unit"))
               (limit-attenuation-rate spec tip period-years)
               (list-ref entry 5))))))

(define* (migrated-limits entries #:key (place "earth") (period-years 1.0) (headroom-of #f))
  (filter-map (lambda (e) (migrate-limit e #:place place #:period-years period-years
                                         #:headroom-of headroom-of))
              entries))

;; ── projections: the records a solve wants, each a plain map over the above ───
;; Nature's return is a RATE, so its process draws a per-period gate good: one run
;; per period, and the return cannot be spent forward as a budget.
(define (migrated-gate m) (string-append "attenuation~" (migrated-spec m)))
(define (migrated-proc-id m) (string-append "attenuate~" (migrated-spec m)))

(define (migrated->resources ms) (map (lambda (m) (regenerating-stock->resource (migrated-stock m))) ms))
(define (migrated->storables ms) (map migrated-spec ms))
(define (migrated->procs ms)
  (filter-map (lambda (m)
                (and (migrated-rate m)
                     (make-recipe-process #:id (migrated-proc-id m)
                                          #:name (string-append "attenuation of " (migrated-spec m)))))
              ms))
(define (migrated->flows ms)
  (append-map
   (lambda (m)
     (if (not (migrated-rate m)) '()
         (let ((pid (migrated-proc-id m)))
           (list (stock-restore-flow (string-append pid ">") (migrated-spec m) (migrated-rate m) pid
                                     "nature's own return, per witness table 3")
                 (make-recipe-flow #:id (string-append pid "<") #:action 'consume #:resource-conforms-to (migrated-gate m)
                                   #:resource-quantity (make-measure 1.0 "unit") #:recipe-input-of pid)))))
   ms))
;; the governance weight each level's balance is felt at — plan-from-records
;; #:stock-frag. Without it a migrated limit would be ridden to its edge.
(define (migrated->stock-frag ms)
  (map (lambda (m) (cons (migrated-spec m) (migrated-weight m))) ms))

(define (migrated->caps ms periods)
  (append-map
   (lambda (m)
     (if (not (migrated-rate m)) '()
         (map (lambda (t) (cons (string-append (migrated-gate m) "#" (migrated-place m)
                                               "@" (number->string t)) 1.0))
              periods)))
   ms))

;; ── MONITORING: survey labour narrows a boundary, and buys α back off the floor ──
;;
;; `formulas/cadence.scm` already derives a recert cadence from the load a plan
;; routes through a skill edge — edge-reliance(throughput, harm) → a* → a recert
;; interval. Nothing there is skill-specific: LOADS is `((edge . hours) …)`, read
;; off a live solve. An ecological boundary's DRAW is the same shape as a skill's
;; hours, so `conformance-recert-schedule` derives a SURVEY cadence for a limit
;; with no new machinery — a second adapter over the fold that already exists,
;; the same move `mean-shocks` makes for forecast vs Observer calibration.
;;
;; What is genuinely new is the other direction: today α is a static governance
;; choice (eco-catalogue.scm's own words: "political-economic choices, NOT
;; engineering constants"). A federation that SURVEYS a boundary — spends the
;; labour a* prices — has bought down its uncertainty about where s_tip sits, and
;; the [lo,hi] range is precisely that uncertainty. So the survey cadence should
;; be able to move α off the precautionary floor, never past central (0.5): a
;; federation earns confidence, it does not spend its way to recklessness.
;;
;; monitored-alpha reads the SAME a* this limit's recert cadence already produces
;; and derives a confidence-adjusted α: 0 (never surveyed) rising toward 0.5 as a*
;; approaches 1 (surveyed every period — the shortest interval the plan will pay
;; for). Nothing here changes the CATALOGUE'S α — the governed one stays the
;; precautionary default; monitored-alpha is what a caller may use in ITS PLACE
;; once real survey labour is committed, and it degrades to the catalogue's own
;; floor the moment surveying stops.

(define* (limit-monitoring-cadence draw-by-spec #:key (now 0) (period-span 1.0)
                                          (ell 1.0) (kappa 1.0) (lam 1.0))
  "The survey cadence for each limit in DRAW-BY-SPEC = ((spec . draw) …), read off a
   live solve exactly as conformance-recert-schedule reads skill loads — the same
   fold, a different edge. Each limit's own governance weight w is its HARM (a
   heavily-weighted boundary is a costlier miss, so it earns more frequent survey
   at the same draw). Returns ((spec . valid-until) …), #f where reliance never
   clears the inspection floor (a barely-drawn boundary is not worth surveying)."
  (append-map
   (lambda (kv)
     (let* ((spec (car kv)) (draw (cdr kv))
            (e (find (lambda (e) (and (pair? e) (not (eq? (car e) 'couple))
                                      (equal? (car e) spec) (>= (length e) 6)))
                     *planetary-catalogue*)))
       (if (not e) '()
           (list (cons spec (reliance->valid-until (edge-reliance draw (list-ref e 5))
                                                    ell kappa now period-span lam))))))
   draw-by-spec))

(define* (monitored-alpha spec draw #:key (now 0) (period-span 1.0)
                                 (ell 1.0) (kappa 1.0) (lam 1.0))
  "α for SPEC once survey labour is committed at DRAW — the catalogue's own
   precaution floor when unsurveyed, rising toward central (0.5) as the plan's
   inspection intensity a* on this boundary approaches 1 (surveyed every period).
   Never exceeds 0.5 and never lowers a caller's own α; it only says how far a
   federation may move FROM the floor for what it has actually paid to know."
  (let* ((e (find (lambda (e) (and (pair? e) (not (eq? (car e) 'couple))
                                   (equal? (car e) spec) (>= (length e) 6)))
                  *planetary-catalogue*))
         (floor-alpha (if e (list-ref e 4) 0.0))
         (harm        (if e (list-ref e 5) 1.0))
         (a*          (inspection-intensity (edge-reliance draw harm) ell kappa lam)))
    (+ floor-alpha (* a* (- 0.5 floor-alpha)))))
