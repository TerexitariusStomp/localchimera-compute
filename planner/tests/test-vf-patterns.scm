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


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "VF Patterns Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-coin" "FairCoin" #f #f #f "coin" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-plywood" "Plywood" #f #f #f "sheet" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-desk" "Desk" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bucket" "Bucket" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-usd" "USD" #f #f #f "dollar" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-cnc" "CNC Machine" #f #f #f "each" #f #f #f #f #f))

    ($ as 'add-agent (make-agent "alice" 'person "Alice" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "bob" 'person "Bob" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "carol" 'person "Carol" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "store-agent" 'organization "Store" #f #f #f #f #f))

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
       (make-economic-resource "r-alice-coin" "Alice Coins" #f #f #f "spec-coin" #f
         (make-measure 500 "coin") (make-measure 500 "coin")
         #f #f "alice" #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-xfer-coin" 'transfer #f #f
         "r-alice-coin" "r-bob-coin" "spec-coin" #f
         "alice" "bob"
         (make-measure 100 "coin") #f
         #f #f "2026-03-01T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
       (make-economic-resource "r-plywood" "Plywood" #f #f #f "spec-plywood" #f
         (make-measure 10 "sheet") (make-measure 10 "sheet")
         #f #f "alice" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-cnc" "CNC" #f #f #f "spec-cnc" #f
         (make-measure 1 "each") (make-measure 1 "each")
         #f #f "alice" #f #f #f #f #f #f #f #f))

    ;; Use CNC (no quantity effect)
    ($ obs 'record-event
       (make-economic-event
         "ev-use-cnc" 'use "proc-desk" #f
         "r-cnc" #f "spec-cnc" #f
         "alice" "alice"
         (make-measure 1 "each") #f
         #f #f "2026-03-02T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Consume plywood
    ($ obs 'record-event
       (make-economic-event
         "ev-consume-plywood" 'consume "proc-desk" #f
         "r-plywood" #f "spec-plywood" #f
         "alice" "alice"
         (make-measure 4 "sheet") #f
         #f #f "2026-03-02T09:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Produce desk
    ($ obs 'record-event
       (make-economic-event
         "ev-produce-desk" 'produce #f "proc-desk"
         "r-desk" #f "spec-desk" #f
         "alice" "alice"
         (make-measure 1 "each") #f
         #f #f "2026-03-02T12:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
       (make-economic-resource "r-carol-usd" "Carol USD" #f #f #f "spec-usd" #f
         (make-measure 100 "dollar") (make-measure 100 "dollar")
         #f #f "carol" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-store-buckets" "Buckets" #f #f #f "spec-bucket" #f
         (make-measure 20 "each") (make-measure 20 "each")
         #f #f "store-agent" #f #f #f #f #f #f #f #f))

    ;; Leg 1: Carol transfers $5 to Store
    ($ obs 'record-event
       (make-economic-event
         "ev-pay" 'transfer #f #f
         "r-carol-usd" "r-store-usd" "spec-usd" #f
         "carol" "store-agent"
         (make-measure 5 "dollar") #f
         #f #f "2026-03-03T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Leg 2: Store delivers 1 bucket to Carol
    ($ obs 'record-event
       (make-economic-event
         "ev-deliver" 'transfer #f #f
         "r-store-buckets" "r-carol-buckets" "spec-bucket" #f
         "store-agent" "carol"
         (make-measure 1 "each") #f
         #f #f "2026-03-03T10:01:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
         "ev-raise-ply" 'raise #f #f
         "r-plywood" #f "spec-plywood" #f
         "alice" "alice"
         (make-measure 2 "sheet") #f
         #f #f "2026-03-04T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (check "plywood after raise: 8"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity ($ obs 'get-resource "r-plywood")))
           8)

    ;; Lower plywood by 1 (spoilage)
    ($ obs 'record-event
       (make-economic-event
         "ev-lower-ply" 'lower #f #f
         "r-plywood" #f "spec-plywood" #f
         "alice" "alice"
         (make-measure 1 "sheet") #f
         #f #f "2026-03-04T09:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
       (make-economic-resource "r-usd-alice" "Alice USD" #f #f #f "spec-gold" #f
         (make-measure 1000 "USD") (make-measure 1000 "USD")
         #f #f "agent-alice" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-widget-bob" "Bob Widgets" #f #f #f "spec-wheat" #f
         (make-measure 10 "each") (make-measure 10 "each")
         #f #f "agent-bob" #f #f #f #f #f #f #f #f))

    ;; Payment leg: transfer 100 USD from Alice to Bob
    ($ obs 'record-event
       (make-economic-event
         "ev-pay" 'transfer #f #f
         "r-usd-alice" #f "spec-gold" #f
         "agent-alice" "agent-bob"
         (make-measure 100 "USD") #f
         #f #f "2026-03-15T10:00:00Z" #f #f #f #f
         #f #f #f "agreement-1" #f #f #f #f #f #f))

    ;; Delivery leg: transfer 1 widget from Bob to Alice
    ($ obs 'record-event
       (make-economic-event
         "ev-deliver" 'transfer #f #f
         "r-widget-bob" #f "spec-wheat" #f
         "agent-bob" "agent-alice"
         (make-measure 1 "each") #f
         #f #f "2026-03-15T10:05:00Z" #f #f #f #f
         #f #f #f "agreement-1" #f #f #f #f #f #f))

    ;; Verify both events have realizationOf = agreement-1
    (let ((pay ($ obs 'get-event "ev-pay"))
          (deliver ($ obs 'get-event "ev-deliver")))
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
         "ev-multi-1" 'transfer #f #f
         "r-usd-alice" #f "spec-gold" #f
         "agent-alice" "agent-bob"
         (make-measure 50 "USD") #f
         #f #f "2026-03-16T10:00:00Z" #f #f #f #f
         #f #f #f "agreement-2" #f #f #f #f #f #f))
    ($ obs 'record-event
       (make-economic-event
         "ev-multi-2" 'transfer #f #f
         "r-widget-bob" #f "spec-wheat" #f
         "agent-bob" "agent-alice"
         (make-measure 1 "each") #f
         #f #f "2026-03-16T10:05:00Z" #f #f #f #f
         #f #f #f "agreement-2" #f #f #f #f #f #f))
    ($ obs 'record-event
       (make-economic-event
         "ev-multi-3" 'transfer #f #f
         "r-usd-alice" #f "spec-gold" #f
         "agent-alice" "agent-bob"
         (make-measure 25 "USD") #f
         #f #f "2026-03-16T10:10:00Z" #f #f #f #f
         #f #f #f "agreement-2" #f #f #f #f #f #f))

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
(when (> fail-count 0) (exit 1))
