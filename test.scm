;;; test.scm — tests for (xorg play)
;;; Run with:  guile -L . test.scm

(add-to-load-path "module")
(use-modules (xorg play))

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

;;; Base env — Scheme primitives exposed to the meta-evaluator
(define base-env
  (make-initial-env `((+          . ,+)
                      (-          . ,-)
                      (*          . ,*)
                      (>          . ,>)
                      (<          . ,<)
                      (=          . ,=)
                      (equal?     . ,equal?)
                      (eqv?       . ,eqv?)
                      (not        . ,not)
                      (null?      . ,null?)
                      (cons       . ,cons)
                      (car        . ,car)
                      (cdr        . ,cdr)
                      (list       . ,list)
                      (length     . ,length)
                      (env-history  . ,env-history)
                      (env-bindings . ,env-bindings))))

;;; Helper: inject a Scheme value as a binding without going through evaluate
(define (inject-binding env name val)
  (env-modify env (env-expressor env) name val `(inject ,name)))

;;; ── 1. Expressor accessors ──────────────────────────────────────────────────

(display "\n── 1. expressor accessors ──\n")

(let ((id (make-expressor 'alice "alice-key")))
  (check "expressor? recognizes valid id"        (if (expressor? id) #t #f) #t)
  (check "expressor-name returns the name symbol" (expressor-name id) 'alice)
  (check "expressor-key returns the key string"   (expressor-key id) "alice-key"))

(check "expressor-name on non-expressor returns #f"
       (expressor-name 'not-an-expressor) #f)
(check "expressor-key on non-expressor returns #f"
       (expressor-key 'not-an-expressor) #f)

;;; ── 2. extend-env / lambda closures ─────────────────────────────────────────

(display "\n── 2. lambda closures (extend-env) ──\n")

(let* ((env1 (evaluate '(modify! 'outer 99) base-env))
       (fn   (evaluate '(lambda (x) (+ x outer)) env1)))
  (check "lambda closes over outer binding" (fn 1) 100))

(let* ((env1 (evaluate '(modify! 'a 10) base-env))
       (env2 (evaluate '(modify! 'b 20) env1))
       (fn   (evaluate '(lambda (x) (+ x a b)) env2)))
  (check "lambda closes over multiple outer bindings" (fn 5) 35))

;; Parameter binding shadows outer binding
(let* ((env1 (evaluate '(modify! 'x 100) base-env))
       (fn   (evaluate '(lambda (x) x) env1)))
  (check "parameter shadows outer binding of same name" (fn 7) 7))

;;; ── 3. modify! and lookup ───────────────────────────────────────────────────

(display "\n── 3. modify! and lookup ──\n")

(let* ((env1 (evaluate '(modify! 'x 42) base-env)))
  (check "modify! stores value"       (evaluate 'x env1) 42))

(let* ((env1 (evaluate '(modify! 'x 42) base-env))
       (env2 (evaluate '(modify! 'x 99) env1)))
  (check "later modify! shadows earlier" (evaluate 'x env2) 99))

(check-error "unbound variable signals error"
  (evaluate 'undefined-var base-env))

;;; ── 4. Validator: pre-env / post-env signature ──────────────────────────────

(display "\n── 4. validator pre-env / post-env ──\n")

;; Validator that verifies history grows on every transition
(let* ((env-v (evaluate '(enact! (lambda (expressor name value pre-env post-env)
                                   (> (length (env-history post-env))
                                      (length (env-history pre-env)))))
                        base-env)))
  (check "enact! itself passes the history-growth validator"
         (if env-v #t #f) #t)
  (let ((env-m (evaluate '(modify! 'y 7) env-v)))
    (check "modify! under history-growth validator succeeds"
           (evaluate 'y env-m) 7)))

;; Validator that rejects its own installation
(check-error "validator returning #f rejects its own enact!"
  (evaluate '(enact! (lambda (expressor name value pre-env post-env) #f))
            base-env))

;; Direct Scheme-level test: env-modify passes correct pre and post envs.
;; We can't easily test this through evaluate (would need or/set! in meta-env),
;; so we install a capturing validator at the Scheme level.
(let* ((pre-seen  #f)
       (post-seen #f)
       (capturing (lambda (expressor name value pre-env post-env)
                    (set! pre-seen  pre-env)
                    (set! post-seen post-env)
                    #t))
       (env0 (make-env '() capturing (default-history)
                       (make-expressor 'tester "k")))
       (env1 (env-modify env0 (env-expressor env0) 'x 42 '(test))))
  (check "validator receives pre-env with empty bindings"
         (null? (env-bindings pre-seen)) #t)
  (check "validator receives post-env with x=42"
         (assoc 'x (env-bindings post-seen)) '(x . 42))
  (check "pre-env and post-env are distinct"
         (equal? (env-bindings pre-seen) (env-bindings post-seen)) #f))

;;; ── 5. as: identity switching ───────────────────────────────────────────────

(display "\n── 5. as / identity switching ──\n")

;; defexpressor + as round-trip: verify the binding key is the symbol, not (quote name)
(let* ((env1 (evaluate '(defexpressor 'carol "carol-key") base-env))
       (env2 (evaluate '(as carol (modify! 'greeting "hi")) env1)))
  (check "defexpressor + as round-trip works"
         (evaluate 'greeting env2) "hi"))

(let* ((alice (make-expressor 'alice "key-a"))
       (env1  (inject-binding base-env 'alice alice))
       (env2  (evaluate '(as alice (modify! 'greeting "hello")) env1))
       (entry (car (env-history env2))))
  (check "modify! value is stored under as"
         (evaluate 'greeting env2) "hello")
  (check "history entry records alice as the acting expressor"
         (expressor-name (history-expressor entry)) 'alice))

;; modify! on fresh base-env records genesis
(let* ((env1  (evaluate '(modify! 'a 1) base-env))
       (entry (car (env-history env1))))
  (check "modify! without as records genesis in fresh env"
         (expressor-name (history-expressor entry)) 'genesis))

;; The expressor set by 'as' persists in the returned env —
;; env-modify returns make-env with the acting expressor, so subsequent
;; modify! calls on that env continue under alice.
(let* ((alice (make-expressor 'alice "key-a"))
       (env1  (inject-binding base-env 'alice alice))
       (env2  (evaluate '(as alice (modify! 'a 1)) env1))
       (env3  (evaluate '(modify! 'b 2) env2))
       (entry (car (env-history env3))))
  (check "expressor set by as persists in returned env"
         (expressor-name (history-expressor entry)) 'alice))

;; as with unbound name signals error
(check-error "as with unbound name signals error"
  (evaluate '(as nobody (modify! 'x 1)) base-env))

;;; ── 6. show-history: names, not alists ──────────────────────────────────────
;;; The old accessor bug caused expressor-name to return the full alist rather
;;; than the name symbol.  Verify the accessor fix indirectly through history.

(display "\n── 6. expressor-name in history ──\n")

(let* ((bob   (make-expressor 'bob "key-b"))
       (env1  (inject-binding base-env 'bob bob))
       (env2  (evaluate '(as bob (modify! 'flag #t)) env1))
       (entry (car (env-history env2))))
  (check "history-expressor entry holds an expressor id (not a symbol)"
         (if (expressor? (history-expressor entry)) #t #f) #t)
  (check "expressor-name on that id returns the symbol 'bob"
         (expressor-name (history-expressor entry)) 'bob)
  (check "result is a symbol, not a list"
         (symbol? (expressor-name (history-expressor entry))) #t))

;;; ── 7. Lambda carries caller's authority, not author's ──────────────────────

(display "\n── 7. logic vs authority ──\n")

;; Alice defines a lambda that writes to 'target.
;; Bob calls it. History must record Bob, not Alice.
(let* ((alice (make-expressor 'alice "key-a"))
       (bob   (make-expressor 'bob   "key-b"))
       (env0  (inject-binding (inject-binding base-env 'alice alice) 'bob bob))
       ;; Alice defines the modifier
       (env1  (evaluate '(as alice (modify! 'modifier (lambda (x) (modify! 'target x)))) env0))
       ;; Bob calls it
       (env2  (evaluate '(as bob (modifier 42)) env1))
       ;; Most recent history entry is the (modify! 'target 42)
       (entry (car (env-history env2))))
  (check "value is stored correctly via cross-identity call"
         (evaluate 'target env2) 42)
  (check "lambda called by bob attributes modify! to bob, not alice"
         (expressor-name (history-expressor entry)) 'bob))

;;; ── 8. New evaluator forms ──────────────────────────────────────────────────

(display "\n── 8. begin ──\n")

(check "begin returns last value"
       (evaluate '(begin 1 2 3) base-env) 3)

(check "begin with single expression"
       (evaluate '(begin 42) base-env) 42)

;; begin threads env changes through
(let ((env1 (evaluate '(begin (modify! 'a 10) (modify! 'b 20)) base-env)))
  (check "begin threads env: a is set" (evaluate 'a env1) 10)
  (check "begin threads env: b is set" (evaluate 'b env1) 20))

;; begin with env changes followed by value expression
(check "begin env+value: returns last value"
       (evaluate '(begin (modify! 'a 10) (+ a 5)) base-env) 15)

(display "\n── 9. let ──\n")

(check "let basic binding"
       (evaluate '(let ((x 10)) x) base-env) 10)

(check "let multiple bindings"
       (evaluate '(let ((x 10) (y 20)) (+ x y)) base-env) 30)

(check "let body uses outer env"
       (let ((env1 (evaluate '(modify! 'outer 100) base-env)))
         (evaluate '(let ((x 5)) (+ x outer)) env1))
       105)

(check "let bindings are parallel (not sequential)"
       (let ((env1 (evaluate '(modify! 'x 1) base-env)))
         (evaluate '(let ((x 10) (y x)) y) env1))
       1)  ;; y sees the outer x=1, not the let x=10

(check "let with multi-body (implicit begin)"
       (evaluate '(let ((x 1) (y 2)) (+ x 0) (+ x y)) base-env) 3)

(display "\n── 10. let* ──\n")

(check "let* basic"
       (evaluate '(let* ((x 10)) x) base-env) 10)

(check "let* sequential bindings"
       (evaluate '(let* ((x 10) (y (+ x 5))) y) base-env) 15)

(check "let* three bindings"
       (evaluate '(let* ((a 1) (b (+ a 1)) (c (+ a b))) c) base-env) 3)

(check "let* with multi-body"
       (evaluate '(let* ((x 10)) (+ x 0) (+ x 5)) base-env) 15)

(display "\n── 11. define ──\n")

;; define as governed binding
(let ((env1 (evaluate '(define x 42) base-env)))
  (check "define stores value" (evaluate 'x env1) 42)
  (check "define records in history"
         (let ((entry (car (env-history env1))))
           (equal? (history-expr entry) '(define x 42)))
         #t))

;; define function shorthand
(let ((env1 (evaluate '(define (square x) (* x x)) base-env)))
  (check "define function shorthand"
         (evaluate '(square 5) env1) 25))

;; define inside begin threads env
(let ((env1 (evaluate '(begin (define a 10) (define b 20)) base-env)))
  (check "define in begin: a" (evaluate 'a env1) 10)
  (check "define in begin: b" (evaluate 'b env1) 20))

(display "\n── 12. cond ──\n")

(check "cond basic true"
       (evaluate '(cond (#t 42)) base-env) 42)

(check "cond first false, second true"
       (evaluate '(cond (#f 1) (#t 2)) base-env) 2)

(check "cond with else"
       (evaluate '(cond (#f 1) (else 99)) base-env) 99)

(check "cond with computed test"
       (evaluate '(cond ((> 3 2) "yes") (else "no")) base-env) "yes")

(check "cond no-body clause returns test value"
       (evaluate '(cond (42)) base-env) 42)

(check "cond multi-expr body"
       (evaluate '(cond (#t 1 2 3)) base-env) 3)

(display "\n── 13. and / or ──\n")

(check "and no args" (evaluate '(and) base-env) #t)
(check "and single true" (evaluate '(and 42) base-env) 42)
(check "and single false" (evaluate '(and #f) base-env) #f)
(check "and returns last true" (evaluate '(and 1 2 3) base-env) 3)
(check "and short-circuits on false" (evaluate '(and 1 #f 3) base-env) #f)

(check "or no args" (evaluate '(or) base-env) #f)
(check "or single true" (evaluate '(or 42) base-env) 42)
(check "or single false" (evaluate '(or #f) base-env) #f)
(check "or returns first true" (evaluate '(or #f #f 3) base-env) 3)
(check "or short-circuits on true" (evaluate '(or 1 2 3) base-env) 1)

(display "\n── 14. two-branch if ──\n")

(check "two-branch if true"
       (evaluate '(if #t 42) base-env) 42)

(check "two-branch if false returns unspecified"
       (evaluate '(if #f 42) base-env) (if #f #f))

(display "\n── 15. lambda multi-body ──\n")

(let ((fn (evaluate '(lambda (x) (+ x 0) (+ x 1)) base-env)))
  (check "lambda with two body expressions" (fn 10) 11))

;;; ── 16. Org isolation ──────────────────────────────────────────────────────

(display "\n── 16. org isolation ──\n")

(let ((env-a (evaluate '(modify! 'x 100) base-env))
      (env-b (evaluate '(modify! 'x 200) base-env)))
  ;; They should be independent
  (check "org-a has x=100"
         (evaluate 'x env-a) 100)
  (check "org-b has x=200"
         (evaluate 'x env-b) 200)
  ;; env-a doesn't have env-b's bindings leak
  (let ((env-b2 (evaluate '(modify! 'only-in-b 42) env-b)))
    (check "only-in-b exists in org-b"
           (evaluate 'only-in-b env-b2) 42)
    (check-error "only-in-b does not exist in org-a"
      (evaluate 'only-in-b env-a))))

;;; ── 17. Named let ──────────────────────────────────────────────────────────

(display "\n── 17. named let ──\n")

(check "named let: basic loop (sum 0..5)"
       (evaluate '(let loop ((i 0) (acc 0))
                    (if (> i 5) acc (loop (+ i 1) (+ acc i))))
                 base-env)
       15)

(check "named let: countdown accumulator"
       (evaluate '(let loop ((n 5) (acc (list)))
                    (if (= n 0) acc (loop (- n 1) (cons n acc))))
                 base-env)
       '(1 2 3 4 5))

(check "named let: accesses outer bindings"
       (let ((env1 (evaluate '(modify! 'base 100) base-env)))
         (evaluate '(let loop ((i 0))
                      (if (= i 3) base (loop (+ i 1))))
                   env1))
       100)

;;; ── 18. letrec ─────────────────────────────────────────────────────────────

(display "\n── 18. letrec ──\n")

(check "letrec: factorial"
       (evaluate '(letrec ((fact (lambda (n) (if (= n 0) 1 (* n (fact (- n 1)))))))
                    (fact 5))
                 base-env)
       120)

(check "letrec: mutual recursion (even?/odd?)"
       (evaluate '(letrec ((my-even? (lambda (n) (if (= n 0) #t (my-odd? (- n 1)))))
                           (my-odd?  (lambda (n) (if (= n 0) #f (my-even? (- n 1))))))
                    (list (my-even? 4) (my-odd? 3) (my-even? 3)))
                 base-env)
       '(#t #t #f))

;;; ── 19. Variadic lambda ────────────────────────────────────────────────────

(display "\n── 19. variadic lambda ──\n")

(check "variadic lambda: (lambda args ...) collects all"
       (let ((fn (evaluate '(lambda args args) base-env)))
         (fn 1 2 3))
       '(1 2 3))

(check "variadic lambda: (lambda (a . rest) ...) splits"
       (let ((fn (evaluate '(lambda (a . rest) rest) base-env)))
         (fn 1 2 3))
       '(2 3))

(check "variadic lambda: (lambda (a . rest) ...) first arg"
       (let ((fn (evaluate '(lambda (a . rest) a) base-env)))
         (fn 1 2 3))
       1)

(check "define shorthand with rest params"
       (let ((env1 (evaluate '(define (my-list . args) args) base-env)))
         (evaluate '(my-list 1 2 3) env1))
       '(1 2 3))

;;; ── 20. when / unless ──────────────────────────────────────────────────────

(display "\n── 20. when / unless ──\n")

(check "when: true branch executes"
       (evaluate '(when #t 42) base-env)
       42)

(check "when: false branch returns unspecified"
       (evaluate '(when #f 42) base-env)
       (if #f #f))

(check "when: multi-body"
       (evaluate '(when #t 1 2 3) base-env)
       3)

(check "unless: false branch executes"
       (evaluate '(unless #f 42) base-env)
       42)

(check "unless: true branch returns unspecified"
       (evaluate '(unless #t 42) base-env)
       (if #f #f))

;;; ── 21. case ───────────────────────────────────────────────────────────────

(display "\n── 21. case ──\n")

(check "case: matching datum"
       (evaluate '(case (+ 1 1)
                    ((1) "one")
                    ((2) "two")
                    ((3) "three"))
                 base-env)
       "two")

(check "case: else clause"
       (evaluate '(case 99
                    ((1) "one")
                    (else "other"))
                 base-env)
       "other")

(check "case: no match returns unspecified"
       (evaluate '(case 99 ((1) "one") ((2) "two")) base-env)
       (if #f #f))

(check "case: multiple datums per clause"
       (evaluate '(case 3
                    ((1 2) "low")
                    ((3 4) "mid")
                    (else "high"))
                 base-env)
       "mid")

;;; ── 22. do ─────────────────────────────────────────────────────────────────

(display "\n── 22. do ──\n")

(check "do: counting loop"
       (evaluate '(do ((i 0 (+ i 1)))
                      ((= i 5) i))
                 base-env)
       5)

(check "do: accumulation loop"
       (evaluate '(do ((i 0 (+ i 1))
                       (acc 0 (+ acc i)))
                      ((= i 5) acc))
                 base-env)
       10)

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n")
(display (string-append "Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed\n"))
(when (> fail-count 0) (exit 1))
