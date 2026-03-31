;;; test-dependent-supply.scm — Supply routing through recipe chains
;;;
;;; Ported from: old/planner/src/lib/tests/dependent-supply.test.ts
;;;
;;; Intent: Verify that the relational planner can route supply
;;; through recipe chains — finding what outputs are available to
;;; satisfy downstream demands, and detecting surplus.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-dependent-supply.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet kanren-planning)
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
;;; Setup: wheat → flour → bread chain
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Supply Test"))
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

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill" #f #f #f #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake" #f #f #f #f
                            (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-w" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-fo" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-fi" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bo" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))

    ;; Inventory: 500kg wheat, 100kg flour, 0 bread
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat" "Wheat" #f #f #f "spec-wheat" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-flour" "Flour" #f #f #f "spec-flour" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    (check-pred "setup ok" #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Supply netting: surplus detection
;;;
;;; Ported from: "detects surplus when supply exceeds demand"
;;; Relational: net-supply-o should detect when available supply
;;; exceeds consumption claims.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Supply netting: surplus ──\n")

(with-vat vat
  (let ((ns (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Net supply of 500 wheat — no consumption scheduled → remaining 500
    (let-values (((ns1 remaining)
                  (netter-net-supply ns ps "spec-wheat" 500)))
      (check-pred "wheat 500: all remaining (no consumption)"
                  (approx= 500 remaining 1)))

    ;; Add consumption intent for 100 wheat
    ($ ps 'add-intent
       (make-intent "i-wheat-consume" 'consume "Wheat use" #f #f
                    "proc-mill" #f #f "spec-wheat" #f
                    (make-measure 100 "kg") #f #f #f
                    #f "agent-a" #f #f #f #f
                    #f #f #f #f #f #f #f #f))

    ;; Now net supply: 500 wheat - 100 consumed = 400 remaining (surplus)
    (let-values (((ns2 remaining)
                  (netter-net-supply (empty-netter-state) ps "spec-wheat" 500)))
      (check-pred "wheat 500 - 100 consumed: 400 remaining"
                  (approx= 400 remaining 1)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Relational: what can a recipe produce?
;;;
;;; Ported from: "routes supply through recipe chain"
;;; Relational query: given a recipe, what specs does it output?
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Recipe output discovery ──\n")

(with-vat vat
  (let* ((facts (lift-planning-facts ($ scope 'recipe-store)))
         (ns (empty-netter-state)))

    ;; What does recipe-bread produce?
    (let ((outputs (run-plan* ns (q)
                     (fresh (rid rname)
                       (recipe-o facts rid rname q)
                       (== rid "recipe-bread")))))
      (check "recipe-bread output" (car outputs) "spec-bread"))

    ;; What recipes can produce flour? (reverse query)
    ;; flour is an intermediate product from milling
    (let ((flour-producers (run-plan* ns (q)
                             (fresh (pid qty unit action)
                               (flow-o facts pid 'output "spec-flour" qty unit action)
                               (== q pid)))))
      (check-pred "flour producer = rp-mill" (member "rp-mill" flour-producers)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Supply chain tracing (backward from output)
;;;
;;; Ported from: supply chain analysis
;;; Relational: trace what inputs are needed to produce bread
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Supply chain tracing ──\n")

(with-vat vat
  (let* ((facts (lift-planning-facts ($ scope 'recipe-store)))
         (ns (empty-netter-state)))

    ;; Trace: bread ← flour ← wheat
    ;; What does baking consume?
    (let ((bake-inputs (run-plan* ns (q)
                         (fresh (qty unit action)
                           (flow-o facts "rp-bake" 'input q qty unit action)))))
      (check-pred "bake needs flour" (member "spec-flour" bake-inputs)))

    ;; What does milling consume?
    (let ((mill-inputs (run-plan* ns (q)
                         (fresh (qty unit action)
                           (flow-o facts "rp-mill" 'input q qty unit action)))))
      (check-pred "mill needs wheat" (member "spec-wheat" mill-inputs)))

    ;; Full chain: bread → flour → wheat (2 hops)
    ;; Find all specs needed to produce bread (transitively)
    (let ((bread-deps (run-plan* ns (q)
                        (fresh (pid qty unit action)
                          (flow-o facts pid 'input q qty unit 'consume)))))
      (check-pred "bread chain includes wheat" (member "spec-wheat" bread-deps))
      (check-pred "bread chain includes flour" (member "spec-flour" bread-deps)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Available supply computation
;;;
;;; Ported from: "netAvailableQty" supply-side
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Available supply ──\n")

(with-vat vat
  (let ((ns (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Wheat: 500 in inventory, 100 scheduled consumption
    ;; Available = 500 + scheduled_outputs - scheduled_consumptions
    (let-values (((ns1 available)
                  (netter-net-available ns ps obs "spec-wheat")))
      (check-pred "wheat available >= 400" (>= available 400)))

    ;; Flour: 100 in inventory
    (let-values (((ns1 available)
                  (netter-net-available ns ps obs "spec-flour")))
      (check-pred "flour available >= 100" (>= available 100)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Demand-supply matching via plan-o
;;;
;;; Ported from: full demand→supply resolution
;;; Relational: plan-o should find a feasible plan that matches
;;; demand with available supply.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand-supply matching ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ps ($ scope 'plan-store))
         (ctx (make-plan-ctx facts ps ($ scope 'observer) #f "test-ds"))
         (due (+ (current-time) 86400)))

    ;; Add bread demand
    ($ ps 'add-intent
       (make-intent "i-bread-ds" 'produce "Bread demand" #f #f
                    #f #f #f "spec-bread" #f
                    (make-measure 20 "each") #f #f #f
                    #f "agent-a" #f #f #f (number->string due)
                    #f #f #f #f #f #f #f #f))

    ;; Plan-o should find a plan
    (let ((results (run-plan 1 ns (plan) (plan-o ctx plan #:max-depth 5))))
      (check-pred "plan found" (pair? results))
      (check-pred "plan has entries" (and (pair? results) (pair? (car results)))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
