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

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (ice-9 match) (playnet federation remote-transport) (playnet scope root) (playnet vf schemas) (playnet ddmrp records))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 match))
;; =========================================================================
;; 1. Create persistent scope vat
;; =========================================================================


(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(use-modules ((playnet observation account) #:select (declare-claimable!)))
;; the rail is read off the recipes: this fixture stands in for the plan and
;; declares that a claim recipe stands for spec-bread (account.scm spec-claimable?)
(declare-claimable! "spec-bread")

(display "=== Phase 1: Create scope vat ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Riverside Commune"))
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
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource %count-unit))

    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-mill" #:name "Milling"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-bake" #:name "Baking"))

    ;; Recipe processes
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-mill" #:name "Mill wheat" #:process-conforms-to "pspec-mill"
                            #:has-duration (make-duration 2 %effort-unit)))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake bread" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 4 %effort-unit)))

    ;; Recipe flows — include 'work flows so SNLT is computable.
    ;; 6hr work → 20 loaves = 0.3hr SNLT per loaf. Aggregate recipe SNLT:
    ;; work total = 6, output = 20, SNLT = 0.3.
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 2 %effort-unit) #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-wheat-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-out" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                         #:effort-quantity (make-measure 4 %effort-unit) #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-in" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bread-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 20 %count-unit) #:recipe-output-of "rp-bake"))

    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread Production" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-mill" "rp-bake")))

    ;; Verify topo sort
    (let ((chain ($ rs 'get-process-chain "recipe-bread")))
      (check "topo sort" (equal? "rp-mill" (recipe-process-id (car chain)))))

    ;; Agents
    ($ as 'add-agent (make-agent #:id "agent-commune" #:type 'organization
                                 #:name "Riverside Commune"))
    ($ as 'add-agent (make-agent #:id "agent-alice" #:type 'person #:name "Alice"))
    ($ as 'add-agent (make-agent #:id "agent-bob" #:type 'person #:name "Bob"))
    ($ as 'add-agent (make-agent #:id "agent-river" #:type 'ecological-agent
                                 #:name "River Ecosystem"))
    (check "agents" (= 4 (length ($ as 'all-agents))))
    (check "people" (= 2 (length ($ as 'people))))

    ;; Locations
    ($ st 'add-location (make-spatial-thing #:id "loc-farm" #:name "Farm" #:lat 45.5 #:long -73.5))
    ($ st 'add-location (make-spatial-thing #:id "loc-mill" #:name "Mill" #:lat 45.51 #:long -73.49))
    ($ st 'add-location (make-spatial-thing #:id "loc-bakery" #:name "Bakery" #:lat 45.52
                                            #:long -73.48))
    (check "locations" (= 3 (length ($ st 'all-locations))))))
;; =========================================================================
;; 3. Seed inventory
;; =========================================================================

(display "\n=== Phase 3: Seed inventory ===\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-wheat" #:name "Wheat Stock" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 200 "kg") #:onhand-quantity (make-measure 200 "kg")
         #:current-location "loc-farm" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-flour" #:name "Flour Stock" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg")
         #:current-location "loc-mill" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-bread" #:name "Bread Stock" #:conforms-to "spec-bread"
         #:classified-as (list "individually-claimable")
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit)
         #:current-location "loc-bakery" #:primary-accountable "agent-commune"))
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
    ($ ps 'add-plan (make-plan #:id "plan-weekly" #:name "Weekly Bread Plan"
                               #:due "2026-04-07T00:00:00Z" #:created "2026-03-27T00:00:00Z"))

    ;; Commune offers wheat
    ($ ps 'add-intent
       (make-intent #:id "i-wheat-offer" #:action 'consume #:name "Wheat for milling"
                    #:input-of "rp-mill" #:resource-conforms-to "spec-wheat" #:resource-classified-as (list "tag:plan:offer")
                    #:resource-quantity (make-measure 100 "kg")
                    #:provider "agent-commune" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-weekly"))

    ;; Bakery needs bread
    ($ ps 'add-intent
       (make-intent #:id "i-bread-need" #:action 'produce #:name "Bread demand" #:output-of "rp-bake" #:resource-conforms-to "spec-bread" #:resource-classified-as (list "tag:plan:request")
                    #:resource-quantity (make-measure 40 %count-unit) #:receiver "agent-commune" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-weekly"))

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
         #:id "ev-consume-wheat" #:action 'consume #:input-of "proc-mill"
         #:resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
         #:provider "agent-alice" #:receiver "agent-alice"
         #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-03-28T08:00:00Z"
         #:at-location "loc-mill"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-produce-flour" #:action 'produce #:output-of "proc-mill"
         #:resource-inventoried-as "r-flour" #:resource-conforms-to "spec-flour"
         #:provider "agent-alice" #:receiver "agent-alice"
         #:resource-quantity (make-measure 80 "kg") #:has-point-in-time "2026-03-28T10:00:00Z"
         #:at-location "loc-mill"))

    ;; Bob bakes bread (consume flour, produce bread)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-consume-flour" #:action 'consume #:input-of "proc-bake"
         #:resource-inventoried-as "r-flour" #:resource-conforms-to "spec-flour"
         #:provider "agent-bob" #:receiver "agent-bob"
         #:resource-quantity (make-measure 80 "kg") #:has-point-in-time "2026-03-28T12:00:00Z"
         #:at-location "loc-bakery"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-produce-bread" #:action 'produce #:output-of "proc-bake"
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread" #:resource-classified-as (list "individually-claimable")
         #:provider "agent-commune" #:receiver "agent-commune"
         #:resource-quantity (make-measure 40 %count-unit) #:has-point-in-time "2026-03-28T16:00:00Z"
         #:at-location "loc-bakery"))

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
  (let ((acs ($ scope 'account-store))
        (obs ($ scope 'observer)))
    ;; §III.1 Validation Gate: each work event satisfies a recipient-side
    ;; intent (declared need for labor). The intent comes from the
    ;; commune (receiver) — the producer cannot self-author the plan
    ;; that validates their own work.
    ($ obs 'register-intent
       (make-intent #:id "int-alice-6h" #:action 'work #:output-of "proc-mill" #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure 6 %effort-unit)
                    #:provider "agent-alice" #:receiver "agent-commune"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-alice-work" #:action 'work #:input-of "proc-mill"
         #:provider "agent-alice" #:receiver "agent-commune" #:effort-quantity (make-measure 6 %effort-unit) #:has-point-in-time "2026-03-28T10:00:00Z" #:satisfies "int-alice-6h"))
    ($ acs 'credit-from-event
       ($ obs 'get-event "ev-alice-work"))

    ($ obs 'register-intent
       (make-intent #:id "int-bob-8h" #:action 'work #:output-of "proc-bake" #:resource-conforms-to "spec-labor" #:effort-quantity (make-measure 8 %effort-unit)
                    #:provider "agent-bob" #:receiver "agent-commune"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-bob-work" #:action 'work #:input-of "proc-bake"
         #:provider "agent-bob" #:receiver "agent-commune" #:effort-quantity (make-measure 8 %effort-unit) #:has-point-in-time "2026-03-28T16:00:00Z" #:satisfies "int-bob-8h"))
    ($ acs 'credit-from-event
       ($ obs 'get-event "ev-bob-work"))

    (check "total SVC" (= 14 ($ acs 'total-social-svc)))

    ;; Derived credit balances (from observer events, gated by fulfillment)
    (check "alice balance = 6 hours" (= 6 ($ acs 'credit-balance "agent-alice")))
    (check "bob balance = 8 hours"   (= 8 ($ acs 'credit-balance "agent-bob")))

    ;; Validated gross is query-time now; the per-account cache is only
    ;; used for bootstrap credits via add-contribution, so it stays 0
    ;; for gate-routed work events.
    (check "alice validated gross" (= 6 ($ acs 'citizen-gross "agent-alice")))
    (check "bob validated gross"   (= 8 ($ acs 'citizen-gross "agent-bob")))

    ;; Pool = 40 loaves × SNLT(bread). Recipe's SNLT = 6hr work / 20 loaves
    ;; per batch = 0.3hr/loaf. So pool = 40 × 0.3 = 12hr embodied labor.
    (check "pool has 1 resource (bread)" (= 1 (length ($ acs 'pool-resources))))
    (check "embodied labor in pool = 12" (< (abs (- 12 ($ acs 'embodied-labor-in-pool))) 1e-9))

    ;; Alice claims 2 loaves. Labor-cost = 2 × 0.3 = 0.6hr.
    ;; Her effective balance = (6/14) × 12 ≈ 5.14hr, easily covers 0.6.
    (let ((result ($ acs 'claim "r-bread" 2 "agent-alice" 6/10 (list scope)
                      #:fulfills (plan-claim! obs "spec-bread" "agent-alice" 2))))   ; the plan's row
      (check "alice claim succeeds" result))

    ;; Verify observer state reflects transfer: source resource decremented,
    ;; new resource created under claimant's custody.
    (let ((bread ($ obs 'get-resource "r-bread"))
          (alice-bread ($ obs 'get-resource "r-bread-agent-alice")))
      (check "source bread accounting 38" (= 38 (measure-has-numerical-value
                                                   (economic-resource-accounting-quantity bread))))
      (check "source bread still commune-accountable"
             (equal? "agent-commune"
                     (economic-resource-primary-accountable bread)))
      (check "alice-bread accounting = 2" (= 2 (measure-has-numerical-value
                                                  (economic-resource-accounting-quantity alice-bread))))
      (check "alice-bread accountable = alice"
             (equal? "agent-alice"
                     (economic-resource-primary-accountable alice-bread))))

    ;; Raw credit-balance = 6 - 0.6 = 5.4 (governance voice);
    ;; alice-bread exited the pool (held by citizen), so pool = 38 × 0.3 = 11.4.
    (check "alice raw balance = 5.4 (6 - 0.6)"
           (= 54/10 ($ acs 'credit-balance "agent-alice")))
    ;; embodied-labor-in-pool works in inexact hours (SNLT = work÷output, a float),
    ;; so compare within tolerance — float 11.4 ≠ exact 114/10 under `=`.
    (check "pool after claim = 11.4"
           (< (abs (- 114/10 ($ acs 'embodied-labor-in-pool))) 1e-9))))
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
    scope-root-env
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

  ;; Observation: 4 production + 2 work + 1 transfer (claim) = 7 events.
  ;; Resources: wheat, flour, bread, bread-alice (auto-created) = 4.
  (let ((obs ($ scope2 'observer)))
    (check "restored events" (= 7 (length ($ obs 'all-events))))
    (check "restored resources" (= 4 (length ($ obs 'all-resources))))
    (check "restored wheat" (= 100 (measure-has-numerical-value
                                      (economic-resource-accounting-quantity
                                        ($ obs 'get-resource "r-wheat")))))
    (check "restored bread after claim" (= 38 (measure-has-numerical-value
                                                 (economic-resource-accounting-quantity
                                                   ($ obs 'get-resource "r-bread")))))
    (check "restored alice-bread" (= 2 (measure-has-numerical-value
                                          (economic-resource-accounting-quantity
                                            ($ obs 'get-resource "r-bread-agent-alice"))))))

  ;; Planning
  (let ((ps ($ scope2 'plan-store)))
    (check "restored plan" (plan? ($ ps 'get-plan "plan-weekly")))
    (check "restored intents" (= 2 (length ($ ps 'all-intents))))
    (check "restored commitments" (= 1 (length ($ ps 'all-commitments))))
    (check "restored finished" (intent-finished ($ ps 'get-intent "i-wheat-offer"))))

  ;; Accounts: credit balances derived from event log survive persistence
  (let ((acs ($ scope2 'account-store)))
    (check "restored total SVC" (= 14 ($ acs 'total-social-svc)))
    (check "restored alice balance = 5.4" (= 54/10 ($ acs 'credit-balance "agent-alice")))
    (check "restored bob balance = 8"     (= 8 ($ acs 'credit-balance "agent-bob")))
    (check "restored alice validated gross" (= 6 ($ acs 'citizen-gross "agent-alice"))))

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
