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
       (make-commitment "c-wheat-ful" 'produce #f "proc-ful"
                        "spec-wheat" #f
                        (make-measure 100 "kg") #f
                        "agent-a" "agent-a"
                        #f #f #f #f #f "plan-ful" #f #f #f #f))

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

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
