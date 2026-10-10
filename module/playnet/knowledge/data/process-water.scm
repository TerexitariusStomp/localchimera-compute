;;; process-water.scm — a bioregion's WATER-RISK fragility state from vendored WRI
;;; Aqueduct (fetch-water.sh → water.json). GENERAL, reproducible. Baseline water stress
;;; (withdrawals/supply), seasonal + inter-annual variability (the salmon low-flow /
;;; rainfed signal), groundwater stress, overall risk — the real STATE behind the water
;;; fragility. Guile-native (guile-json), the planner's own language.
;;;
;;;   guile process-water.scm [WATER_JSON]

(use-modules ((json parser) #:select (json-string->scm))
             ((ice-9 textual-ports) #:select (get-string-all))
             (ice-9 format))

(define path (let ((a (cdr (command-line)))) (if (pair? a) (car a) "raw/doon/water.json")))
(define a (assoc-ref (vector-ref (assoc-ref (json-string->scm
                                             (call-with-input-file path get-string-all))
                                            "features") 0)
                     "attributes"))
(define (g k) (assoc-ref a k))
(define label (basename (dirname path)))

(format #t "[~a] WRI Aqueduct water risk (basin at the point):~%" label)
(format #t "  baseline water stress (withdrawals/supply): ~,2f  [~a]~%" (g "BWS") (g "BWS_cat"))
(format #t "  seasonal variability:      ~a~%" (g "SV_cat"))
(format #t "  inter-annual variability:  ~a~%" (g "WSV_cat"))
(format #t "  groundwater stress:        ~a~%" (g "GW_cat"))
(format #t "  drought severity:          ~a~%" (g "DRO_cat"))
(format #t "  OVERALL water risk:        ~a~%" (g "WRI_cat"))
(format #t "→ the water fragility STATE (baseline stress) + its seasonal-flow signal (salmon/summer).~%")
