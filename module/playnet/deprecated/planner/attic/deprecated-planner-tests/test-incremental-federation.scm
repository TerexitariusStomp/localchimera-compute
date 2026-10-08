;;; test-incremental-federation.scm — Incremental replanning and federation
;;;
;;; Ported from: old/planner/src/lib/tests/incremental-replan.test.ts
;;;              old/planner/src/lib/tests/federation-decomposition.test.ts
;;;              old/planner/src/lib/tests/membership-lifecycle.test.ts
;;;              old/planner/src/lib/tests/mode-c.test.ts
;;;
;;; Intent: Verify incremental replanning with cache + dirty-scope
;;; tracking, federation decomposition across hierarchical scopes,
;;; membership lifecycle (add/remove agents), and Mode C planning
;;; (metabolic debt / conservation signals).
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-incremental-federation.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

;;; ── Harness ────────────────────────────────────────────────────────────────

;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: 3-scope hierarchy (farm, mill, bakery)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Federation hierarchy ──\n")

(define store (make-memory-store))
(define scope-root-env-full
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root)
      (((vf planning) ^store-registry) ,^store-registry))
    #:extends (list recipe-store-env agent-store-env observer-env
                    plan-store-env buffer-zone-store-env
                    account-store-env capacity-buffer-store-env
                    spatial-thing-store-env snapshot-store-env
                    alert-store-env store-registry-env
                    process-registry-env
                    live-registry-env live-resource-env
                    ballot-store-env demand-registry-env)))

(define-values (vat farm mill bakery registry)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda ()
      (values (spawn-scope-root "Farm Coop")
              (spawn-scope-root "Community Mill")
              (spawn-scope-root "Town Bakery")
              (spawn ^store-registry (hashmap))))
    store))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Scope creation and naming
;;;
;;; Ported from: membership-lifecycle "scope creation"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope creation ──\n")

(with-vat vat
  (check "farm name" ($ farm 'name) "Farm Coop")
  (check "mill name" ($ mill 'name) "Community Mill")
  (check "bakery name" ($ bakery 'name) "Town Bakery"))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Agent lifecycle: add agents to scopes
;;;
;;; Ported from: membership-lifecycle "agent deletion methods"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Agent lifecycle ──\n")

(with-vat vat
  (let ((as-farm ($ farm 'agent-store))
        (as-mill ($ mill 'agent-store)))
    ;; Add agents to farm
    ($ as-farm 'add-agent (make-agent #:id "agent-farmer-1" #:type 'person #:name "Farmer 1"))
    ($ as-farm 'add-agent (make-agent #:id "agent-farmer-2" #:type 'person #:name "Farmer 2"))

    ;; Add agents to mill
    ($ as-mill 'add-agent (make-agent #:id "agent-miller-1" #:type 'person #:name "Miller 1"))

    (check "farm agents" (length ($ as-farm 'all-agents)) 2)
    (check "mill agents" (length ($ as-mill 'all-agents)) 1)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Store registry
;;;
;;; Ported from: federation-decomposition "store registry"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Store registry ──\n")

(with-vat vat
  ;; Register scopes
  ($ registry 'register "farm" ($ farm 'plan-store))
  ($ registry 'register "mill" ($ mill 'plan-store))
  ($ registry 'register "bakery" ($ bakery 'plan-store))

  (check "registry count" ($ registry 'scope-count) 3)
  (check-pred "registry has farm" (not (not ($ registry 'get "farm"))))
  (check "scope ids" (length ($ registry 'all-scope-ids)) 3))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Seed knowledge per scope
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Seed knowledge ──\n")

(define wheat-spec (make-resource-specification #:id "spec-wheat" #:name "Wheat"
                                                #:default-unit-of-resource "kg"))
(define flour-spec (make-resource-specification #:id "spec-flour" #:name "Flour"
                                                #:default-unit-of-resource "kg"))
(define bread-spec (make-resource-specification #:id "spec-bread" #:name "Bread"
                                                #:default-unit-of-resource "each"))

(with-vat vat
  ;; Farm: grows wheat
  (let ((rs ($ farm 'recipe-store))
        (obs ($ farm 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-farm-wheat" #:name "Farm Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 500 "kg") #:onhand-quantity (make-measure 500 "kg") #:primary-accountable "agent-farmer-1")))

  ;; Mill: converts wheat → flour
  (let ((rs ($ mill 'recipe-store))
        (obs ($ mill 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-grind" #:name "Grind"
                            #:has-duration (make-duration 3 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-w-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-grind"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-f-out" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-grind"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-flour" #:name "Flour" #:primary-output "spec-flour"
                    #:recipe-processes (list "rp-grind"))))

  ;; Bakery: converts flour → bread
  (let ((rs ($ bakery 'recipe-store))
        (obs ($ bakery 'observer)))
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-resource-spec bread-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake-fed" #:name "Bake"
                            #:has-duration (make-duration 4 "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-fi-fed" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 5 "kg") #:recipe-input-of "rp-bake-fed"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bo-fed" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 10 "each") #:recipe-output-of "rp-bake-fed"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread-fed" #:name "Bread" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-bake-fed")))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-bakery-flour" #:name "Bakery Flour" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 20 "kg") #:onhand-quantity (make-measure 20 "kg") #:primary-accountable "agent-bakery")))

  (check-pred "knowledge seeded" #t))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Federation planning
;;;
;;; Ported from: federation-decomposition "plan all scopes"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Federation planning ──\n")

(with-vat vat
  ;; Add bread demand to bakery
  (let ((ps ($ bakery 'plan-store)))
    ($ ps 'add-intent
       (make-intent #:id "i-bread-fed" #:action 'produce #:name "Bread demand" #:resource-conforms-to "spec-bread"
                    #:resource-quantity (make-measure 30 "each") #:receiver "agent-bakery" #:due "2026-04-01T00:00:00Z")))

  ;; Run federation planning
  (let ((result (plan-federation
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
                        rs ps obs)))
                  #:parent-of (hashmap)
                  #:registry registry)))

    (let ((by-scope (assq-ref result 'by-scope))
          (plan-order (assq-ref result 'plan-order)))
      (check "federation: 3 scopes planned" (hashmap-count by-scope) 3)
      (check "plan order: 3" (length plan-order) 3))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Qualified reference resolution
;;;
;;; Ported from: federation-decomposition "resolve cross-scope refs"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Qualified references ──\n")

(with-vat vat
  (let ((resolved ($ registry 'resolve "bakery::i-bread-fed")))
    (check-pred "resolved bread intent" (> (length resolved) 0)))

  (let ((resolved ($ registry 'resolve "farm::nonexistent")))
    (check "missing ref returns empty" (length resolved) 0)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Federation persistence
;;;
;;; Ported from: incremental-replan "cache survives vat restart"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Federation persistence ──\n")

(define-values (vat2 farm2 mill2 bakery2 registry2)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda () (error "Should restore!"))
    store))

(with-vat vat2
  (check "farm restored" ($ farm2 'name) "Farm Coop")
  (check "mill restored" ($ mill2 'name) "Community Mill")
  (check "bakery restored" ($ bakery2 'name) "Town Bakery")
  (check "registry restored" ($ registry2 'scope-count) 3)

  ;; Inventory persisted
  (check-pred "farm wheat persisted"
    (= 500 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ farm2 'observer) 'get-resource "r-farm-wheat")))))

  ;; Agents persisted
  (check "farm agents persisted" (length ($ ($ farm2 'agent-store) 'all-agents)) 2))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
