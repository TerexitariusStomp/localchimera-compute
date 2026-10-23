;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-multisig-credential.scm — k-of-n multisig signing of a credential
;;;
;;; A single-controller scope signs a credential with one key. A governance
;;; GROUP AID (k-of-n) has no single key — each member signs the SAID and the
;;; block carries a threshold of them. This is the credential-layer multisig
;;; core (the KERIA IPEX-multisig exchange that COLLECTS remote member sigs,
;;; and the keystate lookup that resolves the member set, sit above it).

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness))
(use-modules (playnet keri acdc) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair)))
(use-modules (goblins) (goblins vat) (rnrs bytevectors))

(define (fresh n) (make-keri-identity (make-bytevector 32 n)))

(define vat (spawn-vat))

(display "\n── k-of-n multisig over a credential SAID ──\n")

(with-vat vat
  ;; A 3-member governance group; threshold k = 2.
  (define m1 (fresh 51)) (define m2 (fresh 52)) (define m3 (fresh 53))
  (define members (list (keri-identity-aid m1) (keri-identity-aid m2) (keri-identity-aid m3)))
  (define group-aid "E_group_v1")
  (define signer (lambda (id) (cons (keri-identity-aid id) (keri-identity-keypair id))))

  ;; Issue an authorized-issuer credential UNDER the group AID, signed by
  ;; two of the three members.
  (define cred (make-authorized-issuer-credential
                 #:root-aid group-aid
                 #:ecosystem-aid "E_some_commune"
                 #:blessed-at 10
                 #:multisig-signers (list (signer m1) (signer m2))))

  (check-pred "multisig credential carries a signature block (not a single sig)"
              (pair? (cred-signature cred)))
  (check-pred "single-sig verifier declines a multisig block (no crash)"
              (not (cred-signature-valid? cred)))
  (check-pred "2 valid member sigs meet threshold 2"
              (cred-multisig-valid? cred members 2))
  (check-pred "…but not threshold 3"
              (not (cred-multisig-valid? cred members 3)))

  ;; Tamper: swap the holder in the alist → SAID no longer commits → reject.
  (let ((tampered (map (lambda (kv) (if (eq? (car kv) 'holder) (cons 'holder "E_mallory") kv)) cred)))
    (check-pred "digest-inconsistent multisig cred is rejected"
                (not (cred-multisig-valid? tampered members 2))))

  ;; A non-member's signature does not count toward the threshold.
  (define outsider (fresh 54))
  (define cred2 (make-authorized-issuer-credential
                  #:root-aid group-aid
                  #:ecosystem-aid "E_commune_2"
                  #:blessed-at 11
                  #:multisig-signers (list (signer m1) (signer outsider))))
  (check-pred "one member + one outsider does NOT meet threshold 2"
              (not (cred-multisig-valid? cred2 members 2)))
  (check-pred "…but meets threshold 1 (the one real member)"
              (cred-multisig-valid? cred2 members 1))

  ;; Duplicate member signatures count once.
  (define cred3 (make-authorized-issuer-credential
                  #:root-aid group-aid
                  #:ecosystem-aid "E_commune_3"
                  #:blessed-at 12
                  #:multisig-signers (list (signer m1) (signer m1))))
  (check-pred "the same member signing twice counts once (not threshold 2)"
              (not (cred-multisig-valid? cred3 members 2))))

(newline)
(test-summary!)
