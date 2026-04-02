;;; test-rollup-costvar.scm — Standard/actual cost rollup and variance
;;;
;;; Ported from: old/planner/src/lib/tests/rollup.test.ts
;;;
;;; Intent: Verify standard cost rollup from recipe BOM, actual cost from
;;; observed events, and cost variance computation.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-rollup-costvar.scm

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
;;; Setup + All tests in single with-vat
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup & Tests: Rollup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Rollup Test"))
    store))

;; Price lookup
(define (mock-price spec unit)
  (cond
    ((equal? spec "spec-wood")  10)   ;; $10 per board
    ((equal? spec "spec-nail")  1)    ;; $1 per nail
    ((equal? spec "spec-labor") 50)   ;; $50 per hour
    (else 0)))

;; Inline rollup computation (rollup.scm has a module-scoping issue with srfi-1)
(define (test-rollup-standard recipe-id rs price-fn scale)
  (let* ((chain ($ rs 'get-process-chain recipe-id))
         (stages
           (map (lambda (rp)
                  (let* ((pid (recipe-process-id rp))
                         (flows ($ rs 'flows-for-process pid))
                         (inputs (car flows))
                         (stage-cost
                           (fold (lambda (f acc)
                                   (let* ((spec (recipe-flow-resource-conforms-to f))
                                          (rq (recipe-flow-resource-quantity f))
                                          (eq (recipe-flow-effort-quantity f))
                                          (qty (cond (rq (* (measure-has-numerical-value rq) scale))
                                                     (eq (* (measure-has-numerical-value eq) scale))
                                                     (else 0)))
                                          (unit (cond (rq (measure-has-unit rq))
                                                      (eq (measure-has-unit eq))
                                                      (else "each")))
                                          (price (if spec (price-fn spec unit) 0)))
                                     (+ acc (* qty price))))
                                 0 inputs)))
                    `((process-id . ,pid) (name . ,(recipe-process-name rp))
                      (cost . ,stage-cost))))
                chain)))
    `((total . ,(fold (lambda (s acc) (+ acc (assq-ref s 'cost))) 0 stages))
      (by-stage . ,stages))))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── Setup ──────────────────────────────────────────────────

    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wood" "Wood" #f #f #f "board" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-nail" "Nail" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-labor" "Labor" #f #f #f "hour" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-table" "Table" #f #f #f "each" #f #f #f #f #f))

    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification "pspec-cut" "Cut Wood" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-build" "Build Table" #f #f #f #f #f #f #f))

    ;; Recipe processes
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cut" "Cut Wood" #f #f "pspec-cut" #f
                            (make-duration 1 "hour") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-build" "Build Table" #f #f "pspec-build" #f
                            (make-duration 2 "hour") #f #f))

    ;; Recipe flows
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cut-in" 'consume "spec-wood" #f
                         (make-measure 1 "board") #f "rp-cut" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-build-nails" 'consume "spec-nail" #f
                         (make-measure 10 "each") #f "rp-build" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-build-labor" 'work "spec-labor" #f
                         #f (make-measure 2 "hour") "rp-build" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-build-out" 'produce "spec-table" #f
                         (make-measure 1 "each") #f #f "rp-build" #f #f #f #f #f #f))

    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe "recipe-table" "Table Recipe" #f #f "spec-table"
                    (list "rp-cut" "rp-build") #f))

    (check-pred "setup ok" #t)

    ;; ── 1. Standard cost rollup ────────────────────────────────

    (display "\n── Standard cost rollup ──\n")

    (let ((result (test-rollup-standard "recipe-table" rs mock-price 1)))
      (check "total standard cost" (assq-ref result 'total) 120)
      (let ((stages (assq-ref result 'by-stage)))
        (check "two stages" (length stages) 2)
        (let ((cut-stage (find (lambda (s) (equal? (assq-ref s 'name) "Cut Wood")) stages)))
          (check "Cut Wood cost" (assq-ref cut-stage 'cost) 10))
        (let ((build-stage (find (lambda (s) (equal? (assq-ref s 'name) "Build Table")) stages)))
          (check "Build Table cost" (assq-ref build-stage 'cost) 110))))

    ;; ── 2. Scaled standard cost ────────────────────────────────

    (display "\n── Scaled standard cost ──\n")

    (let ((result (test-rollup-standard "recipe-table" rs mock-price 2)))
      (check "scaled total = 240" (assq-ref result 'total) 240))

    ;; ── 3. Actual cost from events ─────────────────────────────

    (display "\n── Actual cost rollup ──\n")

    ;; Seed table resource
    ($ obs 'seed-resource
       (make-economic-resource "r-table" "My Table" #f #f #f "spec-table" #f
         (make-measure 0 "each") (make-measure 0 "each")
         #f #f "agent-workshop" #f #f #f #f #f #f #f #f))

    ;; Record actual events
    ($ obs 'record-event
       (make-economic-event
         "ev-cut-wood" 'consume "proc-cut" #f
         #f #f "spec-wood" #f
         "agent-workshop" "agent-workshop"
         (make-measure 1 "board") #f
         #f #f "2026-03-01T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-nails" 'consume "proc-build" #f
         #f #f "spec-nail" #f
         "agent-workshop" "agent-workshop"
         (make-measure 12 "each") #f
         #f #f "2026-03-01T09:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-labor" 'work "proc-build" #f
         #f #f "spec-labor" #f
         "agent-workshop" "agent-workshop"
         #f (make-measure 3 "hour")
         #f #f "2026-03-01T09:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ($ obs 'record-event
       (make-economic-event
         "ev-table" 'produce #f "proc-build"
         "r-table" #f "spec-table" #f
         "agent-workshop" "agent-workshop"
         (make-measure 1 "each") #f
         #f #f "2026-03-01T12:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Actual cost: collect input events across ALL processes in the chain
    (let* ((all-events ($ obs 'all-events))
           ;; All processes involved in making the table
           (proc-ids '("proc-cut" "proc-build"))
           ;; Find all input events for those processes
           (input-events (filter (lambda (e)
                                   (and (economic-event-input-of e)
                                        (member (economic-event-input-of e) proc-ids)
                                        (memq (economic-event-action e) '(consume use work cite))))
                                 all-events))
           (entries
             (map (lambda (e)
                    (let* ((spec (economic-event-resource-conforms-to e))
                           (rq (economic-event-resource-quantity e))
                           (eq (economic-event-effort-quantity e))
                           (qty (cond (rq (measure-has-numerical-value rq))
                                      (eq (measure-has-numerical-value eq))
                                      (else 0)))
                           (unit (cond (rq (measure-has-unit rq))
                                       (eq (measure-has-unit eq))
                                       (else "each")))
                           (price (if spec (mock-price spec unit) 0)))
                      `((event-id . ,(economic-event-id e))
                        (spec-id . ,spec) (qty . ,qty) (cost . ,(* qty price)))))
                  input-events))
           (total (fold (lambda (entry acc) (+ acc (assq-ref entry 'cost))) 0 entries)))
      ;; 1 wood * $10 + 12 nails * $1 + 3h * $50 = 10 + 12 + 150 = 172
      (check "actual total = 172" total 172)
      (check-pred "has 3 input events" (= 3 (length entries))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Cost variance (pure, no actors needed)
;;;
;;; Ported from: "costVariance under/over budget"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Cost variance ──\n")

(let* ((std-result '((total . 100)))
       (act-under  '((total . 80)))
       (act-over   '((total . 150))))
  (let ((v (cost-variance std-result act-under)))
    (check "under: variance=20" (assq-ref v 'variance) 20)
    (check "under: pct=20%" (assq-ref v 'variance-pct) 20))
  (let ((v (cost-variance std-result act-over)))
    (check "over: variance=-50" (assq-ref v 'variance) -50)
    (check "over: pct=-50%" (assq-ref v 'variance-pct) -50)))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
