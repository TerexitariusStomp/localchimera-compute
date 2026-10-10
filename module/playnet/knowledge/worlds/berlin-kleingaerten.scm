;;; worlds/berlin-kleingaerten.scm — Berlin's allotment gardens as located economic resources,
;;; graded by the tenure security the city itself assigns them.
;;;
;;; Third in the series with worlds/berlin-baumscheiben.scm and worlds/berlin-gemeinschaftsgaerten.scm,
;;; and the one that dwarfs both: 2,917 ha against their 9.7 and 10.7. It is also the one
;;; where TENURE IS PUBLISHED — officially, per site, on a graded ladder, with the reason
;;; recorded. That makes it the control case for the other two.
;;;
;;; ── PROVENANCE (data/sources.md) ─────────────────────────────────────────────
;;; [DATA] Kleingartenentwicklungsplan 2030 — Entwicklungskategorien, official WFS,
;;;   retrieved 2026-08-07 (Senate resolution of 2020-08-20):
;;;   https://gdi.berlin.de/services/wfs/kleingartenentwicklungsplan2030
;;;   layer kleingartentwicklungsplan2030:kleingartenentwicklungsplan2030
;;;   → 1,065 sites, 29,174,877 m² (2,917 ha), 71,382 parcels. Complete download.
;;;   Fields used: `entwicklung` (the category), `fl_in_m2`, `parzellen`, `landeseigen`.
;;; [DATA] Kleingartenbestand Berlin, official WFS (https://gdi.berlin.de/services/wfs/
;;;   kleingarten, layer kleingarten:kleingarten) → 1,038 Anlagen, 28,775,789 m²,
;;;   70,390 parcels; 79.9% of that area flagged `landoderbezirk`=1. A second, slightly
;;;   different vintage of the same stock — kept as a CROSS-CHECK, not merged. The two
;;;   registers agree to within 1.4% on area and 1.4% on parcels, which is the honest
;;;   precision of any figure below.
;;; [DATA] Mean parcel 409 m² (Bestand) / 409 m² (KEP) — the two agree exactly.
;;; [DRAFT] The mapping from KEP category to a LOSS PROBABILITY is judgment. The
;;;   ORDERING is not: it is the city's own ranking, in the category names.
;;;
;;; Data licence: Datenlizenz Deutschland — Namensnennung 2.0. Attribution required:
;;; "Geoportal Berlin / Kleingartenentwicklungsplan 2030 - Entwicklungskategorien".

;; ── TENURE, PUBLISHED AND GRADED ─────────────────────────────────────────────
;; The Baumscheiben register answers "who owns this?" uniformly and says nothing about
;; permission. The community gardens answer neither. The KEP answers BOTH, per site,
;; and adds the city's own reasoning in `bem_entw` ("landeseigen + FNP-Grünfläche").
;; It is the only one of the three where a plan's tenure assumptions can be checked
;; against a public document rather than elicited in a room.
;;
;; What the ladder says, by share of area:
;;   67.7% permanently secured · 14.1% permanently to be retained · 9.3% long-term
;;   perspective only · 3.9% "other" · 3.2% rail land · 0.7% to become recreation
;;   grounds · 0.5% earmarked FOR BUILDING · 0.5% replacement land.
;; So roughly 82% is durable and roughly 18% is not, and the city has already said
;; which is which. That 18% — 515 ha, 13,105 parcels — is the part a plan must hedge.
;;
;; `landeseigen`: 738 sites / 2,320 ha state-owned, 327 sites / 598 ha not. Ownership
;; and security are related but distinct — rail land (Bahnflächen) is its own category
;; precisely because the owner is neither the Land nor a private person.

;; ── the KEP 2030 ladder ──────────────────────────────────────────────────────
;; (id  official-category-name  sites  area-m²  parcels  loss-probability)
;; The first five columns are DATA. The sixth is [DRAFT] — a judgment mapping from the
;; city's ordering onto a number, to be RATIFIED. Change these and nothing else changes.
(define-module (playnet knowledge worlds berlin-kleingaerten)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:export (*berlin-kleingaerten* *berlin-kg-sites* *berlin-kg-area*
            *berlin-kg-parcels* *berlin-kg-mean-parcel* *berlin-kg-bestand-sites*
            *berlin-kg-bestand-area* *berlin-kg-bestand-parcels*
            *berlin-kg-landeseigen-area* *berlin-kg-fremd-area* kg-id kg-name kg-sites
            kg-area kg-parcels kg-risk kg-spec %kg-secured kg-secured?
            berlin-kg-total-area berlin-kg-secured-area berlin-kg-at-risk-area
            kleingarten-resources kleingarten-spatials kleingarten-records))

