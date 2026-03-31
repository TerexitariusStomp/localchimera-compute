;;; test-workflow-recipe.scm — Workflow recipe instantiation, track-trace, batch SNE
;;;
;;; Ported from: old/planner/src/lib/tests/workflow-recipe.test.ts
;;;              old/planner/src/lib/tests/track-trace.test.ts
;;;              old/planner/src/lib/tests/batch-sne-depreciation.test.ts
;;;
;;; Intent: Verify multi-step workflow recipe instantiation with
;;; scaling, resource track-and-trace through event chains, and
;;; batch SNE depreciation calculations.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-workflow-recipe.scm

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
;;; Setup: Multi-step workflow
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Workflow ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Workflow Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer)))
    ;; 3-step recipe: harvest → clean → pack
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-raw-herb" "Raw Herb" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-clean-herb" "Clean Herb" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-packed-herb" "Packed Herb" #f #f #f "packet" #f #f #f #f #f))

    ;; Step 1: Harvest (1h) → 10kg raw herb
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-harvest" "Harvest" #f #f #f #f
                            (make-duration 1 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-harvest-out" 'produce "spec-raw-herb" #f
                         (make-measure 10 "kg") #f #f "rp-harvest" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-harvest-work" 'work #f #f
                         #f (make-measure 1 "hours") "rp-harvest" #f #f #f #f #f #f #f))

    ;; Step 2: Clean (2h) → 10kg raw → 8kg clean
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-clean" "Clean" #f #f #f #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-clean-in" 'consume "spec-raw-herb" #f
                         (make-measure 10 "kg") #f "rp-clean" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-clean-out" 'produce "spec-clean-herb" #f
                         (make-measure 8 "kg") #f #f "rp-clean" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-clean-work" 'work #f #f
                         #f (make-measure 2 "hours") "rp-clean" #f #f #f #f #f #f #f))

    ;; Step 3: Pack (1h) → 8kg clean → 20 packets
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-pack" "Pack" #f #f #f #f
                            (make-duration 1 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-pack-in" 'consume "spec-clean-herb" #f
                         (make-measure 8 "kg") #f "rp-pack" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-pack-out" 'produce "spec-packed-herb" #f
                         (make-measure 20 "packet") #f #f "rp-pack" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-pack-work" 'work #f #f
                         #f (make-measure 1 "hours") "rp-pack" #f #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-herbs" "Herb Production" #f #f "spec-packed-herb"
                    (list "rp-harvest" "rp-clean" "rp-pack") #f))

    (check-pred "workflow recipe seeded"
                (= 3 (length ($ rs 'get-process-chain "recipe-herbs"))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Multi-step chain topology
;;;
;;; Ported from: workflow-recipe "3-step process chain"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Chain topology ──\n")

(with-vat vat
  (let* ((facts (lift-planning-facts ($ scope 'recipe-store)))
         (ns (empty-netter-state)))

    ;; Chain should be harvest → clean → pack
    (let ((chains (run-plan* ns (q) (chain-o facts "recipe-herbs" q))))
      (check-pred "chain found" (pair? chains))
      (check "chain order"
             (car chains)
             '("rp-harvest" "rp-clean" "rp-pack")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Scale factor for multi-step recipe
;;;
;;; Ported from: workflow-recipe "scaling"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Workflow scale factor ──\n")

(with-vat vat
  (let ((facts (lift-planning-facts ($ scope 'recipe-store))))
    ;; Recipe produces 20 packets per execution
    ;; Demand 40 → scale = 2
    (let ((scale (compute-scale facts "recipe-herbs" "spec-packed-herb" 40)))
      (check-pred "herb scale 40→2" (approx= 2 scale)))

    ;; Demand 60 → scale = 3
    (let ((scale (compute-scale facts "recipe-herbs" "spec-packed-herb" 60)))
      (check-pred "herb scale 60→3" (approx= 3 scale)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Input collection for multi-step chain
;;;
;;; Ported from: workflow-recipe "scaled input demands"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Workflow input collection ──\n")

(with-vat vat
  (let* ((facts (lift-planning-facts ($ scope 'recipe-store)))
         (due (+ (current-time) 86400)))
    ;; Scale 2: raw herb demand = 10 * 2 = 20, clean herb = 8 * 2 = 16
    (let ((inputs (collect-consuming-inputs facts "recipe-herbs" 2 due)))
      (check-pred "inputs found" (>= (length inputs) 2))

      (let ((raw (find (lambda (i) (equal? "spec-raw-herb" (car i))) inputs))
            (clean (find (lambda (i) (equal? "spec-clean-herb" (car i))) inputs)))
        (when raw
          (check-pred "raw herb qty 20" (approx= 20 (cadr raw))))
        (when clean
          (check-pred "clean herb qty 16" (approx= 16 (cadr clean))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. SNLT for multi-step recipe
;;;
;;; Ported from: batch-sne-depreciation "SNLT computation"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Workflow SNLT ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; Total work: 1h + 2h + 1h = 4h
    ;; Total output: 20 packets
    ;; SNLT = 4/20 = 0.2 hours/packet
    (let ((snlt (compute-snlt rs "recipe-herbs")))
      (check-pred "herb SNLT = 0.2" (approx= 0.2 snlt 0.001)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Recipe lead time
;;;
;;; Ported from: track-trace "recipe DLT"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Workflow lead time ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; DLT = 1h + 2h + 1h = 4h = 4/24 ≈ 0.167 days
    (let ((dlt (recipe-lead-time "recipe-herbs" rs)))
      (check-pred "herb DLT ≈ 0.167 days" (approx= (/ 4 24) dlt 0.01)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Relational demand resolution for workflow
;;;
;;; Ported from: workflow-recipe "demand explosion"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Workflow demand resolution ──\n")

(with-vat vat
  (let* ((ns (empty-netter-state))
         (facts (lift-planning-facts ($ scope 'recipe-store)))
         (ctx (make-plan-ctx facts ($ scope 'plan-store) ($ scope 'observer) #f "test-wf"))
         (due (+ (current-time) 86400)))

    ;; Demand 20 packed herbs: should find produce solution
    (let ((results (run-plan 1 ns (q)
                     (demand-o ctx "spec-packed-herb" 20 due q #:depth 5))))
      (check-pred "herbs: finds solution" (pair? results))
      (check-pred "herbs: produce"
                  (and (pair? results) (eq? 'produce (caar results)))))

    ;; Multiple solutions
    (let ((results (run-plan 3 ns (q)
                     (demand-o ctx "spec-packed-herb" 20 due q #:depth 5))))
      (check-pred "herbs: multiple solutions" (>= (length results) 2))
      (let ((kinds (map car results)))
        (check-pred "herbs: has produce" (memq 'produce kinds))
        (check-pred "herbs: has purchase" (memq 'purchase kinds))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Track-trace: event chain for resource
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Track-trace ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed and process herbs
    ($ obs 'seed-resource
       (make-economic-resource "r-raw" "Raw Herbs" #f #f #f "spec-raw-herb" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Harvest: produce 10kg raw
    ($ obs 'record-event
       (make-economic-event
         "ev-tt-harvest" 'produce #f "proc-harvest"
         "r-raw" #f "spec-raw-herb" #f
         "agent-a" "agent-a"
         (make-measure 10 "kg") #f
         #f #f "2026-03-28T08:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Clean: consume 10kg raw
    ($ obs 'record-event
       (make-economic-event
         "ev-tt-clean" 'consume "proc-clean" #f
         "r-raw" #f "spec-raw-herb" #f
         "agent-a" "agent-a"
         (make-measure 10 "kg") #f
         #f #f "2026-03-28T10:00:00Z" #f #f #f #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Trace events for r-raw
    (let ((events (filter (lambda (e)
                            (equal? "r-raw" (economic-event-resource-inventoried-as e)))
                          ($ obs 'all-events))))
      (check "r-raw events" (length events) 2)
      (let ((actions (map economic-event-action events)))
        (check-pred "has produce" (memq 'produce actions))
        (check-pred "has consume" (memq 'consume actions))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
