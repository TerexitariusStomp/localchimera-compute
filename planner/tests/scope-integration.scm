;;; scope-integration.scm — End-to-end integration test for the VF Goblins layer
;;;
;;; Exercises the full ValueFlows lifecycle in a single persistent vat:
;;;   1. Seed knowledge (specs, recipes, agents, locations)
;;;   2. Seed inventory (initial resources)
;;;   3. Plan (intents, promote to commitments)
;;;   4. Execute (record events, verify resource state)
;;;   5. Account (credit work, verify claim capacities)
;;;   6. Buffer (add zones, record snapshots)
;;;   7. Persist (save entire vat, restore, verify all state)

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 match))

(define pass-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  ok: ~a\n" label))
      (error (string-append "FAIL: " label))))


;; =========================================================================
;; 1. Create persistent scope vat
;; =========================================================================

(display "=== Phase 1: Create scope vat ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Riverside Commune"))
    store))

(with-vat vat
  (check "scope created" (string? ($ scope 'name)))
  (check "scope name" (equal? "Riverside Commune" ($ scope 'name))))


;; =========================================================================
;; 2. Seed knowledge layer
;; =========================================================================

(display "\n=== Phase 2: Seed knowledge ===\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store))
        (st ($ scope 'spatial-thing-store)))

    ;; Resource specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))

    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))

    ;; Recipe processes
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill wheat" #f #f "pspec-mill" #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f
                            (make-duration 4 "hours") #f #f))

    ;; Recipe flows
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))

    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))

    ;; Verify topo sort
    (let ((chain ($ rs 'get-process-chain "recipe-bread")))
      (check "topo sort" (equal? "rp-mill" (recipe-process-id (car chain)))))

    ;; Agents
    ($ as 'add-agent (make-agent "agent-commune" 'organization "Riverside Commune"
                                 #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-alice" 'person "Alice" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-bob" 'person "Bob" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-river" 'ecological-agent "River Ecosystem"
                                 #f #f #f #f #f))
    (check "agents" (= 4 (length ($ as 'all-agents))))
    (check "people" (= 2 (length ($ as 'people))))

    ;; Locations
    ($ st 'add-location (make-spatial-thing "loc-farm" "Farm" #f 45.5 -73.5 #f #f))
    ($ st 'add-location (make-spatial-thing "loc-mill" "Mill" #f 45.51 -73.49 #f #f))
    ($ st 'add-location (make-spatial-thing "loc-bakery" "Bakery" #f 45.52 -73.48 #f #f))
    (check "locations" (= 3 (length ($ st 'all-locations))))))


;; =========================================================================
;; 3. Seed inventory
;; =========================================================================

(display "\n=== Phase 3: Seed inventory ===\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource
         "r-wheat" "Wheat Stock" #f #f #f "spec-wheat" #f
         (make-measure 200 "kg") (make-measure 200 "kg")
         "loc-farm" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource
         "r-flour" "Flour Stock" #f #f #f "spec-flour" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         "loc-mill" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource
         "r-bread" "Bread Stock" #f #f #f "spec-bread" #f
         (make-measure 0 "each") (make-measure 0 "each")
         "loc-bakery" #f "agent-commune" #f #f #f #f #f #f #f #f))
    (check "resources seeded" (= 3 (length ($ obs 'all-resources))))
    (check "wheat 200kg" (= 200 (measure-has-numerical-value
                                   (economic-resource-accounting-quantity
                                     ($ obs 'get-resource "r-wheat")))))))


;; =========================================================================
;; 4. Plan: create intents and promote to commitments
;; =========================================================================

(display "\n=== Phase 4: Planning ===\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Create plan
    ($ ps 'add-plan (make-plan "plan-weekly" "Weekly Bread Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))

    ;; Commune offers wheat
    ($ ps 'add-intent
       (make-intent "i-wheat-offer" 'consume "Wheat for milling" #f #f
                    "rp-mill" #f #f "spec-wheat" (list "tag:plan:offer")
                    (make-measure 100 "kg") #f #f #f
                    "agent-commune" #f
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-weekly" #f #f #f #f))

    ;; Bakery needs bread
    ($ ps 'add-intent
       (make-intent "i-bread-need" 'produce "Bread demand" #f #f
                    #f "rp-bake" #f "spec-bread" (list "tag:plan:request")
                    (make-measure 40 "each") #f #f #f
                    #f "agent-commune"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-weekly" #f #f #f #f))

    (check "intents" (= 2 (length ($ ps 'all-intents))))
    (check "offers" (= 1 (length ($ ps 'offers))))
    (check "requests" (= 1 (length ($ ps 'requests))))

    ;; Promote wheat offer to commitment
    (let ((cid ($ ps 'promote-to-commitment "i-wheat-offer"
                  (list (cons 'receiver "agent-commune")))))
      (check "commitment created" (commitment? ($ ps 'get-commitment cid)))
      (check "wheat intent finished" (intent-finished ($ ps 'get-intent "i-wheat-offer"))))

    (check "commitments" (= 1 (length ($ ps 'all-commitments))))))


;; =========================================================================
;; 5. Execute: record economic events
;; =========================================================================

(display "\n=== Phase 5: Execution ===\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (ps ($ scope 'plan-store)))

    ;; Alice mills wheat -> flour (consume wheat, produce flour)
    ($ obs 'record-event
       (make-economic-event
         "ev-consume-wheat" 'consume "proc-mill" #f
         "r-wheat" #f "spec-wheat" #f
         "agent-alice" "agent-alice"
         (make-measure 100 "kg") #f
         #f #f "2026-03-28T08:00:00Z" #f
         "loc-mill" #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-produce-flour" 'produce #f "proc-mill"
         "r-flour" #f "spec-flour" #f
         "agent-alice" "agent-alice"
         (make-measure 80 "kg") #f
         #f #f "2026-03-28T10:00:00Z" #f
         "loc-mill" #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Bob bakes bread (consume flour, produce bread)
    ($ obs 'record-event
       (make-economic-event
         "ev-consume-flour" 'consume "proc-bake" #f
         "r-flour" #f "spec-flour" #f
         "agent-bob" "agent-bob"
         (make-measure 80 "kg") #f
         #f #f "2026-03-28T12:00:00Z" #f
         "loc-bakery" #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-produce-bread" 'produce #f "proc-bake"
         "r-bread" #f "spec-bread" #f
         "agent-bob" "agent-bob"
         (make-measure 40 "each") #f
         #f #f "2026-03-28T16:00:00Z" #f
         "loc-bakery" #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Verify resource state
    (let ((wheat ($ obs 'get-resource "r-wheat"))
          (flour ($ obs 'get-resource "r-flour"))
          (bread ($ obs 'get-resource "r-bread")))
      (check "wheat 100kg left" (= 100 (measure-has-numerical-value
                                          (economic-resource-accounting-quantity wheat))))
      (check "flour 50kg left" (= 50 (measure-has-numerical-value
                                        (economic-resource-accounting-quantity flour))))
      (check "bread 40 produced" (= 40 (measure-has-numerical-value
                                          (economic-resource-accounting-quantity bread)))))

    (check "4 events" (= 4 (length ($ obs 'all-events))))
    (check "inventory" (= 3 (length ($ obs 'inventory))))))


;; =========================================================================
;; 6. Account: credit work, verify capacities
;; =========================================================================

(display "\n=== Phase 6: Accounting ===\n")

(with-vat vat
  (let ((acs ($ scope 'account-store)))
    ;; Set up commune pool
    ($ acs 'add-to-pool "individual-claimable" 1000)

    ;; Alice's milling work (6 hours)
    ($ acs 'credit-from-event
       (make-economic-event
         "ev-alice-work" 'work "proc-mill" #f
         #f #f #f #f
         "agent-alice" "agent-alice"
         #f (make-measure 6 "hours")
         #f #f "2026-03-28T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Bob's baking work (8 hours)
    ($ acs 'credit-from-event
       (make-economic-event
         "ev-bob-work" 'work "proc-bake" #f
         #f #f #f #f
         "agent-bob" "agent-bob"
         #f (make-measure 8 "hours")
         #f #f "2026-03-28T16:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (check "total SVC" (= 14 ($ acs 'total-social-svc)))
    (check "pool SVC" (= 1000 ($ acs 'get-pool-svc "individual-claimable")))

    ;; Alice's account
    (let ((alice-acct ($ acs 'get-account "agent-alice")))
      (check "alice credited" (= 6 (account-gross-contribution-credited alice-acct))))

    ;; Bob's account
    (let ((bob-acct ($ acs 'get-account "agent-bob")))
      (check "bob credited" (= 8 (account-gross-contribution-credited bob-acct))))

    ;; Alice claims some goods
    (let ((result ($ acs 'claim-goods "agent-alice" 50)))
      (check "alice claim succeeds" result))

    ;; Verify pool decreased
    (check "pool decreased" (= 950 ($ acs 'get-pool-svc "individual-claimable")))))


;; =========================================================================
;; 7. Buffers: add zones, record snapshots
;; =========================================================================

(display "\n=== Phase 7: Buffer management ===\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store))
        (sns ($ scope 'snapshot-store)))
    ;; Add a wheat buffer zone
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-wheat" "spec-wheat" "prof-1" 'replenished
         "loc-farm" #f #f #f #f
         25 "kg" #f #f #f #f #f #f #f #f #f
         10 0 "kg" #f #f #f #f #f
         100 250 400 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (check "zone added" (buffer-zone? ($ bzs 'get-zone "bz-wheat")))

    ;; Record snapshot
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-28" 100 100 250 400 'yellow))
    (check "snapshot" (= 1 (length ($ sns 'all-snapshots))))
    (check "snapshot zone" (eq? 'yellow
                                (buffer-snapshot-zone ($ sns 'latest "spec-wheat"))))))


;; =========================================================================
;; 8. Persistence: save and restore entire scope
;; =========================================================================

(display "\n=== Phase 8: Persistence round-trip ===\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (error "Should not be called — restoring from store!"))
    store))

(with-vat vat2
  ;; Scope identity
  (check "restored name" (equal? "Riverside Commune" ($ scope2 'name)))

  ;; Knowledge layer
  (let ((rs ($ scope2 'recipe-store)))
    (check "restored specs" (= 3 (length ($ rs 'all-resource-specs))))
    (check "restored recipes" (= 1 (length ($ rs 'all-recipes))))
    (let ((chain ($ rs 'get-process-chain "recipe-bread")))
      (check "restored topo" (equal? "rp-mill" (recipe-process-id (car chain))))))

  ;; Agents
  (let ((as ($ scope2 'agent-store)))
    (check "restored agents" (= 4 (length ($ as 'all-agents))))
    (check "restored alice" (agent? ($ as 'get-agent "agent-alice"))))

  ;; Locations
  (let ((st ($ scope2 'spatial-thing-store)))
    (check "restored locations" (= 3 (length ($ st 'all-locations)))))

  ;; Observation
  (let ((obs ($ scope2 'observer)))
    (check "restored events" (= 4 (length ($ obs 'all-events))))
    (check "restored resources" (= 3 (length ($ obs 'all-resources))))
    (check "restored wheat" (= 100 (measure-has-numerical-value
                                      (economic-resource-accounting-quantity
                                        ($ obs 'get-resource "r-wheat")))))
    (check "restored bread" (= 40 (measure-has-numerical-value
                                     (economic-resource-accounting-quantity
                                       ($ obs 'get-resource "r-bread"))))))

  ;; Planning
  (let ((ps ($ scope2 'plan-store)))
    (check "restored plan" (plan? ($ ps 'get-plan "plan-weekly")))
    (check "restored intents" (= 2 (length ($ ps 'all-intents))))
    (check "restored commitments" (= 1 (length ($ ps 'all-commitments))))
    (check "restored finished" (intent-finished ($ ps 'get-intent "i-wheat-offer"))))

  ;; Accounts
  (let ((acs ($ scope2 'account-store)))
    (check "restored total SVC" (= 14 ($ acs 'total-social-svc)))
    (check "restored pool" (= 950 ($ acs 'get-pool-svc "individual-claimable")))
    (check "restored alice work" (= 6 (account-gross-contribution-credited
                                         ($ acs 'get-account "agent-alice")))))

  ;; Buffers
  (let ((bzs ($ scope2 'buffer-zone-store)))
    (check "restored zone" (buffer-zone? ($ bzs 'get-zone "bz-wheat"))))

  ;; Snapshots
  (let ((sns ($ scope2 'snapshot-store)))
    (check "restored snapshot" (= 1 (length ($ sns 'all-snapshots))))))


;; =========================================================================
;; Summary
;; =========================================================================

(format #t "\n~a/~a checks passed.\n" pass-count pass-count)
(display "End-to-end integration test complete.\n")
