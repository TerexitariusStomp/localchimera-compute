;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-custody.scm — Custody-attestation + custody-transfer-commitment ACDCs

(use-modules (playnet test harness))
(use-modules (playnet credentials custody) (playnet credentials registry) (playnet keri acdc) (playnet keri acdc))
(use-modules (goblins))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Custody attestation: shape, claims, SAID determinism
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Attestation structure ──\n")

(let ((att (make-custody-attestation-credential
            #:issuing-authority-aid "EAuth"
            #:custodian-aid "EScopeA"
            #:resource-spec "spec:widget"
            #:qty 100
            #:valid-from "2026-04-24T00:00:00Z"
            #:valid-until "2026-12-31T00:00:00Z")))
  (check-pred "schema custody-attestation/v1"
              (equal? *schema-playnet-custody-attestation* (cred-schema att)))
  (check-pred "issuer = authority" (equal? "EAuth" (cred-issuer att)))
  (check-pred "holder = custodian" (equal? "EScopeA" (cred-holder att)))
  (check-pred "qty 100"            (= 100 (cred-claim att 'qty)))
  (check-pred "resource-spec"      (equal? "spec:widget" (cred-claim att 'resource-spec)))
  (check-pred "valid-until set"
              (equal? "2026-12-31T00:00:00Z" (cred-claim att 'valid-until)))
  (check-pred "no edges (genesis)" (null? (cred-edges att)))
  (check-pred "SAID is string"     (string? (cred-said att))))

(let ((a1 (make-custody-attestation-credential #:issuing-authority-aid "EA"
                                               #:custodian-aid "EB"
                                               #:resource-spec "spec:x"
                                               #:qty 5))
      (a2 (make-custody-attestation-credential #:issuing-authority-aid "EA"
                                               #:custodian-aid "EB"
                                               #:resource-spec "spec:x"
                                               #:qty 5)))
  (check-pred "deterministic SAID" (equal? (cred-said a1) (cred-said a2))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Supersedes edge
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Supersedes edge ──\n")

(let* ((prior (make-custody-attestation-credential #:issuing-authority-aid "EAuth"
                                                   #:custodian-aid "EA"
                                                   #:resource-spec "spec:x"
                                                   #:qty 5))
       (succ  (make-custody-attestation-credential
               #:issuing-authority-aid "EAuth"
               #:custodian-aid "EB"
               #:resource-spec "spec:x"
               #:qty 5
               #:supersedes (cred-said prior))))
  (let ((edge (cred-edge succ 'supersedes)))
    (check-pred "supersedes edge present" (not (not edge)))
    (check-pred "edge target = prior SAID" (equal? (cred-said prior) (edge-target edge)))
    (check-pred "edge operator I2I"        (eq? 'I2I (edge-operator edge)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Custody-transfer commitment: edges + carries-commitments enumeration
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Transfer commitment edges ──\n")

(let* ((old-att (make-custody-attestation-credential #:issuing-authority-aid "EAuth"
                                                     #:custodian-aid "EA"
                                                     #:resource-spec "spec:x"
                                                     #:qty 50))
       (new-att (make-custody-attestation-credential
                 #:issuing-authority-aid "EAuth"
                 #:custodian-aid "EB"
                 #:resource-spec "spec:x"
                 #:qty 50
                 #:supersedes (cred-said old-att)))
       (xfer    (make-custody-transfer-commitment-credential
                 #:from-scope-aid "EA"
                 #:to-scope-aid "EB"
                 #:resource-spec "spec:x"
                 #:qty 50
                 #:new-attestation-said (cred-said new-att)
                 #:revoked-attestation-said (cred-said old-att)
                 #:carries-commitments '("ECommit1" "ECommit2"))))
  (check-pred "schema custody-transfer-commitment/v1"
              (equal? *schema-playnet-custody-transfer-commitment*
                      (cred-schema xfer)))
  (check-pred "from-scope" (equal? "EA" (cred-claim xfer 'from-scope-aid)))
  (check-pred "to-scope"   (equal? "EB" (cred-claim xfer 'to-scope-aid)))
  (let ((new-edge (cred-edge xfer 'new-attestation))
        (rev-edge (cred-edge xfer 'revoked-attestation))
        (c0       (cred-edge xfer 'carries-commitment-0))
        (c1       (cred-edge xfer 'carries-commitment-1)))
    (check-pred "new-attestation edge points at successor"
                (equal? (cred-said new-att) (edge-target new-edge)))
    (check-pred "revoked-attestation edge points at prior"
                (equal? (cred-said old-att) (edge-target rev-edge)))
    (check-pred "carries-commitment-0 present"
                (and c0 (equal? "ECommit1" (edge-target c0))))
    (check-pred "carries-commitment-1 present"
                (and c1 (equal? "ECommit2" (edge-target c1))))))

(let* ((old-att (make-custody-attestation-credential #:issuing-authority-aid "EAuth"
                                                     #:custodian-aid "EA"
                                                     #:resource-spec "spec:x"
                                                     #:qty 1))
       (new-att (make-custody-attestation-credential #:issuing-authority-aid "EAuth"
                                                     #:custodian-aid "EB"
                                                     #:resource-spec "spec:x"
                                                     #:qty 1))
       (empty-xfer (make-custody-transfer-commitment-credential
                    #:from-scope-aid "EA"
                    #:to-scope-aid "EB"
                    #:resource-spec "spec:x"
                    #:qty 1
                    #:new-attestation-said (cred-said new-att)
                    #:revoked-attestation-said (cred-said old-att)
                    #:carries-commitments '())))
  (check-pred "no carries-commitment edges when list empty"
              (not (cred-edge empty-xfer 'carries-commitment-0))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Schemas registered in *playnet-schemas*
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Schema registration ──\n")

(check-pred "custody-attestation in *playnet-schemas*"
            (member *schema-playnet-custody-attestation* *playnet-schemas*))
(check-pred "custody-transfer-commitment in *playnet-schemas*"
            (member *schema-playnet-custody-transfer-commitment* *playnet-schemas*))


(display "\n")
(test-summary!)
