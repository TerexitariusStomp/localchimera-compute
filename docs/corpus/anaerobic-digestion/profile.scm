;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; profile.scm — what to extract from the anaerobic-digestion literature.
;;;
;;;   node tools/corpus/corpus.mjs probe anaerobic-digestion --target yield
;;;
;;; Retrieval produces citations, not facts. An empty shelf is a finding.
;;;
;;; WHY THIS DOMAIN IS SHAPED LIKE THIS. Digestion is the plan's cleanest
;;; instance of cultivated metabolism: substrate in, organisms work for weeks in
;;; the dark, two products out, human labour reduced to loading and watching.
;;; Phase 0 established that the engine already carries that shape — a duration
;;; is not charged as labour (planner.scm:1953), so a 30-day retention time with
;;; two hours of tending compiles as two hours. What is missing is the biology:
;;; how much gas a given feedstock yields, over how long, at what temperature.
;;;
;;; The domain also has to answer a question the others do not: this recipe has
;;; TWO products, and how their value is apportioned decides whether digestate
;;; reads as a co-product or as a waste stream that happens to be useful.

(profile
  (name "Anaerobic digestion → ValueFlows recipes")
  (goal "Turn digestion into a recipe with two outputs and a wall-clock \
duration: substrate and thin labour in; biogas and digestate out; retention \
time, temperature and loading rate as the conditions the process must be held \
inside — and the nutrient content of the digestate stated well enough that a \
grow recipe can consume it.")

  (index
    (class "digester-type"
      (description "Named designs. Each is a different capital cost and a \
different labour profile, which is exactly what distinguishes recipes here.")
      (terms "covered lagoon" "complete mix" "plug flow" "fixed dome"
             "floating drum" "tubular" "CSTR" "UASB" "dry digestion"
             "batch digester" "two stage"))

    (class "feedstock"
      (description "What goes in. Yield varies by an order of magnitude across \
these, so the feedstock is half the recipe.")
      (terms "cattle manure" "pig slurry" "poultry litter" "food waste"
             "energy crop" "silage" "crop residue" "sewage sludge"
             "abattoir waste" "co-digestion" "FOG" "grease trap waste"))

    (class "product"
      (description "What comes out, and what it becomes. Digestate has two \
fractions with different fates, and the split matters to any recipe consuming it.")
      (terms "biogas" "biomethane" "upgrading" "digestate" "liquid fraction"
             "solid fraction" "struvite" "ammonium sulphate" "combined heat and power")))

  ;; ── The yield: how much gas per unit of feedstock ────────────────────────
  (target
    (name "yield")
    (construct "recipe-flow produce, per unit of substrate")
    (description "Methane and biogas yield per tonne of feedstock, or per \
kilogram of volatile solids. IPCC Ch. 10's Bo (maximum methane producing \
capacity) and volatile-solids excretion are the parameterised form of this; the \
EPA guidebook gives operating reality. Prize anything per kg VS.")
    (fields (feedstock parameter value unit temperature-regime basis))
    (probes
      "biogas yield per tonne of feedstock by substrate type"
      "maximum methane producing capacity Bo for manure by animal type"
      "volatile solids excreted per animal per day"
      "methane content of biogas as a percentage"
      "specific methane yield per kilogram of volatile solids added"
      "energy content of biogas in megajoules per cubic metre"))

  ;; ── The conditions: what the metabolism must be held inside ──────────────
  (target
    (name "process-condition")
    (construct "process-specification: the envelope the recipe runs within")
    (description "Retention time, temperature, loading rate, pH, C:N ratio. \
These are the ecological specification of a cultivated metabolism — the \
conditions verified rather than the quantities produced.")
    (fields (parameter range unit regime consequence-if-exceeded))
    (probes
      "hydraulic retention time for mesophilic and thermophilic digestion"
      "organic loading rate in kilograms of volatile solids per cubic metre per day"
      "operating temperature ranges for mesophilic and thermophilic digesters"
      "carbon to nitrogen ratio required for stable digestion"
      "pH range and what causes acidification or ammonia inhibition"
      "start up period and how a digester is brought to stable operation"))

  ;; ── The labour: the watchman's residue, tested again ─────────────────────
  (target
    (name "labour")
    (construct "recipe-flow work")
    (description "Hours to load, monitor and maintain, against weeks of \
unattended metabolism. CHECKED 2026-08-10 AND EMPTY: the EPA guidebook says what \
to inspect and how often to inspect it, and never how long any of it takes. No \
figure in hours per day or per week appears anywhere in the domain. Labour here \
is EXTERNAL until an operations or farm-budget source is added — see the research \
plan's labour rule, which this domain is the second instance of.")
    (fields (operation hours frequency scale equipment))
    (probes
      "daily operator time required to run a farm digester"
      "labour for feeding and mixing a small scale biogas plant"
      "maintenance schedule and hours for digester and gas equipment"
      "how much attention an operating digester needs per week"))

  ;; ── The second product: digestate as an input to growing ─────────────────
  (target
    (name "digestate")
    (construct "recipe-flow produce → consumed by a grow recipe")
    (description "The loop-closing output. Nutrient content and availability \
decide whether digestate can substitute for a fertiliser input in grow.scm, and \
whether it feeds the same soil-N/P/K specs that recipe already consumes.")
    (fields (fraction nutrient content unit availability application-rate))
    (probes
      "nutrient content of digestate: nitrogen phosphorus and potassium"
      "ammonium nitrogen as a fraction of total nitrogen in digestate"
      "digestate application rate per hectare and nutrient availability to crops"
      "separation of digestate into liquid and solid fractions"
      "how digestion changes the nutrient value compared with raw manure"))

  ;; ── The pair: same feedstock, composted or digested ──────────────────────
  (target
    (name "paired-route")
    (construct "two recipes producing overlapping specs (research plan Phase 2)")
    (description "IPCC Vol. 5 Ch. 4 treats composting and digestion as two \
treatments of one waste stream, which is a paired route in the plan's sense. \
humisoil.scm already holds the composting side, so what is wanted is what \
differs: the products, the time, and the labour.")
    (fields (treatment feedstock products duration labour emissions))
    (probes
      "composting compared with anaerobic digestion for the same waste"
      "emission factors for composting and for anaerobic digestion facilities"
      "mass balance of a biological treatment: inputs to outputs"
      "what fraction of feedstock carbon leaves as gas versus stays in the residue")))
