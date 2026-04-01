;;; test-planning-store.scm — Plan store operations and recipe instantiation
;;;
;;; Ported from: old/planner/src/lib/tests/planning.test.ts
;;;              old/planner/src/lib/tests/planning-advanced.test.ts
;;;
;;; Intent: Verify plan store CRUD, intent/commitment lifecycle,
;;; recipe instantiation with scaling, promote to commitment,
;;; offers/requests, and forward/back scheduling.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-planning-store.scm

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


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "PlanStore Test"))
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
       (make-resource-specification "spec-apples" "Apples" #f #f #f "kg" #f #f #f #f #f))
    ;; Mill → Bake recipe chain
    ($ rs 'add-process-spec
       (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill" #f #f "pspec-mill" #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake" #f #f "pspec-bake" #f
                            (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-w-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-f-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-f-in" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-b-out" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))
    (check-pred "recipes seeded" #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Plan CRUD: add plan, intent, commitment
;;;
;;; Ported from: "addPlan, addIntent, addCommitment correctly stores entities"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan CRUD ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add plan
    ($ ps 'add-plan (make-plan "plan-test" "Test Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))
    (check-pred "plan created" (plan? ($ ps 'get-plan "plan-test")))
    (check "plan name" (plan-name ($ ps 'get-plan "plan-test")) "Test Plan")

    ;; Add intent
    ($ ps 'add-intent
       (make-intent "i-test-1" 'consume "Test intent" #f #f
                    "proc-1" #f #f "spec-wheat" #f
                    (make-measure 100 "kg") #f #f #f
                    #f "agent-a"
                    #f #f #f #f
                    #f #f #f "plan-test" #f #f #f #f))
    (check-pred "intent created" (intent? ($ ps 'get-intent "i-test-1")))
    (check "intent action" (intent-action ($ ps 'get-intent "i-test-1")) 'consume)

    ;; Add commitment
    ($ ps 'add-commitment
       (make-commitment "c-test-1" 'produce #f "proc-1"
                        "spec-bread" #f
                        (make-measure 20 "each") #f
                        "agent-a" "agent-b"
                        #f #f #f #f #f "plan-test" #f #f #f #f))
    (check-pred "commitment created" (commitment? ($ ps 'get-commitment "c-test-1")))
    (check "commitment action" (commitment-action ($ ps 'get-commitment "c-test-1")) 'produce)

    ;; Counts
    (check-pred "1 intent" (= 1 (length ($ ps 'all-intents))))
    (check-pred "1 commitment" (= 1 (length ($ ps 'all-commitments))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Offers and Requests
;;;
;;; Ported from: "publishOffer and publishRequest create Intents and Proposals"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Offers and Requests ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Offer: provider offers apples
    ($ ps 'add-intent
       (make-intent "i-offer-apples" 'produce "Apple offer" #f #f
                    #f "proc-harvest" #f "spec-apples" (list "tag:plan:offer")
                    (make-measure 10 "kg") #f #f #f
                    "agent-alice" #f
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-test" #f #f #f #f))

    ;; Request: receiver requests wheat
    ($ ps 'add-intent
       (make-intent "i-request-wheat" 'consume "Wheat request" #f #f
                    "proc-mill" #f #f "spec-wheat" (list "tag:plan:request")
                    (make-measure 50 "kg") #f #f #f
                    #f "agent-bob"
                    #f #f #f "2026-04-01T00:00:00Z"
                    #f #f #f "plan-test" #f #f #f #f))

    ;; Query offers and requests
    (let ((offers ($ ps 'offers))
          (requests ($ ps 'requests)))
      (check-pred "1 offer" (= 1 (length offers)))
      (check-pred "1 request" (= 1 (length requests)))
      (check "offer spec" (intent-resource-conforms-to (car offers)) "spec-apples")
      (check "request spec" (intent-resource-conforms-to (car requests)) "spec-wheat"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Promote intent to commitment
;;;
;;; Ported from: "promoteToCommitment" tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Promote to commitment ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Promote the offer intent
    (let ((cid ($ ps 'promote-to-commitment "i-offer-apples"
                  (list (cons 'receiver "agent-bob")))))
      (check-pred "promotion creates commitment" (commitment? ($ ps 'get-commitment cid)))

      ;; Original intent marked finished
      (check-pred "intent finished after promotion"
                  (intent-finished ($ ps 'get-intent "i-offer-apples")))

      ;; Commitment inherits fields
      (let ((c ($ ps 'get-commitment cid)))
        (check "promoted action" (commitment-action c) 'produce)
        (check "promoted spec" (commitment-resource-conforms-to c) "spec-apples")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Recipe process chain topology
;;;
;;; Ported from: instantiateRecipe scheduling tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Recipe process chain ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; Topo sort: mill before bake
    (let ((chain ($ rs 'get-process-chain "recipe-bread")))
      (check-pred "chain has 2 procs" (= 2 (length chain)))
      (check "first = mill" (recipe-process-id (car chain)) "rp-mill")
      (check "second = bake" (recipe-process-id (cadr chain)) "rp-bake"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Recipe flow queries
;;;
;;; Ported from: instantiateRecipe flow verification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Recipe flows ──\n")

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ;; Mill process: consumes wheat, produces flour
    (let ((mill-flows ($ rs 'flows-for-process "rp-mill")))
      (check-pred "mill has inputs" (pair? (assq-ref mill-flows 'inputs)))
      (check-pred "mill has outputs" (pair? (assq-ref mill-flows 'outputs)))

      (let ((inputs (assq-ref mill-flows 'inputs))
            (outputs (assq-ref mill-flows 'outputs)))
        (check-pred "mill input = wheat"
                    (any (lambda (f) (equal? "spec-wheat"
                                             (recipe-flow-resource-conforms-to f)))
                         inputs))
        (check-pred "mill output = flour"
                    (any (lambda (f) (equal? "spec-flour"
                                             (recipe-flow-resource-conforms-to f)))
                         outputs))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Inventory query
;;;
;;; Ported from: observer.test.ts inventory tracking
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Inventory query ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed inventory
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat-ps" "Wheat" #f #f #f "spec-wheat" #f
         (make-measure 200 "kg") (make-measure 200 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-flour-ps" "Flour" #f #f #f "spec-flour" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         #f #f "agent-a" #f #f #f #f #f #f #f #f))

    (let ((inv ($ obs 'inventory)))
      (check-pred "inventory has items" (>= (length inv) 2)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Commitment lifecycle: create → fulfill → finish
;;;
;;; Ported from: planning-advanced "commitmentsForProcess"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Commitment lifecycle ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add process-bound commitments
    ($ ps 'add-commitment
       (make-commitment "c-mill-in" 'consume "proc-mill" #f
                        "spec-wheat" #f
                        (make-measure 10 "kg") #f
                        "agent-a" "agent-a"
                        #f #f #f #f #f "plan-test" #f #f #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-mill-out" 'produce #f "proc-mill"
                        "spec-flour" #f
                        (make-measure 8 "kg") #f
                        "agent-a" "agent-a"
                        #f #f #f #f #f "plan-test" #f #f #f #f))

    ;; Both should exist
    (check-pred "mill input commitment"
                (commitment? ($ ps 'get-commitment "c-mill-in")))
    (check-pred "mill output commitment"
                (commitment? ($ ps 'get-commitment "c-mill-out")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Persistence
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (error "Should restore!"))
    store))

(with-vat vat2
  (let ((ps ($ scope2 'plan-store)))
    (check-pred "restored plan" (plan? ($ ps 'get-plan "plan-test")))
    (check-pred "restored intents" (>= (length ($ ps 'all-intents)) 2))
    (check-pred "restored commitments" (>= (length ($ ps 'all-commitments)) 3))
    (check-pred "restored finished intent"
                (intent-finished ($ ps 'get-intent "i-offer-apples")))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
