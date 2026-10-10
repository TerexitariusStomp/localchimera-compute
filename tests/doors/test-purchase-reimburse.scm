;;; test-purchase-reimburse.scm — buying for the commons, and being paid back.
;;;
;;; Alice buys 2 kg of flour for the commons with her own €10 and records
;;; it: the flour is RAISED into the commons (planner/doors/service.scm
;;; record-purchase). What the commons then owes her back is restitution,
;;; not credit: Alice signs her OWN purchase-claim ("I gave the commons
;;; this" — economy/debts.scm purchase-claim, the exact twin of a
;;; socialization grant), and governance's own accept-reimbursement
;;; (governance/scope.scm) binds it as the primary to a reciprocal DEBT in
;;; an Agreement — the same shape accept-socialization already uses for a
;;; grant and its return commitment. Payout settlement (planner/doors/service.scm
;;; settle-payout, injected #:settle-of) pays the debt: what is owed is
;;; payable as a payout, because the acquisition recipes price EUR and XMR
;;; in labour (€10 = 0.01 XMR), and the runner pays the debt first, out of
;;; the commons' own pool. See docs/planning/socialization/reimbursement-funding-source.md
;;; for why this is restitution, never labour-credit.
;;;
;;; Run: guile -L module -L tests tests/doors/test-purchase-reimburse.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (playnet observation states) (playnet doors service) (playnet economy debts) (playnet boot scope) (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store)
             (playnet monero specs) (playnet monero payout))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (srfi srfi-13))

(define ADDR "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A")
(define COMMUNE "s1") (define ALICE "alice")

