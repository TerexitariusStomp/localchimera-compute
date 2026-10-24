;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-egress.scm — the egress relay profile end to end.
;;;
;;; params.profile 'egress asks the node to exit to the open internet on
;;; the borrower's behalf: the envelope refuses early without a
;;; destination or the fetch grant, the claim carries the destination
;;; across the shelf intact, and the receipt meters the bytes the exit
;;; actually carried. The destination policy is the lender's gate —
;;; envelope-side the shape is all that's checked.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-egress.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine specs)
             (localchimera machine receipt)
             (localchimera machine registry)
             (localchimera machine envelope)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-egress-e2e"))
(define HOME "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define NODE  "did:key:z6MkNode")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (scenario "egress — the destination crosses the shelf intact")

  (define offer-id
    (door-call gov ALICE 'machine-offer HOME "member" "bandwidth" 4
               "deterministic"))
  (define env-wire
    `((kind . "relay")
      (bridgeJobId . "bj-egress")
      (inputHash . "in:egress")
      (caps . ("fetch"))
      (network . #t)
      (params . ((profile . "egress")
                 (destination . "https://cdn.example/file")
                 (method . "GET")))))
  (define job-id
    (door-call gov BOB 'machine-submit HOME "bandwidth" "member"
               "deterministic" "in:egress" 'envelope env-wire))
  (define claim-id
    (door-call gov ALICE 'machine-claim HOME job-id offer-id))
  (door-call gov BOB 'machine-accept HOME claim-id)

  (define fetched (door-call gov ALICE 'machine-fetch-envelope HOME claim-id))
  (check "the fetched envelope is relay"
         (cdr (assoc "kind" fetched)) "relay")
  (check "the network grant crossed"
         (cdr (assoc "network" fetched)) #t)
  (let ((p (cdr (assoc "params" fetched))))
    (check "params.profile crossed"
           (cdr (assq 'profile p)) "egress")
    (check "params.destination crossed intact"
           (cdr (assq 'destination p)) "https://cdn.example/file"))

  (scenario "the bytes receipt completes the claim")
  (define rcpt
    (make-receipt #:bridge-job-id claim-id #:lender-did NODE
                  #:input-hash "in:egress"
                  #:output-hash "out:egress"
                  #:usage (make-usage-meter #:unit "bytes" #:amount 4096)
                  #:executed-at 1761000002000))
  (check "a bytes-metered receipt lands"
         (car ($ gov 'machine-receipt BOB HOME
                 `((bridgeJobId . ,claim-id) (lenderDid . ,NODE)
                   (inputHash . "in:egress") (outputHash . "out:egress")
                   (usage . ((unit . "bytes") (amount . 4096)))
                   (executedAt . 1761000002000)
                   (digest . ,(receipt-digest rcpt)))))
         'ok)

  (scenario "an egress shape without its grant is refused at submit")
  ;; each of these is a job that could never run — refused where the
  ;; envelope parses, not inside the lender's executor. Wire keys
  ;; REPLACE, not append — assq reads the first pair.
  (define (wire-with . replaces)
    (map (lambda (p)
           (cond ((assoc (car p) replaces) => (lambda (r) (cons (car p) (cdr r))))
                 (else p)))
         env-wire))
  (define (submit-wire wire)
    ($ gov 'machine-submit BOB HOME "bandwidth" "member"
       "deterministic" "in:bad" 'envelope wire))
  (check "no destination → refused"
         (car (submit-wire
               (wire-with '(params . ((profile . "egress"))))))
         'error)
  (check "network:#f → refused"
         (car (submit-wire
               (wire-with '(network . #f)
                          '(params . ((profile . "egress")
                                      (destination . "https://x"))))))
         'error)
  (check "no fetch cap → refused"
         (car (submit-wire
               (wire-with '(caps . ())
                          '(params . ((profile . "egress")
                                      (destination . "https://x"))))))
         'error)
  (check "a non-egress relay without destination still parses"
         (car (submit-wire
               (wire-with '(network . #f) '(caps . ())
                          '(params . ((inUrl . "https://in"))))))
         'ok))

(test-summary!)