;;; tools/qgis/catchment-job.scm — the TRUE upstream catchment above a point.
;;;
;;; grass:r.watershed's `basin` output (what watershed-job.scm uses) tiles
;;; the whole DEM into local sub-basins at roughly THRESHOLD cells each —
;;; the shed immediately around a point, not everything that drains through
;;; it. A river's real catchment (the whole Willamette above Salem, say) can
;;; be far larger than any one of those tiles. This script derives that
;;; instead, via grass:r.water.outlet — the correct tool, whose one extra
;;; requirement is an outlet point already ON the stream network (an
;;; unsnapped lat/lon a few cells off-channel gives a near-empty catchment).
;;;
;;; For one bioregion (id, pour-point lat/lon, tile radius) this writes ONE
;;; qgis-runner job under <qgis-dir>/jobs/<id>-catchment/ that chains:
;;;   gdal:buildvirtualraster    → one mosaic VRT over the DEM tiles present
;;;   grass:r.watershed          → accumulation + drainage-direction rasters
;;;   grass:r.mapcalc.simple     → streams = accumulation > STREAM-THRESHOLD
;;;   grass:r.to.vect            → the stream cells as points
;;;   grass:v.distance           → nearest stream point to the pour point,
;;;                                 uploading its (to_x, to_y) as attributes
;;;                                 (v.distance UPDATEs existing columns,
;;;                                 never creates them, so the pour point's
;;;                                 own GeoJSON pre-declares snap_x/snap_y
;;;                                 as dummy numbers for it to overwrite)
;;;   [extract]                  → SNAP_X, SNAP_Y bound from that vector
;;;   grass:r.water.outlet       → the catchment raster above (SNAP_X, SNAP_Y),
;;;                                 via (join "," (var …) (var …)) — the
;;;                                 runner reads the snapped coordinate
;;;                                 straight out of the prior step's own
;;;                                 output, no round-trip through this script
;;;   grass:r.to.vect            → vector catchment (GRASS drops the raster's
;;;                                 uncategorized null background on export —
;;;                                 the catchment is the ONLY feature; unlike
;;;                                 watershed-job.scm's basin=, which tiles
;;;                                 the whole DEM and needs a pick-by-point
;;;                                 filter, r.water.outlet's raster already
;;;                                 has nothing else in it)
;;;   native:simplifygeometries  → web-weight outline
;;;   native:savefeatures        → out/<id>-catchment.geojson (EPSG:4326)
;;;
;;; STREAM-THRESHOLD (accumulation cells) sets what counts as "on the
;;; stream network" for snapping — coarser than watershed-job's basin
;;; THRESHOLD is usually right: a stream is a much smaller commitment than
;;; a whole basin.
;;;
;;; The job and its pour-point.geojson are built as Scheme/JSON DATA and
;;; written with `write`/scm->json-string — see watershed-job.scm's header
;;; for why that beats assembling job.scm as text a shell splices together.
;;;
;;; Usage:
;;;   guile --no-auto-compile tools/qgis/catchment-job.scm \
;;;     <id> <lat> <lon> [radius-deg=1] [stream-threshold=1000]
;;;   QGIS_DIR   spool root (default /var/lib/playnet/qgis)

(use-modules (ice-9 match) (ice-9 format) (ice-9 textual-ports) (json) (srfi srfi-11))
(load (string-append (dirname (current-filename)) "/lib-dem-tiles.scm"))

(define (mkdir-p! path) (system* "mkdir" "-p" path))

(define (write-job! path job)
  (call-with-output-file path
    (lambda (port) (write job port) (newline port))))