(define *berlin-kleingaerten*
  '(("gesichert"    "1 dauerhaft gesicherte Kleingärten"                514 19750000  48104 0.002)
    ("zu-erhalten"  "2 dauerhaft zu erhaltende Kleingärten"             172  4130000   9744 0.008)
    ("langfristig"  "3 Kleingärten mit langfristiger Nutzungsperspektive" 154 2720000  6934 0.025)
    ("sonstige"     "5 Sonstige Kleingärten"                             75  1130000   2672 0.040)
    ("bahn"         "Bahnflächen"                                       106   940000   2589 0.050)
    ("erholung"     "7 Umwandlung in Erholungsanlagen"                    9   220000    456 0.080)
    ("baulich"      "4 bauliche Entwicklung von Kleingärten"             21   150000    454 0.100)
    ("ersatz"       "1 E Ersatzflächen"                                  14   140000    429 0.004)))

;; register totals, as downloaded
(define *berlin-kg-sites* 1065)
(define *berlin-kg-area* 29174877.0)          ; m² — 2,917 ha
(define *berlin-kg-parcels* 71382)
(define *berlin-kg-mean-parcel* 409.0)        ; m²
;; the Bestand register, for cross-check
(define *berlin-kg-bestand-sites* 1038)
(define *berlin-kg-bestand-area* 28775789.0)
(define *berlin-kg-bestand-parcels* 70390)
;; landeseigen split (KEP)
(define *berlin-kg-landeseigen-area* 23200000.0)
(define *berlin-kg-fremd-area* 5980000.0)

(define (kg-id k)      (list-ref k 0))
(define (kg-name k)    (list-ref k 1))
(define (kg-sites k)   (list-ref k 2))
(define (kg-area k)    (exact->inexact (list-ref k 3)))
(define (kg-parcels k) (list-ref k 4))
(define (kg-risk k)    (list-ref k 5))
(define (kg-spec k)    (string-append "kg-" (kg-id k)))

;; the categories the KEP treats as durable — "dauerhaft" in the city's own words,
;; plus the replacement land held against losses elsewhere.
(define %kg-secured '("gesichert" "zu-erhalten" "ersatz"))
(define (kg-secured? k) (member (kg-id k) %kg-secured))

(define (berlin-kg-total-area)
  (fold + 0.0 (map kg-area *berlin-kleingaerten*)))
(define (berlin-kg-secured-area)
  (fold + 0.0 (map kg-area (filter kg-secured? *berlin-kleingaerten*))))
(define (berlin-kg-at-risk-area)
  (- (berlin-kg-total-area) (berlin-kg-secured-area)))

;; ── resources: one land stock per KEP category, each its own spec ────────────
;; The unit of tenure here is the CATEGORY, because that is the unit the city's own
;; decision moves: a Senate resolution reclassifies a category, not a parcel. (In the
;; Baumscheiben it was the Bezirk; in the community gardens the individual lease.)
;; #:unit 'm2 (default) or 'ha. The whole stock is 2.9e7 m², and a plan carried in m²
;; against a matching demand hands the interior-point solve a condition number it
;; refuses — it reports no strictly-feasible point for a comfortably feasible problem.
;; Hectares keep every magnitude in a range the solver is happy with.
(define* (kleingarten-resources #:key (cats *berlin-kleingaerten*) (place "berlin-kg")
                                      (unit 'm2))
  (let ((div (if (eq? unit 'ha) 1e4 1.0))
        (u   (if (eq? unit 'ha) "ha" "m2")))
    (map (lambda (k)
           (let ((a (/ (kg-area k) div)))
             (make-economic-resource
               #:id (kg-spec k) #:name (kg-name k) #:conforms-to (kg-spec k) #:classified-as '()
               #:accounting-quantity (make-measure a u) #:onhand-quantity (make-measure a u)
               #:current-location place)))
         cats)))

(define* (kleingarten-spatials #:key (place "berlin-kg") (shed "berlin"))
  (list (make-spatial-thing #:id "biosphere" #:name "The biosphere" #:lat 0.0 #:long 0.0)
        (make-spatial-thing #:id "germany" #:name "Germany" #:lat 51.0 #:long 10.0
                            #:contained-in "biosphere")
        (make-spatial-thing #:id shed #:name "Berlin/Brandenburg" #:lat 52.52 #:long 13.40
                            #:contained-in "germany")
        (make-spatial-thing #:id place #:name "Berlin Kleingärten" #:lat 52.52 #:long 13.40
                            #:contained-in shed)))

(define* (kleingarten-records #:key (cats *berlin-kleingaerten*) (place "berlin-kg")
                                    (shed "berlin"))
  (values (kleingarten-resources #:cats cats #:place place)
          (kleingarten-spatials #:place place #:shed shed)))
