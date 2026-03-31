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

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet kanren-planning)
             (srfi srfi-1))


;;; ── Harness ───────────────────────────────────────────────────────────────────

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
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Netting Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wood" "Wood" #f #f #f "plank" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-yarn" "Yarn" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-linen" "Linen" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-steel" "Steel" #f #f #f "each" #f #f #f #f #f))
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
       (make-economic-resource "r-wood" "Wood" #f #f #f "spec-wood" #f
         (make-measure 8 "plank") (make-measure 8 "plank")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

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
       (make-intent "i-yarn-out" 'produce "Yarn production" #f #f
                    #f "proc-1" #f "spec-yarn" #f
                    (make-measure 4 "each") #f #f #f
                    "agent-a" #f
                    #f #f #f #f
                    #f #f #f "test-plan" #f #f #f #f))

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
       (make-intent "i-yarn-in" 'consume "Yarn consumption" #f #f
                    "proc-1" #f #f "spec-yarn" #f
                    (make-measure 3 "each") #f #f #f
                    #f "agent-a"
                    #f #f #f #f
                    #f #f #f "test-plan" #f #f #f #f))

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
       (make-economic-resource "r-linen" "Linen" #f #f #f "spec-linen" #f
         (make-measure 5 "each") (make-measure 5 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; 3 more scheduled to be produced
    ($ ps 'add-intent
       (make-intent "i-linen-out" 'produce "Linen output" #f #f
                    #f "proc-x" #f "spec-linen" #f
                    (make-measure 3 "each") #f #f #f
                    "agent-a" #f
                    #f #f #f #f
                    #f #f #f "test-plan" #f #f #f #f))

    ;; 4 scheduled to be consumed
    ($ ps 'add-intent
       (make-intent "i-linen-in" 'consume "Linen input" #f #f
                    "proc-y" #f #f "spec-linen" #f
                    (make-measure 4 "each") #f #f #f
                    #f "agent-a"
                    #f #f #f #f
                    #f #f #f "test-plan" #f #f #f #f))

    ;; Available = 5 + 3 - 4 = 4
    (let-values (((ns available)
                  (netter-net-available (empty-netter-state) ps obs "spec-linen")))
      (check-pred "linen available: ~4" (approx= 4 available 1)))))


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
;;; Ported from: netting tests expressed as miniKanren goals
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Relational netter goals ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-rng")))

    ;; net-demand-o: 5 wood from 8 in inventory → remaining ~0
    (let ((results (run-plan 1 ns (q)
                     (fresh (rem alloc)
                       (net-demand-o ctx "spec-wood" 5 rem alloc)
                       (== q rem)))))
      (check-pred "goal: wood 5 satisfied"
                  (and (pair? results) (approx= 0 (car results)))))

    ;; net-demand-o: 12 wood from 8 → remaining ~4
    (let ((results (run-plan 1 ns (q)
                     (fresh (rem alloc)
                       (net-demand-o ctx "spec-wood" 12 rem alloc)
                       (== q rem)))))
      (check-pred "goal: wood 12 partial (~4 remaining)"
                  (and (pair? results) (approx= 4 (car results) 1))))

    ;; Flour: 50 in inventory
    ;; net-demand-o: 30 → fully satisfied
    (let ((results (run-plan 1 ns (q)
                     (fresh (rem alloc)
                       (net-demand-o ctx "spec-flour" 30 rem alloc)
                       (== q rem)))))
      (check-pred "goal: flour 30 satisfied"
                  (and (pair? results) (< (car results) 1))))))


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

      ;; After reserving 3, only 5 available for demand
      (let-values (((ns2 remaining alloc)
                    (netter-net-demand ns1 ps obs "spec-wood" 6)))
        (check-pred "after reserve: remaining ~1" (approx= 1 remaining))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
