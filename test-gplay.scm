;;; test-gplay.scm — tests for (xorg gplay)
;;; Run with:  guile -L module test-gplay.scm

(add-to-load-path "module")
(use-modules (xorg gplay)
             (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins persistence-store memory)
             (ice-9 receive))

;;; ── Harness ─────────────────────────────────────────────────────────────────

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

;;; ── Base bindings ───────────────────────────────────────────────────────────

(define test-base-bindings
  `((+       . ,+)
    (-       . ,-)
    (*       . ,*)
    (>       . ,>)
    (<       . ,<)
    (=       . ,=)
    (equal?  . ,equal?)
    (eqv?    . ,eqv?)
    (not     . ,not)
    (null?   . ,null?)
    (cons    . ,cons)
    (car     . ,car)
    (cdr     . ,cdr)
    (list    . ,list)
    (length  . ,length)))

;;; ── Shared test vat ─────────────────────────────────────────────────────────

(define test-vat (spawn-vat))

;;; Convenience: evaluate in org with default expressor
(define (ev expr org)
  (evaluate expr org '() ($ org 'current-expressor)))
(define (ev/locals expr org locals)
  (evaluate expr org locals ($ org 'current-expressor)))

;;; ── 1. Expressor accessors ─────────────────────────────────────────────────

(display "\n── 1. expressor accessors ──\n")

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (sealer (ev '(defexpressor 'alice "alice-key") org))
         (id ($ org 'authenticate-sealer sealer)))
    (check "authenticate-sealer returns valid id"
           (and id #t) #t)
    (check "expressor? recognizes authenticated id"
           ($ org 'expressor? id) #t)
    (check "expressor-name returns the name symbol"
           ($ org 'expressor-name id) 'alice)
    (check "expressor-key returns the key string"
           ($ org 'expressor-key id) "alice-key")))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "expressor-name on non-expressor returns #f"
           ($ org 'expressor-name 'not-an-expressor) #f)
    (check "expressor-key on non-expressor returns #f"
           ($ org 'expressor-key 'not-an-expressor) #f)))

;;; ── 2. Lambda closures ─────────────────────────────────────────────────────

(display "\n── 2. lambda closures ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'outer 99) org)
    (let ((fn (ev '(lambda (x) (+ x outer)) org)))
      (check "lambda accesses org-level binding" (fn 1) 100))))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'a 10) org)
    (ev '(modify! 'b 20) org)
    (let ((fn (ev '(lambda (x) (+ x a b)) org)))
      (check "lambda accesses multiple org-level bindings" (fn 5) 35))))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'x 100) org)
    (let ((fn (ev '(lambda (x) x) org)))
      (check "parameter shadows org-level binding of same name" (fn 7) 7))))

;;; ── 3. modify! and lookup ──────────────────────────────────────────────────

(display "\n── 3. modify! and lookup ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'x 42) org)
    (check "modify! stores value" (ev 'x org) 42)))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'x 42) org)
    (ev '(modify! 'x 99) org)
    (check "later modify! shadows earlier" (ev 'x org) 99)))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check-error "unbound variable signals error"
      (ev 'undefined-var org))))

;;; ── 4. Validator pre/post bindings ─────────────────────────────────────────

(display "\n── 4. validator pre/post bindings ──\n")

;; Permissive validator
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(enact! (lambda (e n v pre post) #t)) org)
    (ev '(modify! 'y 7) org)
    (check "modify! under permissive validator succeeds"
           (ev 'y org) 7)))

;; Validator that rejects its own installation
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check-error "validator returning #f rejects its own enact!"
      (ev '(enact! (lambda (e n v pre post) #f)) org))))

;; Direct test: validator receives correct pre and post bindings
(with-vat test-vat
  (let* ((pre-seen  #f)
         (post-seen #f)
         (org (make-initial-org test-base-bindings)))
    ;; Install capturing validator directly via $ call
    (let* ((capturing (lambda (expressor name value pre post)
                        (set! pre-seen  pre)
                        (set! post-seen post)
                        #t))
           (version (next-version))
           (entry (list version ($ org 'current-expressor)
                        '(test) ($ org 'head-version))))
      ($ org 'enact! '(lambda (e n v pre post) #t) capturing entry))
    ;; Now modify
    (ev '(modify! 'x 42) org)
    (check "validator receives pre-bindings without x"
           (assq 'x pre-seen) #f)
    (check "validator receives post-bindings with x=42"
           (assq 'x post-seen) '(x . 42))
    (check "pre and post bindings are distinct"
           (equal? pre-seen post-seen) #f)))

;;; ── 5. as / identity switching ─────────────────────────────────────────────

(display "\n── 5. as / identity switching ──\n")

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (carol-seal (ev '(defexpressor 'carol "carol-key") org)))
    (ev/locals '(as carol (modify! 'greeting "hi")) org `((carol . ,carol-seal)))
    (check "defexpressor + as round-trip works"
           (ev 'greeting org) "hi")))

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (alice-seal (ev '(defexpressor 'alice "key-a") org)))
    (ev/locals '(as alice (modify! 'greeting "hello")) org `((alice . ,alice-seal)))
    (let ((entry (car ($ org 'history))))
      (check "modify! value is stored under as"
             (ev 'greeting org) "hello")
      (check "history entry records alice as the acting expressor"
             ($ org 'expressor-name (cadr entry)) 'alice))))

;; modify! on fresh org records genesis
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(modify! 'a 1) org)
    (let ((entry (car ($ org 'history))))
      (check "modify! without as records genesis"
             ($ org 'expressor-name (cadr entry)) 'genesis))))

;; as with invalid credential signals error
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check-error "as with invalid credential signals error"
      (ev '(as 'not-a-sealer (modify! 'x 1)) org))))

;;; ── 6. expressor-name in history ───────────────────────────────────────────

(display "\n── 6. expressor-name in history ──\n")

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (bob-seal (ev '(defexpressor 'bob "key-b") org)))
    (ev/locals '(as bob (modify! 'flag #t)) org `((bob . ,bob-seal)))
    (let ((entry (car ($ org 'history))))
      (check "history entry holds an expressor id"
             ($ org 'expressor? (cadr entry)) #t)
      (check "expressor-name returns the symbol 'bob"
             ($ org 'expressor-name (cadr entry)) 'bob)
      (check "result is a symbol, not a list"
             (symbol? ($ org 'expressor-name (cadr entry))) #t))))

;;; ── 7. Lambda carries caller's authority ───────────────────────────────────

(display "\n── 7. logic vs authority ──\n")

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (alice-seal (ev '(defexpressor 'alice "key-a") org))
         (bob-seal (ev '(defexpressor 'bob "key-b") org)))
    ;; Alice defines the modifier
    (ev/locals '(as alice (modify! 'modifier (lambda (x) (modify! 'target x)))) org
               `((alice . ,alice-seal)))
    ;; Bob calls it
    (ev/locals '(as bob (modifier 42)) org `((bob . ,bob-seal)))
    (let ((entry (car ($ org 'history))))
      (check "value is stored correctly via cross-identity call"
             (ev 'target org) 42)
      (check "lambda called by bob attributes modify! to bob, not alice"
             ($ org 'expressor-name (cadr entry)) 'bob))))

;;; ── 8. begin ───────────────────────────────────────────────────────────────

(display "\n── 8. begin ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "begin returns last value"
           (ev '(begin 1 2 3) org) 3)

    (check "begin with single expression"
           (ev '(begin 42) org) 42)

    ;; begin with mutations
    (ev '(begin (modify! 'a 10) (modify! 'b 20)) org)
    (check "begin: a is set" (ev 'a org) 10)
    (check "begin: b is set" (ev 'b org) 20)))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "begin mutation + value: returns last value"
           (ev '(begin (modify! 'a 10) (+ a 5)) org) 15)))

;;; ── 9. let ─────────────────────────────────────────────────────────────────

(display "\n── 9. let ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "let basic binding"
           (ev '(let ((x 10)) x) org) 10)

    (check "let multiple bindings"
           (ev '(let ((x 10) (y 20)) (+ x y)) org) 30)

    (ev '(modify! 'outer 100) org)
    (check "let body uses org-level bindings"
           (ev '(let ((x 5)) (+ x outer)) org) 105)

    (ev '(modify! 'x 1) org)
    (check "let bindings are parallel (not sequential)"
           (ev '(let ((x 10) (y x)) y) org) 1)

    (check "let with multi-body (implicit begin)"
           (ev '(let ((x 1) (y 2)) (+ x 0) (+ x y)) org) 3)))

;;; ── 10. let* ───────────────────────────────────────────────────────────────

(display "\n── 10. let* ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "let* basic"
           (ev '(let* ((x 10)) x) org) 10)

    (check "let* sequential bindings"
           (ev '(let* ((x 10) (y (+ x 5))) y) org) 15)

    (check "let* three bindings"
           (ev '(let* ((a 1) (b (+ a 1)) (c (+ a b))) c) org) 3)

    (check "let* with multi-body"
           (ev '(let* ((x 10)) (+ x 0) (+ x 5)) org) 15)))

;;; ── 11. define ─────────────────────────────────────────────────────────────

(display "\n── 11. define ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define x 42) org)
    (check "define stores value" (ev 'x org) 42)
    (check "define records in history"
           (let ((entry (car ($ org 'history))))
             (equal? (caddr entry) '(define x 42)))
           #t)))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define (square x) (* x x)) org)
    (check "define function shorthand"
           (ev '(square 5) org) 25)))

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(begin (define a 10) (define b 20)) org)
    (check "define in begin: a" (ev 'a org) 10)
    (check "define in begin: b" (ev 'b org) 20)))

;;; ── 12. cond ───────────────────────────────────────────────────────────────

(display "\n── 12. cond ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "cond basic true"
           (ev '(cond (#t 42)) org) 42)

    (check "cond first false, second true"
           (ev '(cond (#f 1) (#t 2)) org) 2)

    (check "cond with else"
           (ev '(cond (#f 1) (else 99)) org) 99)

    (check "cond with computed test"
           (ev '(cond ((> 3 2) "yes") (else "no")) org) "yes")

    (check "cond no-body clause returns test value"
           (ev '(cond (42)) org) 42)

    (check "cond multi-expr body"
           (ev '(cond (#t 1 2 3)) org) 3)))

;;; ── 13. and / or ───────────────────────────────────────────────────────────

(display "\n── 13. and / or ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "and no args" (ev '(and) org) #t)
    (check "and single true" (ev '(and 42) org) 42)
    (check "and single false" (ev '(and #f) org) #f)
    (check "and returns last true" (ev '(and 1 2 3) org) 3)
    (check "and short-circuits on false" (ev '(and 1 #f 3) org) #f)

    (check "or no args" (ev '(or) org) #f)
    (check "or single true" (ev '(or 42) org) 42)
    (check "or single false" (ev '(or #f) org) #f)
    (check "or returns first true" (ev '(or #f #f 3) org) 3)
    (check "or short-circuits on true" (ev '(or 1 2 3) org) 1)))

;;; ── 14. two-branch if ──────────────────────────────────────────────────────

(display "\n── 14. two-branch if ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "two-branch if true"
           (ev '(if #t 42) org) 42)

    (check "two-branch if false returns unspecified"
           (ev '(if #f 42) org) (if #f #f))))

;;; ── 15. lambda multi-body ──────────────────────────────────────────────────

(display "\n── 15. lambda multi-body ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (let ((fn (ev '(lambda (x) (+ x 0) (+ x 1)) org)))
      (check "lambda with two body expressions" (fn 10) 11))))

;;; ── 16. Org isolation ──────────────────────────────────────────────────────

(display "\n── 16. org isolation ──\n")

(with-vat test-vat
  (let ((org-a (make-initial-org test-base-bindings))
        (org-b (make-initial-org test-base-bindings)))
    (ev '(modify! 'x 100) org-a)
    (ev '(modify! 'x 200) org-b)
    (check "org-a has x=100" (ev 'x org-a) 100)
    (check "org-b has x=200" (ev 'x org-b) 200)
    (ev '(modify! 'only-in-b 42) org-b)
    (check "only-in-b exists in org-b"
           (ev 'only-in-b org-b) 42)
    (check-error "only-in-b does not exist in org-a"
      (ev 'only-in-b org-a))))

;;; ── 17. Named let ──────────────────────────────────────────────────────────

(display "\n── 17. named let ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "named let: basic loop (sum 0..5)"
           (ev '(let loop ((i 0) (acc 0))
                  (if (> i 5) acc (loop (+ i 1) (+ acc i))))
               org)
           15)

    (check "named let: countdown accumulator"
           (ev '(let loop ((n 5) (acc (list)))
                  (if (= n 0) acc (loop (- n 1) (cons n acc))))
               org)
           '(1 2 3 4 5))

    (ev '(modify! 'base 100) org)
    (check "named let: accesses org-level bindings"
           (ev '(let loop ((i 0))
                  (if (= i 3) base (loop (+ i 1))))
               org)
           100)))

;;; ── 18. letrec ─────────────────────────────────────────────────────────────

(display "\n── 18. letrec ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "letrec: factorial"
           (ev '(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))))
                  (fact 5))
               org)
           120)

    (check "letrec: mutual recursion (even?/odd?)"
           (ev '(letrec ((my-even? (lambda (n) (if (= n 0) #t (my-odd? (- n 1)))))
                         (my-odd?  (lambda (n) (if (= n 0) #f (my-even? (- n 1))))))
                  (list (my-even? 4) (my-odd? 3) (my-even? 3)))
               org)
           '(#t #t #f))))

;;; ── 19. Variadic lambda ────────────────────────────────────────────────────

(display "\n── 19. variadic lambda ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "variadic lambda: (lambda args ...) collects all"
           (let ((fn (ev '(lambda args args) org)))
             (fn 1 2 3))
           '(1 2 3))

    (check "variadic lambda: (lambda (a . rest) ...) splits"
           (let ((fn (ev '(lambda (a . rest) rest) org)))
             (fn 1 2 3))
           '(2 3))

    (check "variadic lambda: (lambda (a . rest) ...) first arg"
           (let ((fn (ev '(lambda (a . rest) a) org)))
             (fn 1 2 3))
           1)

    (ev '(define (my-list . args) args) org)
    (check "define shorthand with rest params"
           (ev '(my-list 1 2 3) org)
           '(1 2 3))))

;;; ── 20. when / unless ──────────────────────────────────────────────────────

(display "\n── 20. when / unless ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "when: true branch executes"
           (ev '(when #t 42) org) 42)

    (check "when: false branch returns unspecified"
           (ev '(when #f 42) org) (if #f #f))

    (check "when: multi-body"
           (ev '(when #t 1 2 3) org) 3)

    (check "unless: false branch executes"
           (ev '(unless #f 42) org) 42)

    (check "unless: true branch returns unspecified"
           (ev '(unless #t 42) org) (if #f #f))))

;;; ── 21. case ───────────────────────────────────────────────────────────────

(display "\n── 21. case ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "case: matching datum"
           (ev '(case (+ 1 1)
                  ((1) "one")
                  ((2) "two")
                  ((3) "three"))
               org)
           "two")

    (check "case: else clause"
           (ev '(case 99
                  ((1) "one")
                  (else "other"))
               org)
           "other")

    (check "case: no match returns unspecified"
           (ev '(case 99 ((1) "one") ((2) "two")) org)
           (if #f #f))

    (check "case: multiple datums per clause"
           (ev '(case 3
                  ((1 2) "low")
                  ((3 4) "mid")
                  (else "high"))
               org)
           "mid")))

;;; ── 22. do ─────────────────────────────────────────────────────────────────

(display "\n── 22. do ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (check "do: counting loop"
           (ev '(do ((i 0 (+ i 1)))
                    ((= i 5) i))
               org)
           5)

    (check "do: accumulation loop"
           (ev '(do ((i 0 (+ i 1))
                     (acc 0 (+ acc i)))
                    ((= i 5) acc))
               org)
           10)))

;;; ── 23. NEW: Org-level bindings are live ───────────────────────────────────

(display "\n── 23. org-level bindings are live ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define x 10) org)
    (let ((get-x (ev '(lambda () x) org)))
      (ev '(modify! 'x 20) org)
      (check "lambda sees updated org-level binding"
             (get-x) 20))))

;;; ── 24. NEW: Rollback ─────────────────────────────────────────────────────

(display "\n── 24. rollback ──\n")

;; Basic rollback: define x, define y, rollback to x-only state
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define x 10) org)
    (let ((v1 ($ org 'head-version)))  ;; version after x=10
      (ev '(define y 20) org)
      (check "pre-rollback: y exists" (ev 'y org) 20)
      (ev `(rollback! ,v1) org)
      (check "post-rollback: x restored" (ev 'x org) 10)
      (check-error "post-rollback: y no longer bound"
        (ev 'y org)))))

;; Rollback does not alter history
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define a 1) org)
    (ev '(define b 2) org)
    (let ((hist-len-before (length ($ org 'history)))
          (v1 (car (cadr ($ org 'history)))))  ;; version of 'a' define
      (ev `(rollback! ,v1) org)
      (check "rollback does not alter history"
             (length ($ org 'history)) hist-len-before))))

;; Rollback with validator rejection
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    ;; Install validator that rejects rollback
    (let* ((reject-rollback
            (lambda (e n v pre post)
              (not (eq? n 'rollback))))
           (version (next-version))
           (entry (list version ($ org 'current-expressor)
                        '(test) ($ org 'head-version))))
      ($ org 'enact! '(lambda (e n v pre post) #t) reject-rollback entry))
    (ev '(define x 10) org)
    (check-error "rollback rejected by validator"
      (ev '(rollback! 1) org))))

;;; ── 25. NEW: Persistence round-trip ────────────────────────────────────────

(display "\n── 25. persistence round-trip ──\n")

(let ((store (make-memory-store)))
  ;; Create and mutate
  (receive (vat org)
    (make-persistent-org "test-persist" test-base-bindings store)
    (with-vat vat
      (ev '(modify! 'x 42) org)
      (ev '(modify! 'y 99) org)))
  ;; Restore from same store
  (receive (vat2 org2)
    (make-persistent-org "test-persist" test-base-bindings store)
    (with-vat vat2
      (check "post-restore: x=42"
             ($ org2 'lookup 'x) 42)
      (check "post-restore: y=99"
             ($ org2 'lookup 'y) 99)
      (check "history preserved after restore"
             (> (length ($ org2 'history)) 1) #t)
      ;; Mutations work on restored org
      (ev '(modify! 'z 77) org2)
      (check "post-restore: new mutation works"
             (ev 'z org2) 77)
      ;; Base bindings (procedures) re-injected
      (check "post-restore: base bindings available"
             (ev '(+ 1 2) org2) 3))))

;;; ── 26. NEW: Expressor as capability ───────────────────────────────────────

(display "\n── 26. expressor as capability ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (let* ((sealer (ev '(defexpressor 'alice "key-a") org))
           (alice-id ($ org 'authenticate-sealer sealer)))
      (check "sealer authenticates to valid expressor"
             (and alice-id ($ org 'expressor? alice-id)) #t)
      (check "non-expressor fails capability check"
             ($ org 'expressor? 'random-symbol) #f))))

;;; ── 27. NEW: Transactionality ──────────────────────────────────────────────

(display "\n── 27. transactionality ──\n")

;; Validation failure doesn't corrupt org state
(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define x 10) org)
    ;; Install validator that rejects value 0
    (ev '(enact! (lambda (e n v pre post)
                   (or (equal? n 'validator) (not (equal? v 0)))))
        org)
    (check-error "validation rejects zero"
      (ev '(modify! 'bad 0) org))
    ;; x should still be intact
    (check "state intact after rejected mutation"
           (ev 'x org) 10)
    ;; Further mutations still work
    (ev '(modify! 'y 42) org)
    (check "subsequent mutation succeeds"
           (ev 'y org) 42)))

;;; ── 28. Sealer triplets ──────────────────────────────────────────────────────

(display "\n── 28. sealer triplets ──\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    ;; defexpressor returns sealer
    (let ((sealer (ev '(defexpressor 'alice "key-a") org)))
      (check "defexpressor returns a sealer" (not (not sealer)) #t)
      ;; unsealer and sealed? in expressor-store
      (let* ((id ($ org 'authenticate-sealer sealer))
             (unsealer ($ org 'expressor-unsealer id))
             (sealed? ($ org 'expressor-sealed? id)))
        (check "expressor-unsealer returns an unsealer" (not (not unsealer)) #t)
        (check "expressor-sealed? returns a predicate" (not (not sealed?)) #t)
        ;; seal + unseal round-trip
        (let* ((sealed ($ sealer "secret"))
               (unsealed ($ unsealer sealed)))
          (check "seal + unseal round-trip" unsealed "secret")
          (check "sealed? recognizes sealed value" ($ sealed? sealed) #t)
          (check "sealed? rejects plain value" ($ sealed? "not sealed") #f))))))

;;; ── 29. Identity/controller pair ────────────────────────────────────────────

(display "\n── 29. identity/controller pair ──\n")

(with-vat test-vat
  (let* ((org (make-initial-org test-base-bindings))
         (pair (create-expressor-pair org 'bob "bob-key"))
         (identity (car pair))
         (controller (cdr pair)))
    ;; Identity methods
    (check "identity name" ($ identity 'name) 'bob)
    (check "identity has unsealer" (not (not ($ identity 'unsealer))) #t)
    (check "identity has sealed?" (not (not ($ identity 'sealed?))) #t)
    ;; Controller evaluates in org
    ($ controller 'evaluate '(define x 42))
    (check "controller evaluate modifies org" ($ org 'lookup 'x) 42)
    ;; Controller evaluate-with-locals
    (check "controller evaluate-with-locals"
           ($ controller 'evaluate-with-locals '(+ x local-y) '((local-y . 8)))
           50)
    ;; Controller seal + identity unseal
    (let* ((sealed ($ controller 'seal "test-content"))
           (unsealer ($ identity 'unsealer))
           (unsealed ($ unsealer sealed)))
      (check "controller seal + identity unseal" unsealed "test-content"))
    ;; Controller expressor-id
    (check "controller has expressor-id"
           ($ org 'expressor? ($ controller 'expressor-id)) #t)
    ;; Subscription sealer on identity
    (check "identity has subscription-sealer"
           (not (not ($ identity 'subscription-sealer))) #t)
    (check "identity has subscription-unsealer"
           (not (not ($ identity 'subscription-unsealer))) #t)
    ;; Subscription seal/unseal round-trip
    (let* ((sub-sealer ($ identity 'subscription-sealer))
           (sub-unsealer ($ identity 'subscription-unsealer))
           (sealed ($ sub-sealer "secret-controller"))
           (unsealed ($ sub-unsealer sealed)))
      (check "subscription seal + unseal round-trip"
             unsealed "secret-controller"))))

;;; ── 30. Warded inbox ────────────────────────────────────────────────────────

(display "\n── 30. warded inbox ──\n")

(with-vat test-vat
  (let* ((triple (make-org-with-inbox test-base-bindings))
         (org (car triple))
         (inbox (cadr triple))
         (incanter (cddr triple)))
    ;; Public: submit
    (let ((msg-id ($ inbox 'submit '(define x 42) 'alice-ref)))
      (check "submit returns msg-id" msg-id 0)
      ;; Public: pending
      (check "pending shows submitted message" (length ($ inbox 'pending)) 1)
      ;; Public: all-entries
      (check "all-entries shows submitted message" (length ($ inbox 'all-entries)) 1)
      ;; Controller: process (via incanter)
      (let ((expr ($ incanter inbox 'process msg-id)))
        (check "process returns the expr" expr '(define x 42)))
      ;; After processing, pending is empty
      (check "pending is empty after process" (length ($ inbox 'pending)) 0)
      ;; all-entries still has the entry (now processed)
      (check "all-entries retains processed entry" (length ($ inbox 'all-entries)) 1))
    ;; Submit another for retract test
    (let ((msg-id2 ($ inbox 'submit '(define y 99) 'bob-ref)))
      ;; Retract by correct sender
      ($ incanter inbox 'retract msg-id2 'bob-ref)
      (check "retract removes from pending" (length ($ inbox 'pending)) 0)
      ;; Retract by wrong sender errors
      (let ((msg-id3 ($ inbox 'submit '(define z 1) 'carol-ref)))
        (check-error "retract by wrong sender errors"
          ($ incanter inbox 'retract msg-id3 'wrong-ref))))
    ;; Direct call to controller method without incanter errors
    (let ((msg-id4 ($ inbox 'submit '(define w 0) 'test-ref)))
      (check-error "direct process without incanter errors"
        ($ inbox 'process msg-id4)))))

;;; ── 31. process-message form ────────────────────────────────────────────────

(display "\n── 31. process-message form ──\n")

(with-vat test-vat
  (let* ((triple (make-org-with-inbox test-base-bindings))
         (org (car triple))
         (inbox (cadr triple))
         (incanter (cddr triple)))
    ;; Submit a define expression to inbox
    (let ((msg-id ($ inbox 'submit '(define x 42) 'remote-sender)))
      ;; Evaluate process-message in the org
      (parameterize ((*inbox* inbox)
                     (*inbox-incanter* incanter))
        (ev `(process-message ,msg-id) org))
      ;; Verify org state changed
      (check "process-message: x defined in org" (ev 'x org) 42)
      ;; Message is now processed
      (check "process-message: pending empty" (length ($ inbox 'pending)) 0))
    ;; process-message without inbox errors
    (check-error "process-message without inbox errors"
      (ev '(process-message 0) org))
    ;; retract-message form
    (let ((msg-id2 ($ inbox 'submit '(define y 99) 'sender-ref)))
      (parameterize ((*inbox* inbox)
                     (*inbox-incanter* incanter))
        (ev `(retract-message ,msg-id2 'sender-ref) org))
      (check "retract-message: pending empty" (length ($ inbox 'pending)) 0))))

;;; ── 32. Sealed membership handshake ─────────────────────────────────────────

(display "\n── 32. sealed membership handshake ──\n")

(with-vat test-vat
  (let* ((triple (make-org-with-inbox test-base-bindings))
         (org (car triple))
         (inbox (cadr triple))
         (incanter (cddr triple)))
    ;; Create remote identity with subscription-sealer
    (receive (sub-sealer sub-unsealer sub-sealed?)
      (spawn-sealer-triplet)
      (let* ((remote-identity
              (spawn (lambda (bcom)
                       (methods
                        [(name) 'remote-alice]
                        [(subscription-sealer) sub-sealer]))))
             ;; Submit membership request
             (msg-id ($ inbox 'submit '(request-membership) remote-identity))
             ;; Approve membership
             (sealed-controller
              (approve-membership inbox incanter msg-id org
                                  'remote-alice "remote-key" remote-identity))
             ;; Unseal with remote's subscription-unsealer
             (controller ($ sub-unsealer sealed-controller)))
        ;; Evaluate through controller
        ($ controller 'evaluate '(define remote-val 999))
        (check "handshake: controller evaluates in org"
               (ev 'remote-val org) 999)
        ;; Verify expressor was created
        (let ((eid ($ controller 'expressor-id)))
          (check "handshake: expressor registered"
                 ($ org 'expressor? eid) #t)
          (check "handshake: expressor name"
                 ($ org 'expressor-name eid) 'remote-alice))
        ;; Wrong unsealer can't unseal
        (receive (other-sealer other-unsealer other-sealed?)
          (spawn-sealer-triplet)
          (check-error "handshake: wrong unsealer can't unseal"
            ($ other-unsealer sealed-controller)))))))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n")
(display (string-append "Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))
(when (> fail-count 0) (exit 1))
