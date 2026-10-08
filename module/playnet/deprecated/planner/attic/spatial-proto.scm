;;; spatial-proto.scm — PROTOTYPE: the spatial-equilibrium convex core.
;;;
;;; Proving the math before the full state-model rewrite (relaxation.scm Phase 1).
;;; Spec: docs/playnet.typ §"Desire, possibility, and the resolving chord".
;;;
;;; THE CLAIM we are testing:
;;;   Recipes are placeless (ValueFlows: RecipeFlow/RecipeProcess carry no
;;;   location). Where to instantiate one is therefore a FREE VARIABLE. If we let
;;;   production-per-place be CONTINUOUS, the spatial allocation is a convex
;;;   problem → a single global optimum, and "site selection" falls out as the
;;;   continuous optimum (produce where located prices are lowest). No NP-hardness.
;;;
;;; CONTAINMENT is the one relation (SpatialThing.contained-in):
;;;   • location      = a resource contained-in a place
;;;   • transport     = move a container; nested contents move with it
;;;   • transformation= transfer a CONTAINED SUBSTANCE between resources
;;;                     (nutrient contained-in soil → contained-in carrot)
;;; A `grow` recipe consuming soil-nutrient and producing carrots is literally a
;;; containment-transfer of a CONSERVED substance. So the located ecological
;;; "cap" is the rate a soil-container yields its nutrient, and drawing it shows
;;; up as a rising located price λ(nutrient, that-soil).
;;;
;;; THE METABOLIC RIFT, for free: grow carrots in the country, eat them in the
;;; city, and the nutrient leaves the country soil and does not return. The
;;; located price λ(nutrient, country-soil) climbs — soil exhaustion as a price
;;; signal. A compost return-flow (city → country) relaxes it. We show both.
;;;
;;; Run:  guile -L module module/playnet/planner/spatial-proto.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner vf schemas))

