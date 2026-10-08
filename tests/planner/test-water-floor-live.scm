;;; test-water-floor-live.scm — a body's water floor, met from a form that is water.
;;;
;;; Water is the molecule (catalogues/substances.scm: every water form carries h2o, one for one),
;;; and a body's drinking-water floor (catalogues/subsistence.scm, 3.2 L a day) is met
;;; by the forms that are water and nothing else (`water-form?`), each carrying its
;;; litre per kilogram as a DERIVED nutrient row. A scope that draws water from its
;;; well (a process producing drinking-water) meets the floor through the same eat
;;; reduction every food takes; one that draws none is told so ([diet]) and the
;;; floor stands on nothing. Grain's moisture meets no floor: the food rows carry no
;;; water, on purpose (docs/observation/physics.md §6).
;;;
;;; Run:  guile -q -L module tests/planner/test-water-floor-live.scm

(use-modules (playnet test harness) (playnet planner scope root) (playnet planner vf schemas) (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand) (playnet planner knowledge dsl world)
             ((playnet planner scope live) #:select (plan-scope))
             (goblins) (srfi srfi-1))

(define PLACE "town")
(define win (all-week-window "06:00" "18:00"))   ; every day: the test stands on today

(define (scope-with! litres draws?)
  "A scope with one person, a well of LITRES, and — when DRAWS? — the act that
   draws drinking water from it."
  (let ((root (spawn-scope-root "well-town")))
    (seed-world! root
      (world #:specs (list (spec* "spec-water" "Water" "liters") (spec* "drinking-water" "Drinking water" "L")
                           (spec* "skill-house" "House labour" "hours"))
             #:procs (if draws? (list (rp* "draw-water" "Draw drinking water")) '())
             #:flows (if draws?
                         (list (consume* "w1" "spec-water" 1.0 "draw-water" "liters")
                               (out* "w2" "drinking-water" 1.0 "draw-water" "L")
                               (wk* "w3" "skill-house" 0.01 "draw-water"))
                         '())
             #:recipes (if draws? (list (make-recipe #:id "r-water" #:name "Drinking water"
                                                     #:primary-output "drinking-water"
                                                     #:recipe-processes '("draw-water"))) '())
             #:spatials (list (place* PLACE))
             #:agents (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
             #:resources (list (er "well" "spec-water" #f #:name "the well" #:place PLACE #:qty litres #:unit "liters")
                               (er "skill-house:ada" "skill-house" "ada"))))
    root))

(define (feasible? root)
  (call-with-values (lambda () (plan-scope root #:reproduce? #t #:demand '() #:periods '(0)
                                          #:backend 'native-c #:allow-infeasible? #t))
    (lambda (ints coms material fill x ntot report)
      (assq-ref (assq-ref report 'certificate) 'feasible?))))

(define vat (spawn-vat))
(with-vat vat
  (display "\n── the floor, met from the well ──\n")
  (check-pred "a well of a hundred litres and the act of drawing: Ada's 3.2 litres a day are met, the plan is feasible"
              (feasible? (scope-with! 100.0 #t)))
  (check-pred "a well of one litre: the floor stands and cannot be met"
              (not (feasible? (scope-with! 1.0 #t))))
  (display "\n── no act that draws: the floor stands on nothing, and the scope is told ──\n")
  (check-pred "with the well but no draw, no food carries the litre: the plan is feasible, the [diet] line says what was dropped"
              (feasible? (scope-with! 100.0 #f))))

(test-summary!)
