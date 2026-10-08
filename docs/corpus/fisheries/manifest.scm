;;; manifest.scm — the wild-capture fisheries corpus.
;;;
;;; Phase 1 of docs/planning/food/natural-processes-research-plan.md. Fisheries is
;;; kept apart from aquaculture deliberately: aquaculture CULTIVATES, wild capture
;;; is a pure draw against regeneration with no production labour at all, which
;;; makes it the limit case of the whole argument. docs/playnet.typ names it
;;; directly — "a fishing scope stewards its fishery", and a coastal scope
;;; stewarding fishery, estuary and mangrove together.
;;;
;;; It is also the first real user of `pooled-budget` (engine/fragility.scm:136): one
;;; ecological agent, many scopes debited against one measured level. Today that
;;; machinery is exercised only by a synthetic "shed"/"water" case in
;;; test-fragility-scales.scm.
;;;
;;;   node tools/corpus/corpus.mjs fetch fisheries
;;;   node tools/corpus/corpus.mjs build fisheries
;;;
;;; LICENCE. Everything here is FAO, therefore CC BY-NC-SA 3.0 IGO: NonCommercial
;;; AND ShareAlike, and both propagate to anything derived. Unlike forestry there
;;; is no public-domain alternative — FAO simply is the field's publisher — so
;;; this domain carries share-alike throughout rather than in one corner. Record
;;; it wherever a coefficient lands. Every url below was checked (HTTP 200) on
;;; 2026-08-10 before being written here.
;;;
;;; The stock LEVELS themselves are not here. Time series of biomass, spawner
;;; biomass, recruitment and fishing mortality live in the RAM Legacy Stock
;;; Assessment Database, which is versioned, machine-readable, and enters by the
;;; DATA path (research plan §2.3), not by this corpus.

(corpus
  (title "Wild-capture fisheries & stock assessment")
  (description "How much may be taken from a fishery given what comes back — \
the regenerative envelope in its oldest quantified form. Growth, mortality, \
recruitment, effort and the yield curve: the terms a pooled-budget over a \
stewarded fishery is built from.")
  (profile "profile.scm")

  ;; ── The classical manual: where the yield curve comes from ───────────────
  ;; Gulland 1969. Old, and that is a feature: it is the clearest statement of
  ;; the population arithmetic — growth, mortality, recruitment, effort and catch
  ;; per unit effort — before the field became model-software. Section 9, "The
  ;; Simple Yield Curve", is the sustainable-yield envelope in its plainest form.

  (source
    (slug "gulland-stock-assessment")
    (title "Manual of Methods for Fish Stock Assessment — Part 1: Fish Population Analysis")
    (author "J. A. Gulland, FAO Fishery Resources and Exploitation Division")
    (year 1969)
    (license "CC BY-NC-SA 3.0 IGO")
    (urls "https://www.fao.org/4/x5685e/x5685e01.htm"
          "https://www.fao.org/4/x5685e/x5685e02.htm"
          "https://www.fao.org/4/x5685e/x5685e03.htm"
          "https://www.fao.org/4/x5685e/x5685e04.htm"
          "https://www.fao.org/4/x5685e/x5685e05.htm"
          "https://www.fao.org/4/x5685e/x5685e06.htm"
          "https://www.fao.org/4/x5685e/x5685e07.htm"
          "https://www.fao.org/4/x5685e/x5685e08.htm"
          "https://www.fao.org/4/x5685e/x5685e09.htm"
          "https://www.fao.org/4/x5685e/x5685e0a.htm"
          "https://www.fao.org/4/x5685e/x5685e0b.htm"
          "https://www.fao.org/4/x5685e/x5685e0d.htm")
    (file "texts/gulland-stock-assessment/source.html")
    (note "§3 growth (von Bertalanffy), §5 mortalities, §7 recruitment and \
selection, §9 the simple yield curve. The draw-and-restore terms of a fishery \
read as one arithmetic."))

  ;; ── The management-facing statement: reference points as LIMITS ──────────
  ;; Where the assessment stops being a description and becomes a governed
  ;; number: yield-based reference points as targets, spawning-capacity points as
  ;; LIMITS. That distinction is the same one eco-catalogue.scm draws between a
  ;; level you may approach and a wall you may not cross.

  (source
    (slug "stock-assessment-for-management")
    (title "Stock Assessment for Fishery Management")
    (author "Food and Agriculture Organization of the United Nations")
    (year 2009)
    (license "CC BY-NC-SA 3.0 IGO")
    (url "https://openknowledge.fao.org/server/api/core/bitstreams/b7b8da38-3a41-47ea-ae58-5b78985f7490/content")
    (file "texts/stock-assessment-for-management/source.pdf")
    (note "~5.9 MB. Reference points: yield-based as targets, spawning-capacity \
as limits. The governed-number side — what a scope's fishery envelope is set \
BY, and who sets it."))

  ;; ── The applied manual, for the coefficients ─────────────────────────────
  (source
    (slug "cadima-stock-assessment")
    (title "Fish Stock Assessment Manual")
    (author "Emygdio L. Cadima, FAO")
    (year 2003)
    (license "CC BY-NC-SA 3.0 IGO")
    (url "https://openknowledge.fao.org/server/api/core/bitstreams/22f881ba-5ac0-4062-972c-2c4181a1fc68/content")
    (file "texts/cadima-stock-assessment/source.pdf")
    (note "The worked modern companion to Gulland: production models, \
yield-per-recruit, and the parameters each needs stated.")))
