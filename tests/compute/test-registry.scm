;;; test-registry.scm — the dispatch book: offers, jobs, claims, receipts,
;;; statements.
;;;
;;; The registry is the spec's matching half — offers answer jobs at the
;;; ring the job sits on, a claim binds a lender's offer to a borrower's
;;; intent under a countersign-by deadline, the receipt completes both
;;; sides, and a statement reconciles against what the receipts remember.
;;; Run: guile --no-auto-compile -q -L module tests/compute/test-registry.scm

(use-modules (playnet test harness)
             (playnet compute specs)
             (playnet compute receipt)
             (playnet compute registry)
             (playnet compute settlement)
             (playnet compute envelope)
             (playnet utils store-utils)
             (playnet boot governance)
             (goblins) (goblins vat)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "compute-registry-test"))

(define ALICE "did:key:z6MkAlice")
(define BOB   "did:key:z6MkBob")
(define CAROL "did:key:z6MkCarol")
(define HOME  "did:keri:EHomeCommune")

(with-vat vat
  (define reg (spawn ^compute-registry (hashmap) (hashmap) (hashmap) '()))

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
         (list (compute-job-state ($ reg 'job-of job-id))
               (compute-job-ring ($ reg 'job-of job-id)))
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
  (check "the job is claimed" (compute-job-state ($ reg 'job-of job-id)) 'claimed)
  (check "the claim awaits acceptance"
         (dispatch-claim-state ($ reg 'claim-of claim-id)) 'claimed)

  (check-error "a non-lender cannot claim under the offer"
               (lambda () ($ reg 'claim BOB job-id offer-id-2 0)))

  ($ reg 'preempt claim-id)
  (check "the claim is preempted — never a miss"
         (dispatch-claim-state ($ reg 'claim-of claim-id)) 'preempted)
  (check "the job reopens one ring outward"
         (list (compute-job-state ($ reg 'job-of job-id))
               (compute-job-ring ($ reg 'job-of job-id)))
         '(open 2))

  ;; ring escalation caps at 3 — two more preempts then no further
  (define claim-2 ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  ($ reg 'preempt claim-2)
  (check "second preempt → ring 3"
         (compute-job-ring ($ reg 'job-of job-id)) 3)
  (define claim-3 ($ reg 'claim ALICE job-id offer-id-2 (+ 1761000000000 259200000)))
  ($ reg 'preempt claim-3)
  (check "ring is capped at 3" (compute-job-ring ($ reg 'job-of job-id)) 3)

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
         (compute-job-state ($ reg 'job-of job-id)) 'settled)
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

  (define o-wire ($ gov 'compute-offer ALICE HOME "member" "inference,fetch" 4
                    "deterministic"))
  (check "compute-offer answers ok + an id" (car o-wire) 'ok)
  (define o-id (cdr o-wire))
  (check "compute-offers lists the offer as a wire row"
         (let ((rows (cdr ($ gov 'compute-offers HOME))))
           (and (pair? rows) (cdr (assoc "lender" (car rows))))) ALICE)

  (check "a nonsense class is refused at the door"
         (car ($ gov 'compute-offer ALICE HOME "member" "alchemy" 4 "exact"))
         'error)

  (define j-wire ($ gov 'compute-submit BOB HOME "inference" "member"
                    "deterministic" "in:wire"))
  (check "compute-submit answers ok + an id" (car j-wire) 'ok)
  (define j-id (cdr j-wire))
  (check "compute-jobs lists the open job"
         (let ((rows (cdr ($ gov 'compute-jobs HOME))))
           (and (pair? rows) (cdr (assoc "state" (car rows))))) "open")
  (check "compute-match answers the offer"
         (length (cdr ($ gov 'compute-match HOME j-id))) 1)

  (define c-wire ($ gov 'compute-claim ALICE HOME j-id o-id))
  (check "compute-claim answers ok + an id" (car c-wire) 'ok)
  (define c-id (cdr c-wire))
  (check "compute-claims lists the claim"
         (let ((rows (cdr ($ gov 'compute-claims HOME))))
           (and (pair? rows) (cdr (assoc "state" (car rows))))) "claimed")

  (check "a stranger cannot accept the borrower's dispatch"
         (car ($ gov 'compute-accept CAROL HOME c-id)) 'error)
  (check "the borrower accepts"
         (car ($ gov 'compute-accept BOB HOME c-id)) 'ok)

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
  (define v-wire ($ gov 'compute-verify rcpt-wire))
  (check "compute-verify: digest ok, sig unverifiable (no resolver here)"
         (cdr v-wire) '(#t unverifiable))

  (define r-wire ($ gov 'compute-receipt BOB HOME rcpt-wire))
  (check "compute-receipt records"
         (car r-wire) 'ok)
  (check "the claim completes through the door"
         (let ((rows (cdr ($ gov 'compute-claims HOME))))
           (cdr (assoc "state" (car rows)))) "complete")

  (check "a tampered digest is refused"
         (car ($ gov 'compute-receipt BOB HOME
                 (map (lambda (p) (if (eq? (car p) 'digest)
                                      (cons 'digest "tampered") p))
                      rcpt-wire))) 'error)

  (check "compute-envelope validates a clean envelope"
         (car ($ gov 'compute-envelope
                 '((bridgeJobId . "bj-x") (image . "i") (entrypoint . "r")
                   (inputHash . "h") (caps . ()) (network . #f)))) 'ok)
  (check "compute-envelope refuses a priced one"
         (car ($ gov 'compute-envelope
                 '((bridgeJobId . "bj-y") (image . "i") (entrypoint . "r")
                   (inputHash . "h") (caps . ()) (network . #f)
                   (amount . 5)))) 'error)

  ;; ── the envelope shelf — submit carries the body, the lender fetches ──
  (define env-wire
    '((bridgeJobId . "bj-shelf") (image . "js:work.js") (entrypoint . "run")
      (inputHash . "in:shelf") (caps . ()) (network . #f)))
  (define shelf-job (cdr ($ gov 'compute-submit BOB HOME "inference" "member"
                            "deterministic" "in:shelf"
                            'envelope env-wire 'envelopeHash "eh:shelf")))
  (check "submit with an envelope lands the job" (string? shelf-job) #t)
  (check "a priced envelope is refused at submit"
         (car ($ gov 'compute-submit BOB HOME "inference" "member"
                 "deterministic" "in:shelf2"
                 'envelope (cons '(amount . 9) env-wire))) 'error)
  (define shelf-claim
    (cdr ($ gov 'compute-claim ALICE HOME shelf-job o-id)))
  (check "the lender fetches the envelope it is meant to run"
         (let ((r ($ gov 'compute-fetch-envelope ALICE HOME shelf-claim)))
           (and (eq? (car r) 'ok)
                (equal? (cdr (assoc "image" (cdr r))) "js:work.js"))) #t)
  (check "the borrower cannot fetch the envelope back"
         (car ($ gov 'compute-fetch-envelope BOB HOME shelf-claim)) 'error)
  (check "a stranger cannot fetch the envelope"
         (car ($ gov 'compute-fetch-envelope CAROL HOME shelf-claim)) 'error)
  (check "no envelope on the shelf is an error, not a crash"
         (let* ((j2 (cdr ($ gov 'compute-submit BOB HOME "fetch" "member"
                            "none" "in:bare")))
                (c2 (cdr ($ gov 'compute-claim ALICE HOME j2 o-id))))
           (car ($ gov 'compute-fetch-envelope ALICE HOME c2))) 'error)

  (check "compute-settle refuses when the commune is unreachable here"
         (car ($ gov 'compute-settle ALICE "did:keri:ENowhere"
                 '((period . ("2026-10-01" . "2026-10-31")) (entries . ())
                   (payments . ()) (bridgeSig . "sig")))) 'error))

(test-summary!)
