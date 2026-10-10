;;; test-snapshot-hydration.scm — Full vat snapshot/hydrate persistence round-trip
;;;
;;; Verifies that all stores survive a complete persist → restore cycle:
;;;   1. Create a persistent vat with a memory-store, populate all stores
;;;   2. Exit with-vat (triggers persistence)
;;;   3. Spawn a NEW persistent vat from the SAME memory-store (hydration)
;;;   4. Verify every record survived intact
;;;
;;; Sections:
;;;   1. Recipe-store round-trip (specs, processes, flows, recipe, topo sort)
;;;   2. Plan-store round-trip (plan, intent, commitment, meta)
;;;   3. Observer round-trip (seed resource, record event, verify quantities)
;;;   4. Agent-store round-trip (agents by type)
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-snapshot-hydration.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Phase 1: Create and populate a persistent vat
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Phase 1: Populate vat ──\n")

(define mem-store (make-memory-store))

(define-values (vat1 scope1)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Hydration Test"))
    mem-store))
;;; ── 1a. Recipe-store ──────────────────────────────────────────────────────

(display "\n  Seeding recipe-store...\n")

(with-vat vat1
  (let ((rs ($ scope1 'recipe-store)))

    ;; Resource specifications
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-ore" #:name "Iron Ore"
                                    #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-ingot" #:name "Iron Ingot"
                                    #:default-unit-of-resource %count-unit))

    ;; Process specifications
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-smelt" #:name "Smelting"))

    ;; Recipe process
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-smelt" #:name "Smelt ore" #:process-conforms-to "pspec-smelt"
                            #:has-duration (make-duration 3 %effort-unit)))

    ;; Recipe flows
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-ore-in" #:action 'consume #:resource-conforms-to "spec-ore"
                         #:resource-quantity (make-measure 50 "kg") #:recipe-input-of "rp-smelt"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-ingot-out" #:action 'produce #:resource-conforms-to "spec-ingot"
                         #:resource-quantity (make-measure 10 %count-unit) #:recipe-output-of "rp-smelt"))

    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-ingots" #:name "Ingot Production" #:primary-output "spec-ingot"
                    #:recipe-processes (list "rp-smelt")))

    (check-pred "recipe-store seeded" #t)))
;;; ── 1b. Plan-store ────────────────────────────────────────────────────────

(display "\n  Seeding plan-store...\n")

(with-vat vat1
  (let ((ps ($ scope1 'plan-store)))

    ;; Plan
    ($ ps 'add-plan (make-plan #:id "plan-smelt" #:name "Weekly Smelting Plan"
                               #:due "2026-04-07T00:00:00Z" #:created "2026-04-01T00:00:00Z"))

    ;; Intent: ore offer
    ($ ps 'add-intent
       (make-intent #:id "i-ore-offer" #:action 'consume #:name "Ore for smelting"
                    #:input-of "rp-smelt" #:resource-conforms-to "spec-ore" #:resource-classified-as (list "tag:plan:offer")
                    #:resource-quantity (make-measure 50 "kg")
                    #:provider "agent-foundry" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-smelt"))

    ;; Intent: ingot request
    ($ ps 'add-intent
       (make-intent #:id "i-ingot-need" #:action 'produce #:name "Ingot demand" #:output-of "rp-smelt" #:resource-conforms-to "spec-ingot" #:resource-classified-as (list "tag:plan:request")
                    #:resource-quantity (make-measure 10 %count-unit) #:receiver "agent-foundry" #:due "2026-04-01T00:00:00Z" #:planned-within "plan-smelt"))

    ;; Promote ore offer to commitment
    ($ ps 'promote-to-commitment "i-ore-offer"
       (list (cons 'receiver "agent-foundry")))

    ;; Set meta on the ingot-need intent
    ($ ps 'set-meta "i-ingot-need" '((priority . "high") (batch . "weekly")))

    (check-pred "plan-store seeded" #t)))
;;; ── 1c. Observer ──────────────────────────────────────────────────────────

(display "\n  Seeding observer...\n")

(with-vat vat1
  (let ((obs ($ scope1 'observer)))

    ;; Seed ore resource
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-ore" #:name "Ore Stockpile" #:conforms-to "spec-ore"
         #:accounting-quantity (make-measure 500 "kg") #:onhand-quantity (make-measure 500 "kg") #:primary-accountable "agent-foundry"))

    ;; Seed ingot resource
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-ingot" #:name "Ingot Stock" #:conforms-to "spec-ingot"
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:primary-accountable "agent-foundry"))

    ;; Record consume-ore event
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-consume-ore" #:action 'consume #:input-of "rp-smelt"
         #:resource-inventoried-as "r-ore" #:resource-conforms-to "spec-ore"
         #:provider "agent-foundry" #:receiver "agent-foundry"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-02T08:00:00Z"))

    ;; Record produce-ingot event
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-produce-ingot" #:action 'produce #:output-of "rp-smelt"
         #:resource-inventoried-as "r-ingot" #:resource-conforms-to "spec-ingot"
         #:provider "agent-foundry" #:receiver "agent-foundry"
         #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-04-02T11:00:00Z"))

    (check-pred "observer seeded" #t)))
;;; ── 1d. Agent-store ───────────────────────────────────────────────────────

(display "\n  Seeding agent-store...\n")

(with-vat vat1
  (let ((as ($ scope1 'agent-store)))

    ($ as 'add-agent (make-agent #:id "agent-foundry" #:type 'organization #:name "Iron Foundry"))
    ($ as 'add-agent (make-agent #:id "agent-smith" #:type 'person #:name "Smith"))
    ($ as 'add-agent (make-agent #:id "agent-river" #:type 'ecological-agent
                                 #:name "River Ecosystem"))

    (check "agents seeded" (length ($ as 'all-agents)) 3)
    (check "people count" (length ($ as 'people)) 1)))
;;; ── Phase 1 summary checks ───────────────────────────────────────────────

(display "\n  Verifying pre-persistence state...\n")

(with-vat vat1
  (let ((rs  ($ scope1 'recipe-store))
        (ps  ($ scope1 'plan-store))
        (obs ($ scope1 'observer))
        (as  ($ scope1 'agent-store)))

    ;; Recipe-store
    (check "pre: resource-specs" (length ($ rs 'all-resource-specs)) 2)
    (check "pre: process-specs" (length ($ rs 'all-process-specs)) 1)
    (check "pre: recipes" (length ($ rs 'all-recipes)) 1)
    (let ((chain ($ rs 'get-process-chain "recipe-ingots")))
      (check "pre: topo chain" (recipe-process-id (car chain)) "rp-smelt"))

    ;; Plan-store
    (check-pred "pre: plan exists" (plan? ($ ps 'get-plan "plan-smelt")))
    (check "pre: intents" (length ($ ps 'all-intents)) 2)
    (check "pre: commitments" (length ($ ps 'all-commitments)) 1)
    (check-pred "pre: ore intent finished"
                (intent-finished ($ ps 'get-intent "i-ore-offer")))

    ;; Observer
    (check "pre: resources" (length ($ obs 'all-resources)) 2)
    (check "pre: events" (length ($ obs 'all-events)) 2)
    (check "pre: ore qty" (measure-has-numerical-value
                            (economic-resource-accounting-quantity
                              ($ obs 'get-resource "r-ore")))
           450)
    (check "pre: ingot qty" (measure-has-numerical-value
                              (economic-resource-accounting-quantity
                                ($ obs 'get-resource "r-ingot")))
           10)

    ;; Agents
    (check "pre: agents" (length ($ as 'all-agents)) 3)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Phase 2: Hydrate — restore from the same memory-store
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Phase 2: Hydrate from memory-store ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (error "Should not be called — restoring from store!"))
    mem-store))
;;; ── 2a. Recipe-store round-trip ───────────────────────────────────────────

(display "\n  Verifying recipe-store hydration...\n")

(with-vat vat2
  (let ((rs ($ scope2 'recipe-store)))

    ;; Resource specs survived
    (check "hydrated: resource-specs count" (length ($ rs 'all-resource-specs)) 2)
    (let ((ore-spec ($ rs 'get-resource-spec "spec-ore")))
      (check-pred "hydrated: ore spec exists" (resource-specification? ore-spec))
      (check "hydrated: ore spec name"
             (resource-specification-name ore-spec) "Iron Ore")
      (check "hydrated: ore spec unit"
             (resource-specification-default-unit-of-resource ore-spec) "kg"))

    (let ((ingot-spec ($ rs 'get-resource-spec "spec-ingot")))
      (check-pred "hydrated: ingot spec exists" (resource-specification? ingot-spec))
      (check "hydrated: ingot spec name"
             (resource-specification-name ingot-spec) "Iron Ingot"))

    ;; Process specs survived
    (check "hydrated: process-specs count" (length ($ rs 'all-process-specs)) 1)
    (let ((pspec ($ rs 'get-process-spec "pspec-smelt")))
      (check-pred "hydrated: smelt pspec exists" (process-specification? pspec))
      (check "hydrated: smelt pspec name"
             (process-specification-name pspec) "Smelting"))

    ;; Recipe survived with correct topo sort
    (check "hydrated: recipes count" (length ($ rs 'all-recipes)) 1)
    (let ((chain ($ rs 'get-process-chain "recipe-ingots")))
      (check-pred "hydrated: chain non-empty" (pair? chain))
      (check "hydrated: chain first = rp-smelt"
             (recipe-process-id (car chain)) "rp-smelt")
      (check "hydrated: chain length" (length chain) 1))

    ;; Flows survived — flows-for-process returns (cons inputs outputs)
    (let ((flows ($ rs 'flows-for-process "rp-smelt")))
      (check-pred "hydrated: smelt has inputs"
                  (pair? (car flows)))
      (check-pred "hydrated: smelt has outputs"
                  (pair? (cdr flows)))
      (let ((inputs (car flows)))
        (check-pred "hydrated: input is ore"
                    (any (lambda (f) (equal? "spec-ore"
                                              (recipe-flow-resource-conforms-to f)))
                         inputs)))
      (let ((outputs (cdr flows)))
        (check-pred "hydrated: output is ingot"
                    (any (lambda (f) (equal? "spec-ingot"
                                              (recipe-flow-resource-conforms-to f)))
                         outputs))))))
;;; ── 2b. Plan-store round-trip ─────────────────────────────────────────────

(display "\n  Verifying plan-store hydration...\n")

(with-vat vat2
  (let ((ps ($ scope2 'plan-store)))

    ;; Plan survived
    (check-pred "hydrated: plan exists" (plan? ($ ps 'get-plan "plan-smelt")))
    (check "hydrated: plan name"
           (plan-name ($ ps 'get-plan "plan-smelt")) "Weekly Smelting Plan")

    ;; Intents survived
    (check "hydrated: intents count" (length ($ ps 'all-intents)) 2)

    ;; Ore intent is finished (was promoted to commitment)
    (let ((ore-intent ($ ps 'get-intent "i-ore-offer")))
      (check-pred "hydrated: ore intent exists" (intent? ore-intent))
      (check-pred "hydrated: ore intent finished" (intent-finished ore-intent))
      (check "hydrated: ore intent action" (intent-action ore-intent) 'consume))

    ;; Ingot intent is NOT finished
    (let ((ingot-intent ($ ps 'get-intent "i-ingot-need")))
      (check-pred "hydrated: ingot intent exists" (intent? ingot-intent))
      (check-pred "hydrated: ingot intent not finished"
                  (not (intent-finished ingot-intent)))
      (check "hydrated: ingot intent action" (intent-action ingot-intent) 'produce)
      (check "hydrated: ingot intent spec"
             (intent-resource-conforms-to ingot-intent) "spec-ingot"))

    ;; Commitment survived (created via promote-to-commitment)
    (check "hydrated: commitments count" (length ($ ps 'all-commitments)) 1)
    (let ((c (car ($ ps 'all-commitments))))
      (check-pred "hydrated: commitment is commitment" (commitment? c))
      (check "hydrated: commitment action" (commitment-action c) 'consume))

    ;; Offers and requests survived
    (check "hydrated: offers" (length ($ ps 'offers)) 0)   ;; was promoted, now finished
    (check "hydrated: requests" (length ($ ps 'requests)) 1)

    ;; Meta survived
    (let ((meta ($ ps 'get-meta "i-ingot-need")))
      (check-pred "hydrated: meta is alist" (pair? meta))
      (check "hydrated: meta priority"
             (assq-ref meta 'priority) "high")
      (check "hydrated: meta batch"
             (assq-ref meta 'batch) "weekly"))))
;;; ── 2c. Observer round-trip ───────────────────────────────────────────────

(display "\n  Verifying observer hydration...\n")

(with-vat vat2
  (let ((obs ($ scope2 'observer)))

    ;; Resources survived
    (check "hydrated: resources count" (length ($ obs 'all-resources)) 2)

    ;; Ore resource: 500 - 50 = 450
    (let ((ore ($ obs 'get-resource "r-ore")))
      (check-pred "hydrated: ore resource exists" (economic-resource? ore))
      (check "hydrated: ore name" (economic-resource-name ore) "Ore Stockpile")
      (check "hydrated: ore qty" (measure-has-numerical-value
                                    (economic-resource-accounting-quantity ore))
             450)
      (check "hydrated: ore unit" (measure-has-unit
                                    (economic-resource-accounting-quantity ore))
             "kg"))

    ;; Ingot resource: 0 + 10 = 10
    (let ((ingot ($ obs 'get-resource "r-ingot")))
      (check-pred "hydrated: ingot resource exists" (economic-resource? ingot))
      (check "hydrated: ingot name" (economic-resource-name ingot) "Ingot Stock")
      (check "hydrated: ingot qty" (measure-has-numerical-value
                                      (economic-resource-accounting-quantity ingot))
             10)
      (check "hydrated: ingot unit" (measure-has-unit
                                      (economic-resource-accounting-quantity ingot))
             %count-unit))

    ;; Events survived
    (check "hydrated: events count" (length ($ obs 'all-events)) 2)

    ;; Verify individual events
    (let ((events ($ obs 'all-events)))
      (check-pred "hydrated: consume event present"
                  (any (lambda (e) (and (eq? 'consume (economic-event-action e))
                                        (equal? "ev-consume-ore" (economic-event-id e))))
                       events))
      (check-pred "hydrated: produce event present"
                  (any (lambda (e) (and (eq? 'produce (economic-event-action e))
                                        (equal? "ev-produce-ingot" (economic-event-id e))))
                       events)))

    ;; Inventory survived
    (let ((inv ($ obs 'inventory)))
      (check "hydrated: inventory count" (length inv) 2))))
;;; ── 2d. Agent-store round-trip ────────────────────────────────────────────

(display "\n  Verifying agent-store hydration...\n")

(with-vat vat2
  (let ((as ($ scope2 'agent-store)))

    ;; All agents survived
    (check "hydrated: agents count" (length ($ as 'all-agents)) 3)

    ;; Individual agents retrievable
    (let ((foundry ($ as 'get-agent "agent-foundry")))
      (check-pred "hydrated: foundry exists" (agent? foundry))
      (check "hydrated: foundry name" (agent-name foundry) "Iron Foundry")
      (check "hydrated: foundry type" (agent-type foundry) 'organization))

    (let ((smith ($ as 'get-agent "agent-smith")))
      (check-pred "hydrated: smith exists" (agent? smith))
      (check "hydrated: smith name" (agent-name smith) "Smith")
      (check "hydrated: smith type" (agent-type smith) 'person))

    (let ((river ($ as 'get-agent "agent-river")))
      (check-pred "hydrated: river exists" (agent? river))
      (check "hydrated: river name" (agent-name river) "River Ecosystem")
      (check "hydrated: river type" (agent-type river) 'ecological-agent))

    ;; Type queries survived
    (check "hydrated: people count" (length ($ as 'people)) 1)))
;;; ── 2e. Scope identity ───────────────────────────────────────────────────

(display "\n  Verifying scope identity...\n")

(with-vat vat2
  (check "hydrated: scope name" ($ scope2 'name) "Hydration Test"))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Phase 3: Mutate hydrated vat and verify isolation
;;;
;;; Ensure that mutations to the restored vat work correctly and
;;; don't corrupt the original data.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Phase 3: Mutate hydrated vat ──\n")

(with-vat vat2
  (let ((obs ($ scope2 'observer))
        (as  ($ scope2 'agent-store)))

    ;; Record another event on the restored vat
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-consume-ore-2" #:action 'consume #:input-of "rp-smelt"
         #:resource-inventoried-as "r-ore" #:resource-conforms-to "spec-ore"
         #:provider "agent-foundry" #:receiver "agent-foundry"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-03T08:00:00Z"))

    ;; Verify the mutation took effect
    (check "mutated: events count" (length ($ obs 'all-events)) 3)
    (check "mutated: ore qty after 2nd consume"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity
               ($ obs 'get-resource "r-ore")))
           400)

    ;; Add another agent
    ($ as 'add-agent (make-agent #:id "agent-apprentice" #:type 'person #:name "Apprentice"))
    (check "mutated: agents count" (length ($ as 'all-agents)) 4)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Phase 4: Third hydration — verify mutations persisted
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Phase 4: Third hydration ──\n")

(define-values (vat3 scope3)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (error "Should not be called — restoring round 3!"))
    mem-store))

(with-vat vat3
  (let ((obs ($ scope3 'observer))
        (as  ($ scope3 'agent-store)))

    ;; Phase 3 mutations survived
    (check "round3: events" (length ($ obs 'all-events)) 3)
    (check "round3: ore qty"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity
               ($ obs 'get-resource "r-ore")))
           400)
    (check "round3: agents" (length ($ as 'all-agents)) 4)
    (check-pred "round3: apprentice exists"
                (agent? ($ as 'get-agent "agent-apprentice")))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
