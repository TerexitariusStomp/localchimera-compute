;;; test-sky-reading-live.scm — a reading replaces the estimate, by the one door.
;;;
;;; The shine states the light a hectare receives as an ESTIMATE (catalogues/substances.scm
;;; insolation-kwh-per-m2-day). A scope that measures its own sun logs a reading
;;; of the shine's produce, and the solve takes it as it takes every reading of a
;;; process against its nominal (solve/robust.scm observed-shocks: an output reads no
;;; better than the map): the light bound tightens to what was seen, and a hectare
;;; grows less. Nothing new is built for it — the estimate is the nominal, and a
;;; reading is a contrary observation (docs/observation/physics.md §6).
;;;
;;; Run:  guile -q -L module tests/scope/test-sky-reading-live.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (playnet vf schemas)
             (playnet knowledge dsl shorthand) (playnet knowledge dsl world)
             ((playnet knowledge catalogues substances) #:select (sunlight-for insolation-kwh-per-m2-day area-m2))
             ((playnet scope live) #:select (plan-scope))
             (goblins) (srfi srfi-1))

(define PLACE "field")
(define win (all-week-window "06:00" "18:00"))

(define (farm)
  "A hectare under the June sun at 52.5° north, soil and a farmer: grain bounded by the light."
  (world-sky
   (world #:specs (list (spec* "land" "Land" "ha" #:keep-in-place #t) (spec* "soil-n" "Soil N" "kg")
                        (spec* "grain" "Grain" "kg") (spec* "skill-farm" "Farm labour" %effort-unit))
          #:procs (list (rp* "grow" "Grow" 1.0))
          #:flows (list (consume* "g1" "soil-n" 0.05 "grow") (out* "g2" "grain" 1.0 "grow") (wk* "g3" "skill-farm" 0.001 "grow"))
          #:recipes (list (make-recipe #:id "r-grow" #:name "Grain" #:primary-output "grain"
                                       #:recipe-processes '("grow")))
          #:spatials (list (place* PLACE))
          #:agents (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
          #:resources (list (er "sn" "soil-n" #f #:place PLACE #:qty 1.0e6 #:unit "kg")
                            ;; the ground's other two stores the harvest roots in (world.scm world-rooted), ample: the light bounds
                            (er "sp" "soil-p" #f #:place PLACE #:qty 1.0e6 #:unit "kg") (er "sk" "soil-k" #f #:place PLACE #:qty 1.0e6 #:unit "kg")
                            (er "field" "land" #f #:place PLACE #:qty 1.0 #:unit "ha")
                            (er "skill-farm:ada" "skill-farm" "ada" #:place PLACE)))
   #:lat 52.5 #:month 6))

(define NOMINAL (* (insolation-kwh-per-m2-day 52.5 6) (area-m2 "ha")))   ; the shine's kWh a day, the estimate
(define BOUND (/ NOMINAL (sunlight-for "grain" 1.0)))                   ; kg of grain that light stores

(define (grain-grown observed)
  (with-vat (spawn-vat)
    (let ((root (spawn-scope-root "farm")))
      (seed-world! root (farm))
      (call-with-values
        (lambda () (plan-scope root #:reproduce? #f #:demand (list (cons (format #f "grain#~a@0" PLACE) 1.0e6))
                               #:periods '(0) #:backend 'native-c #:allow-infeasible? #t #:observed observed))
        (lambda (ints coms material fill x ntot report)
          (* fill 1.0e6))))))                  ; the share of a million kilograms asked: the kilograms grown

(display "\n── the estimate stands until a reading arrives ──\n")
(define estimated (grain-grown '()))
(define seen-half (grain-grown (list (list "shine~land" 'produce NOMINAL (* 0.5 NOMINAL)))))
(define seen-more (grain-grown (list (list "shine~land" 'produce NOMINAL (* 2.0 NOMINAL)))))
(format #t "  light bound ~,1f kg · grown on the estimate ~,1f · on a reading of half the light ~,1f · on a reading of twice ~,1f~%"
        BOUND estimated seen-half seen-more)
(check-pred "on the estimate a hectare grows near its light bound" (and (> estimated (* 0.9 BOUND)) (<= estimated (* 1.001 BOUND))))
(check-pred "a reading of half the light halves the harvest: the estimate is the nominal, the reading tightens it"
            (and (> seen-half (* 0.45 BOUND)) (< seen-half (* 0.55 BOUND))))
(check-pred "a reading of more light than the estimate moves nothing: an output reads no better than the map"
            (< (abs (- seen-more estimated)) (* 0.01 BOUND)))

(test-summary!)
