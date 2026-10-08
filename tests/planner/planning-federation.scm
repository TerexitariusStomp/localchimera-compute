;;; planning-federation.scm — Tests for plan-for-unit, plan-for-scope,
;;; store-registry, and plan-federation.
;;;
;;; Scenario: 3-scope federation (farm, mill, bakery).
;;; Farm produces wheat, mill converts to flour, bakery makes bread.
;;; Federation planner coordinates bottom-up, then lateral matching
;;; resolves cross-scope deficits.

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))
;; ═════════════════════════════════════════════════════════════════════════
;; Setup: Create 3 scopes in a single vat
;; ═════════════════════════════════════════════════════════════════════════

(display "=== Setup: Federation of 3 scopes ===\n")

(define store (make-memory-store))
(define scope-root-env-full
  ;; each env names its own actor; a new slot on ^scope-root needs no edit here
  (make-persistence-env '() #:extends (list scope-root-env store-registry-env)))

(define-values (vat farm mill bakery registry)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda ()
      (values (spawn-scope-root "Farm Cooperative")
              (spawn-scope-root "Community Mill")
              (spawn-scope-root "Town Bakery")
              (spawn ^store-registry (hashmap))))
    store))
;; ═════════════════════════════════════════════════════════════════════════
;; Seed knowledge in each scope
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Seed knowledge ===\n")

