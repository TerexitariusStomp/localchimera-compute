;;; matching/spatial.scm — Spatial indexing helpers.
;;;
;;; The matcher reads location data from VF <spatial-thing> records
;;; directly (carried on <intent-binding>.location). No denorms onto
;;; the criteria sidecar.
;;;
;;; Pure math (haversine, ring counts, resolution selection) needs no
;;; H3 backend. H3 cell operations dispatch through *h3-backend* —
;;; callers install a backend (FFI wrapper around h3-js in the browser,
;;; libh3 binding server-side, or a mock in tests). With no backend,
;;; cell ops degrade safely.

(define-module (playnet planner matching spatial)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner matching schemas)
  #:export (haversine-distance
            grid-rings-for-radius
            resolution-from-zoom
            resolution-from-density
            edge-length-km
            cell-area-km2

            *h3-backend*
            make-h3-backend
            h3-backend?

            location-remote?
            binding-remote?
            binding-h3-index
            get-cells-in-radius
            cells-compatible?))


;;; ── Pure math ──────────────────────────────────────────────────────────────

(define *earth-radius-km* 6371)
(define *pi* 3.141592653589793)

(define (deg->rad d) (/ (* d *pi*) 180))

(define (haversine-distance lat1 lng1 lat2 lng2)
  "Great-circle distance between two (lat, lng) pairs, in km."
  (let* ((d-lat (deg->rad (- lat2 lat1)))
         (d-lng (deg->rad (- lng2 lng1)))
         (sh-lat (sin (/ d-lat 2)))
         (sh-lng (sin (/ d-lng 2)))
         (a (+ (* sh-lat sh-lat)
               (* (cos (deg->rad lat1))
                  (cos (deg->rad lat2))
                  sh-lng sh-lng)))
         (c (* 2 (atan (sqrt a) (sqrt (- 1 a))))))
    (* *earth-radius-km* c)))

(define (edge-length-km r)
  (and (integer? r) (>= r 0) (<= r 15) (vector-ref *h3-edge-lengths-km* r)))

(define (cell-area-km2 r)
  (and (integer? r) (>= r 0) (<= r 15) (vector-ref *h3-areas-km2* r)))

(define (grid-rings-for-radius radius-km resolution)
  (let ((edge (edge-length-km resolution)))
    (if (and edge (> edge 0))
        (+ 1 (inexact->exact (ceiling (/ radius-km edge))))
        (error "Invalid H3 resolution" resolution))))

(define (resolution-from-zoom zoom)
  (cond ((< zoom 2)    0)  ((< zoom 3)    1)  ((< zoom 4.5)  2)
        ((< zoom 6)    3)  ((< zoom 7.5)  4)  ((< zoom 9)    5)
        ((< zoom 10.5) 6)  ((< zoom 12)   7)  ((< zoom 13.5) 8)
        ((< zoom 15)   9)  ((< zoom 16.5) 10) ((< zoom 18)   11)
        ((< zoom 20)   12) (else          13)))

(define (resolution-from-density density)
  (cond ((> density 100) 8) ((> density 10) 7) (else 6)))


;;; ── H3 backend ─────────────────────────────────────────────────────────────

(define-record-type <h3-backend>
  (make-h3-backend* lat-lng->cell get-resolution grid-disk
                    cell-to-parent cell-to-lat-lng grid-distance)
  h3-backend?
  (lat-lng->cell    h3-backend-lat-lng->cell)
  (get-resolution   h3-backend-get-resolution)
  (grid-disk        h3-backend-grid-disk)
  (cell-to-parent   h3-backend-cell-to-parent)
  (cell-to-lat-lng  h3-backend-cell-to-lat-lng)
  (grid-distance    h3-backend-grid-distance))

(define* (make-h3-backend #:key lat-lng->cell get-resolution grid-disk
                                cell-to-parent cell-to-lat-lng grid-distance)
  (make-h3-backend* lat-lng->cell get-resolution grid-disk
                    cell-to-parent cell-to-lat-lng grid-distance))

(define *h3-backend* (make-parameter #f))

(define (backend-op accessor)
  (let ((be (*h3-backend*))) (and be (accessor be))))


;;; ── Location helpers ──────────────────────────────────────────────────────
;;;
;;; A <spatial-thing> with no coordinates ⇒ "no specific physical
;;; location" ⇒ treat as remote for matching.  A criteria record with
;;; a non-empty online-link likewise indicates online/remote.

(define (location-remote? location)
  "True when a <spatial-thing> lacks usable coordinates (or is #f)."
  (or (not location)
      (not (spatial-thing-lat location))
      (not (spatial-thing-long location))))

(define (binding-online? b)
  (let ((c (intent-binding-criteria b)))
    (and c (let ((ol (intent-matching-criteria-online-link c)))
             (and ol (not (equal? ol "")))))))

(define (binding-remote? b)
  "True when intent-binding B represents a remote/online intent."
  (or (binding-online? b)
      (location-remote? (intent-binding-location b))))


;;; ── H3 cell operations ─────────────────────────────────────────────────────

(define* (binding-h3-index b #:optional resolution)
  "H3 cell id for binding B's location, or *remote-h3-index* when B
   is remote or no backend is installed. Pure — no caching."
  (cond
    ((binding-remote? b) *remote-h3-index*)
    (else
     (let* ((loc (intent-binding-location b))
            (c   (intent-binding-criteria b))
            (res (or resolution
                     (and c (intent-matching-criteria-h3-resolution c))
                     *default-h3-resolution*))
            (op  (backend-op h3-backend-lat-lng->cell)))
       (if op
           (op (spatial-thing-lat loc) (spatial-thing-long loc) res)
           *remote-h3-index*)))))

(define (get-cells-in-radius center-cell radius-km)
  "List of H3 cells covering RADIUS-KM around CENTER-CELL.
   With no backend installed, returns just the center cell."
  (cond
    ((equal? center-cell *remote-h3-index*) (list *remote-h3-index*))
    (else
     (let ((disk   (backend-op h3-backend-grid-disk))
           (res-of (backend-op h3-backend-get-resolution)))
       (if (and disk res-of)
           (disk center-cell (grid-rings-for-radius radius-km (res-of center-cell)))
           (list center-cell))))))

(define* (cells-compatible? cell1 cell2
                            #:optional (search-radius-km *default-search-radius-km*))
  "True when CELL1 and CELL2 are within SEARCH-RADIUS-KM.
   Remote cells match everywhere; with no backend, only equal cells match."
  (cond
    ((or (equal? cell1 *remote-h3-index*)
         (equal? cell2 *remote-h3-index*)
         (equal? cell1 cell2)) #t)
    (else
     (let ((res-of (backend-op h3-backend-get-resolution))
           (parent (backend-op h3-backend-cell-to-parent))
           (gdist  (backend-op h3-backend-grid-distance)))
       (and res-of parent gdist
            (let* ((coarser (min (res-of cell1) (res-of cell2)))
                   (p1 (if (= (res-of cell1) coarser) cell1 (parent cell1 coarser)))
                   (p2 (if (= (res-of cell2) coarser) cell2 (parent cell2 coarser))))
              (or (equal? p1 p2)
                  (let ((d (gdist p1 p2)))
                    (and d (<= d (grid-rings-for-radius search-radius-km
                                                        coarser)))))))))))
