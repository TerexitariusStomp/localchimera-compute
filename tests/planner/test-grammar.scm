;;; test-grammar.scm — Tests for the relational query grammar
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-grammar.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))
(define ns '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Scope setup (same as relational-planner.scm)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Grammar Test")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-wheat" #:name "Wheat"
                                                          #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-flour" #:name "Flour"
                                                          #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-bread" #:name "Bread"
                                                          #:default-unit-of-resource %count-unit))
    ($ rs 'add-process-spec (make-process-specification #:id "pspec-mill" #:name "Milling"))
    ($ rs 'add-process-spec (make-process-specification #:id "pspec-bake" #:name "Baking"))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-mill" #:name "Mill wheat"
                                                   #:process-conforms-to "pspec-mill"
                                                   #:has-duration (make-duration 2 %effort-unit)))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-bake" #:name "Bake bread"
                                                   #:process-conforms-to "pspec-bake"
                                                   #:has-duration (make-duration 4 %effort-unit)))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-wheat-in" #:action 'consume
                                             #:resource-conforms-to "spec-wheat"
                                             #:resource-quantity (make-measure 10 "kg")
                                             #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-flour-out" #:action 'produce
                                             #:resource-conforms-to "spec-flour"
                                             #:resource-quantity (make-measure 8 "kg")
                                             #:recipe-output-of "rp-mill"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-flour-in" #:action 'consume
                                             #:resource-conforms-to "spec-flour"
                                             #:resource-quantity (make-measure 8 "kg")
                                             #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-bread-out" #:action 'produce
                                             #:resource-conforms-to "spec-bread"
                                             #:resource-quantity (make-measure 20 %count-unit)
                                             #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread Production"
                                   #:primary-output "spec-bread"
                                   #:recipe-processes (list "rp-mill" "rp-bake")))
    ($ as 'add-agent (make-agent #:id "agent-commune" #:type 'organization #:name "Grammar Test"))
    (check-pred "knowledge seeded" (pair? ($ rs 'get-process-chain "recipe-bread")))))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource (make-economic-resource #:id "r-wheat" #:name "Wheat Stock" #:conforms-to "spec-wheat"
      #:accounting-quantity (make-measure 200 "kg") #:onhand-quantity (make-measure 200 "kg") #:current-location "loc-farm" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource (make-economic-resource #:id "r-flour" #:name "Flour Stock" #:conforms-to "spec-flour"
      #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg") #:current-location "loc-mill" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource (make-economic-resource #:id "r-bread" #:name "Bread Stock" #:conforms-to "spec-bread"
      #:accounting-quantity (make-measure 0 %count-unit) #:onhand-quantity (make-measure 0 %count-unit) #:current-location "loc-bakery" #:primary-accountable "agent-commune"))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Lift facts & build ctx
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Lift facts ──\n")

(define test-facts
  (with-vat vat (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer))))

(define test-ctx
  (with-vat vat
    (make-plan-ctx test-facts ($ scope 'plan-store) ($ scope 'observer) #f "test-grammar"
                   (build-indexes test-facts))))

(check-pred "spec-name facts present"
  (any (lambda (f) (eq? (car f) 'spec-name)) test-facts))

(check-pred "specs-by-word index built"
  (let ((indexes (ctx-indexes test-ctx)))
    (pair? (idx-ref indexes 'specs-by-word "wheat"))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Lexicon tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Lexicon ──\n")

(check "tokenize simple"
  (tokenize-phrase "how do we make 10 bread")
  '("how" "do" "we" "make" 10 "bread"))

(check "tokenize normalizes case"
  (tokenize-phrase "Make Bread")
  '("make" "bread"))

(check "spec-name-o: wheat"
  (run-plan* ns (q) (spec-name-o test-ctx "wheat" q))
  '("spec-wheat"))

(check "spec-name-o: bread"
  (run-plan* ns (q) (spec-name-o test-ctx "bread" q))
  '("spec-bread"))

(check "spec-name-o: unknown word"
  (run-plan* ns (q) (spec-name-o test-ctx "pizza" q))
  '())

(check "spec-word-o: spec-flour → flour"
  (run-plan* ns (q) (spec-word-o test-ctx "spec-flour" q))
  '("flour"))

(check "location-word-o: strips loc- prefix"
  (run-plan* ns (q) (location-word-o test-ctx "loc-farm" q))
  '("farm"))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Parse tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Parsing ──\n")

(check "parse: how do we make 10 bread"
  (parse-query test-ctx "how do we make 10 bread")
  '((demand "spec-bread" 10)))

(check "parse: make bread (no qty)"
  (let ((results (parse-query test-ctx "make bread")))
    (and (pair? results)
         (eq? (caar results) 'demand)
         (equal? (cadar results) "spec-bread")))
  #t)

(check "parse: produce 5 flour"
  (parse-query test-ctx "produce 5 flour")
  '((demand "spec-flour" 5)))

(check "parse: what is needed for flour"
  (parse-query test-ctx "what is needed for flour")
  '((provenance "spec-flour")))

(check "parse: what goes into bread"
  (parse-query test-ctx "what goes into bread")
  '((provenance "spec-bread")))

(check "parse: what can we make from wheat"
  (parse-query test-ctx "what can we make from wheat")
  '((destination "spec-wheat")))

(check "parse: what uses wheat"
  (parse-query test-ctx "what uses wheat")
  '((destination "spec-wheat")))

(check "parse: how much wheat do we have"
  (parse-query test-ctx "how much wheat do we have")
  '((inventory "spec-wheat")))

(check "parse: inventory of flour"
  (parse-query test-ctx "inventory of flour")
  '((inventory "spec-flour")))

(check "parse: show recipes for bread"
  (parse-query test-ctx "show recipes for bread")
  '((recipes "spec-bread")))

(check "parse: recipes for flour"
  (parse-query test-ctx "recipes for flour")
  '((recipes "spec-flour")))

(check "parse: unknown phrase returns empty"
  (parse-query test-ctx "hello world")
  '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Narration tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Narration ──\n")

(check "narrate: satisfied"
  (narrate-plan test-ctx '(satisfied "spec-wheat" 100 50 "loc-farm"))
  "use 50 wheat from farm inventory")

(check "narrate: produce"
  (narrate-plan test-ctx '(produce "spec-bread" "recipe-bread" 2 () () ()))
  "produce bread at scale 2 via bread production")

(check "narrate: transport"
  (narrate-plan test-ctx '(transport "spec-wheat" 50 "loc-farm" "loc-mill" "t-1"))
  "transport 50 wheat from farm to mill")

(check "narrate: unmet"
  (narrate-plan test-ctx '(unmet "spec-flour" 30 "loc-mill"))
  "30 flour cannot be sourced")
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Execute tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Execution ──\n")

(let ((results (execute-query test-ctx '(inventory "spec-wheat") #f)))
  (check "execute inventory: wheat"
    results
    '((stock 200 "loc-farm"))))

(let ((results (execute-query test-ctx '(recipes "spec-bread") #f)))
  (check "execute recipes: bread"
    results
    '((recipe "recipe-bread" "Bread Production"))))

(let ((results (execute-query test-ctx '(provenance "spec-bread") #f)))
  (check-pred "execute provenance: bread has inputs"
    (pair? results)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Bidirectional round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Bidirectional ──\n")

;; Parse → execute → narrate
(let* ((goals (parse-query test-ctx "how much wheat do we have"))
       (results (and (pair? goals) (execute-query test-ctx (car goals) #f))))
  (check-pred "round-trip: parse inventory yields results"
    (and (pair? results) (equal? (car results) '(stock 200 "loc-farm")))))

;; Narrate a plan-term, then check words are sensible
(let ((words (run-plan 1 ns (w) (narrate-o test-ctx '(satisfied "spec-flour" 50 50 "loc-mill") w '()))))
  (check "bidirectional: narrate-o produces word list"
    (and (pair? words) (car words))
    '("use" "50" "flour" "from" "mill" "inventory")))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Recursive narration
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Recursive narration ──\n")

(check "narrate-plan-tree: satisfied (leaf)"
  (narrate-plan-tree test-ctx '(satisfied "spec-wheat" 100 50 "loc-farm"))
  "use 50 wheat from farm inventory\n")

(check "narrate-plan-tree: produce with sub-plans"
  (narrate-plan-tree test-ctx
    '(produce "spec-bread" "recipe-bread" 1
       ((satisfied "spec-flour" 8 8 "loc-mill"))
       () ()))
  (string-append
    "produce bread at scale 1 via bread production\n"
    "  inputs:\n"
    "    use 8 flour from mill inventory\n"))

(check "narrate-plan-tree: nested production"
  (let ((tree (narrate-plan-tree test-ctx
          '(produce "spec-bread" "recipe-bread" 1
             ((produce "spec-flour" "recipe-bread" 1
                ((satisfied "spec-wheat" 10 10 "loc-farm"))
                () ()))
             () ()))))
    (string? tree))
  #t)
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Full ask pipeline
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Ask pipeline ──\n")

(let ((result (ask test-ctx "how much wheat do we have")))
  (check-pred "ask inventory: returns string"
    (string? result))
  (check-pred "ask inventory: mentions 200"
    (string-contains result "200")))

(let ((result (ask test-ctx "show recipes for bread")))
  (check-pred "ask recipes: returns string"
    (string? result))
  (check-pred "ask recipes: mentions Bread Production"
    (string-contains result "Bread Production")))

(let ((result (ask test-ctx "what is needed for bread")))
  (check-pred "ask provenance: returns string"
    (string? result)))

(check-pred "ask unknown: graceful failure"
  (string-contains (ask test-ctx "hello world") "don't understand"))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)

(display (string-append "  " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))

(test-summary!)
