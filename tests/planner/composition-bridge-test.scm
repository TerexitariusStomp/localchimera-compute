;;; composition-bridge-test.scm — the three rungs of the substance ladder, one path.
;;;
;;;   (1) spec-level   the *contains* fallback table
;;;   (2) recipe-level derive-contains reads composition off the grow recipe
;;;   (3) instance     materialize-composition! seeds those nutrients as real
;;;                    EconomicResources CONTAINED-IN the produced batch, and the
;;;                    observer's containment cascade draws them down on consume.
;;;
;;; So a grow recipe that derives carrot ≈ 4.0% N yields a 100 kg batch literally
;;; holding 4.0 kg of nitrogen, and eating half the batch eats 2.0 kg of it. The
;;; numbers come from the recipe; contained-in carries them per-batch; the cascade
;;; conserves them. No spec table, no observer change.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/planner/composition-bridge-test.scm

(use-modules (playnet test harness)
             (playnet planner knowledge recipes grow) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner knowledge catalogues substances)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Composition Bridge")) store))
(define (~= a b) (and a b (< (abs (- a b)) 1e-3)))
(define (onhand obs id)
  (let ((r ($ obs 'get-resource id)))
    (and r (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

(with-vat vat
  (let ((obs ($ scope 'observer))
        (rs  ($ scope 'recipe-store)))
    (seed-grow-specs rs)
    (seed-grow-recipe rs)

    ;; a produced carrot batch: 100 kg at the field
    ($ obs 'seed-resource
       (make-economic-resource #:id "batch-1" #:name "Carrot batch" #:conforms-to "carrot"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "field"))

    ;; THE BRIDGE: materialize the recipe-derived composition as contained-in
    ;; nutrient resources on this batch.
    (define content (materialize-composition! scope "batch-1" "carrot" 100 #:location "field"))

    (display "\n── derived composition becomes contained-in resources (rungs 2→3) ──\n")
    (check-pred "the batch now contains nutrient resources"
                (pair? ($ obs 'resources-contained-in "batch-1")))
    ;; the numbers are the grow recipe's DERIVED composition (0.040 N, not 0.026)
    (check-pred "nitrogen materialized = 100 × 0.040 = 4.0 kg (recipe-derived)"
                (~= (onhand obs "batch-1:N") 4.0))
    (check-pred "and NOT the *contains* fallback (would be 2.6 kg)"
                (not (~= (onhand obs "batch-1:N") 2.6)))
    (check-pred "carbon materialized = 100 × 0.12009 = 12.009 kg"
                (~= (onhand obs "batch-1:C") (* 100 (/ (* 44.0 (atomic-weight "C")) (molar-mass "co2") 100))))
    (check-pred "phosphorus materialized = 0.56 kg" (~= (onhand obs "batch-1:P") 0.56))
    (check-pred "potassium materialized = 1.40 kg"  (~= (onhand obs "batch-1:K") 1.40))
    (check-pred "each contained resource conforms to its element"
                (every (lambda (r) (member (economic-resource-conforms-to r) *element-ids*))   ; every tracked element, the oxygen its carbon dioxide brought among them
                       ($ obs 'resources-contained-in "batch-1")))

    ;; THE CASCADE: eat half the batch → every nutrient halves (conservation)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-eat" #:action 'consume #:input-of "proc-eat"
         #:resource-inventoried-as "batch-1" #:resource-conforms-to "carrot" #:provider "household" #:receiver "household"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-06-13T12:00:00Z"))

    (display "\n── consuming the batch cascades the carried nutrients (rung 3) ──\n")
    (check-pred "carrot drawn down to 50 kg" (~= (onhand obs "batch-1") 50))
    (check-pred "nitrogen halved to 2.0 kg — the derived N rode inside the batch"
                (~= (onhand obs "batch-1:N") 2.0))
    (check-pred "carbon halved to 6.0 kg"     (~= (onhand obs "batch-1:C") 6.0045))
    (check-pred "phosphorus halved to 0.28 kg" (~= (onhand obs "batch-1:P") 0.28))
    (check-pred "potassium halved to 0.70 kg"  (~= (onhand obs "batch-1:K") 0.70))))

(test-summary!)
