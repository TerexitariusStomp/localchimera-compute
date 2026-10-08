;;; refresh-priors.scm — fill the arc-time prior table from the local Valhalla.
;;;
;;; One sources_to_targets matrix call per manner over the given places, stamped
;;; with the engine's tileset version, written as the sexp prior file the
;;; planner loads (routing-load-priors → #:arc-table). Run when the place-set
;;; changes or after a tile/GTFS rebuild — never on the solve path.
;;;
;;;   guile module/playnet/planner/solve/refresh-priors.scm \
;;;     [--path data/routing/priors.sexp] [--manners pedestrian,bicycle,auto] \
;;;     depot=42.6977,23.3219 clinic=42.6506,23.3792 …
;;;
;;; Places may also come from a file of (name . (lat . lon)) pairs via
;;; --places-file (the shape ingest-located! sees), so a live deployment can
;;; export its SpatialThings and refresh in one move.

(define-module (playnet planner solve refresh-priors)
  #:use-module (playnet planner solve routing)
  #:use-module (ice-9 format)
  #:export (parse-place opt-value))

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve routing))

(define (parse-place s)                       ; "name=lat,lng" → (name . (lat . lon))
  (let* ((eq (string-index s #\=))
         (cm (and eq (string-index s #\, eq))))
    (and eq cm
         (let ((lat (string->number (substring s (+ eq 1) cm)))
               (lon (string->number (substring s (+ cm 1)))))
           (and lat lon (cons (substring s 0 eq) (cons lat lon)))))))

(define (opt-value args flag default)
  (let ((p (member flag args)))
    (if (and p (pair? (cdr p))) (cadr p) default)))

(let* ((args     (cdr (command-line)))
       (path     (opt-value args "--path" "data/routing/priors.sexp"))
       (manners  (string-split (opt-value args "--manners" "pedestrian,bicycle,auto") #\,))
       (pfile    (opt-value args "--places-file" #f))
       (latlon   (append (if (and pfile (file-exists? pfile))
                             (call-with-input-file pfile read) '())
                         (filter-map parse-place args))))
  (cond
   ((null? latlon)
    (format #t "no places given — see the header for usage~%") (exit 1))
   ((not (valhalla-up?))
    (format #t "valhalla unreachable at ~a — engine down?~%" *valhalla-base*) (exit 1))
   (else
    (refresh-priors! (map car latlon) latlon manners #:path path
                     #:period-classes (period-class-date-times))
    (exit 0))))
