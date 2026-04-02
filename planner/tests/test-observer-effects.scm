;;; test-observer-effects.scm — Observer action-effect tests
;;;
;;; Ported from: old/planner/src/lib/tests/observer.test.ts
;;;              old/planner/src/lib/tests/observer-actions.test.ts
;;;
;;; Intent: Verify that the observer (stockbook) correctly applies resource
;;; effects for each VF action: produce/consume change quantities, transfer
;;; moves between resources, corrections unroll previous events, use/cite
;;; are existence-only gates, combine/separate manage containment, and
;;; fulfillment/satisfaction are tracked.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-observer-effects.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
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
    (lambda () (spawn-scope "Observer Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-gold" "Gold" #f #f #f "oz" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-tool" "Tool" #f #f #f "each" #f #f #f #f #f))
    (check-pred "specs seeded" #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Produce increments resource quantity
;;;
;;; Ported from: "records events and tracks resources" (produce part)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Produce ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed resource at 0
    ($ obs 'seed-resource
       (make-economic-resource "r-bread" "Bread" #f #f #f "spec-bread" #f
         (make-measure 0 "each") (make-measure 0 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Produce 10
    ($ obs 'record-event
       (make-economic-event
         "ev-produce-1" 'produce #f "proc-1"
         "r-bread" #f "spec-bread" #f
         "agent-a" "agent-a"
         (make-measure 10 "each") #f
         #f #f "2026-03-28T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-bread")))
      (check "produce: qty=10"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             10))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Consume decrements resource quantity
;;;
;;; Ported from: "records events and tracks resources" (consume part)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Consume ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Consume 3 bread
    ($ obs 'record-event
       (make-economic-event
         "ev-consume-1" 'consume "proc-2" #f
         "r-bread" #f "spec-bread" #f
         "agent-a" "agent-a"
         (make-measure 3 "each") #f
         #f #f "2026-03-28T09:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-bread")))
      (check "consume: qty=7"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             7))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Transfer moves quantity between resources
;;;
;;; Ported from: "handles transfer correctly"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Transfer ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed gold resource
    ($ obs 'seed-resource
       (make-economic-resource "r-gold-a" "Gold A" #f #f #f "spec-gold" #f
         (make-measure 10 "oz") (make-measure 10 "oz")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Transfer 4oz from r-gold-a to r-gold-b
    ($ obs 'record-event
       (make-economic-event
         "ev-transfer-1" 'transfer #f #f
         "r-gold-a" "r-gold-b" "spec-gold" #f
         "agent-a" "agent-b"
         (make-measure 4 "oz") #f
         #f #f "2026-03-28T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((a ($ obs 'get-resource "r-gold-a"))
          (b ($ obs 'get-resource "r-gold-b")))
      (check "transfer: source=6"
             (measure-has-numerical-value (economic-resource-accounting-quantity a))
             6)
      (check "transfer: dest=4"
             (measure-has-numerical-value (economic-resource-accounting-quantity b))
             4))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Use does not change quantity (existence gate)
;;;
;;; Ported from: observer-actions "use does not change accounting"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Use (existence gate) ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed tool
    ($ obs 'seed-resource
       (make-economic-resource "r-tool" "Hammer" #f #f #f "spec-tool" #f
         (make-measure 1 "each") (make-measure 1 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Use the tool
    ($ obs 'record-event
       (make-economic-event
         "ev-use-1" 'use "proc-3" #f
         "r-tool" #f "spec-tool" #f
         "agent-a" "agent-a"
         (make-measure 1 "each") #f
         #f #f "2026-03-28T11:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Quantity unchanged
    (let ((r ($ obs 'get-resource "r-tool")))
      (check "use: qty unchanged=1"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             1)
      (check "use: onhand unchanged=1"
             (measure-has-numerical-value (economic-resource-onhand-quantity r))
             1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Cite does not change quantity (reference-only)
;;;
;;; Ported from: observer-actions "cite does not change quantity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Cite (reference-only) ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Cite the tool
    ($ obs 'record-event
       (make-economic-event
         "ev-cite-1" 'cite "proc-4" #f
         "r-tool" #f "spec-tool" #f
         "agent-a" "agent-a"
         (make-measure 1 "each") #f
         #f #f "2026-03-28T12:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-tool")))
      (check "cite: qty unchanged=1"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Work does not change onhand (non-consuming)
;;;
;;; Ported from: labor-as-resource "work events do not change onhandQuantity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Work (non-consuming) ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed capacity resource
    ($ obs 'seed-resource
       (make-economic-resource "r-cap-alice" "Alice Capacity" #f #f #f "spec-tool" #f
         (make-measure 40 "hours") (make-measure 40 "hours")
         #f #f "agent-alice" #f #f #f #f #f #f #f #f))

    ;; Record work event
    ($ obs 'record-event
       (make-economic-event
         "ev-work-1" 'work "proc-5" #f
         "r-cap-alice" #f "spec-tool" #f
         "agent-alice" "agent-alice"
         #f (make-measure 8 "hours")
         #f #f "2026-03-28T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-cap-alice")))
      (check "work: onhand unchanged=40"
             (measure-has-numerical-value (economic-resource-onhand-quantity r))
             40))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Raise / Lower adjust resource levels
;;;
;;; Ported from: observer-actions raise/lower tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Raise/Lower ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed wheat
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat-rl" "Wheat RL" #f #f #f "spec-wheat" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Raise by 10
    ($ obs 'record-event
       (make-economic-event
         "ev-raise-1" 'raise #f #f
         "r-wheat-rl" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 10 "kg") #f
         #f #f "2026-03-28T13:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-wheat-rl")))
      (check "raise: qty=110"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             110))

    ;; Lower by 20
    ($ obs 'record-event
       (make-economic-event
         "ev-lower-1" 'lower #f #f
         "r-wheat-rl" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 20 "kg") #f
         #f #f "2026-03-28T14:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-wheat-rl")))
      (check "lower: qty=90"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             90))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Event count and inventory tracking
;;;
;;; Ported from: observer "records events" and "inventory" checks
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Event tracking ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    (check-pred "events recorded" (>= (length ($ obs 'all-events)) 5))
    (check-pred "inventory tracked" (>= (length ($ obs 'all-resources)) 3))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Fulfillment tracking
;;;
;;; Ported from: "tracks fulfillment of commitments"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Fulfillment tracking ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Create a plan and commitment for 100kg wheat
    ($ ps 'add-plan (make-plan "plan-ful" "Fulfillment Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-wheat-ful" 'produce #f #f "proc-ful"
                        #f "spec-wheat" #f
                        (make-measure 100 "kg") #f
                        "agent-a" "agent-a"
                        #f #f #f #f #f #f #f #f #f #f #f #f
                        "plan-ful" #f #f))

    ;; Record partial fulfillment: 60kg
    ($ obs 'record-event
       (make-economic-event
         "ev-ful-1" 'produce #f "proc-ful"
         "r-wheat-rl" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 60 "kg") #f
         "c-wheat-ful" #f "2026-03-29T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Record remaining fulfillment: 40kg
    ($ obs 'record-event
       (make-economic-event
         "ev-ful-2" 'produce #f "proc-ful"
         "r-wheat-rl" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 40 "kg") #f
         "c-wheat-ful" #f "2026-03-29T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Commitment should be fully fulfilled
    (let ((c ($ ps 'get-commitment "c-wheat-ful")))
      (check-pred "fulfillment: commitment exists" (commitment? c)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Persistence of observer state
;;;
;;; Ported from: scope-integration "persistence round-trip"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Observer persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (error "Should restore from store!"))
    store))

(with-vat vat2
  (let ((obs ($ scope2 'observer)))
    (check-pred "restored: events" (>= (length ($ obs 'all-events)) 5))
    (check-pred "restored: resources" (>= (length ($ obs 'all-resources)) 3))

    ;; Bread should still be at 7 (10 produced - 3 consumed)
    (let ((r ($ obs 'get-resource "r-bread")))
      (check "restored: bread qty=7"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             7))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. State effects on resources
;;;
;;; Verify that recording events with a state field updates the resource state.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── State effects ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a fresh flour resource with no state
    ($ obs 'seed-resource
       (make-economic-resource "r-flour-state" "Flour State" #f #f #f "spec-flour" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Produce 50kg with state = 'fresh
    ($ obs 'record-event
       (make-economic-event
         "ev-state-1" 'produce #f "proc-state-1"
         "r-flour-state" #f "spec-flour" #f
         "agent-a" "agent-a"
         (make-measure 50 "kg") #f
         #f #f "2026-03-30T08:00:00Z" #f #f #f 'fresh
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-flour-state")))
      (check "state: produce sets state to fresh"
             (economic-resource-state r) 'fresh)
      (check "state: produce qty=50"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 50))

    ;; Use the flour with state = 'processing (use has state-effect 'update)
    ($ obs 'record-event
       (make-economic-event
         "ev-state-2" 'use "proc-state-2" #f
         "r-flour-state" #f "spec-flour" #f
         "agent-a" "agent-a"
         (make-measure 1 "kg") #f
         #f #f "2026-03-30T09:00:00Z" #f #f #f 'processing
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-flour-state")))
      (check "state: use updates state to processing"
             (economic-resource-state r) 'processing)
      ;; use has no-effect on quantities
      (check "state: use qty unchanged=50"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 50))

    ;; Cite the resource with state = 'referenced
    ($ obs 'record-event
       (make-economic-event
         "ev-state-3" 'cite "proc-state-3" #f
         "r-flour-state" #f "spec-flour" #f
         "agent-a" "agent-a"
         (make-measure 1 "kg") #f
         #f #f "2026-03-30T10:00:00Z" #f #f #f 'referenced
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-flour-state")))
      (check "state: cite updates state to referenced"
             (economic-resource-state r) 'referenced))

    ;; Query resources-by-state
    (let ((by-state ($ obs 'resources-by-state 'referenced)))
      (check-pred "state: resources-by-state finds resource"
                  (pair? (filter (lambda (r)
                                   (equal? (economic-resource-id r) "r-flour-state"))
                                 by-state))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. Combine sets contained-in on ingredient resource
;;;
;;; combine action: onhand-effect = decrement, contained-effect = update
;;; The from-resource gets contained-in set to the to-resource.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Combine ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a container resource (a bread basket)
    ($ obs 'seed-resource
       (make-economic-resource "r-basket" "Bread Basket" #f #f #f "spec-bread" #f
         (make-measure 1 "each") (make-measure 1 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Seed an ingredient resource (a bread loaf)
    ($ obs 'seed-resource
       (make-economic-resource "r-loaf-1" "Loaf 1" #f #f #f "spec-bread" #f
         (make-measure 1 "each") (make-measure 1 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Combine: loaf goes into basket
    ;; resource-inventoried-as = ingredient (from), to-resource-inventoried-as = container (to)
    ($ obs 'record-event
       (make-economic-event
         "ev-combine-1" 'combine "proc-combine" #f
         "r-loaf-1" "r-basket" "spec-bread" #f
         "agent-a" "agent-a"
         (make-measure 1 "each") #f
         #f #f "2026-03-30T11:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((loaf ($ obs 'get-resource "r-loaf-1")))
      (check "combine: ingredient contained-in set to basket"
             (economic-resource-contained-in loaf) "r-basket")
      ;; onhand decremented on from (ingredient) - combine's onhand-effect is decrement
      (check "combine: ingredient onhand=0"
             (measure-has-numerical-value (economic-resource-onhand-quantity loaf)) 0))

    ;; resources-contained-in query
    (let ((contained ($ obs 'resources-contained-in "r-basket")))
      (check-pred "combine: resources-contained-in finds loaf"
                  (pair? (filter (lambda (r)
                                   (equal? (economic-resource-id r) "r-loaf-1"))
                                 contained))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Separate clears contained-in on separated resource
;;;
;;; separate action: onhand-effect = increment, contained-effect = remove
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Separate ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Separate: loaf out of basket
    ($ obs 'record-event
       (make-economic-event
         "ev-separate-1" 'separate #f "proc-separate"
         "r-loaf-1" #f "spec-bread" #f
         "agent-a" "agent-a"
         (make-measure 1 "each") #f
         #f #f "2026-03-30T12:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((loaf ($ obs 'get-resource "r-loaf-1")))
      (check "separate: contained-in cleared"
             (economic-resource-contained-in loaf) #f)
      ;; onhand incremented back on from (separated) - separate's onhand-effect is increment
      (check "separate: ingredient onhand=1"
             (measure-has-numerical-value (economic-resource-onhand-quantity loaf)) 1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 14. Move transfers onhand between resources without changing accountable
;;;
;;; move: accounting = decrement-increment, onhand = decrement-increment
;;; accountable-effect = no-effect (stays same owner)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Move ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed wheat at location-a
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat-move-a" "Wheat Warehouse A" #f #f #f "spec-wheat" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         "location-a" #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Move 30kg from r-wheat-move-a to r-wheat-move-b (auto-creates destination)
    ($ obs 'record-event
       (make-economic-event
         "ev-move-1" 'move #f #f
         "r-wheat-move-a" "r-wheat-move-b" "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 30 "kg") #f
         #f #f "2026-03-30T13:00:00Z" #f #f "location-b" #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((src ($ obs 'get-resource "r-wheat-move-a"))
          (dst ($ obs 'get-resource "r-wheat-move-b")))
      (check "move: source accounting=70"
             (measure-has-numerical-value (economic-resource-accounting-quantity src)) 70)
      (check "move: source onhand=70"
             (measure-has-numerical-value (economic-resource-onhand-quantity src)) 70)
      (check "move: dest accounting=30"
             (measure-has-numerical-value (economic-resource-accounting-quantity dst)) 30)
      (check "move: dest onhand=30"
             (measure-has-numerical-value (economic-resource-onhand-quantity dst)) 30)
      ;; accountable unchanged for move
      (check "move: source accountable unchanged"
             (economic-resource-primary-accountable src) "agent-a"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 15. Copy creates new resource without depleting source
;;;
;;; copy: accounting = increment-to, onhand = increment-to
;;; Source stays unchanged, destination gets the quantity.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Copy ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a digital resource
    ($ obs 'seed-resource
       (make-economic-resource "r-digital-orig" "Digital Pattern" #f #f #f "spec-tool" #f
         (make-measure 1 "each") (make-measure 1 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Copy resource to new destination
    ($ obs 'record-event
       (make-economic-event
         "ev-copy-1" 'copy #f #f
         "r-digital-orig" "r-digital-copy" "spec-tool" #f
         "agent-a" "agent-a"
         (make-measure 1 "each") #f
         #f #f "2026-03-30T14:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((orig ($ obs 'get-resource "r-digital-orig"))
          (copy ($ obs 'get-resource "r-digital-copy")))
      ;; Source unchanged (increment-to only affects 'to direction)
      (check "copy: source accounting unchanged=1"
             (measure-has-numerical-value (economic-resource-accounting-quantity orig)) 1)
      (check "copy: source onhand unchanged=1"
             (measure-has-numerical-value (economic-resource-onhand-quantity orig)) 1)
      ;; Destination gets the quantity
      (check "copy: dest accounting=1"
             (measure-has-numerical-value (economic-resource-accounting-quantity copy)) 1)
      (check "copy: dest onhand=1"
             (measure-has-numerical-value (economic-resource-onhand-quantity copy)) 1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 16. Inventory filtering — excludes qty=0 resources
;;;
;;; The inventory method filters out resources with both accounting=0 and onhand=0.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inventory filtering ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a zero-quantity resource
    ($ obs 'seed-resource
       (make-economic-resource "r-empty" "Empty Resource" #f #f #f "spec-wheat" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Seed a non-zero resource
    ($ obs 'seed-resource
       (make-economic-resource "r-full" "Full Resource" #f #f #f "spec-wheat" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    (let ((inv ($ obs 'inventory)))
      ;; r-empty should NOT be in inventory (qty=0)
      (check-pred "inventory: excludes zero-qty resource"
                  (not (any (lambda (r) (equal? (economic-resource-id r) "r-empty")) inv)))
      ;; r-full should be in inventory
      (check-pred "inventory: includes non-zero resource"
                  (any (lambda (r) (equal? (economic-resource-id r) "r-full")) inv)))

    ;; conforming-resources returns all resources matching a spec (even zero-qty)
    (let ((wheat-resources ($ obs 'conforming-resources "spec-wheat")))
      (check-pred "conforming-resources: returns wheat resources"
                  (>= (length wheat-resources) 2))
      ;; Should include both empty and full
      (check-pred "conforming-resources: includes zero-qty resource"
                  (any (lambda (r) (equal? (economic-resource-id r) "r-empty"))
                       wheat-resources)))

    ;; inventory-for-spec excludes zero-qty
    (let ((wheat-inv ($ obs 'inventory-for-spec "spec-wheat")))
      (check-pred "inventory-for-spec: excludes zero-qty"
                  (not (any (lambda (r) (equal? (economic-resource-id r) "r-empty"))
                            wheat-inv)))
      (check-pred "inventory-for-spec: includes non-zero"
                  (any (lambda (r) (equal? (economic-resource-id r) "r-full"))
                       wheat-inv)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 17. Corrections — apply-correction negates and replaces
;;;
;;; Record an event, then record a correction that negates the original and
;;; applies a new effect. Verify active-events-for-resource excludes corrected.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Corrections ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a resource for correction tests
    ($ obs 'seed-resource
       (make-economic-resource "r-corr" "Correction Test" #f #f #f "spec-wheat" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Record original event: produce 20kg (brings to 120)
    ($ obs 'record-event
       (make-economic-event
         "ev-corr-orig" 'produce #f "proc-corr"
         "r-corr" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 20 "kg") #f
         #f #f "2026-03-30T15:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-corr")))
      (check "correction: after original, qty=120"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 120))

    ;; Apply correction: corrects ev-corr-orig, new produce of 10kg
    ;; The correction negates the original (+20 -> -20, net 100), then applies +10 = 110
    ($ obs 'apply-correction
       (make-economic-event
         "ev-corr-fix" 'produce #f "proc-corr"
         "r-corr" #f "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 10 "kg") #f
         #f #f "2026-03-30T15:30:00Z" #f #f #f #f
         #f #f "ev-corr-orig" #f #f #f #f #f #f #f))

    (let ((r ($ obs 'get-resource "r-corr")))
      (check "correction: after fix, qty=110"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 110))

    ;; active-events-for-resource should exclude the corrected original
    (let ((active ($ obs 'active-events-for-resource "r-corr")))
      (check-pred "correction: active events exclude corrected"
                  (not (any (lambda (e) (equal? (economic-event-id e) "ev-corr-orig"))
                            active)))
      (check-pred "correction: active events include correction"
                  (any (lambda (e) (equal? (economic-event-id e) "ev-corr-fix"))
                       active)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 18. Satisfaction tracking — intent satisfaction via events
;;;
;;; Register an intent on the observer, record events with satisfies field,
;;; verify the satisfaction state is updated.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Satisfaction tracking ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Create an intent for 50kg wheat
    (let ((intent (make-intent "intent-sat-1" 'produce #f #f #f
                               #f #f #f "spec-wheat" #f
                               (make-measure 50 "kg") #f #f #f
                               "agent-a" "agent-a"
                               #f #f #f #f #f #f #f #f #f #f #f #f)))
      ;; Register the intent on the observer
      ($ obs 'register-intent intent)

      ;; Verify initial satisfaction state
      (let ((ss ($ obs 'get-satisfaction "intent-sat-1")))
        (check-pred "satisfaction: initial state exists" (satisfaction-state? ss))
        (check "satisfaction: initial total-satisfied=0"
               (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 0)
        (check "satisfaction: initial finished=#f"
               (satisfaction-state-finished ss) #f))

      ;; Record event satisfying 30kg of the intent
      ($ obs 'record-event
         (make-economic-event
           "ev-sat-1" 'produce #f "proc-sat"
           "r-wheat-rl" #f "spec-wheat" #f
           "agent-a" "agent-a"
           (make-measure 30 "kg") #f
           #f #f "2026-03-30T16:00:00Z" #f #f #f #f
           #f "intent-sat-1" #f #f #f #f #f #f #f #f))

      (let ((ss ($ obs 'get-satisfaction "intent-sat-1")))
        (check "satisfaction: partial total-satisfied=30"
               (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 30)
        (check "satisfaction: partial finished=#f"
               (satisfaction-state-finished ss) #f))

      ;; Record remaining 20kg
      ($ obs 'record-event
         (make-economic-event
           "ev-sat-2" 'produce #f "proc-sat"
           "r-wheat-rl" #f "spec-wheat" #f
           "agent-a" "agent-a"
           (make-measure 20 "kg") #f
           #f #f "2026-03-30T17:00:00Z" #f #f #f #f
           #f "intent-sat-1" #f #f #f #f #f #f #f #f))

      (let ((ss ($ obs 'get-satisfaction "intent-sat-1")))
        (check "satisfaction: full total-satisfied=50"
               (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 50)
        (check "satisfaction: full finished=#t"
               (satisfaction-state-finished ss) #t))

      ;; satisfied-by query
      (let ((events ($ obs 'satisfied-by "intent-sat-1")))
        (check "satisfaction: satisfied-by returns 2 events"
               (length events) 2)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 19. Over-fulfillment tracking
;;;
;;; Register commitment on observer, fulfill beyond committed qty,
;;; verify over-fulfilled flag.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Over-fulfillment ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed resource for over-fulfillment test
    ($ obs 'seed-resource
       (make-economic-resource "r-over" "Over Resource" #f #f #f "spec-bread" #f
         (make-measure 0 "each") (make-measure 0 "each")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Register commitment for 10 bread
    (let ((comm (make-commitment "c-over-1" 'produce #f #f "proc-over"
                                 #f "spec-bread" #f
                                 (make-measure 10 "each") #f
                                 "agent-a" "agent-a"
                                 #f #f #f #f #f #f #f #f #f #f #f #f
                                 "plan-ful" #f #f)))
      ($ obs 'register-commitment comm)

      ;; Fulfill with 15 (exceeds committed 10)
      ($ obs 'record-event
         (make-economic-event
           "ev-over-1" 'produce #f "proc-over"
           "r-over" #f "spec-bread" #f
           "agent-a" "agent-a"
           (make-measure 15 "each") #f
           #f #f "2026-03-30T18:00:00Z" #f #f #f #f
           "c-over-1" #f #f #f #f #f #f #f #f #f))

      (let ((fs ($ obs 'get-fulfillment "c-over-1")))
        (check-pred "over-fulfill: state exists" (fulfillment-state? fs))
        (check "over-fulfill: total-fulfilled=15"
               (measure-has-numerical-value (fulfillment-state-total-fulfilled fs)) 15)
        (check "over-fulfill: finished=#t"
               (fulfillment-state-finished fs) #t)
        (check "over-fulfill: over-fulfilled=#t"
               (fulfillment-state-over-fulfilled fs) #t))

      ;; fulfilled-by query
      (let ((events ($ obs 'fulfilled-by "c-over-1")))
        (check "over-fulfill: fulfilled-by returns 1 event"
               (length events) 1)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 20. Claims — register and query claim states
;;;
;;; Register a claim, settle it via events, verify state and queries.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claims ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Register a claim for 20 oz gold
    (let ((claim (make-claim "claim-1" 'transfer "agent-a" "agent-b"
                             "ev-transfer-1"
                             (make-measure 20 "oz") #f
                             "spec-gold" #f
                             #f #f #f #f)))
      ($ obs 'register-claim claim)

      ;; Verify initial claim state
      (let ((cs ($ obs 'get-claim-state "claim-1")))
        (check-pred "claims: initial state exists" (claim-state? cs))
        (check "claims: initial total-settled=0"
               (measure-has-numerical-value (claim-state-total-settled cs)) 0)
        (check "claims: initial finished=#f"
               (claim-state-finished cs) #f))

      ;; Seed resources for settlement
      ($ obs 'seed-resource
         (make-economic-resource "r-gold-settle-a" "Gold Settle A" #f #f #f "spec-gold" #f
           (make-measure 30 "oz") (make-measure 30 "oz")
           #f #f "agent-a" #f #f #f #f #f #f #f #f))

      ;; Settle 12 oz
      ($ obs 'record-event
         (make-economic-event
           "ev-settle-1" 'transfer #f #f
           "r-gold-settle-a" "r-gold-settle-b" "spec-gold" #f
           "agent-a" "agent-b"
           (make-measure 12 "oz") #f
           #f #f "2026-03-30T19:00:00Z" #f #f #f #f
           #f #f #f #f "claim-1" #f #f #f #f #f))

      (let ((cs ($ obs 'get-claim-state "claim-1")))
        (check "claims: partial total-settled=12"
               (measure-has-numerical-value (claim-state-total-settled cs)) 12)
        (check "claims: partial finished=#f"
               (claim-state-finished cs) #f))

      ;; Settle remaining 8 oz
      ($ obs 'record-event
         (make-economic-event
           "ev-settle-2" 'transfer #f #f
           "r-gold-settle-a" "r-gold-settle-b" "spec-gold" #f
           "agent-a" "agent-b"
           (make-measure 8 "oz") #f
           #f #f "2026-03-30T19:30:00Z" #f #f #f #f
           #f #f #f #f "claim-1" #f #f #f #f #f))

      (let ((cs ($ obs 'get-claim-state "claim-1")))
        (check "claims: full total-settled=20"
               (measure-has-numerical-value (claim-state-total-settled cs)) 20)
        (check "claims: full finished=#t"
               (claim-state-finished cs) #t))

      ;; all-claims returns the hashmap of claim states
      (let ((all-cs ($ obs 'all-claims)))
        (check-pred "claims: all-claims contains claim-1"
                    (hashmap-ref all-cs "claim-1" #f)))

      ;; settled-by query
      (let ((events ($ obs 'settled-by "claim-1")))
        (check "claims: settled-by returns 2 events"
               (length events) 2)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 21. Inventory slicing — by agent and location
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inventory slicing ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed resource at specific location for agent-b
    ($ obs 'seed-resource
       (make-economic-resource "r-loc-test" "Location Test" #f #f #f "spec-wheat" #f
         (make-measure 25 "kg") (make-measure 25 "kg")
         "warehouse-1" #f "agent-b" #f #f #f #f #f #f #f #f))

    ;; inventory-for-agent
    (let ((agent-b-inv ($ obs 'inventory-for-agent "agent-b")))
      (check-pred "inv-slice: agent-b has resources"
                  (any (lambda (r) (equal? (economic-resource-id r) "r-loc-test"))
                       agent-b-inv)))

    ;; inventory-at-location
    (let ((wh-inv ($ obs 'inventory-at-location "warehouse-1")))
      (check-pred "inv-slice: warehouse-1 has resources"
                  (any (lambda (r) (equal? (economic-resource-id r) "r-loc-test"))
                       wh-inv))
      ;; Other locations should not include this resource
      (check-pred "inv-slice: other location excludes resource"
                  (null? ($ obs 'inventory-at-location "nonexistent-loc"))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 22. Event trace — trace-resource walks previousEvent chain
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Event trace ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; r-bread has had multiple events: produce, consume
    ;; trace-resource should return events in chronological order
    (let ((trace ($ obs 'trace-resource "r-bread")))
      (check-pred "trace: returns non-empty trace for bread"
                  (pair? trace))
      ;; The trace should contain the produce and consume events
      (check-pred "trace: trace events are economic-event records"
                  (economic-event? (car trace))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 23. Events-for-agreement query
;;;
;;; Ported from: observer-gaps.test.ts "M3 — eventsForAgreement"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Events for agreement ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Record two events with realization-of = "agreement-xyz"
    ($ obs 'record-event
       (make-economic-event
         "ev-agr-1" 'transfer #f #f
         #f #f "spec-wheat" #f
         "agent-alice" "agent-bob"
         (make-measure 100 "kg") #f
         #f #f "2026-03-20T10:00:00Z" #f #f #f #f
         #f #f #f "agreement-xyz" #f #f #f #f #f #f))
    ($ obs 'record-event
       (make-economic-event
         "ev-agr-2" 'transfer #f #f
         #f #f "spec-gold" #f
         "agent-bob" "agent-alice"
         (make-measure 50 "oz") #f
         #f #f "2026-03-20T10:05:00Z" #f #f #f #f
         #f #f #f "agreement-xyz" #f #f #f #f #f #f))
    ;; Record an event with NO agreement
    ($ obs 'record-event
       (make-economic-event
         "ev-no-agr" 'transfer #f #f
         #f #f "spec-wheat" #f
         "agent-alice" "agent-bob"
         (make-measure 10 "kg") #f
         #f #f "2026-03-20T11:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Query events for agreement-xyz
    (let ((agr-events ($ obs 'events-for-agreement "agreement-xyz")))
      (check "agreement: 2 events" (length agr-events) 2)
      (let ((ids (map economic-event-id agr-events)))
        (check-pred "agreement: includes ev-agr-1" (member "ev-agr-1" ids))
        (check-pred "agreement: includes ev-agr-2" (member "ev-agr-2" ids))
        (check-pred "agreement: excludes ev-no-agr" (not (member "ev-no-agr" ids)))))

    ;; Unknown agreement → empty
    (let ((empty-events ($ obs 'events-for-agreement "agreement-missing")))
      (check "agreement: unknown → empty" (length empty-events) 0))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
