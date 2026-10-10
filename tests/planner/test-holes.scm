;;; test-holes.scm — a hole in the recipe web: known by its boundary, yielding once mapped
;;;
;;; A hole is one tagged process whose flows are its ports. It seeds through
;;; the same world door as any recipe, reads back as a hole, its ports carry
;;; the quantities that cross, conformance reads the taxonomy path, and the
;;; admit predicate drops a hole exactly when a recipe of the scope's own
;;; fills its output port.
;;; Run: guile -L module tests/planner/test-holes.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner vf schemas))
(use-modules (playnet planner knowledge dsl shorthand))
(use-modules (playnet planner knowledge dsl world))
(use-modules (playnet planner knowledge dsl holes))
(use-modules ((playnet planner knowledge recipes store) #:select (^recipe-store)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(define vat (spawn-vat))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

(with-vat vat
  (let ((rs (empty-recipe-store)))
    ;; the kitchen: makes meals, leaves organic waste; the garden takes compost
    (seed-world-recipes! rs
      (world #:specs (list (spec* "vegetables" "Vegetables" "kg")
                           (spec* "meal" "Meal" %count-unit)
                           (spec* "organic-waste" "Organic waste" "kg")
                           (spec* "vegetable-trimmings" "Trimmings" "kg")
                           (spec* "compost" "Compost" "kg")
                           (make-resource-specification #:id "worm-castings" #:name "Worm castings"
                                                        #:resource-classified-as '("compost/vermicompost") #:default-unit-of-resource "kg"))
             #:procs (list (rp* "cook" "Cook" 0.6))
             #:flows (list (consume* "cook/veg" "vegetables" 2 "cook")
                           (out* "cook/meal" "meal" 4 "cook" %count-unit)
                           (out* "cook/waste" "organic-waste" 0.5 "cook" #:primary #f))
             #:recipes (list (make-recipe #:id "rp-meal" #:name "Cooked meal"
                                          #:primary-output "meal" #:recipe-processes '("cook")
                                          #:recipe-exchanges '()))))
    ;; the hole: waste management, known only by what crosses its boundary
    (seed-world-recipes! rs
      (hole-world "hole-waste" "Waste management" "waste-management"
                  #:in '(("organic-waste" 10 "kg")) #:out '(("compost" 4 "kg")) #:hours 1.5))

    (let ((hole ($ rs 'get-recipe "hole-waste"))
          (meal ($ rs 'get-recipe "rp-meal")))
      (check "the hole seeds as a recipe" (and hole #t))
      (check "the hole reads as a hole" (hole-recipe? rs hole))
      (check "an ordinary recipe is not one" (not (hole-recipe? rs meal)))
      (check "holes-of lists exactly the hole" (map recipe-id (holes-of rs)) '("hole-waste"))
      (let ((rp ($ rs 'get-recipe-process "hole-waste/hole")))
        (check "the process carries the tag and the term"
               (recipe-process-process-classified-as rp) (list hole-tag "waste-management"))
        (check "hole-term reads the term" (hole-term rp) "waste-management")
        (check "the hole's labour is a work flow of the boundary"
               (any (lambda (f) (eq? (recipe-flow-action f) 'work))
                    (car ($ rs 'flows-for-process "hole-waste/hole")))))
      (let ((ports (hole-ports rs hole)))
        (check "one input port, its quantity the crossing"
               (map (lambda (f) (cons (recipe-flow-resource-conforms-to f)
                                      (measure-has-numerical-value (recipe-flow-resource-quantity f))))
                    (filter (lambda (f) (eq? (recipe-flow-action f) 'consume)) (car ports)))
               '(("organic-waste" . 10)))
        (check "one output port, primary"
               (map (lambda (f) (cons (recipe-flow-resource-conforms-to f) (recipe-flow-is-primary f))) (cdr ports))
               '(("compost" . #t))))
      (check "the hole's primary output is its first output port" (recipe-primary-output hole) "compost")

      ;; conformance: the same spec, a spec under the term, a spec classified under it
      (check "a spec fills its own port" (port-conforms? rs "compost" "compost"))
      (check "a spec under the term fills the port" (port-conforms? rs "organic-waste" "organic-waste/kitchen"))
      (check "a spec classified under the term fills the port" (port-conforms? rs "compost" "worm-castings"))
      (check "an unrelated spec does not" (not (port-conforms? rs "compost" "meal")))
      (check "a caller's broader? relation is read too"
             (port-conforms? rs "organic-waste" "vegetable-trimmings"
                             #:broader? (lambda (a b) (and (string=? a "organic-waste") (string=? b "vegetable-trimmings")))))

      ;; the hole yields once mapped
      (let ((admit (hole-admit rs)))
        (check "unmapped, the hole is admitted" (admit hole))
        (check "the ordinary recipe is admitted" (admit meal))
        (check "no filler yet" (hole-fillers rs hole) '()))
      (seed-world-recipes! rs
        (world #:procs (list (rp* "vermi" "Worm bin" 0.3))
               #:flows (list (consume* "vermi/in" "organic-waste" 5 "vermi")
                             (out* "vermi/out" "worm-castings" 2 "vermi"))
               #:recipes (list (make-recipe #:id "rp-vermi" #:name "Vermicompost"
                                            #:primary-output "worm-castings"
                                            #:recipe-processes '("vermi") #:recipe-exchanges '()))))
      (check "a recipe whose output is classified under the port fills the hole"
             (map recipe-id (hole-fillers rs hole)) '("rp-vermi"))
      (let ((admit (hole-admit rs)))
        (check "mapped, the hole yields" (not (admit hole)))
        (check "the filler is admitted" (admit ($ rs 'get-recipe "rp-vermi"))))
      (let ((both (compose-admit (lambda (r) (not (equal? (recipe-id r) "rp-meal"))) (hole-admit rs))))
        (check "composed admits pass when every one does" (both ($ rs 'get-recipe "rp-vermi")))
        (check "…and refuse when any one does" (not (both meal)))
        (check "…the hole among them" (not (both hole))))
      (check "compose-admit of nothing is no condition" (compose-admit #f #f) #f))))

(test-summary!)