(define (^mock-policy bcom)
  (define log '())
  (lambda (msg . args)
    (case msg
      ((authorize-invoice) (car args)) ((revoke-invoice) #t)
      ((transfer) (set! log (cons (car args) log)) '(("tx_hash" . "feedface")))
      ((get-outgoing) '(("out" . #())))
      ((log) log)
      (else (error "mock-policy" msg)))))

(define vat (spawn-vat))
(define SR #f) (define STORE #f) (define SCOPE #f) (define GOV #f)
(define-values (svc policy)
  (with-vat vat
    (let* ((sr    (begin (set! SR (spawn-scope-root "Buy Scope")) SR))
           (obs   ($ sr 'observer))
           (store (begin (set! STORE (spawn-acdc-store)) STORE))
           (scope (begin (set! SCOPE (spawn-scope "Buy Scope" #:kind 'commune #:scope-root-ref sr
                                                  #:scope-aid COMMUNE #:acdc-store store))
                         SCOPE))
           (gov   (begin (set! GOV ($ scope 'mint-gov-cap "op")) GOV))
           (svc   (spawn ^planner-service (hashmap-set (hashmap) COMMUNE sr) plain-plan-fn #f
                        (append (socialized-readers store)
                                (list (cons 'debts open-debts-alist) (cons 'owed debts-owed-in-xmr) (cons 'settle settle-debts!))))))
      ;; XMR at 20 h and EUR at 0.02 h — the commons' one price for money
      (bootstrap-monero-resource! sr)
      (bootstrap-external-asset! sr #:spec-id "spec-eur" #:name "Euros" #:unit "EUR"
                                 #:categories '("external/fiat") #:acquisition-hours 0.02)
      ;; the commons' XMR pool holds 1 XMR (a donation came in)
      ($ obs 'record-event
         (make-economic-event #:id "ev-donation" #:action 'raise
                              #:resource-inventoried-as %xmr-resource-id
                              #:resource-conforms-to "spec-xmr"
                              #:resource-classified-as '("donation") #:receiver "agent-playnet"
                              #:resource-quantity (make-measure 1 "XMR") #:in-scope-of '()))
      (values svc (spawn ^mock-policy)))))

;; mints + issues Alice's own purchase-claim (unsigned here — the client-
;; signing ceremony itself is test-purchase-claim.scm's job; this test is
;; about accept-reimbursement's binding + debt + payout, not the signature)
;; and returns its SAID, ready to hand to accept-reimbursement.
(define (claim! spec qty unit)
  (let ((c (purchase-claim ALICE COMMUNE
                           (string-append "claim:" ALICE ":" spec ":" (number->string qty)
                                          ":" (number->string (random 1000000)))
                           spec qty unit #f)))
    ($ STORE 'issue-idempotent c)
    (cred-said c)))

(define (owed) (assq-ref (cdr ($ svc 'my-payouts COMMUNE ALICE STORE)) 'owed))
(define (avail) (let ((a (assq-ref (cdr ($ svc 'my-payouts COMMUNE ALICE STORE)) 'available)))
                  (/ (round (* a 100000)) 100000.0)))
(define (pool) (measure-has-numerical-value
                (economic-resource-onhand-quantity ($ ($ SR 'observer) 'get-resource %xmr-resource-id))))

(with-vat vat
  (display "\n── an unplanned purchase: nothing owed until the commune accepts ──\n")
  (let ((r ($ svc 'record-purchase COMMUNE ALICE "spec-flour" 2 "kg" "spec-eur" 10 "town" "flour for the bakery" "rcpt-001")))
    (check "recorded" (car r) 'ok)
    (check "nothing planned it" (assq-ref (cdr r) 'planned?) #f)
    (check "the flour is the commons' now, 2 kg"
           (let ((f ($ ($ SR 'observer) 'get-resource (assq-ref (cdr r) 'resource))))
             (and f (= 2 (measure-has-numerical-value (economic-resource-onhand-quantity f)))
                  (equal? COMMUNE (economic-resource-primary-accountable f)))))
    (check "nothing owed until the commune mints the debt" (length (owed)) 0)
    (check "so nothing is payable yet" (avail) 0.0)
    (check "the commune accepts alice's own signed claim — mints the reciprocal debt"
           (car (list (begin ($ SCOPE 'accept-reimbursement GOV (claim! "spec-eur" 10 "EUR")) 'ok))) 'ok)
    (check "the commons owes alice €10"
           (let ((k (car (owed)))) (and (= 10 (assq-ref k 'amount)) (equal? "EUR" (assq-ref k 'unit))
                                        (= 10 (assq-ref k 'remaining)))))
    (check "owed €10 = 0.01 XMR payable" (avail) 0.01))

  (display "\n── the payout pays the debt first, from the commons' pool ──\n")
  (check "alice asks for her 0.01 XMR" (car ($ svc 'request-payout COMMUNE ALICE STORE ADDR 0.01 "" "")) 'ok)
  (check "…and no more" (car ($ svc 'request-payout COMMUNE ALICE STORE ADDR 0.001 "" "")) 'error)
  (run-payouts! svc policy COMMUNE STORE #:now-iso "2026-08-21T00:00:00Z" #:reconcile? #f))
(with-vat vat #t) (with-vat vat #t) (with-vat vat #t) (with-vat vat #t)
(with-vat vat
  (check "one transfer left the wallet" (length ($ policy 'log)) 1)
  (check "the debt is settled — revoked, nothing open" (length (owed)) 0)
  (check "the commons' pool paid it: 1 − 0.01" (< (abs (- (pool) 0.99)) 1e-9))
  (check "nothing left to ask" (avail) 0.0)

  (display "\n── a planned purchase is fulfilling a commitment; a donation owes nothing ──\n")
  ;; the plan had committed to acquiring bread-flour
  ($ ($ SR 'plan-store) 'add-commitment-silent
     (make-commitment #:id "c-plan-flour" #:action 'produce #:note "planned acquisition" #:output-of "rp-acquire-spec-flour" #:resource-conforms-to "spec-flour"
                      #:resource-quantity (make-measure 5 "kg") #:provider COMMUNE #:created "2026-08-01T00:00:00Z" #:in-scope-of (list COMMUNE)))
  ;; a declared need for yeast — the demand rail's own record, which the
  ;; donation below SATISFIES (linkage is about the good arriving, so a
  ;; gift links exactly like a purchase)
  ($ svc 'declare-need COMMUNE "bob" "spec-yeast" 1 "kg" "" "" "yeast" "" "" "")
  (let ((r ($ svc 'record-purchase COMMUNE ALICE "spec-flour" 5 "kg" "spec-eur" 25 "town" "" "rcpt-002")))
    (check "planned: the plan had already committed to it" (assq-ref (cdr r) 'planned?) #t)
    (check "…and the raise FULFILLS that very commitment, not a boolean"
           (assq-ref (cdr r) 'fulfills) "c-plan-flour")
    (check "the observer's fulfillment tracking advanced on this event: 5 of 5 kg"
           (let ((fs ($ ($ SR 'observer) 'get-fulfillment "c-plan-flour")))
             (and fs (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))))
           5))
  (let ((r ($ svc 'record-purchase COMMUNE ALICE "spec-yeast" 1 "kg" "spec-eur" 4 "town" "gift" "" #t)))
    (check "a donation raises the good and reports no owed field" (and (eq? 'ok (car r)) (eq? #f (assq-ref (cdr r) 'owed))))
    (check "…and the donated yeast SATISFIES bob's declared need: 1 of 1 kg"
           (let ((ss ($ ($ SR 'observer) 'get-satisfaction "need:bob:spec-yeast")))
             (and ss (measure-has-numerical-value (satisfaction-state-total-satisfied ss))))
           1))
  (check "still nothing owed — the plan flag is informational, minting is a separate act" (avail) 0.0)
  (let ((said (claim! "spec-eur" 25 "EUR")))
    ($ SCOPE 'accept-reimbursement GOV said)
    (check "€25 owed = 0.025 XMR payable" (avail) 0.025)
    (check "re-accepting the SAME claim is idempotent, not a duplicate debt"
           (begin ($ SCOPE 'accept-reimbursement GOV said) (length (owed))) 1)))

(with-vat vat
  (display "\n── two purchases in the same second must not collide on one resource ──\n")
  ;; record-purchase's id is agent+spec+iso-now (second precision) — two calls
  ;; in the SAME vat turn land in the same second with nothing to tell them
  ;; apart unless the id itself carries a running count, the same fix
  ;; request-payout already needed for its own iid a few hundred lines above
  (let* ((r1 ($ svc 'record-purchase COMMUNE ALICE "spec-bricks" 10 %count-unit "spec-eur" 20 "town" "first batch" "rcpt-b1"))
         (r2 ($ svc 'record-purchase COMMUNE ALICE "spec-bricks" 15 %count-unit "spec-eur" 30 "town" "second batch" "rcpt-b2")))
    (check "both record ok" (and (eq? 'ok (car r1)) (eq? 'ok (car r2))) #t)
    (check "…with DIFFERENT resource ids — the real bug, fixed"
           (not (equal? (assq-ref (cdr r1) 'resource) (assq-ref (cdr r2) 'resource))))
    (check "the FIRST purchase's own resource note survives — not clobbered by the second"
           (let ((f ($ ($ SR 'observer) 'get-resource (assq-ref (cdr r1) 'resource))))
             (and f (equal? "first batch" (economic-resource-note f)))))))

(display "\n")
(test-summary!)
