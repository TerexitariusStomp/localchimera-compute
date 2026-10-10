;;; worlds/berlin-gemeinschaftsgaerten.scm — Berlin's community gardens as located economic
;;; resources. The companion to worlds/berlin-baumscheiben.scm, and its opposite in tenure:
;;; the pits are uniformly public land nobody can take away from the city; the gardens
;;; are ground the gardeners mostly do NOT own, held on leases that end.
;;;
;;; Loaded after planner.scm. Provides *berlin-gemeinschaftsgaerten* (the named mapped
;;; gardens) and (gemeinschaftsgarten-resources / -spatials) for a planning scope.
;;;
;;; ── PROVENANCE (data/sources.md) ─────────────────────────────────────────────
;;; [DATA] OpenStreetMap via Overpass, retrieved 2026-08-07:
;;;   area["name"="Berlin"][admin_level=4]; nwr["garden:type"="community"]; out geom;
;;;   → 202 features: 104 ways + 3 relations carrying polygons, 95 nodes with no
;;;     extent. 164 of the 202 are named; 69 of the mapped polygons are named.
;;;   Areas computed from the polygon geometry (equirectangular projection at each
;;;   garden's own latitude — accurate well past the metre at this size).
;;; [DATA] Total mapped community-garden ground: 106,558 m². Median garden 429 m².
;;;   The 20 largest named gardens below hold 60,309 m² — 57% of the mapped total.
;;; [GAP] OSM is a volunteer register, not a cadastre: the 95 point-only features have
;;;   real extent that is simply unmapped, and gardens missing from OSM are missing
;;;   here. Treat 106,558 m² as a FLOOR on the true figure, never a census.
;;; [GAP] TENURE IS ABSENT — see §TENURE. This is the important gap, not the area one.

;; ── TENURE: the decisive variable, and nobody records it ──────────────────────
;; The Baumscheibe register answers "who owns this?" for all 434,765 pits in one word
;; (Land Berlin). For community gardens the same question is the whole ballgame — a
;; Zwischennutzung lease that ends is how Berlin gardens actually die — and no public
;; dataset holds it. What OSM carries is thin and about something else:
;;   operator:type  known for 18 of 104 polygons (community 14, private_non_profit 2,
;;                  public 1, private 1)
;;   access         known for 43 (private 25, yes 12, permissive 4, no 1, customers 1)
;;   start_date     known for 4
;; Owner, lease term, and end date: recorded nowhere public. So every tenure figure a
;; plan over these gardens uses is elicited, not measured, and must be marked [DRAFT]
;; pending ratification. Collecting real lease horizons from the gardens themselves is
;; the highest-value data work this candidate has.

;; ── the twenty largest named mapped gardens ──────────────────────────────────
;; (id name area-m² lat lon) — real names, real polygons, real centroids.
(define-module (playnet knowledge worlds berlin-gemeinschaftsgaerten)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:export (*berlin-gemeinschaftsgaerten* *berlin-gg-mapped-count*
            *berlin-gg-feature-count* *berlin-gg-mapped-area* gg-id gg-name gg-area
            gg-lat gg-lon gg-spec berlin-gg-total-area gemeinschaftsgarten-spatials
            gemeinschaftsgarten-resources gemeinschaftsgarten-records))

(define *berlin-gemeinschaftsgaerten*
  '(("nachbarschaftscampus-dammweg"       "Nachbarschaftscampus Dammweg"            11257 52.4727 13.4681)
    ("interkultureller-generationengarten" "Interkultureller Generationengarten"      5978 52.3903 13.3802)
    ("coop-campus"                        "Coop Campus"                              5737 52.4711 13.4235)
    ("allmende-kontor"                    "Gemeinschaftsgarten Allmende-Kontor"      5448 52.4745 13.4169)
    ("prinzessinnengarten"                "Prinzessinnengarten"                      5446 52.5030 13.4112)
    ("freilandlabor-schaefersee"          "Freilandlabor am Schäfersee (FlaSch)"     3147 52.5674 13.3575)
    ("urban-garden-htw"                   "Urban Garden HTW Berlin"                  2304 52.4547 13.5262)
    ("garten-rosenduft"                   "Interkultureller Garten Rosenduft"        2152 52.4922 13.3760)
    ("mauergarten"                        "Mauergarten"                              1928 52.5457 13.4000)
    ("lucys-garten"                       "Lucys Garten"                             1785 52.4849 13.4228)
    ("himmelbeet"                         "Himmelbeet"                               1736 52.5414 13.3790)
    ("schulgarten-picasso"                "Schulgarten der Picasso Grundschule"      1712 52.5475 13.4611)
    ("kubiz"                              "Offener Garten im KuBiZ"                  1574 52.5578 13.4702)
    ("stadtacker"                         "Stadtacker"                               1554 52.4814 13.4025)
    ("lichtenberger-stadtgarten"          "Lichtenberger Stadtgarten"                1540 52.5261 13.5132)
    ("frieda-sued"                        "Frieda Süd"                               1516 52.5028 13.3915)
    ("heizkraftwerk-mitte"                "Gemeinschaftsgarten Heizkraftwerk Mitte"  1443 52.5102 13.4208)
    ("karma-kultur-garten"                "Karma Kultur Garten"                      1376 52.4755 13.4464)
    ("blaetterlaube"                      "Blätterlaube"                             1361 52.4528 13.2871)
    ("stadtteilgarten-schillerkiez"       "Stadtteilgarten Schillerkiez"             1318 52.4746 13.4164)))

