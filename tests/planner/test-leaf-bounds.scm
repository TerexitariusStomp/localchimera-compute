;;; test-leaf-bounds.scm — a floor and a cap are both bounds on a LEAF.
;;;
;;; docs/observation/physics.md §6: the leaf registry (catalogues/substances.scm declare-leaf!)
;;; lists every substance a plan holds, and a need or a limit is a bound on one of
;;; them, read over the composition map. Two halves, one idea:
;;;
;;;   THE CAP    a fragility keyed on a leaf (engine.scm build-located `leaf-keys`)
;;;              reads the leaf DRAWN — every raw carrying it stresses it by its mass
;;;              fraction, the cascade's own shape derived from the composition map —
;;;              so a nitrogen boundary feels N however it enters. A cap on the spec
;;;              "soil-n" alone lets the same nitrogen in through a fertiliser.
;;;   THE FLOOR  a person's nutrient good carries from period to period when the body
;;;              stores that nutrient (catalogues/subsistence.scm reserve-nutrients →
;;;              live.scm scope-reserves): a store-shaped recipe that leaks
;;;              1 − e^(−p/τ) per period (catalogues/thermal.scm relaxation-records with no base
;;;              and no heat), the body an enclosure. A fat day feeds a lean one, and a
;;;              store of a day feeds nobody a week on.
;;;   THE LIGHT  where a world holds land, the land shines (world.scm world-sunlit):
;;;              a unit of land used through the period yields the light that falls on
;;;              it, and a grow that draws its light is bounded by the field.
;;;
;;; Run: guile -L module tests/planner/test-leaf-bounds.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format)
             (playnet planner solve engine) (playnet planner vf schemas) (playnet planner facts located)
             (playnet planner knowledge dsl shorthand) (playnet planner knowledge dsl world)
             ((playnet planner knowledge catalogues thermal) #:select (relaxation-records))
             ((playnet planner knowledge recipes farm-commune-seed) #:select ((farm-world . commune-farm-world)))   ; the suite's own farm-world is the hectare below
             ((playnet planner knowledge catalogues substances) #:select (sunlight-for water-for insolation-kwh-per-m2-day area-m2))
             ((playnet planner knowledge catalogues subsistence) #:select (reserve-nutrients)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PLACE "farm")
(define win (all-week-window "06:00" "18:00"))

;; ── the cap ────────────────────────────────────────────────────────────────────
;; grow: 1 kg soil-n (N 1.0) + 1 kg nh3-fert (N 0.82) → 50 kg grain (N 0.02): 1.82 kg
;; of N drawn per run, 1.0 embodied, the rest a loss the closure allows.
(define COMP '(("soil-n" ("N" . 1.0)) ("nh3-fert" ("N" . 0.82)) ("grain" ("N" . 0.02))))
(define (n-drawn col) (+ (* 1.0 col) (* 0.82 col)))     ; kg N per run of grow

(define* (grow-solve #:key (spec-frag #f) (budget '()) (soil-n-onhand 1000.0))
  ;; a frag-capped SPEC's onhand is read as its draw to date (the prior), so the
  ;; spec-capped run states a negligible prior; a leaf is no spec, and soil-n's
  ;; onhand is then the stock it is
  (call-with-values
    (lambda ()
      (plan-from-records
       (list (er "sn" "soil-n" #f #:place PLACE #:qty soil-n-onhand #:unit "kg")
             (er "nf" "nh3-fert" #f #:place PLACE #:qty 1000.0 #:unit "kg")
             (er "skill-farm:ada" "skill-farm" "ada"))
       (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
       (list (place* PLACE))
       (list (rp* "grow" "Grow"))
       (list (consume* "g1" "soil-n" 1.0 "grow") (consume* "g2" "nh3-fert" 1.0 "grow")
             (out* "g3" "grain" 50.0 "grow") (wk* "g4" "skill-farm" 0.1 "grow"))
       #:composition COMP
       #:demand (list (cons (format #f "grain#~a@0" PLACE) 1000.0))
       #:periods '(0) #:per-agent? #f #:backend 'native-c #:allow-infeasible? #t
       #:eco-spec-frag spec-frag #:eco-budget budget))
    (lambda (i c material fill cols x idx nt rep)
      (let ((j (hash-ref idx (format #f "p|grow|~a@0" PLACE) #f)))
        (if j (vector-ref x j) 0.0)))))

(define LO 10.0) (define HI 20.0) (define ALPHA 0.5)    ; the boundary's range, kg N per period
(define profile (list LO HI ALPHA 5.0))                 ; (lo hi alpha w)
(define TIP (+ LO (* ALPHA (- HI LO))))                 ; where the barrier stands in the range: 15

(format #t "~%── the cap: a leaf-keyed fragility reads N however it enters ──~%")
(let* ((free (grow-solve))
       (on-spec (grow-solve #:spec-frag (list (cons "soil-n" profile)) #:soil-n-onhand 0.01))
       (on-leaf (grow-solve #:spec-frag (list (cons "N" profile))))
       (on-leaf-budget (grow-solve #:budget (list (cons "N" profile)))))
  (format #t "  runs: free ~,2f · cap on soil-n ~,2f (N drawn ~,2f) · cap on N ~,2f (N drawn ~,2f) · budget on N ~,2f~%"
          free on-spec (n-drawn on-spec) on-leaf (n-drawn on-leaf) on-leaf-budget)
  (check "unbounded, the plan grows toward the demand" (> free 15.0))
  (check "a cap on the spec soil-n holds soil-n under the tip…" (and (> on-spec 1.0) (< on-spec TIP)))
  (check "…and lets more nitrogen than the tip in through the fertiliser" (> (n-drawn on-spec) TIP))
  (check "a cap on the LEAF N holds the nitrogen drawn, every route summed, under the tip" (< (n-drawn on-leaf) TIP))
  (check "…and is a real bound, not a shutdown" (> on-leaf 1.0))
  (check "a budget on the leaf over the horizon reads the same way" (< (n-drawn on-leaf-budget) TIP)))

;; ── the floor ──────────────────────────────────────────────────────────────────
;; two periods; bread on hand at period 0 only, and bread carries across no period on
;; its own. Ada's energy floor stands each period. With her energy good storable,
;; she eats ahead on day 0 and the reserve meets day 1; without, day 1 starves.
(define KCAL 2470.0)                                  ; bread's kilocalories per kg (the eat reduction, stated here)
(define RDA 2200.0)
(define (energy-good t) (format #f "energy|ada#~a@~a" PLACE t))
(define PERIODS '(0 1 2))
(define (fed? tau-days bread-kg)
  ;; the engine is fail-closed: a floor no column of its period can touch is an
  ;; error, never a quiet zero, and that is the honest answer for "starves"
  (catch #t
   (lambda ()
   (call-with-values
    (lambda ()
      (call-with-values
        (lambda () (if tau-days
                       (relaxation-records "energy|ada" #f 0 "body" #:tau (* 24.0 tau-days) #:period-hours 24.0
                                           #:id "reserve~energy~ada" #:unit "kcal" #:enclosure-hours 1e-5)
                       (values '() '())))
        (lambda (rprocs rflows)
          (plan-from-records
           (list (er "b0" "bread" #f #:place PLACE #:qty bread-kg #:unit "kg")
                 (er "body~ada" "body" "ada" #:place PLACE #:qty 24.0 #:unit "hours/day"))
           (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
           (list (place* PLACE))
           (append (list (rp* "eat~bread~ada" "eat bread")) rprocs)
           (append (list (consume* "e1" "bread" 1.0 "eat~bread~ada")
                         (out* "e2" "energy|ada" KCAL "eat~bread~ada" "kcal"))
                   rflows)
           #:specs (list (spec* "body" "A body" "hours/day" #:keep-in-place #t))
           #:periods PERIODS #:per-agent? #f #:backend 'native-c #:allow-infeasible? #t
           #:bands (map (lambda (t) (list (energy-good t) RDA #f 1.0)) PERIODS)))))
    (lambda (i c material fill cols x idx nt rep)
      (assq-ref (assq-ref rep 'certificate) 'feasible?))))
   (lambda (k . args) #f)))

(format #t "~%── the floor: a stored nutrient feeds tomorrow from today ──~%")
(check "the catalogue states which nutrients the body stores, and for how many days: energy six weeks, B12 years"
       (let ((r (reserve-nutrients)))
         (and (= 45 (assoc-ref r "energy")) (> (assoc-ref r "vit B12") 365) (assoc-ref r "iron") (assoc-ref r "calcium") #t)))
(check "…and which it does not: water, protein, vitamin K eat their own day"
       (let ((r (reserve-nutrients)))
         (not (or (assoc-ref r "drinking-water") (assoc-ref r "protein") (assoc-ref r "vit K")))))
;; three days' floors, 6600 kcal; 3 kg of bread on hand the first day, 7410 kcal
(check "with no reserve, bread on hand today alone cannot feed tomorrow's floor" (not (fed? #f 3.0)))
(check "with a six-week store the surplus carries, leaking 2 % a day, and three days are fed" (fed? 45 3.0))
(check "a store of one day leaks 63 % a period: the same bread feeds nobody three days on" (not (fed? 1 3.0)))
(check "…and does with four times the bread: the leak is a rate, never a wall" (fed? 1 12.0))

;; ── the light ──────────────────────────────────────────────────────────────────
;; a farm of one hectare: soil-n and light in, grain out; the land shines what falls
;; on it in June at 52° north, and no more grain can grow than that light stores
(define (farm-world lit?)
  (let ((w (world #:specs (list (spec* "land" "Land" "ha" #:keep-in-place #t) (spec* "soil-n" "Soil N" "kg")
                                (spec* "grain" "Grain" "kg") (spec* "skill-farm" "Farm labour" %effort-unit))
                  #:procs (list (rp* "grow" "Grow" 1.0))
                  #:flows (list (consume* "g1" "soil-n" 0.05 "grow") (out* "g2" "grain" 1.0 "grow") (wk* "g3" "skill-farm" 0.001 "grow"))
                  #:recipes (list (make-recipe #:id "r-grow" #:name "Grain" #:primary-output "grain"
                                               #:recipe-processes '("grow")))
                  #:spatials (list (place* PLACE)))))
    (if lit? (world-sunlit w #:lat 52.5 #:month 6) w)))
(define (grain-grown lit?)
  (let ((w (farm-world lit?)))
    (call-with-values
      (lambda ()
        (plan-from-records
         (append (list (er "sn" "soil-n" #f #:place PLACE #:qty 1.0e6 #:unit "kg")
                       (er "field" "land" #f #:place PLACE #:qty 1.0 #:unit "ha")
                       (er "skill-farm:ada" "skill-farm" "ada" #:place PLACE))
                 (world-resources w))                    ; the sky over the land, the shine's means
         (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
         (world-spatials w) (world-procs w) (world-flows w)
         #:specs (world-specs w)
         #:demand (list (cons (format #f "grain#~a@0" PLACE) 1.0e6))
         #:periods '(0) #:per-agent? #f #:backend 'native-c #:allow-infeasible? #t))
      (lambda (i c material fill cols x idx nt rep)
        (let ((j (hash-ref idx (format #f "p|grow|~a@0" PLACE) #f)))
          (if j (vector-ref x j) 0.0))))))

(format #t "~%── the light: the land shines, and the field bounds the harvest ──~%")
(define I (insolation-kwh-per-m2-day 52.5 6))
(define BOUND (/ (* I (area-m2 "ha")) (sunlight-for "grain" 1.0)))   ; kg of grain a hectare's June day can store
(let ((lit (grain-grown #t)) (dark (grain-grown #f)))
  (format #t "  June at 52.5°: ~,2f kWh/m²/day · a hectare stores at most ~,1f kg of grain a day · grown lit ~,1f · unlit ~,1f~%" I BOUND lit dark)
  (check "June at Berlin's latitude is between four and a half and six kWh per square metre a day" (and (> I 4.5) (< I 6.0)))
  (check "…December under one" (< (insolation-kwh-per-m2-day 52.5 12) 1.0))
  (check "…and the equator's year is flat" (< (abs (- (insolation-kwh-per-m2-day 0 6) (insolation-kwh-per-m2-day 0 12))) 0.01))
  (check "unlit, the world's grain is bounded by nothing here: the demand is met" (> dark (* 10 BOUND)))
  (check "lit, a hectare grows at most what its light stores" (<= lit (* 1.001 BOUND)))
  (check "sunlit is a fixed point: lighting a lit world adds no flow and no shine"
         (let* ((w1 (farm-world #t)) (w2 (world-sunlit w1 #:lat 52.5 #:month 6)))
           (and (= (length (world-flows w1)) (length (world-flows w2)))
                (= (length (world-procs w1)) (length (world-procs w2))))))
  (check "…and grows near it: the light is a bound, never a wall" (> lit (* 0.9 BOUND))))

(format #t "~%── the water: a grow that names none draws rain, and the land rains when told its millimetres ──~%")
(let* ((w0 (farm-world #t))
       (w1 (world-watered w0))
       (rain-of (lambda (w) (filter (lambda (f) (and (eq? 'consume (recipe-flow-action f)) (equal? "rain" (recipe-flow-resource-conforms-to f)))) (world-flows w))))
       (wr (world-sunlit (farm-world #f) #:lat 52.5 #:month 6 #:rain-mm-day 2.0))
       (rained (filter (lambda (f) (and (eq? 'produce (recipe-flow-action f)) (equal? "rain" (recipe-flow-resource-conforms-to f)))) (world-flows wr))))
  (check "watered, the grow draws its rain: one flow, sized by the energy it stores"
         (and (= 1 (length (rain-of w1)))
              (< (abs (- (measure-has-numerical-value (recipe-flow-resource-quantity (car (rain-of w1)))) (water-for "grain" 1.0))) 1e-9)))
  (check "…and rain is a spec of the world" (any (lambda (s) (equal? "rain" (resource-specification-id s))) (world-specs w1)))
  (check "watered is a fixed point" (= (length (world-flows w1)) (length (world-flows (world-watered w1)))))
  (check "unwatered, nothing is drawn: the shine alone states no rain" (null? (rain-of w0)))
  (check "told two millimetres a day, a hectare's shine rains twenty thousand litres"
         (and (= 1 (length rained)) (< (abs (- (measure-has-numerical-value (recipe-flow-resource-quantity (car rained))) 20000.0)) 1e-6))))

(format #t "~%── the land rains into whatever the field drinks from, in its unit ──~%")
(let* ((w (world #:specs (list (spec* "land" "Land" "ha" #:keep-in-place #t) (spec* "water" "Summer water" "ML")
                               (spec* "grain" "Grain" "kg") (spec* "skill-farm" "Farm labour" %effort-unit))
                 #:procs (list (rp* "grow" "Grow" 1.0))
                 #:flows (list (consume* "g1" "water" 0.001 "grow" "ML") (out* "g2" "grain" 1.0 "grow") (wk* "g3" "skill-farm" 0.001 "grow"))
                 #:recipes (list (make-recipe #:id "r-grow" #:name "Grain" #:primary-output "grain"
                                              #:recipe-processes '("grow")))
                 #:spatials (list (place* PLACE))))
       (ws (world-sky w #:lat 52.5 #:month 6 #:rain-mm-day 2.0))
       (rain (filter (lambda (f) (and (eq? 'produce (recipe-flow-action f)) (equal? "water" (recipe-flow-resource-conforms-to f)))) (world-flows ws))))
  (check "a field that drinks megalitres is rained on in megalitres: two millimetres on a hectare is 0.02 ML"
         (and (= 1 (length rain))
              (equal? "ML" (measure-has-unit (recipe-flow-resource-quantity (car rain))))
              (< (abs (- (measure-has-numerical-value (recipe-flow-resource-quantity (car rain))) 0.02)) 1e-9)))
  (check "…and the shine draws the sky's rain at the boundary, litre for litre of what it lays: 20 000 L"
         (let ((drawn (filter (lambda (f) (and (eq? 'consume (recipe-flow-action f)) (equal? "rain" (recipe-flow-resource-conforms-to f)))) (world-flows ws))))
           (and (= 1 (length drawn)) (equal? "shine~land" (recipe-flow-recipe-input-of (car drawn)))
                (< (abs (- (measure-has-numerical-value (recipe-flow-resource-quantity (car drawn))) 20000.0)) 1e-6))))
  (check "…while the grow's transpiration is not drawn twice: it drinks the water it names"
         (null? (filter (lambda (f) (and (equal? "rain" (recipe-flow-resource-conforms-to f)) (equal? "grow" (recipe-flow-recipe-input-of f)))) (world-flows ws))))
  (check "the shine's means is the sky over the land, sized by all the land the world holds: two hectares shine and rain twice one"
         (let* ((two (world-with w #:resources (list (er "f1" "land" #f #:place PLACE #:qty 2.0 #:unit "ha"))))
                (ws2 (world-sky two #:lat 52.5 #:month 6 #:rain-mm-day 2.0))
                (rain2 (find (lambda (f) (and (eq? 'produce (recipe-flow-action f)) (equal? "water" (recipe-flow-resource-conforms-to f)))) (world-flows ws2)))
                (sky (find (lambda (r) (equal? "sky~land" (economic-resource-conforms-to r))) (world-resources ws2))))
           (and rain2 (< (abs (- (measure-has-numerical-value (recipe-flow-resource-quantity rain2)) 0.04)) 1e-9)
                sky (equal? PLACE (economic-resource-current-location sky)))))
  (check "the farm commune under a shed with a record rains its water each period, off the record, whatever its land is spent on"
         (let* ((fw (commune-farm-world #:crops '(("wheat" . (2.0 . 5000.0))) #:place "brandenburg-farm" #:parent "berlin" #:lat 52.5))
                (r (filter (lambda (f) (and (eq? 'produce (recipe-flow-action f)) (equal? "water" (recipe-flow-resource-conforms-to f)))) (world-flows fw))))
           (and (= 1 (length r)) (> (measure-has-numerical-value (recipe-flow-resource-quantity (car r))) 0.0))))
  (check "…and a farm under no record is as it was: its water a stated stock"
         (null? (filter (lambda (f) (and (eq? 'produce (recipe-flow-action f)) (equal? "water" (recipe-flow-resource-conforms-to f))))
                        (world-flows (commune-farm-world #:crops '(("wheat" . (2.0 . 5000.0))) #:place "farm-x"))))))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
