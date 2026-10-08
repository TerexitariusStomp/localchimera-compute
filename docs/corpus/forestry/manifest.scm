;;; manifest.scm — the silviculture corpus.
;;;
;;; Forestry is the first Phase 1 domain (docs/planning/food/natural-processes-research-plan.md)
;;; and it is first because its shelf is the best on the whole map: the two
;;; standard references are US Government work, therefore PUBLIC DOMAIN, and both
;;; are dimensioned throughout. No no-`url` entry is needed to build this domain.
;;;
;;;   node tools/corpus/corpus.mjs fetch forestry
;;;   node tools/corpus/corpus.mjs build forestry
;;;
;;; This file is COMMITTED; the texts are NOT (docs/corpus/**/texts/ is
;;; gitignored). The repo keeps the provenance and the fetch recipe — which
;;; matters more here than usual, since the four PDFs total ~195 MB.
;;;
;;; LICENCE DISCIPLINE. Every url below was fetched and checked (HTTP 200,
;;; application/pdf) on 2026-08-10 before it was written down. Three are US-Gov
;;; public domain; the IPCC chapters are free to reproduce with attribution under
;;; the IPCC's own terms. Nothing here is behind a paywall and nothing is a
;;; third-party mirror — the research plan §2.1 records two domains where a search
;;; engine offered an unauthorised host as the top result, so the rule is that a
;;; url enters this file only from the rightsholder.
;;;
;;; WHY THESE FIVE. The domain has to answer three different questions:
;;;   how a stand GROWS      → Silvics (per-species habitat, life history, rates)
;;;   what the wood IS       → Wood Handbook (material properties, the output spec)
;;;   what the stand HOLDS   → IPCC AFOLU (carbon stock and its change: the
;;;                            regenerating-stock level a `pooled-budget` carries)
;;; plus the yield MODEL itself (Essential FVS), which is the data-path entry
;;; described in the plan's §2.3 — an FVS run is vendored as deck + version, and
;;; this guide is how the deck gets written.

