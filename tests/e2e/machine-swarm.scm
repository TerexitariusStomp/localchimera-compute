;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-swarm.scm — the coordination record through the doors.
;;;
;;; A swarm binds N shard jobs under one borrower-named record; the doors
;;; beside it are the N-party bus — the same signal shelf a claim's relay
;;; legs use, keyed "swarm:<id>", gated to the swarm's members. This suite
;;; walks the story: submit the shards, open the record, read the fan-out
;;; shape, speak on the bus — and every refusal the record owes a stranger.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-swarm.scm

(use-modules (localchimera test harness)
             (localchimera test e2e)
             (localchimera machine registry)
             (localchimera machine swarm)
             (localchimera machine receipt)
             (localchimera boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-swarm-e2e"))
(define HOME  "did:keri:EHomeCommune")
(define ALICE "did:keri:DAliceLender")
(define BOB   "did:keri:DBobBorrower")
(define CAROL "did:keri:DCarolStranger")

(with-vat vat
  (define gov
    (spawn-governance-service '() #f
      #:scope-of (lambda (aid) #f)
      #:governor? (lambda (aid) #f)))

  (define (shard-job n)
    "One exec shard in BOB's name — the fan-out's Nth member."
    (door-call gov BOB 'machine-submit HOME "swarm-infer" "member"
               "deterministic" (string-append "in:shard-" n)
               'envelope
               `((kind . "exec")
                 (bridgeJobId . ,(string-append "bj-shard-" n))
                 (image . "js:shard") (entrypoint . "main")
                 (inputHash . ,(string-append "in:shard-" n))
                 (caps . ()) (network . #f)
                 (params . ()))))

  (scenario "open — the borrower binds its shard jobs under one record")
  (define job-a (shard-job "a"))
  (define job-b (shard-job "b"))
  (define job-c (shard-job "c"))
  (define opened
    (door-call gov BOB 'machine-swarm-open HOME "sw-1" (list job-a job-b job-c)))
  (check "the record names its borrower" BOB (list-ref opened 1))
  (check "the record names its commune" HOME (list-ref opened 2))
  (check "the fan-out keeps job order — index IS shard-index"
         (list job-a job-b job-c) (list-ref opened 3))

  (scenario "open — refusal keeps the record honest")
  (check "a swarm over a stranger's job refuses"
         (car ($ gov 'machine-swarm-open ALICE HOME "sw-bad" (list job-a)))
         'error)
  (check "a swarm over a job that doesn't exist refuses"
         (car ($ gov 'machine-swarm-open BOB HOME "sw-bad2" (list "job-nope")))
         'error)
  (check "re-open is idempotent — the same record answers"
         opened
         (door-call gov BOB 'machine-swarm-open HOME "sw-1"
                    (list job-a job-b job-c)))

  (scenario "machine-swarm-of — the fan-out's shape, members only")
  (let ((view (door-call gov BOB 'machine-swarm-of HOME "sw-1")))
    (check "the borrower reads the record back" "sw-1"
           (car (cdr (assoc "swarm" view))))
    (check "shard jobs start 'open'"
           '("open" "open" "open")
           (map (lambda (j) (cdr (assoc "state" j)))
                (cdr (assoc "jobs" view)))))
  (check "a stranger may not read the swarm"
         (car ($ gov 'machine-swarm-of CAROL HOME "sw-1")) 'error)

  (scenario "the lender joins by claiming — the bus opens to its members")
  ;; ALICE's offer on the commune, then a claim on shard a — the claim is
  ;; what makes her a member, not any swarm-side join.
  (define offer-id
    (door-call gov ALICE 'machine-offer HOME "member" "swarm-infer"
               4 "deterministic"))
  (define claim-a (door-call gov ALICE 'machine-claim HOME job-a offer-id))
  (door-call gov BOB 'machine-accept HOME claim-a)
  (let ((view (door-call gov ALICE 'machine-swarm-of HOME "sw-1")))
    (check "the claimed shard reports 'claimed'"
           "claimed"
           (cdr (assoc "state" (car (cdr (assoc "jobs" view)))))))

  (scenario "the bus — a swarm-scoped rendezvous in seq order")
  (define seq1
    (door-call gov BOB 'machine-swarm-signal HOME "sw-1"
               '((role . "merge") (stage . 0))))
  (check "the descriptor post seqs at 1" 1 seq1)
  (define seq2
    (door-call gov ALICE 'machine-swarm-signal HOME "sw-1"
               '((role . "stage") (shard . 0) (ready . #t))))
  (check "the member post seqs at 2" 2 seq2)
  (let ((rows (door-call gov ALICE 'machine-swarm-signals HOME "sw-1" 'after 0)))
    (check "the member reads the whole bus"
           '(1 2) (map (lambda (r) (cdr (assoc "seq" r))) rows))
    (check "posts carry their author"
           (list BOB ALICE)
           (map (lambda (r) (cdr (assoc "from" r))) rows)))
  (let ((rows (door-call gov BOB 'machine-swarm-signals HOME "sw-1" 'after 1)))
    (check "after:1 reads only what came later"
           '(2) (map (lambda (r) (cdr (assoc "seq" r))) rows)))

  (scenario "dead-letter — the bus refuses everyone else")
  (check "a stranger may not post"
         (car ($ gov 'machine-swarm-signal CAROL HOME "sw-1" '((x . 1))))
         'error)
  (check "a stranger may not read"
         (car ($ gov 'machine-swarm-signals CAROL HOME "sw-1"))
         'error)
  (check "an unknown swarm refuses even a citizen"
         (car ($ gov 'machine-swarm-of BOB HOME "sw-ghost")) 'error)

  (scenario "the settled shard leaves the bus — live claims only")
  ;; ALICE's claim completes; a 'complete claim is no longer membership.
  (let* ((rcpt (make-receipt #:bridge-job-id claim-a
                             #:lender-did "did:key:z6MkNode"
                             #:input-hash "in:shard-a"
                             #:output-hash "out:shard-a"
                             #:usage (make-usage-meter #:unit "seconds"
                                                       #:amount 1)
                             #:executed-at 1761000002000))
         (wire `((bridgeJobId . ,claim-a) (lenderDid . "did:key:z6MkNode")
                 (inputHash . "in:shard-a") (outputHash . "out:shard-a")
                 (usage . ((unit . "seconds") (amount . 1)))
                 (executedAt . 1761000002000)
                 (digest . ,(receipt-digest rcpt)))))
    (check "the node's receipt completes the shard"
           (car ($ gov 'machine-receipt BOB HOME wire)) 'ok))
  (check "the settled shard's lender has no more to say"
         (car ($ gov 'machine-swarm-signal ALICE HOME "sw-1" '((x . 2))))
         'error)
  ;; …but the borrower still speaks — the record is theirs until it isn't.
  (check "the borrower still posts" 3
         (door-call gov BOB 'machine-swarm-signal HOME "sw-1"
                    '((role . "merge") (done . #t)))))
