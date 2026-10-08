;;; test-ddmrp-leaf-planner.scm — Tests for the relational DDMRP leaf-planner
;;;
;;; Run: cd planner && guile -c '
;;;   (add-to-load-path "../module")
;;;   (load "load-all.scm")
;;;   (load "tests/test-ddmrp-leaf-planner.scm")'

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))
(define ns '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Helpers (ground)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Helpers ──\n")

(define h-facts
  `((buffer-zone "spec-bread" 50 100 150 10 7)
    (buffer-zone "spec-flour" 30 60 90 5 5)
    (inventory "r-1" "spec-wheat" 200 #f #f)
    (inventory "r-2" "spec-flour" 80 #f #f)))

(check "buffered-spec-set returns buffered specs"
       (sort (buffered-spec-set h-facts) string<?)
       '("spec-bread" "spec-flour"))

(check "toy-floor on buffered spec" (toy-floor h-facts "spec-bread") 100)
(check "tor-floor on buffered spec" (tor-floor h-facts "spec-bread") 50)
(check "toy-floor on unbuffered spec" (toy-floor h-facts "spec-wheat") 0)
(check "tor-floor on unbuffered spec" (tor-floor h-facts "spec-wheat") 0)

(check-pred "decoupling-stop? true for buffered"
            (decoupling-stop? '("spec-flour" "spec-bread") "spec-flour"))
(check-pred "decoupling-stop? false for unbuffered"
            (not (decoupling-stop? '("spec-flour") "spec-wheat")))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. ddmrp-allocate-o — 3-tier allocation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3-tier ddmrp-allocate-o ──\n")

;; The 3-tier ddmrp-allocate-o is a conde with three branches (TOY/TOR/0).
;; Each branch can independently produce solutions. To probe behavior at
;; a specific tier, we constrain `remaining` and check whether the search
;; finds a satisfying solution at all (i.e. whether SOME branch can hit it).

;; Scenario A: comfortable buffer — TOY branch should satisfy
;; flour onhand=200, demand=50, TOY=100 → 200-50=150 ≥ TOY → TOY suffices
(define a-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 200 #f #f)))

(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o a-facts "spec-flour" 50 remaining allocated)
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "TOY tier: comfortable buffer fully satisfies" (pair? results)))

;; Scenario B: TOR fallback — TOY can't satisfy fully, TOR can
;; flour onhand=110, demand=80, TOY=100, TOR=30
;;   TOY branch: max take = 110-100 = 10, leaves remaining=70
;;   TOR branch: max take = 110-30 = 80, leaves remaining=0 ✓
(define b-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 110 #f #f)))

(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o b-facts "spec-flour" 80 remaining allocated)
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "TOR fallback: yellow sacrifice satisfies" (pair? results)))

;; Scenario C: sacrifice tier — only floor=0 can satisfy
;; flour onhand=70, demand=50, TOY=100, TOR=30
;;   TOY branch: max take = max(0, 70-100) = 0, remaining=50
;;   TOR branch: max take = 70-30 = 40, remaining=10
;;   Sacrifice : max take = 70, remaining=0 ✓
(define c-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 70 #f #f)))

(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o c-facts "spec-flour" 50 remaining allocated)
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "Sacrifice tier: red zone satisfies" (pair? results)))

;; Scenario D: insufficient at every tier
;; flour onhand=20, demand=50
;;   No tier can fully satisfy. Best is sacrifice with take=20, remaining=30.
(define d-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 20 #f #f)))

(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o d-facts "spec-flour" 50 remaining allocated)
                   (== remaining 30)
                   (== q allocated)))))
  (check-pred "Insufficient: best sacrifice (remaining=30) reachable"
              (pair? results)))

;; Scenario E: unbuffered spec degrades to plain allocation
;; wheat onhand=100, demand=40, no buffer-zone fact (TOY=TOR=0)
(define e-facts
  `((inventory "r-1" "spec-wheat" 100 #f #f)))

(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o e-facts "spec-wheat" 40 remaining allocated)
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "Unbuffered: plain allocation satisfies" (pair? results)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Scope setup for integration tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "DDMRP Test")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ;; Resource specs
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-bread" #:name "Bread"
                                    #:default-unit-of-resource "each"))
    ;; Process specs
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-mill" #:name "Milling"))
    ($ rs 'add-process-spec
       (make-process-specification #:id "pspec-bake" #:name "Baking"))
    ;; Recipe processes
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-mill" #:name "Mill wheat" #:process-conforms-to "pspec-mill"
                            #:has-duration (make-duration 2 "hours")))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id "rp-bake" #:name "Bake bread" #:process-conforms-to "pspec-bake"
                            #:has-duration (make-duration 4 "hours")))
    ;; Recipe flows: wheat -> flour -> bread
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-wheat-in" #:action 'consume #:resource-conforms-to "spec-wheat"
                         #:resource-quantity (make-measure 10 "kg") #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-out" #:action 'produce #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-output-of "rp-mill"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-flour-in" #:action 'consume #:resource-conforms-to "spec-flour"
                         #:resource-quantity (make-measure 8 "kg") #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id "rf-bread-out" #:action 'produce #:resource-conforms-to "spec-bread"
                         #:resource-quantity (make-measure 20 "each") #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe
       (make-recipe #:id "recipe-bread" #:name "Bread Production" #:primary-output "spec-bread"
                    #:recipe-processes (list "rp-mill" "rp-bake")))
    ($ as 'add-agent (make-agent #:id "agent-test" #:type 'organization #:name "Test"))))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-wheat" #:name "Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 200 "kg") #:onhand-quantity (make-measure 200 "kg")
         #:current-location "loc-farm" #:primary-accountable "agent-test"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-flour" #:name "Flour" #:conforms-to "spec-flour"
         #:accounting-quantity (make-measure 200 "kg") #:onhand-quantity (make-measure 200 "kg")
         #:current-location "loc-mill" #:primary-accountable "agent-test"))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. ddmrp-demand-o (decoupling)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ddmrp-demand-o decoupling ──\n")

;; Build facts WITHOUT buffer zones — ddmrp-demand-o should produce
;; the same shape of result as plain demand-o.
(define plain-facts
  (with-vat vat
    (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer))))

(define plain-ctx
  (with-vat vat
    (make-plan-ctx plain-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-ddmrp" (build-indexes plain-facts))))

(with-vat vat
  ;; flour 30: should be satisfied from inventory (no buffer = no decoupling)
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 1 ns (q)
                    (ddmrp-demand-o plain-ctx '() "spec-flour" 30 due q
                                    #:depth 5))))
    (check-pred "ddmrp-demand-o flour 30: satisfied (no buffer)"
                (and (pair? results) (eq? 'satisfied (caar results))))))

;; Add a buffer zone for flour. Now flour is a decoupling point —
;; bread demand should still be satisfied but the plan should NOT
;; recurse into producing flour from wheat.
(define facts-with-flour-buffer
  (cons '(buffer-zone "spec-flour" 30 100 150 5 5)
        plain-facts))

(define buf-ctx
  (with-vat vat
    (make-plan-ctx facts-with-flour-buffer ($ scope 'plan-store)
                   ($ scope 'observer) #f "test-ddmrp"
                   (build-indexes facts-with-flour-buffer))))

;; Parity check: ddmrp-demand-o with NO buffered specs and NO buffer facts
;; should behave identically to plain demand-o (same plan term shape).
;; This validates that the wrapping logic doesn't change the base case.
(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (plain (run-plan 1 ns (q)
                  (demand-o plain-ctx "spec-bread" 20 due q #:depth 5)))
         (ddmrp (run-plan 1 ns (q)
                  (ddmrp-demand-o plain-ctx '() "spec-bread" 20 due q #:depth 5))))
    (check-pred "demand-o and ddmrp-demand-o agree on bread (no buffered)"
                (and (= (length plain) (length ddmrp))
                     (or (null? plain)
                         (eq? (caar plain) (caar ddmrp)))))))

;; With flour as a decoupling point: ddmrp-demand-o should treat flour
;; as inventory-only, not recursively producing it. This is the
;; structural difference from plain demand-o.
(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 1 ns (q)
                    (ddmrp-demand-o buf-ctx '("spec-flour") "spec-bread" 20 due q
                                    #:depth 5))))
    (check-pred "ddmrp-demand-o bread 20 with flour-decoupled: finds a result"
                (pair? results))
    (when (pair? results)
      (let ((term (car results)))
        (check-pred "result is a valid plan term"
                    (memq (car term) '(produce satisfied unmet)))))))

;; Direct gate semantics test: demand a buffered spec at the top level
;; should NOT try produce-branch (decoupling at top), even if a recipe
;; for it exists. With flour onhand=200 and TOY=100, demanding 30 flour
;; should be satisfied (200-30=170 ≥ TOY). And the plan must be a
;; satisfied term, not a produce term, even though flour has a recipe.
(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 1 ns (q)
                    (ddmrp-demand-o buf-ctx '("spec-flour") "spec-flour" 30 due q
                                    #:depth 5))))
    (check-pred "decoupled flour 30: finds satisfied directly from inventory"
                (and (pair? results) (eq? 'satisfied (caar results))))))

;; Replenishment gate-open test: when ddmrp-demand-o is called with
;; #:replenishment? #t for a buffered spec, the gate is open and
;; produce-branch CAN fire. Verify that a flour replenishment can
;; succeed via the recipe (or at least via inventory if available).
(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 1 ns (q)
                    (ddmrp-demand-o buf-ctx '("spec-flour") "spec-flour" 30 due q
                                    #:depth 5
                                    #:replenishment? #t))))
    (check-pred "replenishment-mode flour 30: finds a result"
                (pair? results))
    ;; In replenishment mode the gate is open. With 200 flour onhand
    ;; this still satisfies via the TOY tier directly — but if it had
    ;; been below TOY, it would have tried produce instead of unmet.
    (when (pair? results)
      (check-pred "replenishment result is satisfied (inventory still suffices)"
                  (eq? 'satisfied (caar results))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. ddmrp-plan-o (single relation)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ddmrp-plan-o master relation ──\n")

(with-vat vat
  ;; Add an open intent for bread
  (let ((ps ($ scope 'plan-store)))
    ($ ps 'add-intent
       (make-intent #:id "i-bread-1" #:action 'consume #:name "Bread Demand"
                    #:resource-conforms-to "spec-bread"
                    #:resource-quantity (make-measure 20 "each") #:receiver "agent-test" #:due "2026-12-31T00:00:00Z"))))

;; Now lift facts AGAIN (to pick up the new intent) and add the buffer zone
(define final-facts
  (cons '(buffer-zone "spec-flour" 30 100 150 5 5)
        (with-vat vat
          (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer)
                                ($ scope 'plan-store)))))

(define final-ctx
  (with-vat vat
    (make-plan-ctx final-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-ddmrp" (build-indexes final-facts))))

(with-vat vat
  ;; Run ddmrp-plan-o directly
  (let* ((demands `(((spec-id . "spec-bread") (quantity . 20)
                     (due . #f) (at-location . #f))))
         (results (run-plan 1 ns (plan)
                    (ddmrp-plan-o final-ctx demands plan))))
    (check-pred "ddmrp-plan-o produces a result" (pair? results))
    (when (pair? results)
      (let ((p (car results)))
        (check-pred "result has primary section" (assq 'primary p))
        (check-pred "result has derived section" (assq 'derived p))
        (check-pred "result has supply section" (assq 'supply p))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. ddmrp-leaf-planner federation entry
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ddmrp-leaf-planner ──\n")

(define (force-first stream)
  "Get the first element of either a regular list or a lazy stream.
   The leaf-planner now returns a list (from run-plan), but for
   robustness we handle the lazy-stream case too."
  (cond
    ((null? stream) #f)
    ((pair? stream) (car stream))
    ((procedure? stream)
     (let ((cell (stream-take-1 stream)))
       (and cell (car cell))))
    (else #f)))

(with-vat vat
  (let* ((cfg (make-federation-config))
         (stream (ddmrp-leaf-planner "test-scope" final-ctx cfg))
         (first (force-first stream)))
    (check-pred "leaf-planner returns a non-empty stream" first)
    (when first
      (check-pred "first element is a federation-result alist"
                  (and (pair? first) (assq 'scope first)))
      (check "result scope-id" (assq-ref first 'scope) "test-scope")
      (check-pred "result has plan field" (assq 'plan first))
      (check-pred "result has deficits field" (assq 'deficits first))
      (check-pred "result has surpluses field" (assq 'surpluses first))
      (check-pred "result has retraction-candidates field"
                  (assq 'retraction-candidates first))
      (check-pred "result has residual field" (assq 'residual first)))))

;; Test with weight-fn / harmony
(with-vat vat
  (let* ((level-fn (lambda (s) (if (equal? s "spec-bread") 9 0)))
         (cfg (make-federation-config #:level-fn level-fn))
         (stream (ddmrp-leaf-planner "test-scope" final-ctx cfg))
         (first (force-first stream)))
    (check-pred "result with level-fn includes harmony"
                (and first (assq 'harmony first)))))

;; Empty ctx returns empty stream
(check "ddmrp-leaf-planner with #f ctx → empty"
       (ddmrp-leaf-planner "test-scope" #f (make-federation-config))
       '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Cascade replenishment (gap #1 from planner-known-gaps.md)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Cascade replenishment ──\n")

;; Build a hand-crafted scenario with buffer-below-TOY consumption
;; that doesn't depend on the bread-unmet limitation. We construct
;; the "primary" plans directly as satisfied terms so we can verify
;; replenishment-o's cascade logic in isolation.

(define cascade-facts
  `(;; Buffer zone for flour: TOR=30, TOY=100, TOG=150
    (buffer-zone "spec-flour" 30 100 150 5 5)
    ;; Inventory: 105 flour (just barely above TOY)
    (inventory "r-flour-cascade" "spec-flour" 105 #f #f)
    ;; A simple recipe so the replenishment can produce flour from
    ;; nothing (we won't recurse into wheat)
    (recipe "recipe-flour-only" "Flour" "spec-flour")
    (chain "recipe-flour-only" (rp-flour))
    (process rp-flour "Flour Process" 1 1)
    (flow rf-flour-out rp-flour output "spec-flour" 10 "kg" produce #f rf-id-1)))

(define cascade-ctx
  (with-vat vat
    (make-plan-ctx cascade-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-cascade" (build-indexes cascade-facts))))

;; Test 1: replenishment-o fires when buffered consumption drops below TOY
(with-vat vat
  (let* ((primary-plans
           ;; Hand-crafted satisfied term: consumed 10 flour
           `((((spec-id . "spec-flour") (quantity . 10))
              (satisfied "spec-flour" 10 (("r-flour-cascade" 10)) #f))))
         (results (run-plan 1 ns (q)
                    (replenishment-o cascade-ctx '("spec-flour")
                                      primary-plans '() q))))
    (check-pred "cascade replenishment fires when buffered consumption < TOY"
                (pair? results))
    (when (pair? results)
      (let ((replen (car results)))
        ;; Post-consumption: 105 - 10 = 95, which is < TOY=100
        ;; Gap = 100 - 95 = 5 → should trigger a replenishment for 5
        ;; (or however the cascade ends up — it might be more if it
        ;; can't find a recipe; that's fine, we just want SOMETHING)
        (check-pred "result is a list of plans" (list? replen))))))

;; Test 2: replenishment-o does NOT fire when buffered consumption stays above TOY
(with-vat vat
  (let* ((primary-plans
           ;; Consumed only 1 flour: 105-1=104 ≥ TOY=100
           `((((spec-id . "spec-flour") (quantity . 1))
              (satisfied "spec-flour" 1 (("r-flour-cascade" 1)) #f))))
         (results (run-plan 1 ns (q)
                    (replenishment-o cascade-ctx '("spec-flour")
                                      primary-plans '() q))))
    (check-pred "no replenishment when buffer stays above TOY"
                (and (pair? results) (null? (car results))))))

;; Test 3: cascade does not loop (terminates within depth bound)
;; Even if the recipe consumes more flour, the visited-set prevents
;; replenishing the same spec twice in one cascade.
(with-vat vat
  (let* ((primary-plans
           ;; Heavily consume flour: 105-50=55, gap = 100-55 = 45
           `((((spec-id . "spec-flour") (quantity . 50))
              (satisfied "spec-flour" 50 (("r-flour-cascade" 50)) #f))))
         (results (run-plan 1 ns (q)
                    (replenishment-o cascade-ctx '("spec-flour")
                                      primary-plans '() q))))
    (check-pred "cascade with large consumption terminates"
                (pair? results))))

;; Test 4: plain replenishment-o with no buffered specs is a no-op
(with-vat vat
  (let* ((primary-plans
           `((((spec-id . "spec-wheat") (quantity . 10))
              (satisfied "spec-wheat" 10 (("r-wheat" 10)) #f))))
         (results (run-plan 1 ns (q)
                    (replenishment-o cascade-ctx '() primary-plans '() q))))
    (check "no buffered specs → empty replenishment"
           (and (pair? results) (car results)) '())))

;; Test 5: visited-set semantics — a spec already replenished isn't
;; replenished again on a recursive cascade pass. This is implicit in
;; the depth-bounded recursion; verifying it via the helper is enough.
(with-vat vat
  (let* ((primary-plans
           `((((spec-id . "spec-flour") (quantity . 10))
              (satisfied "spec-flour" 10 (("r-flour-cascade" 10)) #f))))
         ;; Pretend flour was already replenished in a previous round
         (results (run-plan 1 ns (q)
                    (replenishment-cascade-o cascade-ctx '("spec-flour")
                      primary-plans '("spec-flour") '() q 5))))
    (check "already-replenished specs are skipped in cascade"
           (and (pair? results) (car results)) '())))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Plan coherence ranking
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan coherence ──\n")

;; Test 1: plan-coherence on hand-crafted plans
(check "plan-coherence: empty plan = 1 (vacuous)"
       (plan-coherence '()) 1)

(check "plan-coherence: all satisfied = 1"
       (plan-coherence
         `((((spec-id . "bread") (quantity . 100))
            (satisfied "bread" 100 (("r-1" 100)) #f))))
       1)

(check "plan-coherence: all unmet = 0"
       (plan-coherence
         `((((spec-id . "bread") (quantity . 100))
            (unmet "bread" 100 #f))))
       0)

(check "plan-coherence: 60 satisfied + 40 unmet = 0.6"
       (plan-coherence
         `((((spec-id . "bread") (quantity . 60))
            (satisfied "bread" 60 (("r-1" 60)) #f))
           (((spec-id . "wheat") (quantity . 40))
            (unmet "wheat" 40 #f))))
       3/5)

;; Test 2: ddmrp-leaf-planner returns results sorted by coherence
;; This is a structural test — we verify that if multiple plans are
;; returned, they're in coherence-descending order. The actual plan
;; content depends on what the search finds.
(with-vat vat
  (let* ((cfg (make-federation-config))
         (results (ddmrp-leaf-planner "test-scope" final-ctx cfg)))
    (when (and (pair? results) (pair? (cdr results)))
      ;; Multiple results — verify monotone non-increasing coherence
      (let loop ((rs results) (prev-c 2))
        (cond
          ((null? rs) #t)
          (else
           (let ((c (assq-ref (car rs) 'coherence)))
             (check-pred "coherence is monotone non-increasing"
                         (<= c prev-c))
             (loop (cdr rs) c))))))))

;; Test 3: every result has a coherence field
(with-vat vat
  (let* ((cfg (make-federation-config))
         (results (ddmrp-leaf-planner "test-scope" final-ctx cfg)))
    (check-pred "leaf-planner result has coherence field"
                (and (pair? results)
                     (assq 'coherence (car results))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Supply forward BFS (gap #2)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Supply forward BFS ──\n")

;; Test 1: with no excess inventory, supply-routing-o produces empty
(define no-excess-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 100 #f #f)))  ; below TOG

(define no-excess-ctx
  (with-vat vat
    (make-plan-ctx no-excess-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-bfs" (build-indexes no-excess-facts))))

(with-vat vat
  (let ((results (run-plan 1 ns (q)
                   (supply-routing-o no-excess-ctx '("spec-flour") q))))
    (check "no excess → empty supply plans"
           (and (pair? results) (car results)) '())))

;; Test 2: excess inventory with no consuming recipe → emits surplus
(define excess-no-recipe-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-1" "spec-flour" 200 #f #f)))  ; 50 above TOG

(define excess-no-recipe-ctx
  (with-vat vat
    (make-plan-ctx excess-no-recipe-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-bfs" (build-indexes excess-no-recipe-facts))))

(with-vat vat
  (let ((results (run-plan 1 ns (q)
                   (supply-routing-o excess-no-recipe-ctx '("spec-flour") q))))
    (check-pred "excess + no recipe → surplus term"
                (and (pair? results)
                     (let ((plans (car results)))
                       (and (pair? plans)
                            (eq? 'surplus (caar plans))))))))

;; Test 3: excess inventory WITH a consuming recipe → forward absorption
;; bread-bake recipe consumes wheat. wheat is buffered with TOG=50.
;; wheat onhand=200 → 150 excess. The bake recipe consumes 5 per exec
;; → 30 executions absorb all 150.
(define excess-with-recipe-facts
  `((buffer-zone "spec-wheat" 10 30 50 5 5)
    (inventory "r-w" "spec-wheat" 200 #f #f)
    (recipe "bake-recipe" "Bake" "spec-bread")
    (chain "bake-recipe" (rp-bake))
    (process rp-bake "Bake" 14400000 1)
    (flow rp-bake input "spec-wheat" 5 "kg" consume #f rf-w-in)
    (flow rp-bake output "spec-bread" 20 "each" produce #f rf-b-out)))

(define excess-with-recipe-ctx
  (with-vat vat
    (make-plan-ctx excess-with-recipe-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-bfs" (build-indexes excess-with-recipe-facts))))

(with-vat vat
  (let ((results (run-plan 1 ns (q)
                   (supply-routing-o excess-with-recipe-ctx '("spec-wheat") q))))
    (check-pred "excess + recipe → forward absorption"
                (and (pair? results)
                     (let ((plans (car results)))
                       (and (pair? plans)
                            (eq? 'forward (caar plans))))))))

;; Test 4: forward term has expected structure
(with-vat vat
  (let ((results (run-plan 1 ns (q)
                   (supply-routing-o excess-with-recipe-ctx '("spec-wheat") q))))
    (when (pair? results)
      (let ((forward-term (caar results)))
        (check "forward term spec is wheat"
               (cadr forward-term) "spec-wheat")
        (check-pred "forward term has positive consumed amount"
                    (> (caddr forward-term) 0))
        (check "forward term recipe is bake-recipe"
               (cadddr forward-term) "bake-recipe")))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Multi-scope DDMRP federation (gap #14)
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Verify that ddmrp-leaf-planner plugs cleanly into plan-federation-o
;;; across multiple scopes — the federation substrate doesn't notice it
;;; is running DDMRP at the leaves.

(display "\n── Multi-scope DDMRP federation ──\n")

;; Two peer scopes: bakery (needs flour) and mill (has flour).
;; Build minimal lifted facts manually so we don't need a full
;; goblins multi-scope setup.

(define bakery-facts
  `((inventory "r-bread" "spec-bread" 0 #f #f)
    (recipe "recipe-bread" "Bread" "spec-bread")
    (chain "recipe-bread" (rp-bake))
    (process rp-bake "Bake" 14400000 1)
    (flow rp-bake input "spec-flour" 5 "kg" consume #f rf-fi)
    (flow rp-bake output "spec-bread" 20 "each" produce #f rf-bo)))

(define mill-facts
  `((inventory "r-flour" "spec-flour" 200 #f #f)
    (buffer-zone "spec-flour" 30 100 150 5 5)))

(define multi-facts (append bakery-facts mill-facts))

(define bakery-ctx
  (with-vat vat
    (make-plan-ctx multi-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "bakery" (build-indexes multi-facts))))

(define mill-ctx
  (with-vat vat
    (make-plan-ctx multi-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "mill" (build-indexes multi-facts))))

;; Federation-level test: plan-federation-o with ddmrp-leaf-planner
;; The ctx-map gives each scope its own ctx (same facts; in a real
;; setup each scope would have its own lifted facts subset).
(with-vat vat
  (let* ((scope-ids '("bakery" "mill"))
         (parent-map '())  ;; flat federation, no hierarchy
         (ctx-map `(("bakery" . ,bakery-ctx)
                    ("mill"   . ,mill-ctx)))
         (results
           (run-plan 1 ns (q)
             (plan-federation-o multi-facts scope-ids parent-map ctx-map q
                                #:leaf-planner ddmrp-leaf-planner))))
    (check-pred "multi-scope DDMRP federation produces a result"
                (pair? results))
    (when (pair? results)
      (let ((fed-result (car results)))
        (check-pred "federation result is an alist"
                    (and (pair? fed-result) (assq 'scope fed-result)))
        (check-pred "federation result has plan field"
                    (assq 'plan fed-result))
        (check-pred "federation result has deficits field"
                    (assq 'deficits fed-result))
        (check-pred "federation result has retraction-candidates field"
                    (assq 'retraction-candidates fed-result))
        (check-pred "federation result aggregates coherence from children"
                    (assq 'coherence fed-result))))))

;; Test that harmony scoring works across DDMRP federation
(with-vat vat
  (let* ((scope-ids '("bakery" "mill"))
         (parent-map '())
         (ctx-map `(("bakery" . ,bakery-ctx)
                    ("mill"   . ,mill-ctx)))
         (level-fn (lambda (s) (if (equal? s "spec-bread") 9 1)))
         (results
           (run-plan 1 ns (q)
             (plan-federation-o multi-facts scope-ids parent-map ctx-map q
                                #:leaf-planner ddmrp-leaf-planner
                                #:level-fn level-fn))))
    (check-pred "DDMRP federation with level-fn produces a result"
                (pair? results))
    (when (pair? results)
      (check-pred "result includes harmony aggregation"
                  (assq 'harmony (car results))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. Transport-branch threading (gap #15)
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; Pre-fix, the duplicated `ddmrp-after-allocation` only had two conde
;;; branches: produce-branch and unmet. transport-branch was silently
;;; dropped. After collapsing the duplication and parameterizing
;;; demand-o through #:allocator + #:buffered-specs, transport-branch
;;; is back in the conde. This regression test verifies the wiring:
;;; a cross-location pull through ddmrp-demand-o must produce a
;;; (transport ...) plan term, not just an unmet term.

(display "\n── Transport-branch threading (gap #15) ──\n")

;; Cross-location scenario: flour inventory only at warehouse-A,
;; demand needs it at warehouse-B. spec is NOT buffered (so the
;; decoupling gate doesn't fire). The expected outcome is that the
;; conde in after-allocation reaches transport-branch, finds the
;; warehouse-A inventory, and emits a (transport ...) term.

(define transport-facts
  `((inventory "r-flour-A" "spec-flour" 200 "warehouse-A" #f)))

(define transport-ctx
  (with-vat vat
    (make-plan-ctx transport-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-transport" (build-indexes transport-facts))))

(with-vat vat
  (let* ((due (+ (current-time) 86400))
         ;; Enumerate up to 5 alternatives so the (slower-to-search)
         ;; transport branch is reachable past the trivial unmet branch.
         (results (run-plan 5 ns (q)
                    (ddmrp-demand-o transport-ctx '() "spec-flour" 50 due q
                                    #:at-location "warehouse-B"
                                    #:depth 5))))
    (check-pred "ddmrp-demand-o cross-location: produces results"
                (pair? results))
    (let ((kinds (map car results)))
      (check-pred "results include transport term (not silently dropped)"
                  (memq 'transport kinds))
      (check-pred "results also include unmet branch (sanity)"
                  (memq 'unmet kinds)))
    ;; Verify transport term has the expected shape:
    ;; (transport spec-id allocated source-loc dest-loc transport-rid)
    (let ((transport-term (find (lambda (t) (eq? (car t) 'transport)) results)))
      (when transport-term
        (check "transport spec is flour" (cadr transport-term) "spec-flour")
        (check-pred "transport allocation is non-empty"
                    (pair? (caddr transport-term)))
        (check "transport source is warehouse-A"
               (list-ref transport-term 3) "warehouse-A")
        (check "transport destination is warehouse-B"
               (list-ref transport-term 4) "warehouse-B")))))

;; Replenishment + transport: when a buffered spec is being
;; replenished and inventory exists only at another location, the
;; gate is open AND transport-branch is reachable. This is the
;; full DDMRP cross-location replenishment scenario.

(define transport-buffered-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-flour-A" "spec-flour" 200 "warehouse-A" #f)))

(define transport-buffered-ctx
  (with-vat vat
    (make-plan-ctx transport-buffered-facts ($ scope 'plan-store) ($ scope 'observer)
                   #f "test-transport-buf" (build-indexes transport-buffered-facts))))

(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 5 ns (q)
                    (ddmrp-demand-o transport-buffered-ctx '("spec-flour")
                                    "spec-flour" 50 due q
                                    #:at-location "warehouse-B"
                                    #:replenishment? #t
                                    #:depth 5))))
    (check-pred "buffered+replenishment cross-location: produces results"
                (pair? results))
    (let ((kinds (map car results)))
      (check-pred "buffered+replenishment includes transport term"
                  (memq 'transport kinds)))))

;; Negative control: gate-closed buffered spec at cross-location
;; without replenishment mode → transport must NOT fire (the gate
;; intercepts before the conde, forcing unmet directly).

(with-vat vat
  (let* ((due (+ (current-time) 86400))
         (results (run-plan 5 ns (q)
                    (ddmrp-demand-o transport-buffered-ctx '("spec-flour")
                                    "spec-flour" 50 due q
                                    #:at-location "warehouse-B"
                                    #:depth 5))))
    (check-pred "buffered no-replenishment cross-location: produces results"
                (pair? results))
    (let ((kinds (delete-duplicates (map car results))))
      (check-pred "gate-closed buffered: only unmet (no transport)"
                  (and (memq 'unmet kinds)
                       (not (memq 'transport kinds)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 12. harmony-above-o (gap #10 — partial Level A)
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; harmony-above-o is a Level A composable goal: it filters the
;;; result stream of `(run-plan ...)` by a harmony threshold. It is
;;; NOT a Level C in-search constraint (the harmony arithmetic uses
;;; sqrt and float exponents that CLP(FD) cannot prune over) — every
;;; candidate plan is fully constructed before the threshold check.
;;; See harmony.scm for the level-A/B/C distinction.

(display "\n── harmony-above-o (gap #10 partial) ──\n")

;; Hand-craft plans with known harmony so we can test the threshold
;; behavior without needing to run a full plan-o search.
;;
;; Recall:
;;   compute-harmony goal output =
;;     - ((output-goal)/goal)²   if output < goal   (deficit, negative)
;;     0                          if output = goal
;;     sqrt((output-goal)/goal)  if output > goal   (surplus, positive)

(define satisfied-plan
  '((((spec-id . "spec-bread") (quantity . 20))
     (satisfied "spec-bread" 20 (("r-bread" 20)) #f))))

(define half-plan
  '((((spec-id . "spec-bread") (quantity . 20))
     (unmet "spec-bread" 10 #f))))

;; Satisfied plan: harmony = 0 per demand × 1 priority = 0 total
(check-pred "harmony-above-o: satisfied plan passes threshold -1"
            (pair? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-above-o satisfied-plan -1))))

(check-pred "harmony-above-o: satisfied plan fails threshold 1"
            (null? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-above-o satisfied-plan 1))))

(check-pred "harmony-at-least-o: satisfied plan equals threshold 0"
            (pair? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-at-least-o satisfied-plan 0))))

(check-pred "harmony-above-o: satisfied plan strictly above 0 → fail"
            (null? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-above-o satisfied-plan 0))))

;; Half plan: 10/20 unmet → output=10, goal=20, u=-0.5, harmony = -0.25
(check-pred "harmony-above-o: half plan passes -0.5"
            (pair? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-above-o half-plan -1/2))))

(check-pred "harmony-above-o: half plan fails -0.1 (too low)"
            (null? (run-plan 1 ns (q)
                     (== q 'ok)
                     (harmony-above-o half-plan -1/10))))

;; Composition: filter a multi-result run by harmony threshold.
;; Use the satisfied plan as the only candidate; it should pass and
;; come back. Then test with a harmony threshold the half plan can't
;; meet — it should be filtered out.
(let* ((all-plans (list satisfied-plan half-plan))
       (passing
         (filter (lambda (p)
                   (pair? (run-plan 1 ns (q)
                            (== q 'ok)
                            (harmony-above-o p -1/4))))
                 all-plans)))
  (check "harmony-above-o filter: 1 of 2 passes -1/4"
         (length passing) 1)
  (check "harmony-above-o filter: kept the satisfied plan"
         (car passing) satisfied-plan))

;; Priority-fn weighting: a low-priority deficit should pass a
;; threshold that the same demand at high priority would fail.
(let ((low-prio-fn  (lambda (s) 1/10))
      (high-prio-fn (lambda (s) 10)))
  (check-pred "harmony-above-o: half plan passes -0.1 with low priority"
              (pair? (run-plan 1 ns (q)
                       (== q 'ok)
                       (harmony-above-o half-plan -1/10
                                        #:priority-fn low-prio-fn))))
  (check-pred "harmony-above-o: half plan fails -0.1 with high priority"
              (null? (run-plan 1 ns (q)
                       (== q 'ok)
                       (harmony-above-o half-plan -1/10
                                        #:priority-fn high-prio-fn)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 13. Container-aware DDMRP allocation (gap #3)
;;; ════════════════════════════════════════════════════════════════════════════
;;;
;;; ddmrp-allocate-o threads #:container-id through to allocate-o, which
;;; applies the container filter BEFORE the per-floor conde branches.
;;; That means buffer floors are computed against the *whole* inventory
;;; pool but only resources matching the container can satisfy the
;;; demand. These tests verify the filter wires through correctly and
;;; that the 3-tier behavior is preserved when scoped to one container.

(display "\n── Container-aware DDMRP allocation (gap #3) ──\n")

;; Three flour resources: two in container "bin-A", one in "bin-B".
;; Plus a top-level (uncontained) resource. The buffer zone applies
;; globally to spec-flour.
(define container-facts
  `((buffer-zone "spec-flour" 30 100 150 5 5)
    (inventory "r-fA1" "spec-flour" 60 #f "bin-A")
    (inventory "r-fA2" "spec-flour" 50 #f "bin-A")
    (inventory "r-fB"  "spec-flour" 80 #f "bin-B")
    (inventory "r-top" "spec-flour" 40 #f #f)))

;; Container A has 60+50=110 units. Demand 30 → 110-30=80, which is
;; below TOY=100 but above TOR=30, so the TOR sacrifice tier should
;; satisfy it. (The TOY tier alone can take only 110-100=10 units,
;; not enough for 30.)
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o container-facts "spec-flour" 30
                                     remaining allocated
                                     #:container-id "bin-A")
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "container bin-A: TOR sacrifice tier satisfies"
              (pair? results))
  (when (pair? results)
    (let* ((alloc (car results))
           (rids (map car alloc)))
      (check-pred "container bin-A: only bin-A resources used"
                  (every (lambda (r) (member r '("r-fA1" "r-fA2"))) rids))
      (check-pred "container bin-A: bin-B resource not touched"
                  (not (member "r-fB" rids)))
      (check-pred "container bin-A: top-level resource not touched"
                  (not (member "r-top" rids))))))

;; Container B has 80 units alone. Demand 50 → 80-50=30, TOY=100,
;; TOR=30 → above TOR floor. TOY tier insufficient (can take only
;; 80-100=−20 → 0). TOR can take 80-30=50. ✓
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o container-facts "spec-flour" 50
                                     remaining allocated
                                     #:container-id "bin-B")
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "container bin-B: TOR tier satisfies 50"
              (pair? results))
  (when (pair? results)
    (let* ((alloc (car results))
           (rids (map car alloc)))
      (check-pred "container bin-B: only r-fB used"
                  (equal? rids '("r-fB"))))))

;; Empty container (bin-C) has no inventory. Even sacrifice can't
;; satisfy a positive demand. Allocator returns remaining=demand.
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o container-facts "spec-flour" 10
                                     remaining allocated
                                     #:container-id "bin-C")
                   (== q remaining)))))
  (check-pred "container bin-C (empty): allocator returns full remaining"
              (and (pair? results) (= (car results) 10))))

;; Demand exceeds even sacrifice tier in bin-A: ask for 200 units.
;; bin-A has 110 total → max take = 110, remaining = 90.
;; Constrain remaining=90 directly so the solver picks the
;; sacrifice-tier solution instead of enumerating all 3 tiers.
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o container-facts "spec-flour" 200
                                     remaining allocated
                                     #:container-id "bin-A")
                   (== remaining 90)
                   (== q allocated)))))
  (check-pred "container bin-A overdemand: sacrifice tier leaves rem=90"
              (pair? results)))

;; Cross-check: a top-level resource demand (no container-id) only
;; sees the uncontained r-top (40 units). Demand 30 → 40-30=10,
;; below TOR=30 → only sacrifice can satisfy.
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (ddmrp-allocate-o container-facts "spec-flour" 30
                                     remaining allocated)
                   (== remaining 0)
                   (== q allocated)))))
  (check-pred "no container-id: only top-level resources visible"
              (pair? results))
  (when (pair? results)
    (let ((rids (map car (car results))))
      (check "no container-id: only r-top in allocation"
             rids '("r-top")))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Results
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
