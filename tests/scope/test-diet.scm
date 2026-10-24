;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-diet.scm — what a person will not eat, as the eat recipe reads it.
;;;
;;; A diet is a statement about which (person, food) pairs exist. The nutrient
;;; floors stay where they are — hard, per person, from attributes — and the
;;; plan closes them from the foods the person accepts. knowledge/diets.scm is
;;; the rule; live.scm's scope-consumption builds only the pairs it allows, and
;;; the catalogue's L2b layer raises the floors a diet makes harder to fill.
;;;
;;; Run: guile --no-auto-compile -L module tests/scope/test-diet.scm

(use-modules (localchimera test harness) (localchimera vf schemas) (srfi srfi-1) (localchimera scope live)
             (localchimera vf schemas)
             (localchimera knowledge catalogues diets)
             (localchimera knowledge catalogues subsistence)
             (srfi srfi-1) (ice-9 format))

;;; ─── the rule ───────────────────────────────────────────────────────────
(display "\n── the rule: two polarities, one predicate ──\n")
(check-pred "a vegetarian refuses meat, fish and shellfish"
            (lset= string=? (diet-exclusions '("diet:vegetarian" "age:30"))
                   '("vf:food-class:meat" "vf:food-class:fish" "vf:food-class:shellfish")))
(check-pred "an allergy names the allergen class, a raw excludes: names any class"
            (lset= string=? (diet-exclusions '("allergy:nuts" "excludes:vf:food-class:honey"))
                   '("vf:allergen:contains-nuts" "vf:food-class:honey")))
(check-pred "a fixture food reads its classes off the table; a spec record's own classes join them"
            (and (member "vf:food-class:fish" (food-classes-of "fish" #f))
                 (member "vf:food-class:not-halal" (food-classes-of "fish" '("vf:food-class:not-halal")))))
(check-pred "a vegetarian eats beans and not fish; with no diet, everything"
            (and (eats? '("diet:vegetarian") "beans" #f)
                 (not (eats? '("diet:vegetarian") "fish" #f))
                 (eats? '("sex:F") "fish" #f)))
(check-pred "a milk allergy refuses dairy by its allergen class, and nothing else"
            (and (not (eats? '("allergy:milk") "dairy" #f)) (eats? '("allergy:milk") "eggs" #f)))
(check-pred "the floor side lives in the catalogue: a vegetarian's iron 1.8×, a vegan's zinc 1.5× as well, an omnivore's nothing"
            (and (equal? (diet-floor-shifts '("diet:vegetarian")) '(("iron" #:rda 1.8)))
                 (equal? (diet-floor-shifts '("diet:vegan")) '(("iron" #:rda 1.8) ("zinc" #:rda 1.5)))
                 (null? (diet-floor-shifts '("sex:M")))))

;;; ─── the eat recipe, per person ─────────────────────────────────────────
(define (person id tags) (make-agent #:id id #:type 'person #:name id #:primary-location "town"
                                     #:classified-as tags))
(define ada (person "ada" '("sex:F" "age:30" "diet:vegetarian")))
(define bo  (person "bo"  '("sex:F" "age:30")))
(define cy  (person "cy"  '("sex:F" "age:30" "diet:vegan")))
(define (where pid t) "town")
(define (consumption people foods)
  (call-with-values (lambda () (scope-consumption people foods '(0) where))
    (lambda (procs flows bands)
      (list (map recipe-process-id procs) bands))))
(define (band-of bands key) (assoc key bands))
(define (rda-of bands nut pid) (let ((b (band-of bands (string-append nut "|" pid "#town@0")))) (and b (cadr b))))

(define both (consumption (list ada bo) '("beans" "fish")))
(display "\n── the eat recipe, built only for the pairs the diet allows ──\n")
(format #t "  recipes: ~s\n" (car both))
(check-pred "bo, with no diet, eats beans and fish"
            (and (member "eat~beans~bo" (car both)) (member "eat~fish~bo" (car both))))
(check-pred "ada, vegetarian, has an eat recipe for beans and NONE for fish — the solver cannot feed her fish"
            (and (member "eat~beans~ada" (car both)) (not (member "eat~fish~ada" (car both)))))
(check-pred "the floors stay hard for both: each has a protein band at her cell"
            (and (rda-of (cadr both) "protein" "ada") (rda-of (cadr both) "protein" "bo")))
(format #t "  iron floor: ada ~a mg · bo ~a mg\n" (rda-of (cadr both) "iron" "ada") (rda-of (cadr both) "iron" "bo"))
(check-pred "ada's iron floor is 1.8× bo's — the catalogue's diet layer, off the same tag"
            (< (abs (- (/ (rda-of (cadr both) "iron" "ada") (rda-of (cadr both) "iron" "bo")) 1.8)) 1e-9))
(check-pred "…and her protein floor is bo's: a diet only moves what it makes harder"
            (< (abs (- (rda-of (cadr both) "protein" "ada") (rda-of (cadr both) "protein" "bo"))) 1e-9))
(check-pred "the context carries the diet as stated, and the catalogue reads its rows off that"
            (let ((ctx (agent->subsistence-ctx cy)))
              (and (equal? (assq-ref ctx 'diet) '("diet:vegan"))
                   (= 1.5 (/ (cadr (assoc "zinc" (subsistence-bands ctx)))
                             (cadr (assoc "zinc" (subsistence-bands (agent->subsistence-ctx bo)))))))))

;; a vegan on a menu of beans and fish: no food she eats carries B12 or vitamin
;; D, so those floors cannot stand — dropped for her, and said out loud
(define err (open-output-string))
(define vegan (with-error-to-port err (lambda () (consumption (list cy bo) '("beans" "fish")))))
(define said (get-output-string err))
(display "\n── the menu guard, per person ──\n")
(format #t "  ~a" said)
(check-pred "cy, vegan, eats beans only"
            (and (member "eat~beans~cy" (car vegan)) (not (member "eat~fish~cy" (car vegan)))))
(check-pred "no B12 floor stands for her — beans carry none — while bo's B12 floor stands on the fish"
            (and (not (rda-of (cadr vegan) "vit B12" "cy")) (rda-of (cadr vegan) "vit B12" "bo")))
(check-pred "…and the gap is said, naming her and the nutrients the diet took off her menu"
            (and (string-contains said "[diet] cy") (string-contains said "vit B12")))
(check-pred "…and nothing is said of bo, whose menu is the whole menu — the difference is empty by construction"
            (not (string-contains said "[diet] bo")))
;; a floor the menu carries but cannot fill under the body's energy ceiling
;; STANDS — the solve reads the infeasibility — and is named as the menu's
;; finding: beans and fish carry vitamin E in trace against a 15 mg floor.
;; bo's calcium, 0.7 kg of beans, fits under her ceiling: it stands unremarked.
(check-pred "cy's vitamin E stands on no meal under her energy ceiling: the floor stands, and the menu's finding names it"
            (and (rda-of (cadr vegan) "vit E" "cy") (string-contains said "[menu] cy") (string-contains said "vit E")))
(check-pred "bo's calcium, filled by beans under her ceiling, stands and is not among what her menu cannot fill"
            (and (rda-of (cadr vegan) "calcium" "bo")
                 (let ((line (find (lambda (l) (string-contains l "[menu] bo")) (string-split said #\newline))))
                   (or (not line) (not (string-contains line "calcium"))))))
(check-pred "her iron floor still stands, at 1.8×, from the beans"
            (< (abs (- (/ (rda-of (cadr vegan) "iron" "cy") (rda-of (cadr vegan) "iron" "bo")) 1.8)) 1e-9))

(test-summary!)
