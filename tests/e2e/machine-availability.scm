;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-availability.scm — the availability profile end to end.
;;;
;;; params.availability on a 'bundle declares durable serving: lease-hours
;;; is the commitment the node-hours meter is read against, replicas names
;;; the borrower's fan-out (this claim is one of them). The descriptor
;;; crosses the shelf intact; a malformed one never reaches a claim; the
;;; receipt meters node-hours delivered — the honest fraction, not the
;;; promise.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-availability.scm

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

(define vat (spawn-vat #:name "machine-availability-e2e"))
(define HOME "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define NODE  "did:key:z6MkNode")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (scenario "availability — the descriptor crosses the shelf intact")

  (define offer-id
    (door-call gov ALICE 'machine-offer HOME "member" "storage" 4
               "deterministic"))
  (define env-wire
    `((kind . "bundle")
      (bridgeJobId . "bj-avail")
      (inputHash . "in:avail")
      (caps . ())
      (network . #f)
      (params . ((availability . ((lease-hours . 24)
                                  (replicas . 3)
                                  (replica-index . 1)))
                 (legs . (((kind . "store")
                           (inputHash . "content:cdn")
                           (params . ((contentB64 . "c2VydmVk")
                                      (ttlSeconds . 86400))))
                          ((kind . "relay")
                           (params . ((inUrl . "https://cdn/origin"))))))))))
  (define job-id
    (door-call gov BOB 'machine-submit HOME "storage" "member"
               "deterministic" "in:avail" 'envelope env-wire))
  (define claim-id
    (door-call gov ALICE 'machine-claim HOME job-id offer-id))
  (door-call gov BOB 'machine-accept HOME claim-id)

  (define fetched (door-call gov ALICE 'machine-fetch-envelope HOME claim-id))
  (check "the fetched envelope is bundle"
         (cdr (assoc "kind" fetched)) "bundle")
  (let* ((p (cdr (assoc "params" fetched)))
         (a (cdr (assq 'availability p))))
    (check "availability.lease-hours crossed"
           (cdr (assq 'lease-hours a)) 24)
    (check "availability.replicas crossed"
           (cdr (assq 'replicas a)) 3)
    (check "availability.replica-index crossed"
           (cdr (assq 'replica-index a)) 1)
    (check "the legs ride beside the descriptor"
           (length (cdr (assq 'legs p))) 2))

  (scenario "the node-hours receipt completes the claim")
  (define rcpt
    (make-receipt #:bridge-job-id claim-id #:lender-did NODE
                  #:input-hash "in:avail"
                  #:output-hash "out:avail"
                  #:usage (make-usage-meter #:unit "node-hours" #:amount 23.5)
                  #:executed-at 1761000002000))
  (check "a node-hours-metered receipt lands — under the lease, honest"
         (car ($ gov 'machine-receipt BOB HOME
                 `((bridgeJobId . ,claim-id) (lenderDid . ,NODE)
                   (inputHash . "in:avail") (outputHash . "out:avail")
                   (usage . ((unit . "node-hours") (amount . 23.5)))
                   (executedAt . 1761000002000)
                   (digest . ,(receipt-digest rcpt)))))
         'ok)

  (scenario "a malformed availability descriptor is refused at submit")
  (define (submit-with-availability a)
    ($ gov 'machine-submit BOB HOME "storage" "member"
       "deterministic" "in:bad" 'envelope
       (map (lambda (p)
              (if (equal? (car p) 'params)
                  (cons 'params `((availability . ,a)
                                  (legs . (((kind . "exec")
                                            (image . "js:")
                                            (entrypoint . "(i)=>i"))))))
                  p))
            env-wire)))
  (check "no lease-hours → refused"
         (car (submit-with-availability '((replicas . 3))))
         'error)
  (check "zero lease-hours → refused"
         (car (submit-with-availability '((lease-hours . 0))))
         'error)
  (check "zero replicas → refused"
         (car (submit-with-availability '((lease-hours . 24)
                                          (replicas . 0))))
         'error)
  (check "a negative replica-index → refused"
         (car (submit-with-availability '((lease-hours . 24)
                                          (replica-index . -1))))
         'error)

  (scenario "availability on a non-bundle is refused")
  (check "an exec envelope cannot wear availability"
         (car ($ gov 'machine-submit BOB HOME "compute" "member"
                 "deterministic" "in:bad" 'envelope
                 '((kind . "exec") (bridgeJobId . "bj-x")
                   (image . "js:") (entrypoint . "(i)=>i")
                   (inputHash . "in:x") (caps . ()) (network . #f)
                   (params . ((availability . ((lease-hours . 1))))))))
         'error))

(test-summary!)