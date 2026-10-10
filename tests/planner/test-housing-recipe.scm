;;; test-housing-recipe.scm — the housing rows in a real recipe-store, and in
;;; the conservation ledger.
;;;
;;; tests/planner/test-housing-substance.scm proves the
;;; standard, the derivation and the solve. This is the store's side: the six
;;; rows register as ResourceSpecifications (nutrient-specs' twin — the
;;; per-unit and per-person goods are made per solve, as `food~pid` is), each
;;; named and unit-denominated from the catalogue, and each DECLARED non-matter
;;; in catalogues/substances.scm, the way spec-shelter is — never left a free variable.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module tests/planner/test-housing-recipe.scm

(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas))
(use-modules (playnet doors service))
(use-modules (playnet knowledge catalogues substances))
(use-modules (playnet knowledge catalogues housing))
(use-modules (playnet knowledge catalogues housing-substance))
(use-modules (goblins) (goblins persistence-store memory) (srfi srfi-1))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Housing Test")) store))

(display "\n── the six rows, in the store ──\n")
(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    (for-each (lambda (sp) ($ rs 'add-resource-spec sp)) housing-specs)
    (for-each
     (lambda (row)
       (let ((sp ($ rs 'get-resource-spec row)))
         (check-pred (string-append row " registers, named and denominated from the catalogue")
                     (and sp
                          (string=? (housing-row-name row) (resource-specification-name sp))
                          (string=? (housing-row-unit row) (resource-specification-default-unit-of-resource sp))))))
     *housing-rows*)))

(display "\n── conservation: a night's adequacy is not matter, and it is DECLARED so ──\n")
(for-each
 (lambda (row)
   (check-pred (string-append row " carries an empty composition row")
               (and (assoc row *contains*) (null? (assoc-ref *contains* row))))
   (check-pred (string-append row " is not in *composition-unstated*")
               (not (member row *composition-unstated*))))
 *housing-rows*)

(test-summary!)
