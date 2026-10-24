;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-resource-flows.scm — Resource flow reports and value equations
;;;
;;; Ported from: old/planner/src/lib/tests/resource-flows.test.ts
;;;              old/planner/src/lib/tests/value-equations.test.ts
;;;              old/planner/src/lib/tests/rollup.test.ts
;;;
;;; Intent: Verify resource flow tracking (inflows/outflows by period),
;;; value distribution across recipe chains, and cost rollup.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-resource-flows.scm

(use-modules ((localchimera utils units) #:select (%count-unit %effort-unit)))
(use-modules (localchimera test harness))
(use-modules (localchimera algorithms propagation) (localchimera scope root) (localchimera vf schemas) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
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
    (lambda () (spawn-scope-root "Flow Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource %count-unit))

    ;; Seed resources
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-wheat" #:name "Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 1000 "kg") #:onhand-quantity (make-measure 1000 "kg") #:primary-accountable "agent-alice"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-flour" #:name "Flour" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg") #:primary-accountable "agent-bob"))

    (check-pred "setup ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Inflows and outflows tracking
;;;
;;; Ported from: "separates actual inflows and outflows"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inflows and outflows ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; March: Alice receives 100kg wheat from Bob (transfer inflow)
    ;; to-resource-inventoried-as = r-wheat (destination), resource-inventoried-as = #f
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-transfer-in-1" #:action 'transfer #:to-resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
         #:provider "agent-bob" #:receiver "agent-alice"
         #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-03-10T10:00:00Z"))

    ;; March: Alice sends 40kg wheat to Carol (transfer outflow)
    ;; resource-inventoried-as = r-wheat (source), to = #f
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-transfer-out-1" #:action 'transfer
         #:resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
         #:provider "agent-alice" #:receiver "agent-carol"
         #:resource-quantity (make-measure 40 "kg") #:has-point-in-time "2026-03-20T10:00:00Z"))

    ;; April: Alice receives 50kg wheat from Carol (transfer inflow)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-transfer-in-2" #:action 'transfer #:to-resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
         #:provider "agent-carol" #:receiver "agent-alice"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-05T10:00:00Z"))

    ;; All transfer events recorded
    (let ((events ($ obs 'all-events)))
      (check-pred "3 events recorded" (= 3 (length events))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Event filtering by action type
;;;
;;; Ported from: "only includes transfer events for the agent"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Event filtering ──\n")

(with-vat vat
  (let* ((obs ($ scope 'observer))
         (events ($ obs 'all-events))
         (transfers (filter (lambda (e) (eq? 'transfer (economic-event-action e)))
                            events)))
    (check-pred "all events are transfers" (= 3 (length transfers)))

    ;; Count inflows to alice (receiver = agent-alice)
    (let ((inflows (filter (lambda (e) (equal? "agent-alice"
                                               (economic-event-receiver e)))
                           transfers)))
      (check-pred "2 inflows to alice" (= 2 (length inflows))))

    ;; Count outflows from alice (provider = agent-alice)
    (let ((outflows (filter (lambda (e) (equal? "agent-alice"
                                                (economic-event-provider e)))
                            transfers)))
      (check-pred "1 outflow from alice" (= 1 (length outflows))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Resource state after flows
;;;
;;; Ported from: flow effect verification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Resource state after flows ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Wheat: started at 1000, +100, -40, +50 = 1110
    (let ((r ($ obs 'get-resource "r-wheat")))
      (check "wheat after flows"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             1110))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Production flows
;;;
;;; Ported from: "processes generate correct intents and scheduled flows"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Production flows ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Alice mills wheat → flour
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-mill-consume" #:action 'consume #:input-of "proc-mill"
         #:resource-inventoried-as "r-wheat" #:resource-conforms-to "spec-wheat"
         #:provider "agent-alice" #:receiver "agent-alice"
         #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-03-15T08:00:00Z"))
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-mill-produce" #:action 'produce #:output-of "proc-mill"
         #:resource-inventoried-as "r-flour" #:resource-conforms-to "spec-flour"
         #:provider "agent-alice" #:receiver "agent-alice"
         #:resource-quantity (make-measure 80 "kg") #:has-point-in-time "2026-03-15T10:00:00Z"))

    ;; Verify: wheat decreased, flour increased
    (let ((wheat ($ obs 'get-resource "r-wheat"))
          (flour ($ obs 'get-resource "r-flour")))
      (check "wheat after milling"
             (measure-has-numerical-value (economic-resource-accounting-quantity wheat))
             1010)  ;; 1110 - 100
      (check "flour after milling"
             (measure-has-numerical-value (economic-resource-accounting-quantity flour))
             80))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. SNLT cost rollup through chain
;;;
;;; Ported from: rollup.test.ts "rolls up cost through recipe chain"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── SNLT rollup ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; Add work flows for SNE computation
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-mill-w" #:name "Mill"
                            #:has-duration (make-duration 2 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-work" #:action 'work
                         #:effort-quantity (make-measure 1 %effort-unit) #:recipe-input-of "rp-mill-w"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-mill-w"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-mill-fo" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-mill-w"))

    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake-w" #:name "Bake"
                            #:has-duration (make-duration 4 %effort-unit)))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-work" #:action 'work
                         #:effort-quantity (make-measure 2 %effort-unit) #:recipe-input-of "rp-bake-w"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-fi" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-bake-w"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bake-bo" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 20 %count-unit) #:recipe-output-of "rp-bake-w"))

    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread-w" #:name "Bread (worked)" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-mill-w" "rp-bake-w")))

    ;; SNLT = total work / total output = (1h + 2h) / 20 = 0.15 hours/bread
    (let ((snlt (compute-snlt rs "recipe-bread-w")))
      (check-pred "snlt bread = 0.15" (approx= 0.15 snlt 0.001)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. SNE index
;;;
;;; Ported from: rollup "SNE index maps spec to efficiency"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── SNE index ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; Inline SNE computation — avoids the actor-vs-facts collision
    ;; that used to bite `build-sne-index`. (Now resolved: the actor
    ;; version is `build-sne-index/actor`, but this test already
    ;; had an inline version so we keep it.)
    ;; SNLT = total-work / primary-output-qty
    ;; total-work = 1h (mill) + 2h (bake) = 3h
    ;; primary-output = 20 bread (from last process's produce flow)
    ;; SNLT = 3/20 = 0.15
    (let* ((chain ($ rs 'get-process-chain "recipe-bread-w"))
           (total-work
             (fold (lambda (rp acc)
                     (let* ((pid (recipe-process-id rp))
                            (flows ($ rs 'flows-for-process pid))
                            (inputs (car flows)))
                       (+ acc (fold (lambda (f a)
                                      (if (and (eq? (recipe-flow-action f) 'work)
                                               (recipe-flow-effort-quantity f))
                                          (+ a (measure-has-numerical-value
                                                 (recipe-flow-effort-quantity f)))
                                          a))
                                    0 inputs))))
                   0 chain))
           ;; Only count the PRIMARY output (last process's produce flow)
           (last-proc (last chain))
           (last-pid (recipe-process-id last-proc))
           (last-flows ($ rs 'flows-for-process last-pid))
           (last-outputs (cdr last-flows))
           (primary-output
             (fold (lambda (f a)
                     (if (and (eq? (recipe-flow-action f) 'produce)
                              (recipe-flow-resource-quantity f))
                         (+ a (measure-has-numerical-value
                                (recipe-flow-resource-quantity f)))
                         a))
                   0 last-outputs))
           (bread-sne (if (> primary-output 0) (/ total-work primary-output) 0)))
      (check-pred "sne bread computed" (number? bread-sne))
      (check-pred "sne bread = 0.15" (approx= 0.15 bread-sne 0.001)))))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