(define *berlin-gg-mapped-count* 104)          ; polygons in the Overpass result
(define *berlin-gg-feature-count* 202)         ; all community-garden features, incl. nodes
(define *berlin-gg-mapped-area* 106558.0)      ; m², summed over the 104 polygons

(define (gg-id g)   (list-ref g 0))
(define (gg-name g) (list-ref g 1))
(define (gg-area g) (exact->inexact (list-ref g 2)))
(define (gg-lat g)  (list-ref g 3))
(define (gg-lon g)  (list-ref g 4))
(define (gg-spec g) (string-append "gg-" (gg-id g)))

(define (berlin-gg-total-area)
  (fold + 0.0 (map gg-area *berlin-gemeinschaftsgaerten*)))

;; ── spatials: each garden at its own centroid, contained-in the shed ──────────
(define* (gemeinschaftsgarten-spatials #:key (gardens *berlin-gemeinschaftsgaerten*)
                                             (shed "berlin"))
  (append
    (list (make-spatial-thing #:id "biosphere" #:name "The biosphere" #:lat 0.0 #:long 0.0)
          (make-spatial-thing #:id "germany" #:name "Germany" #:lat 51.0 #:long 10.0
                              #:contained-in "biosphere")
          (make-spatial-thing #:id shed #:name "Berlin/Brandenburg" #:lat 52.52 #:long 13.40
                              #:contained-in "germany"))
    (map (lambda (g) (make-spatial-thing #:id (gg-id g) #:name (gg-name g) #:lat (gg-lat g)
                                         #:long (gg-lon g) #:contained-in shed))
         gardens)))

;; ── resources: one `land` stock per garden, its own spec ─────────────────────
;; Each garden carries its OWN resource-spec, because tenure is per-garden — one lease,
;; one landlord, one end date. That is what lets a scenario take exactly one garden
;; away. (Same reason the Baumscheiben carry a spec per Bezirk: there the unit of
;; permission is the Amt, here it is the lease.)
;;
;; #:place #f keeps each garden at its own centroid; passing a place pools them, which
;; is what a citywide plan wants while intra-Berlin transport is out of scope.
(define* (gemeinschaftsgarten-resources #:key (gardens *berlin-gemeinschaftsgaerten*)
                                              (place #f))
  (map (lambda (g)
         (make-economic-resource
           #:id (gg-spec g) #:name (gg-name g) #:conforms-to (gg-spec g) #:classified-as '()
           #:accounting-quantity (make-measure (gg-area g) "m2") #:onhand-quantity (make-measure (gg-area g) "m2")
           #:current-location (or place (gg-id g))))
       gardens))

(define* (gemeinschaftsgarten-records #:key (gardens *berlin-gemeinschaftsgaerten*)
                                            (place #f) (shed "berlin"))
  (values (gemeinschaftsgarten-resources #:gardens gardens #:place place)
          (gemeinschaftsgarten-spatials #:gardens gardens #:shed shed)))
