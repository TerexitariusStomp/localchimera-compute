;;; process-eco.scm — a bioregion's LOCAL soil-fertility state from vendored SoilGrids.
;;; GENERAL: any raw/<label>/soil-eco.json. Reproducible: same raw ⇒ same out. Guile-native.
;;;
;;;   guile process-eco.scm [SOIL_JSON]
;;;
;;; Emits the 0–30 cm depth-weighted means. Topsoil ORGANIC CARBON is the state
;;; variable of the soil-carbon fragility: a *frag-container* on the shed's `topsoil`
;;; spec placed so draw-down (tillage/erosion mining SOC) is felt before the tip.
;;; Planetary-boundary analogue: land-system change / soil health.

(use-modules ((json parser) #:select (json-string->scm))
             ((ice-9 textual-ports) #:select (get-string-all))
             (ice-9 format))

(define path (let ((a (cdr (command-line)))) (if (pair? a) (car a) "raw/doon/soil-eco.json")))
(define d (json-string->scm (call-with-input-file path get-string-all)))
(define layers
  (let ((props (assoc-ref d "properties")))
    (or (and props (assoc-ref props "layers"))
        (begin (format (current-error-port)
                       "~a: empty or not SoilGrids JSON (a throttled/failed fetch?) — ~
                        re-run fetch-eco.sh; SoilGrids rate-limits, so give it a minute.~%" path)
               (exit 1)))))

;; depth thickness weights (cm) for a 0–30 cm mean
(define W '(("0-5cm" . 5.0) ("5-15cm" . 10.0) ("15-30cm" . 15.0)))
;; SoilGrids mapped units → conventional: soc dg/kg→g/kg (/10); N cg/kg→g/kg (/100); phh2o pH*10→pH (/10)
(define CONV '(("soc" 0.1 "g/kg SOC") ("nitrogen" 0.01 "g/kg N") ("phh2o" 0.1 "pH")))

(format #t "[~a] local soil state, 0–30 cm depth-weighted (SoilGrids v2.0):~%" path)
(for-each
 (lambda (L)
   (let ((name (assoc-ref L "name")))
     (let loop ((deps (vector->list (assoc-ref L "depths"))) (num 0.0) (den 0.0))
       (if (null? deps)
           (if (= den 0.0)
               (format #t "  ~a: null (masked cell — move LAT/LON to tilled ground, sources.md §eco)~%" name)
               (let ((c (or (assoc-ref CONV name) '(1.0 ""))))
                 (format #t "  ~a: ~,2f ~a~%" name (* (/ num den) (car c)) (cadr c))))
           (let* ((dep (car deps))
                  (v (assoc-ref (assoc-ref dep "values") "mean"))
                  (w (or (assoc-ref W (assoc-ref dep "label")) 0.0)))
             (if (and (number? v) (not (nan? v)))
                 (loop (cdr deps) (+ num (* v w)) (+ den w))
                 (loop (cdr deps) num den)))))))
 (vector->list layers))
(format #t "→ the shed's soil-carbon fragility state (a *frag-container* on `topsoil`).~%")
