;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-bridge.scm — ring 3's provider legs through the doors.
;;;
;;; The bridge is the router's outbound half: a borrower whose commune
;;; can't serve a ring:3 job may send it to a provider network — golem for
;;; exec, mysterium for relay egress, storj for store — with the attempt
;;; landing in the ledger the settlement edge reads. The rules this suite
;;; pins: the borrower alone routes its own job, ring:3 is the privacy
;;; bound (a job that never declared it can't cross), OUR capacity always
;;; wins (an inner offer makes the bridge refuse), and no transport means
;;; an honest 'unavailable — never a fabricated result.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-bridge.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine registry)
             (localchimera machine providers)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-bridge-e2e"))
(define HOME  "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define CAROL "did:keri:DCarolStranger")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (define (outbound-job kind ring)
    "A ring:3 envelope job in BOB's name — the work that may cross."
    (door-call gov BOB 'machine-submit HOME "swarm-infer" "member"
               "deterministic" "in:outbound"
               'envelope `((kind . ,kind)
                           (bridgeJobId . "bj-out")
                           (image . "js:shard") (entrypoint . "main")
                           (inputHash . "in:outbound")
                           (caps . ()) (network . #f) (params . ()))
               'ring ring))

  (scenario "the privacy bound — only a ring:3 job may cross")
  (define inner-job (outbound-job "exec" 1))
  (check "a ring:1 job never reaches a provider"
         (car ($ gov 'machine-bridge-submit BOB HOME inner-job "golem"))
         'error)
  (define open-job (outbound-job "exec" 3))
  (check "a stranger cannot route the borrower's job"
         (car ($ gov 'machine-bridge-submit CAROL HOME open-job "golem"))
         'error)
  (check "a provider that doesn't serve the kind refuses"
         (car ($ gov 'machine-bridge-submit BOB HOME open-job "storj"))
         'error)

  (scenario "no transport — the call fails closed, honestly")
  (check "an unwired provider answers 'unavailable, not a result"
         (car ($ gov 'machine-bridge-submit BOB HOME open-job "golem"))
         'error)

  (scenario "local-first — inner capacity always wins")
  ;; ALICE's offer answers the job's class: the commune has capacity, so
  ;; the provider stays fallback — the door refuses to send it out.
  (define alice-offer
    (door-call gov ALICE 'machine-offer HOME "member" "swarm-infer"
               4 "deterministic"))
  (check "a matchable job refuses the bridge — claim it here"
         (car ($ gov 'machine-bridge-submit BOB HOME open-job "golem"))
         'error)

  (scenario "the outbound leg — transport injected, attempt ledgered")
  ;; a class the offer can't answer routes out: 'canary is not in
  ;; ALICE's swarm-infer lane, so the commune's match stays empty.
  (register-provider-transport!
   'golem (lambda (method path body)
            `((taskId . "glm-task-7") (outputHash . "out:glm")
              (ref . "glm-task-7"))))
  (define far-job
    (door-call gov BOB 'machine-submit HOME "canary" "member"
               "deterministic" "in:far"
               'envelope `((kind . "exec")
                           (bridgeJobId . "bj-far")
                           (image . "js:shard") (entrypoint . "main")
                           (inputHash . "in:far")
                           (caps . ()) (network . #f) (params . ()))
               'ring 3))
  (define attempt
    (door-call gov BOB 'machine-bridge-submit HOME far-job "golem"))
  (check "the provider's ref lands in the ledger"
         (list-ref attempt 3) "glm-task-7")
  (check "the result hash lands beside it"
         (list-ref attempt 4) "out:glm")
  (check "the attempt reads 'answered"
         (list-ref attempt 5) "answered")
  (let ((rows (door-call gov BOB 'machine-bridge-attempts HOME far-job)))
    (check "the borrower reads its attempts back"
           (length rows) 1)
    (check "the row names the network"
           (list-ref (car rows) 2) "golem"))
  (check "the borrower's ledger is the borrower's read"
         (car ($ gov 'machine-bridge-attempts CAROL HOME far-job))
         'error)
  (check "a claimed job no longer routes out"
         (let* ((claim (door-call gov ALICE 'machine-claim HOME open-job
                                  alice-offer)))
           (car ($ gov 'machine-bridge-submit BOB HOME open-job "golem")))
         'error)
  (unregister-provider-transport! 'golem))
