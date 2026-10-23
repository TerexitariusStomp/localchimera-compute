;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; manifest.scm — the permaculture / regenerative-design corpus.
;;;
;;; This file is COMMITTED; the texts it points at are NOT. `.git` already
;;; carries 678 MB and every Radicle clone and CI rsync pays for what lands
;;; here, so the repo keeps the provenance and the fetch recipe while the
;;; bytes stay local (docs/corpus/**/texts/ is gitignored).
;;;
;;;   node tools/corpus/corpus.mjs fetch permaculture
;;;   node tools/corpus/corpus.mjs build permaculture
;;;
;;; LICENSE DISCIPLINE. Every `url` below points at a text its rightsholder
;;; publishes for free — public domain, or an explicit Creative Commons grant.
;;; Sources with no `url` are in copyright: the manifest records that they
;;; exist and where they belong, and the pipeline reads them only if you drop
;;; your own copy at `file`. Nothing here downloads a book someone is selling.
;;;
;;; Note the NC in CC BY-NC: Millison's two textbooks are free to read, remix
;;; and build on for non-commercial use. Recipes derived from them inherit that
;;; condition — record it wherever a fact traces back to these two.

(corpus
  (title "Permaculture & regenerative design")
  (description "The design literature behind water-harvesting earthworks, \
soil building, food forests and closed nutrient loops — the branch of knowledge \
that turns a bounded piece of land into a recipe graph.")
  (profile "profile.scm")

  ;; ── The primary teaching texts ──────────────────────────────────────────
  ;; Andrew Millison teaches OSU's permaculture design course and publishes
  ;; both of his textbooks as open educational resources. This is the spine of
  ;; the corpus: a full design curriculum, openly licensed, already prose.

  (source
    (slug "millison-intro-permaculture")
    (title "Introduction to Permaculture")
    (author "Andrew Millison")
    (year 2017)
    (license "CC BY-NC 4.0")
    (url "https://open.oregonstate.education/permaculture/open/download?type=pdf")
    (file "texts/millison-intro-permaculture/source.pdf")
    (note "OSU open textbook. Ethics, principles, pattern literacy, zones \
and sectors, water, soil, plants, structures. The vocabulary the rest of the \
corpus is read through."))

  (source
    (slug "millison-permaculture-design")
    (title "Permaculture Design: Tools for Climate Resilience")
    (author "Andrew Millison")
    (year 2023)
    (license "CC BY-NC 4.0")
    (url "https://open.oregonstate.education/permaculturedesign/open/download?type=pdf")
    (file "texts/millison-permaculture-design/source.pdf")
    (note "The design-process text: site assessment, sector analysis, \
earthworks sizing, climate-resilience strategies. Richest single source of \
DIMENSIONED earthworks in the corpus — the numbers recipes need."))

  ;; ── The public-domain canon ─────────────────────────────────────────────
  ;; The books permaculture was assembled out of. Both are unambiguously in
  ;; the public domain and served as plain text by Project Gutenberg, which
  ;; means no OCR loss and stable line numbers.

  (source
    (slug "king-farmers-of-forty-centuries")
    (title "Farmers of Forty Centuries; or, Permanent Agriculture in China, Korea and Japan")
    (author "F. H. King")
    (year 1911)
    (license "public domain")
    (url "https://www.gutenberg.org/ebooks/5350.txt.utf-8")
    (file "texts/king-farmers-of-forty-centuries/source.txt")
    (note "The origin of the phrase \"permanent agriculture\". Forty centuries \
of closed nutrient loops observed and MEASURED — night soil, canal muck, \
composting, multiple cropping, with real quantities per mou. The metabolic-rift \
loop the planner already models, documented in the field."))

  (source
    (slug "darwin-vegetable-mould")
    (title "The Formation of Vegetable Mould Through the Action of Worms")
    (author "Charles Darwin")
    (year 1881)
    (license "public domain")
    (url "https://www.gutenberg.org/ebooks/2355.txt.utf-8")
    (file "texts/darwin-vegetable-mould/source.txt")
    (note "Topsoil as a thing that is BUILT at a measurable rate. Feeds the \
soil-fertility regenerating stock (navdanya-farm.scm) with rates of soil \
formation rather than the placeholder coefficients now standing in."))

  ;; ── Institutional open-access agronomy ──────────────────────────────────
  ;; FAO publishes under CC BY-NC-SA 3.0 IGO. These carry the thing the
  ;; agroecology bring-over marked EXTERNAL: measured coefficients.

  (source
    (slug "fao-10-elements-agroecology")
    (title "The 10 Elements of Agroecology: Guiding the Transition to Sustainable Food and Agricultural Systems")
    (author "FAO")
    (year 2018)
    (license "CC BY-NC-SA 3.0 IGO")
    (url "https://www.fao.org/3/i9037en/i9037en.pdf")
    (file "texts/fao-10-elements-agroecology/source.pdf")
    (note "The framework FAO evaluates agroecological transitions against — \
diversity, synergies, efficiency, recycling, resilience. Maps closely onto the \
fragility/diversity measures the planner already computes."))

  (source
    (slug "fao-save-and-grow")
    (title "Save and Grow: A Policymaker's Guide to the Sustainable Intensification of Smallholder Crop Production")
    (author "FAO")
    (year 2011)
    (license "CC BY-NC-SA 3.0 IGO")
    (url "https://www.fao.org/3/i2215e/i2215e.pdf")
    (file "texts/fao-save-and-grow/source.pdf")
    (note "Smallholder crop production with numbers: yields, water \
requirements, nutrient budgets, labour. Directly addresses the per-crop yield \
function that agroecology-bring-over.md flagged as the one real gap."))

  ;; ── The specification layer, reached by following leads ─────────────────
  ;; `corpus leads permaculture` reads the video corpus as an INDEX: it names
  ;; semi-circular bunds, contour bunds, negarim, percolation tanks, zai. Each
  ;; name is a thread, and this is where the threads end up — the engineering
  ;; manuals that dimension what the documentaries only point at.
  ;;
  ;; This source carries design procedure: catchment:cultivated area ratios,
  ;; bund spacing by slope, runoff coefficients, storage sizing. It is where
  ;; recipe NUMBERS come from; the videos are only how the technique was found.

  (source
    (slug "fao-water-harvesting-manual")
    (title "Water Harvesting: A Manual for the Design and Construction of Water Harvesting Schemes for Plant Production")
    (author "FAO — Will Critchley & Klaus Siegert")
    (year 1991)
    (license "CC BY-NC-SA 3.0 IGO")
    (urls "https://www.fao.org/3/U3160E/u3160e01.htm"
          "https://www.fao.org/3/U3160E/u3160e02.htm"
          "https://www.fao.org/3/U3160E/u3160e03.htm"
          "https://www.fao.org/3/U3160E/u3160e04.htm"
          "https://www.fao.org/3/U3160E/u3160e05.htm"
          "https://www.fao.org/3/U3160E/u3160e06.htm"
          "https://www.fao.org/3/U3160E/u3160e07.htm"
          "https://www.fao.org/3/U3160E/u3160e08.htm"
          "https://www.fao.org/3/U3160E/u3160e09.htm")
    (file "texts/fao-water-harvesting-manual/source.html")
    (note "THE specification the video corpus lacks. Chapter 7 dimensions each \
technique — negarim microcatchments, contour bunds, semi-circular bunds (the \
Sahel half-moon, engineered), trapezoidal bunds, water-spreading bunds — with \
sizing rules, slope limits and catchment ratios. Reached by following the \
`half-moon` and `contour bund` leads out of the footage."))

  ;; ── Community-maintained practice ───────────────────────────────────────

  (source
    (slug "appropedia-permaculture")
    (title "Appropedia: Permaculture (wiki source)")
    (author "Appropedia contributors")
    (license "CC BY-SA 4.0")
    (url "https://www.appropedia.org/Permaculture?action=raw")
    (file "texts/appropedia-permaculture/source.txt")
    (note "Seed page only. Appropedia is worth a proper crawl later — it is \
the largest CC-licensed appropriate-technology corpus going, and its how-to \
pages are nearly recipes already."))

  ;; ── Spoken sources: the design canon that was filmed, not written ───────
  ;; Millison's textbooks are video-centric — the PDFs are largely headings and
  ;; links, and the teaching sits in the footage. The spoken track is still
  ;; text, held in captions, so the pipeline reads it as one document per
  ;; playlist (kind "youtube-playlist", tools/corpus/lib/youtube.mjs).
  ;;
  ;; These playlists are chosen to span SCALE, which is the axis the written
  ;; corpus lacks entirely: a single catchment, then a farm, then a village,
  ;; then a watershed, then a river basin, then a continental belt. The same
  ;; three moves — slow the water, spread it, sink it — recur at every one of
  ;; them, and that recurrence is what makes a scale-graded recipe set possible.
  ;;
  ;; These are captions of copyrighted videos. They stay local and gitignored;
  ;; what is inscribed from them is quantities and procedures, cited by video id
  ;; and timestamp, not passages of speech.

  (source
    (slug "millison-water-management")
    (title "Permaculture Water Management (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqOArISsDK7sYZw7UbIaCdhYX")
    (file "texts/millison-water-management/source.md")
    (note "26 videos. The technique layer: swales, ponds, keyline, greywater. \
Where dimensions live."))

  (source
    (slug "millison-rainwater-course")
    (title "Rainwater Harvesting Course (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqODoLa3-lKmLmsktxu9RfQp-")
    (file "texts/millison-rainwater-course/source.md")
    (note "8 videos, taught as a course ⇒ the most explicitly procedural \
material on the channel. Household and site scale."))

  (source
    (slug "millison-india-water-2020")
    (title "India's Water Revolution 2020 (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqOCgePyiAyBT0sh7zlr7xhz3")
    (file "texts/millison-india-water-2020/source.md")
    (note "Village-to-watershed scale: johads, check dams, and the social form \
that builds them."))

  (source
    (slug "millison-india-water-2023")
    (title "India's Water Revolution 2023 (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqODd4hJ4bXl1UR1ncdDdlalT")
    (file "texts/millison-india-water-2023/source.md")
    (note "The same regions revisited — outcomes over time, which is the rarest \
thing in this literature and the only way to calibrate a restoration rate."))

  (source
    (slug "millison-paani-foundation")
    (title "India's Paani Foundation (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqODK1mtweVoVZaPgtdzseGdr")
    (file "texts/millison-paani-foundation/source.md")
    (note "Village-scale watershed work organised as a COMPETITION between \
villages — labour mobilisation as the binding constraint, not technique."))

  (source
    (slug "millison-cauvery-restoration")
    (title "India's Cauvery River Restoration (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqODPsASVOz-g4Tn5xSrpLOAM")
    (file "texts/millison-cauvery-restoration/source.md")
    (note "River-basin scale: agroforestry transition across a whole catchment."))

  (source
    (slug "millison-great-green-wall")
    (title "Africa's Great Green Wall (playlist)")
    (author "Andrew Millison")
    (license "captions of copyrighted video — local use, cite by timestamp")
    (kind "youtube-playlist")
    (playlist "PLNdMkGYdEqOCMkEtNGDRvEZgjPnZY5yUj")
    (file "texts/millison-great-green-wall/source.md")
    (note "Continental scale: the Sahel belt. Half-moons and zai pits — the \
smallest earthworks in the corpus, deployed across the largest area."))

  ;; ── In copyright: supply your own copy ──────────────────────────────────
  ;; The rest of the design canon, recorded so the corpus knows what it is
  ;; missing. No `url`: `fetch` will print the path and move on, and `build`
  ;; picks each one up the moment a file appears there. If you own these as
  ;; PDF or EPUB, drop them in and rebuild — nothing else changes.

  (source
    (slug "mollison-designers-manual")
    (title "Permaculture: A Designers' Manual")
    (author "Bill Mollison")
    (year 1988)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/mollison-designers-manual/source.pdf")
    (note "The field's reference work. Chapter 7 (water) and chapter 10 (soils) \
are the densest recipe material in the whole literature."))

  (source
    (slug "holmgren-principles-pathways")
    (title "Permaculture: Principles and Pathways Beyond Sustainability")
    (author "David Holmgren")
    (year 2002)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/holmgren-principles-pathways/source.pdf"))

  (source
    (slug "hemenway-gaias-garden")
    (title "Gaia's Garden: A Guide to Home-Scale Permaculture")
    (author "Toby Hemenway")
    (year 2009)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/hemenway-gaias-garden/source.pdf")
    (note "Guild and polyculture tables — the companion-planting relations \
the folksonomy graph wants."))

  (source
    (slug "lancaster-rainwater-drylands")
    (title "Rainwater Harvesting for Drylands and Beyond, Volume 1")
    (author "Brad Lancaster")
    (year 2013)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/lancaster-rainwater-drylands/source.pdf")
    (note "Sizing formulas for catchment and earthworks — dimensioned, which \
is exactly what a water recipe needs."))

  (source
    (slug "yeomans-water-for-every-farm")
    (title "Water for Every Farm: Yeomans Keyline Plan")
    (author "P. A. Yeomans")
    (year 1993)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/yeomans-water-for-every-farm/source.pdf")
    (note "Keyline geometry and the soil-building plough regime. Editions of \
this circulate with the Yeomans family's blessing; if you find an authorized \
free edition, promote this entry to a url."))

  (source
    (slug "fukuoka-one-straw-revolution")
    (title "The One-Straw Revolution")
    (author "Masanobu Fukuoka")
    (year 1975)
    (license "in-copyright")
    (supplied-by-user #t)
    (file "texts/fukuoka-one-straw-revolution/source.pdf")
    (note "Do-nothing farming: seed balls, no-till rice/barley rotation, \
groundcover. Recipes defined by what they OMIT — a useful stress test for a \
model that thinks in inputs.")))
