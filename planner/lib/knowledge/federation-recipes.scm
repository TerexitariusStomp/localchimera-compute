;;; federation-recipes.scm — Bootstrap recipe data for federation demos
;;;
;;; Provides seed functions to populate a RecipeStore with standard
;;; Mediterranean commune recipes (grain, dairy, bakery, etc.).

(use-modules (srfi srfi-1))

(define *spec-names*
  '(("spec-wheat" . "Wheat")
    ("spec-flour" . "Flour")
    ("spec-bread" . "Bread")
    ("spec-milk" . "Milk")
    ("spec-cheese" . "Cheese")
    ("spec-fish" . "Fish")
    ("spec-salt-fish" . "Salt Fish")
    ("spec-olives" . "Olives")
    ("spec-olive-oil" . "Olive Oil")
    ("spec-tools" . "Tools")
    ("spec-labor" . "Labor Hours")))

(define (seed-federation-specs recipe-store)
  "Add standard resource specifications to a recipe store."
  (for-each
    (lambda (pair)
      ($ recipe-store 'add-resource-spec
         (make-resource-specification (car pair) (cdr pair) #f #f #f "each" #f #f #f #f #f)))
    *spec-names*))

(define (seed-federation-recipes recipe-store)
  "Add standard recipes: milling (wheat->flour), baking (flour->bread),
   cheese-making (milk->cheese), salting (fish->salt-fish), pressing (olives->oil)."
  ;; Milling
  ($ recipe-store 'add-process-spec
     (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process "rp-mill" "Mill grain" #f #f "pspec-mill" #f
                          (make-duration 3 "hours") #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f
                       (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f
                       (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe
     (make-recipe "recipe-flour" "Flour Production" #f #f "spec-flour"
                  (list "rp-mill") #f))

  ;; Baking
  ($ recipe-store 'add-process-spec
     (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f
                          (make-duration 4 "hours") #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f
                       (make-measure 5 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f
                       (make-measure 10 "each") #f #f "rp-bake" #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe
     (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread"
                  (list "rp-bake") #f))

  ;; Cheese-making
  ($ recipe-store 'add-process-spec
     (make-process-specification "pspec-cheese" "Cheese Making" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process "rp-cheese" "Make cheese" #f #f "pspec-cheese" #f
                          (make-duration 8 "hours") #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-milk-in" 'consume "spec-milk" #f
                       (make-measure 10 "liters") #f "rp-cheese" #f #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow "rf-cheese-out" 'produce "spec-cheese" #f
                       (make-measure 1 "kg") #f #f "rp-cheese" #f #f #f #f #f #f))
  ($ recipe-store 'add-recipe
     (make-recipe "recipe-cheese" "Cheese Production" #f #f "spec-cheese"
                  (list "rp-cheese") #f)))

(define (seed-federation-inventory observer scope-inventories)
  "Seed initial inventory. scope-inventories: alist of (scope-name . ((spec-id qty unit) ...))."
  (for-each
    (lambda (scope)
      (for-each
        (lambda (item)
          (let ((spec (car item)) (qty (cadr item)) (unit (caddr item)))
            ($ observer 'seed-resource
               (make-economic-resource
                 (generate-id "r-") (or (assoc-ref *spec-names* spec) spec)
                 #f #f #f spec #f
                 (make-measure qty unit) (make-measure qty unit)
                 #f #f (car scope) #f #f #f #f #f #f #f #f))))
        (cdr scope)))
    scope-inventories))
