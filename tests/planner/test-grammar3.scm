;;; test-grammar3.scm — Tests for the unified table grammar (grammar3.scm)
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-grammar3.scm
;;;
;;; What this tests vs. the earlier grammars:
;;;   - match-pattern-o directly (unit tests on the interpreter itself)
;;;   - Full parity with grammar.scm on all original question forms
;;;   - New words work with zero grammar changes (only table rows)
;;;   - tell3 returns structured assertion goals
;;;   - ask3 end-to-end pipeline
;;;   - The table itself as a consistency check

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (playnet deprecated kanren-constraints)
             (srfi srfi-1))
(define ns '())

;; Load grammar3 alongside the existing relational layer
(let ((dir (dirname (current-filename))))
  (use-modules (playnet deprecated planner relational grammar3)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Scope + world setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Grammar3 Test")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-wheat" #:name "Wheat"
                                                          #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-flour" #:name "Flour"
                                                          #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec (make-resource-specification #:id "spec-bread" #:name "Bread"
                                                          #:default-unit-of-resource "each"))
    ($ rs 'add-process-spec  (make-process-specification  #:id "pspec-mill" #:name "Milling"))
    ($ rs 'add-process-spec  (make-process-specification  #:id "pspec-bake" #:name "Baking"))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-mill" #:name "Mill wheat"
                                                   #:process-conforms-to "pspec-mill"
                                                   #:has-duration (make-duration 2 "hours")))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-bake" #:name "Bake bread"
                                                   #:process-conforms-to "pspec-bake"
                                                   #:has-duration (make-duration 4 "hours")))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-wheat-in"  #:action 'consume
                                             #:resource-conforms-to "spec-wheat"
                                             #:resource-quantity (make-measure 10 "kg")
                                             #:recipe-input-of "rp-mill"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-flour-out" #:action 'produce
                                             #:resource-conforms-to "spec-flour"
                                             #:resource-quantity (make-measure  8 "kg")
                                             #:recipe-output-of "rp-mill"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-flour-in"  #:action 'consume
                                             #:resource-conforms-to "spec-flour"
                                             #:resource-quantity (make-measure  8 "kg")
                                             #:recipe-input-of "rp-bake"))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id "rf-bread-out" #:action 'produce
                                             #:resource-conforms-to "spec-bread"
                                             #:resource-quantity (make-measure 20 "each")
                                             #:recipe-output-of "rp-bake"))
    ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread Production"
                                   #:primary-output "spec-bread"
                                   #:recipe-processes (list "rp-mill" "rp-bake")))
    ($ as 'add-agent  (make-agent #:id "agent-commune" #:type 'organization #:name "Grammar3 Test"))
    (check-pred "knowledge seeded" (pair? ($ rs 'get-process-chain "recipe-bread")))))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource (make-economic-resource #:id "r-wheat" #:name "Wheat Stock" #:conforms-to "spec-wheat"
      #:accounting-quantity (make-measure 200 "kg")   #:onhand-quantity (make-measure 200 "kg")   #:current-location "loc-farm" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource (make-economic-resource #:id "r-flour" #:name "Flour Stock" #:conforms-to "spec-flour"
      #:accounting-quantity (make-measure  50 "kg")   #:onhand-quantity (make-measure  50 "kg")   #:current-location "loc-mill" #:primary-accountable "agent-commune"))
    ($ obs 'seed-resource (make-economic-resource #:id "r-bread" #:name "Bread Stock" #:conforms-to "spec-bread"
      #:accounting-quantity (make-measure   0 "each") #:onhand-quantity (make-measure   0 "each") #:current-location "loc-bakery" #:primary-accountable "agent-commune"))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))

(define test-facts
  (with-vat vat (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer))))

(define test-ctx
  (with-vat vat
    (make-plan-ctx test-facts ($ scope 'plan-store) ($ scope 'observer) #f "test-grammar3"
                   (build-indexes test-facts))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Table integrity
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Table integrity ──\n")

(check-pred "every entry has exactly 2 elements"
  (every (lambda (e) (= (length e) 2)) *utterances*))

(check-pred "every surface-pattern is a list"
  (every (lambda (e) (list? (car e))) *utterances*))

(check-pred "every goal-template starts with a symbol"
  (every (lambda (e) (symbol? (caadr e))) *utterances*))

(check-pred "demand entries exist"
  (any (lambda (e) (eq? (caadr e) 'demand)) *utterances*))

(check-pred "assertion entries exist"
  (any (lambda (e) (let ((s (symbol->string (caadr e))))
                     (and (>= (string-length s) 7)
                          (string=? "assert-" (substring s 0 7)))))
       *utterances*))

;; New verbs come for free — just check the table has them
(for-each (lambda (verb)
            (check-pred (string-append "table has verb: " verb)
              (any (lambda (e) (equal? (caar e) verb)) *utterances*)))
          '("make" "produce" "build" "grow" "harvest" "create"))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. match-pattern-o — unit tests on the interpreter directly
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── match-pattern-o (interpreter unit tests) ──\n")

;; Literal consumption
(check "literal: consumes single word"
  (run-plan* ns (b) (match-pattern-o test-ctx '("make") b '("make") '()))
  '(()))

(check "literal: fails on wrong word"
  (run-plan* ns (b) (match-pattern-o test-ctx '("make") b '("produce") '()))
  '())

(check "literal sequence: all consumed"
  (run-plan* ns (b)
    (match-pattern-o test-ctx '("how" "much") b '("how" "much") '()))
  '(()))

;; Slot collection
(check ":spec collected into bindings"
  (let ((results (run-plan* ns (b)
                   (match-pattern-o test-ctx '(:spec) b '("wheat") '()))))
    (and (pair? results)
         (equal? (assq ':spec (car results))
                 '(:spec . "spec-wheat"))))
  #t)

(check ":?qty absent — no :qty binding"
  (let ((results (run-plan* ns (b)
                   (match-pattern-o test-ctx '(:?qty :spec) b '("bread") '()))))
    (and (pair? results)
         (not (assq ':qty (car results)))
         (assq ':spec (car results))
         #t))
  #t)

(check ":?qty present — :qty binding appears"
  (let ((results (run-plan* ns (b)
                   (match-pattern-o test-ctx '(:?qty :spec) b '(10 "bread") '()))))
    (and (pair? results)
         (equal? (assq ':qty (car results)) '(:qty . 10))
         (assq ':spec (car results))
         #t))
  #t)

(check ":spec before literal: spec then literal consumed"
  (let ((results (run-plan* ns (b)
                   (match-pattern-o test-ctx
                     '(:spec "do" "we" "have")
                     b
                     '("wheat" "do" "we" "have") '()))))
    (and (pair? results)
         (equal? (assq ':spec (car results)) '(:spec . "spec-wheat"))))
  #t)

;; SVO: :spec then literal then :spec2
(check ":spec literal :spec2 — both collected"
  (let ((results (run-plan* ns (b)
                   (match-pattern-o test-ctx
                     '(:spec "needs" :spec2)
                     b
                     '("bread" "needs" "flour") '()))))
    (and (pair? results)
         (equal? (assq ':spec  (car results)) '(:spec  . "spec-bread"))
         (equal? (assq ':spec2 (car results)) '(:spec2 . "spec-flour"))))
  #t)

(check "unknown slot keyword → fail"
  (run-plan* ns (b) (match-pattern-o test-ctx '(:unknown) b '("wheat") '()))
  '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. assemble-goal-o
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── assemble-goal-o ──\n")

(check "assemble demand: spec + qty present"
  (run-plan 1 ns (g)
    (assemble-goal-o '(demand :spec :qty)
                     '((:spec . "spec-bread") (:qty . 10))
                     g))
  '((demand "spec-bread" 10)))

(check "assemble demand: qty absent → #f"
  (run-plan 1 ns (g)
    (assemble-goal-o '(demand :spec :qty)
                     '((:spec . "spec-bread"))
                     g))
  '((demand "spec-bread" #f)))

(check "assemble inventory: single slot"
  (run-plan 1 ns (g)
    (assemble-goal-o '(inventory :spec)
                     '((:spec . "spec-wheat"))
                     g))
  '((inventory "spec-wheat")))

(check "assemble assert-requires: two specs"
  (run-plan 1 ns (g)
    (assemble-goal-o '(assert-requires :spec :spec2)
                     '((:spec . "spec-bread") (:spec2 . "spec-flour"))
                     g))
  '((assert-requires "spec-bread" "spec-flour")))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. utterance-o — parity with grammar.scm
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Question parsing (parity with grammar.scm) ──\n")

(define (parse3 phrase) (parse-utterance3 test-ctx phrase))

(check "parse: how do we make 10 bread"
  (parse3 "how do we make 10 bread")
  '((demand "spec-bread" 10)))

(check "parse: make bread (no qty → #f)"
  (let ((r (parse3 "make bread")))
    (and (pair? r) (equal? (car r) '(demand "spec-bread" #f))))
  #t)

(check "parse: produce 5 flour"
  (parse3 "produce 5 flour")
  '((demand "spec-flour" 5)))

(check "parse: what is needed for flour"
  (parse3 "what is needed for flour")
  '((provenance "spec-flour")))

(check "parse: what goes into bread"
  (parse3 "what goes into bread")
  '((provenance "spec-bread")))

(check "parse: what can we make from wheat"
  (parse3 "what can we make from wheat")
  '((destination "spec-wheat")))

(check "parse: what uses wheat"
  (parse3 "what uses wheat")
  '((destination "spec-wheat")))

(check "parse: how much wheat do we have"
  (parse3 "how much wheat do we have")
  '((inventory "spec-wheat")))

(check "parse: inventory of flour"
  (parse3 "inventory of flour")
  '((inventory "spec-flour")))

(check "parse: show recipes for bread"
  (parse3 "show recipes for bread")
  '((recipes "spec-bread")))

(check "parse: unknown phrase → empty"
  (parse3 "hello world")
  '())
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. New utterance forms — added by table rows only
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── New forms (table-only additions) ──\n")

(check "build 5 bread"
  (let ((r (parse3 "build 5 bread")))
    (and (pair? r) (equal? (car r) '(demand "spec-bread" 5))))
  #t)

(check "grow wheat"
  (let ((r (parse3 "grow wheat")))
    (and (pair? r) (eq? (caar r) 'demand)))
  #t)

(check "harvest flour"
  (let ((r (parse3 "harvest flour")))
    (and (pair? r) (eq? (caar r) 'demand)))
  #t)

(check "how to make bread"
  (let ((r (parse3 "how to make bread")))
    (and (pair? r) (eq? (caar r) 'demand)))
  #t)

(check "how many wheat do we have"
  (parse3 "how many wheat do we have")
  '((inventory "spec-wheat")))

(check "how much flour is there"
  (parse3 "how much flour is there")
  '((inventory "spec-flour")))

(check "inputs for bread"
  (parse3 "inputs for bread")
  '((provenance "spec-bread")))

(check "what needs wheat"
  (let ((r (parse3 "what needs wheat")))
    (and (pair? r) (eq? (caar r) 'destination)))
  #t)

(check "what does it take to make bread"
  (let ((r (parse3 "what does it take to make bread")))
    (and (pair? r) (eq? (caar r) 'provenance)))
  #t)

(check "what recipes use wheat"
  (parse3 "what recipes use wheat")
  '((recipes "spec-wheat")))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Statement parsing (tell3)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Statements (tell3) ──\n")

(check "we have 200 wheat"
  (tell3 test-ctx "we have 200 wheat")
  '(assert-inventory "spec-wheat" 200 #f))

(check "there are 50 flour"
  (tell3 test-ctx "there are 50 flour")
  '(assert-inventory "spec-flour" 50 #f))

(check "bread needs flour (SVO)"
  (tell3 test-ctx "bread needs flour")
  '(assert-requires "spec-bread" "spec-flour"))

(check "bread requires wheat (SVO)"
  (tell3 test-ctx "bread requires wheat")
  '(assert-requires "spec-bread" "spec-wheat"))

(check "bread is made from flour (SVO)"
  (tell3 test-ctx "bread is made from flour")
  '(assert-recipe "spec-bread" "spec-flour"))

(check "unknown statement → #f"
  (tell3 test-ctx "hello world")
  #f)

(check "question is not an assertion"
  (tell3 test-ctx "make bread")
  #f)
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. ask3 end-to-end
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ask3 pipeline ──\n")

(let ((r (ask3 test-ctx "how much wheat do we have")))
  (check-pred "ask3: inventory returns string" (string? r))
  (check-pred "ask3: inventory mentions 200"   (string-contains r "200")))

(let ((r (ask3 test-ctx "show recipes for bread")))
  (check-pred "ask3: recipes returns string"            (string? r))
  (check-pred "ask3: recipes mentions Bread Production" (string-contains r "Bread Production")))

(let ((r (ask3 test-ctx "what is needed for bread")))
  (check-pred "ask3: provenance returns string" (string? r)))

(check-pred "ask3: unknown → graceful failure"
  (string-contains (ask3 test-ctx "hello world") "don't understand"))

;; New verbs work end-to-end
(let ((r (ask3 test-ctx "build 1 bread")))
  (check-pred "ask3: build (new verb) returns string" (string? r)))

(let ((r (ask3 test-ctx "harvest 5 wheat")))
  (check-pred "ask3: harvest (new verb) returns string" (string? r)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. Grammar reduction comparison
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Grammar size comparison ──\n")

(display (string-append
  "  grammar.scm  — 5 question functions, 0 statement support\n"
  "  grammar2.scm — 3 tables, 4 frame fns, np-args-o (5 branches)\n"
  "  grammar3.scm — 1 table (" (number->string (length *utterances*))
  " rows), match-pattern-o, utterance-o (3 lines)\n"))

(check-pred "utterances table is the only grammar"
  (> (length *utterances*) 20))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)

(display (string-append "  " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))

(test-summary!)
