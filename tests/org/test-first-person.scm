;;; test-first-person.scm — the trust triangle over the bootstrap ceremony, and a ^scope's invite / vouch / revoke
;;;
;;; The credential and verification halves that stand on the library alone are
;;; tests/keri/test-first-person.scm.

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet utils endorsement))
(use-modules (playnet federation bootstrap) (playnet boot scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (playnet crypto shamir))
(use-modules ((playnet keri signify) #:select (ed25519-keypair-public)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define (fresh-identity seed-byte)
  "Helper: deterministic KERI identity for a 1-byte seed value."
  (make-keri-identity (make-bytevector 32 seed-byte)))


(define vat (spawn-vat))
(define test-bran "0ABCDEFGHIJKLMNOPQRSTu")


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Trust triangle: bootstrap + mutual VRC closes; revocation breaks it
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Trust triangle over the bootstrap ceremony ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define ceremony (spawn-bootstrap-ceremony store))

  ($ ceremony 'add-founder "alice" "E_alice" "http://a/oobi")
  ($ ceremony 'add-founder "bob"   "E_bob"   "http://b/oobi")
  ($ ceremony 'add-founder "carol" "E_carol" "http://c/oobi")

  (define gov-aid ($ ceremony 'create-governance "river" 2))
  ($ ceremony 'create-registry "river-reg")
  ($ ceremony 'issue-founding-credentials)
  ($ ceremony 'split-bran test-bran 2 3)

  (check-pred "alice holds live PHC in ecosystem"
              (holds-live-phc? store gov-aid "E_alice"))
  (check-pred "bob   holds live PHC in ecosystem"
              (holds-live-phc? store gov-aid "E_bob"))
  (check "ecosystem has 3 live PHCs"
         (length (phcs-in-ecosystem store gov-aid)) 3)

  ;; Triangle false without VRCs.
  (check-pred "triangle #f before any VRC"
              (not (trust-triangle-holds? store "E_alice" "E_bob" gov-aid #:require-signatures? #f)))

  ;; Issue one direction only.
  (let* ((phc-a (phc-for store gov-aid "E_alice"))
         (vrc-ab (make-relationship-credential
                   #:issuer-aid "E_alice"
                   #:subject-aid "E_bob"
                   #:relationship-type 'trust
                   #:issuer-phc-said (cred-said phc-a)
                   #:issued-at 101)))
    ($ store 'issue vrc-ab)
    (check-pred "triangle #f with only one VRC"
                (not (trust-triangle-holds? store "E_alice" "E_bob" gov-aid #:require-signatures? #f))))

  ;; Issue reverse direction — triangle closes.
  (let* ((phc-b (phc-for store gov-aid "E_bob"))
         (vrc-ba (make-relationship-credential
                   #:issuer-aid "E_bob"
                   #:subject-aid "E_alice"
                   #:relationship-type 'trust
                   #:issuer-phc-said (cred-said phc-b)
                   #:issued-at 102)))
    ($ store 'issue vrc-ba)
    (check-pred "triangle closes with mutual VRCs"
                (trust-triangle-holds? store "E_alice" "E_bob" gov-aid #:require-signatures? #f)))

  ;; Revoke alice's PHC → triangle collapses, VRCs untouched.
  (let ((phc-a (phc-for store gov-aid "E_alice")))
    ($ store 'revoke (cred-said phc-a))
    (check-pred "triangle collapses when a PHC is revoked"
                (not (trust-triangle-holds? store "E_alice" "E_bob" gov-aid #:require-signatures? #f)))
    (check-pred "VRC alice→bob is still live"
                (vrc-from-to store "E_alice" "E_bob"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Invitation + vouching via ^scope
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Scope invite / vouch / revoke-phc ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "River"))
  (define scope (spawn-scope "River"
                             #:kind 'commune
                             #:scope-aid "E_river"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "operator"))

  ;; Seed alice as the first person via issue-phc.
  ($ scope 'issue-phc gov-cap "E_alice" "evidence:alice")
  (check-pred "alice enrolled via issue-phc"
              (holds-live-phc? store "E_river" "E_alice"))

  ;; Alice invites bob — sponsor must hold a live PHC.
  ($ scope 'invite gov-cap "E_alice" "E_bob" "evidence:bob")
  (check-pred "bob enrolled via invite"
              (holds-live-phc? store "E_river" "E_bob"))

  ;; Inviting with a non-member sponsor rejects.
  (check-pred "invite rejects sponsor lacking PHC"
              (catch #t
                (lambda ()
                  ($ scope 'invite gov-cap "E_stranger" "E_carol" "ev")
                  #f)
                (lambda _ #t)))

  ;; Mutual vouch → triangle closes without hand-crafting VRCs.
  ($ scope 'vouch "E_alice" "E_bob" 'trust)
  ($ scope 'vouch "E_bob"   "E_alice" 'trust)
  (check-pred "scope's trust-triangle? closes after mutual vouch"
              ($ scope 'trust-triangle? "E_alice" "E_bob"))

  ;; A person without a PHC can't vouch.
  (check-pred "vouch rejects caller with no live PHC"
              (catch #t
                (lambda ()
                  ($ scope 'vouch "E_stranger" "E_bob" 'trust) #f)
                (lambda _ #t)))

  ;; revoke-phc collapses the triangle; VRCs survive.
  (check "revoke-phc returns count of revoked PHCs"
         ($ scope 'revoke-phc gov-cap "E_alice") 1)
  (check-pred "triangle collapses after PHC revocation"
              (not ($ scope 'trust-triangle? "E_alice" "E_bob")))
  (check-pred "VRC alice→bob still present (personhood orthogonal to relationship)"
              (vrc-from-to store "E_alice" "E_bob")))


;;; 7. scope.vouch with real keypairs — proof-of-possession enforced
(display "\n── 7. Scope vouch with real KERI signatures ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "Signed"))
  (define alice (fresh-identity 7))
  (define bob   (fresh-identity 8))
  (define eve   (fresh-identity 13))
  (define scope (spawn-scope "Signed"
                             #:kind 'commune
                             #:scope-aid "E_signed"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ($ scope 'issue-phc gov-cap (keri-identity-aid alice) "evidence:alice")
  ($ scope 'issue-phc gov-cap (keri-identity-aid bob)   "evidence:bob")

  ;; Legitimate signed vouch.
  ($ scope 'vouch (keri-identity-aid alice) (keri-identity-aid bob) 'trust
     (keri-identity-keypair alice))
  ($ scope 'vouch (keri-identity-aid bob) (keri-identity-aid alice) 'trust
     (keri-identity-keypair bob))

  (check-pred "signed trust-triangle via scope.vouch closes"
              ($ scope 'trust-triangle? (keri-identity-aid alice)
                                        (keri-identity-aid bob)))

  (let ((vrc (vrc-from-to store (keri-identity-aid alice)
                                (keri-identity-aid bob))))
    (check-pred "alice→bob VRC has a signature"
                (and (cred-signature vrc) #t))
    (check-pred "alice→bob VRC signature verifies"
                (cred-signature-valid? vrc)))

  ;; Forgery attempt: eve tries to vouch AS alice using eve's keypair.
  ;; The scope must reject — signature won't verify against alice's AID.
  (check-pred "scope rejects vouch when keypair ≠ caller-aid"
              (catch #t
                (lambda ()
                  ($ scope 'vouch
                     (keri-identity-aid alice) (keri-identity-aid bob)
                     'colleague (keri-identity-keypair eve))
                  #f)
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
