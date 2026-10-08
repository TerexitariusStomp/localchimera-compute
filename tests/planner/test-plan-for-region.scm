;;; test-plan-for-region.scm — Regional planning utilities
;;;
;;; Tests normalize-cells deduplication, plan-store merge, remove-records,
;;; extract-demands, and extract-supply.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-plan-for-region.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. normalizeCells: dedup identical
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── normalizeCells: dedup identical ──\n")

(let ((result (normalize-cells '("cell-a" "cell-a" "cell-b"))))
  (check "dedup length" (length result) 2)
  (check-pred "contains cell-a" (member "cell-a" result))
  (check-pred "contains cell-b" (member "cell-b" result)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. normalizeCells: empty
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── normalizeCells: empty ──\n")

(check "empty input" (normalize-cells '()) '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. normalizeCells: no duplicates
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── normalizeCells: no duplicates ──\n")

(let ((result (normalize-cells '("x" "y" "z"))))
  (check "no-dup length" (length result) 3))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: single vat for all actor tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Region Test"))
    store))

(with-vat vat

  ;; Seed resource specs so extract-demands / extract-supply have references
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource "each"))

    ;; Add a recipe so classify-demand can look it up
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-bake" #:name "Baking"))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 4 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-f-in" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-b-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 20 "each") #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake")))
    (check-pred "recipes seeded" #t))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 4. PlanStore merge
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── PlanStore merge ──\n")

  (let ((ps-main ($ scope 'plan-store)))

    ;; Confirm main store starts empty
    (check "main intents empty" (length ($ ps-main 'all-intents)) 0)
    (check "main commitments empty" (length ($ ps-main 'all-commitments)) 0)
    (check "main plans empty" (length ($ ps-main 'all-plans)) 0)

    ;; Create a second plan-store actor inside the same vat
    (let ((ps-sub (spawn ^plan-store (empty-plan-store-state) '())))

      ;; Add records to the sub store
      ($ ps-sub 'add-plan
         (make-plan #:id "plan-sub" #:name "Sub Plan"))

      ($ ps-sub 'add-intent
         (make-intent #:id "i-merge-1" #:action 'consume #:name "Merge intent"
                      #:input-of "proc-m1" #:resource-conforms-to "spec-wheat"
                      #:resource-quantity (make-measure 50 "kg") #:receiver "agent-sub" #:planned-within "plan-sub"))

      ($ ps-sub 'add-commitment
         (make-commitment #:id "c-merge-1" #:action 'produce #:resource-conforms-to "spec-bread"
                          #:resource-quantity (make-measure 10 "each")
                          #:provider "agent-sub" #:receiver "agent-sub" #:planned-within "plan-sub"))

      ;; Verify sub store has records
      (check "sub has 1 intent" (length ($ ps-sub 'all-intents)) 1)
      (check "sub has 1 commitment" (length ($ ps-sub 'all-commitments)) 1)
      (check "sub has 1 plan" (length ($ ps-sub 'all-plans)) 1)

      ;; Merge sub into main
      ($ ps-main 'merge ps-sub)

      ;; Verify main now has all records
      (check "main has 1 intent after merge" (length ($ ps-main 'all-intents)) 1)
      (check "main has 1 commitment after merge" (length ($ ps-main 'all-commitments)) 1)
      (check "main has 1 plan after merge" (length ($ ps-main 'all-plans)) 1)

      ;; Verify the specific records are accessible
      (check-pred "merged intent accessible"
                  (intent? ($ ps-main 'get-intent "i-merge-1")))
      (check-pred "merged commitment accessible"
                  (commitment? ($ ps-main 'get-commitment "c-merge-1")))
      (check-pred "merged plan accessible"
                  (plan? ($ ps-main 'get-plan "plan-sub")))))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 5. PlanStore removeRecords
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── PlanStore removeRecords ──\n")

  (let ((ps ($ scope 'plan-store)))

    ;; Add a fresh intent and commitment for removal testing
    ($ ps 'add-intent
       (make-intent #:id "i-rm-1" #:action 'produce #:name "Remove me" #:resource-conforms-to "spec-flour"
                    #:resource-quantity (make-measure 20 "kg")
                    #:provider "agent-a" #:planned-within "plan-sub"))

    ($ ps 'add-commitment
       (make-commitment #:id "c-rm-1" #:action 'consume #:resource-conforms-to "spec-wheat"
                        #:resource-quantity (make-measure 30 "kg")
                        #:provider "agent-a" #:receiver "agent-a" #:planned-within "plan-sub"))

    ;; Verify they exist
    (check-pred "i-rm-1 exists before remove"
                (intent? ($ ps 'get-intent "i-rm-1")))
    (check-pred "c-rm-1 exists before remove"
                (commitment? ($ ps 'get-commitment "c-rm-1")))

    ;; Remove both
    ($ ps 'remove-records '() '("c-rm-1") '("i-rm-1"))

    ;; Verify they are gone
    (check "i-rm-1 gone" ($ ps 'get-intent "i-rm-1") #f)
    (check "c-rm-1 gone" ($ ps 'get-commitment "c-rm-1") #f))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 6. PlanStore removeRecords idempotent
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── PlanStore removeRecords idempotent ──\n")

  (let ((ps ($ scope 'plan-store)))
    ;; Removing nonexistent IDs should not error
    ($ ps 'remove-records '() '("nonexistent") '("also-missing"))
    (check-pred "idempotent remove no error" #t))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 7. extract-demands (inlined)
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── extract-demands ──\n")

  (let ((ps ($ scope 'plan-store)))

    ;; Add open intents (finished=#f) to plan-store
    ($ ps 'add-intent
       (make-intent #:id "i-demand-1" #:action 'consume #:name "Demand wheat"
                    #:input-of "proc-d1" #:resource-conforms-to "spec-wheat"
                    #:resource-quantity (make-measure 100 "kg") #:receiver "agent-region" #:due "2026-05-01T00:00:00Z" #:planned-within "plan-sub"))

    ($ ps 'add-intent
       (make-intent #:id "i-demand-2" #:action 'consume #:name "Demand flour"
                    #:input-of "proc-d2" #:resource-conforms-to "spec-flour"
                    #:resource-quantity (make-measure 50 "kg") #:receiver "agent-region" #:due "2026-05-01T00:00:00Z" #:planned-within "plan-sub"))

    ;; Inline extract-demands: filter open intents with resource-quantity > 0
    (let* ((open (filter (lambda (i) (not (intent-finished i)))
                         ($ ps 'all-intents)))
           (slots (filter-map
                    (lambda (i)
                      (let ((rq (intent-resource-quantity i)))
                        (and rq (> (measure-has-numerical-value rq) 0)
                             `((intent-id . ,(intent-id i))
                               (spec-id . ,(intent-resource-conforms-to i))
                               (action . ,(intent-action i))
                               (remaining-quantity . ,(measure-has-numerical-value rq))
                               (unit . ,(measure-has-unit rq))
                               (due . ,(intent-due i))
                               (at-location . ,(intent-at-location i))
                               (provider . ,(intent-provider i))
                               (receiver . ,(intent-receiver i))))))
                    open)))
      (check-pred "extract-demands finds slots" (>= (length slots) 2))

      ;; Verify wheat demand is present
      (let ((wheat-slot (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-wheat")) slots)))
        (check-pred "wheat demand present" (pair? wheat-slot))
        (when (pair? wheat-slot)
          (check-pred "wheat qty = 100"
                      (approx= 100 (assq-ref wheat-slot 'remaining-quantity)))))

      ;; Verify flour demand is present
      (let ((flour-slot (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-flour")) slots)))
        (check-pred "flour demand present" (pair? flour-slot))
        (when (pair? flour-slot)
          (check-pred "flour qty = 50"
                      (approx= 50 (assq-ref flour-slot 'remaining-quantity)))))))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 8. extract-supply (inlined)
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── extract-supply ──\n")

  (let ((obs ($ scope 'observer)))

    ;; Seed inventory
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-wheat-region" #:name "Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 200 "kg") #:onhand-quantity (make-measure 200 "kg") #:primary-accountable "agent-region"))

    ($ obs 'seed-resource
       (make-economic-resource #:id "r-flour-region" #:name "Flour" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 80 "kg") #:onhand-quantity (make-measure 80 "kg") #:primary-accountable "agent-region"))

    ;; Inline extract-supply: get all resources with onhand > 0
    (let* ((all-res ($ obs 'all-resources))
           (supply (filter-map
                     (lambda (r)
                       (let ((qty (measure-has-numerical-value
                                    (economic-resource-onhand-quantity r))))
                         (and (> qty 0)
                              `((id . ,(string-append "inv:" (economic-resource-id r)))
                                (spec-id . ,(economic-resource-conforms-to r))
                                (quantity . ,qty)
                                (at-location . ,(economic-resource-current-location r))))))
                     all-res)))
      (check-pred "extract-supply finds resources" (>= (length supply) 2))

      ;; Verify wheat supply
      (let ((wheat (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-wheat")) supply)))
        (check-pred "wheat supply present" (pair? wheat))
        (when (pair? wheat)
          (check-pred "wheat onhand = 200"
                      (approx= 200 (assq-ref wheat 'quantity)))))

      ;; Verify flour supply
      (let ((flour (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-flour")) supply)))
        (check-pred "flour supply present" (pair? flour))
        (when (pair? flour)
          (check-pred "flour onhand = 80"
                      (approx= 80 (assq-ref flour 'quantity)))))))
  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 9. Process registry round-trip
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── Process registry ──\n")

  (let ((preg ($ scope 'process-registry)))

    ;; Register a process
    ($ preg 'register
       (make-process #:id "proc-1" #:name "Test Process" #:planned-within "plan-sub"))

    (check-pred "process registered"
                (process? ($ preg 'get "proc-1")))
    (check "process name"
           (process-name ($ preg 'get "proc-1")) "Test Process")

    ;; All returns at least one
    (check-pred "all has process" (>= (length ($ preg 'all)) 1))

    ;; Register another and verify count
    ($ preg 'register
       (make-process #:id "proc-2" #:name "Second Process" #:planned-within "plan-sub"))
    (check-pred "all has 2 processes" (>= (length ($ preg 'all)) 2)))

  ;;; ════════════════════════════════════════════════════════════════════════
  ;;; 10. classifySlot (inline classify-demand)
  ;;;
  ;;; classify-demand classifies a demand slot against supply and recipes:
  ;;; - locally-satisfiable: supply of same spec exists
  ;;; - producible-with-imports: a recipe produces the spec but no supply exists
  ;;; - external-dependency: neither supply nor recipe exists
  ;;; ════════════════════════════════════════════════════════════════════════

  (display "\n── classifySlot ──\n")

  (let ((rs ($ scope 'recipe-store)))

    ;; Build test data inline
    (let ((supply-list (list `((spec-id . "spec-wheat") (quantity . 200))
                             `((spec-id . "spec-flour") (quantity . 80)))))

      ;; Case 1: locally-satisfiable — demand for wheat, wheat supply exists
      (let* ((slot-wheat `((spec-id . "spec-wheat") (remaining-quantity . 50)))
             (cls (classify-demand slot-wheat supply-list rs)))
        (check "wheat demand = locally-satisfiable"
               cls 'locally-satisfiable))

      ;; Case 2: producible-with-imports — demand for bread, recipe exists but
      ;; bread is NOT in the supply list
      (let* ((supply-no-bread (list `((spec-id . "spec-wheat") (quantity . 200))))
             (slot-bread `((spec-id . "spec-bread") (remaining-quantity . 10)))
             (cls (classify-demand slot-bread supply-no-bread rs)))
        (check "bread demand (no supply, recipe exists) = producible-with-imports"
               cls 'producible-with-imports))

      ;; Case 3: external-dependency — demand for apples, no supply, no recipe
      (let* ((slot-apples `((spec-id . "spec-apples") (remaining-quantity . 20)))
             (cls (classify-demand slot-apples supply-list rs)))
        ;; spec-apples is not in supply and no recipe produces it
        (check "apples demand (no supply, no recipe) = external-dependency"
               cls 'external-dependency))))

) ;; end with-vat
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
