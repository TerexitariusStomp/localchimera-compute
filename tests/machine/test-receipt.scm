;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-receipt.scm — the digest is the contract.
;;;
;;; The vectors below are produced by poi-compute's receipt-translate.ts —
;;; canonical string and sha256 both, verbatim. They are the whole test of
;;; the port's claim: a hive's receipt and a localchimera receipt over the same
;;; body hash the same commitment, or the two commons cannot settle against
;;; each other. If either side changes canonicalization this suite turns
;;; red here and red over there, in the same direction.

(use-modules (localchimera test harness)
             (localchimera machine specs)
             (localchimera machine receipt)
             (localchimera vf schemas)
             (srfi srfi-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. canonicalization — the exact bytes JS would emit
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. canonical strings — key order, nulls, separators ──\n")

(define r1 (make-receipt #:bridge-job-id "bj-1" #:lender-did "did:key:z6MkAlice"
                         #:input-hash "aa11" #:output-hash "bb22"
                         #:executed-at 1761000000000))
(check "minimal receipt, the literal JSON.stringify bytes"
       (receipt-canonical r1)
       "{\"bridgeJobId\":\"bj-1\",\"lenderDid\":\"did:key:z6MkAlice\",\"inputHash\":\"aa11\",\"outputHash\":\"bb22\",\"engine\":null,\"usage\":null,\"repro\":null,\"executedAt\":1761000000000}")

(define r2 (make-receipt #:bridge-job-id "bj-2" #:lender-did "did:key:z6MkBob"
                         #:input-hash "cc33" #:output-hash "dd44"
                         #:engine "llama.cpp@1.0"
                         #:usage (make-usage-meter #:unit "tokens" #:amount 512)
                         #:repro (make-repro-spec #:mode 'deterministic #:seed 42
                                                  #:decoding "greedy"
                                                  #:engine-version "llama.cpp/1.0.0")
                         #:executed-at 1761000000123))
(check "full receipt — optionals inside, in JS property order"
       (receipt-canonical r2)
       "{\"bridgeJobId\":\"bj-2\",\"lenderDid\":\"did:key:z6MkBob\",\"inputHash\":\"cc33\",\"outputHash\":\"dd44\",\"engine\":\"llama.cpp@1.0\",\"usage\":{\"unit\":\"tokens\",\"amount\":512},\"repro\":{\"mode\":\"deterministic\",\"seed\":42,\"decoding\":\"greedy\",\"engineVersion\":\"llama.cpp/1.0.0\"},\"executedAt\":1761000000123}")

(define r3 (make-receipt #:bridge-job-id "bj-3" #:lender-did "did:key:z6MkCarol"
                         #:input-hash "ee55" #:output-hash "ff66"
                         #:usage (make-usage-meter #:unit "seconds" #:amount 3)
                         #:repro (make-repro-spec #:mode 'exact)
                         #:executed-at 1761000000456))
(check "repro with no params — absent fields drop, mode stays"
       (receipt-canonical r3)
       "{\"bridgeJobId\":\"bj-3\",\"lenderDid\":\"did:key:z6MkCarol\",\"inputHash\":\"ee55\",\"outputHash\":\"ff66\",\"engine\":null,\"usage\":{\"unit\":\"seconds\",\"amount\":3},\"repro\":{\"mode\":\"exact\"},\"executedAt\":1761000000456}")


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. the digests — what the TypeScript produces for the same bodies
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. digests — naoms-compute-receipt/v1, same bytes both sides ──\n")

(check "bj-1 digest" (receipt-digest r1)
       "c33eb2ac2c573c8272b9647a57066e5461b0810534aa434e0824707e8c7acd48")
(check "bj-2 digest" (receipt-digest r2)
       "df6cbf026c538a5da99282535bf2e8660423886f05459e19254fd40c861cccbe")
(check "bj-3 digest" (receipt-digest r3)
       "03369b9cd11b98d2ab86cc5d353242d9301da30444e05b26392156928b0887bd")

;; a receipt that claims a digest is checked against what its body produces —
;; this is how a stale or tampered commitment reads at the door.
(check "a claimed digest verifies"
       (receipt-digest-ok?
         (make-receipt #:bridge-job-id "bj-1" #:lender-did "did:key:z6MkAlice"
                       #:input-hash "aa11" #:output-hash "bb22"
                       #:executed-at 1761000000000
                       #:digest-field "c33eb2ac2c573c8272b9647a57066e5461b0810534aa434e0824707e8c7acd48")))
(check "a wrong claim does not"
       (not (receipt-digest-ok?
              (make-receipt #:bridge-job-id "bj-1" #:lender-did "did:key:z6MkAlice"
                            #:input-hash "aa11" #:output-hash "bb22"
                            #:executed-at 1761000000000
                            #:digest-field "0000"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. a receipt is a use event — the fold into the ledger
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. receipt->event — borrowed capacity, metered, in scope ──\n")

(let ((e (receipt->event r2 #:scope-id "commune:town" #:spec-id "spec:infer-small"
                         #:commitment-id "commit:7" #:intent-id "intent:9")))
  (check "the digest is the event's id" (economic-event-id e) (receipt-digest r2))
  (check "the action is use — the machine stays the lender's"
         (economic-event-action e) 'use)
  (check "provider is the lender" (economic-event-provider e) "did:key:z6MkBob")
  (check "receiver is the scope"   (economic-event-receiver e) "commune:town")
  (check "conforms to the compute spec"
         (economic-event-resource-conforms-to e) "spec:infer-small")
  (check "usage meters the resource-quantity in its own unit"
         (list (measure->qty (economic-event-resource-quantity e))
               (measure->unit (economic-event-resource-quantity e)))
         '(512 "tokens"))
  (check "the scope is the event's" (economic-event-in-scope-of e) '("commune:town"))
  (check "fulfills the commitment" (economic-event-fulfills e) "commit:7")
  (check "satisfies the intent"    (economic-event-satisfies e) "intent:9")
  (check "executed-at lands as an ISO instant"
         (economic-event-has-point-in-time e)
         (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime 1761000000))))

(let ((e (receipt->event r1 #:scope-id "commune:town" #:spec-id "spec:fetch"
                         #:commitment-id #f #:intent-id #f #:state "preempted")))
  (check "no usage, no quantity" (economic-event-resource-quantity e) #f)
  (check "preempted is the recorded state — unpaid, not a miss"
         (economic-event-state e) "preempted"))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. compute specs — classification is the whole wire
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. specs — tags in, tags out ──\n")

(let ((s (make-machine-spec "spec:infer-small" "small inference, member machines"
                            #:task-class 'inference #:lane "member"
                            #:repro-mode 'deterministic #:usage-unit "tokens")))
  (check "it is a compute spec"  (machine-spec? s))
  (check "the class reads back"  (spec-task-class s) 'inference)
  (check "the lane reads back"   (spec-lane s) "member")
  (check "the mode reads back"   (spec-repro-mode s) 'deterministic)
  (check "resource unit is the usage unit"
         (resource-specification-default-unit-of-resource s) "tokens")
  (check "effort is always seconds"
         (resource-specification-default-unit-of-effort s) "seconds")
  (check "the tags are the whole classification"
         (resource-specification-resource-classified-as s)
         '("compute" "inference" "lane:member" "repro:deterministic")))

(check "an ordinary spec is not a compute spec"
       (not (machine-spec?
              (make-resource-specification #:id "x" #:name "x"
                                           #:resource-classified-as '("tool")))))
(check-error "a nonsense class is rejected"
             (lambda () (make-machine-spec "s" "s" #:task-class 'alchemy
                                           #:lane "l" #:repro-mode 'none)))
(check-error "a nonsense mode is rejected"
             (lambda () (make-machine-spec "s" "s" #:task-class 'fetch
                                           #:lane "l" #:repro-mode 'vibes)))

(test-summary!)
