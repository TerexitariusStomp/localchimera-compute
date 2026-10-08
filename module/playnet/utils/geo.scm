;;; geo.scm — a point, a polygon, and whether the one is in the other.
;;;
;;; The one ray-cast point-in-polygon the tree uses on the Scheme side: the
;;; boundary checks (tools/qgis/check-boundaries.scm, check-parcels.scm) and the
;;; lookup of the place a position stands in (knowledge/jurisdiction-at.scm).
;;; ui/app/tabs/map/containers.ts `inGeometry` applies the same rule in the
;;; browser. Geometry is GeoJSON as guile-json reads it: an alist with string
;;; keys, arrays as vectors (lists are taken too).
;;;
;;; `topojson-features` reads the other form the tree ships its outlines in
;;; (browser/data/geo/*.json): TopoJSON, whose shared arcs are delta-encoded
;;; integers. It yields the same GeoJSON geometry, so one test serves both.

(define-module (playnet utils geo)
  #:use-module (srfi srfi-1)
  #:export (in-ring? in-geometry? topojson-features))

(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))

;;; RING : a closed list of (lng lat) positions. Even–odd rule.
(define (in-ring? lng lat ring)
  (let ((ring (jarr ring)))
    (and (pair? ring)
         (let loop ((ps ring) (prev (last ring)) (in #f))
           (if (null? ps) in
               (let* ((p (jarr (car ps))) (q (jarr prev))
                      (xi (car p)) (yi (cadr p)) (xj (car q)) (yj (cadr q)))
                 (loop (cdr ps) (car ps)
                       (if (and (not (eq? (> yi lat) (> yj lat)))
                                (< lng (+ (/ (* (- xj xi) (- lat yi)) (- yj yi)) xi)))
                           (not in) in))))))))

;;; GEOM : a GeoJSON Polygon or MultiPolygon. Inside a polygon is inside its
;;; outer ring and outside every hole.
(define (in-geometry? lng lat geom)
  (let ((polys (cond ((equal? (assoc-ref geom "type") "MultiPolygon")
                      (jarr (assoc-ref geom "coordinates")))
                     ((equal? (assoc-ref geom "type") "Polygon")
                      (list (assoc-ref geom "coordinates")))
                     (else '()))))
    (any (lambda (rings)
           (let ((rings (map jarr (jarr rings))))
             (and (pair? rings)
                  (in-ring? lng lat (car rings))
                  (not (any (lambda (h) (in-ring? lng lat h)) (cdr rings))))))
         polys)))

;;; ─── TopoJSON → GeoJSON geometry ─────────────────────────────────────────
;;; TOPO is a parsed TopoJSON topology; OBJECT names one of its objects (a
;;; GeometryCollection). → ((id . geometry) …), each geometry a GeoJSON Polygon
;;; or MultiPolygon alist with list coordinates. An arc is a run of positions,
;;; the first absolute and the rest deltas, in integers the topology's
;;; `transform` scales and translates; a ring names arcs by index, and a
;;; negative index ~i is arc i walked backwards.
(define (topojson-features topo object)
  (let* ((tr    (assoc-ref topo "transform"))
         (scale (and tr (jarr (assoc-ref tr "scale"))))
         (shift (and tr (jarr (assoc-ref tr "translate"))))
         (place (lambda (x y)
                  (if tr
                      (list (+ (* x (car scale)) (car shift)) (+ (* y (cadr scale)) (cadr shift)))
                      (list x y))))
         (arcs  (list->vector
                 (map (lambda (arc)
                        (let loop ((ps (jarr arc)) (x 0) (y 0) (acc '()))
                          (if (null? ps) (reverse acc)
                              (let* ((p (jarr (car ps)))
                                     (x (+ x (car p))) (y (+ y (cadr p))))
                                (loop (cdr ps) x y (cons (place x y) acc))))))
                      (jarr (assoc-ref topo "arcs")))))
         (arc   (lambda (i) (if (< i 0)
                                (reverse (vector-ref arcs (- (- i) 1)))
                                (vector-ref arcs i))))
         ;; consecutive arcs share their joining position: keep it once
         (ring  (lambda (indexes)
                  (let loop ((is (jarr indexes)) (acc '()))
                    (if (null? is) acc
                        (let ((ps (arc (car is))))
                          (loop (cdr is) (append acc (if (null? acc) ps (cdr ps)))))))))
         (polygon (lambda (rings) (map ring (jarr rings)))))
    (filter-map
     (lambda (g)
       (let ((type (assoc-ref g "type")) (id (assoc-ref g "id")))
         (cond ((equal? type "Polygon")
                (cons id `(("type" . "Polygon") ("coordinates" . ,(polygon (assoc-ref g "arcs"))))))
               ((equal? type "MultiPolygon")
                (cons id `(("type" . "MultiPolygon")
                           ("coordinates" . ,(map polygon (jarr (assoc-ref g "arcs")))))))
               (else #f))))
     (jarr (assoc-ref (assoc-ref (assoc-ref topo "objects") object) "geometries")))))
