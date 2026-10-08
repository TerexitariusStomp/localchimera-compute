;;; tools/qgis/check-boundaries.scm — every bioregion polygon holds its own point.
;;;
;;; The proof that a derived watershed is the RIGHT basin: the bioregion's
;;; registered lat/lon (its pour point, the coordinate a scope placed there
;;; carries) falls inside the polygon boundaries.json now carries for it.
;;; Ray-cast point-in-polygon over Polygon | MultiPolygon with holes — the
;;; same rule ui/app/tabs/map/containers.ts inGeometry applies client-side.
;;;
;;; Usage: guile tools/qgis/check-boundaries.scm [browser/data/geo/boundaries.json]
;;; Exit 1 when any seeded shed is missing a polygon or lies outside it.

(use-modules (json) (ice-9 textual-ports) (srfi srfi-1) (ice-9 format))

;; id → (lon . lat): the pour points all-watersheds.sh queues, which are the
;; bioregions' own coordinates in knowledge/<id>.scm.
(define %sheds
  '(("berlin"    . (13.40 . 52.52))
    ("bay-area"  . (-122.42 . 37.77))
    ("cascadia"  . (-123.00 . 45.00))
    ("doon-shed" . (78.03 . 30.32))))

(define (jarr x) (cond ((vector? x) (vector->list x)) ((list? x) x) (else '())))

;; the point-in-polygon test is the tree's one: (playnet utils geo)
(use-modules ((playnet utils geo) #:select (in-ring? in-geometry?)))

(define (main args)
  (let* ((path (if (pair? (cdr args)) (cadr args) "browser/data/geo/boundaries.json"))
         (fc   (json-string->scm (call-with-input-file path get-string-all #:encoding "UTF-8")))
         (feats (jarr (assoc-ref fc "features")))
         (by-id (map (lambda (f) (cons (assoc-ref (assoc-ref f "properties") "id") f)) feats))
         (bad 0))
    (for-each
     (lambda (shed)
       (let* ((id (car shed)) (lng (cadr shed)) (lat (cddr shed))
              (f  (assoc-ref by-id id)))
         (cond
          ((not f) (format #t "MISSING  ~a~%" id) (set! bad (+ bad 1)))
          ((in-geometry? lng lat (assoc-ref f "geometry"))
           (format #t "inside   ~a (~a, ~a) ~a~%" id lat lng
                   (if (assoc-ref (assoc-ref f "properties") "derivation") "[derived]" "[hand-drawn]")))
          (else (format #t "OUTSIDE  ~a (~a, ~a)~%" id lat lng) (set! bad (+ bad 1))))))
     %sheds)
    (exit (if (zero? bad) 0 1))))

(main (command-line))
