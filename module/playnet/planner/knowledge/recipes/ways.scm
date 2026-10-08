;;; ways.scm — the ways of doing an activity, as ValueFlows recipes.
;;;
;;; The law face lists WAYS of an activity: share a meal from a home kitchen,
;;; serve a permitted community meal, hold land in a trust and build on it,
;;; move into a vacant building. A way trips legal crossings, and what it trips
;;; is read off its recipe (legal/crossings.scm) — what is made, what is handed over
;;; and what comes back, whose rights move. This file is the recipe of each way
;;; that had none; hosting in a spare room is recipes/dwelling.scm, surplus
;;; recovery is recipes/food-surplus.scm.
;;;
;;; A recipe here says the SHAPE of the way — its actions, the kinds of thing,
;;; its exchange — with one unit of each. It is the legal shape and makes no
;;; claim about yields or hours; a scope that runs the way plans it with its own
;;; recipe, and that recipe's records trip the same crossings by the same fold.
;;; So these seeders are called by name (knowledge/law/way-recipes.scm) and stay out
;;; of the planner umbrella's sweep, as recipes/compliance-food.scm does.
;;;
;;; What the records cannot say rides a tag on the flow, as everywhere:
;;; `crossing:home-kitchen` (WHERE it was cooked), `crossing:feed-in-public`
;;; (WHERE it is handed out), `crossing:land-use` (WHAT the land is zoned for),
;;; `crossing:occupy-property` (WHOSE the building is), and `channel:personal`
;;; (a meal served by a person, to a person).

(define-module (playnet planner knowledge recipes ways)
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module ((playnet planner knowledge recipes handover) #:select (state-exchange!))
  #:export (seed-ways-recipes))

;;; one process, one recipe: FLOWS is a list of
;;;   (action spec qty unit side [classes] [exchange])
;;; side ∈ in | out. A `work` or `use` row's quantity is its effort.
(define (seed-way! rs id name primary flows exchanges)
  (let ((pid (string-append "rp-" id)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id pid #:name name #:has-duration (make-duration 1 "hours")))
    (let loop ((fs flows) (i 0))
      (when (pair? fs)
        (let* ((f (car fs))
               (action (list-ref f 0)) (spec (list-ref f 1))
               (qty (list-ref f 2)) (unit (list-ref f 3)) (side (list-ref f 4))
               (classes (and (> (length f) 5) (list-ref f 5)))
               (exchange (and (> (length f) 6) (list-ref f 6)))
               (effort? (memq action effort-actions)))
          ($ rs 'add-recipe-flow
             (make-recipe-flow #:id (string-append pid "/" (number->string i)) #:action action #:resource-conforms-to spec #:resource-classified-as classes
                               #:resource-quantity (and (not effort?) (make-measure qty unit))
                               #:effort-quantity (and effort? (make-measure qty unit))
                               #:recipe-input-of (and (eq? side 'in) pid) #:recipe-output-of (and (eq? side 'out) pid)
                               #:recipe-clause-of exchange
                               #:is-primary (equal? spec primary))))
        (loop (cdr fs) (+ i 1))))
    ($ rs 'add-recipe
       (make-recipe #:id (string-append "recipe-" id) #:name name #:primary-output primary #:recipe-processes (list pid)
                    #:recipe-exchanges (and (pair? exchanges) exchanges)))))

(define (spec! rs id name unit classes)
  ($ rs 'add-resource-spec
     (make-resource-specification #:id id #:name name #:resource-classified-as classes
                                  #:default-unit-of-resource unit)))

(define (seed-ways-recipes rs)
  "Seed the recipe of every way that has no other: four ways of giving out food,
   four of sheltering people."
  (spec! rs "spec-way-ingredients" "Ingredients" "kg" '("food"))
  (spec! rs "spec-way-meal" "A cooked meal" "meal" '("food"))
  (spec! rs "spec-way-parcel" "A food parcel" "kg" '("food"))
  (spec! rs "spec-way-labour" "Hours" "hours" #f)

  ;; ── free food ──
  ;; a meal cooked at home and handed to a neighbour
  (state-exchange! rs "rx-way-home-share" "A home-cooked meal, given")
  (seed-way! rs "way-home-share" "Home-kitchen direct share" "spec-way-meal"
             '((consume "spec-way-ingredients" 1 "kg" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-way-meal" 1 "meal" out
                        ("crossing:home-kitchen" "channel:personal") "rx-way-home-share"))
             '("rx-way-home-share"))
  ;; a meal cooked in a permitted kitchen and served on site
  (state-exchange! rs "rx-way-permitted-meal" "A served meal, given")
  (seed-way! rs "way-permitted-meal" "Permitted community meal" "spec-way-meal"
             '((consume "spec-way-ingredients" 1 "kg" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-way-meal" 1 "meal" out
                        ("crossing:congregate-meal" "channel:personal") "rx-way-permitted-meal"))
             '("rx-way-permitted-meal"))
  ;; food handed out in a public space, on a site secured by consent
  (state-exchange! rs "rx-way-consented-site" "Food, handed out in public")
  (seed-way! rs "way-consented-site" "Consented-site public distribution" "spec-way-parcel"
             '((consume "spec-way-ingredients" 1 "kg" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-way-parcel" 1 "kg" out
                        ("crossing:feed-in-public") "rx-way-consented-site"))
             '("rx-way-consented-site"))
  ;; a meal served indoors, to people gathered
  (state-exchange! rs "rx-way-indoor-congregate" "A served meal, given")
  (seed-way! rs "way-indoor-congregate" "Indoor congregate meal" "spec-way-meal"
             '((consume "spec-way-ingredients" 1 "kg" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-way-meal" 1 "meal" out
                        ("crossing:congregate-meal" "channel:personal") "rx-way-indoor-congregate"))
             '("rx-way-indoor-congregate"))

  ;; ── shelter ──
  ;; land's rights move into the trust, and a dwelling is built on it
  (seed-way! rs "way-land-trust" "Community land trust housing" "spec-dwelling"
             '((transfer-all-rights "land" 1 "each" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-dwelling" 1 "each" out ("crossing:land-use")))
             '())
  ;; small dwellings placed together on one sanctioned site
  (seed-way! rs "way-tiny-homes" "Sanctioned tiny-home village" "spec-dwelling"
             '((work    "spec-way-labour" 1 "hours" in)
               (produce "spec-dwelling" 1 "each" out
                        ("crossing:land-use" "crossing:congregate-shelter")))
             '())
  ;; a parcel assembled into common ownership, and housing built on it
  (seed-way! rs "way-coop-build" "Build new cooperative housing" "spec-dwelling"
             '((transfer-all-rights "land" 1 "each" in)
               (work    "spec-way-labour" 1 "hours" in)
               (produce "spec-dwelling" 1 "each" out ("crossing:land-use")))
             '())
  ;; people move into a standing building another holds the title to
  (seed-way! rs "way-occupy-vacant" "Occupy a vacant building" "spec-shelter"
             '((cite "spec-dwelling" 1 "each" in
                     ("crossing:occupy-property" "crossing:built-structure"))
               (deliver-service "spec-shelter" 1 "person-nights" out))
             '())
  'seeded)
