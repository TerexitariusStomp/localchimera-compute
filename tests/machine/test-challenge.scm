;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-challenge.scm — the store kind: envelope kinds and params,
;;; resources and needs, and the storage challenge's issue→answer→verify
;;; lifecycle.
;;;
;;; The challenge is the storage kind's replay — 'exact by construction:
;;; answer = sha256(nonce ∥ content), a pure function of a fresh nonce and
;;; the committed bytes. Run:
;;;   guile --no-auto-compile -q -L module tests/machine/test-challenge.scm

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
             (gcrypt hash)
             (gcrypt base16)
             (rnrs bytevectors)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-challenge-test"))

(define ALICE "did:key:z6MkAlice")
(define BOB   "did:key:z6MkBob")
(define CAROL "did:key:z6MkCarol")
(define HOME  "did:keri:EHomeCommune")

(define CONTENT "the bytes a store claim promises to keep")
(define CONTENT-BV (string->utf8 CONTENT))
(define CONTENT-HASH (bytevector->base16-string (sha256 CONTENT-BV)))

(with-vat vat
  (display "\n── envelope kinds — the wire's five shapes ──\n")

  ;; a kindless envelope is the legacy exec — image and entrypoint required
  (define legacy
    (alist->job-envelope '((bridgeJobId . "bj-1") (image . "js:")
                           (entrypoint . "(x)=>x") (inputHash . "h:1")
                           (caps . ()) (network . #f))))
  (check "a kindless envelope parses as exec"
         (job-envelope-kind legacy) 'exec)

  ;; a store envelope needs no image — its commitment is inputHash alone
  (define store-env
    (alist->job-envelope
     '((kind . "store") (bridgeJobId . "bj-2") (inputHash . "h:2")
       (caps . ()) (network . #f)
       (params . ((ttlSeconds . 60) (contentB64 . "aGk="))))))
  (check "a store envelope parses without an image"
         (job-envelope-kind store-env) 'store)
  (check "params survive the parse"
         (assq-ref (job-envelope-params store-env) 'ttlSeconds) 60)
  (check "kind and params round-trip onto the wire"
         (let ((w (job-envelope->alist store-env)))
           (and (equal? (assoc-ref w "kind") "store")
                (= (assoc-ref (assoc-ref w "params") 'ttlSeconds) 60))) #t)

  (check-error "an exec envelope without an image is refused"
               (lambda ()
                 (alist->job-envelope
                  '((kind . "exec") (bridgeJobId . "bj-3")
                    (inputHash . "h") (caps . ()) (network . #f)))))
  (check-error "an unknown kind is refused"
               (lambda ()
                 (alist->job-envelope
                  '((kind . "teleport") (bridgeJobId . "bj-4")
                    (inputHash . "h") (caps . ()) (network . #f)))))
  (check-error "a priced envelope is refused"
               (lambda ()
                 (alist->job-envelope
                  '((bridgeJobId . "bj-5") (image . "i") (entrypoint . "r")
                    (inputHash . "h") (caps . ()) (network . #f)
                    (amount . 5)))))
  (check-error "a price hiding in params is refused"
               (lambda ()
                 (alist->job-envelope
                  '((kind . "store") (bridgeJobId . "bj-6") (inputHash . "h")
                    (caps . ()) (network . #f)
                    (params . ((fee . 1)))))))
  (check-error "a price nested a level deep is refused"
               (lambda ()
                 (alist->job-envelope
                  '((kind . "store") (bridgeJobId . "bj-7") (inputHash . "h")
                    (caps . ()) (network . #f)
                    (params . ((inner . ((price . 9)))))))))
  (check-error "a price inside a bundle leg is refused"
               (lambda ()
                 (alist->job-envelope
                  '((kind . "bundle") (bridgeJobId . "bj-8") (inputHash . "h")
                    (caps . ()) (network . #f)
                    (params . ((legs . (((kind . "exec") (rate . 2))))))))))

  (display "\n── usage units — the per-kind meters ──\n")
  (for-each (lambda (u)
              (check (string-append u " is a usage unit")
                     (usage-unit? u) #t))
            '("seconds" "tokens" "bytes" "byte-seconds" "readings"
              "node-hours"))
  (check "an unknown unit is not" (usage-unit? "widgets") #f)

  (display "\n── resources and needs — what an offer covers ──\n")
  (define res-reg
    (spawn ^machine-registry (hashmap) (hashmap) (hashmap) '()))

  (define res-offer
    ($ res-reg 'offer ALICE HOME "member" '(storage) 4 'deterministic
       "seconds" '(("storage-gb" . 2) ("net-mbps" . 10))))
  (check "an offer with resources lands" (string? res-offer))
  (check "the offer remembers its resources"
         (lane-offer-resources ($ res-reg 'offer-of res-offer))
         '(("storage-gb" . 2) ("net-mbps" . 10)))
  (check-error "a symbol-keyed resources alist is refused"
               (lambda () (make-lane-offer #:id "o" #:lender-did "l"
                          #:commune-aid "c" #:lane "m" #:task-classes '()
                          #:headroom 1 #:repro-mode 'none
                          #:usage-unit "seconds"
                          #:resources '((storage-gb . 4)))))
  (check-error "a non-numeric amount is refused"
               (lambda () (make-lane-offer #:id "o" #:lender-did "l"
                          #:commune-aid "c" #:lane "m" #:task-classes '()
                          #:headroom 1 #:repro-mode 'none
                          #:usage-unit "seconds"
                          #:resources '(("x" . "lots")))))

  (define needs-job
    ($ res-reg 'submit BOB HOME 'storage "member" 'deterministic "in:n"
       #f 1 #f '(("storage-gb" . 4))))
  (check "a need the offer cannot cover does not match"
         (length ($ res-reg 'match needs-job)) 0)
  (define met-job
    ($ res-reg 'submit BOB HOME 'storage "member" 'deterministic "in:m"
       #f 1 #f '(("storage-gb" . 1))))
  (check "a covered need matches"
         (length ($ res-reg 'match met-job)) 1)
  (define free-job
    ($ res-reg 'submit BOB HOME 'storage "member" 'deterministic "in:f"))
  (check "a job that names no needs matches"
         (length ($ res-reg 'match free-job)) 1)
  (check "the job remembers its needs"
         (machine-job-needs ($ res-reg 'job-of met-job)) '(("storage-gb" . 1))))

(with-vat vat
  (display "\n── the doors — issue, answer, verify ──\n")
  ;; a single governor so the borrower/lender/stranger boundary is real —
  ;; the test default lets everyone govern, which would hide it.
  (define GOV-AID "did:keri:EGovernor")
  (define gov (spawn-governance-service '() #f
                #:governor? (lambda (aid) (equal? aid GOV-AID))))

  (define s-offer
    (cdr ($ gov 'machine-offer ALICE HOME "member" "storage" 4
            "deterministic" 'resources '(("storage-gb" . 8)))))
  (define s-job
    (cdr ($ gov 'machine-submit BOB HOME "storage" "member" "deterministic"
            CONTENT-HASH 'envelope
            `((kind . "store") (bridgeJobId . "s-env")
              (inputHash . ,CONTENT-HASH) (caps . ()) (network . #f)
              (params . ((ttlSeconds . 60)))))))
  (check "a storage job submits" (string? s-job))
  (check "the resource-covered offer matches the storage job"
         (length (cdr ($ gov 'machine-match HOME s-job))) 1)
  (define s-claim
    (cdr ($ gov 'machine-claim ALICE HOME s-job s-offer)))
  (check "the claim lands" (string? s-claim))

  ;; the lender reads the envelope its claim carries — kind and params on
  ;; the wire
  (define env-wire ($ gov 'machine-fetch-envelope ALICE HOME s-claim))
  (check "machine-fetch-envelope returns the store envelope"
         (cdr (assoc "kind" (cdr env-wire))) "store")
  (check "the params ride with it"
         (cdr (assoc 'ttlSeconds (cdr (assoc "params" (cdr env-wire))))) 60)

  ;; issue
  (define ch1 ($ gov 'machine-challenge BOB HOME s-claim))
  (check "the borrower issues a challenge" (car ch1) 'ok)
  (define ch1-row (cdr ch1))
  (define ch1-id (cdr (assoc "id" ch1-row)))
  (define ch1-nonce (cdr (assoc "nonce" ch1-row)))
  (check "the row carries the claim" (cdr (assoc "claimId" ch1-row)) s-claim)
  (check "the nonce is 128-bit hex" (string-length ch1-nonce) 32)

  (check "the lender cannot issue"
         (car ($ gov 'machine-challenge ALICE HOME s-claim)) 'error)
  (check "a stranger cannot issue"
         (car ($ gov 'machine-challenge CAROL HOME s-claim)) 'error)
  (check "a governor can issue"
         (car ($ gov 'machine-challenge GOV-AID HOME s-claim)) 'ok)

  ;; answer — the lender hashes nonce ∥ the bytes it holds
  (define expected (challenge-answer-hash ch1-nonce CONTENT-BV))
  (check "the borrower cannot answer for the node"
         (car ($ gov 'machine-challenge-answer BOB HOME ch1-id expected))
         'error)
  (check "a short answer is refused"
         (car ($ gov 'machine-challenge-answer ALICE HOME ch1-id "beef"))
         'error)
  (define a-wire ($ gov 'machine-challenge-answer ALICE HOME ch1-id expected))
  (check "the lender's answer lands"
         (cdr (assoc "state" (cdr a-wire))) "answered")

  ;; verify — the issuer closes it against its own expected hash, bound to
  ;; the job's committed inputHash
  (check "a wrong content-hash cannot verify"
         (car ($ gov 'machine-challenge-verify BOB HOME ch1-id expected
                 "0000000000000000000000000000000000000000000000000000000000000000"))
         'error)
  (check "a non-issuer cannot verify"
         (car ($ gov 'machine-challenge-verify CAROL HOME ch1-id expected
                 CONTENT-HASH))
         'error)
  (define v1 ($ gov 'machine-challenge-verify BOB HOME ch1-id expected
                CONTENT-HASH))
  (check "an honest answer verifies reproduced"
         (cdr (assoc "verdict" (cdr v1))) "reproduced")

  ;; a second challenge the node answers WRONG — the mismatch lands on the
  ;; record, not in an exception
  (define ch2 ($ gov 'machine-challenge BOB HOME s-claim))
  (define ch2-id (cdr (assoc "id" (cdr ch2))))
  (define ch2-nonce (cdr (assoc "nonce" (cdr ch2))))
  ($ gov 'machine-challenge-answer ALICE HOME ch2-id
     (challenge-answer-hash ch2-nonce (string->utf8 "different bytes")))
  (define v2 ($ gov 'machine-challenge-verify BOB HOME ch2-id
                (challenge-answer-hash ch2-nonce CONTENT-BV) CONTENT-HASH))
  (check "a wrong answer verifies mismatch"
         (cdr (assoc "verdict" (cdr v2))) "mismatch")

  ;; a third the node never answers — silence is a failed proof
  (define ch3 ($ gov 'machine-challenge BOB HOME s-claim))
  (define ch3-id (cdr (assoc "id" (cdr ch3))))
  (define ch3-nonce (cdr (assoc "nonce" (cdr ch3))))
  (define v3 ($ gov 'machine-challenge-verify BOB HOME ch3-id
                (challenge-answer-hash ch3-nonce CONTENT-BV) CONTENT-HASH))
  (check "no answer verifies failed"
         (cdr (assoc "verdict" (cdr v3))) "failed")

  ;; the node's poll surface — three closed plus the governor's open one
  (check "machine-challenges lists the claim's four"
         (length (cdr ($ gov 'machine-challenges ALICE HOME s-claim))) 4)
  (check "a stranger cannot read the claim's challenges"
         (car ($ gov 'machine-challenges CAROL HOME s-claim)) 'error)

  ;; a non-storage claim carries no challenges — the challenge is the
  ;; store kind's proof shape, not a generic liveness ping
  (define e-offer
    (cdr ($ gov 'machine-offer CAROL HOME "member" "inference" 4
            "deterministic")))
  (define e-job
    (cdr ($ gov 'machine-submit BOB HOME "inference" "member"
            "deterministic" "in:x")))
  (define e-claim (cdr ($ gov 'machine-claim CAROL HOME e-job e-offer)))
  (check "a challenge on an exec claim is refused"
         (car ($ gov 'machine-challenge BOB HOME e-claim)) 'error)

  ;; a closed challenge takes no late answer
  (check "a late answer is refused"
         (car ($ gov 'machine-challenge-answer ALICE HOME ch1-id expected))
         'error))

(with-vat vat
  (display "\n── the record — expiry reads failed, not pending ──\n")
  (define stale (make-store-challenge #:id "chal-x" #:claim-id "c"
                                      #:issuer BOB #:nonce "aa"
                                      #:issued-at 100 #:deadline 200))
  (check "open before the deadline"
         (challenge-expired? stale 150) #f)
  (check "expired after it"
         (challenge-expired? stale 300) #t)
  (check "the wire word on silence is failed"
         (challenge-verdict stale 300) 'failed)
  (check "an answered record reads unverified"
         (challenge-verdict (challenge-answer! stale "ab") 150) 'unverified)
  (check-error "a closed challenge cannot re-verify"
               (lambda ()
                 (challenge-verify!
                  (challenge-verify! stale "ee") "ee"))))

(test-summary!)
