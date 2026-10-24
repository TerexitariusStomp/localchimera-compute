;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; profile.scm — what to extract from the irrigation and hydrology literature.
;;;
;;;   node tools/corpus/corpus.mjs probe water --target crop-demand
;;;
;;; Retrieval produces citations, not facts. An empty shelf is a finding.
;;;
;;; WHY THIS DOMAIN MATTERS TWICE OVER. It is a Phase 1 domain in its own right —
;;; the watershed limit localchimera.typ promises — and it is also the missing half of
;;; every food recipe already in the repo. `grow.scm` consumes soil-N/P/K and
;;; states the metabolic-rift question properly for nutrients; water is the same
;;; question and is currently a band rather than a function. FAO 56 is what turns
;;; it into a function.

(profile
  (name "Water → ValueFlows recipes")
  (goal "Turn the water cycle into two things the planner can hold: a per-crop, \
per-stage DEMAND that a grow recipe consumes, and a catchment ENVELOPE that a \
scope draws against — with the yield consequence of falling short stated as a \
relation rather than a guess.")

  (index
    (class "method"
      (description "Named computational methods. Each is a different way of \
turning weather into a demand, with different data requirements — which decides \
whether a bioregion can actually be calibrated from what is pinned.")
      (terms "Penman-Monteith" "reference evapotranspiration" "ETo" "ETc"
             "crop coefficient" "Kc" "dual crop coefficient" "basal crop coefficient"
             "yield response factor" "Ky" "water productivity" "AquaCrop"
             "soil water balance" "readily available water" "depletion fraction"))

    (class "structure"
      (description "The physical works that move a catchment's water in time — \
each a recipe with a construction cost and a storage or infiltration yield.")
      (terms "farm pond" "check dam" "percolation tank" "recharge well"
             "rainwater harvesting" "roof catchment" "swale" "contour bund"
             "infiltration basin" "spring box" "borehole" "qanat" "stepwell"))

    (class "governance"
      (description "The forms a water envelope is held in. A catchment drawn by \
many scopes is the pooled-budget case again, in the domain where it is oldest.")
      (terms "water rights" "riparian rights" "prior appropriation"
             "groundwater district" "water user association" "irrigation scheme"
             "environmental flow" "safe yield" "sustainable yield"
             "stage of groundwater extraction" "abstraction licence")))

  ;; ── The demand side: what a crop actually takes ──────────────────────────
  (target
    (name "crop-demand")
    (construct "recipe-flow consume, per crop per stage")
    (description "ETc = Kc x ETo, per crop and per growth stage. This is the \
water input of a grow recipe stated as a function of climate rather than as a \
seasonal band — the form agroecology-bring-over.md §9.1 asked for.")
    (fields (crop stage kc length-days rooting-depth depletion-fraction))
    (probes
      "single crop coefficient Kc values for initial mid season and late stage"
      "length of crop growth stages in days for staple crops"
      "dual crop coefficient: basal Kcb and evaporation Ke components"
      "maximum rooting depth and soil water depletion fraction by crop"
      "how to adjust Kc for climate, humidity and wind speed"
      "crop water requirement in millimetres per season for cereals and pulses"))

  ;; ── The reference: turning weather into ETo ──────────────────────────────
  (target
    (name "reference-et")
    (construct "derived coefficient from pinned climate data")
    (description "The Penman-Monteith computation itself, and what it needs \
stated. The point is to know which inputs are required, because that decides \
whether a bioregion can be calibrated from the ERA5 fields already pinned in \
knowledge/data/ or needs something further.")
    (fields (input unit source required-or-estimable estimation-method))
    (probes
      "FAO Penman-Monteith equation and its input variables"
      "estimating solar radiation from sunshine hours or temperature range"
      "estimating missing humidity and wind data for the ETo calculation"
      "how to compute ETo from daily maximum and minimum temperature alone"
      "reference surface definition and why grass is the reference"))

  ;; ── The consequence: what falling short does to yield ────────────────────
  (target
    (name "water-stress")
    (construct "scenario multiplier / the Ky relation already used in data/agronomy.scm")
    (description "Yield loss as a function of water deficit. data/agronomy.scm \
already implements the Ky relation, so this target is about CITING it properly \
and extending it stage-wise: the same deficit hurts far more at flowering than \
at ripening, which is the refinement worlds/doon-valley.scm currently carries as \
marked JUDGMENT.")
    (fields (crop stage ky relative-yield-loss deficit-measure))
    (probes
      "yield response factor Ky by crop and growth stage"
      "relative yield decrease as a function of relative evapotranspiration deficit"
      "which growth stage is most sensitive to water shortage"
      "effect of waterlogging and excess water on crop yield"
      "deficit irrigation: yield penalty for applying less than full requirement"))

  ;; ── The envelope: the catchment as a governed level ──────────────────────
  (target
    (name "catchment-envelope")
    (construct "pooled-budget (solve/ingest.scm) over a shed")
    (description "What the catchment yields and what may be drawn without \
lowering it — the watershed specification localchimera.typ promises. Aquifer level is \
the motivating example in pooled-budget's own docstring, so this is the target \
that turns that comment into a citation.")
    (fields (parameter value unit basis timescale reversibility))
    (probes
      "groundwater recharge rate and how it is estimated for a basin"
      "safe yield or sustainable yield of an aquifer"
      "runoff coefficient and how much rainfall becomes streamflow"
      "environmental flow requirement to keep a river alive"
      "stage of groundwater extraction and what over-exploitation means"
      "how long an aquifer takes to recover once drawdown stops")))
