;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-kinds.scm — every envelope kind through the doors.
;;;
;;; The lifecycle suite walks the exec story; this one walks the KINDS:
;;; 'store, 'relay, 'sense, 'bundle — each submitted as a wire envelope,
;;; claimed, fetched back, and answered with the receipt its meter names.
;;; The envelope's kind and params must cross the shelf intact — a node
;;; that fetches a 'store envelope and reads 'exec has a different job
;;; than the one the borrower committed.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-kinds.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine specs)
             (localchimera machine receipt)
             (localchimera machine registry)
             (localchimera machine envelope)
             (localchimera machine challenge)
             (localchimera machine replay)
             (localchimera machine binding)
             (localchimera machine binding-verifiers)
             (localchimera keri signify)          ; installs the ed25519 backend
             ((localchimera keri signify-portable) #:select (seed->ed25519-keypair))
             ((localchimera keri crypto-primitives) #:select (ed25519-keypair-public))
             ((localchimera keri citizen-sig) #:select (sign-said))
             (localchimera machine payout)
             (localchimera machine settlement)
             (localchimera machine executors)
             (localchimera utils store-utils)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-kinds-e2e"))
(define HOME "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define NODE  "did:key:z6MkNode")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (define (kind-run kind class params usage-unit usage-amount)
    "Offer → submit an envelope of KIND with PARAMS → claim → fetch →
     receipt in USAGE-UNIT. Answers (claim-id fetched-envelope)."
  (let* ((offer-id (door-call gov ALICE 'machine-offer HOME "member" class
                              4 "deterministic"))
         (env-wire `((kind . ,(symbol->string kind))
                     (bridgeJobId . ,(string-append "bj-" (symbol->string kind)))
                     (inputHash . ,(string-append "in:" (symbol->string kind)))
                     (caps . ()) (network . #f)
                     (params . ,params)))
         (job-id (door-call gov BOB 'machine-submit HOME class "member"
                            "deterministic"
                            (string-append "in:" (symbol->string kind))
                            'envelope env-wire))
         (claim-id (door-call gov ALICE 'machine-claim HOME job-id offer-id)))
    (door-call gov BOB 'machine-accept HOME claim-id)
    (list claim-id (door-call gov ALICE 'machine-fetch-envelope HOME claim-id))))

  (define (land-receipt claim-id usage-unit usage-amount input-hash)
    "The node's countersigned receipt body, posted through the door —
     the claim completes in its kind's unit."
    (let* ((rcpt (make-receipt #:bridge-job-id claim-id #:lender-did NODE
                               #:input-hash input-hash
                               #:output-hash (string-append "out:" input-hash)
                               #:usage (make-usage-meter #:unit usage-unit
                                                         #:amount usage-amount)
                               #:executed-at 1761000002000))
           (wire `((bridgeJobId . ,claim-id) (lenderDid . ,NODE)
                   (inputHash . ,input-hash)
                   (outputHash . ,(string-append "out:" input-hash))
                   (usage . ((unit . ,usage-unit) (amount . ,usage-amount)))
                   (executedAt . 1761000002000)
                   (digest . ,(receipt-digest rcpt)))))
      ($ gov 'machine-receipt BOB HOME wire)))

  (scenario "lenderSig — a did:key lender's signature verifies door-side")
  ;; the node IS its key: the receipt's lenderDid names the did:key the
  ;; signature checks against — no resolver, no binding needed to read it
  (let* ((kp (seed->ed25519-keypair
              (u8-list->bytevector (iota 32 1))))
         (node-did (ed25519-pubkey->did-key (ed25519-keypair-public kp)))
         (rcpt (make-receipt #:bridge-job-id "claim-signed"
                             #:lender-did node-did
                             #:input-hash "in:signed"
                             #:output-hash "out:signed"
                             #:usage (make-usage-meter #:unit "seconds"
                                                       #:amount 1)
                             #:executed-at 1761000002000))
         (digest (receipt-digest rcpt))
         (wire `((bridgeJobId . "claim-signed") (lenderDid . ,node-did)
                 (inputHash . "in:signed") (outputHash . "out:signed")
                 (usage . ((unit . "seconds") (amount . 1)))
                 (executedAt . 1761000002000)
                 (lenderSig . ,(sign-said digest kp))
                 (digest . ,digest))))
    (check "machine-verify answers 'verified on a real signature"
           (cdr ($ gov 'machine-verify wire)) '(#t verified))
    ;; a genuinely tampered sig: signed over other bytes, so it fails
    ;; against the digest the door recomputes from this body
    (let ((forged (map (lambda (p)
                         (if (equal? (car p) 'lenderSig)
                             (cons 'lenderSig (sign-said "deadbeef" kp))
                             p))
                       wire)))
      (check "a sig over a different digest is 'bad, not 'verified"
             (cdr ($ gov 'machine-verify forged)) '(#t bad)))
    (check "an unsigned receipt stays 'unverifiable, never refused at verify"
           (cdr ($ gov 'machine-verify
                    (filter (lambda (p) (not (equal? (car p) 'lenderSig)))
                            wire)))
           '(#t unverifiable)))

  (scenario "store — the envelope keeps its kind and content commitment")
  (let* ((run (kind-run 'store "storage"
                        `((contentB64 . "aGVsbG8=") (ttlSeconds . 3600))
                        "byte-seconds" 3600))
         (claim-id (car run)) (env (cadr run)))
    (check "the fetched envelope is 'store"
           (cdr (assoc "kind" env)) "store")
    (check "params cross with their inner keys"
           (cdr (assq 'ttlSeconds (cdr (assoc "params" env)))) 3600)
    ;; the retention challenge the node will answer rides the same claim
    (define ch (cdr ($ gov 'machine-challenge BOB HOME claim-id)))
    (check "a challenge lands on the store claim"
           (eq? (car ($ gov 'machine-challenges BOB HOME claim-id)) 'ok) #t)
    (check "the byte-seconds receipt completes the claim"
           (car (land-receipt claim-id "byte-seconds" 3600 "in:store")) 'ok))

  (scenario "relay — signal on the claim, then meter the bytes")
  (let* ((run (kind-run 'relay "bandwidth"
                        `((inUrl . "https://in") (outUrl . "https://out"))
                        "bytes" 2048))
         (claim-id (car run)) (env (cadr run)))
    (check "the fetched envelope is 'relay"
           (cdr (assoc "kind" env)) "relay")
    ;; the rendezvous the browser legs negotiate through — same claim
    (check "the parties signal on the claim"
           (eq? (car ($ gov 'machine-signal BOB HOME claim-id
                        '((type . "offer") (sdp . "e2e-sdp")))) 'ok)
           #t)
    (check "the counterparty polls it back"
           (length (cdr ($ gov 'machine-signals ALICE HOME claim-id))) 1)
    (check "the bytes receipt completes the claim"
           (car (land-receipt claim-id "bytes" 2048 "in:relay")) 'ok))

  (scenario "sense — readings on the meter")
  (let* ((run (kind-run 'sense "canary"
                        `((sources . #("battery" "network"))
                          (intervalMs . 5000) (count . 3))
                        "readings" 6))
         (claim-id (car run)) (env (cadr run)))
    (check "the fetched envelope is 'sense"
           (cdr (assoc "kind" env)) "sense")
    (check "the readings receipt completes the claim"
           (car (land-receipt claim-id "readings" 6 "in:sense")) 'ok))

  (scenario "sense — a malformed stream refuses at submit, not in the node")
  ;; the instrument's contract crosses the envelope: no sources is no
  ;; instrument, and a session knob that isn't positive measures nothing —
  ;; the door refuses before a claim is ever minted
  (define (submit-sense params)
    (car ($ gov 'machine-submit BOB HOME "canary" "member"
            "deterministic" "in:bad-sense"
            'envelope `((kind . "sense") (bridgeJobId . "bj-bs")
                        (inputHash . "in:bs") (caps . ()) (network . #f)
                        (params . ,params)))))
  (check "a sense envelope with no sources refuses"
         (submit-sense '((count . 3))) 'error)
  (check "empty sources is still no instrument"
         (submit-sense '((sources . ()))) 'error)
  (check "a zero-count session refuses — it would sample nothing"
         (submit-sense '((sources . #("machine")) (count . 0))) 'error)
  (check "a negative interval is not a tick"
         (submit-sense '((sources . #("machine")) (intervalMs . -5))) 'error)
  (check "a duration-bound session parses — count is not the only shape"
         (submit-sense '((sources . #("machine")) (durationMs . 5000))) 'ok)

  (scenario "bundle — legs cross inside params, no price survives")
  ;; a bundle leg's first alist pair CANNOT be a price key — the
  ;; recursive check walks every nested element now
  (check "a leg's leading price key is refused at submit"
         (car ($ gov 'machine-submit BOB HOME "compute" "member"
                 "deterministic" "in:bad"
                 'envelope `((kind . "bundle") (bridgeJobId . "bj-bad")
                             (inputHash . "in:bad") (caps . ()) (network . #f)
                             (params . ((legs . (((price . 5)
                                                  (kind . "exec")))))))))
         'error)
  (let* ((run (kind-run 'bundle "compute"
                        `((legs . (((kind . "exec") (image . "js:")
                                    (entrypoint . "(i)=>i"))
                                   ((kind . "sense")
                                    (params . ((sources . #("machine"))
                                               (count . 1)))))))
                        "seconds" 2))
         (claim-id (car run)) (env (cadr run)))
    (check "the fetched envelope is 'bundle"
           (cdr (assoc "kind" env)) "bundle")
    (check "the legs crossed intact"
           (length (cdr (assq 'legs (cdr (assoc "params" env))))) 2)
    (check "the seconds receipt completes the claim"
           (car (land-receipt claim-id "seconds" 2 "in:bundle")) 'ok)))

(test-summary!)
