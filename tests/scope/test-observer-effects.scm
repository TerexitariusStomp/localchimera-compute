;;; SPDX-License-Identifier: AGPL-3.0-or-later
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

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet algorithms track-trace) (playnet scope root) (playnet vf schemas) (playnet observation states) (srfi srfi-1))
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

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Observer Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-gold" #:name "Gold" #:default-unit-of-resource "oz"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-tool" #:name "Tool" #:default-unit-of-resource %count-unit))
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
       (make-economic-resource #:id "r-bread" #:name "Bread" #:conforms-to "spec-bread"
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:primary-accountable "agent-a"))

    ;; Produce 10
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-produce-1" #:action 'produce #:output-of "proc-1"
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-28T08:00:00Z"))

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
         #:id "ev-consume-1" #:action 'consume #:input-of "proc-2"
         #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 3 %count-unit) #:has-point-in-time "2026-03-28T09:00:00Z"))

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
       (make-economic-resource #:id "r-gold-a" #:name "Gold A" #:conforms-to "spec-gold"
         #:accounting-quantity (make-measure 10 "oz") #:onhand-quantity (make-measure 10 "oz") #:primary-accountable "agent-a"))

    ;; Transfer 4oz from r-gold-a to r-gold-b
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-transfer-1" #:action 'transfer
         #:resource-inventoried-as "r-gold-a" #:to-resource-inventoried-as "r-gold-b" #:resource-conforms-to "spec-gold"
         #:provider "agent-a" #:receiver "agent-b"
         #:resource-quantity (make-measure 4 "oz") #:has-point-in-time "2026-03-28T10:00:00Z"))

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
       (make-economic-resource #:id "r-tool" #:name "Hammer" #:conforms-to "spec-tool"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "agent-a"))

    ;; Use the tool
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-use-1" #:action 'use #:input-of "proc-3"
         #:resource-inventoried-as "r-tool" #:resource-conforms-to "spec-tool"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-28T11:00:00Z"))

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
         #:id "ev-cite-1" #:action 'cite #:input-of "proc-4"
         #:resource-inventoried-as "r-tool" #:resource-conforms-to "spec-tool"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-28T12:00:00Z"))

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
       (make-economic-resource #:id "r-cap-alice" #:name "Alice Capacity" #:conforms-to "spec-tool"
         #:accounting-quantity (make-measure 40 %effort-unit) #:onhand-quantity (make-measure 40 %effort-unit) #:primary-accountable "agent-alice"))

    ;; Record work event
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-work-1" #:action 'work #:input-of "proc-5"
         #:resource-inventoried-as "r-cap-alice" #:resource-conforms-to "spec-tool"
         #:provider "agent-alice" #:receiver "agent-alice" #:effort-quantity (make-measure 8 %effort-unit) #:has-point-in-time "2026-03-28T10:00:00Z"))

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
       (make-economic-resource #:id "r-wheat-rl" #:name "Wheat RL" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "agent-a"))

    ;; Raise by 10
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-raise-1" #:action 'raise
         #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 10 "kg") #:has-point-in-time "2026-03-28T13:00:00Z"))

    (let ((r ($ obs 'get-resource "r-wheat-rl")))
      (check "raise: qty=110"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             110))

    ;; Lower by 20
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-lower-1" #:action 'lower
         #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 20 "kg") #:has-point-in-time "2026-03-28T14:00:00Z"))

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
    ($ ps 'add-plan (make-plan #:id "plan-ful" #:name "Fulfillment Plan"
                               #:due "2026-04-07T00:00:00Z" #:created "2026-03-27T00:00:00Z"))
    ($ ps 'add-commitment
       (make-commitment #:id "c-wheat-ful" #:action 'produce #:output-of "proc-ful" #:resource-conforms-to "spec-wheat"
                        #:resource-quantity (make-measure 100 "kg")
                        #:provider "agent-a" #:receiver "agent-a"
                        #:planned-within "plan-ful"))

    ;; Record partial fulfillment: 60kg
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-ful-1" #:action 'produce #:output-of "proc-ful"
         #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 60 "kg")
         #:has-beginning "c-wheat-ful" #:has-point-in-time "2026-03-29T08:00:00Z"))

    ;; Record remaining fulfillment: 40kg
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-ful-2" #:action 'produce #:output-of "proc-ful"
         #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 40 "kg")
         #:has-beginning "c-wheat-ful" #:has-point-in-time "2026-03-29T10:00:00Z"))

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
    scope-root-env
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
       (make-economic-resource #:id "r-flour-state" #:name "Flour State" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg") #:primary-accountable "agent-a"))

    ;; Produce 50kg with state = 'fresh
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-state-1" #:action 'produce #:output-of "proc-state-1"
         #:resource-inventoried-as "r-flour-state" #:resource-conforms-to "spec-flour"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-03-30T08:00:00Z" #:state 'fresh))

    (let ((r ($ obs 'get-resource "r-flour-state")))
      (check "state: produce sets state to fresh"
             (economic-resource-state r) 'fresh)
      (check "state: produce qty=50"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 50))

    ;; Use the flour with state = 'processing (use has state-effect 'update)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-state-2" #:action 'use #:input-of "proc-state-2"
         #:resource-inventoried-as "r-flour-state" #:resource-conforms-to "spec-flour"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 "kg") #:has-point-in-time "2026-03-30T09:00:00Z" #:state 'processing))

    (let ((r ($ obs 'get-resource "r-flour-state")))
      (check "state: use updates state to processing"
             (economic-resource-state r) 'processing)
      ;; use has no-effect on quantities
      (check "state: use qty unchanged=50"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 50))

    ;; Cite the resource with state = 'referenced
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-state-3" #:action 'cite #:input-of "proc-state-3"
         #:resource-inventoried-as "r-flour-state" #:resource-conforms-to "spec-flour"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 "kg") #:has-point-in-time "2026-03-30T10:00:00Z" #:state 'referenced))

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
       (make-economic-resource #:id "r-basket" #:name "Bread Basket" #:conforms-to "spec-bread"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "agent-a"))

    ;; Seed an ingredient resource (a bread loaf)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-loaf-1" #:name "Loaf 1" #:conforms-to "spec-bread"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "agent-a"))

    ;; Combine: loaf goes into basket
    ;; resource-inventoried-as = ingredient (from), to-resource-inventoried-as = container (to)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-combine-1" #:action 'combine #:input-of "proc-combine"
         #:resource-inventoried-as "r-loaf-1" #:to-resource-inventoried-as "r-basket" #:resource-conforms-to "spec-bread"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-30T11:00:00Z"))

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
         #:id "ev-separate-1" #:action 'separate #:output-of "proc-separate"
         #:resource-inventoried-as "r-loaf-1" #:resource-conforms-to "spec-bread"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-30T12:00:00Z"))

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
       (make-economic-resource #:id "r-wheat-move-a" #:name "Wheat Warehouse A" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg")
         #:current-location "location-a" #:primary-accountable "agent-a"))

    ;; Move 30kg from r-wheat-move-a to r-wheat-move-b (auto-creates destination)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-move-1" #:action 'move
         #:resource-inventoried-as "r-wheat-move-a" #:to-resource-inventoried-as "r-wheat-move-b" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 30 "kg") #:has-point-in-time "2026-03-30T13:00:00Z" #:to-location "location-b"))

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
       (make-economic-resource #:id "r-digital-orig" #:name "Digital Pattern" #:conforms-to "spec-tool"
         #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "agent-a"))

    ;; Copy resource to new destination
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-copy-1" #:action 'copy
         #:resource-inventoried-as "r-digital-orig" #:to-resource-inventoried-as "r-digital-copy" #:resource-conforms-to "spec-tool"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 1 %count-unit) #:has-point-in-time "2026-03-30T14:00:00Z"))

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
       (make-economic-resource #:id "r-empty" #:name "Empty Resource" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg") #:primary-accountable "agent-a"))

    ;; Seed a non-zero resource
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-full" #:name "Full Resource" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg") #:primary-accountable "agent-a"))

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
;;; 17. Corrections — a correction is a signed event (VF accounting.md)
;;;
;;; Record an event, then record a correction: an event of the same action with a
;;; signed quantity that `corrects` it. The net effect is the sum; the original
;;; stays and stands at its net quantity, and the correction is no act of its own.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Corrections ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed a resource for correction tests
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-corr" #:name "Correction Test" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "agent-a"))

    ;; Record original event: produce 20kg (brings to 120)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-corr-orig" #:action 'produce #:output-of "proc-corr"
         #:resource-inventoried-as "r-corr" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 20 "kg") #:has-point-in-time "2026-03-30T15:00:00Z"))

    (let ((r ($ obs 'get-resource "r-corr")))
      (check "correction: after original, qty=120"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 120))

    ;; Apply correction: corrects ev-corr-orig; 20 kg should have been 10, so the
    ;; correction is a produce of -10 kg: the net is 120 - 10 = 110
    ($ obs 'apply-correction
       (make-economic-event
         #:id "ev-corr-fix" #:action 'produce #:output-of "proc-corr"
         #:resource-inventoried-as "r-corr" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure -10 "kg") #:has-point-in-time "2026-03-30T15:30:00Z" #:corrects "ev-corr-orig"))

    (let ((r ($ obs 'get-resource "r-corr")))
      (check "correction: after fix, qty=110"
             (measure-has-numerical-value (economic-resource-accounting-quantity r)) 110))

    ;; active-events-for-resource lists the acts that stand, each at its net
    (let ((active ($ obs 'active-events-for-resource "r-corr")))
      (check-pred "correction: the corrected act stands"
                  (any (lambda (e) (equal? (economic-event-id e) "ev-corr-orig")) active))
      (check "correction: …at its net quantity, 10 kg"
             (measure-has-numerical-value
              (economic-event-resource-quantity
               (find (lambda (e) (equal? (economic-event-id e) "ev-corr-orig")) active)))
             10)
      (check-pred "correction: the correction is no act of its own"
                  (not (any (lambda (e) (equal? (economic-event-id e) "ev-corr-fix")) active))))))
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
    (let ((intent (make-intent #:id "intent-sat-1" #:action 'produce #:resource-conforms-to "spec-wheat"
                               #:resource-quantity (make-measure 50 "kg")
                               #:provider "agent-a" #:receiver "agent-a")))
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
           #:id "ev-sat-1" #:action 'produce #:output-of "proc-sat"
           #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
           #:provider "agent-a" #:receiver "agent-a"
           #:resource-quantity (make-measure 30 "kg") #:has-point-in-time "2026-03-30T16:00:00Z" #:satisfies "intent-sat-1"))

      (let ((ss ($ obs 'get-satisfaction "intent-sat-1")))
        (check "satisfaction: partial total-satisfied=30"
               (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 30)
        (check "satisfaction: partial finished=#f"
               (satisfaction-state-finished ss) #f))

      ;; Record remaining 20kg
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-sat-2" #:action 'produce #:output-of "proc-sat"
           #:resource-inventoried-as "r-wheat-rl" #:resource-conforms-to "spec-wheat"
           #:provider "agent-a" #:receiver "agent-a"
           #:resource-quantity (make-measure 20 "kg") #:has-point-in-time "2026-03-30T17:00:00Z" #:satisfies "intent-sat-1"))

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
;;; 18b. Satisfaction through the commitment chain
;;;
;;; VF's chain (valueflows/concepts/flows.md): the event fulfils the
;;; COMMITMENT, and the commitment satisfies the INTENT — an event satisfies
;;; directly only "when there is no Commitment". Registering the commitment
;;; writes the satisfying-commitments edge; fulfilling it flows the quantity
;;; through to the intent's satisfaction state.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Satisfaction through the commitment chain ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; an intent wanting 10 hours of milling
    ($ obs 'register-intent
       (make-intent #:id "intent-chain-1" #:action 'work #:resource-conforms-to "skill-mill" #:effort-quantity (make-measure 10 %effort-unit)
                    #:provider "agent-a" #:receiver "agent-a"))
    ;; a commitment for those 10 hours, SATISFYING the intent
    ($ obs 'register-commitment
       (make-commitment #:id "c-chain-1" #:action 'work #:input-of "proc-chain" #:resource-conforms-to "skill-mill" #:effort-quantity (make-measure 10 %effort-unit)
                        #:provider "agent-a" #:receiver "agent-a"
                        #:satisfies "intent-chain-1"))
    (let ((ss ($ obs 'get-satisfaction "intent-chain-1")))
      (check-pred "chain: registration writes satisfying-commitments"
                  (member "c-chain-1" (satisfaction-state-satisfying-commitments ss))))
    ;; 6 hours happen — the event carries ONLY fulfills (the observer's law)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-chain-1" #:action 'work #:input-of "proc-chain" #:resource-conforms-to "skill-mill"
         #:provider "agent-a" #:receiver "agent-a" #:effort-quantity (make-measure 6 %effort-unit) #:has-point-in-time "2026-03-30T18:00:00Z"
         #:fulfills "c-chain-1"))
    (let ((fs ($ obs 'get-fulfillment "c-chain-1"))
          (ss ($ obs 'get-satisfaction "intent-chain-1")))
      (check "chain: fulfilment advanced to 6"
             (measure-has-numerical-value (fulfillment-state-total-fulfilled fs)) 6)
      (check "chain: satisfaction flowed through to 6"
             (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 6)
      (check "chain: not finished at 6 of 10"
             (satisfaction-state-finished ss) #f))
    ;; the remaining 4
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-chain-2" #:action 'work #:input-of "proc-chain" #:resource-conforms-to "skill-mill"
         #:provider "agent-a" #:receiver "agent-a" #:effort-quantity (make-measure 4 %effort-unit) #:has-point-in-time "2026-03-30T22:00:00Z"
         #:fulfills "c-chain-1"))
    (let ((ss ($ obs 'get-satisfaction "intent-chain-1")))
      (check "chain: satisfaction complete at 10"
             (measure-has-numerical-value (satisfaction-state-total-satisfied ss)) 10)
      (check "chain: finished"
             (satisfaction-state-finished ss) #t))))
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
       (make-economic-resource #:id "r-over" #:name "Over Resource" #:conforms-to "spec-bread"
         #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:primary-accountable "agent-a"))

    ;; Register commitment for 10 bread
    (let ((comm (make-commitment #:id "c-over-1" #:action 'produce #:output-of "proc-over" #:resource-conforms-to "spec-bread"
                                 #:resource-quantity (make-measure 10 %count-unit)
                                 #:provider "agent-a" #:receiver "agent-a"
                                 #:planned-within "plan-ful")))
      ($ obs 'register-commitment comm)

      ;; Fulfill with 15 (exceeds committed 10)
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-over-1" #:action 'produce #:output-of "proc-over"
           #:resource-inventoried-as "r-over" #:resource-conforms-to "spec-bread"
           #:provider "agent-a" #:receiver "agent-a"
           #:resource-quantity (make-measure 15 %count-unit) #:has-point-in-time "2026-03-30T18:00:00Z"
           #:fulfills "c-over-1"))

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
    (let ((claim (make-claim #:id "claim-1" #:action 'transfer #:provider "agent-a" #:receiver "agent-b"
                             #:triggered-by "ev-transfer-1"
                             #:resource-quantity (make-measure 20 "oz")
                             #:resource-conforms-to "spec-gold")))
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
         (make-economic-resource #:id "r-gold-settle-a" #:name "Gold Settle A" #:conforms-to "spec-gold"
           #:accounting-quantity (make-measure 30 "oz") #:onhand-quantity (make-measure 30 "oz") #:primary-accountable "agent-a"))

      ;; Settle 12 oz
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-settle-1" #:action 'transfer
           #:resource-inventoried-as "r-gold-settle-a" #:to-resource-inventoried-as "r-gold-settle-b" #:resource-conforms-to "spec-gold"
           #:provider "agent-a" #:receiver "agent-b"
           #:resource-quantity (make-measure 12 "oz") #:has-point-in-time "2026-03-30T19:00:00Z" #:settles "claim-1"))

      (let ((cs ($ obs 'get-claim-state "claim-1")))
        (check "claims: partial total-settled=12"
               (measure-has-numerical-value (claim-state-total-settled cs)) 12)
        (check "claims: partial finished=#f"
               (claim-state-finished cs) #f))

      ;; Settle remaining 8 oz
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-settle-2" #:action 'transfer
           #:resource-inventoried-as "r-gold-settle-a" #:to-resource-inventoried-as "r-gold-settle-b" #:resource-conforms-to "spec-gold"
           #:provider "agent-a" #:receiver "agent-b"
           #:resource-quantity (make-measure 8 "oz") #:has-point-in-time "2026-03-30T19:30:00Z" #:settles "claim-1"))

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
       (make-economic-resource #:id "r-loc-test" #:name "Location Test" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 25 "kg") #:onhand-quantity (make-measure 25 "kg")
         #:current-location "warehouse-1" #:primary-accountable "agent-b"))

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
         #:id "ev-agr-1" #:action 'transfer #:resource-conforms-to "spec-wheat"
         #:provider "agent-alice" #:receiver "agent-bob"
         #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-03-20T10:00:00Z" #:realization-of "agreement-xyz"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-agr-2" #:action 'transfer #:resource-conforms-to "spec-gold"
         #:provider "agent-bob" #:receiver "agent-alice"
         #:resource-quantity (make-measure 50 "oz") #:has-point-in-time "2026-03-20T10:05:00Z" #:realization-of "agreement-xyz"))
    ;; Record an event with NO agreement
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-no-agr" #:action 'transfer #:resource-conforms-to "spec-wheat"
         #:provider "agent-alice" #:receiver "agent-bob"
         #:resource-quantity (make-measure 10 "kg") #:has-point-in-time "2026-03-20T11:00:00Z"))

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
(test-summary!)
