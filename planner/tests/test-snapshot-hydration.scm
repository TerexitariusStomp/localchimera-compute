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

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

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
    scope-env
    (lambda () (spawn-scope "Hydration Test"))
    mem-store))


;;; ── 1a. Recipe-store ──────────────────────────────────────────────────────

(display "\n  Seeding recipe-store...\n")

(with-vat vat1
  (let ((rs ($ scope1 'recipe-store)))

    ;; Resource specifications
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-ore" "Iron Ore" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-ingot" "Iron Ingot" #f #f #f "each" #f #f #f #f #f))

    ;; Process specifications
    ($ rs 'add-process-spec
       (make-process-specification "pspec-smelt" "Smelting" #f #f #f #f #f #f #f))

    ;; Recipe process
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-smelt" "Smelt ore" #f #f "pspec-smelt" #f
                            (make-duration 3 "hours") #f #f))

    ;; Recipe flows
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-ore-in" 'consume "spec-ore" #f
                         (make-measure 50 "kg") #f "rp-smelt" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-ingot-out" 'produce "spec-ingot" #f
                         (make-measure 10 "each") #f #f "rp-smelt" #f #f #f #f #f #f))

    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe "recipe-ingots" "Ingot Production" #f #f "spec-ingot"
                    (list "rp-smelt") #f))

    (check-pred "recipe-store seeded" #t)))


;;; ── 1b. Plan-store ────────────────────────────────────────────────────────

(display "\n  Seeding plan-store...\n")

(with-vat vat1
  (let ((ps ($ scope1 'plan-store)))

    ;; Plan
    ($ ps 'add-plan (make-plan "plan-smelt" "Weekly Smelting Plan" #f
                               "2026-04-07T00:00:00Z" "2026-04-01T00:00:00Z"
                               #f #f #f))

    ;; Intent: ore offer
    ($ ps 'add-intent
       (make-intent "i-ore-offer" 'consume "Ore for smelting" #f #f
                    "rp-smelt" #f #f "spec-ore" (list "tag:plan:offer")
                    (make-measure 50 "kg") #f #f #f
                    "agent-foundry" #f
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-smelt" #f #f #f #f))

    ;; Intent: ingot request
    ($ ps 'add-intent
       (make-intent "i-ingot-need" 'produce "Ingot demand" #f #f
                    #f "rp-smelt" #f "spec-ingot" (list "tag:plan:request")
                    (make-measure 10 "each") #f #f #f
                    #f "agent-foundry"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-smelt" #f #f #f #f))

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
         "r-ore" "Ore Stockpile" #f #f #f "spec-ore" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         #f #f "agent-foundry" #f #f #f #f #f #f #f #f))

    ;; Seed ingot resource
    ($ obs 'seed-resource
       (make-economic-resource
         "r-ingot" "Ingot Stock" #f #f #f "spec-ingot" #f
         (make-measure 0 "each") (make-measure 0 "each")
         #f #f "agent-foundry" #f #f #f #f #f #f #f #f))

    ;; Record consume-ore event
    ($ obs 'record-event
       (make-economic-event
         "ev-consume-ore" 'consume "rp-smelt" #f
         "r-ore" #f "spec-ore" #f
         "agent-foundry" "agent-foundry"
         (make-measure 50 "kg") #f
         #f #f "2026-04-02T08:00:00Z" #f
         #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Record produce-ingot event
    ($ obs 'record-event
       (make-economic-event
         "ev-produce-ingot" 'produce #f "rp-smelt"
         "r-ingot" #f "spec-ingot" #f
         "agent-foundry" "agent-foundry"
         (make-measure 10 "each") #f
         #f #f "2026-04-02T11:00:00Z" #f
         #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (check-pred "observer seeded" #t)))


;;; ── 1d. Agent-store ───────────────────────────────────────────────────────

(display "\n  Seeding agent-store...\n")

(with-vat vat1
  (let ((as ($ scope1 'agent-store)))

    ($ as 'add-agent (make-agent "agent-foundry" 'organization "Iron Foundry"
                                  #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-smith" 'person "Smith" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "agent-river" 'ecological-agent "River Ecosystem"
                                  #f #f #f #f #f))

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
    scope-env
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
             "each"))

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
         "ev-consume-ore-2" 'consume "rp-smelt" #f
         "r-ore" #f "spec-ore" #f
         "agent-foundry" "agent-foundry"
         (make-measure 50 "kg") #f
         #f #f "2026-04-03T08:00:00Z" #f
         #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Verify the mutation took effect
    (check "mutated: events count" (length ($ obs 'all-events)) 3)
    (check "mutated: ore qty after 2nd consume"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity
               ($ obs 'get-resource "r-ore")))
           400)

    ;; Add another agent
    ($ as 'add-agent (make-agent "agent-apprentice" 'person "Apprentice" #f #f #f #f #f))
    (check "mutated: agents count" (length ($ as 'all-agents)) 4)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Phase 4: Third hydration — verify mutations persisted
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Phase 4: Third hydration ──\n")

(define-values (vat3 scope3)
  (spawn-persistent-vat
    scope-env
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
(when (> fail-count 0) (exit 1))