(corpus
  (title "Silviculture & forest growth")
  (description "The literature behind a forestry recipe: how a stand grows, what \
its rotation costs and yields, what the wood can then be used for, and how much \
carbon the standing forest holds. The long-rotation watchman case — where the \
disproportion between direct labour and product is largest, and where the \
regenerating-stock recurrence already runs green (test-forest-recurrence.scm).")
  (profile "profile.scm")

  ;; ── The growth side: the USDA standard reference ─────────────────────────
  ;; Agriculture Handbook 654. Silvical characteristics of ~200 species: habitat,
  ;; life history, genetics, per genus and species. Written by US Government
  ;; employees on official time, hence public domain. This is where a species'
  ;; growth behaviour, site requirements and regeneration come from.

  (source
    (slug "silvics-conifers")
    (title "Silvics of North America, Volume 1: Conifers")
    (author "Russell M. Burns and Barbara H. Honkala (tech. coords.), USDA Forest Service")
    (year 1990)
    (license "Public domain (US Government work)")
    (url "https://www.srs.fs.usda.gov/pubs/misc/ag_654_vol1.pdf")
    (file "texts/silvics-conifers/source.pdf")
    (note "AH-654 vol 1. 15 genera, 63 species, 20 varieties. ~37 MB. Habitat, \
life history and genetics per species — the growth side of a stand recipe."))

  (source
    (slug "silvics-hardwoods")
    (title "Silvics of North America, Volume 2: Hardwoods")
    (author "Russell M. Burns and Barbara H. Honkala (tech. coords.), USDA Forest Service")
    (year 1990)
    (license "Public domain (US Government work)")
    (url "https://www.srs.fs.usda.gov/pubs/misc/ag_654_vol2.pdf")
    (file "texts/silvics-hardwoods/source.pdf")
    (note "AH-654 vol 2. 58 genera, 128 species, 6 varieties. ~51 MB. The \
broadleaf half — coppice, sprouting and the short-rotation species live here."))

  ;; ── The material side: what the rotation actually produces ───────────────
  ;; A forestry recipe whose output is "timber" says almost nothing. The Wood
  ;; Handbook is what turns the output into a specification with properties —
  ;; density, strength, moisture behaviour, durability, and the processing a
  ;; given use demands. It is the bridge from `forestry` to the materials pairs.

  (source
    (slug "wood-handbook")
    (title "Wood Handbook — Wood as an Engineering Material")
    (author "Forest Products Laboratory, USDA Forest Service")
    (year 2021)
    (license "Public domain (US Government work; Wikimedia Commons carries it under PD Mark 1.0)")
    (url "https://www.fpl.fs.usda.gov/documnts/fplgtr/fplgtr282/fpl_gtr282.pdf")
    (file "texts/wood-handbook/source.pdf")
    (note "General Technical Report FPL-GTR-282. ~104 MB — the largest single \
text in any domain here, and worth it: it is the ResourceSpecification side of \
every timber output, and the industrial-route reference for the sheet-material \
pair in Phase 2."))

  ;; ── The stock side: what the standing forest holds ───────────────────────
  ;; The IPCC guidelines are Tier 1 in the plan's reputability ordering: the
  ;; methodology states are obliged to use, with documented tiers and uncertainty.
  ;; Chapter 4 is Forest Land; chapter 2 is the generic biomass/dead-organic-
  ;; matter/soil methods every land chapter builds on. Together they give the
  ;; carbon LEVEL a forest carries and how a cut or a regrowth changes it —
  ;; which is exactly what stocks.scm's S[t+1] = S[t] − draw + restore needs.

  (source
    (slug "ipcc-afolu-forest")
    (title "2006 IPCC Guidelines for National GHG Inventories, Vol. 4 Ch. 4: Forest Land")
    (author "IPCC Task Force on National Greenhouse Gas Inventories (IGES)")
    (year 2006)
    (license "Free to reproduce with attribution (IPCC/IGES terms); not CC")
    (url "https://www.ipcc-nggip.iges.or.jp/public/2006gl/pdf/4_Volume4/V4_04_Ch4_Forest_Land.pdf")
    (file "texts/ipcc-afolu-forest/source.pdf")
    (note "Carbon stock and stock change on forest land, land remaining forest \
and land converted. The regenerating-stock level and its draw/restore terms."))

  (source
    (slug "ipcc-afolu-generic")
    (title "2006 IPCC Guidelines, Vol. 4 Ch. 2: Generic Methodologies Applicable to Multiple Land-Use Categories")
    (author "IPCC Task Force on National Greenhouse Gas Inventories (IGES)")
    (year 2006)
    (license "Free to reproduce with attribution (IPCC/IGES terms); not CC")
    (url "https://www.ipcc-nggip.iges.or.jp/public/2006gl/pdf/4_Volume4/V4_02_Ch2_Generic.pdf")
    (file "texts/ipcc-afolu-generic/source.pdf")
    (note "The generic biomass / dead organic matter / soil carbon methods the \
forest chapter rests on. Read alongside ch. 4, never instead of it."))

  ;; ── The model side: how the yield function is actually run ───────────────
  ;; FVS is the Forest Service's national standard for growth and yield, and it
  ;; is a MODEL, not a table — so it enters by the data path (research plan
  ;; §2.3): an FVS run is vendored as its pinned input deck plus the FVS version,
  ;; and the yield table it emits is the derived artefact. This guide is the text
  ;; that says how to write the deck. Source at
  ;; github.com/USDAForestService/ForestVegetationSimulator.

  ;; ── The labour side: added 2026-08-10, because the shelf was EMPTY ───────
  ;; forestry-bring-over.md §1 records the finding: all six `labour` probes came
  ;; back with stocking densities — seedlings per acre, never hours per acre.
  ;; Silvics describes how trees grow and the Wood Handbook describes what wood
  ;; is; neither was ever a work study. Labour is the number the whole
  ;; disproportion claim rests on, so the domain needed a source that measures it.
  ;;
  ;; FAO Forestry Paper 99 is that source: its §3 calculates machine rates with
  ;; LABOR COSTS broken out, and §5 estimates logging unit costs through felling,
  ;; bucking, skidding, loading and transport — production rates per crew and per
  ;; machine, which is exactly what a recipe's work flow needs. Chaptered HTML,
  ;; so it enters as (urls …) joined in declared order.

  (source
    (slug "fao-harvesting-costs")
    (title "Cost Control in Forest Harvesting and Road Construction (FAO Forestry Paper 99)")
    (author "Food and Agriculture Organization of the United Nations")
    (year 1992)
    (license "CC BY-NC-SA 3.0 IGO — NonCommercial AND ShareAlike propagate to anything derived")
    (urls "https://www.fao.org/4/t0579e/t0579e01.htm"
          "https://www.fao.org/4/t0579e/t0579e02.htm"
          "https://www.fao.org/4/t0579e/t0579e03.htm"
          "https://www.fao.org/4/t0579e/t0579e04.htm"
          "https://www.fao.org/4/t0579e/t0579e05.htm"
          "https://www.fao.org/4/t0579e/t0579e06.htm"
          "https://www.fao.org/4/t0579e/t0579e07.htm"
          "https://www.fao.org/4/t0579e/t0579e08.htm"
          "https://www.fao.org/4/t0579e/t0579e09.htm"
          "https://www.fao.org/4/t0579e/t0579e0a.htm")
    (file "texts/fao-harvesting-costs/source.html")
    (note "The labour shelf. §3 machine rates incl. labor costs; §5 logging unit \
costs by operation. NOTE the licence: this is the first NC-SA source in the \
forestry domain, so anything traced to it carries share-alike — record it \
wherever a coefficient comes from here."))

  (source
    (slug "ilo-forestry-work")
    (title "Productive and Safe Work in Forestry")
    (author "International Labour Organization")
    (year 2019)
    (license "ILO publication — attribution required; confirm the exact CC grant before redistributing anything derived")
    (url "https://www.ilo.org/media/349076/download")
    (file "texts/ilo-forestry-work/source.pdf")
    (note "The work-organisation side: crews, tools, and what makes forest work \
productive. Read as context for the FAO rates rather than as a second rate table."))

  (source
    (slug "essential-fvs")
    (title "Essential FVS: A User's Guide to the Forest Vegetation Simulator")
    (author "Gary E. Dixon, USDA Forest Service, Forest Management Service Center")
    (year 2002)
    (license "Public domain (US Government work)")
    (url "https://www.fs.usda.gov/sites/default/files/forest-management/essential-fvs.pdf")
    (file "texts/essential-fvs/source.pdf")
    (note "How to drive FVS: keywords, cycles, treatment scheduling. Read for \
what a growth-and-yield RUN needs stated, so the vendored deck is complete.")))
