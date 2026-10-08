;;; test-scope-phc-signing.scm — a live scope signs the PHCs it issues
;;;
;;; In production a ^scope is an autonomous single-controller signer: its AID
;;; is a D/B KERI prefix and it holds the matching keypair (from
;;; governance-create-scope-aid!). So the credentials it issues must carry a
;;; signature by that keypair — verifiable against scope-aid by any foreign
;;; gateway. This guards that issue-phc / invite sign with the scope's OWN
;;; keypair by default (not only when a caller passes one).

(use-modules (playnet test harness))
(use-modules (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet openvtc credentials) (playnet openvtc first-person))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair)))
(use-modules (goblins) (goblins vat) (rnrs bytevectors))

(define vat (spawn-vat))

(display "\n── Scope signs the PHCs it issues (autonomous-signer keypair) ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  ;; A scope whose AID is a real KERI identity with the matching keypair.
  (define signer   (make-keri-identity (make-bytevector 32 71)))
  (define eco-aid  (keri-identity-aid signer))
  (define scope    (spawn-scope "Signed-Commune"
                                #:kind 'federation
                                #:scope-aid eco-aid
                                #:keypair (keri-identity-keypair signer)
                                #:acdc-store store))
  (define gov-cap  ($ scope 'mint-gov-cap "gov"))

  ;; Unilateral enrollment — no caller keypair supplied.
  ($ scope 'issue-phc gov-cap "E_alice_member")
  (let ((phc (phc-for store eco-aid "E_alice_member")))
    (check-pred "issue-phc produced a PHC" (and phc #t))
    (check-pred "issue-phc PHC is signed by the scope and verifies"
                (cred-signature-valid? phc)))

  ;; Sponsored enrollment (invite) — alice sponsors bob.
  ($ scope 'invite gov-cap "E_alice_member" "E_bob_member")
  (let ((phc (phc-for store eco-aid "E_bob_member")))
    (check-pred "invite produced a PHC" (and phc #t))
    (check-pred "invite PHC is signed by the scope and verifies"
                (cred-signature-valid? phc))
    (check-pred "invite PHC records the sponsor"
                (equal? "E_alice_member" (cred-claim phc 'sponsor-aid)))))

(display "\n── A blessed scope's PHCs are structurally rooted (issuer-authz edge) ──\n")

(with-vat vat
  (define store  (spawn-acdc-store))
  (define root   (make-keri-identity (make-bytevector 32 72)))
  (define signer (make-keri-identity (make-bytevector 32 73)))
  (define root-aid (keri-identity-aid root))
  (define eco-aid  (keri-identity-aid signer))
  (define scope    (spawn-scope "Blessed-Commune"
                                #:kind 'federation
                                #:scope-aid eco-aid
                                #:keypair (keri-identity-keypair signer)
                                #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "gov"))

  ;; Root blesses the scope: a signed AIC (root → scope) lands in its store.
  ($ store 'issue (make-authorized-issuer-credential
                    root-aid eco-aid 10
                    #:signing-keypair (keri-identity-keypair root)))

  ;; Now a PHC the scope issues carries the issuer-authz edge and chains to
  ;; root STRUCTURALLY (end-verifiable from the PHC alone, sig-checked).
  ($ scope 'issue-phc gov-cap "E_carol_member")
  (let ((phc (phc-for store eco-aid "E_carol_member")))
    (check-pred "issued PHC carries an issuer-authz edge"
                (and (phc-issuer-authz-edge phc) #t))
    (check-pred "issued PHC chains to root structurally (require-signature? #t)"
                (phc-chains-to-root? store phc root-aid))
    (check-pred "and the PHC itself verifies (signed by the scope)"
                (cred-signature-valid? phc))))


(display "\n── bless-issuer: a federation populates the trust registry by AID ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define fed   (make-keri-identity (make-bytevector 32 74)))
  (define fed-aid (keri-identity-aid fed))
  (define federation (spawn-scope "Fed" #:kind 'federation
                                  #:scope-aid fed-aid
                                  #:keypair (keri-identity-keypair fed)
                                  #:acdc-store store))
  (define commune-aid "E_member_commune")

  (check-pred "commune does NOT chain before blessing"
              (not (issuer-chains-to-root? store fed-aid commune-aid)))
  ($ federation 'bless-issuer ($ federation 'mint-gov-cap "b") commune-aid)
  (check-pred "bless-issuer: commune now chains to root under require-signature? #t"
              (issuer-chains-to-root? store fed-aid commune-aid))
  (check-pred "the blessing AIC is signed by the federation and verifies"
              (cred-signature-valid? (authorized-issuer-cred store fed-aid commune-aid))))


(newline)
(test-summary!)
