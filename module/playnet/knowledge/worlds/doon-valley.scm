;;; worlds/doon-valley.scm — a real bioregion's climate scenarios + crop yields, for
;;; robust multi-scenario planning (docs/planning/solve/robust-multiscenario.md).
;;;
;;; Bioregion: Doon Valley / Dehradun district, Uttarakhand, India — the Navdanya
;;; farm region (docs/planning/food/agroecology-bring-over.md §1). Subtropical, SW-
;;; monsoon-fed, high interannual rainfall variability + frequent flash floods.
;;;
;;; Loaded after planner.scm (needs schemas' make-planning-scenario). Provides:
;;;   *doon-valley-crop-yields*  — normal-year baseline yield (kg/ha) per crop.
;;;   *doon-valley-scenarios*    — <planning-scenario> list (normal/drought/flood).
;;;
;;; ── PROVENANCE ────────────────────────────────────────────────────────────────
;;; [DATA] Scenario probabilities — the Doon Valley's OWN monsoon record, derived
;;;   reproducibly in data/ : Dehradun JJAS (June–Sep) rainfall 1960–2023 (ERA5 via
;;;   Open-Meteo, mean 1240 mm σ 352 mm), classified ±1σ (the IMD method, applied
;;;   locally): drought 9/64 = 0.14, normal 43/64 = 0.67, excess/flood 12/64 = 0.19.
;;;   More floods than the all-India average (0.13) — the flash-flood-prone
;;;   foothills. Re-derive (any bioregion): sh data/fetch.sh LAT LON LABEL && guile data/process.scm raw/LABEL/precip.json 6,7,8,9 (data/sources.md).
;;; [DATA] Baseline yields (kg/ha) — Uttarakhand state averages: rice 2,710
;;;   (2025), wheat 3,244 (2024), pulses 992 (2023); finger millet ~1,747
;;;   (national avg productivity). (CEIC / ICAR / Indiastat.)
;;; [DERIVED + refined] Per-scenario yield MULTIPLIERS. These are now GROUNDED, not
;;;   guessed: data/process-multipliers.scm derives them reproducibly from THIS
;;;   bioregion's rainfall scenarios (drought 783 / normal 1175 / flood 1812 mm) via
;;;   FAO Irrigation & Drainage Paper 33 — relative yield loss = Ky·(1−ETa/ETm), the
;;;   water deficit driving loss through each crop's Ky (rice 1.20, maize 1.25, ragi
;;;   0.90, pulses 0.90) + a waterlogging penalty. That deriver alone gives, e.g.,
;;;   drought rice 0.60 / maize 0.58 / ragi 0.70 / pulses 0.70. The live values below
;;;   keep that shape but REFINE it with crop-STAGE physiology the seasonal Ky model
;;;   misses — rainfed rice's reproductive-stage crash (60%+ loss) deepens its drought
;;;   figure, pulses' waterlogging deepens its flood figure. Both tiers agree on the
;;;   point: NO crop wins in all three futures — drought punishes rice, flood punishes
;;;   pulses — so a floor-holding plan must SPAN them. Re-derive anywhere: python3
;;;   data/process-multipliers.scm raw/<label>/precip.json <crops>. GAEZ water-limited
;;;   ratios remain the further refinement (agroecology-bring-over.md §9.3).
;;;
;;; Sources (full provenance + checksums: data/sources.md):
;;;   Local monsoon record — ERA5 via Open-Meteo Archive API (CC-BY 4.0), pinned
;;;     query + vendored raw + sha256 in data/ ; derived by data/process.scm.
;;;   Uttarakhand yields  — CEIC / Indiastat / ICAR Uttarakhand [still ESTIMATE-tier: portal, not a pinned API]
;;;   Drought sensitivity — finger-millet & rainfed-rice drought-tolerance literature (see agroecology-bring-over §9.1)

