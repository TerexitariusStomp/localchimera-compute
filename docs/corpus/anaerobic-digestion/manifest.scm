;;; manifest.scm — the anaerobic-digestion corpus.
;;;
;;; Phase 1 of docs/planning/food/natural-processes-research-plan.md, and the domain
;;; chosen to CLOSE A LOOP rather than stand alone: digestion takes biomass and
;;; returns fuel *and* digestate, so it joins composting → energy → soil across
;;; two of the six instances docs/playnet.typ names. Both ends already exist in
;;; the repo — humisoil.scm ferments biomass into a soil amendment, and grow.scm
;;; consumes soil-N/P/K explicitly — so the digestate has somewhere to land.
;;;
;;; RE-ANCHORED. The research plan first named the GTZ *Biogas Digest* as this
;;; domain's spine. §2.1 records why it is not: the GTZ→GIZ reorganisation took
;;; the canonical urls down, and what remains are mirrors of unclear provenance.
;;; The EPA guidebook is US-Gov public domain and published by its author, so it
;;; leads instead.
;;;
;;;   node tools/corpus/corpus.mjs fetch anaerobic-digestion
;;;   node tools/corpus/corpus.mjs build anaerobic-digestion
;;;
;;; LICENCE: one public-domain source and two IPCC chapters (free to reproduce
;;; with attribution). No NC, no share-alike — this domain stays clean, unlike
;;; fisheries and water. Urls checked (HTTP 200, application/pdf) 2026-08-10.
;;;
;;; A note on what was REJECTED. FAO document i3325e was fetched and inspected
;;; before being cited: it is the Climate-Smart Agriculture Sourcebook, not a
;;; digestion text, so it is not here. Checking a document's identity rather than
;;; its URL status is the second half of the rule §2.1 states.

(corpus
  (title "Anaerobic digestion: biogas and digestate")
  (description "Microbes eat biomass in the dark and return two products — a \
fuel and a fertiliser. The clearest case of cultivated metabolism as a means of \
production, and the one that closes a loop the repo's existing recipes leave \
open: humisoil.scm makes soil from biomass, grow.scm draws nutrients from soil, \
and digestion is what joins the fuel side to both.")
  (profile "profile.scm")

  ;; ── The operating manual: what a digester actually needs run ─────────────
  (source
    (slug "epa-agstar-operator")
    (title "Anaerobic Digester / Biogas System Operator Guidebook")
    (author "US Environmental Protection Agency, AgSTAR")
    (year 2020)
    (license "Public domain (US Government work)")
    (url "https://www.epa.gov/sites/default/files/2020-11/documents/agstar-operator-guidebook.pdf")
    (file "texts/epa-agstar-operator/source.pdf")
    (note "~4.6 MB. Feedstock handling, loading rates, retention time, \
temperature regime, gas handling, and what goes wrong. The process-specification \
side: the conditions the metabolism has to be held inside."))

  ;; ── The coefficients: methane potential and manure characteristics ───────
  ;; Tier 1 in the plan's reputability ordering. Ch. 10 carries volatile-solids
  ;; excretion and maximum methane-producing capacity (Bo) per animal and region
  ;; — which is the YIELD FUNCTION of a manure-fed digester, stated as a
  ;; parameter table with documented uncertainty.
  (source
    (slug "ipcc-livestock-manure")
    (title "2006 IPCC Guidelines, Vol. 4 Ch. 10: Emissions from Livestock and Manure Management")
    (author "IPCC Task Force on National Greenhouse Gas Inventories (IGES)")
    (year 2006)
    (license "Free to reproduce with attribution (IPCC/IGES terms); not CC")
    (url "https://www.ipcc-nggip.iges.or.jp/public/2006gl/pdf/4_Volume4/V4_10_Ch10_Livestock.pdf")
    (file "texts/ipcc-livestock-manure/source.pdf")
    (note "Volatile solids excreted per animal, maximum methane producing \
capacity Bo by manure type, and manure-management-system definitions. The \
feedstock side of the yield, with default values by region."))

  ;; ── The other half of the pair: composting vs digestion, same feedstock ──
  ;; Small, and exactly on point: this chapter treats composting and anaerobic
  ;; digestion as two treatments of the same waste stream. That is a paired route
  ;; in the plan's sense — one feedstock, two recipes, different products — and
  ;; humisoil.scm already occupies the composting side.
  (source
    (slug "ipcc-biological-treatment")
    (title "2006 IPCC Guidelines, Vol. 5 Ch. 4: Biological Treatment of Solid Waste")
    (author "IPCC Task Force on National Greenhouse Gas Inventories (IGES)")
    (year 2006)
    (license "Free to reproduce with attribution (IPCC/IGES terms); not CC")
    (url "https://www.ipcc-nggip.iges.or.jp/public/2006gl/pdf/5_Volume5/V5_4_Ch4_Bio_Treat.pdf")
    (file "texts/ipcc-biological-treatment/source.pdf")
    (note "Composting and anaerobic digestion side by side on the same \
feedstock — the paired-route shape, from a Tier 1 source. Small chapter; read \
whole.")))
