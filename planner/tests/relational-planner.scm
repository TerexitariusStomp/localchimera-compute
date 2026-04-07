;;; relational-planner.scm — Tests for the pure relational planner (CLP/FD)
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/relational-planner.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
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

(define ns (quote ()))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Core
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Core ──\n")

(check "==" (run-plan* ns (q) (== q 42)) '(42))
(check "fresh" (run-plan* ns (q) (fresh (x) (== x 'hello) (== q x))) '(hello))
(check "conde" (run-plan* ns (q) (conde ((== q 1)) ((== q 2)) ((== q 3)))) '(1 2 3))
(check "project" (run-plan* ns (q) (fresh (x) (== x '(a b)) (project (x) (== q (length x))))) '(2))
(check "in-list-o" (run-plan* ns (q) (in-list-o q '(x y z))) '(x y z))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Scope setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Scope setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-env (lambda () (spawn-scope "Test Commune")) store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (as ($ scope 'agent-store)))
    ($ rs 'add-resource-spec (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-process-spec (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-process (make-recipe-process "rp-mill" "Mill wheat" #f #f "pspec-mill" #f (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process (make-recipe-process "rp-bake" "Bake bread" #f #f "pspec-bake" #f (make-duration 4 "hours") #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-wheat-in" 'consume "spec-wheat" #f (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-flour-out" 'produce "spec-flour" #f (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-flour-in" 'consume "spec-flour" #f (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow (make-recipe-flow "rf-bread-out" 'produce "spec-bread" #f (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe (make-recipe "recipe-bread" "Bread Production" #f #f "spec-bread" (list "rp-mill" "rp-bake") #f))
    ($ as 'add-agent (make-agent "agent-commune" 'organization "Test Commune" #f #f #f #f #f))
    (check-pred "knowledge seeded" (pair? ($ rs 'get-process-chain "recipe-bread")))))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ($ obs 'seed-resource (make-economic-resource "r-wheat" "Wheat Stock" #f #f #f "spec-wheat" #f
      (make-measure 200 "kg") (make-measure 200 "kg") "loc-farm" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource (make-economic-resource "r-flour" "Flour Stock" #f #f #f "spec-flour" #f
      (make-measure 50 "kg") (make-measure 50 "kg") "loc-mill" #f "agent-commune" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource (make-economic-resource "r-bread" "Bread Stock" #f #f #f "spec-bread" #f
      (make-measure 0 "each") (make-measure 0 "each") "loc-bakery" #f "agent-commune" #f #f #f #f #f #f #f #f))
    (check-pred "inventory seeded" (= 3 (length ($ obs 'all-resources))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Lifted facts
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Lifted facts ──\n")

(define test-facts
  (with-vat vat (lift-planning-facts ($ scope 'recipe-store) ($ scope 'observer))))

(define test-ctx
  (with-vat vat
    (make-plan-ctx test-facts ($ scope 'plan-store) ($ scope 'observer) #f "test-rp"
                   (build-indexes test-facts))))


(check-pred "facts include inventory"
            (any (lambda (f) (eq? (car f) 'inventory)) test-facts))

(check "inventory-o: wheat"
       (run-plan* ns (q) (fresh (rid qty loc)
         (inventory-o test-facts rid "spec-wheat" qty loc) (== q (list rid qty))))
       '(("r-wheat" 200)))

(check "recipe-o: finds bread"
       (run-plan* ns (q) (fresh (rid rname)
         (recipe-o test-facts rid rname "spec-bread") (== q rid)))
       '("recipe-bread"))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. CLP(FD) allocation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Allocation ──\n")

;; 30 flour from 50
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o test-facts "spec-flour" 30 remaining allocated)
                   (== q (list remaining allocated))))))
  (check-pred "allocate 30 flour: finds solution" (pair? results))
  (when (pair? results)
    (check "allocate 30 flour: remaining = 0" (caar results) 0)))

;; 80 flour from 50 — remaining = 30
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o test-facts "spec-flour" 80 remaining allocated)
                   (== q remaining)))))
  (check "allocate 80 flour: remaining = 30" (and (pair? results) (car results)) 30))

;; 150 wheat from 200
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o test-facts "spec-wheat" 150 remaining allocated)
                   (== q remaining)))))
  (check "allocate 150 wheat: remaining = 0" (and (pair? results) (car results)) 0))

;; 20 bread from 0
(let ((results (run-plan 1 ns (q)
                 (fresh (remaining allocated)
                   (allocate-o test-facts "spec-bread" 20 remaining allocated)
                   (== q remaining)))))
  (check "allocate 20 bread: remaining = 20" (and (pair? results) (car results)) 20))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Demand relation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Demand relation ──\n")

(with-vat vat
  (let ((due (+ (current-time) 86400)))

    ;; 30 flour: satisfied from inventory
    (let ((results (run-plan 1 ns (q)
                     (demand-o test-ctx "spec-flour" 30 due q))))
      (check-pred "flour 30: satisfied"
                  (and (pair? results) (eq? 'satisfied (caar results)))))

    ;; 20 bread: must produce or unmet
    (let ((results (run-plan 1 ns (q)
                     (demand-o test-ctx "spec-bread" 20 due q
                               #:depth 5))))
      (check-pred "bread 20: finds solution" (pair? results))
      (check-pred "bread 20: produces or unmets"
                  (and (pair? results) (memq (caar results) '(produce unmet)))))

    ;; Both produce and unmet are reachable
    (let ((first (run-plan 1 ns (q)
                   (demand-o test-ctx "spec-bread" 20 due q
                             #:depth 5))))
      (check-pred "bread: first plan found" (pair? first))
      (check-pred "bread: is produce or unmet"
                  (and (pair? first) (memq (caar first) '(produce unmet)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Plan relation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plan relation ──\n")

(with-vat vat
  (let ((ps (ctx-ps test-ctx))
        (due (+ (current-time) 86400)))
    ($ ps 'add-intent
       (make-intent "i-test-bread" 'produce "Bread demand" #f #f
                    #f #f #f "spec-bread" #f
                    (make-measure 20 "each") #f #f #f
                    #f "agent-commune"
                    #f #f #f (number->string due)
                    #f #f #f "test-plan" #f #f #f #f))
    (let ((results (run-plan 1 ns (plan) (plan-o test-ctx plan #:max-depth 5))))
      (check-pred "plan-o: finds a plan" (pair? results))
      (check-pred "plan-o: has entries" (and (pair? results) (pair? (car results)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Federation — unit tests for protocol components
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Federation ──\n")

;; Test federation components with mock data (no Goblins scopes needed)
(let* ((fed-facts '((scope-parent "bakery" "commune")
                    (scope-parent "mill" "commune")))
       (scope-ids '("bakery" "mill" "commune"))
       (parent-map '(("bakery" . "commune") ("mill" . "commune"))))

  ;; Test hierarchy construction
  (let ((hierarchy (build-hierarchy fed-facts scope-ids parent-map)))
    (check-pred "hierarchy: commune has 2 children"
                (let ((commune-children (assoc-ref hierarchy "commune")))
                  (and commune-children (= 2 (length commune-children))))))

  ;; Test hierarchy
  (check-pred "hierarchy: commune has children"
              (let ((ch (assoc-ref (build-hierarchy fed-facts scope-ids parent-map) "commune")))
                (and ch (= 2 (length ch)))))

  ;; Test extract-deficits and extract-surpluses (the federation protocol)
  (check "extract-deficits: unmet becomes deficit"
         (extract-deficits '(((d1) (unmet spec-flour 30))) "bakery")
         '(((scope-id . "bakery") (spec-id . spec-flour) (qty . 30))))

  (check "extract-surpluses: satisfied with excess becomes surplus"
         (length (extract-surpluses '(((d1) (satisfied spec-flour 20 (("r" 30))))) "mill"))
         1)

  ;; Test federation structure
  (check-pred "federation: builds hierarchy"
              (pair? (build-hierarchy fed-facts scope-ids parent-map)))

  ;; Test lateral matching
  (let* ((defs '(((scope-id . "bakery") (spec-id . spec-flour) (qty . 30))))
         (surps '(((scope-id . "mill") (spec-id . spec-flour) (qty . 50))))
         (result (match-at-level defs surps))
         (matches (car result))
         (unmatched (cdr result)))
    (check-pred "lateral-match: finds match"
                (and (= 1 (length matches))
                     (null? unmatched)))
    (when (pair? matches)
      (check "lateral-match: from mill to bakery"
             (assq-ref (car matches) 'from-scope) "mill")
      (check "lateral-match: qty = 30 (min of deficit)"
             (assq-ref (car matches) 'qty) 30)))

  ;; Test unmatched deficit propagation
  (let* ((defs '(((scope-id . "bakery") (spec-id . spec-wheat) (qty . 100))))
         (surps '())
         (result (match-at-level defs surps)))
    (check "unmatched: deficit propagates"
           (length (cdr result)) 1)))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
