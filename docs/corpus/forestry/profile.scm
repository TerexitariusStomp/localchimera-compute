;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; profile.scm — what to extract from silviculture literature, and how to find it.
;;;
;;; The generic seam (docs/corpus/README.md): tools/corpus/ knows nothing about
;;; forests. This file names the constructs a forestry recipe is made of and the
;;; retrieval probes that surface the passages holding them.
;;;
;;;   node tools/corpus/corpus.mjs probe forestry --target rotation
;;;   node tools/corpus/corpus.mjs probe forestry --out /tmp/forestry-pack.md
;;;
;;; The output is a CITED pack, not an answer. Read the cited span in full before
;;; inscribing, and tag what you inscribe DIRECT / ANCHOR / EXTERNAL. A probe that
;;; returns weak matches reports an EMPTY SHELF — write that down; do not fill it
;;; by inference.
;;;
;;; WHAT THIS DOMAIN IS FOR. Forestry is the long-rotation watchman case: decades
;;; of wall-clock time, a thin sprinkle of human labour, and a yield out of all
;;; proportion to the hours. Phase 0 established that the engine already carries
;;; every piece of that — a duration is not charged as labour (planner.scm:1953),
;;; the stand is a regenerating stock (stocks.scm), and test-forest-recurrence.scm
;;; is green on the regrowth-fed cut outlasting the clearcut. So this profile is
;;; aimed at the NUMBERS those mechanisms are currently standing in for.

