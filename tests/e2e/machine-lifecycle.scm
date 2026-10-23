;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/compute-lifecycle.scm — the whole compute story, in order.
;;;
;;; Not one act — the chain: a lender binds a did:key node to its AID with
;;; real signatures, offers a lane, a borrower submits an enveloped job,
;;; the lender claims, fetches the envelope, runs it (a registered
;;; executor), countersigns the receipt, the registry verifies it, replay
;;; reproduces, the bridge statement settles, and the payout rail sends to
;;; the bound treasury — every hop a door call, every signature real.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/compute-lifecycle.scm

(use-modules (playnet test harness)
             (playnet test e2e)
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
             (playnet doors machine)
             (playnet delegates)
             (playnet boot governance)
             (playnet keri signify-portable)
             (playnet keri crypto-primitives)
             (playnet keri cesr)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (srfi srfi-1))

(define vat (spawn-vat #:name "compute-lifecycle-e2e"))
(define HOME "did:keri:EHomeCommune")

;; real identities: seeds → keypairs → a did:key node and AID lenders.
;; bran->signing-keypair accepts a bran string; deterministic across runs.
(define node-kp  (bran->signing-keypair "playnet-e2e-node-keypair-0000001"))
(define alice-kp (bran->signing-keypair "playnet-e2e-alice-keypair-000001"))
(define bob-kp   (bran->signing-keypair "playnet-e2e-bob-keypair-00000001"))

(define NODE  (ed25519-pubkey->did-key (ed25519-keypair-public node-kp)))
(define ALICE (public-key->aid-prefix (ed25519-keypair-public alice-kp)))
(define BOB   (public-key->aid-prefix (ed25519-keypair-public bob-kp)))

;; sign a binding statement and CESR-encode it the way the verifiers read
(define (sig-of statement kp)
  (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 statement) kp)))

