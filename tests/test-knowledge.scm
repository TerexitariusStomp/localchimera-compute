;;; test-knowledge.scm — tests for (playnet kanren), (playnet hyperarc), (playnet knowledge)
;;; Run with:  guile -L module tests/test-knowledge.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet kanren)
             (playnet hyperarc)
             (playnet knowledge)
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

(define-syntax check-error
  (syntax-rules ()
    ((_ label body ...)
     (check label
            (catch #t
              (lambda () body ... #f)
              (lambda (key . args) #t))
            #t))))

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
       (let ((s (unify '(a b) '(a b) empty-subst)))
         s)
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

;; Occurs check: (== x (list x)) should fail, not loop
(check "occurs check prevents circular substitution"
       (run* (q)
         (fresh (x)
           (== x (list x))
           (== q 'should-not-reach)))
       '())

;; Reification: unbound vars appear as _.0, _.1, etc.
(check "reification of unbound variable"
       (run* (q) succeed)
       '(_.0))

(check "reification of pair with unbound vars"
       (run* (q)
         (fresh (a b)
           (== q (list a b))))
       '((_.0 _.1)))

;; Recursive relation with suspension: (fives x) should not diverge
(define (fives x)
  (conde
   ((== x 5))
   ((fives x))))

(check "recursive relation with suspension"
       (run 3 (q) (fives q))
       '(5 5 5))

;; State-threaded counter: nested run calls should not interfere
(check "nested run calls produce consistent results"
       (run* (q)
         (== q (run* (inner) (== inner 'ok))))
       '((ok)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 2: Hyperarc data structures
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Hyperarc data structures ──\n")

(let ((n (make-node 'n1 'atom)))
  (check "make-node creates tagged list"
         (car n)
         'node)
  (check "node? recognizes node"
         (node? n)
         #t)
  (check "node-id"
         (node-id n)
         'n1)
  (check "node-value"
         (node-value n)
         'atom)
  (check "node-meta default"
         (node-meta n)
         '()))

(let ((n (make-node 'n2 'atom '((tag . important)))))
  (check "node-meta with data"
         (node-meta n)
         '((tag . important))))

(check "node? rejects non-node"
       (node? '(foo bar))
       #f)

(let* ((n1 (make-node 'n1 'heat))
       (n2 (make-node 'n2 'expansion))
       (ha (make-hyperarc 'ha1 '((label . "causes")) (list n1 n2))))
  (check "hyperarc? recognizes hyperarc"
         (hyperarc? ha)
         #t)
  (check "hyperarc-id"
         (hyperarc-id ha)
         'ha1)
  (check "hyperarc-meta"
         (hyperarc-meta ha)
         '((label . "causes")))
  (check "hyperarc-nodes count"
         (length (hyperarc-nodes ha))
         2))

(let* ((n1 (make-node 'n1 'heat))
       (n2 (make-node 'n2 'expansion))
       (ha (make-hyperarc 'ha1 '() (list n1 n2)))
       (mg (make-metagraph 'mg1 '((domain . "physics")) (list ha))))
  (check "metagraph? recognizes metagraph"
         (metagraph? mg)
         #t)
  (check "metagraph-id"
         (metagraph-id mg)
         'mg1)
  (check "metagraph-arcs count"
         (length (metagraph-arcs mg))
         1)
  (check "metagraph-all-nodes"
         (length (metagraph-all-nodes mg))
         2)
  (check "metagraph-node-values"
         (metagraph-node-values mg)
         '(heat expansion)))

(let* ((mg1 (make-metagraph 'mg1 '() '()))
       (mg2 (make-metagraph 'mg2 '() '()))
       (kb (make-kb `((cause . ,mg1) (tax . ,mg2)))))
  (check "kb? recognizes kb"
         (kb? kb)
         #t)
  (check "kb-keys"
         (kb-keys kb)
         '(cause tax))
  (check "kb-ref found"
         (metagraph-id (kb-ref kb 'cause))
         'mg1)
  (check "kb-ref not found"
         (kb-ref kb 'nope)
         #f))

(let* ((mg (make-metagraph 'mg3 '() '()))
       (kb (make-kb '()))
       (kb2 (kb-add kb 'test mg)))
  (check "kb-add"
         (kb-keys kb2)
         '(test)))

(let* ((n1 (make-node 'n1 'a))
       (n2 (make-node 'n2 'b))
       (ha (make-hyperarc 'ha1 '() (list n1 n2))))
  (check "hyperarc-find-node found"
         (node-value (hyperarc-find-node ha 'n1))
         'a)
  (check "hyperarc-find-node not found"
         (hyperarc-find-node ha 'n99)
         #f))

;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 3: Knowledge base relations
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Knowledge base relations ──\n")

;; Build a sample knowledge base
(define sample-kb
  (make-kb
   `((causality .
      ,(make-metagraph 'mg-cause
        '((domain . "physics"))
        (list
         (make-hyperarc 'ha1 '((label . "heat-expansion"))
           (list (make-node 'n1 'heat)
                 (make-node 'n2 'expansion)))
         (make-hyperarc 'ha2 '((label . "expansion-cracking"))
           (list (make-node 'n3 'expansion)
                 (make-node 'n4 'cracking))))))
     (taxonomy .
      ,(make-metagraph 'mg-tax
        '((domain . "biology"))
        (list
         (make-hyperarc 'ha3 '()
           (list (make-node 'n5 'cat)
                 (make-node 'n6 'mammal)))
         (make-hyperarc 'ha4 '()
           (list (make-node 'n7 'mammal)
                 (make-node 'n8 'animal)))))))))

(check "kb-o: enumerate domain names"
       (sort (run* (q) (kb-o sample-kb q (var 999)))
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(causality taxonomy))

(check "arcs-of-o: count arcs in causality"
       (length (run* (q)
                 (fresh (mg)
                   (kb-o sample-kb 'causality mg)
                   (arcs-of-o mg q))))
       2)

(check "arc-nodes-o: find nodes in ha1"
       (length (run* (q)
                 (fresh (mg arc)
                   (kb-o sample-kb 'causality mg)
                   (arcs-of-o mg arc)
                   (fresh (aid ameta anodes)
                     (hyperarc-o arc aid ameta anodes)
                     (== aid 'ha1))
                   (arc-nodes-o arc q))))
       2)

(check "node-value-matches-o: find all node values in causality"
       (sort (run* (q)
               (fresh (node)
                 (node-value-matches-o sample-kb node q)))
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(animal cat cracking expansion expansion heat mammal mammal))

(check "node-value-matches-o: find specific value"
       (run* (q)
         (fresh (node)
           (node-value-matches-o sample-kb node 'heat)
           (== q 'found)))
       '(found))

(check "related-by-o: heat and expansion in same arc"
       (length (run* (q)
                 (fresh (n1 n2 id1 id2 m1 m2)
                   (related-by-o sample-kb 'causality n1 n2)
                   (node-o n1 id1 'heat m1)
                   (node-o n2 id2 'expansion m2)
                   (== q 'yes))))
       1)

;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 4: Transitive closure & proof traces
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Transitive closure & proof traces ──\n")

(check "transitive-o: base case (same arc)"
       (run* (trace)
         (transitive-o sample-kb 'causality 'heat 'expansion trace))
       '((heat expansion)))

(check "transitive-o: one step (heat -> expansion -> cracking)"
       (member '(heat expansion cracking)
               (run* (trace)
                 (transitive-o sample-kb 'causality 'heat 'cracking trace)))
       '((heat expansion cracking)))

(check "transitive-o: taxonomy base (cat -> mammal)"
       (run* (trace)
         (transitive-o sample-kb 'taxonomy 'cat 'mammal trace))
       '((cat mammal)))

(check "transitive-o: taxonomy chain (cat -> mammal -> animal)"
       (member '(cat mammal animal)
               (run* (trace)
                 (transitive-o sample-kb 'taxonomy 'cat 'animal trace)))
       '((cat mammal animal)))

(check "proof-length: base case"
       (proof-length '(heat expansion))
       1)

(check "proof-length: two steps"
       (proof-length '(heat expansion cracking))
       2)

(check "proof-steps: identity"
       (proof-steps '(cat mammal animal))
       '(cat mammal animal))

(check "transitive-o: no path returns empty"
       (run* (trace)
         (transitive-o sample-kb 'causality 'heat 'animal trace))
       '())

;;; ════════════════════════════════════════════════════════════════════════════
;;; Section 5: Pattern matching via unification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Pattern matching via unification ──\n")

;; Build a KB with structured node values for pattern matching
(define pattern-kb
  (make-kb
   `((concepts .
      ,(make-metagraph 'mg-pat '()
        (list
         (make-hyperarc 'ha-p1 '()
           (list (make-node 'p1 '(person . alice) '((role . admin)))
                 (make-node 'p2 '(person . bob))))
         (make-hyperarc 'ha-p2 '()
           (list (make-node 'p3 '(action . login))
                 (make-node 'p4 '(person . alice))))))))))

(check "pattern match: extract all person names"
       (sort (run* (name)
               (fresh (node)
                 (node-value-matches-o pattern-kb node (cons 'person name))))
             (lambda (a b) (string<? (symbol->string a) (symbol->string b))))
       '(alice alice bob))

(check "pattern match: find actions"
       (run* (act)
         (fresh (node)
           (node-value-matches-o pattern-kb node (cons 'action act))))
       '(login))

(check "node-meta-has-o: find admin nodes"
       (run* (q)
         (fresh (node)
           (node-meta-has-o pattern-kb node 'role 'admin)
           (fresh (nid nval nmeta)
             (node-o node nid nval nmeta)
             (== q nval))))
       '((person . alice)))

;; Nested metagraph as node value
(define nested-kb
  (let ((inner-mg (make-metagraph 'mg-inner '()
                    (list (make-hyperarc 'ha-inner '()
                            (list (make-node 'ni1 'deep-value)))))))
    (make-kb
     `((outer .
        ,(make-metagraph 'mg-outer '()
          (list (make-hyperarc 'ha-outer '()
                  (list (make-node 'no1 inner-mg))))))))))

(check "nested metagraph: outer node is a metagraph"
       (run* (q)
         (fresh (node nid nmeta mg-val)
           (node-value-matches-o nested-kb node mg-val)
           (metagraph-o mg-val q (var 998) (var 997))))
       '(mg-inner))

;;; ════════════════════════════════════════════════════════════════════════════
;;; Summary
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