;; snap_x/snap_y: dummy numeric properties for v.distance's `column=` to
;; UPDATE (see the v.distance step comment above) — real values overwritten
;; once it runs.
(define (write-pour-point! path id lon lat)
  (call-with-output-file path
    (lambda (port)
      (put-string port
       (scm->json-string
        `(("type" . "FeatureCollection")
          ("features"
           . #((("type" . "Feature")
                ("properties" . (("id" . ,id) ("snap_x" . 0.0) ("snap_y" . 0.0)))
                ("geometry" . (("type" . "Point") ("coordinates" . #(,lon ,lat)))))))))))))

(define (main args)
  (match args
    ((_ id lat-s lon-s . rest)
     (let* ((lat              (string->number lat-s))
            (lon              (string->number lon-s))
            (radius           (if (pair? rest) (string->number (car rest)) 1))
            (stream-threshold (if (and (pair? rest) (pair? (cdr rest))) (string->number (cadr rest)) 1000))
            (qgis-dir         (or (getenv "QGIS_DIR") "/var/lib/playnet/qgis"))
            (dem              (string-append qgis-dir "/data/dem"))
            (out              (string-append qgis-dir "/out"))
            (work             (string-append out "/" id "-catchment"))
            (stage            (string-append qgis-dir "/stage/" id "-catchment"))
            (job-dir          (string-append qgis-dir "/jobs/" id "-catchment")))
       (for-each mkdir-p! (list dem out work stage (string-append qgis-dir "/jobs")))
       (let*-values (((fetch inputs) (dem-tile-set lat lon radius dem)))
         (let* ((vrt          (string-append work "/dem.vrt"))
                (accum        (string-append work "/accum.tif"))
                (drain        (string-append work "/drain.tif"))
                (streams      (string-append work "/streams.tif"))
                (stream-pts   (string-append work "/stream-pts.gpkg"))
                (point        (string-append work "/pour-point.geojson"))
                (snap         (string-append work "/snap.gpkg"))
                (snap-nearest (string-append work "/snap-nearest.gpkg"))
                (snap-geojson (string-append work "/snap.geojson"))
                (basin        (string-append work "/catchment.tif"))
                (basin-vec    (string-append work "/catchment.gpkg"))
                (simple       (string-append work "/catchment-simple.gpkg"))
                (geojson      (string-append out "/" id "-catchment.geojson"))
                (job
                 `((id . ,id)
                   (fetch . ,fetch)
                   (steps
                    . (((algorithm . "gdal:buildvirtualraster")
                        (params . (("INPUT" existing . ,inputs)
                                   ("RESOLUTION" . 0) ("SEPARATE" . false)
                                   ("OUTPUT" . ,vrt))))
                       ((algorithm . "grass:r.watershed")
                        (params . (("elevation" . ,vrt) ("-a" . true) ("-s" . true) ("-m" . true)
                                   ("accumulation" . ,accum) ("drainage" . ,drain)
                                   ("GRASS_REGION_CELLSIZE_PARAMETER" . 0))))
                       ((algorithm . "grass:r.mapcalc.simple")
                        (params . (("a" . ,accum)
                                   ("expression" . ,(format #f "if(A>~a,1,null())" stream-threshold))
                                   ("output" . ,streams))))
                       ((algorithm . "grass:r.to.vect")
                        (params . (("input" . ,streams) ("type" . 1)
                                   ("output" . ,stream-pts))))
                       ((algorithm . "grass:v.distance")
                        (params . (("from" . ,point) ("to" . ,stream-pts)
                                   ("upload" . "2,3") ("column" . "snap_x;snap_y")
                                   ("output" . ,snap) ("from_output" . ,snap-nearest))))
                       ((algorithm . "native:savefeatures")
                        (params . (("INPUT" . ,snap-nearest) ("OUTPUT" . ,snap-geojson))))
                       ((extract . ((from . ,snap-geojson)
                                    (fields . (("snap_x" . "SNAP_X") ("snap_y" . "SNAP_Y"))))))
                       ((algorithm . "grass:r.water.outlet")
                        (params . (("input" . ,drain)
                                   ("coordinates" . (join "," (var "SNAP_X") (var "SNAP_Y")))
                                   ("output" . ,basin))))
                       ((algorithm . "grass:r.to.vect")
                        (params . (("input" . ,basin) ("type" . 2) ("-s" . true)
                                   ("output" . ,basin-vec))))
                       ((algorithm . "native:simplifygeometries")
                        (params . (("INPUT" . ,basin-vec) ("METHOD" . 0) ("TOLERANCE" . 0.002)
                                   ("OUTPUT" . ,simple))))
                       ((algorithm . "native:savefeatures")
                        (params . (("INPUT" . ,simple) ("OUTPUT" . ,geojson)
                                   ("LAYER_OPTIONS" . "RFC7946=YES")))))))))
           (write-pour-point! point id lon lat)
           (write-job! (string-append stage "/job.scm") job)
           (rename-file stage job-dir)
           (format #t "[catchment-job] queued ~a → ~a~%" job-dir geojson)))))
    (_ (format (current-error-port)
               "usage: catchment-job.scm <id> <lat> <lon> [radius-deg=1] [stream-threshold=1000]~%")
       (exit 1))))

(main (command-line))
