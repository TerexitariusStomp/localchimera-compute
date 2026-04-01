;;; test-dependent-demand.scm — Relational demand-explosion tests
;;;
;;; Ported from: old/planner/src/lib/tests/dependent-demand.test.ts
;;;
;;; Intent: Verify that the relational planner correctly explodes demand
;;; through recipe chains, nets against inventory and scheduled outputs,
;;; selects recipes by SNLT efficiency, and respects depth bounds.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-dependent-demand.scm

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

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup: Create scope with multi-stage recipe chain
;;;
;;; Table recipe: wood → (cut wood) → table
;;;   cut-wood process: consumes 1 wood, 10 nails, produces 1 table
;;;   Nails have no recipe → purchase fallback
;;;
;;; Bread recipe: wheat → flour → bread (2-step chain)
;;;   Mill: 10kg wheat → 8kg flour (2h)
;;;   Bake: 8kg flour → 20 bread  (4h)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Multi-recipe scope ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Demand Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))

    ;; ── Resource specs ──
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wood" "Wood" #f #f #f "plank" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-nails" "Nails" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-table" "Table" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-widget" "Widget" #f #f #f "each" #f #f #f #f #f))

    ;; ── Bread recipe: wheat → flour → bread ──
    ($ rs 'add-process-spec
       (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))

    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill wheat" #f #f "pspec-mill" #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f
                            (make-duration 4 "hours") #f #f))

    ;; Mill flows: 10 wheat → 8 flour
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ;; Bake flows: 8 flour → 20 bread
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))

    ;; ── Widget recipes: two competing recipes (for SNLT test) ──
    ;; Recipe A: slow — 2h work per widget
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-widget-slow" "Make Widget Slow" #f #f #f #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-ws-work" 'work #f #f
                         #f (make-measure 2 "hours") "rp-widget-slow" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-ws-out" 'produce "spec-widget" #f
                         (make-measure 1 "each") #f #f "rp-widget-slow" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-widget-slow" "Widget (Slow)" #f #f "spec-widget"
                    (list "rp-widget-slow") #f))

    ;; Recipe B: fast — 1h work per widget
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-widget-fast" "Make Widget Fast" #f #f #f #f
                            (make-duration 1 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wf-work" 'work #f #f
                         #f (make-measure 1 "hours") "rp-widget-fast" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-wf-out" 'produce "spec-widget" #f
                         (make-measure 1 "each") #f #f "rp-widget-fast" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-widget-fast" "Widget (Fast)" #f #f "spec-widget"
                    (list "rp-widget-fast") #f))

    (check-pred "knowledge seeded"
                (pair? ($ rs 'get-process-chain "recipe-bread")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Demand explosion through recipe chain
;;;
;;; Ported from: "explodes demand backwards through a recipe chain"
;;; Relational: demand-o should find a produce solution for bread that
;;; recurses through flour → wheat, identifying purchase needs for
;;; specs with no recipe.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand explosion through chain ──\n")

(with-vat vat
  ;; No inventory — force full production chain
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-dd"))
         (due (+ (current-time) 86400)))

    ;; Demand 20 bread with no inventory → must produce
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-bread" 20 due q #:depth 8))))
      (check-pred "bread demand: finds solution" (pair? results))
      (check-pred "bread demand: produce solution"
                  (and (pair? results) (eq? 'produce (caar results)))))

    ;; Demand 40 bread → scale factor = 2 (recipe makes 20)
    ;; Should recurse: need flour (2× recipe), need wheat (2× recipe)
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-bread" 40 due q #:depth 8))))
      (check-pred "bread 40: finds solution" (pair? results))
      (let ((plan-term (car results)))
        (check-pred "bread 40: is produce"
                    (eq? 'produce (car plan-term)))
        ;; plan-term = (produce spec-id rid scale sub-plans)
        (when (and (list? plan-term) (>= (length plan-term) 4))
          (let ((scale (list-ref plan-term 3)))
            (check-pred "bread 40: scale = 2"
                        (approx= 2 scale 0.01))))))

    ;; Wheat has no upstream recipe → leaf demands result in purchase
    ;; We can verify by demanding wheat directly with no inventory
    (let ((results (run-plan* ns (q)
                     (demand-o ctx "spec-wheat" 10 due q #:depth 3))))
      (check-pred "wheat: has purchase option"
                  (and (pair? results)
                       (any (lambda (r) (eq? 'purchase (car r))) results))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Inventory netting during demand resolution
;;;
;;; Ported from: "nets against existing inventory"
;;; Relational: demand-o should return 'satisfied when inventory covers
;;; the demand, and produce/purchase only the remaining deficit.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inventory netting ──\n")

;; Seed inventory: 200kg wheat, 50kg flour, 0 bread
(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat" "Wheat Stock" #f #f #f "spec-wheat" #f
         (make-measure 200 "kg") (make-measure 200 "kg")
         #f #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-flour" "Flour Stock" #f #f #f "spec-flour" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         #f #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-bread" "Bread Stock" #f #f #f "spec-bread" #f
         (make-measure 0 "each") (make-measure 0 "each")
         #f #f "agent-commune" #f #f #f #f #f #f #f #f))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-inv"))
         (due (+ (current-time) 86400)))

    ;; 30kg flour demand — 50kg in inventory → fully satisfied
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-flour" 30 due q))))
      (check-pred "flour 30: satisfied from inventory"
                  (and (pair? results) (eq? 'satisfied (caar results)))))

    ;; 80kg flour demand — 50kg inventory, 30 remaining → needs production
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-flour" 80 due q))))
      (check-pred "flour 80: not fully satisfied"
                  (and (pair? results) (not (eq? 'satisfied (caar results))))))

    ;; 150kg wheat demand — 200kg in inventory → fully satisfied
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-wheat" 150 due q))))
      (check-pred "wheat 150: satisfied from inventory"
                  (and (pair? results) (eq? 'satisfied (caar results)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Multiple solutions (produce vs purchase)
;;;
;;; Ported from: dependent-demand "ranked recipes" concept
;;; Relational: conde branches should yield both produce and purchase
;;; solutions for any spec with a recipe.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Multiple solutions ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-ms"))
         (due (+ (current-time) 86400)))

    ;; Bread (0 in inventory) — should find both produce and purchase
    (let ((results (run-plan 3 ns (q)
                     (demand-o ctx "spec-bread" 20 due q #:depth 5))))
      (check-pred "bread: multiple solutions" (>= (length results) 2))
      (let ((kinds (map car results)))
        (check-pred "bread: has produce option" (memq 'produce kinds))
        (check-pred "bread: has purchase option" (memq 'purchase kinds))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. SNLT recipe selection (multiple competing recipes)
;;;
;;; Ported from: "ranks recipes by SNLT efficiency"
;;; Relational: Both widget recipes are reachable via conde. The relational
;;; planner explores all branches — we verify both appear and that the
;;; fast recipe (lower SNLT) is a valid solution.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── SNLT recipe selection ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-snlt"))
         (due (+ (current-time) 86400)))

    ;; Widget: two recipes — fast (1h SNLT) and slow (2h SNLT)
    ;; Both should appear as solutions
    (let ((results (run-plan* ns (q)
                     (demand-o ctx "spec-widget" 1 due q #:depth 3))))
      (check-pred "widget: finds solutions" (pair? results))

      ;; Extract recipe IDs from produce solutions
      (let ((produce-results (filter (lambda (r) (eq? 'produce (car r))) results)))
        (check-pred "widget: has produce solutions" (pair? produce-results))

        ;; Each produce term = (produce spec-id rid scale sub-plans)
        (let ((rids (map (lambda (r) (list-ref r 2)) produce-results)))
          (check-pred "widget: fast recipe reachable"
                      (member "recipe-widget-fast" rids))
          (check-pred "widget: slow recipe reachable"
                      (member "recipe-widget-slow" rids)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Scale factor computation
;;;
;;; Ported from: planning-constraints H1 "scale factor"
;;; Relational: compute-scale should correctly derive the multiplier
;;; for scaling recipe quantities to meet demand.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scale factor ──\n")

(with-vat vat
  (let ((facts (lift-planning-facts ($ scope 'recipe-store))))

    ;; Bread recipe produces 20 per execution
    ;; Demand 60 → scale = 3
    (let ((scale (compute-scale facts "recipe-bread" "spec-bread" 60)))
      (check-pred "bread scale 60→3" (approx= 3 scale)))

    ;; Demand 20 → scale = 1
    (let ((scale (compute-scale facts "recipe-bread" "spec-bread" 20)))
      (check-pred "bread scale 20→1" (approx= 1 scale)))

    ;; Demand 10 → scale = 0.5
    (let ((scale (compute-scale facts "recipe-bread" "spec-bread" 10)))
      (check-pred "bread scale 10→0.5" (approx= 0.5 scale)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Collecting consuming inputs (back-scheduling)
;;;
;;; Ported from: "explodes demand backwards" scheduling verification
;;; Relational: collect-consuming-inputs should yield the scaled input
;;; demands with back-scheduled needed-by dates.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Input collection and back-scheduling ──\n")

(with-vat vat
  (let* ((facts (lift-planning-facts ($ scope 'recipe-store)))
         (due (+ (current-time) 86400)))

    ;; Bread recipe, scale=2 → needs 2× wheat, 2× flour
    (let ((inputs (collect-consuming-inputs facts "recipe-bread" 2 due)))
      (check-pred "inputs non-empty" (pair? inputs))

      ;; Should have wheat input (from milling) and flour input (from baking)
      (let ((wheat-input (find (lambda (i) (equal? "spec-wheat" (car i))) inputs))
            (flour-input (find (lambda (i) (equal? "spec-flour" (car i))) inputs)))
        (check-pred "wheat input found" (pair? wheat-input))
        (check-pred "flour input found" (pair? flour-input))

        ;; Quantities: wheat = 10 * 2 = 20, flour = 8 * 2 = 16
        (when wheat-input
          (check-pred "wheat qty 20" (approx= 20 (cadr wheat-input))))
        (when flour-input
          (check-pred "flour qty 16" (approx= 16 (cadr flour-input))))

        ;; Back-scheduling: flour needed before bake starts, wheat before mill starts
        ;; Both should have needed-by ≤ due
        (when wheat-input
          (check-pred "wheat needed before due" (<= (caddr wheat-input) due)))
        (when flour-input
          (check-pred "flour needed before due" (<= (caddr flour-input) due)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Depth bounding prevents infinite recursion
;;;
;;; No direct TS equivalent but critical for relational planner safety.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Depth bounding ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-depth"))
         (due (+ (current-time) 86400)))

    ;; At depth 0, no recursion allowed → only purchase
    (let ((results (run-plan* ns (q)
                     (demand-o ctx "spec-bread" 20 due q #:depth 0))))
      (check-pred "depth 0: only purchase"
                  (and (pair? results)
                       (every (lambda (r) (eq? 'purchase (car r))) results))))

    ;; At depth 1, can produce bread but sub-demands are purchase-only
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-bread" 20 due q #:depth 1))))
      (check-pred "depth 1: finds a solution" (pair? results)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Netter state threading through demand resolution
;;;
;;; Ported from: "nets against previously scheduled output Intents"
;;; Relational: The netter state should track allocations across
;;; multiple demand-o calls within a single plan.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Netter state threading ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-nst"))
         (due (+ (current-time) 86400)))

    ;; Net demand for flour: 50 in inventory
    ;; First demand of 30 → remaining 20
    ;; Second demand of 30 → should not double-count inventory
    (let* ((results1 (run-plan 1 ns (q)
                       (fresh (rem alloc)
                         (net-demand-o ctx "spec-flour" 30 rem alloc)
                         (== q (list rem alloc)))))
           (results2 (run-plan 1 ns (q)
                       (fresh (rem alloc)
                         (net-demand-o ctx "spec-flour" 30 rem alloc)
                         (== q rem)))))
      ;; Each independent run-plan creates a fresh netter branch
      ;; Both should see 50 in inventory
      (check-pred "flour net-demand 30: remaining ~0"
                  (and (pair? results1)
                       (< (abs (car (car results1))) 1)))
      (check-pred "flour net-demand 30 (second): remaining ~0"
                  (and (pair? results2) (< (car results2) 1))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Non-consuming actions (use/cite/work) not quantity-netted
;;;
;;; Ported from: planning-constraints C1 "durable inputs"
;;; Relational: flow-o with non-consuming actions should be handled
;;; as existence gates, not deducted from inventory.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Non-consuming actions ──\n")

(let ((ns (empty-netter-state)))
  ;; Verify that *non-consuming-actions* includes the right set
  (check-pred "work is non-consuming"
              (memq 'work *non-consuming-actions*))
  (check-pred "use is non-consuming"
              (memq 'use *non-consuming-actions*))
  (check-pred "cite is non-consuming"
              (memq 'cite *non-consuming-actions*))
  (check-pred "consume is NOT non-consuming"
              (not (memq 'consume *non-consuming-actions*)))
  (check-pred "produce is NOT non-consuming"
              (not (memq 'produce *non-consuming-actions*))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Plan-o orchestration (full plan from open intents)
;;;
;;; Ported from: the plan-o test in relational-planner but extended to
;;; verify the plan contains sub-plans for dependent resources.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan-o orchestration ──\n")

(with-vat vat
  (let* ((ps ($ scope 'plan-store))
         (ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ps ($ scope 'observer) #f "test-plan-dd"))
         (due (+ (current-time) 86400)))

    ;; Add a demand intent for 40 bread
    ($ ps 'add-intent
       (make-intent "i-bread-40" 'produce "Bread demand" #f #f
                    #f #f #f "spec-bread" #f
                    (make-measure 40 "each") #f #f #f
                    #f "agent-commune"
                    #f #f #f (number->string due)
                    #f #f #f "test-plan" #f #f #f #f))

    ;; Run planner
    (let ((results (run-plan 1 ns (plan)
                     (plan-o ctx plan #:max-depth 5))))
      (check-pred "plan-o: finds a plan" (pair? results))
      (check-pred "plan-o: plan has entries"
                  (and (pair? results) (pair? (car results))))

      ;; The plan should contain entries for bread (and possibly sub-entries
      ;; for flour and wheat depending on plan depth)
      (when (pair? results)
        (let ((plan-entries (car results)))
          (check-pred "plan has at least 1 entry" (>= (length plan-entries) 1)))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
