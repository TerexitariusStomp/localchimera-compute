;;; test-registry.scm — the dispatch book: offers, jobs, claims, receipts,
;;; statements.
;;;
;;; The registry is the spec's matching half — offers answer jobs at the
;;; ring the job sits on, a claim binds a lender's offer to a borrower's
;;; intent under a countersign-by deadline, the receipt completes both
;;; sides, and a statement reconciles against what the receipts remember.
;;; Run: guile --no-auto-compile -q -L module tests/compute/test-registry.scm

(use-modules (playnet test harness)
             (playnet machine specs)
             (playnet machine receipt)
             (playnet machine registry)
             (playnet machine settlement)
             (playnet machine envelope)
             (playnet machine replay)
             (playnet machine binding)
             (playnet machine binding-verifiers)
             (playnet machine payout)
             (playnet machine executors)
             (playnet utils store-utils)
             (playnet boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-registry-test"))

(define ALICE "did:key:z6MkAlice")
(define BOB   "did:key:z6MkBob")
(define CAROL "did:key:z6MkCarol")
(define HOME  "did:keri:EHomeCommune")

(with-vat vat
  (define reg (spawn ^machine-registry (hashmap) (hashmap) (hashmap) '()))

  ;; ── offers ─────────────────────────────────────────────────────────────
  (display "\n── offers — a lender keeps its headroom on the book ──\n")

  (define offer-id
    ($ reg 'offer ALICE HOME "member" '(inference fetch) 4 'deterministic
       "seconds"))
  (check "offer lands with an id" (string? offer-id))
  (define the-offer ($ reg 'offer-of offer-id))
  (check "offer remembers its lender" (lane-offer-lender-did the-offer) ALICE)
  (check "offer remembers its headroom" (lane-offer-headroom the-offer) 4)

  (check "the commune's book lists it"
         (length ($ reg 'offers HOME)) 1)
  (check "another commune's book does not"
         (length ($ reg 'offers "did:keri:EOther")) 0)

  (check-error "only the lender retracts"
               (lambda () ($ reg 'retract offer-id BOB)))
  ($ reg 'retract offer-id ALICE)
  (check "a retracted offer leaves the book"
         (length ($ reg 'offers HOME)) 0)

  (define offer-id-2
    ($ reg 'offer ALICE HOME "member" '(inference fetch) 4 'deterministic))

  ;; ── jobs ───────────────────────────────────────────────────────────────
  (display "\n── jobs — the borrower's intent enters at ring 1 ──\n")

  (define job-id
    ($ reg 'submit BOB HOME 'inference "member" 'deterministic "in:hash:1"))
  (check "job lands with an id" (string? job-id))
  (check "the job is open at ring 1"
         (list (machine-job-state ($ reg 'job-of job-id))
               (machine-job-ring ($ reg 'job-of job-id)))
         '(open 1))

  (check-error "only the borrower withdraws"
               (lambda () ($ reg 'withdraw job-id ALICE)))

  ;; ── match ──────────────────────────────────────────────────────────────
  (display "\n── match — offers that answer the job's class, lane, mode ──\n")

  (check "alice's offer answers the inference job"
         (length ($ reg 'match job-id)) 1)
  ($ reg 'offer CAROL HOME "member" (list 'storage) 2 'exact)
  (check "a storage offer does not answer an inference job"
         (length ($ reg 'match job-id)) 1)

  ;; ── claim → preempt ────────────────────────────────────────────────────
  (display "\n── claim, preempt — inner work reclaims, the job walks out a ring ──\n")

  (define claim-id ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  (check "claim binds offer to job" (string? claim-id))
  (check "the job is claimed" (machine-job-state ($ reg 'job-of job-id)) 'claimed)
  (check "the claim awaits acceptance"
         (dispatch-claim-state ($ reg 'claim-of claim-id)) 'claimed)

  (check-error "a non-lender cannot claim under the offer"
               (lambda () ($ reg 'claim BOB job-id offer-id-2 0)))

  ($ reg 'preempt claim-id)
  (check "the claim is preempted — never a miss"
         (dispatch-claim-state ($ reg 'claim-of claim-id)) 'preempted)
  (check "the job reopens one ring outward"
         (list (machine-job-state ($ reg 'job-of job-id))
               (machine-job-ring ($ reg 'job-of job-id)))
         '(open 2))

  ;; ring escalation caps at 3 — two more preempts then no further
  (define claim-2 ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  ($ reg 'preempt claim-2)
  (check "second preempt → ring 3"
         (machine-job-ring ($ reg 'job-of job-id)) 3)
  (define claim-3 ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  ($ reg 'preempt claim-3)
  (check "ring is capped at 3" (machine-job-ring ($ reg 'job-of job-id)) 3)

  ;; ── claim → accept → receipt ───────────────────────────────────────────
  (display "\n── accept, receipt — the event the settlement reconciles ──\n")

  (define claim-live ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  (check-error "only the borrower accepts the dispatch"
               (lambda () ($ reg 'accept claim-live CAROL)))
  ($ reg 'accept claim-live BOB)
  (check "accepted claim runs"
         (dispatch-claim-state ($ reg 'claim-of claim-live)) 'accepted)

  (define rcpt
    (make-receipt #:bridge-job-id claim-live #:lender-did ALICE
                  #:input-hash "in:hash:1" #:output-hash "out:hash:1"
                  #:usage (make-usage-meter #:unit "seconds" #:amount 42)
                  #:repro (make-repro-spec #:mode 'deterministic #:seed 7)
                  #:executed-at 1761000001000))
  (define digest ($ reg 'receipt! claim-live rcpt))
  (check "receipt! answers the body's digest" digest (receipt-digest rcpt))
  (check "the claim completes"
         (dispatch-claim-state ($ reg 'claim-of claim-live)) 'complete)
  (check "the job settles"
         (machine-job-state ($ reg 'job-of job-id)) 'settled)
  (check "the claim remembers its receipt"
         (receipt-digest (dispatch-claim-receipt ($ reg 'claim-of claim-live)))
         digest)

  (check-error "a closed claim cannot be preempted"
               (lambda () ($ reg 'preempt claim-live)))

  ;; ── receipt-of — the settlement entry's lookup ─────────────────────────
  (display "\n── receipt-of — reconciliation reads the book by digest ──\n")

  (check "a known digest answers its receipt"
         (receipt-digest ($ reg 'receipt-of digest)) digest)
  (check "an unknown digest answers #f" ($ reg 'receipt-of "de:ad:be:ef") #f)

  ;; ── settle / statements ────────────────────────────────────────────────
  (display "\n── settle — a bridge's statement lands on the commune's book ──\n")

  (define stmt
    (make-settlement-statement
     #:period '("2026-10-01" . "2026-10-31")
     #:entries `(((bridgeJobId . ,claim-live) (receiptDigest . ,digest)
                  (amount . 42) (asset . "compute-credit"))
                 ((bridgeJobId . "bj-ghost") (receiptDigest . "no:such:digest")
                  (amount . 5) (asset . "compute-credit")))
     #:payments `(((amount . 42) (asset . "compute-credit")
                   (to . "safe:treasury") (txHash . "0xabc")))
     #:bridge-sig "sig:bridge"))

  ($ reg 'settle stmt)
  (check "the statement is on the book"
         (length ($ reg 'statements)) 1)

  (apply
    (lambda (matched missing claimed paid)
      (check "the live claim's entry matches its receipt" (length matched) 1)
      (check "the ghost entry has no receipt" (length missing) 1)
      (check "the statement's total claimed" claimed 47)
      (check "the statement's total paid" paid 42))
    (reconcile-statement stmt (lambda (d) ($ reg 'receipt-of d)))))

;;; ── the envelope contract — pure, no vat ─────────────────────────────────

(display "\n── the job envelope — no price on the wire ──\n")

(define (env-fields . extra)
  `((bridgeJobId . "bj-9") (image . "wasm:runner@1") (entrypoint . "run")
    (inputHash . "in:9") (caps . ((mem-mb . 512) (cpu-seconds . 300)))
    (network . #f) ,@extra))

(define good-env (alist->job-envelope (env-fields)))
(check "a clean envelope parses"
       (job-envelope-bridge-job-id good-env) "bj-9")
(check "a clean envelope round-trips with no price key"
       (envelope-no-amount? (job-envelope->alist good-env)) #t)
(check "a price-keyed field list is caught"
       (envelope-no-amount? (env-fields '(amount . 5))) #f)

(check-error "an envelope with an amount is refused"
             (lambda () (alist->job-envelope (env-fields '(amount . 5)))))
(check-error "an envelope with a price is refused"
             (lambda () (alist->job-envelope (env-fields '(price . "1 XMR")))))



;;; ── the doors — the same acts, as the wire reaches them ─────────────────
;;; The fragment composes into the governance service (boot governance);
;;; member acts carry identity-key first, reads name only the commune.

(display "\n── the doors — member acts and open reads over the service ──\n")

(with-vat vat
  (define gov (spawn-governance-service '() #f))

  (define o-wire ($ gov 'machine-offer ALICE HOME "member" "inference,fetch" 4
                    "deterministic"))
  (check "machine-offer answers ok + an id" (car o-wire) 'ok)
  (define o-id (cdr o-wire))
  (check "machine-offers lists the offer as a wire row"
         (let ((rows (cdr ($ gov 'machine-offers HOME))))
           (and (pair? rows) (cdr (assoc "lender" (car rows))))) ALICE)

  (check "a nonsense class is refused at the door"
         (car ($ gov 'machine-offer ALICE HOME "member" "alchemy" 4 "exact"))
         'error)

  (define j-wire ($ gov 'machine-submit BOB HOME "inference" "member"
                    "deterministic" "in:wire"))
  (check "machine-submit answers ok + an id" (car j-wire) 'ok)
  (define j-id (cdr j-wire))
  (check "machine-jobs lists the open job"
         (let ((rows (cdr ($ gov 'machine-jobs HOME))))
           (and (pair? rows) (cdr (assoc "state" (car rows))))) "open")
  (check "machine-match answers the offer"
         (length (cdr ($ gov 'machine-match HOME j-id))) 1)

  (define c-wire ($ gov 'machine-claim ALICE HOME j-id o-id))
  (check "machine-claim answers ok + an id" (car c-wire) 'ok)
  (define c-id (cdr c-wire))
  (check "machine-claims lists the claim"
         (let ((rows (cdr ($ gov 'machine-claims HOME))))
           (and (pair? rows) (cdr (assoc "state" (car rows))))) "claimed")

  (check "a stranger cannot accept the borrower's dispatch"
         (car ($ gov 'machine-accept CAROL HOME c-id)) 'error)
  (check "the borrower accepts"
         (car ($ gov 'machine-accept BOB HOME c-id)) 'ok)

  ;; a receipt wire row: the body the lender's node emitted
  (define rcpt-wire
    `((bridgeJobId . ,c-id) (lenderDid . ,ALICE)
      (inputHash . "in:wire") (outputHash . "out:wire")
      (usage . ((unit . "seconds") (amount . 7)))
      (repro . ((mode . "deterministic") (seed . 3)))
      (executedAt . 1761000002000)
      (digest . ,(receipt-digest
                   (make-receipt #:bridge-job-id c-id #:lender-did ALICE
                                 #:input-hash "in:wire" #:output-hash "out:wire"
                                 #:usage (make-usage-meter #:unit "seconds" #:amount 7)
                                 #:repro (make-repro-spec #:mode 'deterministic #:seed 3)
                                 #:executed-at 1761000002000)))))
  (define v-wire ($ gov 'machine-verify rcpt-wire))
  (check "machine-verify: digest ok, sig unverifiable (no resolver here)"
         (cdr v-wire) '(#t unverifiable))

  (define r-wire ($ gov 'machine-receipt BOB HOME rcpt-wire))
  (check "machine-receipt records"
         (car r-wire) 'ok)
  (check "the claim completes through the door"
         (let ((rows (cdr ($ gov 'machine-claims HOME))))
           (cdr (assoc "state" (car rows)))) "complete")

  (check "a tampered digest is refused"
         (car ($ gov 'machine-receipt BOB HOME
                 (map (lambda (p) (if (eq? (car p) 'digest)
                                      (cons 'digest "tampered") p))
                      rcpt-wire))) 'error)

  (check "machine-envelope validates a clean envelope"
         (car ($ gov 'machine-envelope
                 '((bridgeJobId . "bj-x") (image . "i") (entrypoint . "r")
                   (inputHash . "h") (caps . ()) (network . #f)))) 'ok)
  (check "machine-envelope refuses a priced one"
         (car ($ gov 'machine-envelope
                 '((bridgeJobId . "bj-y") (image . "i") (entrypoint . "r")
                   (inputHash . "h") (caps . ()) (network . #f)
                   (amount . 5)))) 'error)

  ;; ── the envelope shelf — submit carries the body, the lender fetches ──
  (define env-wire
    '((bridgeJobId . "bj-shelf") (image . "js:work.js") (entrypoint . "run")
      (inputHash . "in:shelf") (caps . ()) (network . #f)))
  (define shelf-job (cdr ($ gov 'machine-submit BOB HOME "inference" "member"
                            "deterministic" "in:shelf"
                            'envelope env-wire 'envelopeHash "eh:shelf")))
  (check "submit with an envelope lands the job" (string? shelf-job) #t)
  (check "a priced envelope is refused at submit"
         (car ($ gov 'machine-submit BOB HOME "inference" "member"
                 "deterministic" "in:shelf2"
                 'envelope (cons '(amount . 9) env-wire))) 'error)
  (define shelf-claim
    (cdr ($ gov 'machine-claim ALICE HOME shelf-job o-id)))
  (check "the lender fetches the envelope it is meant to run"
         (let ((r ($ gov 'machine-fetch-envelope ALICE HOME shelf-claim)))
           (and (eq? (car r) 'ok)
                (equal? (cdr (assoc "image" (cdr r))) "js:work.js"))) #t)
  (check "the borrower cannot fetch the envelope back"
         (car ($ gov 'machine-fetch-envelope BOB HOME shelf-claim)) 'error)
  (check "a stranger cannot fetch the envelope"
         (car ($ gov 'machine-fetch-envelope CAROL HOME shelf-claim)) 'error)
  (check "no envelope on the shelf is an error, not a crash"
         (let* ((j2 (cdr ($ gov 'machine-submit BOB HOME "fetch" "member"
                            "none" "in:bare")))
                (c2 (cdr ($ gov 'machine-claim ALICE HOME j2 o-id))))
           (car ($ gov 'machine-fetch-envelope ALICE HOME c2))) 'error)

  (check "machine-settle refuses when the commune is unreachable here"
         (car ($ gov 'machine-settle ALICE "did:keri:ENowhere"
                 '((period . ("2026-10-01" . "2026-10-31")) (entries . ())
                   (payments . ()) (bridgeSig . "sig")))) 'error)

  ;; ── replay — PoI is authoritative; the executor is injected ──────────
  ;; the verdict logic, executor-injected
  (define shelf-env
    (alist->job-envelope
     '((bridgeJobId . "bj-shelf") (image . "js:work.js")
       (entrypoint . "run") (inputHash . "in:shelf")
       (caps . ()) (network . #f))))
  (define repro-det (make-repro-spec #:mode 'deterministic #:seed 7))
  (check "replay: same hash reproduces"
         (replay-verdict (replay-job shelf-env repro-det "out:x"
                          #:executor (lambda (e r) "out:x"))) 'reproduced)
  (check "replay: a different hash mismatches"
         (replay-verdict (replay-job shelf-env repro-det "out:x"
                          #:executor (lambda (e r) "out:y"))) 'mismatch)
  (check "replay: a raising executor is unverifiable, not a crash"
         (replay-verdict (replay-job shelf-env repro-det "out:x"
                          #:executor (lambda (e r) (error "boom")))) 'unverifiable)
  (check "replay: 'none jobs are evidence-only"
         (replay-verdict (replay-job shelf-env
                          (make-repro-spec #:mode 'none) "out:x"
                          #:executor (lambda (e r) "out:x"))) 'unverifiable)
  (check "replay: no executor injected fails closed"
         (replay-verdict (replay-job shelf-env repro-det "out:x")) 'no-executor)
  (check "a challenge carries the four fields"
         (let ((ch (make-challenge #:receipt-digest "d" #:reproduced 'mismatch
                                   #:attestation-hash "a" #:counter-hash "c")))
           (and (equal? (challenge-receipt-digest ch) "d")
                (eq? (challenge-reproduced ch) 'mismatch)
                (equal? (challenge-attestation-hash ch) "a")
                (equal? (challenge-counter-hash ch) "c"))) #t)

  ;; the door: shelf-claim has an envelope; accept, receipt, then replay
  (check "the borrower accepts the shelf dispatch"
         (car ($ gov 'machine-accept BOB HOME shelf-claim)) 'ok)
  (define shelf-rcpt
    `((bridgeJobId . ,shelf-claim) (lenderDid . ,ALICE)
      (inputHash . "in:shelf") (outputHash . "out:shelf")
      (usage . ((unit . "seconds") (amount . 4)))
      (repro . ((mode . "deterministic") (seed . 7)))
      (executedAt . 1761000003000)
      (digest . ,(receipt-digest
                   (make-receipt #:bridge-job-id shelf-claim #:lender-did ALICE
                                 #:input-hash "in:shelf" #:output-hash "out:shelf"
                                 #:usage (make-usage-meter #:unit "seconds" #:amount 4)
                                 #:repro (make-repro-spec #:mode 'deterministic #:seed 7)
                                 #:executed-at 1761000003000)))))
  (check "receipt on the shelf claim records"
         (car ($ gov 'machine-receipt BOB HOME shelf-rcpt)) 'ok)
  (check "machine-replay without an executor answers no-executor, fail-closed"
         (let ((r ($ gov 'machine-replay BOB HOME shelf-claim)))
           (and (eq? (car r) 'ok)
                (eq? (cdr (assoc "reproduced" (cdr r))) 'no-executor)
                (equal? (cdr (assoc "attestationHash" (cdr r))) "out:shelf")
                (eq? (cdr (assoc "counterHash" (cdr r))) #f))) #t)
  (check "a stranger cannot replay the claim"
         (car ($ gov 'machine-replay CAROL HOME shelf-claim)) 'error)
  (check "replaying a claim with no receipt is an error"
         (let* ((j3 (cdr ($ gov 'machine-submit BOB HOME "fetch" "member"
                            "none" "in:bare2")))
                (c3 (cdr ($ gov 'machine-claim ALICE HOME j3 o-id))))
           (car ($ gov 'machine-replay ALICE HOME c3))) 'error)

  ;; ── bindings — the AccountLink ceremony (spec §1) ──────────────────────
  (define link-x
    (make-account-link #:did-key "did:key:z6MksNode1" #:scope-aid HOME
                       #:account "eip155:1:0xSafeTreasury" #:purpose 'payout
                       #:nonce "n1" #:expiry 9999999999))
  (check "the statement both sides sign is deterministic"
         (equal? (binding-statement link-x) (binding-statement link-x)) #t)
  (check "keri: names the AID↔did:key binding form"
         (keri-account? "keri:EAbC") #t)
  (check "a CAIP-10 is not the keri: form" (keri-account? "eip155:1:0x1") #f)
  (define b-x (make-account-binding link-x "sigS" "sigA"))
  (check "a fresh binding stands" (binding-live? b-x) #t)
  (check "the signer may unlink"
         (account-binding-status (binding-unlink b-x 'signer)) 'unlinked-by-signer)
  (check "the account side may unlink"
         (account-binding-status (binding-unlink b-x 'account)) 'unlinked-by-account)
  (check "an unlinked binding does not stand"
         (binding-live? (binding-unlink b-x 'signer)) #f)
  (check "an expired link does not stand"
         (binding-live?
          (make-account-binding
           (make-account-link #:did-key "d" #:scope-aid HOME #:account "a"
                              #:purpose 'node #:nonce "n" #:expiry 1)
           "s" "s")) #f)
  (check "verify-binding: both sigs good → ok"
         (verify-binding b-x #:verify-signer (lambda (k s g) #t)
                         #:verify-account (lambda (k s g) #t)) 'ok)
  (check "verify-binding: a bad signer sig → bad-signature"
         (verify-binding b-x #:verify-signer (lambda (k s g) #f)
                         #:verify-account (lambda (k s g) #t)) 'bad-signature)
  (check "verify-binding: a bad account sig → bad-signature"
         (verify-binding b-x #:verify-signer (lambda (k s g) #t)
                         #:verify-account (lambda (k s g) #f)) 'bad-signature)
  (check "verify-binding: a raising verifier is unverifiable, not a crash"
         (verify-binding b-x #:verify-signer (lambda (k s g) (error "no resolver"))
                         #:verify-account (lambda (k s g) #t)) 'unverifiable)
  (check "verify-binding: unlinked is a verdict"
         (verify-binding (binding-unlink b-x 'account)
                         #:verify-signer (lambda (k s g) #t)
                         #:verify-account (lambda (k s g) #t)) 'unlinked)

  ;; ── payout — one payee, the treasury Safe (spec §2) ────────────────────
  (define stmt-x
    (make-settlement-statement
     #:period "2026-W43"
     #:entries (list '((bridgeJobId . "j1") (receiptDigest . "d1")
                       (amount . 10) (asset . "eip155:1/erc20:0xUSD"))
                     '((bridgeJobId . "j2") (receiptDigest . "d2")
                       (amount . 5) (asset . "eip155:1/erc20:0xUSD"))
                     '((bridgeJobId . "j3") (receiptDigest . "d3")
                       (amount . 2) (asset . "eip155:1/slip44:60")))
     #:payments '() #:bridge-sig "bsig"))
  (check "a node-purpose binding is not a payout rail"
         (catch #t (lambda () (payout-binding
                      (make-account-binding
                       (make-account-link #:did-key "d" #:scope-aid HOME
                                          #:account "eip155:1:0xA" #:purpose 'node
                                          #:nonce "n" #:expiry 9e9) "s" "s"))
                    #f)
                (lambda (k . a) #t)) #t)
  (check "a keri: binding is an identity, not a payee"
         (catch #t (lambda () (payout-binding
                      (make-account-binding
                       (make-account-link #:did-key "d" #:scope-aid HOME
                                          #:account "keri:EX" #:purpose 'payout
                                          #:nonce "n" #:expiry 9e9) "s" "s"))
                    #f)
                (lambda (k . a) #t)) #t)
  (check "the plan folds entries to one send per asset, treasury only"
         (let ((plan (payout-plan stmt-x b-x)))
           (and (= (length plan) 2)
                (every (lambda (r) (equal? (car r) "eip155:1:0xSafeTreasury")) plan)
                (equal? (assoc "eip155:1/erc20:0xUSD"
                               (map (lambda (r) (cons (cadr r) (caddr r))) plan))
                        '("eip155:1/erc20:0xUSD" . 15)))) #t)
  (check "execute-payout with a send lands rows with tx hashes"
         (let ((rows (execute-payout stmt-x b-x
                      #:send (lambda (to amt asset) "0xTxHash123"))))
           (and (= (length rows) 2)
                (equal? (payout-row-tx-hash (car rows)) "0xTxHash123")
                (equal? (payout-row-to (car rows)) "eip155:1:0xSafeTreasury"))) #t)
  (check "execute-payout without a rail fails closed"
         (catch #t (lambda () (execute-payout stmt-x b-x) #f)
                (lambda (k . a) #t)) #t)

  ;; ── the binding/payout doors ────────────────────────────────────────────
  (check "machine-bind: a keri: binding is the caller's own AID only"
         (car ($ gov 'machine-bind ALICE HOME
                 '((didKey . "did:key:z6MksAlice") (account . "keri:did:keri:EAlice")
                   (purpose . "node") (nonce . "n1") (expiry . 9999999999)
                   (signerSig . "sS") (accountSig . "sA"))))
         'error)
  (check "machine-bind: a keri: self-binding lands"
         (car ($ gov 'machine-bind ALICE HOME
                 (list (cons 'didKey "did:key:z6MksAlice")
                       (cons 'account (string-append "keri:" ALICE))
                       '(purpose . "node") '(nonce . "n1") '(expiry . 9999999999)
                       '(signerSig . "sS") '(accountSig . "sA"))))
         'ok)
  ;; the verifiers are real now: a readable form with a garbage sig is
  ;; bad-signature, not unverifiable — 'unverifiable rides only on the
  ;; account forms this build can't read at all.
  (check "machine-bind: a CAIP-10 link with a bad sig answers bad-signature"
         (let ((r ($ gov 'machine-bind ALICE HOME
                     '((didKey . "did:key:z6MksAlice") (account . "eip155:1:0xAliceSafe")
                       (purpose . "payout") (nonce . "n2") (expiry . 9999999999)
                       (signerSig . "sS") (accountSig . "sA")))))
           (and (eq? (car r) 'ok)
                (eq? (cdr (assoc "verdict" (cdr r))) 'bad-signature))) #t)
  ;; a bad signer sig dominates the verdict regardless of the account's
  ;; form — the did:key's countersignature is checked first
  (check "machine-bind: an unreadable form still answers the signer's verdict"
         (let ((r ($ gov 'machine-bind ALICE HOME
                     '((didKey . "did:key:z6MksAlice") (account . "rgb:xyz")
                       (purpose . "payout") (nonce . "n3") (expiry . 9999999999)
                       (signerSig . "sS") (accountSig . "sA")))))
           (and (eq? (car r) 'ok)
                (eq? (cdr (assoc "verdict" (cdr r))) 'bad-signature))) #t)
  (check "did:key decodes to a 32-byte ed25519 pubkey"
         (let ((pub (did-key->ed25519-pubkey
                     "did:key:z6Mkfriq1MqLBoPWecGoDLjguo1sB9brj6wT3qZ5BxkKqrDA")))
           (and pub (= (bytevector-length pub) 32))) #t)
  (check "a non-ed25519 or malformed did:key answers #f, not a crash"
         (and (not (did-key->ed25519-pubkey "did:key:z6MkShort"))
              (not (did-key->ed25519-pubkey "not-a-did"))
              (not (did-key->ed25519-pubkey #f))) #t)
  (check "machine-bindings lists what was bound"
         (let* ((rows (cdr ($ gov 'machine-bindings ALICE HOME)))
                (hit (find (lambda (r)
                             (equal? (cdr (assoc "account" r)) "eip155:1:0xAliceSafe"))
                           rows)))
           (and hit (equal? (cdr (assoc "purpose" hit)) "payout")
                (equal? (cdr (assoc "status" hit)) "live"))) #t)
  (check "machine-unbind: the account side ends it"
         (let* ((key (binding-key "did:key:z6MksAlice" "eip155:1:0xAliceSafe"))
                (r ($ gov 'machine-unbind ALICE HOME key "account")))
           (and (eq? (car r) 'ok) (equal? (cdr r) "unlinked-by-account"))) #t)
  (check "machine-unbind: a nonsense side is refused"
         (car ($ gov 'machine-unbind ALICE HOME "k" "sideways")) 'error)
  (check "machine-payout: an unreachable commune is refused"
         (car ($ gov 'machine-payout ALICE "did:keri:ENowhere"
                 '((statement . ((period . "w") (entries . ()) (payments . ())
                                 (bridgeSig . "s")))
                   (bindingKey . "k")))) 'error)

  ;; ── the executor registry — replay with a real runner ──────────────────
  (check "no executor registered → the wildcard table is empty"
         (executor-for HOME) #f)
  (register-executor! HOME
    (make-replay-executor #:kind 'wasmcloud #:name "host-1"
                          #:run (lambda (env repro) "out:shelf")))
  (check "a registered executor reproduces through the door"
         (let ((r ($ gov 'machine-replay BOB HOME shelf-claim)))
           (and (eq? (car r) 'ok)
                (eq? (cdr (assoc "reproduced" (cdr r))) 'reproduced)
                (equal? (cdr (assoc "counterHash" (cdr r))) "out:shelf"))) #t)
  (unregister-executor! HOME)
  (check "an executor that disagrees mismatches through the door"
         (begin
           (register-executor! HOME
             (make-replay-executor #:kind 'wasimoff #:name "broker-1"
                                   #:run (lambda (env repro) "out:WRONG")))
           (let ((r ($ gov 'machine-replay ALICE HOME shelf-claim)))
             (eq? (cdr (assoc "reproduced" (cdr r))) 'mismatch))) #t)
  (unregister-executor! HOME)
  (check "no executor again → fail closed"
         (let ((r ($ gov 'machine-replay BOB HOME shelf-claim)))
           (eq? (cdr (assoc "reproduced" (cdr r))) 'no-executor)) #t)
  (check "executors-list reports the registered rows"
         (begin
           (register-executor! 'any
             (make-replay-executor #:kind 'local #:name "wasmtime-26"
                                   #:run (lambda (e r) "x")))
           (let ((rows (executors-list)))
             (unregister-executor! 'any)
             (and (= (length rows) 1)
                (equal? (list-ref (car rows) 1) 'local)))) #t)
  (check "an unknown executor kind is refused at construction"
         (catch #t (lambda () (make-replay-executor #:kind 'magic #:name "x"
                                                  #:run (lambda (e r) "x")) #f)
                (lambda (k . a) #t)) #t)

  ;; ── disputes — spec §5: raise, three-member sortition, review, close ──
  ;; Citizens the service has met are the review pool; four meet the doors
  ;; here so sortition has names beyond the claim's parties.
  (define DAVE "did:key:z6MkDave")
  (define ERIN "did:key:z6MkErin")
  (for-each (lambda (who) ($ gov 'machine-disputes who HOME))
            (list CAROL DAVE ERIN))

  ;; fresh jobs for the dispute claims — a job accepts one claim, and
  ;; o-id's headroom is spent by now; a second offer carries these.
  (define o-id-2
    (cdr ($ gov 'machine-offer ALICE HOME "member" "inference" 8
            "deterministic")))
  (define dead-job
    (cdr ($ gov 'machine-submit BOB HOME "inference" "member"
            "deterministic" "in:dead")))
  (define dead-claim
    (cdr ($ gov 'machine-claim ALICE HOME dead-job o-id-2 'deadline 1000)))
  (check "the deadline-past claim exists for the non-delivery dispute"
         (string? dead-claim) #t)
  ;; …and a live one, deadline still open
  (define live-job-2
    (cdr ($ gov 'machine-submit BOB HOME "inference" "member"
            "deterministic" "in:live")))
  (define live-claim-2
    (cdr ($ gov 'machine-claim ALICE HOME live-job-2 o-id-2)))

  (check "machine-dispute: a stranger may not raise"
         (car ($ gov 'machine-dispute CAROL HOME shelf-claim "wrong-result"))
         'error)
  (check "machine-dispute: a nonsense kind is refused"
         (car ($ gov 'machine-dispute BOB HOME shelf-claim "spite")) 'error)

  ;; wrong-result with a matching executor: the prover reproduces — the
  ;; dispute's premise fails and the door refuses to record it
  (register-executor! HOME
    (make-replay-executor #:kind 'wasmcloud #:name "host-2"
                          #:run (lambda (env repro) "out:shelf")))
  (check "machine-dispute: a reproduced receipt cannot be disputed"
         (car ($ gov 'machine-dispute BOB HOME shelf-claim "wrong-result"))
         'error)

  ;; now the executor disagrees — the dispute lands with its challenge
  (register-executor! HOME
    (make-replay-executor #:kind 'wasimoff #:name "broker-2"
                          #:run (lambda (env repro) "out:DIFFERENT")))
  (define wr ($ gov 'machine-dispute BOB HOME shelf-claim "wrong-result"))
  (check "machine-dispute: a wrong-result dispute lands, challenge attached"
         (let* ((d (cdr wr))
                (ch (cdr (assoc "challenge" d))))
           (and (eq? (car wr) 'ok)
                (equal? (cdr (assoc "kind" d)) "wrong-result")
                (equal? (cdr (assoc "state" d)) "in-review")
                (= (length (vector->list (cdr (assoc "reviewers" d)))) 3)
                (eq? (cdr (assoc "reproduced" ch)) 'mismatch)
                (equal? (cdr (assoc "counterHash" ch)) "out:DIFFERENT"))) #t)
  (define wr-id (cdr (assoc "id" (cdr wr))))
  (define wr-reviewers
    (vector->list (cdr (assoc "reviewers" (cdr wr)))))

  (check "machine-dispute: one dispute per claim"
         (car ($ gov 'machine-dispute ALICE HOME shelf-claim "wrong-result"))
         'error)
  (check "machine-dispute-verdict: a non-reviewer may not vote"
         (car ($ gov 'machine-dispute-verdict "did:key:z6MkNobody" HOME wr-id
                 "upheld")) 'error)
  (check "machine-dispute-verdict: two uphelds close the review"
         (let* ((r1 ($ gov 'machine-dispute-verdict (car wr-reviewers) HOME
                       wr-id "upheld"))
                (r2 ($ gov 'machine-dispute-verdict (cadr wr-reviewers) HOME
                       wr-id "upheld")))
           (and (eq? (car r1) 'ok)
                (equal? (cdr (assoc "outcome" (cdr r2))) "upheld")
                (equal? (cdr (assoc "state" (cdr r2))) "closed"))) #t)

  ;; non-delivery: the deadline passed, no receipt — the absence is the
  ;; evidence, no challenge rides the record
  (define nd ($ gov 'machine-dispute BOB HOME dead-claim "non-delivery"))
  (check "machine-dispute: non-delivery lands with no challenge"
         (let ((d (cdr nd)))
           (and (eq? (car nd) 'ok)
                (equal? (cdr (assoc "kind" d)) "non-delivery")
                (not (cdr (assoc "challenge" d))))) #t)
  (check "machine-dispute: non-delivery before the deadline is refused"
         (car ($ gov 'machine-dispute BOB HOME live-claim-2 "non-delivery"))
         'error)
  (check "machine-dispute-close: within the window the clock refuses"
         (car ($ gov 'machine-dispute-close BOB HOME
                 (cdr (assoc "id" (cdr nd))))) 'error)
  (check "machine-disputes lists both disputes"
         (length (cdr ($ gov 'machine-disputes CAROL HOME))) 2)

  ;; a matched entry under a live dispute is held — the statement counts
  ;; it but money does not move on a contested receipt. gov2 carries a
  ;; stub scope so machine-settle's gov-cap gate is reachable.
  (define fake-scope
    (spawn (lambda (bcom)
             (methods ((mint-gov-cap aid) 'cap)
                      ((scope-aid) HOME)))))
  (define gov2
    (spawn-governance-service '() #f #:scope-of (lambda (aid) fake-scope)))
  (define nd-id (cdr (assoc "id" (cdr nd))))
  ;; rebuild the disputed claim on gov2's own registry
  ($ gov2 'machine-disputes CAROL HOME)
  (define d2-job
    (cdr ($ gov2 'machine-submit BOB HOME "inference" "member"
            "deterministic" "in:d2")))
  (define d2-o
    (cdr ($ gov2 'machine-offer ALICE HOME "member" "inference" 8
            "deterministic")))
  (define d2-claim
    (cdr ($ gov2 'machine-claim ALICE HOME d2-job d2-o 'deadline 1000)))
  (define d2-disp
    (cdr ($ gov2 'machine-dispute BOB HOME d2-claim "non-delivery")))
  (define stmt-wire
    `((period . "test-period") (bridgeSig . "sig")
      (entries . (((bridgeJobId . ,d2-claim) (receiptDigest . "d1")
                   (amount . 5) (asset . "XMR"))))
      (payments . ())))
  (check "machine-settle reports a disputed entry as held"
         (let ((r ($ gov2 'machine-settle ALICE HOME stmt-wire)))
           ;; (ok matched missing held claimed paid)
           (and (eq? (car r) 'ok)
                (= (list-ref (cdr r) 2) 1))) #t)
  (unregister-executor! HOME))

(test-summary!)
