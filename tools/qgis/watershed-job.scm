;;; tools/qgis/watershed-job.scm — derive a bioregion's watershed polygon from a DEM.
;;;
;;; For one bioregion (id, pour-point lat/lon, tile radius) this writes ONE
;;; qgis-runner job under <qgis-dir>/jobs/<id>-watershed/ that
;;;   1. declares the Copernicus GLO-90 DEM tiles (public S3, 1°×1° COG
;;;      GeoTIFFs) covering ±RADIUS degrees around the pour point as
;;;      optional fetches into <qgis-dir>/data/dem/ (the runner lands them
;;;      over Tor; ocean tiles are absent on the bucket and simply drop out
;;;      of the mosaic),
;;;   2. chains:
;;;        gdal:buildvirtualraster  → one mosaic VRT over the tiles present
;;;        grass:r.watershed        → basin raster at THRESHOLD cells
;;;        grass:r.to.vect          → basin polygons
;;;        native:extractbylocation → the basin containing the pour point
;;;        native:simplifygeometries → web-weight outline
;;;        native:savefeatures      → out/<id>-watershed.geojson (EPSG:4326)
;;;
;;; The runner (server/qgis-runner.scm) picks the job up by inotify; this
;;; script touches no network itself. The job and its pour-point.geojson are
;;; built as Scheme/JSON DATA and written with `write`/scm->json-string —
;;; not assembled as text a shell splices into source, so nothing here can
;;; be mis-quoted or (worse) accidentally interpreted by a shell the way a
;;; bash heredoc can. The resulting GeoJSON is merged into
;;; browser/data/geo/boundaries.json by tools/qgis/ingest-boundaries.scm.
;;;
;;; Usage:
;;;   guile --no-auto-compile tools/qgis/watershed-job.scm \
;;;     <id> <lat> <lon> [radius-deg=1] [threshold-cells=20000]
;;;   QGIS_DIR   spool root (default /var/lib/playnet/qgis)
;;;
;;; Threshold is the minimum basin size in cells; at GLO-90 (~90 m) 20 000
;;; cells ≈ 160 km², which separates a metropolitan shed from its creeks.

(use-modules (ice-9 match) (ice-9 format) (ice-9 textual-ports) (json) (srfi srfi-11))
(load (string-append (dirname (current-filename)) "/lib-dem-tiles.scm"))

(define (mkdir-p! path) (system* "mkdir" "-p" path))

(define (write-job! path job)
  (call-with-output-file path
    (lambda (port) (write job port) (newline port))))

(define (write-pour-point! path id lon lat)
  (call-with-output-file path
    (lambda (port)
      (put-string port
       (scm->json-string
        `(("type" . "FeatureCollection")
          ("features"
           . #((("type" . "Feature")
                ("properties" . (("id" . ,id)))
                ("geometry" . (("type" . "Point") ("coordinates" . #(,lon ,lat)))))))))))))

(define (main args)
  (match args
    ((_ id lat-s lon-s . rest)
     (let* ((lat       (string->number lat-s))
            (lon       (string->number lon-s))
            (radius    (if (pair? rest) (string->number (car rest)) 1))
            (threshold (if (and (pair? rest) (pair? (cdr rest))) (string->number (cadr rest)) 20000))
            (qgis-dir  (or (getenv "QGIS_DIR") "/var/lib/playnet/qgis"))
            (dem       (string-append qgis-dir "/data/dem"))
            (out       (string-append qgis-dir "/out"))
            (work      (string-append out "/" id))
            (stage     (string-append qgis-dir "/stage/" id "-watershed"))
            (job-dir   (string-append qgis-dir "/jobs/" id "-watershed")))
       (for-each mkdir-p! (list dem out work stage (string-append qgis-dir "/jobs")))
       (let*-values (((fetch inputs) (dem-tile-set lat lon radius dem)))
         (let* ((vrt        (string-append work "/dem.vrt"))
                (basins     (string-append work "/basins.tif"))
                (basins-vec (string-append work "/basins.gpkg"))
                (shed       (string-append work "/shed.gpkg"))
                (simple     (string-append work "/shed-simple.gpkg"))
                (geojson    (string-append out "/" id "-watershed.geojson"))
                (point      (string-append work "/pour-point.geojson"))
                (job
                 `((id . ,id)
                   (fetch . ,fetch)
                   (steps
                    . (((algorithm . "gdal:buildvirtualraster")
                        (params . (("INPUT" existing . ,inputs)
                                   ("RESOLUTION" . 0) ("SEPARATE" . false)
                                   ("OUTPUT" . ,vrt))))
                       ((algorithm . "grass:r.watershed")
                        (params . (("elevation" . ,vrt) ("threshold" . ,threshold)
                                   ("-s" . true) ("-m" . true)
                                   ("basin" . ,basins) ("GRASS_REGION_CELLSIZE_PARAMETER" . 0))))
                       ((algorithm . "grass:r.to.vect")
                        (params . (("input" . ,basins) ("type" . 2) ("-s" . true)
                                   ("output" . ,basins-vec))))
                       ((algorithm . "native:extractbylocation")
                        (params . (("INPUT" . ,basins-vec) ("PREDICATE" . 0)
                                   ("INTERSECT" . ,point) ("OUTPUT" . ,shed))))
                       ((algorithm . "native:simplifygeometries")
                        (params . (("INPUT" . ,shed) ("METHOD" . 0) ("TOLERANCE" . 0.002)
                                   ("OUTPUT" . ,simple))))
                       ((algorithm . "native:savefeatures")
                        (params . (("INPUT" . ,simple) ("OUTPUT" . ,geojson)
                                   ("LAYER_OPTIONS" . "RFC7946=YES")))))))))
           (write-pour-point! point id lon lat)
           (write-job! (string-append stage "/job.scm") job)
           (rename-file stage job-dir)
           (format #t "[watershed-job] queued ~a → ~a~%" job-dir geojson)))))
    (_ (format (current-error-port)
               "usage: watershed-job.scm <id> <lat> <lon> [radius-deg=1] [threshold-cells=20000]~%")
       (exit 1))))

(main (command-line))
