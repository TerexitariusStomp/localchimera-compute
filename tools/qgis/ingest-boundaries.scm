;;; tools/qgis/ingest-boundaries.scm — merge QGIS watershed outputs into the
;;; single-source boundary file.
;;;
;;; browser/data/geo/boundaries.json is the FeatureCollection load-boundaries!
;;; (service.scm) reads at boot: each feature's properties.id names the
;;; SpatialThing (a bioregion first of all) whose extent it is. This tool
;;; takes the GeoJSON files either job chain writes — a LOCAL shed
;;; (<qgis-dir>/out/<id>-watershed.geojson, watershed-job.scm) or a TRUE
;;; upstream catchment (<qgis-dir>/out/<id>-catchment.geojson,
;;; catchment-job.scm) — and upserts one feature per id, keeping any
;;; feature it has no new geometry for. The two answer different questions
;;; (see catchment-job.scm's header) and can differ hugely in extent; which
;;; kind produced a file is read off its own suffix, and every upserted
;;; feature carries a `derivation` property naming the DEM, the actual
;;; algorithm chain and its threshold, so the polygon states where it came
;;; from and does not claim the other chain's provenance.
;;;
;;; Usage:
;;;   guile tools/qgis/ingest-boundaries.scm <boundaries.json> <out.geojson>...
;;;
;;; Output is rewritten in place; run from the repo root.

(use-modules (json) (ice-9 textual-ports) (ice-9 match) (srfi srfi-1))

(define (read-json path)
  (json-string->scm (call-with-input-file path get-string-all #:encoding "UTF-8")))

(define (features fc)
  (let ((f (assoc-ref fc "features")))
    (cond ((vector? f) (vector->list f)) ((list? f) f) (else '()))))

(define (feature-id f)
  (let ((p (assoc-ref f "properties")))
    (and (pair? p) (assoc-ref p "id"))))

;; Both job kinds' filename suffix, checked in this order — neither is a
;; suffix of the other, so order doesn't affect matching, only which name
;; wins if a file somehow matched both (it can't).
(define %job-suffixes `(("-catchment" . catchment) ("-watershed" . watershed)))

(define (job-kind-of path)
  "The kind (a symbol) a <id>-KIND.geojson filename names, else 'watershed
   — the original, suffix-less convention, kept as the default so an old
   *-watershed.geojson is still read the same way."
  (let ((base (basename path ".geojson")))
    (or (any (lambda (s) (and (string-suffix? (car s) base) (cdr s))) %job-suffixes)
        'watershed)))

(define (id-from-filename path)
  ;; <dir>/<id>-watershed.geojson or <dir>/<id>-catchment.geojson → <id>
  (let* ((base (basename path ".geojson"))
         (suffix (find (lambda (s) (string-suffix? (car s) base)) %job-suffixes)))
    (if suffix
        (substring base 0 (- (string-length base) (string-length (car suffix))))
        base)))

;; A drainage-direction raster is single-valued per cell (r.watershed -s),
;; so a real catchment vectorizes to one connected polygon; a handful of
;; stray single-cell polygons alongside it is r.to.vect exporting an
;; isolated DEM/flat-area artifact (a lake surface, a mosaic seam) as its
;; own micro-"basin" — a known GRASS D8 failure mode over flat terrain,
;; not a second real drainage. Below this bbox span (~0.01°, ~1 km — far
;; smaller than any GLO-90 cell cluster a real threshold-cells basin could
;; produce) a feature is that noise, dropped before it reaches the union.
(define %noise-span 0.01)

(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))

(define (ring-bbox-span ring)
  (let* ((pts (map jarr ring)) (x (map car pts)) (y (map cadr pts)))
    (max (- (apply max x) (apply min x)) (- (apply max y) (apply min y)))))

(define (feature-span f)
  (let* ((g (assoc-ref f "geometry")) (c (jarr (assoc-ref g "coordinates"))))
    (apply max (map (lambda (poly) (ring-bbox-span (jarr (car (jarr poly)))))
                     (if (equal? (assoc-ref g "type") "MultiPolygon") c (list c))))))

(define (drop-rasterization-noise feats)
  (let ((real (filter (lambda (f) (> (feature-span f) %noise-span)) feats)))
    (if (pair? real) real feats)))

(define (union-geometry feats0)
  "The basin the pour point falls in is a single polygon; guard anyway by
   folding several features into one MultiPolygon."
  (let ((feats (drop-rasterization-noise feats0)))
    (match feats
      ((f) (assoc-ref f "geometry"))
      (_ `(("type" . "MultiPolygon")
           ("coordinates"
            . ,(list->vector
                (append-map
                 (lambda (f)
                   (let ((g (assoc-ref f "geometry")))
                     (if (equal? (assoc-ref g "type") "MultiPolygon")
                         (vector->list (assoc-ref g "coordinates"))
                         (list (assoc-ref g "coordinates")))))
                 feats))))))))

;; Display names for sheds that have no feature yet; the registered
;; bioregion's own name (knowledge/<id>.scm).
(define %names
  '(("berlin" . "Berlin/Brandenburg")
    ("bay-area" . "San Francisco Bay Area")
    ("cascadia" . "Cascadia")
    ("doon-shed" . "Doon Valley watershed")))

;; kind → (chain . tool), the derivation each job actually runs — see
;; watershed-job.scm / catchment-job.scm's own headers for the full story.
(define %chains
  `((watershed
     . ("gdal:buildvirtualraster → grass:r.watershed → grass:r.to.vect → native:extractbylocation(pour point) → native:simplifygeometries(0.002°)"
        . "tools/qgis/watershed-job.scm"))
    (catchment
     . ("gdal:buildvirtualraster → grass:r.watershed(accumulation+drainage) → grass:r.mapcalc.simple(streams) → grass:r.to.vect → grass:v.distance(snap) → grass:r.water.outlet → grass:r.to.vect → native:simplifygeometries(0.002°)"
        . "tools/qgis/catchment-job.scm"))))

(define (derived-feature id kind path)
  (let ((feats (features (read-json path)))
        (chain (assq-ref %chains kind)))
    (and (pair? feats)
         `(("type" . "Feature")
           ("properties"
            . (("id" . ,id)
               ("tier" . "bioregion")
               ("derivation"
                . (("dem" . "Copernicus GLO-90 DSM (COG, EPSG:4326)")
                   ("kind" . ,(symbol->string kind))
                   ("chain" . ,(car chain))
                   ("tool" . ,(cdr chain))))))
           ("geometry" . ,(union-geometry feats))))))

(define (main args)
  (match args
    ((_ boundaries . outs)
     (let* ((fc   (read-json boundaries))
            (old  (features fc))
            (new  (filter-map (lambda (p) (derived-feature (id-from-filename p) (job-kind-of p) p)) outs))
            (ids  (map feature-id new))
            (kept (remove (lambda (f) (member (feature-id f) ids)) old))
            ;; Preserve a hand-written feature's `name` when replacing its geometry.
            (new* (map (lambda (f)
                         (let* ((id (feature-id f))
                                (prev (find (lambda (o) (equal? (feature-id o) id)) old))
                                (name (or (and prev (assoc-ref (assoc-ref prev "properties") "name"))
                                          (assoc-ref %names id))))
                           (if name
                               (cons (car f)
                                     (cons `("properties" . ,(cons `("name" . ,name)
                                                                  (assoc-ref f "properties")))
                                           (cddr f)))
                               f)))
                       new))
            (out  `(("type" . "FeatureCollection")
                    ("features" . ,(list->vector (append kept new*))))))
       (call-with-output-file boundaries
         (lambda (port) (put-string port (scm->json-string out #:pretty #t)) (newline port))
         #:encoding "UTF-8")
       (format #t "ingested ~a feature(s) into ~a: ~a~%" (length new*) boundaries ids)))
    (_ (format (current-error-port) "usage: ingest-boundaries.scm <boundaries.json> <out.geojson>...~%")
       (exit 1))))

(main (command-line))
