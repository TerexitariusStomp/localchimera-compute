;;; knowledge/recipes/proofing.scm — a thermal step a scope can plan: proofed dough.
;;;
;;; The first recipe in the tree that requires a STATE (docs/observation/physics.md
;;; §3; docs/the-plan-and-the-laws.typ): dough is kneaded from flour, proofed six
;;; kelvin above ambient in a proofing box, and baked from its proofed form. The
;;; warmed form is declared through the one door (knowledge/thermal.scm
;;; declare-thermal-form!), so its heat and entropy are stated on its spec, the
;;; dough's zero is stated, and the relaxation recipe that holds it in the box
;;; and lets it cool is on the store. The proofer buys its heat as electricity:
;;; exactly c·ΔT per kilogram, so element closure over heat lets it run and would
;;; refuse a proofer stating less (tests/planner/test-relaxation.scm
;;; shows the refusal on the engine).
;;;
;;; Seeded beside a scope's bread recipes by `seed-proofing!`; opt-in, so the
;;; standing bread fixtures keep their numbers.

(define-module (playnet planner knowledge recipes proofing)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner knowledge dsl shorthand) #:select (rp* out* consume* wk* use* spec*))
  #:use-module ((playnet planner knowledge catalogues thermal) #:select (declare-thermal-form!))
  #:use-module ((playnet planner knowledge catalogues substances) #:select (base-at-ambient-row))
  #:use-module (goblins)
  #:export (%dough-specific-heat %proof-delta-t %proofing-box-ua %proofing-box-mass
            seed-proofing! proofed-dough-id))

(define %dough-specific-heat 2.5)     ; kJ/(kg·K): a wet flour paste, near water's half
(define %proof-delta-t 6)             ; kelvin over ambient: a warm kitchen's proof
(define %proofing-box-ua 0.01)        ; kW/K: a lidded, insulated box
(define %proofing-box-mass 20.0)      ; kg the box holds at once
(define proofed-dough-id "dough+6K")  ; what `thermal-form` names dough warmed by six

(define* (seed-proofing! rs #:key (electricity "spec-sp-electricity") (skill "skill-bake") (period-hours 24.0))
  "On recipe store RS: the specs dough and proofing-box (keep-in-place), the warmed
   form through the door with its relaxation recipe, and three processes: knead
   (flour → dough), proof (dough + electricity → proofed dough, in the box), and
   bake-proofed (proofed dough → bread). Returns the proofed form's id."
  (begin
    ;; dough is flour by another name here (its water is the bake's story): its row is
    ;; the flour's, formation and all, so kneading conserves heat and the proofed form
    ;; stands in the flour's frame
    ($ rs 'add-resource-spec (make-resource-specification #:id "dough" #:name "Dough" #:default-unit-of-resource "kg"
                                                          #:composition (base-at-ambient-row "flour")))
    ($ rs 'add-resource-spec (spec* "proofing-box" "Proofing box" "hours/day" #:keep-in-place #t))
    (unless ($ rs 'get-resource-spec electricity)
      ($ rs 'add-resource-spec (spec* electricity "Electricity" "kWh")))
    (let* ((warmed (declare-thermal-form! rs "dough" %dough-specific-heat %proof-delta-t "proofing-box"
                                          #:mass %proofing-box-mass #:ua %proofing-box-ua #:period-hours period-hours))
           ;; the electricity a proof buys is the heat the door STATED on the form over
           ;; the dough's own: c·ΔT per kilogram, read off the two specs, in one place
           (heat (- (assoc-ref (resource-specification-composition ($ rs 'get-resource-spec warmed)) "heat")
                    (or (assoc-ref (resource-specification-composition ($ rs 'get-resource-spec "dough")) "heat") 0.0))))
      (for-each (lambda (p) ($ rs 'add-recipe-process p))
                (list (rp* "knead" "Knead the dough") (rp* "proof" "Proof the dough") (rp* "bake-proofed" "Bake the proofed dough")))
      (for-each (lambda (f) ($ rs 'add-recipe-flow f))
                (list (consume* "pk1" "flour" 1.0 "knead") (out* "pk2" "dough" 1.0 "knead") (wk* "pk3" skill 0.1 "knead")
                      (consume* "pp1" "dough" 1.0 "proof") (consume* "pp2" electricity heat "proof" "kWh")
                      (use* "pp3" "proofing-box" "proof" 0.1) (out* "pp4" warmed 1.0 "proof") (wk* "pp5" skill 0.05 "proof")
                      (consume* "pb1" warmed 1.0 "bake-proofed") (out* "pb2" "bread" 1.0 "bake-proofed") (wk* "pb3" skill 0.5 "bake-proofed")))
      ($ rs 'add-recipe (make-recipe #:id "proofed-bread" #:name "Proofed bread"
                                     #:primary-output "bread"
                                     #:recipe-processes '("knead" "proof" "bake-proofed")))
      warmed)))
