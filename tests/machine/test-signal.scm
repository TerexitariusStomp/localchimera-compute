;;; test-signal.scm — the relay kind's rendezvous: the per-claim signal log.
;;;
;;; Browsers cannot listen; a relay pair negotiates its DataChannel through
;;; signals posted on the claim itself — seq'd by the shelf, stamped
;;; from/at by the door so a body can neither spoof its sender nor predate
;;; its post. Only the claim's parties post or read, and only while the
;;; claim is live. Run:
;;;   guile --no-auto-compile -q -L module tests/machine/test-signal.scm

(use-modules (playnet test harness)
             (playnet machine specs)
             (playnet machine receipt)
             (playnet machine registry)
             (playnet machine envelope)
             (playnet machine challenge)
             (playnet machine settlement)
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
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-signal-test"))

(define ALICE "did:key:z6MkAlice")
(define BOB   "did:key:z6MkBob")
(define CAROL "did:key:z6MkCarol")
(define HOME  "did:keri:EHomeCommune")

(with-vat vat
  (display "\n── the shelf — a seq'd log per claim ──\n")
  (define shelf (spawn-signal-store))
  (check "the first signal seqs at 1"
         ($ shelf 'append! "claim-a" '((body . "one"))) 1)
  (check "the second continues"
         ($ shelf 'append! "claim-a" '((body . "two"))) 2)
  (check "another claim's log is its own"
         ($ shelf 'append! "claim-b" '((body . "elsewhere"))) 1)
  (check "after 0 reads the whole log"
         (length ($ shelf 'after "claim-a" 0)) 2)
  (check "after 1 reads what follows"
         (length ($ shelf 'after "claim-a" 1)) 1)
  (check "the surviving row is the second"
         (car (car ($ shelf 'after "claim-a" 1))) 2)
  (check "past the end reads empty"
         (length ($ shelf 'after "claim-a" 2)) 0)

  (display "\n── the doors — post and poll ──\n")
  (define GOV-AID "did:keri:EGovernor")
  (define gov (spawn-governance-service '() #f
                #:governor? (lambda (aid) (equal? aid GOV-AID))))
  (define r-offer
    (cdr ($ gov 'machine-offer ALICE HOME "member" "bandwidth" 4
            "deterministic")))
  (define r-job
    (cdr ($ gov 'machine-submit BOB HOME "bandwidth" "member"
            "deterministic" "in:relay")))
  (define r-claim (cdr ($ gov 'machine-claim ALICE HOME r-job r-offer)))
  (check "a live claim to signal on" (string? r-claim))

  ;; a stranger may not post — the mailbox belongs to the claim's parties
  (check "a stranger cannot signal"
         (car ($ gov 'machine-signal CAROL HOME r-claim '((type . "offer"))))
         'error)
  ;; the borrower posts an offer body, the lender an answer
  (define s1 ($ gov 'machine-signal BOB HOME r-claim
                '((type . "offer") (sdp . "v=0 offer-sdp"))))
  (check "the borrower's post seqs"
         (and (eq? (car s1) 'ok) (= (cdr s1) 1)) #t)
  (define s2 ($ gov 'machine-signal ALICE HOME r-claim
                '((type . "answer") (sdp . "v=0 answer-sdp"))))
  (check "the lender's post follows"
         (and (eq? (car s2) 'ok) (= (cdr s2) 2)) #t)

  ;; the read — stamped from, body intact, order kept
  (define rows (cdr ($ gov 'machine-signals ALICE HOME r-claim)))
  (check "the poll answers both rows" (length rows) 2)
  (check "the door stamps the sender"
         (cdr (assoc "from" (car rows))) BOB)
  (check "the body crosses intact"
         (cdr (assoc 'sdp (cdr (assoc "body" (car rows)))))
         "v=0 offer-sdp")
  (check "the seq rides along"
         (cdr (assoc "seq" (car rows))) 1)

  ;; the counterparty's incremental poll — after 1 lands only the answer
  (define tail (cdr ($ gov 'machine-signals BOB HOME r-claim 'after 1)))
  (check "an incremental read lands just the tail"
         (cdr (assoc "seq" (car tail))) 2)

  ;; read authorization — the parties and a governor, never a stranger
  (check "a stranger cannot read the log"
         (car ($ gov 'machine-signals CAROL HOME r-claim)) 'error)
  (check "a governor may audit it"
         (car ($ gov 'machine-signals GOV-AID HOME r-claim)) 'ok)
  (check "signals on no claim are an error, not silence"
         (car ($ gov 'machine-signals ALICE HOME "claim-nope")) 'error)

  ;; a dead claim is a dead letter — complete the claim, then posts refuse
  (define dead-offer
    (cdr ($ gov 'machine-offer CAROL HOME "member" "bandwidth" 4
            "deterministic")))
  (define dead-job
    (cdr ($ gov 'machine-submit BOB HOME "bandwidth" "member"
            "deterministic" "in:gone")))
  (define dead-claim (cdr ($ gov 'machine-claim CAROL HOME dead-job dead-offer)))
  ;; the borrower accepts, then the receipt completes the claim
  ($ gov 'machine-accept BOB HOME dead-claim)
  (define dead-receipt
    `((bridgeJobId . ,dead-claim) (lenderDid . ,CAROL)
      (inputHash . "in:gone") (outputHash . "out:gone")
      (usage . ((unit . "bytes") (amount . 9)))
      (executedAt . 1761000002000)
      (digest . ,(receipt-digest
                   (make-receipt #:bridge-job-id dead-claim #:lender-did CAROL
                                 #:input-hash "in:gone" #:output-hash "out:gone"
                                 #:usage (make-usage-meter #:unit "bytes" #:amount 9)
                                 #:executed-at 1761000002000)))))
  ($ gov 'machine-receipt BOB HOME dead-receipt)
  (check "a signal on a completed claim is refused"
         (car ($ gov 'machine-signal CAROL HOME dead-claim '((type . "late"))))
         'error))

(test-summary!)
