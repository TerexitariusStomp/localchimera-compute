;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-intent-acdc.scm — intent ACDCs close the VF triad
;;;
;;; Verifies:
;;;   1. add-intent emits playnet-intent ACDC
;;;   2. promote-to-commitment produces commitment ACDC with
;;;      satisfies = the intent's commitment-id (resolvable to intent SAID)
;;;   3. recover-intents round-trip: intents survive vat tear-down

(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas))
(use-modules (playnet credentials commitments) (playnet keri acdc) (playnet federation rebuild) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. add-intent emits playnet-intent ACDC
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. add-intent emits ACDC ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Bakery"))
         (plan-store ($ scope 'plan-store))
         (scope-aid "E_bakery"))

    ;; Wire on-intent emitter
    ($ plan-store 'set-on-intent
       (lambda (intent)
         ($ acdc-store 'issue-idempotent
            (make-intent-credential
              #:issuer-aid (or (intent-provider intent)
                               (intent-receiver intent)
                               scope-aid)
              #:intent-id (intent-id intent)
              #:action (intent-action intent)
              #:provider (intent-provider intent)
              #:receiver (intent-receiver intent)
              #:resource-conforms-to (intent-resource-conforms-to intent)
              #:plan-id (intent-planned-within intent)
              #:holder-aid scope-aid))))

    ;; Bakery offers 50kg of bread (provider only — VF rule)
    (let ((iid ($ plan-store 'add-intent
                  (make-intent #:id "I-offer-bread" #:action 'transfer
                               #:name "Bread offer" #:resource-conforms-to "spec-bread"
                               #:resource-classified-as (list "tag:offer")
                               #:resource-quantity (make-measure 50 "kg")
                               #:provider "E_alice"
                               #:stage (list "Bakery")
                               #:satisfies "plan-1"))))
      (check "intent added" iid "I-offer-bread"))

    ;; Verify intent ACDC issued
    (let ((cred ($ acdc-store 'by-claim-1
                   *schema-playnet-intent*
                   'intent-id "I-offer-bread")))
      (check-pred "intent ACDC issued" (and cred #t))
      (check "intent issuer = E_alice" (cred-issuer cred) "E_alice")
      (check "intent action = transfer" (cred-claim cred 'action) 'transfer)
      (check "intent resource-conforms-to" (cred-claim cred 'resource-conforms-to) "spec-bread")
      (check "intent provider = E_alice" (cred-claim cred 'provider) "E_alice")
      (check-pred "intent receiver = #f" (not (cred-claim cred 'receiver))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. promote-to-commitment links via satisfies
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Promote intent → commitment with satisfies linkage ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Watershed"))
         (plan-store ($ scope 'plan-store))
         (scope-aid "E_watershed"))

    ;; Wire both intent and commitment emitters
    ($ plan-store 'set-on-intent
       (lambda (intent)
         ($ acdc-store 'issue-idempotent
            (make-intent-credential
              #:issuer-aid (or (intent-provider intent)
                               (intent-receiver intent)
                               scope-aid)
              #:intent-id (intent-id intent)
              #:action (intent-action intent)
              #:provider (intent-provider intent)
              #:receiver (intent-receiver intent)
              #:resource-conforms-to (intent-resource-conforms-to intent)
              #:plan-id (intent-planned-within intent)
              #:holder-aid scope-aid))))

    ($ plan-store 'set-on-commitment
       (lambda (cmt)
         ($ acdc-store 'issue-idempotent
            (make-commitment-credential
              #:provider-aid (or (commitment-provider cmt) "E_provider")
              #:receiver-aid (or (commitment-receiver cmt) "E_receiver")
              #:commitment-id (commitment-id cmt)
              #:action (commitment-action cmt)
              #:resource-conforms-to (commitment-resource-conforms-to cmt)
              #:plan-id (commitment-planned-within cmt)
              #:satisfies (commitment-satisfies cmt)))))

    ;; Add a request intent (receiver only)
    ($ plan-store 'add-intent
       (make-intent #:id "I-want-bread" #:action 'transfer
                    #:name "Bread request" #:resource-conforms-to "spec-bread"
                    #:resource-classified-as (list "tag:request")
                    #:resource-quantity (make-measure 20 "kg") #:receiver "E_bob"  ;; receiver
                    #:stage '("Watershed")
                    #:satisfies "plan-2"))

    ;; Promote with provider supplied
    (let ((cid ($ plan-store 'promote-to-commitment
                  "I-want-bread"
                  (list (cons 'provider "E_alice")))))
      (check-pred "commitment id non-empty" (string? cid))

      ;; Commitment ACDC should have satisfies = intent-id
      (let ((cmt-cred ($ acdc-store 'by-claim-1
                         *schema-playnet-commitment*
                         'commitment-id cid)))
        (check-pred "commitment ACDC issued" (and cmt-cred #t))
        (check "commitment.satisfies = intent-id"
               (cred-claim cmt-cred 'satisfies) "I-want-bread"))

      ;; And the intent ACDC exists for the satisfies reference
      (let ((intent-cred ($ acdc-store 'by-claim-1
                            *schema-playnet-intent*
                            'intent-id "I-want-bread")))
        (check-pred "intent ACDC referenced by commitment is present"
                    (and intent-cred #t))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Recovery round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Recovery round-trip ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Mill"))
         (plan-store ($ scope 'plan-store))
         (scope-aid "E_mill"))

    ($ plan-store 'set-on-intent
       (lambda (intent)
         ($ acdc-store 'issue-idempotent
            (make-intent-credential
              #:issuer-aid (or (intent-provider intent)
                               (intent-receiver intent)
                               scope-aid)
              #:intent-id (intent-id intent)
              #:action (intent-action intent)
              #:provider (intent-provider intent)
              #:receiver (intent-receiver intent)
              #:resource-conforms-to (intent-resource-conforms-to intent)
              #:plan-id (intent-planned-within intent)
              #:holder-aid scope-aid))))

    ($ plan-store 'add-intent
       (make-intent #:id "I-mill-flour" #:action 'produce
                    #:name "Mill 100kg flour" #:resource-conforms-to "spec-flour"
                    #:resource-classified-as '()
                    #:resource-quantity (make-measure 100 "kg")
                    #:provider "E_carol"
                    #:stage '()
                    #:satisfies "plan-3"))

    (check "original intent stored"
           (intent-id ($ plan-store 'get-intent "I-mill-flour"))
           "I-mill-flour")

    ;; Tear down: spawn fresh scope
    (let* ((fresh-scope (spawn-scope-root "Mill"))
           (fresh-plan ($ fresh-scope 'plan-store)))

      (check-pred "fresh plan-store empty"
                  (not ($ fresh-plan 'get-intent "I-mill-flour")))

      ;; Recover from ACDCs (observer registration so the Validation
      ;; Gate can anchor satisfying events post-recovery).
      (recover-intents fresh-plan ($ fresh-scope 'observer) acdc-store)

      (let ((recovered ($ fresh-plan 'get-intent "I-mill-flour")))
        (check-pred "intent recovered" (and recovered #t))
        (check "recovered intent action = produce"
               (intent-action recovered) 'produce)
        (check "recovered intent provider = E_carol"
               (intent-provider recovered) "E_carol")
        (check "recovered resource-conforms-to"
               (intent-resource-conforms-to recovered) "spec-flour")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Idempotent emission — replaying an intent doesn't duplicate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Idempotent emission ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Test"))
         (plan-store ($ scope 'plan-store))
         (scope-aid "E_test"))

    ($ plan-store 'set-on-intent
       (lambda (intent)
         ($ acdc-store 'issue-idempotent
            (make-intent-credential
              #:issuer-aid scope-aid
              #:intent-id (intent-id intent)
              #:action (intent-action intent)
              #:provider (intent-provider intent)
              #:resource-conforms-to (intent-resource-conforms-to intent)
              #:holder-aid scope-aid))))

    ;; Add same intent twice (same ID — should be idempotent)
    (let ((i (make-intent #:id "I-dup" #:action 'transfer #:resource-conforms-to "spec-x" #:resource-classified-as '()
                          #:provider "E_dave"
                          #:stage '())))
      ($ plan-store 'add-intent i)
      ($ plan-store 'add-intent i))

    (let ((all ($ acdc-store 'by-schema *schema-playnet-intent*)))
      (check "idempotent: 1 ACDC after 2 adds" (length all) 1))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