;; ── the containment tree (real SpatialThing records) ────────────────────────
;; earth ⊃ {city, country}.  Soil-nutrient is a located resource: scarce under
;; the city (rooftop beds), plentiful in the country. A `grow` recipe (placeless)
;; can run wherever soil-nutrient is contained; carrots are demanded in the city.
(define earth   (make-spatial-thing #:id "earth"   #:name "Earth"  #:lat 0.0   #:long 0.0))
(define city    (make-spatial-thing #:id "city"    #:name "City" #:lat 40.00 #:long -74.00
                                    #:contained-in "earth"))   ; contained-in earth
(define country (make-spatial-thing #:id "country" #:name "Country" #:lat 41.00 #:long -74.00
                                    #:contained-in "earth"))   ; ~111 km north

;; great-circle km (mirrors matching/spatial.scm) — drives transport cost
(define (km a b)
  (let* ((d2r (/ 3.141592653589793 180.0))
         (la1 (* d2r (spatial-thing-lat a))) (la2 (* d2r (spatial-thing-lat b)))
         (dla (* d2r (- (spatial-thing-lat b) (spatial-thing-lat a))))
         (dlo (* d2r (- (spatial-thing-long b) (spatial-thing-long a))))
         (h (+ (expt (sin (/ dla 2)) 2)
               (* (cos la1) (cos la2) (expt (sin (/ dlo 2)) 2)))))
    (* 6371.0 2.0 (atan (sqrt h) (sqrt (- 1.0 h))))))

;; ── tensions (same shapes as the planner) ───────────────────────────────────
(define (barrier used cap) (if (>= used cap) 1e9 (* 4.0 (- (log (/ (- cap used) cap))))))
(define (bgrad   used cap) (if (>= used cap) 1e6 (/ 4.0 (- cap used))))   ; = located price λ

;; ── the convex spatial equilibrium ──────────────────────────────────────────
;; Decision: g_city, g_country ≥ 0 carrots grown in each place (CONTINUOUS).
;; Carrots reach the city = g_city + (g_country shipped).  Each carrot embodies
;; `nut` nutrient drawn from THAT place's soil and `lab` labour-hours there.
;; harmony = −[ desire-gap²·w                              (want carrots in city)
;;            + barrier(nutrient drawn, soil cap) per place (ecological, LOCATED)
;;            + barrier(labour used,  labour cap) per place (LOCATED)
;;            + transport tension · g_country ]            (move the container)
;; Concave in (g_city,g_country) ⇒ a unique global optimum, by preconditioned
;; projected-gradient ascent with backtracking (the planner's `relax`, in 2-D).
(define* (equilibrium #:key T w nut lab soil-city soil-country lab-city lab-country
                           transport-per-km (return-flow 0.0))
  (let* ((dist (km city country))
         (tau  (* transport-per-km dist))
         ;; a city→country compost return-flow returns nutrient to country soil,
         ;; effectively widening its cap (closing the metabolic loop)
         (soil-country* (+ soil-country return-flow))
         (gap   (lambda (gc gk) (max 0.0 (/ (- T (+ gc gk)) T))))
         (harm  (lambda (gc gk)
                  (- 0.0
                     (* w (expt (gap gc gk) 2))
                     (barrier (* gc nut) soil-city) (barrier (* gk nut) soil-country*)
                     (barrier (* gc lab) lab-city)  (barrier (* gk lab) lab-country)
                     (* tau gk))))
         ;; ∂harmony/∂g_place: desire pull − local nutrient price − local labour price (− transport for country)
         (dC (lambda (gc gk) (- (/ (* 2.0 w (gap gc gk)) T)
                                (* nut (bgrad (* gc nut) soil-city))
                                (* lab (bgrad (* gc lab) lab-city)))))
         (dK (lambda (gc gk) (- (/ (* 2.0 w (gap gc gk)) T)
                                (* nut (bgrad (* gk nut) soil-country*))
                                (* lab (bgrad (* gk lab) lab-country))
                                tau)))
         (precond (/ (* 2.0 w) (* T T))))           ; desire curvature → steps in carrot units
    (let loop ((gc 0.0) (gk 0.0) (i 0))
      (if (>= i 4000)
          (values gc gk gap harm dist tau soil-country*)
          (let ((h0 (harm gc gk))
                (sC (/ (dC gc gk) precond)) (sK (/ (dK gc gk) precond)))
            (let ls ((eta 1.0))
              (let ((gc* (max 0.0 (+ gc (* eta sC)))) (gk* (max 0.0 (+ gk (* eta sK)))))
                (cond ((> (harm gc* gk*) (+ h0 1e-12)) (loop gc* gk* (+ i 1)))
                      ((< eta 1e-9) (values gc gk gap harm dist tau soil-country*))
                      (else (ls (* eta 0.5)))))))))))

(define (run label . args)
  (call-with-values (lambda () (apply equilibrium args))
    (lambda (gc gk gap harm dist tau soilK*)
      (let* ((nut (car (cdr (memq #:nut args))))
             (T   (car (cdr (memq #:T args))))
             (soilC (car (cdr (memq #:soil-city args))))
             (delivered (+ gc gk)))
        (format #t "~%-- ~a~%" label)
        (format #t "   grow:  city ~5,1f   country ~5,1f   (transport ~5,1f over ~,0f km)~%"
                gc gk gk dist)
        (format #t "   carrots delivered to city ~5,1f / ~a   (gap ~,2f)~%"
                delivered T (gap gc gk))
        (format #t "   nutrient drawn:  city ~5,1f/~a   country ~5,1f/~,1f~%"
                (* gc nut) soilC (* gk nut) soilK*)
        (format #t "   price(nutrient): city ~6,2f   country ~6,2f   <- located price / exhaustion signal~%"
                (bgrad (* gc nut) soilC) (bgrad (* gk nut) soilK*))
        ;; conservation: nutrient embodied in delivered carrots = nutrient drawn
        (format #t "   conserved: drawn ~,1f  =  embodied in ~,1f carrots x ~a~%"
                (* delivered nut) delivered nut)))))

(format #t "~%==== spatial equilibrium: where to grow the carrots? ====~%")
(format #t "city demands 100 carrots. soil-nutrient is scarce under the city,~%")
(format #t "plentiful in the country. growing draws nutrient (conserved into carrots).~%")

;; common parameters
(define base (list #:T 100 #:w 1000 #:nut 1.0 #:lab 1.0
                   #:soil-city 30 #:soil-country 300
                   #:lab-city 200 #:lab-country 200))

(apply run "cheap transport -> grow in the country, ship to the city (site = country)"
       (append base (list #:transport-per-km 0.003)))     ; ~0.33 tension over 111 km

(apply run "dear transport -> grow in the city despite scarce soil (site = city)"
       (append base (list #:transport-per-km 0.05)))       ; ~5.5 tension over 111 km

(apply run "METABOLIC RIFT: country feeds the city, soil drains -> price(country) climbs"
       (list #:T 100 #:w 1000 #:nut 1.0 #:lab 1.0
             #:soil-city 30 #:soil-country 110            ; country soil now tight
             #:lab-city 200 #:lab-country 200 #:transport-per-km 0.003))

(apply run "...close the loop: a city->country compost return-flow relaxes the soil"
       (list #:T 100 #:w 1000 #:nut 1.0 #:lab 1.0
             #:soil-city 30 #:soil-country 110
             #:lab-city 200 #:lab-country 200 #:transport-per-km 0.003
             #:return-flow 80))                            ; compost returns nutrient to country soil
(newline)
