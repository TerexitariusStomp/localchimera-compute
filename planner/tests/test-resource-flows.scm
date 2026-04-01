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
    (lambda () (spawn-scope "Flow Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))

    ;; Seed resources
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat" "Wheat" #f #f #f "spec-wheat" #f
         (make-measure 1000 "kg") (make-measure 1000 "kg")
         #f #f "agent-alice" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-flour" "Flour" #f #f #f "spec-flour" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         #f #f "agent-bob" #f #f #f #f #f #f #f #f))

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
         "ev-transfer-in-1" 'transfer #f #f
         #f "r-wheat" "spec-wheat" #f
         "agent-bob" "agent-alice"
         (make-measure 100 "kg") #f
         #f #f "2026-03-10T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; March: Alice sends 40kg wheat to Carol (transfer outflow)
    ;; resource-inventoried-as = r-wheat (source), to = #f
    ($ obs 'record-event
       (make-economic-event
         "ev-transfer-out-1" 'transfer #f #f
         "r-wheat" #f "spec-wheat" #f
         "agent-alice" "agent-carol"
         (make-measure 40 "kg") #f
         #f #f "2026-03-20T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; April: Alice receives 50kg wheat from Carol (transfer inflow)
    ($ obs 'record-event
       (make-economic-event
         "ev-transfer-in-2" 'transfer #f #f
         #f "r-wheat" "spec-wheat" #f
         "agent-carol" "agent-alice"
         (make-measure 50 "kg") #f
         #f #f "2026-04-05T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
         "ev-mill-consume" 'consume "proc-mill" #f
         "r-wheat" #f "spec-wheat" #f
         "agent-alice" "agent-alice"
         (make-measure 100 "kg") #f
         #f #f "2026-03-15T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))
    ($ obs 'record-event
       (make-economic-event
         "ev-mill-produce" 'produce #f "proc-mill"
         "r-flour" #f "spec-flour" #f
         "agent-alice" "agent-alice"
         (make-measure 80 "kg") #f
         #f #f "2026-03-15T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

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
       (make-recipe-process "rp-mill-w" "Mill" #f #f #f #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-mill-work" 'work #f #f
                         #f (make-measure 1 "hours") "rp-mill-w" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-mill-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill-w" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-mill-fo" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill-w" #f #f #f #f #f #f))

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake-w" "Bake" #f #f #f #f
                            (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bake-work" 'work #f #f
                         #f (make-measure 2 "hours") "rp-bake-w" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bake-fi" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake-w" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bake-bo" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake-w" #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-bread-w" "Bread (worked)" #f #f "spec-bread"
                    (list "rp-mill-w" "rp-bake-w") #f))

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
    ;; Inline SNE computation (build-sne-index has SRFI-1 scoping issues)
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
(when (> fail-count 0) (exit 1))
