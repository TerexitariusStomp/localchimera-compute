;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-payers.scm — the demand side through the doors.
;;;
;;; The payer registry is the router's inbound half: a catalogue that
;;; says honestly who pays for which kinds and how their supply fits a
;;; tab (api/browser wireable; daemon/hardware/closed catalogued), the
;;; demand desk's prepaid book, the intake that mints a payer-funded job
;;; with params.payer stamped, and the ledger rows the settlement edge's
;;; payments name. The rules this suite pins: only a wireable payer takes
;;; intake, the customer's owner alone spends its balance, the debit is
;;; honest or the job never exists, and the ledger is the borrower's
;;; read — 'paid lands only when the operator marks the rail confirmed.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-payers.scm

(use-modules (playnet test harness)
             (playnet test e2e)
             (playnet machine registry)
             (playnet machine payers)
             (playnet boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-payers-e2e"))
(define HOME  "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceOperator")
(define BOB   "did:keri:DBobMember")
(define CAROL "did:keri:DCarolStranger")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (define (exec-envelope jid)
    `((kind . "exec") (bridgeJobId . ,jid)
      (image . "js:q") (entrypoint . "main")
      (inputHash . ,jid) (caps . ()) (network . #f) (params . ())))

  (scenario "the catalogue — who pays, classed honestly")
  (define catalogue (door-call gov ALICE 'machine-payers))
  (check "the catalogue answers"
         (> (length catalogue) 20) #t)
  (check "a wireable intake payer is named api"
         (assoc-ref (car catalogue) "class") "api")
  (check "golem is catalogued commune-daemon, not wireable"
         (let ((g (find (lambda (p) (equal? (assoc-ref p "name") "golem"))
                        catalogue)))
           (assoc-ref g "class"))
         "commune-daemon")
  (check "helium is catalogued hardware"
         (let ((h (find (lambda (p) (equal? (assoc-ref p "name") "helium"))
                        catalogue)))
           (assoc-ref h "class"))
         "hardware")

  (scenario "the book — a customer is created, topped up, owner-scoped")
  (define cust
    (door-call gov ALICE 'machine-demand-credit HOME "kh-cust-1" 100 "USD"
               'name "acme-scrapes"))
  (check "the new customer's balance is the seed"
         (assoc-ref cust "balance") 100)
  (define topped
    (door-call gov ALICE 'machine-demand-credit HOME "kh-cust-1" 50 "USD"))
  (check "a top-up adds"
         (assoc-ref topped "balance") 150)
  (check "the owner reads the book"
         (assoc-ref (door-call gov ALICE 'machine-demand-balance HOME "kh-cust-1")
                    "balance")
         150)
  (check "a stranger owns no customer"
         (car ($ gov 'machine-demand-credit CAROL HOME "kh-cust-1" 5 "USD"))
         'error)
  (check "a stranger reads no balance"
         (car ($ gov 'machine-demand-balance CAROL HOME "kh-cust-1"))
         'error)
  (check "an unknown key reads no balance"
         (car ($ gov 'machine-demand-balance ALICE HOME "kh-nobody"))
         'error)
  (check "a negative delta is refused"
         (car ($ gov 'machine-demand-credit ALICE HOME "kh-cust-1" -5 "USD"))
         'error)

  (scenario "intake — the wireable payers, and the honest refusals")
  (check "an unknown payer refuses"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-cust-1"
                 "not-a-net" "r1" 5 "swarm-infer" "member" "deterministic"
                 "in:x" 'envelope (exec-envelope "bj-x")))
         'error)
  (check "a commune-daemon payer takes no intake"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-cust-1"
                 "golem" "r1" 5 "swarm-infer" "member" "deterministic"
                 "in:x" 'envelope (exec-envelope "bj-x")))
         'error)
  (check "a kind the payer doesn't serve refuses"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-cust-1"
                 "api-fetch" "r1" 5 "swarm-infer" "member" "deterministic"
                 "in:x" 'envelope (exec-envelope "bj-x")))
         'error)
  (check "an unknown customer refuses"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-nobody"
                 "api-judge" "r1" 5 "swarm-infer" "member" "deterministic"
                 "in:x" 'envelope (exec-envelope "bj-x")))
         'error)
  (check "a debit past the balance refuses — no job, no row"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-cust-1"
                 "api-judge" "r1" 9999 "swarm-infer" "member" "deterministic"
                 "in:x" 'envelope (exec-envelope "bj-x")))
         'error)
  (check "an envelope stamped for another payer refuses"
         (car ($ gov 'machine-demand-intake ALICE HOME "kh-cust-1"
                 "api-judge" "r1" 5 "swarm-infer" "member" "deterministic"
                 "in:x"
                 'envelope `((kind . "exec") (bridgeJobId . "bj-x")
                             (image . "js:q") (entrypoint . "main")
                             (inputHash . "in:x") (caps . ()) (network . #f)
                             (params . ((payer . ((network . "api-fetch")
                                                  (ref . "r1"))))))))
         'error)

  (scenario "the intake — job minted, payer stamped, ledger booked")
  (define intake
    (door-call gov ALICE 'machine-demand-intake HOME "kh-cust-1"
               "api-judge" "inv-42" 30 "swarm-infer" "member" "deterministic"
               "in:paid" 'envelope (exec-envelope "bj-paid")))
  (define intake-job (assoc-ref intake "jobId"))
  (check "the job minted"
         (string? intake-job) #t)
  (check "the balance debited to the cent"
         (assoc-ref intake "balance") 120)
  (check "the ledger row is readable by job"
         (let ((rows (door-call gov ALICE 'machine-payer-events HOME
                                'jobId intake-job)))
           (and (= (length rows) 1)
                (list-ref (car rows) 2)))
         "api-judge")
  (check "the row carries the payer's ref and the debit"
         (let ((row (car (door-call gov ALICE 'machine-payer-events HOME
                                    'jobId intake-job))))
           (list (list-ref row 3) (list-ref row 4) (list-ref row 5)))
         '("inv-42" 30 "USD"))
  (check "the row opens 'offered — never paid on intake"
         (let ((row (car (door-call gov ALICE 'machine-payer-events HOME
                                    'jobId intake-job))))
           (list-ref row 6))
         "offered")
  ;; the lender claiming the job reads whose money it carries — the
  ;; payer stamp crosses inside the envelope, not beside it
  (define bob-offer
    (door-call gov BOB 'machine-offer HOME "member" "swarm-infer"
               4 "deterministic"))
  (define pay-claim
    (door-call gov BOB 'machine-claim HOME intake-job bob-offer))
  (check "the payer stamp reached the shelved envelope"
         (let* ((env (door-call gov BOB 'machine-fetch-envelope HOME pay-claim))
                (params (assoc-ref env "params"))
                (pd (assq-ref params 'payer)))
           (and pd (assq-ref pd 'network)))
         "api-judge")
  (check "a stranger's intake is refused"
         (car ($ gov 'machine-demand-intake CAROL HOME "kh-cust-1"
                 "api-judge" "r9" 1 "swarm-infer" "member" "deterministic"
                 "in:z" 'envelope (exec-envelope "bj-z")))
         'error)

  (scenario "the ledger — the borrower's read, the operator's settle")
  (check "the unscoped read answers the borrower's rows only"
         (length (door-call gov ALICE 'machine-payer-events HOME))
         1)
  (check "a stranger reads no ledger rows for the job"
         (car ($ gov 'machine-payer-events CAROL HOME 'jobId intake-job))
         'error)
  (define settle
    (door-call gov ALICE 'machine-payer-settle HOME
               (assoc-ref intake "rowId")))
  (check "the operator marks the rail confirmed"
         (assoc-ref settle "state") "paid")
  (check "a paid row stays paid — no re-settle churn"
         (assoc-ref (door-call gov ALICE 'machine-payer-settle HOME
                               (assoc-ref intake "rowId"))
                    "state")
         "paid")
  (check "a stranger settles no row"
         (car ($ gov 'machine-payer-settle CAROL HOME
                 (assoc-ref intake "rowId")))
         'error))
