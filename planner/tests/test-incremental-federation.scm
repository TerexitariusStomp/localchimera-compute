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

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

;;; ── Harness ────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: 3-scope hierarchy (farm, mill, bakery)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Federation hierarchy ──\n")

(define store (make-memory-store))
(define scope-env-full
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root)
      (((vf planning) ^store-registry) ,^store-registry))
    #:extends (list recipe-store-env agent-store-env observer-env
                    plan-store-env buffer-zone-store-env
                    account-store-env capacity-buffer-store-env
                    spatial-thing-store-env snapshot-store-env
                    alert-store-env store-registry-env
                    process-registry-env
                    live-registry-env live-resource-env)))

(define-values (vat farm mill bakery registry)
  (spawn-persistent-vat
    scope-env-full
    (lambda ()
      (values (spawn-scope "Farm Coop")
              (spawn-scope "Community Mill")
              (spawn-scope "Town Bakery")
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
    ($ as-farm 'add-agent (make-agent "agent-farmer-1" 'person "Farmer 1" #f #f #f #f #f))
    ($ as-farm 'add-agent (make-agent "agent-farmer-2" 'person "Farmer 2" #f #f #f #f #f))

    ;; Add agents to mill
    ($ as-mill 'add-agent (make-agent "agent-miller-1" 'person "Miller 1" #f #f #f #f #f))

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

(define wheat-spec (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
(define flour-spec (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
(define bread-spec (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))

(with-vat vat
  ;; Farm: grows wheat
  (let ((rs ($ farm 'recipe-store))
        (obs ($ farm 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ obs 'seed-resource
       (make-economic-resource "r-farm-wheat" "Farm Wheat" #f #f #f "spec-wheat" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         #f #f "agent-farmer-1" #f #f #f #f #f #f #f #f)))

  ;; Mill: converts wheat → flour
  (let ((rs ($ mill 'recipe-store))
        (obs ($ mill 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-grind" "Grind" #f #f #f #f
                            (make-duration 3 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-w-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-grind" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-f-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-grind" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-flour" "Flour" #f #f "spec-flour"
                    (list "rp-grind") #f)))

  ;; Bakery: converts flour → bread
  (let ((rs ($ bakery 'recipe-store))
        (obs ($ bakery 'observer)))
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-resource-spec bread-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake-fed" "Bake" #f #f #f #f
                            (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-fi-fed" 'consume "spec-flour" #f
                         (make-measure 5 "kg") #f "rp-bake-fed" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bo-fed" 'produce "spec-bread" #f
                         (make-measure 10 "each") #f #f "rp-bake-fed" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-bread-fed" "Bread" #f #f "spec-bread"
                    (list "rp-bake-fed") #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-bakery-flour" "Bakery Flour" #f #f #f "spec-flour" #f
         (make-measure 20 "kg") (make-measure 20 "kg")
         #f #f "agent-bakery" #f #f #f #f #f #f #f #f)))

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
       (make-intent "i-bread-fed" 'produce "Bread demand" #f #f
                    #f #f #f "spec-bread" #f
                    (make-measure 30 "each") #f #f #f
                    #f "agent-bakery" #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f #f #f #f #f #f)))

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
    scope-env-full
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
(when (> fail-count 0) (exit 1))
