;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-inference.scm — the inference profile end to end.
;;;
;;; params.model commits the artifact the node decodes: the descriptor
;;; crosses the shelf intact, the claim runs it, the receipt meters
;;; tokens — and 'deterministic replay reruns the committed seed, not a
;;; similar decode. A malformed descriptor never reaches a claim.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-inference.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine specs)
             (localchimera machine receipt)
             (localchimera machine registry)
             (localchimera machine envelope)
             (localchimera machine challenge)
             (localchimera machine replay)
             (localchimera machine executors)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-inference-e2e"))
(define HOME "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define NODE  "did:key:z6MkNode")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (scenario "inference — the model descriptor crosses the shelf intact")

  (define model-desc
    '((uri . "https://models.example/mini-q4.gguf")
      (sha256 . "ab12cd34ef56")
      (format . "gguf-wasm")
      (context . 2048)
      (seed . 7)))

  (define offer-id
    (door-call gov ALICE 'machine-offer HOME "member" "inference" 4
               "deterministic"))
  (define env-wire
    `((kind . "exec")
      (bridgeJobId . "bj-inference")
      (image . "wasm:engine@1")
      (entrypoint . "_start")
      (inputHash . "in:inference")
      (caps . ())
      (network . #t)
      (params . ((model . ,model-desc)))))
  (define job-id
    (door-call gov BOB 'machine-submit HOME "inference" "member"
               "deterministic" "in:inference" 'envelope env-wire))
  (define claim-id
    (door-call gov ALICE 'machine-claim HOME job-id offer-id))
  (door-call gov BOB 'machine-accept HOME claim-id)

  (define fetched (door-call gov ALICE 'machine-fetch-envelope HOME claim-id))
  (check "the fetched envelope is exec"
         (cdr (assoc "kind" fetched)) "exec")
  (let ((m (cdr (assq 'model (cdr (assoc "params" fetched))))))
    (check "model.uri crosses intact"
           (cdr (assq 'uri m)) "https://models.example/mini-q4.gguf")
    (check "model.sha256 crosses intact"
           (cdr (assq 'sha256 m)) "ab12cd34ef56")
    (check "model.seed crosses intact"
           (cdr (assq 'seed m)) 7))

  (scenario "a malformed model descriptor is refused at submit")
  (let ((bad (map (lambda (p)
                    (if (equal? (car p) 'params)
                        (cons 'params `((model . ((uri . "u") (format . "gguf-wasm")))))
                        p))
                  env-wire)))
    (check "a model without sha256 never reaches a claim"
           (car ($ gov 'machine-submit BOB HOME "inference" "member"
                   "deterministic" "in:bad" 'envelope bad))
           'error))

  (scenario "the tokens receipt completes the claim, seeded repro rides it")
  (define rcpt
    (make-receipt #:bridge-job-id claim-id #:lender-did NODE
                  #:input-hash "in:inference"
                  #:output-hash "out:inference"
                  #:usage (make-usage-meter #:unit "tokens" #:amount 512)
                  #:repro (make-repro-spec #:mode 'deterministic #:seed 7)
                  #:executed-at 1761000002000))
  (define rcpt-wire
    `((bridgeJobId . ,claim-id) (lenderDid . ,NODE)
      (inputHash . "in:inference") (outputHash . "out:inference")
      (usage . ((unit . "tokens") (amount . 512)))
      (repro . ((mode . "deterministic") (seed . 7)))
      (executedAt . 1761000002000)
      (digest . ,(receipt-digest rcpt))))
  (check "a tokens-metered receipt lands"
         (car ($ gov 'machine-receipt BOB HOME rcpt-wire)) 'ok)

  (scenario "deterministic replay reruns the committed seed")
  ;; the executor a challenger would run: the door composes the registry's
  ;; executor, and the spec it is called with MUST carry the envelope's
  ;; committed seed — record what arrived, answer the claimed hash.
  (define seen-seed #f)
  (register-executor!
   'any (make-replay-executor
         #:kind 'local #:name "e2e-stub"
         #:run (lambda (env spec)
                 (set! seen-seed (repro-spec-seed spec))
                 "out:inference")))
  (let ((res (cdr ($ gov 'machine-replay BOB HOME claim-id))))
    (check "the replay door answers reproduced"
           (cdr (assoc "reproduced" res)) 'reproduced)
    (check "the executor saw the committed seed"
           seen-seed 7)
    (check "the counter-hash is the claimed output"
           (cdr (assoc "counterHash" res)) "out:inference"))
  (unregister-executor! 'any)

  (scenario "a mismatched replay is the dispute's evidence, not a pass")
  (register-executor!
   'any (make-replay-executor
         #:kind 'local #:name "e2e-wrong"
         #:run (lambda (env spec) "out:different")))
  (let ((res (cdr ($ gov 'machine-replay BOB HOME claim-id))))
    (check "a different decode answers mismatch"
           (cdr (assoc "reproduced" res)) 'mismatch)
    (check "the counter-hash names what replay actually got"
           (cdr (assoc "counterHash" res)) "out:different"))
  (unregister-executor! 'any))

(test-summary!)
