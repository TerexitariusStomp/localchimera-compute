;;; test-vf-patterns.scm — Core ValueFlows patterns
;;;
;;; Ported from: old/planner/src/lib/tests/vf-examples.test.ts
;;;              old/planner/src/lib/tests/exchange.test.ts
;;;
;;; Intent: Verify core VF event patterns work correctly through the
;;; observer: transfer, move, manufacturing process, correction,
;;; exchange (two-legged), and resource lifecycle.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-vf-patterns.scm

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────

;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "VF Patterns Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-coin" #:name "FairCoin"
                                    #:default-unit-of-resource "coin"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-plywood" #:name "Plywood"
                                    #:default-unit-of-resource "sheet"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-desk" #:name "Desk" #:default-unit-of-resource "each"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bucket" #:name "Bucket"
                                    #:default-unit-of-resource "each"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-usd" #:name "USD" #:default-unit-of-resource "dollar"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-cnc" #:name "CNC Machine"
                                    #:default-unit-of-resource "each"))

    ($ as 'add-agent (make-agent #:id "alice" #:type 'person #:name "Alice"))
    ($ as 'add-agent (make-agent #:id "bob" #:type 'person #:name "Bob"))
    ($ as 'add-agent (make-agent #:id "carol" #:type 'person #:name "Carol"))
    ($ as 'add-agent (make-agent #:id "store-agent" #:type 'organization #:name "Store"))

    (check-pred "setup ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Transfer pattern (xfer-crypto)
;;;
;;; Ported from: vf-examples "xfer-crypto"
;;; Alice transfers 100 FairCoin to Bob
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Transfer pattern ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-alice-coin" #:name "Alice Coins" #:conforms-to "spec-coin"
         #:accounting-quantity (make-measure 500 "coin") #:onhand-quantity (make-measure 500 "coin") #:primary-accountable "alice"))

    ($ obs 'record-event
       (make-economic-event
         #:id "ev-xfer-coin" #:action 'transfer
         #:resource-inventoried-as "r-alice-coin" #:to-resource-inventoried-as "r-bob-coin" #:resource-conforms-to "spec-coin"
         #:provider "alice" #:receiver "bob"
         #:resource-quantity (make-measure 100 "coin") #:has-point-in-time "2026-03-01T10:00:00Z"))

    (let ((a ($ obs 'get-resource "r-alice-coin"))
          (b ($ obs 'get-resource "r-bob-coin")))
      (check "alice: 400 coin"
             (measure-has-numerical-value (economic-resource-accounting-quantity a)) 400)
      (check "bob: 100 coin"
             (measure-has-numerical-value (economic-resource-accounting-quantity b)) 100))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Manufacturing process (proc-mfg)
;;;
;;; Ported from: vf-examples "proc-mfg"
;;; Consume plywood + use CNC → produce desk
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Manufacturing process ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed plywood and CNC
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-plywood" #:name "Plywood" #:conforms-to "spec-plywood"
         #:accounting-quantity (make-measure 10 "sheet") #:onhand-quantity (make-measure 10 "sheet") #:primary-accountable "alice"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-cnc" #:name "CNC" #:conforms-to "spec-cnc"
         #:accounting-quantity (make-measure 1 "each") #:onhand-quantity (make-measure 1 "each") #:primary-accountable "alice"))

    ;; Use CNC (no quantity effect)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-use-cnc" #:action 'use #:input-of "proc-desk"
         #:resource-inventoried-as "r-cnc" #:resource-conforms-to "spec-cnc"
         #:provider "alice" #:receiver "alice"
         #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2026-03-02T08:00:00Z"))

    ;; Consume plywood
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-consume-plywood" #:action 'consume #:input-of "proc-desk"
         #:resource-inventoried-as "r-plywood" #:resource-conforms-to "spec-plywood"
         #:provider "alice" #:receiver "alice"
         #:resource-quantity (make-measure 4 "sheet") #:has-point-in-time "2026-03-02T09:00:00Z"))

    ;; Produce desk
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-produce-desk" #:action 'produce #:output-of "proc-desk"
         #:resource-inventoried-as "r-desk" #:resource-conforms-to "spec-desk"
         #:provider "alice" #:receiver "alice"
         #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2026-03-02T12:00:00Z"))

    ;; Verify effects
    (let ((cnc ($ obs 'get-resource "r-cnc"))
          (plywood ($ obs 'get-resource "r-plywood"))
          (desk ($ obs 'get-resource "r-desk")))
      (check "cnc: unchanged"
             (measure-has-numerical-value (economic-resource-accounting-quantity cnc)) 1)
      (check "plywood: 6 remaining"
             (measure-has-numerical-value (economic-resource-accounting-quantity plywood)) 6)
      (check "desk: 1 produced"
             (measure-has-numerical-value (economic-resource-accounting-quantity desk)) 1))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Exchange pattern (two-legged)
;;;
;;; Ported from: vf-examples "exch-pos" (point of sale)
;;; Carol pays $5, Store delivers 1 bucket
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Exchange pattern ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed Carol's dollars and Store's buckets
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-carol-usd" #:name "Carol USD" #:conforms-to "spec-usd"
         #:accounting-quantity (make-measure 100 "dollar") #:onhand-quantity (make-measure 100 "dollar") #:primary-accountable "carol"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-store-buckets" #:name "Buckets" #:conforms-to "spec-bucket"
         #:accounting-quantity (make-measure 20 "each") #:onhand-quantity (make-measure 20 "each") #:primary-accountable "store-agent"))

    ;; Leg 1: Carol transfers $5 to Store
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-pay" #:action 'transfer
         #:resource-inventoried-as "r-carol-usd" #:to-resource-inventoried-as "r-store-usd" #:resource-conforms-to "spec-usd"
         #:provider "carol" #:receiver "store-agent"
         #:resource-quantity (make-measure 5 "dollar") #:has-point-in-time "2026-03-03T10:00:00Z"))

    ;; Leg 2: Store delivers 1 bucket to Carol
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-deliver" #:action 'transfer
         #:resource-inventoried-as "r-store-buckets" #:to-resource-inventoried-as "r-carol-buckets" #:resource-conforms-to "spec-bucket"
         #:provider "store-agent" #:receiver "carol"
         #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2026-03-03T10:01:00Z"))

    ;; Verify
    (let ((carol-usd ($ obs 'get-resource "r-carol-usd"))
          (store-usd ($ obs 'get-resource "r-store-usd"))
          (store-bkt ($ obs 'get-resource "r-store-buckets"))
          (carol-bkt ($ obs 'get-resource "r-carol-buckets")))
      (check "carol USD: 95"
             (measure-has-numerical-value (economic-resource-accounting-quantity carol-usd)) 95)
      (check "store USD: 5"
             (measure-has-numerical-value (economic-resource-accounting-quantity store-usd)) 5)
      (check "store buckets: 19"
             (measure-has-numerical-value (economic-resource-accounting-quantity store-bkt)) 19)
      (check "carol buckets: 1"
             (measure-has-numerical-value (economic-resource-accounting-quantity carol-bkt)) 1))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Raise / Lower pattern
;;;
;;; Ported from: vf-examples adjustments
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Raise/Lower pattern ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Raise plywood by 2 (inventory correction)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-raise-ply" #:action 'raise
         #:resource-inventoried-as "r-plywood" #:resource-conforms-to "spec-plywood"
         #:provider "alice" #:receiver "alice"
         #:resource-quantity (make-measure 2 "sheet") #:has-point-in-time "2026-03-04T08:00:00Z"))

    (check "plywood after raise: 8"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity ($ obs 'get-resource "r-plywood")))
           8)

    ;; Lower plywood by 1 (spoilage)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-lower-ply" #:action 'lower
         #:resource-inventoried-as "r-plywood" #:resource-conforms-to "spec-plywood"
         #:provider "alice" #:receiver "alice"
         #:resource-quantity (make-measure 1 "sheet") #:has-point-in-time "2026-03-04T09:00:00Z"))

    (check "plywood after lower: 7"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity ($ obs 'get-resource "r-plywood")))
           7)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Event chain integrity
;;;
;;; Ported from: vf-examples "previousEvent breadcrumbs"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Event chain ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; All events recorded should be retrievable
    (let ((events ($ obs 'all-events)))
      (check-pred "all events tracked" (>= (length events) 8))

      ;; Event for each action type we used
      (let ((actions (map economic-event-action events)))
        (check-pred "has transfer" (memq 'transfer actions))
        (check-pred "has use" (memq 'use actions))
        (check-pred "has consume" (memq 'consume actions))
        (check-pred "has produce" (memq 'produce actions))
        (check-pred "has raise" (memq 'raise actions))
        (check-pred "has lower" (memq 'lower actions))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Bilateral exchange with agreement
;;;
;;; Ported from: old/planner/src/lib/tests/exchange.test.ts
;;; Intent: Verify bilateral exchange events carry realizationOf (agreement),
;;; and multilateral exchanges (3+ events) all get the agreement ID.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Exchange with agreement ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Bilateral exchange: Alice pays 100 USD, Bob delivers 1 widget
    ;; Both events reference the same agreement via realization-of

    ;; Seed resources for exchange
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-usd-alice" #:name "Alice USD" #:conforms-to "spec-gold"
         #:accounting-quantity (make-measure 1000 "USD") #:onhand-quantity (make-measure 1000 "USD") #:primary-accountable "agent-alice"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-widget-bob" #:name "Bob Widgets" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 10 "each") #:onhand-quantity (make-measure 10 "each") #:primary-accountable "agent-bob"))

    ;; Payment leg: transfer 100 USD from Alice to Bob
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-agr-pay" #:action 'transfer
         #:resource-inventoried-as "r-usd-alice" #:resource-conforms-to "spec-gold"
         #:provider "agent-alice" #:receiver "agent-bob"
         #:resource-quantity (make-measure 100 "USD") #:has-point-in-time "2026-03-15T10:00:00Z" #:realization-of "agreement-1"))

    ;; Delivery leg: transfer 1 widget from Bob to Alice
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-agr-deliver" #:action 'transfer
         #:resource-inventoried-as "r-widget-bob" #:resource-conforms-to "spec-wheat"
         #:provider "agent-bob" #:receiver "agent-alice"
         #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2026-03-15T10:05:00Z" #:realization-of "agreement-1"))

    ;; Verify both events have realizationOf = agreement-1
    (let ((pay ($ obs 'get-event "ev-agr-pay"))
          (deliver ($ obs 'get-event "ev-agr-deliver")))
      (check "bilateral: pay has agreement"
             (economic-event-realization-of pay) "agreement-1")
      (check "bilateral: deliver has agreement"
             (economic-event-realization-of deliver) "agreement-1"))

    ;; Verify resource effects
    (let ((alice-usd ($ obs 'get-resource "r-usd-alice"))
          (bob-widgets ($ obs 'get-resource "r-widget-bob")))
      (check "bilateral: alice usd = 900"
             (measure-has-numerical-value
               (economic-resource-accounting-quantity alice-usd)) 900)
      (check "bilateral: bob widgets = 9"
             (measure-has-numerical-value
               (economic-resource-accounting-quantity bob-widgets)) 9))

    ;; Multilateral: 3-event exchange all share same agreement
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-multi-1" #:action 'transfer
         #:resource-inventoried-as "r-usd-alice" #:resource-conforms-to "spec-gold"
         #:provider "agent-alice" #:receiver "agent-bob"
         #:resource-quantity (make-measure 50 "USD") #:has-point-in-time "2026-03-16T10:00:00Z" #:realization-of "agreement-2"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-multi-2" #:action 'transfer
         #:resource-inventoried-as "r-widget-bob" #:resource-conforms-to "spec-wheat"
         #:provider "agent-bob" #:receiver "agent-alice"
         #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2026-03-16T10:05:00Z" #:realization-of "agreement-2"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-multi-3" #:action 'transfer
         #:resource-inventoried-as "r-usd-alice" #:resource-conforms-to "spec-gold"
         #:provider "agent-alice" #:receiver "agent-bob"
         #:resource-quantity (make-measure 25 "USD") #:has-point-in-time "2026-03-16T10:10:00Z" #:realization-of "agreement-2"))

    (let ((e1 ($ obs 'get-event "ev-multi-1"))
          (e2 ($ obs 'get-event "ev-multi-2"))
          (e3 ($ obs 'get-event "ev-multi-3")))
      (check "multi: e1 agreement" (economic-event-realization-of e1) "agreement-2")
      (check "multi: e2 agreement" (economic-event-realization-of e2) "agreement-2")
      (check "multi: e3 agreement" (economic-event-realization-of e3) "agreement-2"))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
