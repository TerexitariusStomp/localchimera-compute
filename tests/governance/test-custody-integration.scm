;;; test-custody-integration.scm — ^scope custody methods + lift round-trip

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet governance credentials) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. attest-custody issues a self-held attestation
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. attest-custody ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Workshop"))
         (scope (spawn-scope "Workshop"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EWorkshop"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (said  ($ scope 'attest-custody gov "spec:loom" 5)))
    (check-pred "attest returns SAID" (string? said))
    (let ((live ($ scope 'live-custody-attestations)))
      (check-pred "one live attestation" (= 1 (length live)))
      (let ((c (car live)))
        (check-pred "issuer = self"   (equal? "EWorkshop" (cred-issuer c)))
        (check-pred "holder = self"   (equal? "EWorkshop" (cred-holder c)))
        (check-pred "spec correct"    (equal? "spec:loom" (cred-claim c 'resource-spec)))
        (check-pred "qty 5"           (= 5 (cred-claim c 'qty)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. transfer-custody (clean): no outstanding commitments → empty carries
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. transfer-custody clean ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "ScopeA"))
         (scope (spawn-scope "ScopeA"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EScopeA"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:wheat" 100)
    (let ((xfer-said ($ scope 'transfer-custody gov "spec:wheat" 100 "EScopeB"
                        'carries '())))
      (check-pred "transfer returns SAID" (string? xfer-said))
      (let* ((all-att ($ store 'by-schema *schema-playnet-custody-attestation*))
             (live    (filter (lambda (c) (not (cred-revoked? c))) all-att))
             (revoked (filter cred-revoked? all-att)))
        (check-pred "one revoked attestation" (= 1 (length revoked)))
        (check-pred "one live attestation"    (= 1 (length live)))
        (let ((new-att (car live)))
          (check-pred "new holder = recipient"
                      (equal? "EScopeB" (cred-holder new-att)))
          (check-pred "issuer = sender"
                      (equal? "EScopeA" (cred-issuer new-att)))
          (check-pred "supersedes old"
                      (not (not (cred-edge new-att 'supersedes))))))
      (let* ((xfer (find (lambda (c) (equal? xfer-said (cred-said c)))
                         ($ store 'by-schema
                            *schema-playnet-custody-transfer-commitment*))))
        (check-pred "no carries-commitment edges"
                    (not (cred-edge xfer 'carries-commitment-0)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Validator: '() carries with outstanding commitments → error
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Orphan-detection validator ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "ScopeC"))
         (scope (spawn-scope "ScopeC"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EScopeC"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:bread" 10)
    ;; Outstanding commitment: scope-C promises 5 bread to someone.
    ($ store 'issue
       (make-commitment-credential
        "EScopeC" "EBuyer" "comm-1" 'transfer
        #:resource-conforms-to "spec:bread"
        #:resource-quantity (cons 5 "loaf")))
    (check-pred "transfer with empty carries rejects orphan"
                (catch #t
                  (lambda ()
                    ($ scope 'transfer-custody gov "spec:bread" 10 "EOther"
                       'carries '())
                    #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Auto-enumerate: 'all carries threads outstanding into transfer
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. 'all auto-enumerates ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "ScopeD"))
         (scope (spawn-scope "ScopeD"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EScopeD"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:cloth" 30)
    (let* ((c1 (make-commitment-credential
                "EScopeD" "EReceiver1" "comm-A" 'transfer
                #:resource-conforms-to "spec:cloth"
                #:resource-quantity (cons 5 "m")))
           (c2 (make-commitment-credential
                "EScopeD" "EReceiver2" "comm-B" 'transfer
                #:resource-conforms-to "spec:cloth"
                #:resource-quantity (cons 7 "m"))))
      ($ store 'issue c1)
      ($ store 'issue c2)
      (let* ((xfer-said ($ scope 'transfer-custody gov "spec:cloth" 30 "ENew"))
             (xfer (find (lambda (c) (equal? xfer-said (cred-said c)))
                         ($ store 'by-schema
                            *schema-playnet-custody-transfer-commitment*))))
        (check-pred "carries-commitment-0 present"
                    (not (not (cred-edge xfer 'carries-commitment-0))))
        (check-pred "carries-commitment-1 present"
                    (not (not (cred-edge xfer 'carries-commitment-1))))
        (let* ((targets (list (edge-target (cred-edge xfer 'carries-commitment-0))
                              (edge-target (cred-edge xfer 'carries-commitment-1)))))
          (check-pred "comm-A SAID enumerated" (member (cred-said c1) targets))
          (check-pred "comm-B SAID enumerated" (member (cred-said c2) targets)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. End-to-end: scope issues → store filters live → planner lifts facts
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Lift round-trip ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "ScopeE"))
         (scope (spawn-scope "ScopeE"
                             #:kind 'commune
                             #:scope-root-ref root
                             #:scope-aid "EScopeE"
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:water" 200)
    ($ scope 'attest-custody gov "spec:grain" 50)
    (let* ((live  (non-revoked-by-schema store
                                         *schema-playnet-custody-attestation*))
           (facts (lift-custody-facts live)))
      (check-pred "two facts lifted" (= 2 (length facts)))
      (check-pred "all custodian-of"
                  (every (lambda (f) (eq? 'custodian-of (car f))) facts))
      (check-pred "all attribute scope-E"
                  (every (lambda (f) (equal? "EScopeE" (caddr f))) facts)))))


(display "\n")
(test-summary!)
