;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; diets.scm — what a person will not eat, as a rule the eat recipe reads.
;;;
;;; A diet is a statement about which (person, food) pairs exist. The nutrient
;;; floors stay where they are — hard, per person, computed from attributes —
;;; and the plan closes them from the foods the person accepts. Two polarities,
;;; two fields:
;;;
;;;   the FOOD carries what it IS, as classifications on its resource spec —
;;;     "vf:food-class:meat", "vf:food-class:dairy", "vf:allergen:contains-milk"
;;;     (the vocabulary cold-chain.scm already seeds); a fixture food with no
;;;     spec record reads its classes off *food-classes* here;
;;;   the PERSON carries what they refuse, as typed tags on their agent record
;;;     beside age: and sex: — "diet:vegan", "allergy:nut", or a raw
;;;     "excludes:vf:food-class:fish".
;;;
;;; `eats?` is the one predicate: no class on the food is among the person's
;;; exclusions. The floor side of the same statement — non-haem iron absorbed
;;; less well, so a vegetarian's iron floor is 1.8× — is the catalogue's own
;;; L2b layer (catalogues/subsistence.scm *diet-shifts*), beside the sex and
;;; life-stage tables it resembles. Preference inside an allowed diet is a
;;; want, never a rule here (docs/planning/food/diet-constraints.md).

(define-module (localchimera knowledge catalogues diets)
  #:use-module ((localchimera vf facts agent-tags) #:select (tag-key? tag-values))
  #:use-module (srfi srfi-1)
  #:export (*diets* *allergens* *food-classes* diet-tags diet-exclusions
            food-classes-of eats?))

;; diet id → (label . the food classes it refuses)
(define *diets*
  '(("vegetarian"  "vegetarian"  "vf:food-class:meat" "vf:food-class:fish" "vf:food-class:shellfish")
    ("vegan"       "vegan"       "vf:food-class:meat" "vf:food-class:fish" "vf:food-class:shellfish"
                                 "vf:food-class:dairy" "vf:food-class:eggs" "vf:food-class:honey")
    ("pescatarian" "pescatarian" "vf:food-class:meat")
    ("halal"       "halal"       "vf:food-class:pork" "vf:food-class:alcohol" "vf:food-class:not-halal")
    ("kosher"      "kosher"      "vf:food-class:pork" "vf:food-class:shellfish" "vf:food-class:not-kosher")
    ("no-dairy"    "no dairy"    "vf:food-class:dairy")
    ("no-gluten"   "no gluten"   "vf:allergen:contains-gluten")))

;; the allergens a person can name; "allergy:<id>" refuses "vf:allergen:contains-<id>"
(define *allergens* '("milk" "eggs" "nuts" "peanuts" "soy" "gluten" "fish" "shellfish" "sesame"))

;; the fixture foods of *food-nutrition* (catalogues/substances.scm), classed — a scope's
;; own spec records carry their classes themselves
(define *food-classes*
  '(("grain"  "vf:food-class:grain" "vf:allergen:contains-gluten")
    ("beans"  "vf:food-class:legume")
    ("greens" "vf:food-class:produce")
    ("dairy"  "vf:food-class:dairy" "vf:allergen:contains-milk")
    ("eggs"   "vf:food-class:eggs" "vf:allergen:contains-eggs")
    ("fish"   "vf:food-class:fish" "vf:allergen:contains-fish")
    ("meat"   "vf:food-class:meat")
    ;; the plant omega-3 sources catalogues/substances.scm prices (flax, walnuts, rapeseed oil, soy)
    ("flax"         "vf:food-class:seed")
    ("walnuts"      "vf:food-class:nuts" "vf:allergen:contains-nuts")
    ("rapeseed-oil" "vf:food-class:oil")
    ("soy"          "vf:food-class:legume" "vf:allergen:contains-soy")))

(define (diet-tags tags)
  "The diet statements among TAGS: every diet:, allergy: and excludes: tag."
  (filter (lambda (t) (or (tag-key? t "diet") (tag-key? t "allergy") (tag-key? t "excludes"))) tags))

(define (diet-exclusions tags)
  "The food classes a person with TAGS refuses."
  (delete-duplicates
   (append (append-map (lambda (name) (let ((d (assoc name *diets*))) (if d (cddr d) '()))) (tag-values tags "diet"))
           (map (lambda (a) (string-append "vf:allergen:contains-" a)) (tag-values tags "allergy"))
           (tag-values tags "excludes"))
   string=?))

(define (food-classes-of spec classified-as)
  "A food's classes: its spec record's CLASSIFIED-AS (a list, or #f) and the fixture table's row."
  (delete-duplicates (append (or classified-as '()) (let ((r (assoc spec *food-classes*))) (if r (cdr r) '())))
                     string=?))

(define (eats? tags spec classified-as)
  "Does a person with TAGS eat SPEC? No class on the food is among their exclusions."
  (let ((out (diet-exclusions tags)))
    (or (null? out)
        (not (any (lambda (c) (member c out)) (food-classes-of spec classified-as))))))

