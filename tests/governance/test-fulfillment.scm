;;; test-fulfillment.scm — commitment-fulfillment co-signature + spec hierarchy

(use-modules (playnet test harness))
(use-modules (playnet scope root) (srfi srfi-1))
(use-modules (playnet credentials commitments) (playnet credentials custody) (playnet keri acdc) (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


(define (make-leaf store name aid)
  (let ((root (spawn-scope-root name)))
    (spawn-scope name
                 #:kind 'commune
                 #:scope-root-ref root
                 #:scope-aid aid
                 #:acdc-store store)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Captured-provider self-flag is no longer enough
;;;
;;; A leaf with an outstanding commitment tries to transfer custody
;;; with carries='() (asserting "no obligations follow"). The receiver
;;; has NOT issued a fulfillment ACDC. The validator must reject —
;;; the old per-commitment 'finished claim no longer matters.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Self-flag insufficient ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (let* ((store (spawn-acdc-store))
         (scope (make-leaf store "Bakery" "EBakery"))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:bread" 10)
    ;; Outstanding commitment to a buyer.
    ($ store 'issue
       (make-commitment-credential
        "EBakery" "EBuyer" "comm-1" 'transfer
        #:resource-conforms-to "spec:bread"
        #:resource-quantity (cons 5 "loaf")))
    ;; Provider tries to transfer with no carries — must fail.
    (check-pred "transfer rejected without fulfillment ACDC"
                (catch #t
                  (lambda ()
                    ($ scope 'transfer-custody gov "spec:bread" 10 "EOther"
                       'carries '())
                    #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Receiver-issued fulfillment ACDC unblocks the transfer
;;;
;;; Same scenario, but the receiver has co-attested fulfillment.
;;; The transfer with empty carries should now succeed because
;;; outstanding-commitments-of-spec returns empty.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Fulfillment ACDC unblocks ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (let* ((store (spawn-acdc-store))
         (scope (make-leaf store "Bakery2" "EBakery2"))
         (gov   ($ scope 'mint-gov-cap "op"))
         (cmt   (make-commitment-credential
                 "EBakery2" "EBuyer" "comm-2" 'transfer
                 #:resource-conforms-to "spec:bread"
                 #:resource-quantity (cons 5 "loaf"))))
    ($ scope 'attest-custody gov "spec:bread" 10)
    ($ store 'issue cmt)
    ;; Receiver issues fulfillment.
    ($ store 'issue
       (make-commitment-fulfillment-credential
        "EBuyer" "EBakery2" (cred-said cmt)))
    ;; Outstanding now empty → transfer with carries='() succeeds.
    (let ((said ($ scope 'transfer-custody gov "spec:bread" 10 "EOther"
                  'carries '())))
      (check-pred "transfer succeeds" (string? said)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Spec hierarchy: parent transfer respects child commitments
;;;
;;; A commitment for "spec:wheat-A" is registered as a specialization
;;; of "spec:wheat". A transfer of "spec:wheat" must consider the
;;; spec:wheat-A commitment outstanding.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Spec hierarchy ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (register-spec-generalization! "spec:wheat-A" "spec:wheat")
  (let* ((store (spawn-acdc-store))
         (scope (make-leaf store "Mill" "EMill"))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:wheat" 100)
    ;; Commitment for the SPECIFIC sub-spec
    ($ store 'issue
       (make-commitment-credential
        "EMill" "EClient" "comm-3" 'transfer
        #:resource-conforms-to "spec:wheat-A"
        #:resource-quantity (cons 25 "kg")))
    ;; Outstanding-of-spec for the PARENT must surface it
    (check-pred "parent transfer sees child commitment"
                (let ((outstanding ($ scope 'outstanding-commitments-of-spec
                                      "spec:wheat")))
                  (= 1 (length outstanding))))
    ;; Transfer of parent without enumerating it must fail
    (check-pred "transfer of parent rejects orphan child"
                (catch #t
                  (lambda ()
                    ($ scope 'transfer-custody gov "spec:wheat" 100 "EOther"
                       'carries '())
                    #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Spec hierarchy: unrelated sibling NOT considered outstanding
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Spec hierarchy: unrelated siblings ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (register-spec-generalization! "spec:wheat-A" "spec:wheat")
  (register-spec-generalization! "spec:rye-A"   "spec:rye")
  (let* ((store (spawn-acdc-store))
         (scope (make-leaf store "M2" "EM2"))
         (gov   ($ scope 'mint-gov-cap "op")))
    ($ scope 'attest-custody gov "spec:rye" 50)
    ($ store 'issue
       (make-commitment-credential
        "EM2" "EC" "comm-4" 'transfer
        #:resource-conforms-to "spec:wheat-A"   ;; unrelated branch
        #:resource-quantity (cons 5 "kg")))
    (check-pred "transfer of rye unaffected by wheat-A commitment"
                (let ((said ($ scope 'transfer-custody gov "spec:rye" 50 "EOther"
                              'carries '())))
                  (string? said)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Transfer with 'all auto-enumerates child specs
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Auto-enumerate across hierarchy ──\n")

(with-vat vat
  (clear-spec-generalizations!)
  (register-spec-generalization! "spec:wheat-A" "spec:wheat")
  (register-spec-generalization! "spec:wheat-B" "spec:wheat")
  (let* ((store (spawn-acdc-store))
         (scope (make-leaf store "M3" "EM3"))
         (gov   ($ scope 'mint-gov-cap "op"))
         (c-a (make-commitment-credential
               "EM3" "EClient1" "comm-5a" 'transfer
               #:resource-conforms-to "spec:wheat-A"
               #:resource-quantity (cons 10 "kg")))
         (c-b (make-commitment-credential
               "EM3" "EClient2" "comm-5b" 'transfer
               #:resource-conforms-to "spec:wheat-B"
               #:resource-quantity (cons 15 "kg"))))
    ($ scope 'attest-custody gov "spec:wheat" 100)
    ($ store 'issue c-a)
    ($ store 'issue c-b)
    (let* ((xfer-said ($ scope 'transfer-custody gov "spec:wheat" 100 "ENew"))
           (xfer (find (lambda (c) (equal? xfer-said (cred-said c)))
                       ($ store 'by-schema
                          *schema-playnet-custody-transfer-commitment*))))
      (let ((targets (list (and (cred-edge xfer 'carries-commitment-0)
                                (edge-target (cred-edge xfer 'carries-commitment-0)))
                           (and (cred-edge xfer 'carries-commitment-1)
                                (edge-target (cred-edge xfer 'carries-commitment-1))))))
        (check-pred "wheat-A SAID enumerated"
                    (member (cred-said c-a) targets))
        (check-pred "wheat-B SAID enumerated"
                    (member (cred-said c-b) targets))))))


(display "\n")
(test-summary!)
