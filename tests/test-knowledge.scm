;;; test-knowledge.scm — tests for (playnet kanren), (playnet knowledge), (playnet system-kb)
;;; Run with:  guile -L module tests/test-knowledge.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet kanren)
             (playnet knowledge)
             (playnet system-kb)
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


;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 1: miniKanren core
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── miniKanren core ──\n")

(check "unify equal atoms"
       (unify 'a 'a empty-subst)
       '())

(check "unify var with atom"
       (let ((s (unify (var 99) 'hello empty-subst)))
         (walk (var 99) s))
       'hello)

(check "unify two vars"
       (let ((s (unify (var 1) (var 2) empty-subst)))
         (pair? s))
       #t)

(check "unify pairs"
       (unify '(a b) '(a b) empty-subst)
       '())

(check "unify mismatch"
       (unify 'a 'b empty-subst)
       #f)

(check "unify var in pair"
       (let* ((x (var 50))
              (s (unify (list x 'b) '(a b) empty-subst)))
         (walk x s))
       'a)

(check "run* with =="
       (run* (q) (== q 42))
       '(42))

(check "run* fresh introduces variable"
       (run* (q)
         (fresh (x)
           (== x 'hello)
           (== q x)))
       '(hello))

(check "conde produces multiple results"
       (run* (q)
         (conde
          ((== q 1))
          ((== q 2))
          ((== q 3))))
       '(1 2 3))

(check "run with bound"
       (run 2 (q)
         (conde
          ((== q 'a))
          ((== q 'b))
          ((== q 'c))))
       '(a b))

(check "appendo forward"
       (run* (q) (appendo '(a b) '(c d) q))
       '((a b c d)))

(check "appendo backward: split count"
       (length (run* (q)
                 (fresh (x y)
                   (appendo x y '(1 2 3))
                   (== q (list x y)))))
       4)

(check "membero finds element"
       (run* (q) (membero 'b '(a b c)) (== q 'found))
       '(found))

(check "membero generates all elements"
       (run* (q) (membero q '(x y z)))
       '(x y z))

(check "occurs check prevents circular substitution"
       (run* (q)
         (fresh (x)
           (== x (list x))
           (== q 'should-not-reach)))
       '())

(check "reification of unbound variable"
       (run* (q) succeed)
       '(_.0))

(check "reification of pair with unbound vars"
       (run* (q)
         (fresh (a b)
           (== q (list a b))))
       '((_.0 _.1)))

(define (fives x)
  (conde
   ((== x 5))
   ((fives x))))

(check "recursive relation with suspension"
       (run 3 (q) (fives q))
       '(5 5 5))

(check "nested run calls produce consistent results"
       (run* (q)
         (== q (run* (inner) (== inner 'ok))))
       '((ok)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 2: in-list-o
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── in-list-o ──\n")

(check "in-list-o: find element"
       (run* (q) (in-list-o 'b '(a b c)) (== q 'found))
       '(found))

(check "in-list-o: generate all"
       (run* (q) (in-list-o q '(x y z)))
       '(x y z))

(check "in-list-o: empty list fails"
       (run* (q) (in-list-o q '()))
       '())

(check "in-list-o: pattern matching"
       (run* (q)
         (fresh (a b)
           (in-list-o `(pair ,a ,b) '((pair 1 2) (pair 3 4)))
           (== q (list a b))))
       '((1 2) (3 4)))

(check "in-list-o: partial ground"
       (run* (q)
         (in-list-o `(pair ,q 2) '((pair 1 2) (pair 3 4))))
       '(1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 3: Transitive closure
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Transitive closure ──\n")

;; Simple edge relation for testing
(define test-facts
  '((edge heat expansion)
    (edge expansion cracking)
    (edge cat mammal)
    (edge mammal animal)))

(define (test-edge-o from to)
  (in-list-o `(edge ,from ,to) test-facts))

(check "transitive-o: base case"
       (run* (trace)
         (transitive-o test-edge-o 'heat 'expansion trace))
       '((heat expansion)))

(check "transitive-o: two steps"
       (member '(heat expansion cracking)
               (run* (trace)
                 (transitive-o test-edge-o 'heat 'cracking trace)))
       '((heat expansion cracking)))

(check "transitive-o: taxonomy base"
       (run* (trace)
         (transitive-o test-edge-o 'cat 'mammal trace))
       '((cat mammal)))

(check "transitive-o: taxonomy chain"
       (member '(cat mammal animal)
               (run* (trace)
                 (transitive-o test-edge-o 'cat 'animal trace)))
       '((cat mammal animal)))

(check "proof-length: base"
       (proof-length '(heat expansion))
       1)

(check "proof-length: two steps"
       (proof-length '(heat expansion cracking))
       2)

(check "proof-steps: identity"
       (proof-steps '(cat mammal animal))
       '(cat mammal animal))

(check "transitive-o: no path"
       (run* (trace)
         (transitive-o test-edge-o 'heat 'animal trace))
       '())


;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 4: System knowledge base
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── System KB ──\n")

(check "depends-on-o: browser depends on evaluator"
       (run* (q) (depends-on-o 'browser 'evaluator) (== q 'yes))
       '(yes))

(check "depends-on-o: what does browser depend on?"
       (sort (run* (q) (depends-on-o 'browser q))
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(actors evaluator kanren))

(check "depends-on-o: what depends on goblins?"
       (let ((deps (run* (q) (depends-on-o q 'goblins))))
         (and (memq 'actors deps) (memq 'planner deps) #t))
       #t)

(check "file-of-o: actors file"
       (run* (q) (file-of-o 'actors q))
       '("module/playnet/actors.scm"))

(check "file-of-o: browser has multiple files"
       (>= (length (run* (q) (file-of-o 'browser q))) 3)
       #t)

(check "provides-o: actors provides state"
       (run* (q) (provides-o 'actors 'state) (== q 'yes))
       '(yes))

(check "provides-o: what does goblins provide?"
       (sort (run* (q) (provides-o 'goblins q))
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(actors capability-security ocapn persistence))

(check "layer-o: browser is a layer"
       (pair? (run 1 (q) (layer-o 'browser) (== q #t)))
       #t)

(check "trigger-chain-o: push-to-main reaches guix"
       (let ((results (run 5 (proof)
                        (trigger-chain-o 'push-to-main 'guix proof))))
         (and (pair? results)
              (eq? 'push-to-main (caar results))))
       #t)

(check "query-depends: pure Scheme"
       (sort (query-depends 'browser)
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(actors evaluator kanren))

(check "query-provides: pure Scheme"
       (sort (query-provides 'kanren)
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(logic-programming relational-queries unification))

(check "query-what-changes: push-to-main triggers cascade"
       (let ((changed (query-what-changes 'push-to-main)))
         (and (memq 'guix-deploy changed) (memq 'guix changed) #t))
       #t)


;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 5: Bidirectional queries
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Bidirectional queries ──\n")

;; Same relation, different directions
(check "forward: what does evaluator depend on?"
       (run* (q) (depends-on-o 'evaluator q))
       '(actors))

(check "backward: what depends on actors?"
       (let ((deps (run* (q) (depends-on-o q 'actors))))
         (and (memq 'browser deps) (memq 'evaluator deps) #t))
       #t)

(check "forward: what files does planner have?"
       (>= (length (run* (q) (file-of-o 'planner q))) 1)
       #t)

(check "backward: what layer owns kanren.scm?"
       (run* (q) (file-of-o q "module/playnet/kanren.scm"))
       '(kanren))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