(with-vat vat
  ;; a scope that grants gov-caps, so commune acts (settle, payout) are
  ;; reachable — same fake shape test-registry uses
  (define fake-scope
    (spawn (lambda (bcom)
             (methods ((mint-gov-cap aid) 'cap)
                      ((scope-aid) HOME)))))
  (define gov
    (spawn-governance-service '() #f #:scope-of (lambda (aid) fake-scope)))

  (scenario "identity — bind the node's did:key to the lender's AID, real sigs")

  (check "the node identity is a did:key" (string-prefix? "did:key:z" NODE) #t)
  (check "the lender identity is an AID" (string-prefix? "D" ALICE) #t)

  ;; the binding: NODE (signer, did:key) ↔ keri:ALICE (account). Both
  ;; sides sign the same statement — verify-binding checks each under its
  ;; own key.
  (define link
    (make-account-link #:did-key NODE #:scope-aid HOME
                       #:account (string-append "keri:" ALICE)
                       #:purpose 'node #:nonce "e2e-n1" #:expiry 9999999999))
  (define bind-wire
    `((didKey . ,NODE)
      (account . ,(string-append "keri:" ALICE))
      (purpose . "node") (nonce . "e2e-n1") (expiry . 9999999999)
      (signerSig . ,(sig-of (binding-statement link) node-kp))
      (accountSig . ,(sig-of (binding-statement link) alice-kp))))
  (define bind-res ($ gov 'machine-bind ALICE HOME bind-wire))
  (check "machine-bind: the dual-signed link verifies"
         (cdr (assoc "verdict" (cdr bind-res))) 'ok)
  (define bind-key (cdr (assoc "key" (cdr bind-res))))

  (scenario "lending — offer, submit, match, claim, accept")

  (define offer-id
    (door-call gov ALICE 'machine-offer HOME "member" "inference,fetch"
               4 "deterministic"))
  (check "the lane offer lands" (string? offer-id) #t)

  (define env-wire
    `((bridgeJobId . "bj-e2e") (image . "js:solve.js") (entrypoint . "run")
      (inputHash . "in:e2e") (caps . ()) (network . #f)))
  (define job-id
    (door-call gov BOB 'machine-submit HOME "inference" "member"
               "deterministic" "in:e2e" 'envelope env-wire
               'envelopeHash "eh:e2e"))
  (check "the job lands with its envelope" (string? job-id) #t)

  (check "the offer answers the job"
         (length (cdr ($ gov 'machine-match HOME job-id))) 1)

  (define claim-id
    (door-call gov ALICE 'machine-claim HOME job-id offer-id))
  (check "the claim binds offer to job" (string? claim-id) #t)
  (check "the borrower accepts"
         (car ($ gov 'machine-accept BOB HOME claim-id)) 'ok)

  (scenario "execution — fetch, run, countersign, verify")

  (define fetched
    (cdr ($ gov 'machine-fetch-envelope ALICE HOME claim-id)))
  (check "the lender fetches the envelope it runs"
         (cdr (assoc "image" fetched)) "js:solve.js")
  (check "the envelope carries no amount"
         (not (assoc "amount" fetched)) #t)

  ;; the node runs the envelope and countersigns — the receipt body the
  ;; browser executor would emit
  (define rcpt
    (make-receipt #:bridge-job-id claim-id #:lender-did NODE
                  #:input-hash "in:e2e" #:output-hash "out:e2e"
                  #:usage (make-usage-meter #:unit "seconds" #:amount 3)
                  #:repro (make-repro-spec #:mode 'deterministic #:seed 7)
                  #:executed-at 1761000002000))
  (define rcpt-wire
    `((bridgeJobId . ,claim-id) (lenderDid . ,NODE)
      (inputHash . "in:e2e") (outputHash . "out:e2e")
      (usage . ((unit . "seconds") (amount . 3)))
      (repro . ((mode . "deterministic") (seed . 7)))
      (executedAt . 1761000002000)
      (digest . ,(receipt-digest rcpt))))

  (define v-res (cdr ($ gov 'machine-verify rcpt-wire)))
  (check "machine-verify: the receipt body is consistent"
         (car v-res) #t)

  (check "machine-receipt lands — the claim completes"
         (car ($ gov 'machine-receipt BOB HOME rcpt-wire)) 'ok)
  (check "the claim is complete on the book"
         (cdr (assoc "state" (car (cdr ($ gov 'machine-claims HOME)))))
         "complete")

  (scenario "proof — a registered executor replays the work")

  (register-executor! HOME
    (make-replay-executor #:kind 'wasmcloud #:name "host-1"
                          #:run (lambda (env repro) "out:e2e")))
  (define replay-res (cdr ($ gov 'machine-replay ALICE HOME claim-id)))
  (check "replay reproduces the output"
         (cdr (assoc "reproduced" replay-res)) 'reproduced)
  (check "the challenge carries the receipt digest"
         (string? (cdr (assoc "receiptDigest" replay-res))) #t)
  (unregister-executor! HOME)

  (scenario "settlement — the bridge statement reconciles")

  (define stmt-wire
    `((period . ("2026-10-01" . "2026-10-31"))
      (entries . (((bridgeJobId . ,claim-id)
                   (receiptDigest . ,(receipt-digest rcpt))
                   (amount . 42)
                   (asset . "eip155:1/slip44:60"))))
      (payments . ())
      (bridgeSig . "e2e-bridge-sig")))
  (define settle-res (cdr ($ gov 'machine-settle ALICE HOME stmt-wire)))
  (check "the statement reconciles: one matched, none held"
         (car settle-res) 1)
  (check "the statement lands on the book"
         (length (cdr ($ gov 'machine-statements HOME))) 1)

  (scenario "payout — the send rail reaches the bound treasury only")

  ;; the payout binding: NODE ↔ a CAIP-10 treasury, purpose 'payout.
  ;; keri: would be an identity, not a payee — eip155: is the Safe form.
  (define pay-link
    (make-account-link #:did-key NODE #:scope-aid HOME
                       #:account "eip155:1:0xSafeTreasuryE2E"
                       #:purpose 'payout #:nonce "e2e-p1" #:expiry 9999999999))
  ;; did:key signer side is real; the eip155 side can't be signed without a
  ;; secp256k1 key — verify-binding answers the account side's honest
  ;; verdict (bad-signature: the form is readable, our stand-in sig is not)
  (define pay-wire
    `((didKey . ,NODE)
      (account . "eip155:1:0xSafeTreasuryE2E")
      (purpose . "payout") (nonce . "e2e-p1") (expiry . 9999999999)
      (signerSig . ,(sig-of (binding-statement pay-link) node-kp))
      (accountSig . "0xdeadbeef")))
  (define pay-res ($ gov 'machine-bind ALICE HOME pay-wire))
  (check "the treasury binding lands — signer verified, eoa unread"
         (and (member (cdr (assoc "verdict" (cdr pay-res)))
                      '(bad-signature ok)) #t) #t)
  (define pay-key (cdr (assoc "key" (cdr pay-res))))

  ;; the payout: inject a send rail, watch every send land at the Safe
  (define sends '())
  (define pay-out
    (parameterize ((*machine-send-rail*
                    (lambda (to amt asset)
                      (set! sends (cons (list to amt asset) sends))
                      "0xTxE2E")))
      ($ gov 'machine-payout ALICE HOME
         `((statement . ((period . ("2026-10-01" . "2026-10-31"))
                         (entries . (((bridgeJobId . ,claim-id)
                                      (receiptDigest . ,(receipt-digest rcpt))
                                      (amount . 42)
                                      (asset . "eip155:1/slip44:60"))))
                         (payments . ())
                         (bridgeSig . "e2e-bridge-sig")))
           (bindingKey . ,pay-key)))))
  (check "machine-payout answers tx rows"
         (car pay-out) 'ok)
  (check "every send lands at the bound treasury Safe"
         (every (lambda (s) (equal? (car s) "eip155:1:0xSafeTreasuryE2E"))
                sends) #t)
  (check "without the rail the payout refuses, not pretends"
         (car ($ gov 'machine-payout ALICE HOME
                 `((statement . ((period . "w")
                                 (entries . (((bridgeJobId . ,claim-id)
                                              (receiptDigest . ,(receipt-digest rcpt))
                                              (amount . 1)
                                              (asset . "eip155:1/slip44:60"))))
                                 (payments . ())))
                   (bindingKey . ,pay-key)))) 'error)

  (scenario "policy — OPA consults on the commune acts")

  ;; an OPA delegate over a stub transport: deny → refuse, allow → pass,
  ;; 'unavailable → the local gate alone decides (gov-cap already held).
  (define (opa-stub answer)
    (make-opa-delegate (lambda (m p b) (cons 200 answer))))
  (define settle-call
    (lambda ()
      ($ gov 'machine-settle ALICE HOME
         `((period . ("2026-11-01" . "2026-11-30"))
           (entries . ()) (payments . ()) (bridgeSig . "x")))))

  (check "OPA deny refuses a governor — the engine's answer governs"
         (car (parameterize ((*machine-authz*
                              (opa-stub "{\"result\":{\"allow\":false}}")))
                (settle-call)))
         'error)
  (check "OPA allow lets the settled governor through"
         (car (parameterize ((*machine-authz*
                              (opa-stub "{\"result\":{\"allow\":true}}")))
                (settle-call)))
         'ok)
  (check "OPA unavailable falls through to the local gate"
         (car (parameterize ((*machine-authz*
                              (make-opa-delegate
                               (lambda (m p b)
                                 (throw 'unreachable)))))
                (settle-call)))
         'ok))

(test-summary!)
