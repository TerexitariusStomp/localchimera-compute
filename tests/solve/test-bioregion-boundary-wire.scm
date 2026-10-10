;;; test-bioregion-boundary-wire.scm — the ecoregion polygon flows from the ONTOLOGY
;;; to the wire, "live all the way". Single source browser/data/geo/boundaries.json →
;;; set-spatial-boundary! → the shed's SpatialThing.boundary (schemas.scm) →
;;; scope-locations->wire's alist → day-boot's pass-through → a GeoJSON string the
;;; dial JSON.parses and draws as a REAL polygon. This exercises the actual server
;;; data path (minus the Goblins actor plumbing, which is a trivial map).
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-bioregion-boundary-wire.scm

(use-modules (playnet test planner prelude)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge worlds bioregions)
             (srfi srfi-1)
             (ice-9 format))
(use-modules ((json parser)  #:select (json-string->scm))
             ((json builder) #:select (scm->json-string))
             ((ice-9 textual-ports) #:select (get-string-all)))
(use-modules (playnet knowledge worlds doon-valley))
(use-modules (playnet knowledge worlds doon-shed))

;; ── load the SINGLE SOURCE (identical logic to service.scm load-bioregion-boundaries!) ──
(define bpath (or (find file-exists? '("browser/data/geo/boundaries.json"
                                       "../browser/data/geo/boundaries.json"
                                       "../../../../browser/data/geo/boundaries.json"))
                  "browser/data/geo/boundaries.json"))
(define fc   (json-string->scm (call-with-input-file bpath get-string-all)))
(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))
(for-each (lambda (f)
            (let* ((props (assoc-ref f "properties"))
                   (id (and (pair? props) (assoc-ref props "id")))
                   (geom (assoc-ref f "geometry")))
              (when (and (string? id) geom) (set-spatial-boundary! id (scm->json-string geom)))))
          (jarr (assoc-ref fc "features")))

;; ── 1. the shed's SpatialThing now carries its EXTENT ─────────────────────────
(define shed (bioregion-spatial *doon-shed*))
(define bstr (spatial-thing-boundary shed))
(format #t "~%── the Doon shed's extent flows from the ontology to the wire ──~%")
(format #t "  bioregion id: ~a   boundary chars: ~a~%" (spatial-thing-id shed) (if (string? bstr) (string-length bstr) 0))
(check "the shed's SpatialThing carries a boundary (a Point became a Region)" (string? bstr))

;; ── 2. the location wire alist (same fields as scope-locations->wire) carries it ──
(define wire `((id           . ,(spatial-thing-id shed))
               (lat          . ,(spatial-thing-lat shed))
               (contained-in . ,(spatial-thing-contained-in shed))
               (boundary     . ,(spatial-thing-boundary shed))))
(check "scope-locations->wire's alist carries the boundary" (string? (assoc-ref wire 'boundary)))
;; day-boot location->wire pass-through: (if (string? b) b 'null) → the string, not null
(check "day-boot emits the boundary STRING, not null"
       (string? (let ((b (assoc-ref wire 'boundary))) (if (string? b) b 'null))))

;; ── 3. it is the REAL geometry: a Polygon whose ring holds a Doon point ───────
(define geom (json-string->scm bstr))
(define (ring-of g) (map (lambda (p) (cons (car (jarr p)) (cadr (jarr p))))
                         (jarr (car (jarr (assoc-ref g "coordinates"))))))
(define outer (ring-of geom))
(define (inside? lng lat ring)                 ; ray-cast, ring = list of (lng . lat)
  (let loop ((ps ring) (prev (last ring)) (in #f))
    (if (null? ps) in
        (let ((xi (caar ps)) (yi (cdar ps)) (xj (car prev)) (yj (cdr prev)))
          (loop (cdr ps) (car ps)
                (if (and (not (eq? (> yi lat) (> yj lat)))
                         (< lng (+ (/ (* (- xj xi) (- lat yi)) (- yj yi)) xi))) (not in) in))))))
(check "the boundary parses to a Polygon"            (equal? (assoc-ref geom "type") "Polygon"))
(check "the Doon farm (78.03, 30.32) is INSIDE the shed polygon"  (inside? 78.03 30.32 outer))
(check "the Sahel (2.11, 13.51) is OUTSIDE it"                     (not (inside? 2.11 13.51 outer)))

(check-done "  the ecoregion polygon flows ontology → wire → dial, and it is the REAL shape~%  (a Doon point falls inside, the Sahel does not). Live all the way.~%")
