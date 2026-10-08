;;; profile.scm — what to extract from permaculture literature, and how to find it.
;;;
;;; THIS FILE IS THE GENERIC SEAM. `tools/corpus/` knows nothing about
;;; agronomy: it converts, chunks, embeds and retrieves. A profile is what
;;; points that machinery at a particular branch of knowledge — it names the
;;; constructs worth extracting, and gives the retrieval probes that surface
;;; the passages holding them.
;;;
;;; To bring over a different literature (pharmacology, metallurgy, care work,
;;; municipal law), write a sibling directory with its own manifest.scm and a
;;; profile.scm naming ITS constructs. No code changes.
;;;
;;;   node tools/corpus/corpus.mjs probe permaculture --target earthwork
;;;   node tools/corpus/corpus.mjs probe permaculture --out /tmp/pack.md
;;;
;;; The output is a CITED retrieval pack, not an answer. Every passage carries
;;; `source:Lstart-Lend` against texts/<slug>/text.md. Read the cited range
;;; before inscribing anything — the same discipline
;;; docs/planning/food/agroecology-bring-over.md was written under, where each claim
;;; is tagged DIRECT (concrete enough to inscribe), ANCHOR (real but
;;; single-site, calibrate first) or EXTERNAL (the text does not give it).

(profile
  (name "Permaculture → ValueFlows recipes")
  (goal "Turn design literature into ResourceSpecifications, ProcessSpecifications \
and RecipeFlows the planner can actually solve over — inputs, outputs, rates, \
durations, and the ecological conditions each process draws on or rebuilds.")

  ;; ── The index: what this corpus is mined for LEADS rather than facts ────
  ;; Some sources earn their place by telling you what EXISTS. Field
  ;; documentaries name a technique and a project without ever dimensioning
  ;; either — and each name is a thread to pull in the primary literature, where
  ;; the buildable numbers live. `corpus leads permaculture` reports which of
  ;; these the corpus mentions, how often, and where to hear it said.
  ;;
  ;; So the video corpus is a DISCOVERY layer, not a data layer. A fact found
  ;; this way cites the manual it was sourced from and records the video only as
  ;; how it was found.
  (index
    (class "technique"
      (description "Named land-shaping and water-harvesting practices. Each one \
is a recipe someone has already written down properly, somewhere.")
      (terms "zai" "half-moon" "demi-lune" "taanka" "johad" "khadin" "keyline"
             "chinampa" "swale" "check dam" "contour trench" "contour bund"
             "gabion" "percolation tank" "stepwell" "qanat" "terrace"
             "food forest" "hugelkultur" "greywater" "silt trap" "farm pond"))

    (class "project"
      (description "Named programmes with published evaluations, budgets and \
areas — the grey literature that carries real per-hectare costs and outcomes.")
      (terms "Great Green Wall" "Paani Foundation" "Water Cup" "Cauvery Calling"
             "World Food Programme" "Sadhana Forest" "Auroville" "Camp Altiplano"
             "Wadi Hanifah" "Loess Plateau" "Tigray"))

    (class "organisation"
      (description "Bodies that publish the manuals. An organisation named in \
passing is often the publisher of the specification the corpus itself lacks.")
      (terms "ICRAF" "ICRISAT" "CGIAR" "FAO" "Gravis" "Tarun Bharat Sangh"
             "Barefoot College" "Practical Action" "IWMI")))

  ;; ── The core construct: a process with quantified inputs and outputs ─────
  (target
    (name "process-recipe")
    (construct "recipe-process + recipe-flow")
    (description "A transformation with named inputs, named outputs, and a rate. \
This is the unit the planner solves over; everything else here supports it.")
    (fields (name inputs outputs rate duration labour-hours season scale))
    (probes
      "step by step method for making compost, with quantities and turning schedule"
      "how to build a hugelkultur bed: materials, dimensions, and how long it lasts"
      "seed ball preparation: clay, compost, seed proportions"
      "making biochar in a pit or kiln, feedstock and yield"
      "chop and drop mulching: how much biomass per area per year"
      "sheet mulching layers, cardboard, depth of materials needed"
      "vermicomposting: worm stocking rate, feedstock per week, castings yield"
      "liquid fertilizer from comfrey or nettle: ratio, steeping time, dilution"))

  ;; ── Earthworks: the dimensioned water-shaping structures ─────────────────
  (target
    (name "earthwork")
    (construct "process-specification + spatial resource")
    (description "Water-harvesting and land-shaping structures. Prize the ones \
carrying real dimensions — spacing, depth, slope, catchment area — since a \
dimensioned earthwork becomes a recipe and an undimensioned one stays prose.")
    (fields (name dimensions slope-range spacing catchment-area soil-moved labour rainfall-range))
    (probes
      "swale dimensions: width, depth, spacing on contour for a given slope"
      "how to size a pond or tank from catchment area and annual rainfall"
      "keyline plowing pattern and depth, ridge and valley cultivation"
      "terrace construction on steep slopes, riser height and bed width"
      "check dam and gabion sizing in an ephemeral gully"
      "roof catchment: how many litres per square metre per millimetre of rain"
      "greywater branched drain system layout and sizing"
      "infiltration basin depth and drawdown time"))

  ;; ── Species, yields and the production function ──────────────────────────
  (target
    (name "yield-function")
    (construct "resource-specification + recipe-flow rate")
    (description "Land + labour + water + nutrients → yield. The gap \
agroecology-bring-over.md marked EXTERNAL. Anything with an actual number per \
unit area is worth more here than a paragraph of principle.")
    (fields (crop yield-per-area water-requirement nutrient-demand spacing time-to-harvest inputs))
    (probes
      "crop yield per hectare under organic or agroecological management"
      "water requirement in millimetres per season for staple crops"
      "tree crop yield per mature tree per year, nuts or fruit"
      "plant spacing and density per hectare for orchard or food forest"
      "years from planting to first harvest for perennial crops"
      "nitrogen fixed per hectare per year by legumes or nitrogen fixing trees"
      "labour days per hectare required for smallholder crop production"))

  ;; ── Ecological conditions: what a process draws down or rebuilds ─────────
  (target
    (name "eco-parameter")
    (construct "ecological condition / fragility parameter")
    (description "Coefficients for conditions carried through time as stocks — \
soil organic carbon, water table, biodiversity. Feeds the regenerating-stock \
recurrence and the fragility barrier, where placeholder coefficients currently \
stand in for measured ones.")
    (fields (parameter value unit context direction-of-change timescale))
    (probes
      "rate of topsoil formation in millimetres or tonnes per hectare per year"
      "soil organic matter increase under mulching, cover crops or compost"
      "how much water soil holds per percent of organic matter"
      "carbon sequestration rate per hectare per year in agroforestry"
      "erosion rate under bare soil versus covered soil"
      "groundwater recharge from water harvesting structures"
      "soil formation by earthworms, casting weight per acre per year"))

  ;; ── Relations between species: the polyculture graph ─────────────────────
  (target
    (name "guild-relation")
    (construct "folksonomy structure-edge / companion relation")
    (description "Which species support which, and how. These are EDGES, not \
quantities — they belong in the folksonomy graph rather than in a flow, and \
they are what makes a polyculture more than a list of plants.")
    (fields (subject relation object mechanism evidence-strength))
    (probes
      "companion planting: which plants benefit which and why"
      "nitrogen fixing support species in a food forest guild"
      "dynamic accumulator plants that mine minerals from the subsoil"
      "insectary plants that host predators of crop pests"
      "trap crops and push pull pest management pairings"
      "nurse trees and windbreak species for establishing an orchard"
      "allelopathy: plants that suppress the growth of others"))

  ;; ── Nutrition: the reproduction floor ───────────────────────────────────
  (target
    (name "nutrition")
    (construct "*food-nutrition* / contains relation")
    (description "Food → nutrient content, and what a person needs. Feeds the \
reproduction floors the robust planner defends in every scenario.")
    (fields (food nutrient amount per-unit population-need))
    (probes
      "nutritional content per hundred grams of staple grains and pulses"
      "daily calorie and protein requirement per person"
      "how much land is needed to feed one person per year"
      "nutrition produced per acre comparison between cropping systems"))

  ;; ── Design method: not a recipe, but how recipes get chosen ─────────────
  (target
    (name "design-method")
    (construct "planning procedure / scope assessment")
    (description "Zones, sectors, site assessment, observation protocols. Not \
directly solvable, but it is the procedure by which a bounded scope gets \
inscribed in the first place — the W1 step, described by people who do it.")
    (fields (step inputs outputs when-in-process))
    (probes
      "zone and sector analysis: how to place elements by frequency of visit"
      "site assessment checklist: what to observe and measure before designing"
      "reading the landscape: slope, aspect, water flow, microclimate"
      "how to map sectors of sun, wind, fire and water on a site")))
