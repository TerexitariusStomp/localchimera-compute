;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-exit-paths.scm — how a commitment ends before work.
;;;
;;; Three doors close a commitment the receipt path never reaches:
;;; machine-retract pulls an open offer (it stops matching), machine-
;;; withdraw pulls an open job (it can no longer be claimed), and
;;; machine-preempt ends a live claim — the spec's SubmitOutcome
;;; 'preempted: a recorded fact, no payment, no miss.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-exit-paths.scm

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
             (localchimera machine payout)
             (localchimera machine settlement)
             (localchimera machine executors)
             (localchimera utils store-utils)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-exit-e2e"))
(define HOME "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define CAROL "did:keri:DCarolStranger")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (scenario "retract — an open offer stops matching")
  (define offer-1 (door-call gov ALICE 'machine-offer HOME "member"
                             "compute" 4 "deterministic"))
  (define job-1 (door-call gov BOB 'machine-submit HOME "compute" "member"
                           "deterministic" "in:r1"))
  (check "the live offer answers the job"
         (length (cdr ($ gov 'machine-match HOME job-1))) 1)
  (check "a stranger cannot retract someone else's offer"
         (car ($ gov 'machine-retract CAROL HOME offer-1)) 'error)
  (check "the lender retracts"
         (car ($ gov 'machine-retract ALICE HOME offer-1)) 'ok)
  (check "a retracted offer no longer matches"
         (length (cdr ($ gov 'machine-match HOME job-1))) 0)
  (check "…and cannot be claimed"
         (car ($ gov 'machine-claim ALICE HOME job-1 offer-1)) 'error)

  (scenario "withdraw — an open job can no longer be claimed")
  (define offer-2 (door-call gov ALICE 'machine-offer HOME "member"
                             "compute" 4 "deterministic"))
  (define job-2 (door-call gov BOB 'machine-submit HOME "compute" "member"
                           "deterministic" "in:r2"))
  (check "a stranger cannot withdraw someone else's job"
         (car ($ gov 'machine-withdraw CAROL HOME job-2)) 'error)
  (check "the borrower withdraws"
         (car ($ gov 'machine-withdraw BOB HOME job-2)) 'ok)
  (check "a withdrawn job refuses claims"
         (car ($ gov 'machine-claim ALICE HOME job-2 offer-2)) 'error)

  (scenario "preempt — a live claim ends with no payment, no miss")
  (define job-3 (door-call gov BOB 'machine-submit HOME "compute" "member"
                           "deterministic" "in:r3"))
  (define claim-3 (door-call gov ALICE 'machine-claim HOME job-3 offer-2))
  (door-call gov BOB 'machine-accept HOME claim-3)
  (check "a stranger cannot preempt the claim"
         (car ($ gov 'machine-preempt CAROL HOME claim-3)) 'error)
  (check "the borrower preempts"
         (car ($ gov 'machine-preempt BOB HOME claim-3)) 'ok)
  (define row (car (filter (lambda (r) (equal? (cdr (assoc "id" r))
                                               claim-3))
                           (cdr ($ gov 'machine-claims HOME)))))
  (check "the book says preempted"
         (cdr (assoc "state" row)) "preempted")
  (check "a receipt on a preempted claim is refused"
         (car ($ gov 'machine-receipt BOB HOME
                 `((bridgeJobId . ,claim-3) (lenderDid . "did:key:z6MkN")
                   (inputHash . "in:r3") (outputHash . "out:r3")
                   (usage . ((unit . "seconds") (amount . 1)))
                   (executedAt . 1761000002000) (digest . "x"))))
         'error))

(test-summary!)
