;;; relational-planner.scm — Tests for the relational planner
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/relational-planner.scm

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


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Core miniKanren with planning state
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Core miniKanren ──\n")

(let ((ns (empty-netter-state)))
  (check "== unifies"
         (run-plan* ns (q) (== q 42))
         '(42))
  (check "fresh"
         (run-plan* ns (q) (fresh (x) (== x 'hello) (== q x)))
         '(hello))
  (check "conde"
         (run-plan* ns (q) (conde ((== q 1)) ((== q 2)) ((== q 3))))
         '(1 2 3))
  (check "run-plan bounded"
         (run-plan 2 ns (q) (conde ((== q 'a)) ((== q 'b)) ((== q 'c))))
         '(a b))
  (check "reification"
         (run-plan* ns (q) succeed)
         '(_.0))
  (check "project single"
         (run-plan* ns (q)
           (fresh (x) (== x '(a b c)) (project (x) (== q (length x)))))
         '(3))
  (check "project multi"
         (run-plan* ns (q)
           (fresh (x y) (== x 3) (== y 4) (project (x y) (== q (+ x y)))))
         '(7))
  (check "in-list-o"
         (run-plan* ns (q) (in-list-o q '(x y z)))
         '(x y z))
  (check "in-list-o with pattern"
         (run-plan* ns (q)
           (fresh (a b)
             (in-list-o `(pair ,a ,b) '((pair 1 2) (pair 3 4)))
             (== q (list a b))))
         '((1 2) (3 4)))
  (check-pred "netter in state"
              (netter-state? (planning-state-netter
                               (empty-planning-state (empty-netter-state))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Scope setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store))
        (st ($ scope 'spatial-thing-store)))
    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))
    ;; Processes
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill wheat" #f #f "pspec-mill" #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f
                            (make-duration 4 "hours") #f #f))
    ;; Flows: wheat → flour (mill)
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ;; Flows: flour → bread (bake)
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ;; Recipe
    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))
    ;; Agent + locations
    ($ as 'add-agent (make-agent "agent-commune" 'organization "Test Commune"
                                 #f #f #f #f #f))
    ($ st 'add-location (make-spatial-thing "loc-farm" "Farm" #f 45.5 -73.5 #f #f #f))
    ($ st 'add-location (make-spatial-thing "loc-mill" "Mill" #f 45.51 -73.49 #f #f #f))
    ($ st 'add-location (make-spatial-thing "loc-bakery" "Bakery" #f 45.52 -73.48 #f #f #f))
    (check-pred "knowledge seeded"
                (pair? ($ rs 'get-process-chain "recipe-bread")))))

;; Inventory: 200kg wheat, 50kg flour, 0 bread
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat" "Wheat Stock" #f #f #f "spec-wheat" #f
         (make-measure 200 "kg") (make-measure 200 "kg")
         "loc-farm" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-flour" "Flour Stock" #f #f #f "spec-flour" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         "loc-mill" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-bread" "Bread Stock" #f #f #f "spec-bread" #f
         (make-measure 0 "each") (make-measure 0 "each")
         "loc-bakery" #f "agent-commune" #f #f #f #f #f #f #f #f))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Lifted facts
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Lifted facts ──\n")

(define test-facts
  (with-vat vat (lift-planning-facts ($ scope 'recipe-store))))

(define test-ctx
  (with-vat vat
    (make-plan-ctx test-facts
                   ($ scope 'plan-store)
                   ($ scope 'observer)
                   #f "test-rp")))

(check-pred "facts non-empty" (pair? test-facts))

(let ((ns (empty-netter-state)))
  ;; recipe-o: find recipe by output
  (check "recipe-o finds bread"
         (run-plan* ns (q)
           (fresh (rid rname)
             (recipe-o test-facts rid rname "spec-bread")
             (== q rid)))
         '("recipe-bread"))

  ;; chain-o: process chain
  (check "chain-o finds mill→bake"
         (run-plan* ns (q)
           (chain-o test-facts "recipe-bread" q))
         '(("rp-mill" "rp-bake")))

  ;; flow-o: find output flows for bread
  (check "flow-o finds bread output"
         (run-plan* ns (q)
           (fresh (pid qty unit action)
             (flow-o test-facts pid 'output "spec-bread" qty unit action)
             (== q (list pid qty))))
         '(("rp-bake" 20)))

  ;; flow-o: find all input specs for milling
  (check "flow-o finds mill inputs"
         (run-plan* ns (q)
           (fresh (qty unit action)
             (flow-o test-facts "rp-mill" 'input q qty unit action)))
         '("spec-wheat"))

  ;; Bidirectional: what spec does this flow produce?
  (check "flow-o backward: what does rp-bake produce?"
         (run-plan* ns (q)
           (fresh (qty unit action)
             (flow-o test-facts "rp-bake" 'output q qty unit action)))
         '("spec-bread")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Netter goals
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Netter goals ──\n")

(with-vat vat
  (let ((ns (empty-netter-state)))
    ;; Net 80 flour: 50 in inventory, 30 remaining
    (let ((results (run-plan 1 ns (q)
                     (fresh (rem alloc)
                       (net-demand-o test-ctx "spec-flour" 80 rem alloc)
                       (== q rem)))))
      (check-pred "net-demand-o flour: remaining ~30"
                  (and (pair? results) (< (abs (- (car results) 30)) 0.01))))

    ;; Net 150 wheat: 200 in inventory, fully satisfied
    (let ((results (run-plan 1 ns (q)
                     (fresh (rem alloc)
                       (net-demand-o test-ctx "spec-wheat" 150 rem alloc)
                       (== q rem)))))
      (check-pred "net-demand-o wheat: fully satisfied"
                  (and (pair? results) (< (car results) 1))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Demand relation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand relation ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (due (+ (current-time) 86400)))

    ;; 30 flour: satisfied from 50kg inventory
    (let ((results (run-plan 1 ns (q) (demand-o test-ctx "spec-flour" 30 due q))))
      (check-pred "flour 30: satisfied"
                  (and (pair? results) (eq? 'satisfied (caar results)))))

    ;; 80 flour: partially net 50, then produce or purchase
    (let ((results (run-plan 1 ns (q) (demand-o test-ctx "spec-flour" 80 due q))))
      (check-pred "flour 80: not just satisfied"
                  (and (pair? results) (not (eq? 'satisfied (caar results))))))

    ;; 20 bread: must produce (0 in inventory)
    (let ((results (run-plan 1 ns (q)
                     (demand-o test-ctx "spec-bread" 20 due q #:depth 5))))
      (check-pred "bread 20: finds solution" (pair? results))
      (check-pred "bread 20: produces or purchases"
                  (memq (caar results) '(produce purchase))))

    ;; Multiple solutions for bread
    (let ((results (run-plan 3 ns (q)
                     (demand-o test-ctx "spec-bread" 20 due q #:depth 5))))
      (check-pred "bread: multiple solutions" (>= (length results) 2))
      (when (>= (length results) 2)
        (let ((kinds (map car results)))
          (check-pred "bread: has produce" (memq 'produce kinds))
          (check-pred "bread: has purchase" (memq 'purchase kinds)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Plan relation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan relation ──\n")

(with-vat vat
  (let ((ps (ctx-ps test-ctx))
        (ns (empty-netter-state))
        (due (+ (current-time) 86400)))
    ;; Add demand intent
    ($ ps 'add-intent
       (make-intent "i-test-bread" 'produce "Bread demand" #f #f
                    #f #f #f "spec-bread" #f
                    (make-measure 20 "each") #f #f #f
                    #f "agent-commune"
                    #f #f #f (number->string due)
                    #f #f #f "test-plan" #f #f #f #f))
    ;; Run planner
    (let ((results (run-plan 1 ns (plan)
                     (plan-o test-ctx plan #:max-depth 5))))
      (check-pred "plan-o: finds a plan" (pair? results))
      (check-pred "plan-o: has entries" (and (pair? results) (pair? (car results)))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
