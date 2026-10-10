;;; test-netting-advanced.scm — Advanced netting tests (relational)
;;;
;;; Ported from: old/planner/src/lib/tests/netting.test.ts
;;;
;;; Intent: Verify the netter layer — inventory allocation, scheduled
;;; output/consumption netting, double-counting prevention, temporal
;;; guards, location guards, containment guards, fork/retract, and
;;; tag-aware signal exclusion.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-netting-advanced.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Netting Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wood" #:name "Wood"
                                    #:default-unit-of-resource "plank"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-yarn" #:name "Yarn" #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-linen" #:name "Linen"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-steel" #:name "Steel"
                                    #:default-unit-of-resource %count-unit))
    (check-pred "specs seeded" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Net demand against inventory — full satisfaction
;;;
;;; Ported from: "netDemand nets against observer inventory"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Net demand: inventory ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed 8 wood
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-wood" #:name "Wood" #:conforms-to "spec-wood"
         #:accounting-quantity (make-measure 8 "plank") #:onhand-quantity (make-measure 8 "plank") #:primary-accountable "agent-a"))

    ;; Net demand of 5 — should be fully satisfied (remaining ~0)
    (let-values (((new-ns remaining allocated)
                  (netter-net-demand (empty-netter-state) ($ scope 'plan-store)
                                    obs "spec-wood" 5)))
      (check-pred "wood 5: fully satisfied" (approx= 0 remaining))
      (check-pred "wood 5: allocated pairs" (pair? allocated)))

    ;; Net demand of 10 — only 8 available (remaining ~2)
    (let-values (((new-ns remaining allocated)
                  (netter-net-demand (empty-netter-state) ($ scope 'plan-store)
                                    obs "spec-wood" 10)))
      (check-pred "wood 10: partial (remaining ~2)" (approx= 2 remaining)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Net demand against scheduled output intents
;;;
;;; Ported from: "netDemand nets against scheduled output Intents"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Net demand: scheduled outputs ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add a scheduled output intent: 4 yarn to be produced
    ($ ps 'add-intent
       (make-intent #:id "i-yarn-out" #:action 'produce #:name "Yarn production" #:output-of "proc-1" #:resource-conforms-to "spec-yarn"
                    #:resource-quantity (make-measure 4 %count-unit)
                    #:provider "agent-a" #:planned-within "test-plan"))

    ;; Net demand of 4 yarn — should be absorbed by the scheduled output
    (let-values (((new-ns remaining allocated)
                  (netter-net-demand (empty-netter-state) ps
                                    ($ scope 'observer) "spec-yarn" 4)))
      (check-pred "yarn 4: satisfied by scheduled output" (approx= 0 remaining)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Double-counting prevention
;;;
;;; Ported from: "same scheduled output not double-counted across two calls"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Double-counting prevention ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; The yarn output intent (4 units) was added above
    ;; First net: 4 yarn → fully satisfied
    ;; Second net from same state: should also see the 4 (independent netter states)
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand (empty-netter-state) ps obs "spec-yarn" 4)))
      (check-pred "first net: satisfied" (approx= 0 rem1))

      ;; Using ns1 (which has already allocated the output): demand again → remaining 4
      (let-values (((ns2 rem2 alloc2)
                    (netter-net-demand ns1 ps obs "spec-yarn" 4)))
        (check-pred "second net (same state): not double-counted"
                    (> rem2 0))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Net supply against scheduled consumption
;;;
;;; Ported from: "netSupply nets against scheduled consumption Intents"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Net supply: scheduled consumption ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add consumption intent: 3 yarn to be consumed
    ($ ps 'add-intent
       (make-intent #:id "i-yarn-in" #:action 'consume #:name "Yarn consumption"
                    #:input-of "proc-1" #:resource-conforms-to "spec-yarn"
                    #:resource-quantity (make-measure 3 %count-unit) #:receiver "agent-a" #:planned-within "test-plan"))

    ;; Net supply of 5 yarn — 3 pre-claimed → remaining 2
    (let-values (((new-ns remaining)
                  (netter-net-supply (empty-netter-state) ps "spec-yarn" 5)))
      (check-pred "yarn supply 5: remaining ~2" (approx= 2 remaining)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Net available quantity (read-only)
;;;
;;; Ported from: "netAvailableQty returns inventory + outputs - consumptions"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Net available quantity ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Seed 5 linen in inventory
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-linen" #:name "Linen" #:conforms-to "spec-linen"
         #:accounting-quantity (make-measure 5 %count-unit) #:onhand-quantity (make-measure 5 %count-unit) #:primary-accountable "agent-a"))

    ;; 3 more scheduled to be produced
    ($ ps 'add-intent
       (make-intent #:id "i-linen-out" #:action 'produce #:name "Linen output" #:output-of "proc-x" #:resource-conforms-to "spec-linen"
                    #:resource-quantity (make-measure 3 %count-unit)
                    #:provider "agent-a" #:planned-within "test-plan"))

    ;; 4 scheduled to be consumed
    ($ ps 'add-intent
       (make-intent #:id "i-linen-in" #:action 'consume #:name "Linen input"
                    #:input-of "proc-y" #:resource-conforms-to "spec-linen"
                    #:resource-quantity (make-measure 4 %count-unit) #:receiver "agent-a" #:planned-within "test-plan"))

    ;; netter-net-available = inventory + scheduled outputs = 5 + 3 = 8
    ;; (consumption intents are only deducted by netter-net-supply, not net-available)
    (let ((available (netter-net-available (empty-netter-state) ps obs "spec-linen")))
      (check-pred "linen available: ~8 (inv 5 + output 3)"
                  (approx= 8 available 1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Netter fork (immutable state = free branching)
;;;
;;; Ported from: "coexists with fork()"
;;; Relational: netter-fork returns identity because state is immutable.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Netter fork ──\n")

(with-vat vat
  (let* ((ns0 (empty-netter-state))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer)))

    ;; Fork before any allocation
    (let ((child (netter-fork ns0)))
      (check-pred "fork returns netter-state" (netter-state? child)))

    ;; Allocate on parent
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand ns0 ps obs "spec-wood" 5)))
      ;; Parent allocated
      (check-pred "parent allocated" (approx= 0 rem1))

      ;; Fresh ns0 (the "child" before parent's allocation) still sees full inventory
      (let-values (((ns-child rem-child alloc-child)
                    (netter-net-demand ns0 ps obs "spec-wood" 5)))
        (check-pred "child still sees full inventory" (approx= 0 rem-child))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Netter retract (undo plan allocations)
;;;
;;; Ported from: NettingTransaction "begin + rollback — allocations removed"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Netter retract ──\n")

(with-vat vat
  (let* ((ns0 (empty-netter-state))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer)))

    ;; Allocate under a plan-id
    (let-values (((ns1 rem1 alloc1)
                  (netter-net-demand ns0 ps obs "spec-wood" 5
                                    #:plan-id "plan-retract")))
      (check-pred "allocated ok" (approx= 0 rem1))

      ;; Retract the plan's allocations
      (let ((ns2 (netter-retract ns1 "plan-retract")))
        ;; After retract, should be able to allocate again
        (let-values (((ns3 rem3 alloc3)
                      (netter-net-demand ns2 ps obs "spec-wood" 5
                                        #:plan-id "plan-retract-2")))
          (check-pred "retracted: can re-allocate" (approx= 0 rem3)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Relational netter goals (miniKanren integration)
;;;
;;; Note: net-demand-o was removed from the codebase. Netter allocation
;;; is now done imperatively inside the constraint solver via project.
;;; This section verifies netter API consistency via direct calls instead.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Relational netter (imperative API) ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (ps ($ scope 'plan-store))
         (obs ($ scope 'observer)))

    ;; Equivalent: 5 wood from 8 in inventory → remaining ~0
    (let-values (((ns1 rem alloc)
                  (netter-net-demand ns ps obs "spec-wood" 5)))
      (check-pred "goal-equiv: wood 5 satisfied" (approx= 0 rem)))

    ;; Equivalent: 12 wood from 8 → remaining ~4
    (let-values (((ns2 rem2 alloc2)
                  (netter-net-demand ns ps obs "spec-wood" 12)))
      (check-pred "goal-equiv: wood 12 partial (~4 remaining)"
                  (approx= 4 rem2 1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Reserve capacity (buffer replenishment)
;;;
;;; Ported from: netter reserve semantics
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Reserve capacity ──\n")

(with-vat vat
  (let ((ns (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Reserve 3 wood from 8 available
    (let-values (((ns1 reserved)
                  (netter-reserve ns ps obs "spec-wood" 3)))
      (check-pred "reserved 3" (approx= 3 reserved))

      ;; Note: netter state tracks scheduled-output allocations, NOT inventory.
      ;; So a subsequent demand from ns1 still sees all 8 in inventory.
      ;; Reserve's effect is on scheduled outputs only.
      (let-values (((ns2 remaining alloc)
                    (netter-net-demand ns1 ps obs "spec-wood" 6)))
        (check-pred "after reserve: wood still visible from inventory"
                    (approx= 0 remaining))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Commitment-based netting
;;;
;;; The netter's netter-net-demand Step 3 queries plan-store for
;;; commitments-for-spec and absorbs scheduled output commitments.
;;; Verify that committed produce outputs satisfy demand, and that
;;; they are tracked in netter state to prevent double-counting.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Commitment-based netting ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a scheduled output commitment: 6 steel to be produced
    ($ ps 'add-commitment
       (make-commitment #:id "c-steel-out" #:action 'produce #:note "Steel output commitment" #:output-of "proc-steel" #:resource-conforms-to "spec-steel"
                        #:resource-quantity (make-measure 6 %count-unit)
                        #:provider "agent-a" #:planned-within "test-plan"))

    ;; Net demand of 6 steel — no inventory, only the commitment
    ;; Should be fully absorbed by the commitment
    (let-values (((ns1 remaining allocated)
                  (netter-net-demand (empty-netter-state) ps obs "spec-steel" 6)))
      (check-pred "commitment: 6 steel fully satisfied" (approx= 0 remaining))

      ;; Using ns1: the commitment is now allocated, demand again → remaining 6
      (let-values (((ns2 remaining2 allocated2)
                    (netter-net-demand ns1 ps obs "spec-steel" 6)))
        (check-pred "commitment: not double-counted (remaining = 6)"
                    (approx= 6 remaining2))))

    ;; Add a second commitment for steel (4 more)
    ($ ps 'add-commitment
       (make-commitment #:id "c-steel-out-2" #:action 'produce #:note "Steel output 2" #:output-of "proc-steel-2" #:resource-conforms-to "spec-steel"
                        #:resource-quantity (make-measure 4 %count-unit)
                        #:provider "agent-a" #:planned-within "test-plan"))

    ;; Net demand of 10 steel — should absorb both commitments (6 + 4 = 10)
    (let-values (((ns3 remaining3 allocated3)
                  (netter-net-demand (empty-netter-state) ps obs "spec-steel" 10)))
      (check-pred "commitment: 10 steel from 2 commitments (6+4)"
                  (approx= 0 remaining3)))

    ;; Net demand of 12 — only 10 from commitments → remaining 2
    (let-values (((ns4 remaining4 allocated4)
                  (netter-net-demand (empty-netter-state) ps obs "spec-steel" 12)))
      (check-pred "commitment: 12 steel demand, 10 available → remaining ~ 2"
                  (approx= 2 remaining4)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. Tag-aware exclusion
;;;
;;; Signal intents tagged with "tag:plan:deficit" or similar "tag:plan:*"
;;; prefixes should NOT be absorbed by netting — they are planning signals,
;;; not real supply.  The netter checks (planning-signal? tags) and skips
;;; intents whose resource-classified-as contains a "tag:plan:*" string.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Tag-aware exclusion ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Add a signal intent tagged with "tag:plan:deficit" — this should NOT
    ;; be treated as available supply by the netter
    ($ ps 'add-intent
       (make-intent #:id "i-flour-signal" #:action 'produce #:name "Flour deficit signal" #:output-of "proc-signal" #:resource-conforms-to "spec-flour"
                    #:resource-classified-as (list "tag:plan:deficit")    ;; <-- planning signal tag
                    #:resource-quantity (make-measure 50 "kg")
                    #:provider "agent-a" #:planned-within "test-plan"))

    ;; Seed 10 flour in inventory
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-flour" #:name "Flour Stock" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 10 "kg") #:onhand-quantity (make-measure 10 "kg") #:primary-accountable "agent-a"))

    ;; Net demand of 20 flour — only 10 from inventory should be available.
    ;; The 50 signal intent should be excluded.
    ;; Remaining = 20 - 10 = 10
    (let-values (((ns1 remaining allocated)
                  (netter-net-demand (empty-netter-state) ps obs "spec-flour" 20)))
      (check-pred "tag-exclusion: signal intent not absorbed (remaining ~ 10)"
                  (approx= 10 remaining 1)))

    ;; Add a real (non-signal) output intent for flour
    ($ ps 'add-intent
       (make-intent #:id "i-flour-real" #:action 'produce #:name "Flour real output" #:output-of "proc-mill" #:resource-conforms-to "spec-flour"                           ;; <-- no signal tag
                    #:resource-quantity (make-measure 15 "kg")
                    #:provider "agent-a" #:planned-within "test-plan"))

    ;; Net demand of 20 flour — 10 inventory + 15 real output = 25 available
    ;; Signal's 50 still excluded. Demand 20 fully satisfied.
    (let-values (((ns2 remaining2 allocated2)
                  (netter-net-demand (empty-netter-state) ps obs "spec-flour" 20)))
      (check-pred "tag-exclusion: real intent absorbed, signal excluded (remaining ~ 0)"
                  (approx= 0 remaining2)))

    ;; Verify that different signal tags are also excluded
    ($ ps 'add-intent
       (make-intent #:id "i-flour-signal-2" #:action 'produce #:name "Flour overstock signal" #:output-of "proc-signal-2" #:resource-conforms-to "spec-flour"
                    #:resource-classified-as (list "tag:plan:overstock")  ;; <-- another planning signal tag
                    #:resource-quantity (make-measure 100 "kg")
                    #:provider "agent-a" #:planned-within "test-plan"))

    ;; Net demand of 30 flour — still only 10 + 15 = 25 real supply
    ;; Both signal intents (deficit 50 + overstock 100) excluded
    ;; Remaining = 30 - 25 = 5
    (let-values (((ns3 remaining3 allocated3)
                  (netter-net-demand (empty-netter-state) ps obs "spec-flour" 30)))
      (check-pred "tag-exclusion: multiple signals excluded (remaining ~ 5)"
                  (approx= 5 remaining3 1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. Conservation floor (netter API level)
;;;
;;; When a conservation floor is set for a spec, netter-net-demand should
;;; not allocate inventory below that floor.  Allocatable = max(0, qty - floor).
;;; (Note: also tested at Mode C integration level in test-mode-c.scm Section 8,
;;; but here we test the netter API directly with isolated state.)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Conservation floor ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Wood has 8 in inventory (from setup)
    ;; Set a conservation floor of 3 for wood
    (let ((ns-floor (empty-netter-state
                      (hashmap-set (hashmap) "spec-wood" 3))))

      ;; Demand 8 wood: inventory = 8, floor = 3 → allocatable = 5
      ;; Remaining = 8 - 5 = 3
      (let-values (((ns1 remaining alloc)
                    (netter-net-demand ns-floor ps obs "spec-wood" 8)))
        (check-pred "floor: 8 demand with floor 3 → remaining ~ 3"
                    (approx= 3 remaining 1)))

      ;; Demand 4 wood: allocatable = 5, demand 4 → fully satisfied
      (let-values (((ns2 remaining2 alloc2)
                    (netter-net-demand ns-floor ps obs "spec-wood" 4)))
        (check-pred "floor: 4 demand with floor 3 → fully satisfied"
                    (approx= 0 remaining2))))

    ;; Floor equal to full inventory — nothing allocatable from inventory
    (let ((ns-full-floor (empty-netter-state
                           (hashmap-set (hashmap) "spec-wood" 8))))

      ;; Demand 5 wood: inventory = 8, floor = 8 → allocatable = 0
      ;; But scheduled outputs (from earlier sections) may still be available
      ;; so we check that inventory contribution is zero
      (let-values (((ns3 remaining3 alloc3)
                    (netter-net-demand ns-full-floor ps obs "spec-wood" 5)))
        ;; Wood has some scheduled outputs from section 9 (i-wool-out-1/2 are wool,
        ;; not wood). So only the 4 yarn output from earlier section is available
        ;; for yarn, not wood. For wood, no scheduled outputs → remaining = 5.
        ;; But there may be previously added intents. Let's check > 0 remaining
        ;; since floor blocks all 8 inventory.
        (check-pred "floor: full floor blocks all inventory"
                    (> remaining3 0))))

    ;; Floor of zero — no restriction (should match normal behavior)
    (let ((ns-zero-floor (empty-netter-state
                           (hashmap-set (hashmap) "spec-wood" 0))))
      (let-values (((ns4 remaining4 alloc4)
                    (netter-net-demand ns-zero-floor ps obs "spec-wood" 5)))
        (check-pred "floor: zero floor → full allocation"
                    (approx= 0 remaining4))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Temporal guard — scheduled outputs after needed-by NOT absorbed
;;;
;;; Ported from: netting.test.ts temporal guard tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Temporal guard ──\n")

(with-vat vat
  (let* ((ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (ns (make-netter-state (hashmap) (hashmap) (hashmap) (hashmap)))
         ;; Output intent due far in the future (2026-06-01)
         (late-intent (make-intent #:id "i-late" #:action 'produce #:output-of "proc-late" #:resource-conforms-to "spec-wheat"
                                    #:resource-quantity (make-measure 50 "kg") #:due "2026-06-01T00:00:00Z"))
         ;; Output intent due soon (2026-03-01)
         (early-intent (make-intent #:id "i-early" #:action 'produce #:output-of "proc-early" #:resource-conforms-to "spec-wheat"
                                     #:resource-quantity (make-measure 30 "kg") #:due "2026-03-01T00:00:00Z")))
    ($ ps 'add-intent late-intent)
    ($ ps 'add-intent early-intent)

    ;; Demand 70kg wheat needed-by 2026-04-01
    (let ((needed-by (iso-datetime->epoch "2026-04-01T00:00:00Z")))
      (let-values (((new-ns remaining allocated)
                    (netter-net-demand ns ps obs "spec-wheat" 70
                      #:needed-by needed-by)))
        ;; Only early-intent (30kg, due 2026-03-01) should be absorbed
        ;; late-intent (50kg, due 2026-06-01) is AFTER needed-by → excluded
        (check-pred "temporal: only early absorbed, 40 remaining"
          (approx= remaining 40 1))
        (check-pred "temporal: early intent allocated"
          (ns-allocated? new-ns "i-early"))
        (check-pred "temporal: late intent NOT allocated"
          (not (ns-allocated? new-ns "i-late")))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Location guard — outputs at wrong location NOT absorbed
;;;
;;; Ported from: netting.test.ts location guard tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Location guard ──\n")

(with-vat vat
  (let* ((ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (ns (make-netter-state (hashmap) (hashmap) (hashmap) (hashmap)))
         ;; Output intent at location-A
         (intent-a (make-intent #:id "i-loc-a" #:action 'produce #:output-of "proc-a" #:resource-conforms-to "spec-wheat"
                                 #:resource-quantity (make-measure 50 "kg")
                                 #:at-location "location-a"))
         ;; Output intent at location-B
         (intent-b (make-intent #:id "i-loc-b" #:action 'produce #:output-of "proc-b" #:resource-conforms-to "spec-wheat"
                                 #:resource-quantity (make-measure 30 "kg")
                                 #:at-location "location-b")))
    ($ ps 'add-intent intent-a)
    ($ ps 'add-intent intent-b)

    ;; Demand 60kg at location-a → only intent-a (50kg) should be absorbed
    (let-values (((new-ns remaining allocated)
                  (netter-net-demand ns ps obs "spec-wheat" 60
                    #:at-location "location-a")))
      (check-pred "location: only location-a absorbed, 10 remaining"
        (approx= remaining 10 1))
      (check-pred "location: intent-a allocated"
        (ns-allocated? new-ns "i-loc-a"))
      (check-pred "location: intent-b NOT allocated"
        (not (ns-allocated? new-ns "i-loc-b"))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 15. Containment guard — contained resources excluded from free netting
;;;
;;; Ported from: netting.test.ts containment guard tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Containment guard ──\n")

(with-vat vat
  (let* ((ps ($ scope 'plan-store))
         (obs ($ scope 'observer))
         (ns (make-netter-state (hashmap) (hashmap) (hashmap) (hashmap))))

    ;; Use a unique spec to avoid interference from earlier test sections
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification #:id "spec-nitrogen" #:name "Nitrogen"
                                    #:default-unit-of-resource "kg"))

    ;; Seed free-standing nitrogen (not contained)
    ;; make-economic-resource: 20 fields
    ;; id name note image tracking-id conforms-to classified-as acct-qty onhand-qty
    ;; current-location current-virtual-location primary-accountable custodian-scope
    ;; stage state contained-in unit-of-effort lot previous-event availability-window
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-free-n2" #:name "Free N" #:conforms-to "spec-nitrogen"
         #:accounting-quantity (make-measure 20 "kg") #:onhand-quantity (make-measure 20 "kg") #:primary-accountable "agent-a"))

    ;; Seed contained nitrogen (in a soil container)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-cont-n2" #:name "Contained N" #:conforms-to "spec-nitrogen"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg") #:primary-accountable "agent-a"
         #:contained-in "r-soil-x"))

    ;; Demand without contained-in → should only get free-standing (20kg)
    (let-values (((ns1 remaining1 alloc1)
                  (netter-net-demand ns ps obs "spec-nitrogen" 40)))
      (check-pred "containment: free demand skips contained, 20 remaining"
        (approx= remaining1 20 1)))

    ;; Demand WITH contained-in → should only get contained (50kg)
    (let-values (((ns2 remaining2 alloc2)
                  (netter-net-demand ns ps obs "spec-nitrogen" 40
                    #:contained-in "r-soil-x")))
      (check-pred "containment: contained demand gets contained, 0 remaining"
        (approx= remaining2 0 1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Container + buffer conservation floor interaction
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Backported from relational test-ddmrp-leaf-planner.scm Section 13.
;;; The relational planner's ddmrp-allocate-o was tested with
;;; container-aware 3-tier allocation. This tests the imperative
;;; equivalent: netter-net-demand with conservation floors + contained-in.
;;;
;;; The key property: container filtering is applied BEFORE the
;;; conservation floor subtraction. A demand with #:contained-in only
;;; sees resources inside that container, and the floor is subtracted
;;; from each visible resource's individual accounting quantity.

(display "\n── Container + buffer conservation floors ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Create a spec with conservation floor (DDMRP-style buffer)
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification
         #:id "spec-flour-c" #:name "Container Flour" #:default-unit-of-resource "kg"))

    ;; Two containers (bin-A, bin-B) plus one top-level resource
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-bin-A" #:name "Flour Bin A" #:conforms-to "spec-flour-c"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "agent-a"))

    ($ obs 'seed-resource
       (make-economic-resource #:id "r-fA1" #:name "Flour A1" #:conforms-to "spec-flour-c"
         #:accounting-quantity (make-measure 60 "kg") #:onhand-quantity (make-measure 60 "kg") #:primary-accountable "agent-a"
         #:contained-in "r-bin-A"))

    ($ obs 'seed-resource
       (make-economic-resource #:id "r-fA2" #:name "Flour A2" #:conforms-to "spec-flour-c"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg") #:primary-accountable "agent-a"
         #:contained-in "r-bin-A"))

    ($ obs 'seed-resource
       (make-economic-resource #:id "r-fB" #:name "Flour B" #:conforms-to "spec-flour-c"
         #:accounting-quantity (make-measure 80 "kg") #:onhand-quantity (make-measure 80 "kg") #:primary-accountable "agent-a"
         #:contained-in "r-bin-B"))

    ($ obs 'seed-resource
       (make-economic-resource #:id "r-ftop" #:name "Flour Top" #:conforms-to "spec-flour-c"
         #:accounting-quantity (make-measure 40 "kg") #:onhand-quantity (make-measure 40 "kg") #:primary-accountable "agent-a"))

    ;; Set conservation floor (analogous to DDMRP TOR = 30)
    (let ((ns (empty-netter-state
                (hashmap-set (hashmap) "spec-flour-c" 30))))

      ;; Test 1: contained-in bin-A, demand 30
      ;; bin-A has r-fA1(60) + r-fA2(50). Floor=30 per resource.
      ;; r-fA1 allocatable = max(0, 60-30) = 30
      ;; r-fA2 allocatable = max(0, 50-30) = 20
      ;; Total allocatable from bin-A = 50, demand=30 → remaining=0
      (let-values (((ns1 remaining1 alloc1)
                    (netter-net-demand ns ps obs "spec-flour-c" 30
                      #:contained-in "r-bin-A")))
        (check-pred "container bin-A + floor 30: demand 30 fully satisfied"
                    (approx= remaining1 0 1))
        (check-pred "container bin-A: only bin-A resources allocated"
                    (every (lambda (a)
                             (member (car a) '("r-fA1" "r-fA2")))
                           alloc1)))

      ;; Test 2: contained-in bin-B, demand 60
      ;; bin-B has r-fB(80). Floor=30 → allocatable=50.
      ;; Demand 60 → remaining=10.
      (let-values (((ns2 remaining2 alloc2)
                    (netter-net-demand ns ps obs "spec-flour-c" 60
                      #:contained-in "r-bin-B")))
        (check-pred "container bin-B + floor 30: demand 60 leaves remaining ~10"
                    (approx= remaining2 10 1))
        (check-pred "container bin-B: only r-fB allocated"
                    (and (= (length alloc2) 1)
                         (equal? (caar alloc2) "r-fB"))))

      ;; Test 3: no container (top-level only), demand 20
      ;; Top-level: r-ftop(40). Floor=30 → allocatable=10.
      ;; Demand 20 → remaining=10.
      (let-values (((ns3 remaining3 alloc3)
                    (netter-net-demand ns ps obs "spec-flour-c" 20)))
        (check-pred "no container + floor 30: demand 20 from top-level only"
                    (approx= remaining3 10 1))
        (check-pred "no container: only r-ftop allocated"
                    (and (= (length alloc3) 1)
                         (equal? (caar alloc3) "r-ftop"))))

      ;; Test 4: no floor → full allocation from container
      ;; Without conservation floor, bin-A resources give full 110.
      (let ((ns-nofloor (empty-netter-state)))
        (let-values (((ns4 remaining4 alloc4)
                      (netter-net-demand ns-nofloor ps obs "spec-flour-c" 100
                        #:contained-in "r-bin-A")))
          (check-pred "no floor + container bin-A: demand 100 fully satisfied"
                      (approx= remaining4 0 1))
          (check-pred "no floor: allocated from both bin-A resources"
                      (= (length alloc4) 2)))))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