;; The MECHANICAL layer — scenario PROBABILITIES, the Ky-multiplier baseline, and
;; national yields — is GENERATED from the vendored raw (data/emit-derived.scm) into
;; worlds/doon-derived.scm and loaded here, so the numbers below that ARE pure data cannot
;; drift from the record. What stays hand-authored is JUDGMENT, marked as such.
;; `make verify-derived` re-runs the generator and diffs, failing CI on any drift.
(define-module (playnet knowledge worlds doon-valley)
  #:use-module (playnet knowledge worlds bioregions)
  #:use-module (srfi srfi-1)
  ;; The generated table this file reads. Re-exported because every caller that
  ;; loaded worlds/doon-valley.scm got the derived names along with it — the file exists
  ;; to present that table as scenarios, and the two have always been one surface.
  #:use-module (playnet knowledge worlds doon-derived)
  #:re-export (*doon-derived-season* *doon-derived-warm-quarter-degc*
               *doon-derived-annual-mean-degc* *doon-derived-scenario-probs*
               *doon-derived-scenario-rain* *doon-derived-ky-multipliers*
               *doon-derived-yields*)
  #:export (doon-prob *doon-valley-crop-yields* *doon-valley-scenarios/tail-robust*
            *doon-valley-scenarios* *doon-valley-stress-scenario*)
  #:use-module (playnet knowledge worlds doon-derived))

(define (doon-prob k) (assoc-ref *doon-derived-scenario-probs* k))   ; probability from the record

;; Kharif (monsoon-season) crops — the ones a monsoon scenario actually moves.
;; (Rabi wheat is a separate, largely-irrigated season; kept for reference.)
(define *doon-valley-crop-yields*      ; kg/ha, normal year [DATA]
  '(("rice"   . 2710.0)
    ("maize"  . 2500.0)
    ("ragi"   . 1747.0)      ; finger millet
    ("pulses" .  992.0)
    ("wheat"  . 3244.0)))    ; rabi — reference

;; Per-scenario yield MULTIPLIERS keyed by crop (× the normal baseline). A grow
;; recipe named for its crop (proc-id = crop) has its produced quantity scaled by
;; the matching factor. Unlisted crop ⇒ 1.0. PROBABILITIES come straight from the
;; record (doon-prob → worlds/doon-derived.scm). The multipliers are the FAO-Ky baseline
;; (*doon-derived-ky-multipliers*: drought rice 0.60 / ragi 0.70) REFINED here with
;; crop-STAGE physiology the seasonal model misses — rice's reproductive-stage crash
;; deepens its drought figure to 0.45, pulses' waterlogging its flood figure. [JUDGMENT]
;; The two scenario sets, assembled by the shared bioregion assembler (bioregions.scm):
;; three historical futures + a p=0 precautionary TAIL. The TAIL is Taleb precaution, NOT
;; from the record — the 64-yr ERA5 undersamples it and ±1σ assumes thin tails monsoon
;; rainfall lacks; starvation is RUIN, so we do NOT forecast its probability (0.0 by
;; construction — nothing to the surplus objective) but the floor is defended in it too.
(define *doon-valley-scenarios/tail-robust*
  (assemble-scenarios "doon"
    (list (list "normal"  (doon-prob "normal")  '(("rice" . 1.0)  ("maize" . 1.0)  ("ragi" . 1.0)  ("pulses" . 1.0)  ("wheat" . 1.0))
                "Normal SW monsoon (~96–104% LPA). Baseline yields.")
          (list "drought" (doon-prob "drought") '(("rice" . 0.45) ("maize" . 0.55) ("ragi" . 0.82) ("pulses" . 0.80) ("wheat" . 0.70))
                "Deficient monsoon / meteorological drought (<75% LPA). Rice crashes; millet/pulses hold.")
          (list "flood"   (doon-prob "flood")   '(("rice" . 1.05) ("maize" . 0.85) ("ragi" . 0.95) ("pulses" . 0.80) ("wheat" . 0.90))
                "Excess monsoon / flash-flood year (>104% LPA). Rice ok; pulses waterlogged."))
    (list '(("rice" . 0.15) ("maize" . 0.25) ("ragi" . 0.50) ("pulses" . 0.45) ("wheat" . 0.55))
          "TAIL: famine-scale monsoon collapse, beyond the instrumental record. p=0 (not a forecast); floor defended regardless.")))
(define *doon-valley-scenarios*       (drop-right *doon-valley-scenarios/tail-robust* 1))  ; bets on the record
(define *doon-valley-stress-scenario* (last *doon-valley-scenarios/tail-robust*))          ; the p=0 tail
