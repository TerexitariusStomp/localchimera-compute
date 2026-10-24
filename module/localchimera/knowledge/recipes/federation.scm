;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation-recipes.scm — Bootstrap recipe data for federation demos
;;;
;;; Provides seed functions to populate a RecipeStore with standard
;;; Mediterranean commune recipes (grain, dairy, bakery, etc.).

(define-module (localchimera knowledge recipes federation)
  #:use-module ((localchimera utils units) #:select (%count-unit %effort-unit))
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf schemas)   ; the VF record constructors it seeds
  #:use-module (goblins)                   ; $ — it talks to a live recipe-store
  #:use-module ((localchimera utils store-utils) #:select (generate-id))   ; the id of each seeded resource
  #:export (*spec-names* seed-federation-specs seed-federation-recipes
            seed-federation-inventory))

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
         (make-resource-specification #:id (car pair) #:name (cdr pair)
                                      #:default-unit-of-resource %count-unit)))
    *spec-names*))

(define (seed-federation-recipes recipe-store)
  "Add standard recipes: milling (wheat->flour), baking (flour->bread),
   cheese-making (milk->cheese), salting (fish->salt-fish), pressing (olives->oil)."
  ;; Milling
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-mill" #:name "Milling"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-mill" #:name "Mill grain" #:process-conforms-to "pspec-mill"
                          #:has-duration (make-duration 3 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-wheat-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                       #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-mill"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-flour-out" #:action 'produce #:resource-conforms-to "spec-flour"
                       #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-mill"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-flour" #:name "Flour Production" #:primary-output "spec-flour"
                  #:recipe-processes (list "rp-mill")))

  ;; Baking
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-bake" #:name "Baking"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-bake" #:name "Bake bread" #:process-conforms-to "pspec-bake"
                          #:has-duration (make-duration 4 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-flour-in" #:action 'consume #:resource-conforms-to "spec-flour"
                       #:resource-quantity (make-measure 5 "kg") #:recipe-input-of "rp-bake"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-bread-out" #:action 'produce #:resource-conforms-to "spec-bread"
                       #:resource-quantity (make-measure 10 %count-unit) #:recipe-output-of "rp-bake"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-bread" #:name "Bread Production" #:primary-output "spec-bread"
                  #:recipe-processes (list "rp-bake")))

  ;; Cheese-making
  ($ recipe-store 'add-process-spec
     (make-process-specification #:id "pspec-cheese" #:name "Cheese Making"))
  ($ recipe-store 'add-recipe-process
     (make-recipe-process #:id "rp-cheese" #:name "Make cheese" #:process-conforms-to "pspec-cheese"
                          #:has-duration (make-duration 8 %effort-unit)))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-milk-in" #:action 'consume #:resource-conforms-to "spec-milk"
                       #:resource-quantity (make-measure 10 "liters") #:recipe-input-of "rp-cheese"))
  ($ recipe-store 'add-recipe-flow
     (make-recipe-flow #:id "rf-cheese-out" #:action 'produce #:resource-conforms-to "spec-cheese"
                       #:resource-quantity (make-measure 1 "kg") #:recipe-output-of "rp-cheese"))
  ($ recipe-store 'add-recipe
     (make-recipe #:id "recipe-cheese" #:name "Cheese Production" #:primary-output "spec-cheese"
                  #:recipe-processes (list "rp-cheese"))))

(define (seed-federation-inventory observer scope-inventories)
  "Seed initial inventory. scope-inventories: alist of (scope-name . ((spec-id qty unit) ...))."
  (for-each
    (lambda (scope)
      (for-each
        (lambda (item)
          (let ((spec (car item)) (qty (cadr item)) (unit (caddr item)))
            ($ observer 'seed-resource
               (make-economic-resource
                 #:id (generate-id "r-") #:name (or (assoc-ref *spec-names* spec) spec) #:conforms-to spec
                 #:accounting-quantity (make-measure qty unit) #:onhand-quantity (make-measure qty unit) #:primary-accountable (car scope)))))
        (cdr scope)))
    scope-inventories))
