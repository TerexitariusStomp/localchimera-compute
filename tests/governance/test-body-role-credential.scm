;;; tests/governance/test-body-role-credential.scm — a body's role credential, signed by its stewards
;;;
;;; What this pins (keri/first-person/credentials.scm, the body-role projection):
;;;   • k signatures from distinct stewards over the SAID verify; k−1 do not;
;;;   • a non-steward's signature does not count toward k;
;;;   • the SAID commits to the content and not to the block: one credential,
;;;     any block, one SAID; a changed claim is not the same credential;
;;;   • stewards whose AIDs are key logs (E-prefix) verify through the bound
;;;     key resolver, as the gateway binds it.
;;;
;;; Run: guile -L module tests/governance/test-body-role-credential.scm
(use-modules (playnet test harness)
             (playnet keri signify)
             ((playnet keri crypto-primitives) #:select (ed25519-keypair-public))
             ((playnet keri signify-portable) #:select (bran->signing-keypair public-key->aid-prefix))
             ((playnet keri citizen-sig) #:select (sign-said-multisig sign-said aid-signer-keys-resolver))
             ((playnet keri acdc) #:select (cred-said cred-schema cred-issuer cred-holder cred-claim cred-signature))
             (playnet keri first-person credentials)
             (srfi srfi-1))

(define (key-of kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define kps (map bran->signing-keypair '("0ADEMOalice000000000X" "0ADEMObob00000000000X" "0ADEMOcarol000000000X")))
(define stranger (bran->signing-keypair "0ADEMOmallory0000000X"))
;; stewards named by their keys: D-prefix AIDs carry the key the verifier reads
(define stewards (map key-of kps))
(define signers (map cons stewards kps))
(define body-aid "EBODYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define holder "EHOLDERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

(display "\n── the unsigned credential ──\n")
(define cred (make-body-role-credential body-aid holder 'steward "2026-10-10T00:00:00Z" #:quorum 2 #:u "nonce-1"))
(check "schema" *schema-playnet-body-role* (cred-schema cred))
(check "issuer is the body" body-aid (cred-issuer cred))
(check "holder" holder (cred-holder cred))
(check "role" 'steward (cred-claim cred 'role))
(check "quorum" 2 (cred-claim cred 'quorum))
(check "no until when none given" #f (cred-claim cred 'until))
(check "unsigned" #f (cred-signature cred))
(check "unsigned is not valid" #f (body-role-credential-valid? cred stewards 2))
(check "until rides when given" "2027-01-01T00:00:00Z"
       (cred-claim (make-body-role-credential body-aid holder 'member "2026-10-10T00:00:00Z" #:until "2027-01-01T00:00:00Z") 'until))

(display "\n── k of n ──\n")
(define said (cred-said cred))
(define (block . who) (sign-said-multisig said (filter (lambda (s) (member (car s) who)) signers)))
(define two (body-role-credential-with-block cred (block (first stewards) (third stewards))))
(check "two of three verify" #t (body-role-credential-valid? two stewards 2))
(check "the SAID is the unsigned one" said (cred-said two))
(check "three verify" #t (body-role-credential-valid? (body-role-credential-with-block cred (block (first stewards) (second stewards) (third stewards))) stewards 2))
(check "one of three does not" #f (body-role-credential-valid? (body-role-credential-with-block cred (block (second stewards))) stewards 2))
(check "k = 3 needs all three" #f (body-role-credential-valid? two stewards 3))
(check "the same steward twice counts once"
       #f (body-role-credential-valid? (body-role-credential-with-block cred (append (block (first stewards)) (block (first stewards)))) stewards 2))

(display "\n── a non-steward ──\n")
(define with-stranger
  (body-role-credential-with-block cred (cons (cons (key-of stranger) (sign-said said stranger)) (block (second stewards)))))
(check "a stranger's signature does not count" #f (body-role-credential-valid? with-stranger stewards 2))
(check "a steward's signature under a stranger's name does not count"
       #f (body-role-credential-valid? (body-role-credential-with-block cred (list (cons (first stewards) (sign-said said stranger)) (cons (second stewards) (sign-said said (second kps))))) stewards 2))
(check "the block over another SAID does not verify"
       #f (body-role-credential-valid? (body-role-credential-with-block cred (sign-said-multisig "EOTHERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" signers)) stewards 2))

(display "\n── the SAID commits to the content, not the block ──\n")
(check "any block, one SAID"
       (delete-duplicates (map (lambda (c) (cred-said c))
                               (list two (body-role-credential-with-block cred (block (second stewards))) cred)))
       (list said))
(define tampered (map (lambda (p) (if (eq? (car p) 'claims)
                                      (cons 'claims (map (lambda (c) (if (eq? (car c) 'role) (cons 'role 'officer) c)) (cdr p)))
                                      p))
                      two))
(check "a changed claim under the old SAID is not valid" #f (body-role-credential-valid? tampered stewards 2))
(check "another role is another SAID"
       (not (equal? said (cred-said (make-body-role-credential body-aid holder 'officer "2026-10-10T00:00:00Z" #:quorum 2 #:u "nonce-1")))))
(check "another holder is another SAID"
       (not (equal? said (cred-said (make-body-role-credential body-aid "EOTHERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" 'steward "2026-10-10T00:00:00Z" #:quorum 2 #:u "nonce-1")))))
(check "a contact point is not a body role"
       #f (body-role-credential-valid? (body-role-credential-with-block (make-contact-point-credential holder 'email "a@b" #:u "n") (block (first stewards) (second stewards))) stewards 2))

(display "\n── stewards as key logs: the resolver ──\n")
(define log-aids '("EALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "EBOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "ECAROLAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
(define table (map (lambda (aid kp) (cons aid (list (key-of kp)))) log-aids kps))
(define log-block (sign-said-multisig said (map cons log-aids kps)))
(check "without the resolver an E-prefix steward's signature does not resolve"
       #f (body-role-credential-valid? (body-role-credential-with-block cred log-block) log-aids 2))
(aid-signer-keys-resolver (lambda (aid at) (or (assoc-ref table aid) '())))
(check "with the resolver bound, k of n verify"
       #t (body-role-credential-valid? (body-role-credential-with-block cred log-block) log-aids 2))
(check "and a stranger's log still does not count"
       #f (body-role-credential-valid? (body-role-credential-with-block cred (list (car log-block) (cons "ESTRANGERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" (sign-said said stranger)))) log-aids 2))
(aid-signer-keys-resolver #f)

(test-summary!)
