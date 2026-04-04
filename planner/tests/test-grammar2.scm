;;; test-grammar2.scm — Tests for the new DCG-based grammar (grammar2.scm)
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-grammar2.scm
;;;
;;; Covers everything test-grammar.scm covers, PLUS:
;;;   - New verbs added via *verb-entries* (build, grow, create)
;;;   - New question triggers added via *question-triggers*
;;;   - Statement parsing via statement-frame-o / tell
;;;   - Bidirectional generation via generate

(use-modules (goblins)
             (goblins persistence-store memory)
             (playnet kanren-constraints)
             (srfi srfi-1))

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

(define ns '())

;; Load the new grammar modules (alongside the existing ones)
(let ((dir (dirname (current-filename))))
  (load (string-append dir "/../lib/relational/dcg.scm"))
  (load (string-append dir "/../lib/relational/lexicon2.scm"))
  (load (string-append dir "/../lib/relational/grammar2.scm")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Scope setup — identical to test-grammar.scm
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-env (lambda () (spawn-scope "Grammar2 Test")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-process-spec  (make-process-specification  "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec  (make-process-specification  "pspec-bake" "Baking"  #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-process (make-recipe-process "rp-mill" "Mill wheat" #f #f "pspec-mill" #f (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-wheat-in"  'consume "spec-wheat" #f (make-measure 10 "kg")   #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f (make-measure  8 "kg")   #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-flour-in"  'consume "spec-flour" #f (make-measure  8 "kg")   #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread" (list "rp-mill" "rp-bake") #f))
    ($ as 'add-agent  (make-agent "agent-commune" 'organization "Grammar2 Test" #f #f #f #f #f))
    (check-pred "knowledge seeded" (pair? ($ rs 'get-process-chain "recipe-bread")))))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource (make-economic-resource "r-wheat" "Wheat Stock" #f #f #f "spec-wheat" #f
      (make-measure 200 "kg") (make-measure 200 "kg") "loc-farm"   #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource (make-economic-resource "r-flour" "Flour Stock" #f #f #f "spec-flour" #f
      (make-measure  50 "kg") (make-measure  50 "kg") "loc-mill"   #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource (make-economic-resource "r-bread" "Bread Stock" #f #f #f "spec-bread" #f
      (make-measure   0 "each") (make-measure 0 "each") "loc-bakery" #f "agent-commune" #f #f #f #f #f #f #f #f))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Lift facts + build ctx
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Lift facts ──\n")

(define test-facts
  (with-vat vat (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer))))

(define test-ctx
  (with-vat vat
    (make-plan-ctx test-facts ($ scope 'plan-store) ($ scope 'observer) #f "test-grammar2"
                   (build-indexes test-facts))))

(check-pred "spec-name facts present"
  (any (lambda (f) (eq? (car f) 'spec-name)) test-facts))

(check-pred "specs-by-word index built"
  (let ((indexes (ctx-indexes test-ctx)))
    (pair? (idx-ref indexes 'specs-by-word "wheat"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Tokenizer + lexicon
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Tokenizer + Lexicon ──\n")

(check "tokenize: numbers become integers"
  (tokenize-phrase "how do we make 10 bread")
  '("how" "do" "we" "make" 10 "bread"))

(check "tokenize: normalizes case"
  (tokenize-phrase "Make Bread")
  '("make" "bread"))

(check "spec-name-o: wheat resolves"
  (run-plan* ns (q) (spec-name-o test-ctx "wheat" q))
  '("spec-wheat"))

(check "spec-word-o: spec-flour → flour"
  (run-plan* ns (q) (spec-word-o test-ctx "spec-flour" q))
  '("flour"))

(check "location-word-o: strips loc- prefix"
  (run-plan* ns (q) (location-word-o test-ctx "loc-farm" q))
  '("farm"))

;; Lexicon self-consistency
(check-pred "verb-entry: make → demand"
  (any (lambda (e) (and (equal? (car e) "make") (eq? (cadr e) 'demand)))
       *verb-entries*))

(check-pred "verb-entry: build → demand (new word, no grammar change)"
  (any (lambda (e) (and (equal? (car e) "build") (eq? (cadr e) 'demand)))
       *verb-entries*))

(check-pred "question-trigger: (how much) → inventory"
  (any (lambda (e) (and (equal? (car e) '("how" "much")) (eq? (cadr e) 'inventory)))
       *question-triggers*))

(check-pred "statement-trigger: (we have) → assert-inventory"
  (any (lambda (e) (and (equal? (car e) '("we" "have")) (eq? (cadr e) 'assert-inventory)))
       *statement-triggers*))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. DCG macro smoke test
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── DCG macro ──\n")

;; Define a tiny test rule with the macro and verify it works
(define-dcg-rule (test-two-words)
  (:word "hello")
  (:word "world"))

(check "dcg-rule: consumes two words"
  (run-plan* ns (q)
    (test-two-words '("hello" "world") '())
    (== q 'ok))
  '(ok))

(check "dcg-rule: fails on wrong words"
  (run-plan* ns (q)
    (test-two-words '("hi" "world") '())
    (== q 'ok))
  '())

(define-dcg-rules (test-either)
  ((:word "a"))
  ((:word "b")))

(check "dcg-rules: first alternative"
  (run-plan* ns (q) (test-either '("a") '()) (== q 'ok))
  '(ok))

(check "dcg-rules: second alternative"
  (run-plan* ns (q) (test-either '("b") '()) (== q 'ok))
  '(ok))

(check "dcg-rules: neither fails"
  (run-plan* ns (q) (test-either '("c") '()) (== q 'ok))
  '())


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Question parsing — parity with grammar.scm
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Question parsing (parity) ──\n")

(check "parse: how do we make 10 bread"
  (parse-utterance test-ctx "how do we make 10 bread")
  '((demand "spec-bread" 10)))

(check "parse: make bread (no qty)"
  (let ((results (parse-utterance test-ctx "make bread")))
    (and (pair? results) (eq? (caar results) 'demand) (equal? (cadar results) "spec-bread")))
  #t)

(check "parse: produce 5 flour"
  (parse-utterance test-ctx "produce 5 flour")
  '((demand "spec-flour" 5)))

(check "parse: what is needed for flour"
  (parse-utterance test-ctx "what is needed for flour")
  '((provenance "spec-flour")))

(check "parse: what goes into bread"
  (parse-utterance test-ctx "what goes into bread")
  '((provenance "spec-bread")))

(check "parse: what can we make from wheat"
  (parse-utterance test-ctx "what can we make from wheat")
  '((destination "spec-wheat")))

(check "parse: what uses wheat"
  (parse-utterance test-ctx "what uses wheat")
  '((destination "spec-wheat")))

(check "parse: how much wheat do we have"
  (parse-utterance test-ctx "how much wheat do we have")
  '((inventory "spec-wheat")))

(check "parse: inventory of flour"
  (parse-utterance test-ctx "inventory of flour")
  '((inventory "spec-flour")))

(check "parse: show recipes for bread"
  (parse-utterance test-ctx "show recipes for bread")
  '((recipes "spec-bread")))

(check "parse: unknown phrase → empty"
  (parse-utterance test-ctx "hello world")
  '())


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. New words — zero grammar changes, only lexicon rows
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── New words (lexicon-only additions) ──\n")

;; "build" and "create" and "grow" are in *verb-entries* — should work already
(check "parse: build 5 bread (new demand verb)"
  (let ((results (parse-utterance test-ctx "build 5 bread")))
    (and (pair? results) (eq? (caar results) 'demand)))
  #t)

(check "parse: create flour (new demand verb)"
  (let ((results (parse-utterance test-ctx "create flour")))
    (and (pair? results) (eq? (caar results) 'demand)))
  #t)

;; "how to make" is in *question-triggers*
(check "parse: how to make bread"
  (let ((results (parse-utterance test-ctx "how to make bread")))
    (and (pair? results) (eq? (caar results) 'demand)))
  #t)

;; "how many" is in *question-triggers*
(check "parse: how many wheat do we have"
  (let ((results (parse-utterance test-ctx "how many wheat do we have")))
    (and (pair? results) (eq? (caar results) 'inventory)))
  #t)

;; "inputs for" is in *question-triggers*
(check "parse: inputs for bread"
  (parse-utterance test-ctx "inputs for bread")
  '((provenance "spec-bread")))

;; "what needs" is in *question-triggers*
(check "parse: what needs wheat"
  (let ((results (parse-utterance test-ctx "what needs wheat")))
    (and (pair? results) (eq? (caar results) 'destination)))
  #t)


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Statement parsing (tell — new capability)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Statement parsing (tell) ──\n")

(check-pred "tell: we have 200 wheat → assert-inventory"
  (let ((result (tell test-ctx "we have 200 wheat")))
    (and result (eq? (car result) 'assert-inventory))))

(check-pred "tell: there are 50 flour → assert-inventory"
  (let ((result (tell test-ctx "there are 50 flour")))
    (and result (eq? (car result) 'assert-inventory))))

(check "tell: unknown statement → #f"
  (tell test-ctx "hello world")
  #f)


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Generation (grammar run backwards)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Generation (backwards) ──\n")

;; Given a semantic goal, generate a phrase
(check-pred "generate: demand goal → words"
  (let ((result (generate test-ctx '(demand "spec-bread" 5))))
    (and result (string? result))))

(check-pred "generate: inventory goal → words"
  (let ((result (generate test-ctx '(inventory "spec-wheat"))))
    (and result (string? result))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. ask2 pipeline — same as ask but using utterance-o
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ask2 pipeline ──\n")

(let ((result (ask2 test-ctx "how much wheat do we have")))
  (check-pred "ask2: inventory returns string" (string? result))
  (check-pred "ask2: inventory mentions 200"   (string-contains result "200")))

(let ((result (ask2 test-ctx "show recipes for bread")))
  (check-pred "ask2: recipes returns string"        (string? result))
  (check-pred "ask2: recipes mentions Bread Production"
              (string-contains result "Bread Production")))

(let ((result (ask2 test-ctx "what is needed for bread")))
  (check-pred "ask2: provenance returns string" (string? result)))

(check-pred "ask2: unknown → graceful failure"
  (string-contains (ask2 test-ctx "hello world") "don't understand"))

;; New verbs work end-to-end
(let ((result (ask2 test-ctx "build 1 bread")))
  (check-pred "ask2: build (new verb) returns string" (string? result)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display "════════════════════════════════════════════\n")
(display (string-append "  " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))
(display "════════════════════════════════════════════\n")
(when (> fail-count 0) (exit 1))
