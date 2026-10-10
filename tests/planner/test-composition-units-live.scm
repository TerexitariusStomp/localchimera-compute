;;; test-composition-units-live.scm — a composition row is per UNIT of the spec.
;;;
;;; The chemistry table states its rows per kilogram. A scope that counts a spec in
;;; tonnes or grams reads the same row at its own scale (live.scm scope-composition,
;;; catalogues/substances.scm kg-per-unit), so element closure and a leaf-keyed cap hold in the
;;; scope's own units; what a scope STATES on a spec is already per unit and is
;;; left as its word (docs/observation/physics.md §6).
;;;
;;; Run:  guile -q -L module tests/planner/test-composition-units-live.scm

(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             ((playnet scope live) #:select (scope-composition))
             ((playnet knowledge catalogues substances) #:select (*contains*))
             (goblins) (srfi srfi-1))

(define (n-of comp spec) (assoc-ref (assoc-ref comp spec) "N"))
(define vat (spawn-vat))
(with-vat vat
  (let* ((root (spawn-scope-root "quarry")) (rs ($ root 'recipe-store)))
    ($ rs 'add-resource-spec (spec* "soil-n" "Soil nitrogen, by the tonne" "t"))
    ($ rs 'add-resource-spec (spec* "spec-wheat" "Wheat, by the gram" "g"))
    ($ rs 'add-resource-spec (spec* "carrot" "Carrot, by the kilogram" "kg"))
    ($ rs 'add-resource-spec (make-resource-specification #:id "ore" #:name "Ore, by the tonne, its row stated" #:default-unit-of-resource "t"
                                                          #:composition '(("N" . 0.02))))
    (let ((comp (scope-composition root)))
      (check-pred "a tonne of soil nitrogen carries a thousand kilograms of N" (< (abs (- (n-of comp "soil-n") 1000.0)) 1e-9))
      (check-pred "a gram of wheat carries a thousandth of the table's row"
                  (< (abs (- (n-of comp "spec-wheat") (* 0.001 (assoc-ref (assoc-ref *contains* "spec-wheat") "N")))) 1e-12))
      (check-pred "a kilogram reads the table as it stands" (= (n-of comp "carrot") (assoc-ref (assoc-ref *contains* "carrot") "N")))
      (check "what the scope states on a spec is per unit already, and stands as its word" (n-of comp "ore") 0.02))))

(test-summary!)
