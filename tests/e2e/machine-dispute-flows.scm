;;; tests/e2e/machine-dispute-flows.scm — every dispute branch, clock-walked.
;;;
;;; The spec's §5 lifecycle as scenarios, *machine-clock* rebound so the
;;; 72h/4d/7d windows move at test speed:
;;;
;;;   non-delivery — deadline past, no receipt → dispute lands → closure
;;;     window → lapsed → settlement treats it held-then-released per spec
;;;   wrong-result — replay under a disagreeing executor → counterHash →
;;;     sortition three vote 2-of-3 → upheld → the settlement HOLDS it
;;;   reproduced — the prover's own answer refutes the dispute at raise
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-dispute-flows.scm

(use-modules (playnet test harness)
             (playnet test e2e)
             (playnet machine specs)
             (playnet machine receipt)
             (playnet machine registry)
             (playnet machine settlement)
             (playnet machine envelope)
             (playnet machine replay)
             (playnet machine dispute)
             (playnet machine executors)
             (playnet doors machine)
             (playnet boot governance)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "machine-dispute-e2e"))
(define HOME "did:keri:EDisputeCommune")
(define ALICE "did:key:z6MkAlice")
(define BOB   "did:key:z6MkBob")
(define CAROL "did:key:z6MkCarol")
(define DAVE  "did:key:z6MkDave")
(define ERIN  "did:key:z6MkErin")

(define T0 1760000000)                       ;; the scenario's epoch-0
(define clock (make-fake-clock T0))
(define get-now (car clock))
(define advance! (cdr clock))

