;;; test-architectural-elegance.scm — Conservation floors, soft allocation signals,
;;; and planning process metadata
;;;
;;; Tests the three architectural layers that give the planner its elegance:
;;;   1. Conservation floors in the netter prevent inventory depletion below
;;;      ecological/safety minimums.
;;;   2. Soft allocation via emit-signal stores typed signals as tagged intents
;;;      with metadata, queryable by kind.
;;;   3. Planning process metadata round-trips through set-meta/get-meta and
;;;      signal-outputs-of-process queries.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-architectural-elegance.scm

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n== Architectural Elegance ==\n")
(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Elegance Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (ps ($ scope 'plan-store)))

    ;; Resource specs
    ($ rs 'add-resource-spec
       (make-resource-specification
         #:id "spec-grain" #:name "Grain" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification
         #:id "spec-water" #:name "Water" #:default-unit-of-resource "litre"))

    ;; Inventory: 10 kg grain
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-grain" #:name "Grain Stock" #:conforms-to "spec-grain"
         #:accounting-quantity (make-measure 10 "kg") #:onhand-quantity (make-measure 10 "kg") #:primary-accountable "agent-commune"))

    ;; Inventory: 2 kg water (scarce)
    ($ obs 'seed-resource
       (make-economic-resource
         #:id "r-water" #:name "Water Reserve" #:conforms-to "spec-water"
         #:accounting-quantity (make-measure 2 "litre") #:onhand-quantity (make-measure 2 "litre") #:primary-accountable "agent-commune"))

    ;; Plan for signal tests
    ($ ps 'add-plan
       (make-plan #:id "plan-elegance" #:name "Elegance Plan"
                  #:due "2026-05-01T00:00:00Z" #:created "2026-04-01T00:00:00Z"))

    (check-pred "setup: specs, inventory, and plan seeded" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 1: Conservation floor limits allocation
;;;
;;; Inventory 10 kg grain, floor 3 kg, demand 10.
;;; Allocatable from inventory = 10 - 3 = 7.
;;; Remaining = 10 - 7 = 3.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Floor limits allocation ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    (let ((ns-floor (empty-netter-state
                      (hashmap-set (hashmap) "spec-grain" 3))))
      (let-values (((ns1 remaining allocated)
                    (netter-net-demand ns-floor ps obs "spec-grain" 10)))
        (check-pred "floor 3: demand 10, remaining ~ 3"
                    (approx= 3 remaining 0.1))
        (check-pred "floor 3: allocated pairs present"
                    (pair? allocated))
        ;; The allocated quantity should be 7 (10 inventory - 3 floor)
        (let ((alloc-qty (caddr (car allocated))))
          (check-pred "floor 3: allocated qty ~ 7"
                      (approx= 7 alloc-qty 0.1)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 2: Inventory below floor yields nothing allocatable
;;;
;;; Inventory 2 litre water, floor 3.
;;; Allocatable = max(0, 2 - 3) = 0.
;;; Demand of 5 → remaining = 5 (nothing netted).
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Below floor: nothing allocatable ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    (let ((ns-floor (empty-netter-state
                      (hashmap-set (hashmap) "spec-water" 3))))
      (let-values (((ns1 remaining allocated)
                    (netter-net-demand ns-floor ps obs "spec-water" 5)))
        (check-pred "below floor: demand 5, remaining ~ 5 (nothing available)"
                    (approx= 5 remaining 0.1))
        (check "below floor: no allocated pairs" allocated '())))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 3: net-available respects floor
;;;
;;; With floor 3 on grain (inventory 10), net-available should report 7.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. net-available respects floor ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Without floor
    (let ((avail-no-floor (netter-net-available (empty-netter-state) ps obs "spec-grain")))
      (check-pred "no floor: grain available ~ 10"
                  (approx= 10 avail-no-floor 0.1)))

    ;; With floor = 3
    (let* ((ns-floor (empty-netter-state
                       (hashmap-set (hashmap) "spec-grain" 3)))
           (avail-with-floor (netter-net-available ns-floor ps obs "spec-grain")))
      (check-pred "floor 3: grain available ~ 7"
                  (approx= 7 avail-with-floor 0.1)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 4: Fork propagates floor
;;;
;;; A forked netter state must carry the conservation floors forward.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Fork propagates floor ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    (let* ((ns-floor (empty-netter-state
                       (hashmap-set (hashmap) "spec-grain" 3)))
           (ns-forked (netter-fork ns-floor)))

      ;; The forked state should be a valid netter-state
      (check-pred "fork: returns netter-state" (netter-state? ns-forked))

      ;; The forked state should still respect the floor
      (let-values (((ns1 remaining allocated)
                    (netter-net-demand ns-forked ps obs "spec-grain" 10)))
        (check-pred "fork: floor carried — remaining ~ 3"
                    (approx= 3 remaining 0.1))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 5: Soft allocation via emit-signal
;;;
;;; emit-signal stores a deficit as a tagged intent with metadata.
;;; signals-of-kind reconstructs the signal. get-meta returns plan info.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. emit-signal + signals-of-kind ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; Emit a deficit signal
    (let* ((deficit-signal `((kind . deficit) (spec-id . "spec-grain")
                             (qty . 10) (unit . "kg") (scope . "commune-1")
                             (due . "2026-04-15T00:00:00Z")
                             (original-shortfall . 10) (resolved-at . ())))
           (iid ($ ps 'emit-signal deficit-signal "plan-elegance")))

      (check-pred "emit-signal: returns intent id" (string? iid))

      ;; signals-of-kind should return the deficit
      (let ((deficits ($ ps 'signals-of-kind 'deficit)))
        (check-pred "signals-of-kind: at least one deficit"
                    (pair? deficits))
        (let ((found (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-grain"))
                           deficits)))
          (check-pred "signals-of-kind: found grain deficit" (pair? found))
          (check "deficit signal: qty" (assq-ref found 'qty) 10)
          (check "deficit signal: kind" (assq-ref found 'kind) 'deficit)))

      ;; get-meta should have the metadata
      (let ((meta ($ ps 'get-meta iid)))
        (check-pred "get-meta: returns alist" (pair? meta))
        (check "get-meta: kind" (assq-ref meta 'kind) 'deficit)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 6: Multiple signal kinds — filtering
;;;
;;; Emit both deficit and surplus. signals-of-kind returns only the
;;; requested kind.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Signal kind filtering ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; Emit a surplus signal
    (let* ((surplus-signal `((kind . surplus) (spec-id . "spec-water")
                             (qty . 5) (unit . "litre") (scope . "commune-1")
                             (available-from . "2026-04-10T00:00:00Z")))
           (sid ($ ps 'emit-signal surplus-signal "plan-elegance")))

      ;; Query deficits — should NOT contain the surplus
      (let ((deficits ($ ps 'signals-of-kind 'deficit)))
        (check-pred "deficit query: no surplus signals"
                    (not (any (lambda (s) (eq? (assq-ref s 'kind) 'surplus))
                              deficits))))

      ;; Query surpluses — should contain the water surplus
      (let ((surpluses ($ ps 'signals-of-kind 'surplus)))
        (check-pred "surplus query: at least one surplus"
                    (pair? surpluses))
        (let ((found (find (lambda (s) (equal? (assq-ref s 'spec-id) "spec-water"))
                           surpluses)))
          (check-pred "surplus query: found water surplus" (pair? found))
          (check "surplus signal: qty" (assq-ref found 'qty) 5)
          (check "surplus signal: kind" (assq-ref found 'kind) 'surplus))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 7: Planning process meta round-trip
;;;
;;; set-meta on an intent, get-meta returns the same alist.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Meta round-trip ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; Add a plain intent to attach meta to
    ($ ps 'add-intent
       (make-intent #:id "i-meta-test" #:action 'produce #:name "Meta test intent" #:output-of "proc-meta" #:resource-conforms-to "spec-grain"
                    #:resource-quantity (make-measure 5 "kg")
                    #:provider "agent-commune" #:planned-within "plan-elegance"))

    ;; Set metadata
    (let ((meta-alist `((kind . "planning") (process-id . "proc-1"))))
      ($ ps 'set-meta "i-meta-test" meta-alist)

      ;; Get it back
      (let ((result ($ ps 'get-meta "i-meta-test")))
        (check-pred "get-meta: returns alist" (pair? result))
        (check "meta round-trip: kind" (assq-ref result 'kind) "planning")
        (check "meta round-trip: process-id" (assq-ref result 'process-id) "proc-1")))

    ;; Nonexistent intent returns #f
    (check "get-meta: nonexistent returns #f"
           ($ ps 'get-meta "i-does-not-exist") #f)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 8: Signal outputs of process
;;;
;;; Add intents with output-of = "proc-plan" and plan tags.
;;; signal-outputs-of-process returns them.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. signal-outputs-of-process ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))

    ;; Add two intents that are outputs of "proc-plan" with plan tags
    ($ ps 'add-intent
       (make-intent #:id "i-proc-out-1" #:action 'produce #:name "Planned deficit output" #:output-of "proc-plan" #:resource-conforms-to "spec-grain"
                    #:resource-classified-as (list "tag:plan:deficit")
                    #:resource-quantity (make-measure 8 "kg") #:receiver "agent-commune" #:planned-within "plan-elegance"))

    ($ ps 'add-intent
       (make-intent #:id "i-proc-out-2" #:action 'produce #:name "Planned surplus output" #:output-of "proc-plan" #:resource-conforms-to "spec-water"
                    #:resource-classified-as (list "tag:plan:surplus")
                    #:resource-quantity (make-measure 3 "litre") #:receiver "agent-commune" #:planned-within "plan-elegance"))

    ;; Add an intent that is NOT an output of proc-plan (different process)
    ($ ps 'add-intent
       (make-intent #:id "i-proc-other" #:action 'produce #:name "Other process" #:output-of "proc-other" #:resource-conforms-to "spec-grain"
                    #:resource-classified-as (list "tag:plan:deficit")
                    #:resource-quantity (make-measure 2 "kg") #:receiver "agent-commune" #:planned-within "plan-elegance"))

    ;; Query outputs of proc-plan
    (let ((outputs ($ ps 'signal-outputs-of-process "proc-plan")))
      ;; hashmap-filter returns a list of intents
      (check "signal-outputs: count" (length outputs) 2)
      (check-pred "signal-outputs: contains i-proc-out-1"
                  (any (lambda (i) (equal? (intent-id i) "i-proc-out-1"))
                       outputs))
      (check-pred "signal-outputs: contains i-proc-out-2"
                  (any (lambda (i) (equal? (intent-id i) "i-proc-out-2"))
                       outputs))
      (check-pred "signal-outputs: does NOT contain i-proc-other"
                  (not (any (lambda (i) (equal? (intent-id i) "i-proc-other"))
                            outputs))))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
