;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; manifest.scm — the water corpus.
;;;
;;; Phase 1 of docs/planning/food/natural-processes-research-plan.md. This domain
;;; discharges a promise the spec has already made: docs/localchimera.typ names "the
;;; specification that translates a watershed's cycles into a limit the community
;;; can see and govern", and there is no water recipe.
;;;
;;; It also closes a gap another bring-over left open. agroecology-bring-over.md
;;; §9.1 marks per-crop yield functions EXTERNAL and names exactly where they
;;; live: FAO Irrigation & Drainage Paper 56 for evapotranspiration and per-stage
;;; crop coefficients, Paper 33 for yield response to water. Paper 33 is already
;;; in use — data/process-multipliers.scm derives the Doon Valley's per-scenario
;;; yield multipliers from its Ky relation. This corpus brings the METHOD those
;;; numbers come from into reach of a citation, rather than leaving it as a
;;; formula transcribed once.
;;;
;;;   node tools/corpus/corpus.mjs fetch water
;;;   node tools/corpus/corpus.mjs build water
;;;
;;; LICENCE: FAO throughout — CC BY-NC-SA 3.0 IGO, NonCommercial and ShareAlike,
;;; both propagating. Urls checked (HTTP 200) 2026-08-10.
;;;
;;; NOT here, deliberately: the gridded and measured layers. ERA5 precipitation,
;;; SoilGrids, WRI Aqueduct and GAEZ are DATA (research plan §2.3) and several
;;; are already pinned in module/localchimera/knowledge/data/. A raster is not
;;; a text and does not belong in a retrieval index.

(corpus
  (title "Water: evapotranspiration, crop demand and the watershed envelope")
  (description "What a plant actually takes from the water cycle, what a \
catchment returns, and how the difference becomes a governed limit. The method \
behind the water side of every food recipe here, and the basis for a watershed \
specification a community can see.")
  (profile "profile.scm")

  ;; ── FAO 56: the canonical reference for crop water demand ────────────────
  ;; The most-cited document in irrigation. Penman-Monteith reference ETo, then
  ;; per-crop, per-growth-stage coefficients that turn a climate into a demand.
  ;; Chaptered HTML; annexes carry the tables, so they are fetched too — Annex 2
  ;; (meteorological tables) and Annex 7 (Kc for the initial stage) are where the
  ;; numbers actually are.

  (source
    (slug "fao56-evapotranspiration")
    (title "Crop Evapotranspiration — Guidelines for Computing Crop Water Requirements (FAO Irrigation & Drainage Paper 56)")
    (author "R. G. Allen, L. S. Pereira, D. Raes, M. Smith — FAO")
    (year 1998)
    (license "CC BY-NC-SA 3.0 IGO")
    (urls "https://www.fao.org/4/x0490e/x0490e04.htm"
          "https://www.fao.org/4/x0490e/x0490e06.htm"
          "https://www.fao.org/4/x0490e/x0490e07.htm"
          "https://www.fao.org/4/x0490e/x0490e08.htm"
          "https://www.fao.org/4/x0490e/x0490e0a.htm"
          "https://www.fao.org/4/x0490e/x0490e0b.htm"
          "https://www.fao.org/4/x0490e/x0490e0c.htm"
          "https://www.fao.org/4/x0490e/x0490e0e.htm"
          "https://www.fao.org/4/x0490e/x0490e0f.htm"
          "https://www.fao.org/4/x0490e/x0490e0g.htm"
          "https://www.fao.org/4/x0490e/x0490e0h.htm"
          "https://www.fao.org/4/x0490e/x0490e0i.htm"
          "https://www.fao.org/4/x0490e/x0490e0j.htm"
          "https://www.fao.org/4/x0490e/x0490e0k.htm"
          "https://www.fao.org/4/x0490e/x0490e0o.htm"
          "https://www.fao.org/4/x0490e/x0490e0p.htm")
    (file "texts/fao56-evapotranspiration/source.html")
    (note "Ch. 6 single Kc and Ch. 7 dual Kc are the per-crop coefficients; \
Ch. 8 is ETc under water stress — the link to yield loss. Annexes 2 and 7 hold \
the tables. This is the source agroecology-bring-over.md §9.1 named for the \
EXTERNAL yield-function gap.")))
