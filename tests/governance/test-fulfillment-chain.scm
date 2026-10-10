;;; test-fulfillment-chain.scm — work-event → commitment SAID linkage
;;;
;;; Verifies the elegance: fulfillments and satisfactions are derivable
;;; linkage fields, not separate ACDC schemas.
;;;
;;; Pattern:
;;;   1. Plan-store (Watershed) emits playnet-commitment ACDC for C-1
;;;   2. Account-store records work event W with fulfills=C-1
;;;   3. on-work callback looks up C-1's SAID via acdc-store by-claim-1
;;;   4. Emits playnet-work-event ACDC with fulfills=SAID(C-1)
;;;   5. Verification: walk SAID reference to verify the chain

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas))
(use-modules (playnet governance credentials) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Local fulfillment chain (same scope, same store)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Local fulfillment chain ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Watershed"))
         (scope-aid "E_watershed")
         (plan-store ($ scope 'plan-store))
         (account-store ($ scope 'account-store)))

    ;; Wire emitters
    ($ plan-store 'set-on-commitment
       (lambda (cmt)
         ($ acdc-store 'issue-idempotent
            (make-commitment-credential
              (or (commitment-provider cmt) "E_provider")
              (or (commitment-receiver cmt) "E_receiver")
              (commitment-id cmt)
              (commitment-action cmt)
              #:resource-conforms-to (commitment-resource-conforms-to cmt)
              #:plan-id (commitment-planned-within cmt)))))

    ($ account-store 'set-on-work
       (lambda (event)
         (let* ((worker (or (economic-event-provider event)
                            (economic-event-receiver event)))
                (hours (and (economic-event-effort-quantity event)
                            (measure-has-numerical-value
                              (economic-event-effort-quantity event))))
                ;; Local SAID lookup via the index — O(1)
                (cmt-id (economic-event-fulfills event))
                (cmt-cred (and cmt-id
                               ($ acdc-store 'by-claim-1
                                  *schema-playnet-commitment*
                                  'commitment-id cmt-id)))
                (fulfills-said (and cmt-cred (cred-said cmt-cred))))
           ($ acdc-store 'issue-idempotent
              (make-work-event-credential
                scope-aid worker
                (economic-event-id event) hours %effort-unit
                #:scope-id "Watershed"
                #:fulfills fulfills-said)))))

    ;; Step 1: plan-store creates commitment C-1 (Alice promises 8h work)
    (let ((cid ($ plan-store 'add-commitment
                  (make-commitment #:id "C-1" #:action 'work
                                   #:resource-conforms-to "spec-bread" #:effort-quantity (make-measure 8 %effort-unit)
                                   #:provider "E_alice"
                                   #:planned-within "plan-1"))))
      (check "commitment C-1 added"
             cid "C-1"))

    ;; Verify commitment ACDC issued
    (let ((cmt-cred ($ acdc-store 'by-claim-1
                       *schema-playnet-commitment*
                       'commitment-id "C-1")))
      (check-pred "commitment C-1 ACDC issued"
                  (and cmt-cred #t))
      (check "commitment ACDC schema"
             (cred-schema cmt-cred) *schema-playnet-commitment*))

    ;; Step 2: Alice performs work event W-1 fulfilling C-1
    (let* ((event (make-economic-event
                    #:id "W-1" #:action 'work #:resource-conforms-to "spec-bread"
                    #:provider "E_alice"
                    #:effort-quantity (make-measure 8 %effort-unit) #:created "2026-04-20T08:00:00Z"
                    #:fulfills "C-1"  ;; fulfills
)))
      ($ account-store 'credit-from-event event))

    ;; Verify work-event ACDC issued with fulfills = SAID(C-1)
    (let* ((cmt-cred ($ acdc-store 'by-claim-1
                        *schema-playnet-commitment*
                        'commitment-id "C-1"))
           (cmt-said (cred-said cmt-cred))
           (work-cred ($ acdc-store 'by-claim-1
                         *schema-playnet-work-event*
                         'event-id "W-1")))
      (check-pred "work-event W-1 ACDC issued"
                  (and work-cred #t))
      (check "work-event holder = E_alice"
             (cred-holder work-cred) "E_alice")
      (check "work-event hours = 8"
             (cred-claim work-cred 'hours) 8)
      (check "work-event fulfills = SAID(C-1)"
             (cred-claim work-cred 'fulfills) cmt-said))

    ;; Step 3: Walk the SAID chain to verify fulfillment
    (let* ((work-cred ($ acdc-store 'by-claim-1
                         *schema-playnet-work-event*
                         'event-id "W-1"))
           (cmt-said (cred-claim work-cred 'fulfills))
           (cmt-cred ($ acdc-store 'get cmt-said)))
      (check-pred "follow SAID: cmt cred resolved"
                  (and cmt-cred #t))
      (check "fulfilled commitment-id"
             (cred-claim cmt-cred 'commitment-id) "C-1")
      (check-pred "neither work nor commitment revoked"
                  (and (not (cred-revoked? work-cred))
                       (not (cred-revoked? cmt-cred)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Missing commitment → fulfills = #f, credit still applied
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Missing commitment → graceful degradation ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Bakery"))
         (account-store ($ scope 'account-store)))

    ($ account-store 'set-on-work
       (lambda (event)
         (let* ((worker (economic-event-provider event))
                (hours (measure-has-numerical-value
                         (economic-event-effort-quantity event)))
                (cmt-id (economic-event-fulfills event))
                (cmt-cred (and cmt-id
                               ($ acdc-store 'by-claim-1
                                  *schema-playnet-commitment*
                                  'commitment-id cmt-id))))
           ($ acdc-store 'issue-idempotent
              (make-work-event-credential
                "E_bakery" worker
                (economic-event-id event) hours %effort-unit
                #:fulfills (and cmt-cred (cred-said cmt-cred)))))))

    ;; Work event references C-MISSING which doesn't exist
    (let ((event (make-economic-event
                   #:id "W-2" #:action 'work
                   #:provider "E_bob"
                   #:effort-quantity (make-measure 4 %effort-unit) #:created "2026-04-20T10:00:00Z"
                   #:fulfills "C-MISSING")))
      ($ account-store 'credit-from-event event))

    (let ((work-cred ($ acdc-store 'by-claim-1
                        *schema-playnet-work-event*
                        'event-id "W-2")))
      (check-pred "work-event still issued"
                  (and work-cred #t))
      (check "fulfills = #f when commitment not found"
             (cred-claim work-cred 'fulfills) #f))

    ;; Validation Gate (§III.1): work with no resolvable commitment does
    ;; NOT credit social labor. The work-event credential is still
    ;; issued (ACDC graceful degradation), but gross-credited stays 0.
    (check "Bob's gross-credited = 0 (ungated work)"
           ($ account-store 'citizen-gross "E_bob") 0)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Idempotent emission — replaying same event doesn't double-count
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Idempotent emission ──\n")

(with-vat vat
  (let* ((acdc-store (spawn-acdc-store))
         (scope (spawn-scope-root "Test"))
         (account-store ($ scope 'account-store)))

    ($ account-store 'set-on-work
       (lambda (event)
         ($ acdc-store 'issue-idempotent
            (make-work-event-credential
              "E_test" (economic-event-provider event)
              (economic-event-id event)
              (measure-has-numerical-value
                (economic-event-effort-quantity event))
              %effort-unit))))

    (let ((event (make-economic-event
                   #:id "W-3" #:action 'work
                   #:provider "E_carol"
                   #:effort-quantity (make-measure 5 %effort-unit) #:created "2026-04-20T11:00:00Z")))
      ;; Emit twice
      ($ account-store 'credit-from-event event)
      ($ account-store 'credit-from-event event))

    ;; Should still be one ACDC
    (let ((all-work ($ acdc-store 'by-schema *schema-playnet-work-event*)))
      (check "still one ACDC after replay (idempotent)"
             (length all-work) 1))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
