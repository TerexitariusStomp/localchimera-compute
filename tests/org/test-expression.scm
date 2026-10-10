;;; test-expression.scm — weighted distribution over per-scope per-domain targets

(use-modules (playnet test harness))
(use-modules (playnet pools credit-fold) (srfi srfi-1))
(use-modules (playnet utils endorsement))
(use-modules (playnet voice delegation-map) (playnet voice expression) (playnet voice voice-signer))
(use-modules (goblins) (goblins utils hashmap) (srfi srfi-1))


(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.001)))
    (< (abs (- a b)) tol)))

(define (synthetic-aid id) (string-append "E_" id))

(define (make-citizen id voice-share)
  (call-with-values
    (lambda () (spawn-voice-signer id (synthetic-aid id)))
    (lambda (voice sealed?)
      (list id voice sealed? (spawn-delegation-map id) voice-share))))

(define (id c) (list-ref c 0))
(define (voice c) (list-ref c 1))
(define (sealed c) (list-ref c 2))
(define (deleg c) (list-ref c 3))
(define (share c) (list-ref c 4))

(define (registry citizens)
  (fold (lambda (c acc) (hashmap-set acc (id c) (sealed c))) (hashmap) citizens))

(define (vdata citizens)
  (fold (lambda (c acc) (hashmap-set acc (id c) (cons (share c) (deleg c))))
        (hashmap) citizens))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Direct distribution
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Direct distribution ──\n")

(define vat (spawn-vat))

(with-vat vat
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  (define plans '("plan-A" "plan-B" "plan-C"))
  (define expr
    (open-expression 'plan "p-1" 'federation "test" plans
                     (registry citizens) (vdata citizens)))

  ;; Alice distributes: 0.6 to A, 0.3 to B, 0.1 abstains
  (let ((dist (hashmap-set (hashmap-set (hashmap) "plan-A" 0.6) "plan-B" 0.3)))
    ($ expr 'cast "alice" (express (voice alice) 'plan "p-1" dist)))
  ;; Bob distributes: 1.0 to C
  (let ((dist (hashmap-set (hashmap) "plan-C" 1)))
    ($ expr 'cast "bob" (express (voice bob) 'plan "p-1" dist)))

  (let* ((tally-result ($ expr 'tally))
         (tally (assoc-ref tally-result 'tally))
         (abstain (assoc-ref tally-result 'abstain)))
    ;; A: 0.6 × 10 = 6
    (check-pred "plan-A weight = 6"
                (approx= 6 (hashmap-ref tally "plan-A" 0)))
    ;; B: 0.3 × 10 = 3
    (check-pred "plan-B weight = 3"
                (approx= 3 (hashmap-ref tally "plan-B" 0)))
    ;; C: 20
    (check-pred "plan-C weight = 20"
                (approx= 20 (hashmap-ref tally "plan-C" 0)))
    ;; Alice's 0.1 unallocated = 1 abstained
    (check-pred "abstention = 1"
                (approx= 1 abstain))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Liquid delegation in expression
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Liquid delegation flows ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  (define plans '("plan-A" "plan-B"))

  ;; Alice delegates 100% to Bob (federation default).
  ($ (deleg alice) 'delegate "bob" 1)

  (define expr
    (open-expression 'plan "p-2" 'federation "test" plans
                     (registry citizens) (vdata citizens)))

  ;; Only Bob casts: 1.0 to plan-A
  (let ((dist (hashmap-set (hashmap) "plan-A" 1)))
    ($ expr 'cast "bob" (express (voice bob) 'plan "p-2" dist)))

  (let* ((tally-result ($ expr 'tally))
         (tally (assoc-ref tally-result 'tally)))
    ;; A: alice's 10 (flowed through) + bob's 20 = 30
    (check-pred "plan-A gets alice + bob = 30"
                (approx= 30 (hashmap-ref tally "plan-A" 0)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Direct override in expression
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Direct override ──\n")

(define vat3 (spawn-vat))

(with-vat vat3
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define citizens (list alice bob))
  (define plans '("plan-A" "plan-B"))

  ($ (deleg alice) 'delegate "bob" 1)

  (define expr
    (open-expression 'plan "p-3" 'federation "test" plans
                     (registry citizens) (vdata citizens)))

  ;; Alice overrides: distributes 1.0 to plan-B
  (let ((dist (hashmap-set (hashmap) "plan-B" 1)))
    ($ expr 'cast "alice" (express (voice alice) 'plan "p-3" dist)))
  ;; Bob casts: 1.0 to plan-A
  (let ((dist (hashmap-set (hashmap) "plan-A" 1)))
    ($ expr 'cast "bob" (express (voice bob) 'plan "p-3" dist)))

  (let* ((tally-result ($ expr 'tally))
         (tally (assoc-ref tally-result 'tally)))
    ;; B gets alice's 10 (override reclaimed). A gets bob's 20 (no flow from alice).
    (check-pred "plan-B = alice 10"
                (approx= 10 (hashmap-ref tally "plan-B" 0)))
    (check-pred "plan-A = bob 20"
                (approx= 20 (hashmap-ref tally "plan-A" 0)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Validation rejects unknown plan / over-distribution
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Validation ──\n")

(define vat4 (spawn-vat))

(with-vat vat4
  (define alice (make-citizen "alice" 10))
  (define citizens (list alice))
  (define plans '("plan-A" "plan-B"))

  (define expr
    (open-expression 'plan "p-4" 'federation "test" plans
                     (registry citizens) (vdata citizens)))

  (check-pred "unknown target rejected"
              (catch #t
                (lambda ()
                  (let ((dist (hashmap-set (hashmap) "plan-Z" 1)))
                    ($ expr 'cast "alice"
                       (express (voice alice) 'plan "p-4" dist))
                    #f))
                (lambda _ #t)))

  (check-pred "over-distribution rejected"
              (catch #t
                (lambda ()
                  (let ((dist (hashmap-set
                                (hashmap-set (hashmap) "plan-A" 0.7)
                                "plan-B" 0.5)))
                    ($ expr 'cast "alice"
                       (express (voice alice) 'plan "p-4" dist))
                    #f))
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