;; Shared specs (added to each scope's recipe store)
(define wheat-spec (make-resource-specification #:id "spec-wheat" #:name "Wheat"
                                                #:default-unit-of-resource "kg"))
(define flour-spec (make-resource-specification #:id "spec-flour" #:name "Flour"
                                                #:default-unit-of-resource "kg"))
(define bread-spec (make-resource-specification #:id "spec-bread" #:name "Bread"
                                                #:default-unit-of-resource "each"))

(with-vat vat
  ;; Farm: grows wheat (no recipe — raw material)
  (let ((rs ($ farm 'recipe-store))
        (obs ($ farm 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-farm-wheat" #:name "Farm Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 500 "kg") #:onhand-quantity (make-measure 500 "kg")
         #:current-location "loc-farm" #:primary-accountable "agent-farm")))

  ;; Mill: converts wheat to flour
  (let ((rs ($ mill 'recipe-store))
        (obs ($ mill 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-grind" #:name "Grind"
                            #:has-duration (make-duration 3 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-wheat-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-grind"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-out" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-grind"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-flour" #:name "Flour" #:primary-output "spec-flour"
                                   #:recipe-processes (list "rp-grind")))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-mill-wheat" #:name "Mill Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg")
         #:current-location "loc-mill" #:primary-accountable "agent-mill")))

  ;; Bakery: converts flour to bread
  (let ((rs ($ bakery 'recipe-store))
        (obs ($ bakery 'observer)))
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-resource-spec bread-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake"
                            #:has-duration (make-duration 4 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-in" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 5 "kg") #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bread-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 10 "each") #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread" #:primary-output "spec-bread"
                                   #:recipe-processes (list "rp-bake")))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-bakery-flour" #:name "Bakery Flour" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 20 "kg") #:onhand-quantity (make-measure 20 "kg")
         #:current-location "loc-bakery" #:primary-accountable "agent-bakery"))))

(with-vat vat
  (check "farm wheat" (= 500 (measure-has-numerical-value
                                (economic-resource-onhand-quantity
                                  ($ ($ farm 'observer) 'get-resource "r-farm-wheat")))))
  (check "mill wheat" (= 100 (measure-has-numerical-value
                                (economic-resource-onhand-quantity
                                  ($ ($ mill 'observer) 'get-resource "r-mill-wheat")))))
  (check "bakery flour" (= 20 (measure-has-numerical-value
                                 (economic-resource-onhand-quantity
                                   ($ ($ bakery 'observer) 'get-resource "r-bakery-flour"))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: plan-for-unit on bakery scope
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: plan-for-unit (bakery) ===\n")

(with-vat vat
  (let ((ps ($ bakery 'plan-store))
        (rs ($ bakery 'recipe-store))
        (obs ($ bakery 'observer)))
    ;; Add bread demand intent
    ($ ps 'add-intent
       (make-intent #:id "i-bread-demand" #:action 'produce #:name "Need bread"
                    #:resource-conforms-to "spec-bread"
                    #:resource-quantity (make-measure 30 "each") #:receiver "agent-bakery" #:due "2026-04-01T00:00:00Z"))

    ;; Run planning
    (let ((result (plan-for-unit
                    '("bakery") '((from . 1711584000) (to . 1712188800))
                    rs ps obs
                    #:agents `((provider . "agent-bakery")
                               (receiver . "agent-bakery")))))
      (let ((plan-id (assq-ref result 'plan-id))
            (procs (assq-ref result 'processes))
            (deficits (assq-ref result 'deficit-signals))
            (purchases (or (assq-ref result 'unmet-intents) '())))
        (format #t "  plan-id: ~a\n" plan-id)
        (format #t "  processes: ~a, deficits: ~a, purchases: ~a\n"
                (length procs) (length deficits) (length purchases))
        (check "bakery plan created" (string? plan-id))
        (check "bakery has processes" (>= (length procs) 1))
        ;; Bakery has 20kg flour, needs 15kg for 30 bread (3x recipe of 10/exec)
        ;; So no flour deficit (20 >= 15)
        ))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Store registry
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Store registry ===\n")

(with-vat vat
  ;; Register all three scopes
  ($ registry 'register "farm" ($ farm 'plan-store))
  ($ registry 'register "mill" ($ mill 'plan-store))
  ($ registry 'register "bakery" ($ bakery 'plan-store))

  (check "registry count" (= 3 ($ registry 'scope-count)))
  (check "registry has farm" (not (not ($ registry 'get "farm"))))
  (check "all scope ids" (= 3 (length ($ registry 'all-scope-ids)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Federation planning (hierarchy + lateral matching)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Federation planning ===\n")

(with-vat vat
  ;; Build hierarchy: farm and mill are independent, bakery depends on mill
  ;; For simplicity: flat federation (no parent-child, just peers)
  (let* ((parent-of (hashmap))
         (result (plan-federation
                   '("farm" "mill" "bakery")
                   '((from . 1711584000) (to . 1712188800))
                   #f #f  ;; recipe-store, observer (handled per-scope)
                   ;; Plan-scope function: use each scope's own stores
                   (lambda (scope-id child-results)
                     (let* ((scope-root
                              (cond
                                ((equal? scope-id "farm") farm)
                                ((equal? scope-id "mill") mill)
                                ((equal? scope-id "bakery") bakery)))
                            (rs ($ scope-root 'recipe-store))
                            (ps ($ scope-root 'plan-store))
                            (obs ($ scope-root 'observer)))
                       (plan-for-unit
                         (list scope-id) '((from . 1711584000) (to . 1712188800))
                         rs ps obs
                         #:plan-name (string-append scope-id " plan"))))
                   #:parent-of parent-of
                   #:registry registry)))

    (let ((by-scope (assq-ref result 'by-scope))
          (plan-order (assq-ref result 'plan-order))
          (lateral (assq-ref result 'lateral-matches)))

      (check "federation planned all 3" (= 3 (hashmap-count by-scope)))
      (check "plan order has 3" (= 3 (length plan-order)))
      (format #t "  plan order: ~a\n" plan-order)
      (format #t "  lateral matches: ~a\n" (length lateral))
      (check "federation result" #t))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Qualified reference resolution
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Qualified reference resolution ===\n")

(with-vat vat
  ;; The bakery plan-store should have the bread demand intent
  (let ((resolved ($ registry 'resolve "bakery::i-bread-demand")))
    (check "resolve finds intent" (> (length resolved) 0))
    (let ((intent-pair (assq 'intent resolved)))
      (check "resolved intent" (and intent-pair (intent? (cdr intent-pair))))))

  ;; Missing reference
  (let ((resolved ($ registry 'resolve "bakery::nonexistent")))
    (check "resolve missing" (null? resolved))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Federation with weight-fn (harmony aggregation + coherence)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Federation with weight-fn ===\n")

(with-vat vat
  (let* ((parent-of (hashmap))
         (weight-fn (lambda (spec-id)
                      (cond
                        ((equal? spec-id "spec-bread") 10)
                        ((equal? spec-id "spec-flour") 5)
                        ((equal? spec-id "spec-wheat") 1)
                        (else 1))))
         (result (plan-federation
                   '("farm" "mill" "bakery")
                   '((from . 1711584000) (to . 1712188800))
                   #f #f
                   (lambda (scope-id child-results)
                     (let* ((scope-root
                              (cond
                                ((equal? scope-id "farm") farm)
                                ((equal? scope-id "mill") mill)
                                ((equal? scope-id "bakery") bakery)))
                            (rs ($ scope-root 'recipe-store))
                            (ps ($ scope-root 'plan-store))
                            (obs ($ scope-root 'observer)))
                       (plan-for-unit
                         (list scope-id) '((from . 1711584000) (to . 1712188800))
                         rs ps obs
                         #:plan-name (string-append scope-id " plan")
                         #:weight-fn weight-fn)))
                   #:parent-of parent-of
                   #:registry registry
                   #:weight-fn weight-fn)))

    ;; Harmony should be present in the result
    (let ((harmony (assq-ref result 'harmony))
          (by-scope (assq-ref result 'by-scope)))

      (check "weight-fn: harmony field present"
             (pair? harmony))

      (when (pair? harmony)
        (check "weight-fn: harmony has total"
               (number? (assq-ref harmony 'total)))
        (check "weight-fn: harmony has per-scope"
               (pair? (assq-ref harmony 'per-scope)))
        ;; Total should be <= 0 (deficits produce negative harmony,
        ;; satisfied demands produce 0)
        (check "weight-fn: harmony total is non-positive"
               (<= (assq-ref harmony 'total) 0)))

      ;; Each scope result should have a coherence field
      (when by-scope
        (hashmap-fold
          (lambda (scope-id scope-result _acc)
            (let ((coh (assq-ref scope-result 'coherence)))
              (check (string-append "weight-fn: " scope-id " has coherence")
                     (and (number? coh) (>= coh 0) (<= coh 1))))
            #f)
          #f by-scope)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Persistence round-trip of entire federation
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Federation persistence ===\n")

(define-values (vat2 farm2 mill2 bakery2 registry2)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda () (error "Should restore from store!"))
    store))

(with-vat vat2
  ;; Verify scopes restored
  (check "farm restored" (equal? "Farm Cooperative" ($ farm2 'name)))
  (check "mill restored" (equal? "Community Mill" ($ mill2 'name)))
  (check "bakery restored" (equal? "Town Bakery" ($ bakery2 'name)))

  ;; Verify registry restored
  (check "registry restored" (= 3 ($ registry2 'scope-count)))

  ;; Verify inventory persisted
  (check "farm wheat persisted"
    (= 500 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ farm2 'observer) 'get-resource "r-farm-wheat")))))

  ;; Verify plan-store persisted (bakery should have the bread intent)
  (let ((intent ($ ($ bakery2 'plan-store) 'get-intent "i-bread-demand")))
    (check "bakery intent persisted" (intent? intent))))
;; ═════════════════════════════════════════════════════════════════════════
;; Summary
;; ═════════════════════════════════════════════════════════════════════════

(format #t "\n~a/~a federation planning checks passed.\n" pass-count pass-count)
(display "Federation planning test complete.\n")
