;;; tools/qgis/lib-dem-tiles.scm — the Copernicus GLO-90 DEM tile set for a
;;; pour point, shared by every job generator that needs elevation.
;;;
;;; `(dem-tile-set lat lon radius dem-dir)` returns two values: the job.scm
;;; `fetch` entries for every 1°×1° tile in the ±radius° box (each optional
;;; — a bucket has no ocean tiles), and the matching local paths for an
;;; `(existing ...)` param list. Both are Scheme DATA, not text a caller
;;; splices into source — a generator builds its job alist by consing this
;;; in, then `write`s the whole thing once, the same discipline the runner
;;; uses to `read` it back.
;;;
;;; Loaded, not executed: `(load (in-vicinity (dirname (current-filename))
;;; "lib-dem-tiles.scm"))` from a sibling generator script.

(use-modules (srfi srfi-1) (srfi srfi-13))

(define (dem-floor x) (inexact->exact (floor x)))

(define (dem-zero-pad n width) (string-pad (number->string n) width #\0))

(define (dem-tile-name lat lon)
  (string-append "Copernicus_DSM_COG_30_"
                 (if (>= lat 0) "N" "S") (dem-zero-pad (abs lat) 2) "_00_"
                 (if (>= lon 0) "E" "W") (dem-zero-pad (abs lon) 3) "_00_DEM"))

(define (dem-tile-set lat lon radius dem-dir)
  (let* ((la0 (dem-floor lat)) (lo0 (dem-floor lon))
         (offsets (iota (+ 1 (* 2 radius)) (- radius)))
         (tiles (append-map
                 (lambda (dla)
                   (map (lambda (dlo) (dem-tile-name (+ la0 dla) (+ lo0 dlo))) offsets))
                 offsets))
         (paths (map (lambda (t) (string-append dem-dir "/" t ".tif")) tiles)))
    (values
     (map (lambda (t f)
            `((url . ,(string-append "https://copernicus-dem-90m.s3.amazonaws.com/" t "/" t ".tif"))
              (to . ,f) (optional . #t)))
          tiles paths)
     paths)))
