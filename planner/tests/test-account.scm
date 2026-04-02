;;; test-account.scm — Commune labor-credit accounting
;;;
;;; Ported from: old/planner/src/lib/tests/account.test.ts
;;;
;;; Intent: Verify SNLT-based commune accounting: labor crediting,
;;; elastic consumption pools, welfare allocation, and claim capacity.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-account.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


;;; ── Harness ───────────────────────────────────────────────────────────────────

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

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup: Account ──\n")

(define mem-store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Account Test"))
    mem-store))

(with-vat vat
  (check-pred "setup ok" #t))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Default initialization
;;;
;;; Ported from: "Initializes Commune with defaults"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Default initialization ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    (check "welfare rate = 0 (no accounts)"
           ($ as 'welfare-allocation-rate) 0)
    (check "pool = 0"
           ($ as 'get-pool-svc "individual-claimable") 0)
    (check "all-accounts empty"
           (length ($ as 'all-accounts)) 0)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Account creation and retrieval
;;;
;;; Ported from: "Account creation and retrieval"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Account CRUD ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    (check "all-accounts = 2"
           (length ($ as 'all-accounts)) 2)
    (let ((alice ($ as 'get-account "alice")))
      (check-pred "alice exists" (account? alice))
      (check "alice agent-id" (account-agent-id alice) "alice")
      (check "alice gross = 0" (account-gross-contribution-credited alice) 0)
      (check "alice claimed = 0" (account-claimed-capacity alice) 0)
      (check "alice CCF = 1" (account-contribution-capacity-factor alice) 1))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Direct labor credit
;;;
;;; Ported from: "Labor crediting via addLabor"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Direct labor credit ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    ($ as 'add-contribution "alice" 10)
    (let ((alice ($ as 'get-account "alice")))
      (check "alice gross = 10" (account-gross-contribution-credited alice) 10))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Labor credit via work event
;;;
;;; Ported from: "Labor crediting via work EconomicEvent"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Credit from work event ──\n")

(with-vat vat
  (let ((as ($ scope 'account-store)))
    ;; Reset: create fresh account for charlie
    ($ as 'ensure-account "charlie")
    (let ((work-event (make-economic-event
                        "ev-work-1" 'work #f #f #f #f "spec-labor" #f
                        "charlie" #f
                        #f (make-measure 8 "hour")
                        #f #f "2026-03-01T08:00:00Z" #f #f #f #f
                        #f #f #f #f #f #f #f #f #f #f)))
      ($ as 'credit-from-event work-event)
      (let ((charlie ($ as 'get-account "charlie")))
        (check "charlie gross = 8" (account-gross-contribution-credited charlie) 8)))

    ;; Produce event should NOT credit labor
    (let ((produce-event (make-economic-event
                           "ev-prod-1" 'produce #f #f #f #f "spec-bread" #f
                           "charlie" #f
                           (make-measure 100 "kg") #f
                           #f #f "2026-03-01T12:00:00Z" #f #f #f #f
                           #f #f #f #f #f #f #f #f #f #f)))
      ($ as 'credit-from-event produce-event)
      (let ((charlie ($ as 'get-account "charlie")))
        (check "charlie unchanged after produce = 8"
               (account-gross-contribution-credited charlie) 8)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Elastic claim capacity and consumption pool
;;;
;;; Ported from: "Elastic claim capacity and consumption pool"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Elastic claims ──\n")

;; Fresh scope for clean test
(define mem-store-2 (make-memory-store))
(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Elastic Test"))
    mem-store-2))

(with-vat vat2
  (let ((as ($ scope2 'account-store)))
    ;; Alice works 10h, Bob works 30h
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    ($ as 'add-contribution "alice" 10)
    ($ as 'add-contribution "bob" 30)

    ;; Add 100 SVC to pool
    ($ as 'add-to-pool "individual-claimable" 100)

    ;; Alice's claim capacity: 10/40 = 25%
    ;; Bob's claim capacity: 30/40 = 75%
    (let ((alice-cap ($ as 'account-claim-capacity "alice"))
          (bob-cap ($ as 'account-claim-capacity "bob")))
      (check-pred "alice claim ~25"
        (approx= alice-cap 25 0.5))
      (check-pred "bob claim ~75"
        (approx= bob-cap 75 0.5)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Claiming goods reduces pool
;;;
;;; Ported from: "Claiming goods reduces pool"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claim reduces pool ──\n")

(with-vat vat2
  (let ((as ($ scope2 'account-store)))
    ;; Alice claims 10 SVC
    (let ((result ($ as 'claim-goods "alice" 10)))
      (check "claim succeeds" result #t)
      (check "pool drops to 90"
             ($ as 'get-pool-svc "individual-claimable") 90)
      (let ((alice ($ as 'get-account "alice")))
        (check "alice claimed = 10"
               (account-claimed-capacity alice) 10)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Claim fails if insufficient capacity
;;;
;;; Ported from: "Claiming goods fails if insufficient actual capacity"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Claim fails if insufficient ──\n")

;; Fresh scope
(define mem-store-3 (make-memory-store))
(define-values (vat3 scope3)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Claim Fail Test"))
    mem-store-3))

(with-vat vat3
  (let ((as ($ scope3 'account-store)))
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    ($ as 'add-contribution "alice" 10)
    ($ as 'add-contribution "bob" 30)
    ($ as 'add-to-pool "individual-claimable" 40)

    ;; Alice has 25% of 40 = 10 actual capacity
    ;; Trying to claim 15 should fail
    (let ((fail-result ($ as 'claim-goods "alice" 15)))
      (check "claim 15 fails" fail-result #f)
      ;; Pool should be unchanged
      (check "pool unchanged at 40"
             ($ as 'get-pool-svc "individual-claimable") 40))

    ;; Claiming 10 should succeed
    (let ((ok-result ($ as 'claim-goods "alice" 10)))
      (check "claim 10 succeeds" ok-result #t))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Welfare allocation rate
;;;
;;; Ported from: implicit welfare rate tests
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Welfare allocation rate ──\n")

;; Fresh scope with different CCFs
(define mem-store-4 (make-memory-store))
(define-values (vat4 scope4)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Welfare Test"))
    mem-store-4))

(with-vat vat4
  (let ((as ($ scope4 'account-store)))
    ;; All CCF=1 by default → welfare rate should be 0
    ($ as 'ensure-account "alice")
    ($ as 'ensure-account "bob")
    (check "all CCF=1 -> welfare=0"
           ($ as 'welfare-allocation-rate) 0)

    ;; TODO: To properly test non-1 CCF, we'd need a way to set CCF.
    ;; The account-store currently creates all accounts with CCF=1.
    ;; This is a correct default but limits welfare rate testing.
    (check-pred "welfare rate >= 0"
      (>= ($ as 'welfare-allocation-rate) 0))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