;; helpers: run the registry chain inside the clock's parameterization
(define* (mk-claim gov #:key job-env output-hash repro-seed)
  "offer + submit (+envelope) + claim + accept → claim-id."
  (let* ((o (door-call gov ALICE 'machine-offer HOME "member"
                       "inference,fetch" 6 "deterministic"))
         (j (if job-env
                (door-call gov BOB 'machine-submit HOME "inference" "member"
                           "deterministic" "in:x"
                           'envelope job-env 'envelopeHash "eh:x")
                (door-call gov BOB 'machine-submit HOME "inference" "member"
                           "deterministic" "in:x")))
         (c (door-call gov ALICE 'machine-claim HOME j o)))
    ($ gov 'machine-accept BOB HOME c)
    (list c j)))

(define (receipt-wire-for claim-id out-hash seed)
  (let ((r (make-receipt #:bridge-job-id claim-id #:lender-did ALICE
                         #:input-hash "in:x" #:output-hash out-hash
                         #:usage (make-usage-meter #:unit "seconds" #:amount 1)
                         #:repro (make-repro-spec #:mode 'deterministic
                                                  #:seed seed)
                         #:executed-at 1760000100000)))
    `((bridgeJobId . ,claim-id) (lenderDid . ,ALICE)
      (inputHash . "in:x") (outputHash . ,out-hash)
      (usage . ((unit . "seconds") (amount . 1)))
      (repro . ((mode . "deterministic") (seed . ,seed)))
      (executedAt . 1760000100000)
      (digest . ,(receipt-digest r))
      (lenderSig . #f))))

(with-vat vat
  (define fake-scope
    (spawn (lambda (bcom)
             (methods ((mint-gov-cap aid) 'cap)
                      ((scope-aid) HOME)))))
  (define gov
    (spawn-governance-service '() #f #:scope-of (lambda (aid) fake-scope)))

  (parameterize ((*machine-clock* get-now))

    ;; seed the citizen pool — the dispute doors ensure-citizen their caller
    ($ gov 'machine-disputes ALICE HOME)
    ($ gov 'machine-disputes BOB HOME)
    ($ gov 'machine-disputes CAROL HOME)
    ($ gov 'machine-disputes DAVE HOME)
    ($ gov 'machine-disputes ERIN HOME)

    ;; ── non-delivery: the deadline passes, the absence is the evidence ────
    (scenario "non-delivery — a claim whose deadline passed unserved")

    (define nd-claim (car (mk-claim gov)))
    (check "the claim is live, deadline 72h out"
           (car ($ gov 'machine-dispute BOB HOME nd-claim "non-delivery"))
           'error)

    (advance! (+ (* 72 3600) 60))            ;; 72h + one minute
    (define nd (cdr ($ gov 'machine-dispute BOB HOME nd-claim "non-delivery")))
    (define nd-id (cdr (assoc "id" nd)))
    (check "past the deadline the dispute lands"
           (equal? (cdr (assoc "kind" nd)) "non-delivery") #t)
    (check "non-delivery carries no challenge — there is nothing to replay"
           (not (cdr (assoc "challenge" nd))) #t)
    (check "one dispute per claim"
           (car ($ gov 'machine-dispute ALICE HOME nd-claim "non-delivery"))
           'error)

    ;; the closure window: anyone prods it once the clock has run
    (advance! (+ (* 4 24 3600) (* 7 24 3600) 60))   ;; review + closure windows
    (define nd-close ($ gov 'machine-dispute-close CAROL HOME nd-id))
    (check "after the windows the dispute closes lapsed"
           (equal? (cdr (assoc "outcome" (cdr nd-close))) "lapsed") #t)

    ;; ── wrong-result: the prover disagrees, the hive weighs it ────────────
    (scenario "wrong-result — replay under a disagreeing executor")

    (define env '((bridgeJobId . "bj-wr") (image . "js:w.js")
                  (entrypoint . "run") (inputHash . "in:x")
                  (caps . ()) (network . #f)))
    (define wr-pair (mk-claim gov #:job-env env))
    (define wr-claim (car wr-pair))
    (define wr-wire (receipt-wire-for wr-claim "out:wrong" 11))
    ($ gov 'machine-receipt BOB HOME wr-wire)

    ;; an honest executor replays and gets a DIFFERENT output
    (register-executor! HOME
      (make-replay-executor #:kind 'wasimoff #:name "broker-e2e"
                            #:run (lambda (e r) "out:right")))
    (define wr (cdr ($ gov 'machine-dispute BOB HOME wr-claim "wrong-result")))
    (define wr-id (cdr (assoc "id" wr)))
    (check "the dispute carries the challenge's counter-hash"
           (string? (cdr (assoc "challenge" wr))) #f)
    (check "the challenge marks it not reproduced"
           (eq? (cdr (assoc "reproduced" (cdr (assoc "challenge" wr))))
                 'mismatch) #t)

    ;; sortition picked three; two 'upheld verdicts close the review
    (define wr-rows (cdr ($ gov 'machine-disputes CAROL HOME)))
    (define wr-d (find (lambda (r) (equal? (cdr (assoc "id" r)) wr-id))
                       wr-rows))
    (define reviewers (cdr (assoc "reviewers" wr-d)))
    (check "three sortition reviewers were named"
           (vector-length reviewers) 3)
    (check "a non-reviewer is refused"
           (car ($ gov 'machine-dispute-verdict "did:key:z6MkNobody" HOME
                   wr-id "upheld")) 'error)
    ($ gov 'machine-dispute-verdict (vector-ref reviewers 0) HOME wr-id "upheld")
    (define wr-v2 ($ gov 'machine-dispute-verdict (vector-ref reviewers 1) HOME
                     wr-id "upheld"))
    (check "two-of-three upheld closes the review"
           (equal? (cdr (assoc "state" (cdr wr-v2))) "closed") #t)

    ;; the upheld dispute HOLDS the settlement entry — money doesn't move
    (define stmt
      `((period . ("2026-10-01" . "2026-10-31"))
        (entries . (((bridgeJobId . ,wr-claim)
                     (receiptDigest . ,(cdr (assoc 'digest wr-wire)))
                     (amount . 42) (asset . "eip155:1/slip44:60"))))
        (payments . ())
        (bridgeSig . "e2e")))
    (define settle-res (cdr ($ gov 'machine-settle ALICE HOME stmt)))
    (check "the disputed entry is held, not matched"
           (caddr settle-res) 1)

    ;; ── reproduced: the prover's own answer refutes the premise ──────────
    (scenario "reproduced — the dispute cannot stand on a matching replay")

    (define env2 '((bridgeJobId . "bj-ok") (image . "js:ok.js")
                   (entrypoint . "run") (inputHash . "in:x")
                   (caps . ()) (network . #f)))
    (define ok-claim (car (mk-claim gov #:job-env env2)))
    ($ gov 'machine-receipt BOB HOME (receipt-wire-for ok-claim "out:right" 13))

    (check "a reproduced output refuses the dispute at raise"
           (car ($ gov 'machine-dispute BOB HOME ok-claim "wrong-result"))
           'error)

    (unregister-executor! HOME)
    (check "with no executor the challenge answers fail-closed"
           (eq? (cdr (assoc "reproduced"
                            (cdr ($ gov 'machine-replay BOB HOME ok-claim))))
                'no-executor)) #t))

(test-summary!)
