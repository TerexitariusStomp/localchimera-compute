;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; worlds/berlin-baumscheiben.scm — Berlin's street-tree pits (Baumscheiben) as located
;;; economic resources. The city's most widely distributed piece of unbuilt,
;;; already-public growing land: 434,765 of them, one per street tree.
;;;
;;; Loaded after planner.scm (+ knowledge/berlin.scm for the shed and its real
;;; futures). Provides *berlin-baumscheiben* (per-Bezirk records), the spatial tree
;;; placing each Bezirk contained-in "berlin", and (baumscheiben-records …) →
;;; (values resources spatials) for a planning scope.
;;;
;;; ── PROVENANCE (data/sources.md) ─────────────────────────────────────────────
;;; [DATA] Berlin Baumkataster — Straßenbäume, official WFS, retrieved 2026-08-07:
;;;   https://gdi.berlin.de/services/wfs/baumbestand  (layer baumbestand:strassenbaeume)
;;;   434,765 features. Counts per Bezirk and centroids (mean of the feature points,
;;;   reprojected EPSG:25833 → EPSG:4326 by the service) computed over the COMPLETE
;;;   download, not a sample. 1,589 features carry neither `bezirk` nor `eigentuemer`
;;;   and are held out of the per-Bezirk table below — they are in the total, not in
;;;   any district.
;;; [DATA] TENURE — `eigentuemer` is "Land Berlin" for all 433,176 attributed trees.
;;;   Zero privately owned street trees. See §TENURE below: this is why the
;;;   Baumscheibe case is a COMPLIANCE problem, not a socialization one.
;;; [DATA] Median tree age per Bezirk from `standalter`; dominant genus from
;;;   `gattung_deutsch` (Berlin-wide: Linde 150,148 · Ahorn 89,091 · Eiche 38,873).
;;; [DRAFT] USABLE AREA per pit and the PLANTABLE FRACTION are the two judgment
;;;   calls in this file. Both are single named constants so the room can move them,
;;;   and both are governance figures to be RATIFIED, not measurements. See below.

;; ── TENURE: the finding that reframes the whole question ──────────────────────
;; Every attributed street tree in Berlin is owned by Land Berlin. There is no
;; private owner to grant custody, so `socialize-private-resource` has no subject
;; here and the recall-risk dial has nothing to watch — the custody column never
;; moves because it was never privately held.
;;
;; The uncertainty that DOES bite is permission: planting a Baumscheibe wants an
;; Anmeldung with the Bezirk's Grünflächenamt (per-Bezirk rules, loosely enforced,
;; revocable), and an event on street land is a Sondernutzung. That is the
;; compliance axis — a permit as a resource whose absence prunes a column
;; (docs/legal/legal-compliance-lifecycle.md) — and it is per-BEZIRK, which is
;; what makes the twelve districts a real diversification set.

;; usable open soil per Baumscheibe, m². [DRAFT — governance figure, not a measurement]
;; Berlin guidance asks ≥6 m² of root space for NEW plantings; the large inherited
;; stock sits in sealed pavement with far less open surface, commonly 1–2 m².
;; 1.5 is the conservative middle. Raise it and every number below scales linearly.
(define-module (playnet knowledge worlds berlin-baumscheiben)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:export (*baumscheibe-m2* *baumscheibe-plantable-fraction* *berlin-baumscheiben*
            *berlin-baumscheiben-total* bs-name bs-count bs-lat bs-lon bs-age bs-genus
            bs-place bs-spec bs-area berlin-baumscheiben-total-area *pit-spec*
            berlin-baumscheiben-spatials berlin-baumscheiben-resources
            baumscheiben-records))

(define *baumscheibe-m2* 1.5)

;; the share actually plantable. [DRAFT] Excludes pits too compacted, too deeply
;; shaded, too close to running traffic, or already adopted. Deliberately pessimistic:
;; a claim on 15% of the stock is defensible in a way that a claim on all of it is not.
(define *baumscheibe-plantable-fraction* 0.15)

;; ── PER-BEZIRK, from the complete download ────────────────────────────────────
;; (bezirk trees centroid-lat centroid-lon median-tree-age dominant-genus)
(define *berlin-baumscheiben*
  '(("Steglitz-Zehlendorf"        61131 52.4371 13.2780 56 "Linde")
    ("Marzahn-Hellersdorf"        47118 52.5256 13.5775 36 "Ahorn")
    ("Pankow"                     43437 52.5760 13.4370 36 "Linde")
    ("Reinickendorf"              42607 52.6003 13.3025 56 "Linde")
    ("Treptow-Köpenick"           42318 52.4408 13.5710 34 "Linde")
    ("Charlottenburg-Wilmersdorf" 41826 52.4997 13.2935 46 "Linde")
    ("Tempelhof-Schöneberg"       36113 52.4477 13.3750 43 "Linde")
    ("Lichtenberg"                31723 52.5290 13.5065 36 "Linde")
    ("Mitte"                      26156 52.5321 13.3698 36 "Linde")
    ("Spandau"                    23296 52.5271 13.1831 47 "Linde")
    ("Neukölln"                   20873 52.4497 13.4548 41 "Linde")
    ("Friedrichshain-Kreuzberg"   16578 52.5038 13.4287 39 "Linde")))
