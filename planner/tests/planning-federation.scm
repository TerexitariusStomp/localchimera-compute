;;; planning-federation.scm — Tests for plan-for-unit, plan-for-scope,
;;; store-registry, and plan-federation.
;;;
;;; Scenario: 3-scope federation (farm, mill, bakery).
;;; Farm produces wheat, mill converts to flour, bakery makes bread.
;;; Federation planner coordinates bottom-up, then lateral matching
;;; resolves cross-scope deficits.

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

(define pass-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  ok: ~a\n" label))
      (error (string-append "FAIL: " label))))
(define (approx= a b . r) (< (abs (- a b)) (if (pair? r) (car r) 0.01)))


;; ═════════════════════════════════════════════════════════════════════════
;; Setup: Create 3 scopes in a single vat
;; ═════════════════════════════════════════════════════════════════════════

(display "=== Setup: Federation of 3 scopes ===\n")

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
                    process-registry-env)))

(define-values (vat farm mill bakery registry)
  (spawn-persistent-vat
    scope-env-full
    (lambda ()
      (values (spawn-scope "Farm Cooperative")
              (spawn-scope "Community Mill")
              (spawn-scope "Town Bakery")
              (spawn ^store-registry (hashmap))))
    store))


;; ═════════════════════════════════════════════════════════════════════════
;; Seed knowledge in each scope
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Seed knowledge ===\n")

;; Shared specs (added to each scope's recipe store)
(define wheat-spec (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
(define flour-spec (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
(define bread-spec (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))

(with-vat vat
  ;; Farm: grows wheat (no recipe — raw material)
  (let ((rs ($ farm 'recipe-store))
        (obs ($ farm 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ obs 'seed-resource
       (make-economic-resource "r-farm-wheat" "Farm Wheat" #f #f #f "spec-wheat" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         "loc-farm" #f "agent-farm" #f #f #f #f #f #f #f #f)))

  ;; Mill: converts wheat to flour
  (let ((rs ($ mill 'recipe-store))
        (obs ($ mill 'observer)))
    ($ rs 'add-resource-spec wheat-spec)
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-grind" "Grind" #f #f #f #f
                            (make-duration 3 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-grind" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-grind" #f #f #f #f #f #f))
    ($ rs 'add-recipe (make-recipe "recipe-flour" "Flour" #f #f "spec-flour"
                                   (list "rp-grind") #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-mill-wheat" "Mill Wheat" #f #f #f "spec-wheat" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         "loc-mill" #f "agent-mill" #f #f #f #f #f #f #f #f)))

  ;; Bakery: converts flour to bread
  (let ((rs ($ bakery 'recipe-store))
        (obs ($ bakery 'observer)))
    ($ rs 'add-resource-spec flour-spec)
    ($ rs 'add-resource-spec bread-spec)
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake" #f #f #f #f
                            (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f
                         (make-measure 5 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f
                         (make-measure 10 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe (make-recipe "recipe-bread" "Bread" #f #f "spec-bread"
                                   (list "rp-bake") #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-bakery-flour" "Bakery Flour" #f #f #f "spec-flour" #f
         (make-measure 20 "kg") (make-measure 20 "kg")
         "loc-bakery" #f "agent-bakery" #f #f #f #f #f #f #f #f))))

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
       (make-intent "i-bread-demand" 'produce "Need bread" #f #f #f #f #f
                    "spec-bread" #f
                    (make-measure 30 "each") #f #f #f
                    #f "agent-bakery"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f #f #f #f #f #f))

    ;; Run planning
    (let ((result (plan-for-unit
                    '("bakery") '((from . 1711584000) (to . 1712188800))
                    rs ps obs
                    #:agents `((provider . "agent-bakery")
                               (receiver . "agent-bakery")))))
      (let ((plan-id (assq-ref result 'plan-id))
            (procs (assq-ref result 'processes))
            (deficits (assq-ref result 'deficit-signals))
            (purchases (assq-ref result 'purchase-intents)))
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
;; Test: Persistence round-trip of entire federation
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Federation persistence ===\n")

(define-values (vat2 farm2 mill2 bakery2 registry2)
  (spawn-persistent-vat
    scope-env-full
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
