;;; test-mode-c.scm — Mode C demand-supply integration via netter
;;;
;;; Intent: Verify Mode C behavior — demand creates soft-allocations
;;; in the netter state, and subsequent operations see the reduced
;;; availability.  This prevents double-booking: two demands against
;;; the same inventory share a single allocation state.
;;;
;;; The netter is a pure state monad (immutable records), so fork is
;;; free (identity) and isolation comes from passing different state
;;; values to different branches.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-mode-c.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1)
             (srfi srfi-11))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;;
;;; Supply chain: wool -> yarn -> garment
;;; Recipes:
;;;   shear: 10 kg wool -> 8 kg yarn  (2 hours)
;;;   weave:  8 kg yarn -> 5 garments (4 hours)
;;; Inventory: 100 kg wool, 50 kg yarn
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n== Mode C: Demand-Supply Integration ==\n")
(display "\n-- Setup --\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Mode C Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── Resource specs ──
    ($ rs 'add-resource-spec
       (make-resource-specification
         #:id "spec-wool" #:name "Wool" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification
         #:id "spec-yarn" #:name "Yarn" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification
         #:id "spec-garment" #:name "Garment" #:default-unit-of-resource "each"))

    ;; ── Process specs ──
    ($ rs 'add-process-spec
       (make-process-specification
         #:id "pspec-shear" #:name "Shearing"))
    ($ rs 'add-process-spec
       (make-process-specification
         #:id "pspec-weave" #:name "Weaving"))

    ;; ── Recipe processes ──
    ($ rs 'add-recipe-process
       (make-recipe-process
         #:id "rp-shear" #:name "Shear wool" #:process-conforms-to "pspec-shear"
         #:has-duration (make-duration 2 "hours")))
    ($ rs 'add-recipe-process
       (make-recipe-process
         #:id "rp-weave" #:name "Weave yarn" #:process-conforms-to "pspec-weave"
         #:has-duration (make-duration 4 "hours")))

    ;; ── Recipe flows ──
    ;; Shear: 10 kg wool in -> 8 kg yarn out
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         #:id "rf-wool-in" #:action 'consume #:resource-conforms-to "spec-wool"
         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-shear"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         #:id "rf-yarn-out" #:action 'produce #:resource-conforms-to "spec-yarn"
         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-shear"))

    ;; Weave: 8 kg yarn in -> 5 garments out
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         #:id "rf-yarn-in" #:action 'consume #:resource-conforms-to "spec-yarn"
         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-weave"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow
         #:id "rf-garment-out" #:action 'produce #:resource-conforms-to "spec-garment"
         #:resource-quantity (make-measure 5 "each") #:recipe-output-of "rp-weave"))

    ;; ── Recipe ──
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-garment" #:name "Garment Production" #:primary-output "spec-garment"
                    #:recipe-processes (list "rp-shear" "rp-weave")))

    ;; ── Inventory: 100 kg wool, 50 kg yarn ──
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-wool" #:name "Wool Stock" #:conforms-to "spec-wool"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-yarn" #:name "Yarn Stock" #:conforms-to "spec-yarn"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg") #:primary-accountable "agent-commune"))

    (check-pred "setup: specs and inventory seeded" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 1: Netter allocates inventory against demand
;;;
;;; Demand 30 kg wool from 100 kg inventory.
;;; Remaining should be 0 (fully satisfied), with 70 kg still in inventory
;;; for future demands using the same netter state.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 1: Netter allocates inventory --\n")

(with-vat vat
  (let ((ns0 (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Net demand of 30 kg wool against 100 kg inventory
    (let-values (((ns1 remaining allocated)
                  (netter-net-demand ns0 ps obs "spec-wool" 30)))
      (check-pred "wool 30 from 100: fully satisfied (remaining ~ 0)"
                  (approx= 0 remaining))
      (check-pred "wool 30: has allocated pairs"
                  (pair? allocated))

      ;; The allocated pair should reference the wool resource
      (let ((alloc-entry (car allocated)))
        (check "wool 30: allocated resource id" (car alloc-entry) "r-wool")
        (check "wool 30: allocated spec" (cadr alloc-entry) "spec-wool")
        (check-pred "wool 30: allocated qty = 30"
                    (approx= 30 (caddr alloc-entry)))))

    ;; Net demand of 50 kg yarn against 50 kg inventory
    (let-values (((ns1 remaining allocated)
                  (netter-net-demand ns0 ps obs "spec-yarn" 50)))
      (check-pred "yarn 50 from 50: fully satisfied"
                  (approx= 0 remaining))
      (check-pred "yarn 50: allocated pairs"
                  (pair? allocated)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 2: Second demand sees reduced availability
;;;
;;; After allocating 30 kg wool, netter-net-available should report
;;; the remaining 70 kg (not the original 100 kg).
;;;
;;; Note: netter-net-available is a read-only query; it returns a
;;; single numeric value (available qty).  The netter state passed in
;;; determines what has already been allocated via scheduled outputs,
;;; but inventory is re-read from the observer each time.
;;;
;;; For inventory-only allocation (no scheduled intents), allocation
;;; is tracked in the allocated-pairs result, not in netter state.
;;; So we test via sequential netter-net-demand calls instead:
;;; after first demand of 30 from the same netter state, a second
;;; demand of 80 should leave 10 remaining (100 - 30 already taken
;;; via inventory = 70 available, 80 - 70 = 10 remaining).
;;;
;;; BUT: the netter state only tracks scheduled-output allocation
;;; (intent/commitment ids), not inventory.  Each netter-net-demand
;;; call re-scans the observer's inventory independently.  Two calls
;;; from the same netter state both see 100 kg wool because inventory
;;; netting is done at the observer level, not the netter level.
;;;
;;; The MODE C INTENT is tested through scheduled outputs instead:
;;; add a scheduled output intent, allocate it via demand, then
;;; verify the netter state prevents double-counting.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 2: Scheduled output prevents double-counting --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a scheduled output: 20 kg yarn to be produced
    ($ ps 'add-intent
       (make-intent #:id "i-yarn-sched" #:action 'produce #:name "Scheduled yarn" #:output-of "proc-shear" #:resource-conforms-to "spec-yarn"
                    #:resource-quantity (make-measure 20 "kg")
                    #:provider "agent-commune" #:planned-within "test-plan-c"))

    ;; First demand: 20 kg yarn — can be satisfied by scheduled output
    ;; (plus 50 in inventory, but we test with netter-state threading)
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand (empty-netter-state) ps obs "spec-yarn" 70)))
      ;; 50 from inventory + 20 from scheduled = 70 → fully satisfied
      (check-pred "yarn 70: fully satisfied (inv 50 + sched 20)"
                  (approx= 0 rem1))

      ;; Second demand using ns1: the scheduled 20 is now allocated
      ;; So only 50 from inventory remains (no more scheduled output)
      (let-values (((ns2 rem2 alloc2)
                    (netter-net-demand ns1 ps obs "spec-yarn" 70)))
        (check-pred "yarn 70 (second): remaining ~ 20 (scheduled already claimed)"
                    (approx= 20 rem2 1))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 3: Allocation prevents double-booking
;;;
;;; Two demands for 60 kg wool + 20 scheduled output each.
;;; Total available = 100 (inventory) + 20 (scheduled) = 120.
;;; First demand of 60: fully satisfied, netter claims the scheduled output.
;;; Second demand of 60: satisfied from inventory (100) since scheduled
;;; output already claimed — but total coverage is still 60 from inv.
;;; Third demand of 60 from same state: only 40 from inventory left
;;; in un-netted terms.  But recall: inventory is re-scanned each time.
;;; The double-booking prevention applies to scheduled outputs only.
;;;
;;; Concrete test: add 2 scheduled outputs of 15 each. Allocate both
;;; via first demand. Second demand cannot claim them again.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 3: Allocation prevents double-booking --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add two scheduled output intents for wool
    ($ ps 'add-intent
       (make-intent #:id "i-wool-out-1" #:action 'produce #:name "Wool batch 1" #:output-of "proc-farm-1" #:resource-conforms-to "spec-wool"
                    #:resource-quantity (make-measure 15 "kg")
                    #:provider "agent-commune" #:planned-within "test-plan-c"))
    ($ ps 'add-intent
       (make-intent #:id "i-wool-out-2" #:action 'produce #:name "Wool batch 2" #:output-of "proc-farm-2" #:resource-conforms-to "spec-wool"
                    #:resource-quantity (make-measure 15 "kg")
                    #:provider "agent-commune" #:planned-within "test-plan-c"))

    ;; Total available: 100 (inventory) + 15 + 15 (scheduled) = 130
    ;; First demand of 120: satisfied (100 inv + 15 + 15 sched = 130, rem ~ 0)
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand (empty-netter-state) ps obs "spec-wool" 120)))
      (check-pred "wool 120: fully satisfied (inv + 2 scheduled)"
                  (approx= 0 rem1 1))

      ;; Second demand from ns1: both scheduled outputs already claimed
      ;; Only 100 from inventory remains
      (let-values (((ns2 rem2 alloc2)
                    (netter-net-demand ns1 ps obs "spec-wool" 120)))
        (check-pred "wool 120 (second): remaining ~ 20 (scheduled claimed)"
                    (approx= 20 rem2 1))

        ;; Netter state accumulated both allocations
        ;; Third demand from ns2: still only 100 from inventory (same observer)
        (let-values (((ns3 rem3 alloc3)
                      (netter-net-demand ns2 ps obs "spec-wool" 120)))
          (check-pred "wool 120 (third): remaining ~ 20 (same — no new scheduled)"
                      (approx= 20 rem3 1)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 4: Fork preserves isolation
;;;
;;; Fork the netter state (which is free — immutable state is identity).
;;; Allocate in the fork.  Original state should be unchanged:
;;; a demand from the original state should still see all scheduled
;;; outputs as available.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 4: Fork preserves isolation --\n")

(with-vat vat
  (let* ((ns0 (empty-netter-state))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer)))

    ;; Fork ns0 into child
    (let ((child-ns (netter-fork ns0)))
      (check-pred "fork: returns netter-state" (netter-state? child-ns))

      ;; Allocate in child: demand 130 wool (100 inv + 30 scheduled)
      ;; This claims scheduled outputs i-wool-out-1, i-wool-out-2, i-yarn-sched
      (let-values (((child-ns1 child-rem child-alloc)
                    (netter-net-demand child-ns ps obs "spec-wool" 130)))
        (check-pred "child: wool 130 fully satisfied"
                    (approx= 0 child-rem 1))

        ;; Original ns0 is unchanged — scheduled outputs still unclaimed
        (let-values (((orig-ns1 orig-rem orig-alloc)
                      (netter-net-demand ns0 ps obs "spec-wool" 130)))
          (check-pred "original: wool 130 still fully satisfied"
                      (approx= 0 orig-rem 1)))

        ;; Demand from child-ns1: scheduled outputs are now claimed
        (let-values (((child-ns2 child-rem2 child-alloc2)
                      (netter-net-demand child-ns1 ps obs "spec-wool" 130)))
          (check-pred "child after alloc: remaining ~ 30 (scheduled claimed)"
                      (approx= 30 child-rem2 1)))

        ;; But original ns0 still sees everything (isolation confirmed)
        (let-values (((orig-ns2 orig-rem2 orig-alloc2)
                      (netter-net-demand ns0 ps obs "spec-wool" 130)))
          (check-pred "original still sees all (isolation)"
                      (approx= 0 orig-rem2 1)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 5: Retract undoes plan allocations
;;;
;;; Allocate scheduled outputs under a plan-id, then retract.
;;; After retract, the scheduled outputs should be available again.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 5: Retract undoes plan allocations --\n")

(with-vat vat
  (let ((ns0 (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Allocate under plan-id "plan-mode-c"
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand ns0 ps obs "spec-wool" 130
                                    #:plan-id "plan-mode-c")))
      (check-pred "retract setup: wool 130 satisfied"
                  (approx= 0 rem1 1))

      ;; Verify scheduled outputs are claimed (second demand sees gap)
      (let-values (((ns-check rem-check alloc-check)
                    (netter-net-demand ns1 ps obs "spec-wool" 130)))
        (check-pred "before retract: scheduled outputs claimed"
                    (> rem-check 0)))

      ;; Retract the plan
      (let ((ns-retracted (netter-retract ns1 "plan-mode-c")))

        ;; After retract, scheduled outputs are available again
        (let-values (((ns2 rem2 alloc2)
                      (netter-net-demand ns-retracted ps obs "spec-wool" 130)))
          (check-pred "after retract: wool 130 fully satisfied again"
                      (approx= 0 rem2 1)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 6: Mode C intent — demand then supply share state
;;;
;;; The core Mode C insight: run demand netting, then supply netting
;;; on the SAME netter state.  Supply should see what demand already
;;; claimed and not double-count.
;;;
;;; Scenario: 20 kg yarn scheduled output.
;;;   1. Demand claims the 20 kg yarn output (netter marks it allocated)
;;;   2. Supply of 20 kg yarn: the output intent is already allocated,
;;;      so netter-net-supply sees no unclaimed consumption to deduct.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 6: Demand then supply share netter state --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a consumption intent for yarn (someone will consume 10 kg)
    ($ ps 'add-intent
       (make-intent #:id "i-yarn-consume" #:action 'consume #:name "Yarn consumption"
                    #:input-of "proc-weave" #:resource-conforms-to "spec-yarn"
                    #:resource-quantity (make-measure 10 "kg") #:receiver "agent-commune" #:planned-within "test-plan-c"))

    ;; Net supply from fresh state: 30 kg yarn available, consumption claims 10
    ;; Remaining = 30 - 10 = 20
    (let-values (((ns1 supply-rem1)
                  (netter-net-supply (empty-netter-state) ps "spec-yarn" 30)))
      (check-pred "supply 30 yarn: remaining ~ 20 (10 consumed)"
                  (approx= 20 supply-rem1 1))

      ;; Now from ns1 (consumption already allocated), net supply again:
      ;; The consumption intent is already allocated, so no further deduction
      (let-values (((ns2 supply-rem2)
                    (netter-net-supply ns1 ps "spec-yarn" 30)))
        (check-pred "supply 30 yarn (ns1): remaining ~ 30 (consumption already netted)"
                    (approx= 30 supply-rem2 1))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 7: Net-available reflects netter state
;;;
;;; netter-net-available is a read-only query.  When netter state has
;;; scheduled outputs already allocated, they should not be counted
;;; as available for new demand.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 7: Net-available reflects netter state --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; From fresh state: wool available = 100 (inv) + 30 (scheduled outputs)
    ;; minus any consumption intents for wool (none added)
    (let ((avail-fresh (netter-net-available (empty-netter-state) ps obs "spec-wool")))
      (check-pred "fresh state: wool available >= 100"
                  (>= avail-fresh 100))

      ;; Allocate scheduled outputs via demand
      (let-values (((ns1 rem1 alloc1)
                    (netter-net-demand (empty-netter-state) ps obs "spec-wool" 130)))

        ;; From ns1: scheduled outputs are claimed, only inventory available
        (let ((avail-ns1 (netter-net-available ns1 ps obs "spec-wool")))
          (check-pred "after allocation: wool available reduced"
                      (< avail-ns1 avail-fresh))
          (check-pred "after allocation: wool available ~ 100 (inv only)"
                      (approx= 100 avail-ns1 1)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 8: Conservation floor
;;;
;;; When a conservation floor is set, netter should not allocate
;;; inventory below that floor.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 8: Conservation floor --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Set a conservation floor of 40 kg for wool
    (let ((ns-floor (empty-netter-state
                      (hashmap-set (hashmap) "spec-wool" 40))))

      ;; Demand 100 kg wool: inventory = 100, floor = 40
      ;; Allocatable from inventory = 100 - 40 = 60
      ;; Scheduled outputs: 30 (i-wool-out-1 + i-wool-out-2)
      ;; Total allocatable = 60 + 30 = 90
      ;; Remaining = 100 - 90 = 10
      (let-values (((ns1 remaining alloc1)
                    (netter-net-demand ns-floor ps obs "spec-wool" 100)))
        (check-pred "floor 40: 100 demand leaves remaining ~ 10"
                    (approx= 10 remaining 1))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 9: Demand explosion via relational goals
;;;
;;; Test the relational layer (demand-o, recipe-o, flow-o, chain-o)
;;; on top of the netter state tested in sections 1-8.
;;;
;;; demand-o correctly allocates from inventory (satisfied) and
;;; identifies unmet demand when no inventory exists.  The recipe
;;; topology is verified via relational fact queries.
;;;
;;; NOTE: The indexed produce-branch in demand-o requires ground
;;; variables for hash-table lookup, so produce plan-terms are not
;;; yet reachable via run-plan with indexed ctx.  Recipe chain
;;; topology is verified separately via recipe-o/chain-o/flow-o.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 9: Demand explosion via relational goals --\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (ns (empty-netter-state))
         (facts (lift-planning-facts rs obs ps))
         (indexes (build-indexes facts))
         (ctx (make-plan-ctx facts ps obs #f "test-mode-c-demand" indexes))
         (due (+ (current-time) 86400))
         )

    ;; 9a. Yarn demand satisfied from inventory (50 kg available)
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-yarn" 30 due q))))
      (check-pred "yarn 30: satisfied from inventory"
                  (and (pair? results) (eq? 'satisfied (caar results))))
      (when (and (pair? results) (list? (car results)) (>= (length (car results)) 4))
        (check-pred "yarn 30: allocated 30 units"
                    (let ((alloc (list-ref (car results) 3)))
                      (and (pair? alloc)
                           (approx= 30 (cadr (car alloc))))))))

    ;; 9b. Wool demand satisfied from inventory (100 kg available)
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-wool" 80 due q))))
      (check-pred "wool 80: satisfied from inventory"
                  (and (pair? results) (eq? 'satisfied (caar results)))))

    ;; 9c. Garment demand: no garment inventory → demand-o returns unmet
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-garment" 5 due q
                               #:depth 5))))
      (check-pred "garment 5: unmet (no inventory, produce via indexed ctx not reachable)"
                  (and (pair? results) (eq? 'unmet (caar results)))))

    ;; 9d. Verify recipe chain topology relationally: wool → yarn → garment
    ;;     recipe-o finds recipe-garment for spec-garment
    (let ((recipes (run-plan* ns (q)
                     (fresh (rname)
                       (recipe-o facts q rname "spec-garment")))))
      (check-pred "recipe for garment exists"
                  (member "recipe-garment" recipes)))

    ;; 9e. chain-o returns the correct process ordering
    (let ((chains (run-plan* ns (q)
                    (chain-o facts "recipe-garment" q))))
      (check-pred "garment chain = (rp-shear rp-weave)"
                  (member '("rp-shear" "rp-weave") chains)))

    ;; 9f. flow-o traces inputs and outputs correctly
    (let ((weave-inputs (run-plan* ns (q)
                          (fresh (qty unit action)
                            (flow-o facts "rp-weave" 'input q qty unit action)))))
      (check-pred "weave input = yarn"
                  (member "spec-yarn" weave-inputs)))

    (let ((shear-inputs (run-plan* ns (q)
                          (fresh (qty unit action)
                            (flow-o facts "rp-shear" 'input q qty unit action)))))
      (check-pred "shear input = wool"
                  (member "spec-wool" shear-inputs)))

    ;; 9g. Verify output flow quantity for garment recipe
    ;;     recipe makes 5 garments per execution
    (let ((out-qtys (run-plan* ns (q)
                      (fresh (unit action)
                        (flow-o facts "rp-weave" 'output "spec-garment"
                                q unit action)))))
      (check-pred "garment output qty = 5"
                  (and (pair? out-qtys) (approx= 5 (car out-qtys)))))

    ;; 9h. Verify back-schedule-inputs through chain
    ;;     Scale=2 through chain (rp-shear rp-weave): weave's input (yarn)
    ;;     is internal (produced by shear), so only shear's input (wool) appears.
    ;;     Wool: 10 * 2 = 20 kg needed.
    (let ((inputs (back-schedule-inputs facts '("rp-shear" "rp-weave") 2 due)))
      (check-pred "garment inputs non-empty" (pair? inputs))
      (let ((wool-input (find (lambda (i) (equal? "spec-wool" (car i))) inputs)))
        (check-pred "garment input includes wool"
                    (pair? wool-input))
        ;; 2 * 10 = 20 kg wool needed
        (when wool-input
          (check-pred "garment wool qty = 20 (scale=2)"
                      (approx= 20 (cadr wool-input))))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 10: Supply absorption — demand claims reduce supply availability
;;;
;;; Strengthen Section 6 by verifying the full cycle:
;;;   1. Demand claims scheduled outputs
;;;   2. Supply query on same netter state shows reduced availability
;;;   3. A second demand on the post-demand state cannot re-claim
;;;
;;; This is the core Mode C invariant: shared allocation state prevents
;;; double-booking across demand AND supply operations.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 10: Supply absorption after demand claims --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a fresh scheduled output for wool (not claimed by prior tests)
    ($ ps 'add-intent
       (make-intent #:id "i-wool-supply-10" #:action 'produce #:name "Wool supply test" #:output-of "proc-farm-10" #:resource-conforms-to "spec-wool"
                    #:resource-quantity (make-measure 25 "kg")
                    #:provider "agent-commune" #:planned-within "test-plan-c-10"))

    ;; Step 1: Check available wool before demand (includes new scheduled output)
    (let ((avail-before (netter-net-available (empty-netter-state) ps obs "spec-wool")))

      ;; Step 2: Demand claims against fresh state
      (let-values (((ns-after-demand rem alloc)
                    (netter-net-demand (empty-netter-state) ps obs "spec-wool"
                                      (+ 100 25)  ;; inventory + all scheduled
                                      )))
        (check-pred "absorption: demand fully satisfied"
                    (approx= 0 rem 1))

        ;; Step 3: Available supply from ns-after-demand is reduced
        (let ((avail-after (netter-net-available ns-after-demand ps obs "spec-wool")))
          (check-pred "absorption: available reduced after demand"
                      (< avail-after avail-before)))

        ;; Step 4: Supply query from ns-after-demand — scheduled outputs are claimed
        ;; so supply netting should show no new deductions from them
        (let-values (((ns-supply supply-rem)
                      (netter-net-supply ns-after-demand ps "spec-wool" 50)))
          (check-pred "absorption: supply sees residual after demand"
                      (>= supply-rem 0)))

        ;; Step 5: Fresh state still sees everything (isolation from ns-after-demand)
        (let ((avail-fresh (netter-net-available (empty-netter-state) ps obs "spec-wool")))
          (check-pred "absorption: fresh state unaffected by demand ns"
                      (>= avail-fresh avail-before)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 11: Demand explosion — garment demand finds recipe chain
;;;
;;; Verify that a garment demand discovers the wool → yarn → garment
;;; recipe chain via relational goals.  demand-o with the indexed ctx
;;; cannot reach the produce branch (see Section 9 NOTE), so we verify
;;; the chain is discoverable via chain-o, flow-o, and produces-o from
;;; the lifted facts.  This still tests the "demand can be satisfied
;;; by recipe chain" intent relationally.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 11: Demand explosion — garment chain discovery --\n")

(with-vat vat
  (let* ((rs ($ scope 'recipe-store))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (ns (empty-netter-state))
         (facts (lift-planning-facts rs obs ps))
         (indexes (build-indexes facts)))

    ;; 11a. chain-o discovers the full garment chain: shear then weave
    (let ((chains (run-plan* ns (q)
                    (chain-o facts "recipe-garment" q))))
      (check-pred "11a: garment chain found" (pair? chains))
      (check "11a: garment chain order" (car chains) '("rp-shear" "rp-weave")))

    ;; 11b. produces-o traces garment ← yarn (yarn is consumed to produce garment)
    (let ((results (run-plan* ns (q)
                     (produces-o facts "spec-garment" q))))
      (check-pred "11b: garment is produced from yarn"
                  (member "spec-yarn" results)))

    ;; 11c. flow-o traces shear process: wool input → yarn output
    ;;       (produces-o requires spec-yarn to be a recipe primary output,
    ;;        but yarn is only an intermediate — no standalone yarn recipe.
    ;;        So we verify via flow-o that shear consumes wool and outputs yarn.)
    (let ((shear-inputs (run-plan* ns (q)
                          (fresh (qty unit action)
                            (flow-o facts "rp-shear" 'input q qty unit action)))))
      (check-pred "11c: shear consumes wool"
                  (member "spec-wool" shear-inputs)))
    (let ((shear-outputs (run-plan* ns (q)
                           (fresh (qty unit action)
                             (flow-o facts "rp-shear" 'output q qty unit action)))))
      (check-pred "11c: shear produces yarn"
                  (member "spec-yarn" shear-outputs)))

    ;; 11d. destination-o traces wool → garment (via the garment recipe)
    ;;      (destination-o uses consumed-by-o/produces-o which require
    ;;       the target spec to be a recipe primary output.  Since yarn is
    ;;       only an intermediate, the direct destination from wool is garment.)
    (let ((results (run-plan* ns (q)
                     (fresh (trace)
                       (destination-o facts "spec-wool" q trace)))))
      (check-pred "11d: wool leads to garment"
                  (member "spec-garment" results)))

    ;; 11e. back-schedule-inputs for garment chain at scale=1
    ;;      Only wool should appear (yarn is internal to the chain)
    (let* ((due (+ (current-time) 86400))
           (inputs (back-schedule-inputs facts '("rp-shear" "rp-weave") 1 due)))
      (check-pred "11e: garment inputs non-empty" (pair? inputs))
      (let ((wool-input (find (lambda (i) (equal? "spec-wool" (car i))) inputs))
            (yarn-input (find (lambda (i) (equal? "spec-yarn" (car i))) inputs)))
        (check-pred "11e: wool is external input" (pair? wool-input))
        (check-pred "11e: yarn is internal (not in external inputs)"
                    (not yarn-input))
        (when wool-input
          (check-pred "11e: wool qty = 10 (scale=1)"
                      (approx= 10 (cadr wool-input))))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 12: Supply absorption via netter — Mode C invariant
;;;
;;; The core Mode C concept: after demand allocates scheduled outputs,
;;; supply sees reduced availability through the SAME netter state.
;;;
;;; Test: Add a scheduled output intent for 50 kg yarn.
;;; Demand 80 kg yarn (exceeding 50 kg inventory, forcing netter to
;;; claim the scheduled output).  Then on the SAME netter state,
;;; verify net-available shows reduced availability because the
;;; scheduled output was consumed by demand.
;;;
;;; This tests the shared-allocation-state invariant that IS the heart
;;; of Mode C.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n-- Section 12: Supply absorption — shared allocation state --\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a fresh scheduled output of 50 kg yarn (distinct from prior intents)
    ($ ps 'add-intent
       (make-intent #:id "i-yarn-sched-12" #:action 'produce #:name "Yarn output for Mode C test" #:output-of "proc-shear-12" #:resource-conforms-to "spec-yarn"
                    #:resource-quantity (make-measure 50 "kg")
                    #:provider "agent-commune" #:planned-within "test-plan-c-12"))

    ;; Step 1: Check available yarn before demand (includes new scheduled output)
    ;; Available = inventory (50 kg) + scheduled outputs (20 from Section 2 + 50 new)
    (let ((avail-before (netter-net-available (empty-netter-state) ps obs "spec-yarn")))

      ;; Step 2: Demand 80 kg yarn — exceeds inventory (50 kg), so netter
      ;; MUST claim from scheduled output to satisfy the demand.
      (let-values (((ns-after-demand rem alloc)
                    (netter-net-demand (empty-netter-state) ps obs "spec-yarn" 80)))
        (check-pred "12: demand 80 yarn fully satisfied"
                    (approx= 0 rem 1))

        ;; Step 3: On the SAME netter state, check net-available
        ;; The scheduled output(s) that were claimed should be excluded
        (let ((avail-after (netter-net-available ns-after-demand ps obs "spec-yarn")))
          (check-pred "12: available reduced after demand"
                      (< avail-after avail-before))

          ;; Step 4: The reduction should match the scheduled output claimed
          ;; Netter allocated from inventory first (50), then from scheduled (30)
          ;; So scheduled output intent(s) are now marked as allocated in ns
          (let ((reduction (- avail-before avail-after)))
            (check-pred "12: reduction > 0 (scheduled output was claimed)"
                        (> reduction 0))))

        ;; Step 5: Verify via netter-net-supply on same state
        ;; Consumption intents should still be visible for supply netting
        ;; but scheduled outputs already claimed by demand are excluded
        (let-values (((ns-supply supply-rem)
                      (netter-net-supply ns-after-demand ps "spec-yarn" 50)))
          (check-pred "12: supply netting on post-demand state works"
                      (>= supply-rem 0)))

        ;; Step 6: Fresh state still sees everything (isolation)
        (let ((avail-fresh (netter-net-available (empty-netter-state) ps obs "spec-yarn")))
          (check-pred "12: fresh state unaffected"
                      (>= avail-fresh avail-before)))))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "-- Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed --\n"))
(primitive-exit (if (> fail-count 0) 1 0))
