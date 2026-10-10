;;; bay-area-commune-seed.scm — a Bay Area market-garden commune (SF, Oakland, …) as DATA
;;; over the generic seed-farm-commune! (farm-commune-seed.scm). The market-garden set with
;;; US-national yields, and a THREE-deep containment (biosphere ⊃ bay-area ⊃ city ⊃ garden)
;;; so each city is a nested subscope of the Bay. Water is the whole story: California's dry
;;; summers + over-allocated basins (Aqueduct 0.97) make a small water budget the binding
;;; constraint. Yields = *bay-area-derived-yields*; the test drift-checks them.

;; city → (lat . lon), for the SpatialThing under "bay-area".
(define-module (playnet knowledge recipes bay-area-commune-seed)
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge recipes farm-commune-seed)
  #:export (*bay-area-cities* bay-area-city-coord *bay-area-commune-crops*
            seed-bay-area-commune!))

(define *bay-area-cities*
  '(("san-francisco" . (37.77 . -122.42))
    ("oakland"       . (37.80 . -122.27))))
(define (bay-area-city-coord city) (or (assoc-ref *bay-area-cities* city) '(37.77 . -122.42)))

;; staple → (summer-water-ML/ha . yield-kg/ha). Mediterranean thirst: thirsty tomato/potato
;; vs frugaler legumes.
(define *bay-area-commune-crops*
  '(("tomato" . (4.5 . 97566.0))
    ("potato" . (3.6 . 50563.2))
    ("bean"   . (1.6 .  2222.7))
    ("pea"    . (1.4 .  1950.3))))

;; Seed a live Bay Area commune: the garden placed contained-in its city ⊂ "bay-area", so
;; the live solve inherits the Bay's Mediterranean drought futures + its EXTREME water limit.
(define* (seed-bay-area-commune! scope #:key (place "sf-garden") (city "san-francisco")
                                       (city-name "San Francisco") (shed "bay-area")
                                       (land-ha 1.0) (water 3.0) (labour-h 3.0))
  (let* ((coord (bay-area-city-coord city)) (clat (car coord)) (clon (cdr coord)))
    (seed-farm-commune! scope
      #:crops *bay-area-commune-crops* #:place place #:place-name (string-append city-name " market garden")
      #:lat clat #:lon clon #:parent city
      #:tree (list (make-spatial-thing #:id "biosphere" #:name "The biosphere" #:lat 0.0 #:long 0.0)
                   (make-spatial-thing #:id "usa" #:name "USA" #:lat 39.8 #:long -98.6
                                       #:contained-in "biosphere")
                   (make-spatial-thing #:id "california" #:name "California" #:lat 37.0
                                       #:long -120.0 #:contained-in "usa")
                   (make-spatial-thing #:id shed #:name "San Francisco Bay Area" #:lat 37.77
                                       #:long -122.42 #:contained-in "california")
                   (make-spatial-thing #:id city #:name city-name #:lat clat #:long clon
                                       #:contained-in shed))
      #:skill "gardening" #:skill-label "Garden labour" #:skill-hours 300.0
      #:worker-name "Gardener" #:commune-name (string-append city-name " commune")
      #:land-ha land-ha #:water water #:labour-h labour-h)))
