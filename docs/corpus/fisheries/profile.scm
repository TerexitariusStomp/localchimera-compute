;;; profile.scm — what to extract from stock-assessment literature.
;;;
;;;   node tools/corpus/corpus.mjs probe fisheries --target envelope
;;;
;;; Retrieval produces citations, not facts. Read the cited span before
;;; inscribing; tag DIRECT / ANCHOR / EXTERNAL; an empty shelf is a finding.
;;;
;;; WHAT MAKES THIS DOMAIN DIFFERENT. Every other domain here has a production
;;; process with inputs. Wild capture has almost none: the fish are made by the
;;; sea, and the human contribution is the taking. So the recipe is thin and the
;;; ENVELOPE is everything — which is precisely why it is the limit case of the
;;; plan's argument, and why the `labour` target is small and the `envelope`
;;; target is large.
;;;
;;; Phase 0 established that the mechanism exists: `pooled-budget` carries the
;;; envelope of an agent many scopes draw on as a measured LEVEL, with 'carry
;;; semantics so a stock spent forward is rebuilt forward and never borrowed
;;; backward. What is missing is the biology that sets the level and its
;;; regeneration rate.

(profile
  (name "Fisheries → ValueFlows recipes")
  (goal "Turn stock-assessment method into a governed envelope the planner can \
solve under: the level a fishery stands at, the rate it comes back, what may be \
drawn without lowering it, and the effort a draw actually costs.")

  (index
    (class "assessment-model"
      (description "Named models. Each implies a different envelope shape, and \
therefore a different fragility or stock declaration.")
      (terms "surplus production" "Schaefer" "Fox" "yield per recruit"
             "Beverton-Holt" "Ricker" "virtual population analysis" "VPA"
             "cohort analysis" "length frequency" "von Bertalanffy"
             "maximum sustainable yield" "MSY" "spawning stock biomass"
             "biological reference point" "F0.1" "Fmax" "precautionary approach"))

    (class "gear"
      (description "How the draw is actually made. Gear sets both the effort a \
catch costs and the selectivity that decides which cohorts are taken.")
      (terms "gillnet" "longline" "purse seine" "trawl" "trap" "pot" "handline"
             "beach seine" "fish aggregating device" "mesh size" "selectivity"
             "bycatch" "discards"))

    (class "governance"
      (description "The forms a fishery envelope is held in — each maps onto a \
different planner construct, and the mapping is worth arguing explicitly.")
      (terms "total allowable catch" "TAC" "quota" "effort limitation"
             "closed season" "closed area" "marine protected area"
             "minimum landing size" "co-management" "territorial use rights"
             "customary marine tenure" "open access")))

  ;; ── The envelope: what may be taken given what comes back ────────────────
  (target
    (name "envelope")
    (construct "pooled-budget (engine/fragility.scm) + regenerating-stock (stocks.scm)")
    (description "The core construct of this domain. A fishery is a LEVEL drawn \
by many scopes and rebuilt by recruitment and growth. Prize anything stating a \
sustainable yield as a rate, a biomass as a level, or a reference point as a \
limit — and keep targets and limits apart, since they become different objects.")
    (fields (parameter value unit stock reference-point-type basis))
    (probes
      "maximum sustainable yield and how it is estimated from catch and effort"
      "biological reference points: target versus limit, and what each protects"
      "spawning stock biomass and the level below which recruitment fails"
      "surplus production model: how yield relates to stock size"
      "yield per recruit curve and the fishing mortality that maximises it"
      "how quickly a depleted stock rebuilds, and over how many years"
      "natural mortality rate and how it is estimated"))

  ;; ── Growth and recruitment: the restore term ─────────────────────────────
  (target
    (name "regeneration")
    (construct "restore term of S[t+1] = S[t] − draw + restore")
    (description "What puts fish back. Growth of individuals and recruitment of \
new cohorts are the two halves; a recipe that draws without them is mining.")
    (fields (species parameter value unit age-or-length basis))
    (probes
      "von Bertalanffy growth parameters K and L-infinity for a fish stock"
      "stock recruitment relationship and its steepness"
      "age at first maturity and age at recruitment to the fishery"
      "annual recruitment variability and what drives it"
      "length weight relationship parameters for a species"))

  ;; ── The draw: effort, gear and what a catch actually costs ───────────────
  (target
    (name "effort")
    (construct "recipe-flow work + use (the vessel, the gear)")
    (description "The thin human side. Catch per unit effort, crew, vessel time \
and gear — what a tonne landed costs in hours and equipment. Small by design: if \
this is large relative to the yield, the limit case is not what the plan claims.")
    (fields (gear operation effort-unit catch-per-unit-effort crew vessel-time fuel))
    (probes
      "catch per unit effort and how effort is standardised across gears"
      "crew size and fishing time per trip for a small scale vessel"
      "fuel consumption per tonne of fish landed"
      "gear selectivity: mesh size and the sizes actually retained"
      "days at sea and how fishing effort is measured in practice"))

  ;; ── Containment: the fishery inside its bioregion ────────────────────────
  (target
    (name "containment")
    (construct "SpatialThing contained-in / bioregion")
    (description "A fishery sits inside an estuary inside a coast. playnet.typ's \
coastal scope stewards fishery, estuary and mangrove together, so the nesting \
and the couplings between them are the structure this target is after.")
    (fields (habitat role species dependency evidence))
    (probes
      "nursery habitat and the role of mangroves or seagrass for fish stocks"
      "estuarine dependence of coastal fish species"
      "how habitat loss affects fishery productivity"
      "spawning grounds and migration between habitats"))

  ;; ── Multi-scope drawing: the pooled budget's reason for existing ─────────
  (target
    (name "shared-draw")
    (construct "pooled-budget over many scopes")
    (description "A fishery drawn by several communities at once — the case the \
pooled budget was built for and which no landed recipe yet exercises. What the \
literature says about allocation, and what happens when the sum of local draws \
exceeds the shared envelope.")
    (fields (arrangement parties allocation-basis enforcement outcome))
    (probes
      "allocation of a total allowable catch among fleets or communities"
      "shared stocks between jurisdictions and how they are managed jointly"
      "the tragedy of open access and what limits entry in practice"
      "co-management and community based fishery management outcomes"
      "customary marine tenure and territorial use rights in fisheries")))
