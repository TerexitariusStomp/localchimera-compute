;;; tests/keri/test-body-credential.scm — a body's standing is a credential chain in the vLEI's shape
;;;
;;; What this pins (keri/first-person/credentials.scm + predicates.scm):
;;;   • a scope holding an AIC issues a body credential to the body's group
;;;     AID; it chains to the root through its `issuer-authz` I2I edge;
;;;   • a role carrying the `body` edge verifies k-of-n AND the chain;
;;;   • chained validity: the body credential revoked, the role falls;
;;;   • a role whose edge names another body fails `edge-i2i-holds?`;
;;;   • the schema documents pin the edges' operator to I2I;
;;;   • the usage and issuance disclaimers ride on every body credential.
;;;
;;; Run: guile -L module tests/keri/test-body-credential.scm
(use-modules (playnet test harness)
             (playnet keri signify)
             ((playnet keri crypto-primitives) #:select (ed25519-keypair-public))
             ((playnet keri signify-portable) #:select (bran->signing-keypair public-key->aid-prefix))
             ((playnet keri citizen-sig) #:select (sign-said-multisig make-keri-identity keri-identity-aid keri-identity-keypair))
             (playnet keri acdc)
             ((playnet keri acdc-store) #:select (spawn-acdc-store))
             ((playnet keri schemas) #:select (read-schema-alist))
             ((playnet keri credentials) #:select (%schema-body %schema-body-role governance-schema->keria-said))
             (playnet keri first-person credentials)
             (playnet keri first-person predicates)
             (goblins) (goblins vat) (rnrs bytevectors)
             (srfi srfi-1))

(define (key-of kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define kps (map bran->signing-keypair '("0ADEMOalice000000000X" "0ADEMObob00000000000X" "0ADEMOcarol000000000X")))
(define stewards (map key-of kps))
(define signers (map cons stewards kps))
(define BODY "EBODYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define OTHER-BODY "EOTHERBODYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define TIA "EHOLDERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

(define vat (spawn-vat))
(with-vat vat
  (let* ((root  (make-keri-identity (make-bytevector 32 1))) (ROOT (keri-identity-aid root))
         (scope (make-keri-identity (make-bytevector 32 2))) (SCOPE (keri-identity-aid scope))
         (eco-x (make-keri-identity (make-bytevector 32 3))) (ECO-X (keri-identity-aid eco-x))
         (store (spawn-acdc-store))
         (aic (make-authorized-issuer-credential #:root-aid ROOT
                                                 #:ecosystem-aid SCOPE
                                                 #:blessed-at 5
                                                 #:signing-keypair (keri-identity-keypair root)))
         (body (make-body-credential #:ecosystem-aid SCOPE
                                     #:body-aid BODY
                                     #:admitted-at 100
                                     #:kind 'cooperative
                                     #:jurisdiction "FR"
                                     #:legal-ids '((lei . "506700GE1G29325QX363") (siren . "123456789"))
                                     #:quorum 2
                                     #:issuer-authz-said (cred-said aic)
                                     #:signing-keypair (keri-identity-keypair scope))))
    ($ store 'issue aic)
    ($ store 'issue body)

    (display "\n── the body credential ──\n")
    (check "schema" *schema-playnet-body* (cred-schema body))
    (check "issuer is the admitting scope" SCOPE (cred-issuer body))
    (check "holder is the body" BODY (cred-holder body))
    (check "kind" 'cooperative (cred-claim body 'kind))
    (check "jurisdiction" "FR" (cred-claim body 'jurisdiction))
    (check "the LEI rides in legal-ids" "506700GE1G29325QX363" (assq-ref (cred-claim body 'legal-ids) 'lei))
    (check "quorum" 2 (cred-claim body 'quorum))
    (check "admitted-at" 100 (cred-claim body 'admitted-at))
    (check "no expiry when none given" #f (cred-claim body 'expires-at))
    (check "a blinding nonce is minted" (string? (cred-claim body 'u)))
    (check "the usage disclaimer rides" %usage-disclaimer (cred-claim body 'usage-disclaimer))
    (check "the issuance disclaimer rides" %issuance-disclaimer (cred-claim body 'issuance-disclaimer))
    (check "the disclaimers say what they are for"
           (and (string-contains %usage-disclaimer "does not assert")
                (string-contains %issuance-disclaimer "reasonable care")
                (string-contains %issuance-disclaimer "accurate")))
    (check "the issuer-authz edge names the AIC" (cred-said aic) (edge-target (cred-edge body 'issuer-authz)))
    (check "the edge is I2I" 'I2I (edge-operator (cred-edge body 'issuer-authz)))
    (check "the edge's schema is the AIC's" *schema-playnet-authorized-issuer* (edge-schema (cred-edge body 'issuer-authz)))
    (check "the SAID commits to the content" (cred-said-consistent? body))
    (check "the scope's signature verifies" (cred-signature-valid? body))
    (check "the schema label maps to the stamped SAID" %schema-body (governance-schema->keria-said *schema-playnet-body*))
    (check "the role label maps to the stamped SAID" %schema-body-role (governance-schema->keria-said *schema-playnet-body-role*))

    (display "\n── it chains to the root ──\n")
    (check "valid under the root, the chain read from the store"
           #t (body-credential-valid? body #:roots ROOT #:store store))
    (check "valid under a list of roots" #t (body-credential-valid? body #:roots (list "EOTHERROOT" ROOT) #:store store))
    (check "valid with no root asked" #t (body-credential-valid? body))
    (check "under another root it does not chain" #f (body-credential-valid? body #:roots "ENOBODYSROOT" #:store store))
    (check "without a store the edge cannot resolve" #f (body-credential-valid? body #:roots ROOT))
    (check "a body admitted by the root itself needs no edge"
           #t (body-credential-valid? (make-body-credential #:ecosystem-aid ROOT
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:signing-keypair (keri-identity-keypair root))
                                      #:roots ROOT #:store store))
    (check "a scope no root blessed does not chain"
           #f (body-credential-valid? (make-body-credential #:ecosystem-aid ECO-X
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:signing-keypair (keri-identity-keypair eco-x))
                                      #:roots ROOT #:store store))
    (check "unsigned is not valid"
           #f (body-credential-valid? (make-body-credential #:ecosystem-aid SCOPE
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:issuer-authz-said (cred-said aic))))
    (check "…unless the signature is not asked"
           #t (body-credential-valid? (make-body-credential #:ecosystem-aid SCOPE
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:issuer-authz-said (cred-said aic))
                                      #:roots ROOT #:store store #:require-signature? #f))
    (check "an expired body credential is not live"
           #f (body-credential-valid? (make-body-credential #:ecosystem-aid SCOPE
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:expires-at 200
                                                            #:signing-keypair (keri-identity-keypair scope))))
    (check "an edge at the wrong credential does not chain"
           #f (body-credential-valid? (make-body-credential #:ecosystem-aid SCOPE
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:issuer-authz-said (cred-said body)
                                                            #:signing-keypair (keri-identity-keypair scope))
                                      #:roots ROOT #:store store))
    (check "an edge the issuer does not hold does not chain"
           #f (body-credential-valid? (make-body-credential #:ecosystem-aid ECO-X
                                                            #:body-aid BODY
                                                            #:admitted-at 100
                                                            #:issuer-authz-said (cred-said aic)
                                                            #:signing-keypair (keri-identity-keypair eco-x))
                                      #:roots ROOT #:store store))
    (check "a tampered claim under the old SAID is not valid"
           #f (body-credential-valid?
               (map (lambda (p) (if (eq? (car p) 'claims)
                                    (cons 'claims (map (lambda (c) (if (eq? (car c) 'kind) (cons 'kind 'foundation) c)) (cdr p)))
                                    p))
                    body)))
    (check "a personhood is not a body credential"
           #f (body-credential-valid? (make-personhood-credential #:ecosystem-aid SCOPE
                                                                  #:holder-aid TIA
                                                                  #:enrolled-at 100
                                                                  #:signing-keypair (keri-identity-keypair scope))))

    (display "\n── a role chained to it ──\n")
    (let* ((role (make-body-role-credential #:body-aid BODY
                                            #:holder-aid TIA
                                            #:role 'steward
                                            #:since "2026-10-10T00:00:00Z"
                                            #:quorum 2
                                            #:u "n"
                                            #:body-cred-said (cred-said body)))
           (signed (body-role-credential-with-block role (sign-said-multisig (cred-said role) (list (first signers) (third signers)))))
           (other (make-body-credential #:ecosystem-aid SCOPE
                                        #:body-aid OTHER-BODY
                                        #:admitted-at 100
                                        #:issuer-authz-said (cred-said aic)
                                        #:signing-keypair (keri-identity-keypair scope)))
           (astray (make-body-role-credential #:body-aid BODY
                                              #:holder-aid TIA
                                              #:role 'steward
                                              #:since "2026-10-10T00:00:00Z"
                                              #:quorum 2
                                              #:u "n"
                                              #:body-cred-said (cred-said other))))
      ($ store 'issue other)
      (check "the role's edge is I2I at the body schema"
             (list 'I2I *schema-playnet-body*)
             (list (edge-operator (cred-edge role 'body)) (edge-schema (cred-edge role 'body))))
      (check "k of n and the chain verify" #t (body-role-credential-valid? signed stewards 2 #:roots ROOT #:store store))
      (check "k of n with the body credential in hand" #t (body-role-credential-valid? signed stewards 2 #:body-cred body #:roots ROOT #:store store))
      (check "the chain stands and k − 1 does not"
             #f (body-role-credential-valid? (body-role-credential-with-block role (sign-said-multisig (cred-said role) (list (second signers))))
                                             stewards 2 #:roots ROOT #:store store))
      (check "a role whose edge names another body fails: the issuer is not that body"
             #f (body-role-credential-valid?
                 (body-role-credential-with-block astray (sign-said-multisig (cred-said astray) (list (first signers) (second signers))))
                 stewards 2 #:roots ROOT #:store store))
      (check "the same, with the other body's credential in hand"
             #f (body-role-credential-valid?
                 (body-role-credential-with-block astray (sign-said-multisig (cred-said astray) (list (first signers) (second signers))))
                 stewards 2 #:body-cred other))
      (check "edge-i2i-holds? is the gate that fails it" #f (edge-i2i-holds? (cred-edge astray 'body) astray other))
      (check "…and holds for the body's own role" #t (edge-i2i-holds? (cred-edge role 'body) role body))
      (check "the body credential under another root fails the role"
             #f (body-role-credential-valid? signed stewards 2 #:roots "ENOBODYSROOT" #:store store))
      ;; chained validity: revoke the body credential, the role falls
      ($ store 'revoke (cred-said body))
      (check "the body credential revoked, the role read from the store fails"
             #f (body-role-credential-valid? signed stewards 2 #:roots ROOT #:store store))
      (check "the store's revoked copy says the same" #f (body-credential-valid? ($ store 'get (cred-said body)))))))

(display "\n── the schema documents pin the chain ──\n")
(define (edge-operator-const doc edge)
  (let* ((e (assoc-ref (assoc-ref doc "properties") "e"))
         (full (vector-ref (assoc-ref e "oneOf") 1))
         (spec (assoc-ref (assoc-ref full "properties") edge)))
    (assoc-ref (assoc-ref (assoc-ref spec "properties") "o") "const")))
(define body-doc (read-schema-alist "body.json"))
(define role-doc (read-schema-alist "body-role.json"))
(check "body.json pins issuer-authz to I2I" "I2I" (edge-operator-const body-doc "issuer-authz"))
(check "body-role.json pins body to I2I" "I2I" (edge-operator-const role-doc "body"))
(check "body.json's $id is the stamped SAID" %schema-body (assoc-ref body-doc "$id"))
(check "body-role.json's $id is the stamped SAID" %schema-body-role (assoc-ref role-doc "$id"))
(define (attribute-names doc)
  (map car (assoc-ref (vector-ref (assoc-ref (assoc-ref (assoc-ref doc "properties") "a") "oneOf") 1) "properties")))
(check "body.json lists the claims"
       (every (lambda (k) (member k (attribute-names body-doc)))
              '("kind" "jurisdiction" "legal-ids" "quorum" "admitted-at" "expires-at" "usage-disclaimer" "issuance-disclaimer")))
(check "body-role.json lists the claims"
       (every (lambda (k) (member k (attribute-names role-doc))) '("role" "since" "until" "quorum")))

(test-summary!)