(profile
  (name "Silviculture → ValueFlows recipes")
  (goal "Turn silvicultural literature into ResourceSpecifications, \
ProcessSpecifications and RecipeFlows the planner can solve over: what a stand \
yields, over how many years, for how many worker-hours, drawing what — and what \
level of standing timber and carbon it holds while doing it.")

  ;; ── The index: what the corpus is mined for LEADS rather than facts ───────
  ;; Silvics names a practice in passing and dimensions it elsewhere, or not at
  ;; all. Each named system is a thread: a recipe someone has already written
  ;; down properly, in a regional yield table or an extension bulletin.
  (index
    (class "silvicultural-system"
      (description "Named regeneration and tending systems. Each is a distinct \
RECIPE shape — they differ in what is cut, when, and what regenerates it.")
      (terms "clearcut" "seed tree" "shelterwood" "group selection"
             "single-tree selection" "coppice" "coppice with standards"
             "pollarding" "thinning from below" "crown thinning" "sanitation cut"
             "salvage cut" "patch cut" "strip cut" "retention forestry"
             "continuous cover" "close-to-nature" "shade tolerance"))

    (class "agroforestry"
      (description "Systems where the stand shares ground with another yield — \
the cases that couple this domain to the food recipes rather than standing alone.")
      (terms "silvopasture" "alley cropping" "windbreak" "shelterbelt"
             "riparian buffer" "forest farming" "taungya" "nurse crop"))

    (class "product"
      (description "What a rotation actually yields. A recipe whose output is \
'timber' says nothing; these are the specifications a mill or a builder wants.")
      (terms "sawtimber" "pulpwood" "veneer" "pole" "post" "firewood" "chip"
             "biomass" "non-timber forest product" "resin" "bark" "mast"))

    (class "organisation"
      (description "Bodies that publish the regional yield tables and growth \
models this corpus points at but does not contain.")
      (terms "Forest Service" "Forest Products Laboratory" "FVS"
             "Forest Inventory and Analysis" "FIA" "IUFRO" "FAO Forestry")))

  ;; ── The core construct: the rotation as a process with a duration ─────────
  (target
    (name "rotation")
    (construct "recipe-process + recipe-flow, over periods")
    (description "The stand from establishment to harvest: what goes in, when \
the yield arrives, and how many YEARS separate them. The duration is the point — \
Phase 0 established that wall-clock time is carried without being charged as \
labour, so what is missing is the real number of years, not the mechanism.")
    (fields (species system rotation-years yield-per-area site-index entry-schedule inputs))
    (probes
      "rotation length in years for a managed even-aged stand"
      "years from planting to first commercial thinning"
      "mean annual increment and culmination age"
      "site index curves: height at a base age, and what site quality means for yield"
      "yield per acre or hectare at rotation age, in cubic metres or board feet"
      "how many trees per acre to plant, and spacing at establishment"
      "thinning schedule: when to enter a stand and how much basal area to remove"
      "coppice rotation: cutting cycle, sprout survival, and yield per cut"))

  ;; ── Labour: the watchman's residue, which is the claim under test ─────────
  (target
    (name "labour")
    (construct "recipe-flow work / has-duration")
    (description "Worker-hours per unit of forestry work. This target carries \
the whole argument: if the hours per cubic metre over a 40-year rotation are as \
small as the prose claims, the disproportion is measured rather than asserted. \
Prize anything stated per acre, per tree or per cubic metre.")
    (fields (operation hours-per-unit unit crew-size equipment season))
    (probes
      "labour hours or worker days per acre for planting seedlings"
      "person hours per acre for pre-commercial thinning or release"
      "felling and bucking production rates, cubic metres per hour"
      "crew size and daily production for a harvesting operation"
      "time required for stand examination, cruising or marking"
      "labour required for site preparation before planting"))

  ;; ── The stand as a regenerating stock: the level, and its two terms ───────
  (target
    (name "stock-level")
    (construct "regenerating-stock (stocks.scm) + pooled-budget (solve/ingest.scm)")
    (description "Standing volume and carbon as a carried LEVEL, with a draw \
term (the cut) and a restore term (growth). This is what stocks.scm's \
S[t+1] = S[t] − draw + restore needs real coefficients for, and what a \
pooled-budget over a forest many scopes draw on would carry.")
    (fields (parameter value unit species age-class direction-of-change timescale))
    (probes
      "growing stock volume per hectare in a mature stand"
      "annual increment: cubic metres per hectare per year by species and site"
      "carbon stock in above-ground biomass per hectare of forest"
      "carbon stock change factors for forest land remaining forest land"
      "biomass expansion factor and wood density by species"
      "below-ground biomass as a ratio of above-ground"
      "dead organic matter and litter carbon per hectare"
      "how long a stand takes to recover growing stock after harvest"))

  ;; ── The output specification: what the wood IS ────────────────────────────
  (target
    (name "wood-property")
    (construct "resource-specification")
    (description "The properties that make timber a specification rather than a \
word — and the ones a Phase 2 materials pair is decided on, since a natural \
material only substitutes for an industrial one where the properties allow.")
    (fields (species property value unit moisture-condition grade))
    (probes
      "specific gravity and density by species at 12 percent moisture"
      "modulus of elasticity and modulus of rupture for structural lumber"
      "shrinkage: radial, tangential and volumetric, green to oven dry"
      "natural decay resistance and durability of heartwood by species"
      "thermal conductivity and insulating value of wood"
      "equilibrium moisture content and how wood responds to humidity"
      "energy required to dry lumber in a kiln, per thousand board feet"))

  ;; ── What the stand draws and what it needs of its site ───────────────────
  (target
    (name "site-requirement")
    (construct "ecological condition / eco-spec")
    (description "What a species needs of its ground and climate — the \
constraint side of siting a stand, and what a scenario shocks when it changes.")
    (fields (species parameter range unit tolerance))
    (probes
      "soil moisture and drainage requirements by species"
      "frost hardiness and temperature limits for a species"
      "rainfall requirement and drought tolerance of a forest species"
      "nutrient demand and response to fertilisation in forest stands"
      "shade tolerance ranking of species and what it implies for regeneration"
      "rooting depth and windthrow susceptibility"))

  ;; ── Regeneration: the self-reproducing means, in the forest's own form ────
  (target
    (name "regeneration")
    (construct "self-reproducing means (spike S2) / recipe whose output feeds its input")
    (description "Seed production, sprouting and natural regeneration: the stand \
that renews itself. Phase 0's S2 established that the solver handles a recipe \
whose output feeds its own input, provided input-per-output < 1 — so the \
question here is the actual multiplication and survival rates.")
    (fields (species mechanism seed-years seed-per-tree survival-rate stocking))
    (probes
      "seed production: age of first seed bearing and good seed year interval"
      "natural regeneration stocking after harvest, seedlings per acre"
      "sprouting capacity and stump sprout survival by species and age"
      "seedling survival rate after planting in the first years"
      "seed viability, dormancy and stratification requirements"))

  ;; ── The model, read as a text: what a yield RUN must state ───────────────
  (target
    (name "yield-model")
    (construct "data-path entry (research plan §2.3): a vendored FVS deck")
    (description "Not a recipe — the procedure by which a yield table is \
produced. An FVS run enters as raw = pinned deck + FVS version, derived = the \
yield table. Read for what a deck must state so the vendored one is complete \
and re-runnable.")
    (fields (input required-fields cycle-length variant treatment-keywords outputs))
    (probes
      "what stand data FVS needs to start a simulation"
      "FVS cycle length and projection period defaults"
      "how to schedule a thinning or harvest with FVS keywords"
      "FVS variants and how a geographic variant is chosen"
      "what output tables FVS produces and what each column means")))
