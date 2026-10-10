;;; process-temp.scm — a bioregion's TEMPERATURE stressors (heat, frost, warming) from
;;; vendored daily temperature (fetch.sh → temp.json). The real STATE behind the
;;; heat/frost fragility + a driver of the scenario tail. GENERAL, reproducible.
;;; Guile-native (guile-json + SRFI) — the planner's own language, no Python.
;;;
;;;   guile process-temp.scm [TEMP_JSON]
;;;   guile process-temp.scm raw/doon/temp.json

(use-modules ((json parser) #:select (json-string->scm))
             ((ice-9 textual-ports) #:select (get-string-all))
             (ice-9 format) (srfi srfi-1))

(define path (let ((a (cdr (command-line)))) (if (pair? a) (car a) "raw/doon/temp.json")))

(define D (assoc-ref (json-string->scm (call-with-input-file path get-string-all)) "daily"))
(define (col k) (vector->list (assoc-ref D k)))
(define days (col "time"))
(define tmax (col "temperature_2m_max"))
(define tmin (col "temperature_2m_min"))
(define tmean (col "temperature_2m_mean"))
(define HOT 35.0) (define FROST 0.0) (define GDD-BASE 10.0)

(define (num? x) (and (number? x) (not (nan? x))))
(define (mean xs) (if (null? xs) 0.0 (/ (apply + xs) (length xs))))

;; year → #(hot-days frost-days gdd (mean-temps …)), one streaming pass.
(define yr (make-hash-table))
(for-each
 (lambda (t mx mn me)
   (let* ((y (string->number (substring t 0 4)))
          (r (or (hash-ref yr y) (let ((v (vector 0 0 0.0 '()))) (hash-set! yr y v) v))))
     (when (and (num? mx) (> mx HOT))   (vector-set! r 0 (+ 1 (vector-ref r 0))))
     (when (and (num? mn) (< mn FROST)) (vector-set! r 1 (+ 1 (vector-ref r 1))))
     (when (num? me)
       (vector-set! r 2 (+ (vector-ref r 2) (max 0.0 (- me GDD-BASE))))
       (vector-set! r 3 (cons me (vector-ref r 3))))))
 days tmax tmin tmean)

(define yrs (sort (filter-map (lambda (y) (and (pair? (vector-ref (hash-ref yr y) 3)) y))
                              (hash-map->list (lambda (k v) k) yr))
                  <))
(define (per i) (mean (map (lambda (y) (vector-ref (hash-ref yr y) i)) yrs)))
(define hot (per 0)) (define frost (per 1)) (define gdd (per 2))
(define (span-mean ys) (mean (append-map (lambda (y) (vector-ref (hash-ref yr y) 3)) ys)))
(define early  (span-mean (take yrs (min 10 (length yrs)))))
(define recent (span-mean (take-right yrs (min 10 (length yrs)))))
(define (signed x) (string-append (if (>= x 0) "+" "") (format #f "~,2f" x)))
(define label (basename (dirname path)))

(format #t "[~a] temperature stressors ~a–~a (ERA5):~%" label (car yrs) (last yrs))
(format #t "  heat-stress days/yr (Tmax>35°C): ~,1f~%" hot)
(format #t "  frost days/yr       (Tmin<0°C):  ~,1f~%" frost)
(format #t "  growing degree-days (base 10°C): ~a~%" (inexact->exact (round gdd)))
(format #t "  WARMING: mean daily temp ~a°C, last decade vs first (~,1f→~,1f°C)~%"
        (signed (- recent early)) early recent)
(format #t "→ the heat/frost fragility STATE + a driver of the precautionary tail.~%")