;; 433,176 attributed + 1,589 unattributed = 434,765 in the register.
(define *berlin-baumscheiben-total* 434765)

(define (bs-name b)   (list-ref b 0))
(define (bs-count b)  (list-ref b 1))
(define (bs-lat b)    (list-ref b 2))
(define (bs-lon b)    (list-ref b 3))
(define (bs-age b)    (list-ref b 4))
(define (bs-genus b)  (list-ref b 5))

;; a stable spatial id per Bezirk ("Friedrichshain-Kreuzberg" → "bz-friedrichshain-kreuzberg")
(define (bs-place b)
  (string-append "bz-" (string-downcase
                         (string-map (lambda (c)
                                       (case c ((#\x00e4) #\a) ((#\x00f6) #\o) ((#\x00fc) #\u) ((#\x00df) #\s)
                                             ((#\space) #\-) (else c)))
                                     (bs-name b)))))

;; Each Bezirk's pits carry their OWN resource-spec, not a shared "land". This is
;; what lets a scenario revoke ONE district's permission — the robust `avail` shock
;; keys on a spec (solve/robust.scm:32), so a shared spec could only ever revoke the whole
;; city at once. Twelve specs = twelve independently revocable grants, which is the
;; real administrative shape: twelve Grünflächenämter, twelve sets of rules.
(define (bs-spec b) (string-append "pit-" (bs-place b)))

;; plantable m² in a Bezirk — the two DRAFT constants applied to the real count
(define (bs-area b) (* (bs-count b) *baumscheibe-m2* *baumscheibe-plantable-fraction*))

(define (berlin-baumscheiben-total-area)
  (fold + 0.0 (map bs-area *berlin-baumscheiben*)))

;; ── the spatial tree: each Bezirk contained-in the Berlin/Brandenburg shed ─────
;; so a scope placed here inherits the shed's real drought futures and its water and
;; topsoil limits by containment (bioregions.scm) — no per-district wiring.
(define* (berlin-baumscheiben-spatials #:key (shed "berlin"))
  (append
    (list (make-spatial-thing #:id "biosphere" #:name "The biosphere" #:lat 0.0 #:long 0.0)
          (make-spatial-thing #:id "germany" #:name "Germany" #:lat 51.0 #:long 10.0
                              #:contained-in "biosphere")
          (make-spatial-thing #:id shed #:name "Berlin/Brandenburg" #:lat 52.52 #:long 13.40
                              #:contained-in "germany"))
    (map (lambda (b)
           (make-spatial-thing #:id (bs-place b) #:name (bs-name b) #:lat (bs-lat b)
                               #:long (bs-lon b) #:contained-in shed))
         *berlin-baumscheiben*)))

;; ── the resources: one `land` stock per Bezirk, in m² of plantable pit ────────
;; A raw consumed by growing with no producer, so it is a HARD cap — you have the
;; Baumscheiben you have. Owner is Land Berlin throughout (see §TENURE).
;; #:place #f keeps every Bezirk's pits at its OWN centroid (the real geography, what
;; a map wants). Passing a single place pools them there instead — which is what a
;; citywide plan wants while intra-Berlin transport is out of scope: the districts
;; stay distinguishable by SPEC, which is what carries permission anyway, and the
;; harvest lands in one pool a single reproduction floor can defend.
;; SPEC-OF names the spec a Bezirk's pits conform to. The default keeps
;; each Bezirk's own (bs-spec), the engine tests' worlds; the LIVE seed
;; passes one shared spec (*pit-spec*) and lets the PLACE distinguish the
;; districts — a withdrawal is then a shock on the located act
;; (proc . place), the engine's own tiling dimension, and a recipe stays
;; the one location-agnostic template.
(define *pit-spec* "pit")
(define* (berlin-baumscheiben-resources #:key (bezirke *berlin-baumscheiben*) (place #f)
                                        (spec-of bs-spec))
  (map (lambda (b)
         (make-economic-resource
           #:id (bs-spec b) #:conforms-to (spec-of b) #:classified-as '()
           #:accounting-quantity (make-measure (bs-area b) "m2") #:onhand-quantity (make-measure (bs-area b) "m2")
           #:current-location (or place (bs-place b))))
       bezirke))

;; both halves at once, the shape a scope wants
(define* (baumscheiben-records #:key (bezirke *berlin-baumscheiben*) (shed "berlin"))
  (values (berlin-baumscheiben-resources #:bezirke bezirke)
          (berlin-baumscheiben-spatials #:shed shed)))
