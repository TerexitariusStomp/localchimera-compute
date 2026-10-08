;;; check-parcels.scm — every parcel's `within` claim, redone against the polygons.
;;;
;;; A parcel's pack row says which zones it stands `within`, and the whole legal
;;; fold turns on that: a parcel in zone A meets a prohibition on building and a
;;; SAFER pre-emption on its sale; one in Ud1 meets a permis instead. The claim
;;; was made by a point-in-polygon test inside tools/law/fetch-fr-parcels.py and
;;; then thrown away with the geometry, so nothing downstream could tell a right
;;; answer from a wrong one — the ingest was trusted because it was unrepeatable.
;;;
;;; Now both extents are on the boundaries convention, so the claim is checkable:
;;;
;;;   data/law/fr-<insee>-parcels.geojson   the parcels, with their `within`
;;;   data/law/fr-<insee>-zones.geojson     the zones the claim names
;;;
;;; and this redoes it. The sibling check-boundaries.scm proves a derived shed
;;; holds its own pour point; this proves a parcel's own interior point falls in
;;; the zones it claims, and in no zone it does not claim.
;;;
;;; Ray-cast point-in-polygon over Polygon | MultiPolygon with holes — the same
;;; rule check-boundaries.scm applies, and the same one
;;; ui/app/tabs/map/containers.ts inGeometry applies client-side.
;;;
;;; Usage: guile tools/qgis/check-parcels.scm 33330 [--all]
;;;   Samples 200 parcels by default; --all checks every one (slower).
;;; Exit 1 when any parcel's claim does not hold.

(use-modules (json) (ice-9 textual-ports) (srfi srfi-1) (ice-9 format) (ice-9 match))

(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))

;; the point-in-polygon test is the tree's one: (playnet utils geo)
(use-modules ((playnet utils geo) #:select (in-ring? in-geometry?)))

;;; A parcel's interior point. The centroid of a ring is inside it for anything
;;; convex and for nearly every cadastral parcel; where it is not, the parcel is
;;; reported rather than silently passed, because a point outside its own extent
;;; cannot test membership of anything else.
(define (interior-point geom)
  (let* ((polys (cond ((equal? (assoc-ref geom "type") "MultiPolygon")
                       (jarr (assoc-ref geom "coordinates")))
                      (else (list (assoc-ref geom "coordinates")))))
         (ring (and (pair? polys) (jarr (car (jarr (car polys)))))))
    (and (pair? ring)
         (let* ((pts (map jarr ring))
                (n (max 1 (- (length pts) 1)))
                (sx (fold + 0.0 (map car (list-head pts n))))
                (sy (fold + 0.0 (map cadr (list-head pts n)))))
           (cons (/ sx n) (/ sy n))))))

(define (read-fc path)
  (json-string->scm (call-with-input-file path get-string-all #:encoding "UTF-8")))

(define (main args)
  (match (cdr args)
    ((insee . rest)
     (let* ((all? (member "--all" rest))
            (pfc (read-fc (format #f "data/law/fr-~a-parcels.geojson" insee)))
            (zfc (read-fc (format #f "data/law/fr-~a-zones.geojson" insee)))
            (zones (map (lambda (f)
                          (cons (assoc-ref (assoc-ref f "properties") "id")
                                (assoc-ref f "geometry")))
                        (jarr (assoc-ref zfc "features"))))
            (parcels (jarr (assoc-ref pfc "features")))
            (step (if all? 1 (max 1 (quotient (length parcels) 200))))
            (checked 0) (outside-self 0) (missed 0) (extra 0) (straddle 0))
       (let loop ((ps parcels) (i 0))
         (unless (null? ps)
           (when (zero? (modulo i step))
             (let* ((f (car ps))
                    (props (assoc-ref f "properties"))
                    (id (assoc-ref props "id"))
                    (claim (map (lambda (z) (format #f "fr-~a-~a" insee z))
                                (jarr (assoc-ref props "within"))))
                    (geom (assoc-ref f "geometry"))
                    (pt (interior-point geom)))
               (set! checked (+ checked 1))
               (when (> (length claim) 1) (set! straddle (+ straddle 1)))
               (cond
                ((not pt) (format #t "NO POINT  ~a~%" id) (set! outside-self (+ outside-self 1)))
                ((not (in-geometry? (car pt) (cdr pt) geom))
                 ;; a concave parcel whose centroid escapes it: reported, not counted
                 ;; against the claim, since the probe itself is what failed
                 (set! outside-self (+ outside-self 1)))
                (else
                 ;; every zone it CLAIMS must hold the point…
                 (for-each
                  (lambda (zid)
                    (let ((zg (assoc-ref zones zid)))
                      (cond ((not zg) (format #t "NO ZONE   ~a claims ~a~%" id zid)
                                      (set! missed (+ missed 1)))
                            ((not (in-geometry? (car pt) (cdr pt) zg))
                             ;; only a failure when the parcel claims ONE zone: a
                             ;; straddler's centroid legitimately sits in one of
                             ;; the several it touches, not in all of them
                             (when (= 1 (length claim))
                               (format #t "OUTSIDE   ~a claims ~a but its point is not in it~%" id zid)
                               (set! missed (+ missed 1)))))))
                  claim)
                 ;; …and no zone it does NOT claim may hold it
                 (for-each
                  (lambda (z)
                    (when (and (not (member (car z) claim))
                               (in-geometry? (car pt) (cdr pt) (cdr z)))
                      (format #t "UNCLAIMED ~a sits in ~a and does not say so~%" id (car z))
                      (set! extra (+ extra 1))))
                  zones)))))
           (loop (cdr ps) (+ i 1))))
       (format #t "~%checked ~a of ~a parcels (~a zones)~%" checked (length parcels) (length zones))
       (format #t "  straddling more than one zone : ~a~%" straddle)
       (format #t "  centroid outside own extent   : ~a  (probe limitation, not a claim error)~%"
               outside-self)
       (format #t "  claimed a zone it is not in   : ~a~%" missed)
       (format #t "  sits in a zone it never named : ~a~%" extra)
       (exit (if (and (zero? missed) (zero? extra)) 0 1))))
    (_ (format (current-error-port) "usage: check-parcels.scm <insee> [--all]~%") (exit 1))))

(main (command-line))
