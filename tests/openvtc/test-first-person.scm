;;; test-first-person.scm — PHC + VRC shape, store queries, the I2I check, signed VRCs
;;;
;;; The First Person layer on its own two feet: credentials from
;;; (playnet openvtc credentials), verification from (playnet openvtc
;;; first-person), a store from (playnet keri acdc-store). The halves that run
;;; through a ^scope and the bootstrap ceremony are
;;; tests/governance/test-first-person.scm.

(use-modules (playnet test harness))
(use-modules (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig)
             (playnet openvtc credentials) (playnet openvtc first-person))
(use-modules ((playnet keri signify) #:select (ed25519-keypair-public)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define (fresh-identity seed-byte)
  "Helper: deterministic KERI identity for a 1-byte seed value."
  (make-keri-identity (make-bytevector 32 seed-byte)))


(define vat (spawn-vat))
(define test-bran "0ABCDEFGHIJKLMNOPQRSTu")


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Credential constructors shape + SAID determinism
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. PHC / VRC shape ──\n")

(let ((phc (make-personhood-credential "E_eco" "E_alice"
                                        "2026-04-23"
                                        #:enrollment-evidence-digest "h:abc")))
  (check-pred "PHC schema"
              (equal? *schema-playnet-personhood* (cred-schema phc)))
  (check-pred "issuer = ecosystem"
              (equal? "E_eco" (cred-issuer phc)))
  (check-pred "holder = person"
              (equal? "E_alice" (cred-holder phc)))
  (check-pred "ecosystem-aid claim"
              (equal? "E_eco" (cred-claim phc 'ecosystem-aid)))
  (check-pred "active by default"
              (cred-claim phc 'active))
  (check-pred "evidence digest stored"
              (equal? "h:abc" (cred-claim phc 'enrollment-evidence-digest))))

(let ((v1 (make-relationship-credential "E_alice" "E_bob" 'trust
                                         "E_phc_a" "2026-04-23"))
      (v2 (make-relationship-credential "E_alice" "E_bob" 'trust
                                         "E_phc_a" "2026-04-23")))
  (check-pred "VRC schema"
              (equal? *schema-playnet-relationship* (cred-schema v1)))
  (check-pred "same content → same SAID"
              (equal? (cred-said v1) (cred-said v2)))
  (let ((edge (cred-edge v1 'issuer-phc)))
    (check-pred "issuer-phc edge present in `e` block"
                (and edge #t))
    (check-pred "edge target points at PHC SAID"
                (equal? "E_phc_a" (edge-target edge)))
    (check-pred "edge operator = I2I"
                (eq? 'I2I (edge-operator edge)))))

(let ((v-plain (make-relationship-credential "E_alice" "E_bob" 'trust
                                              "E_phc_a" "2026-04-23"))
      (v-diff  (make-relationship-credential "E_alice" "E_bob" 'trust
                                              "E_phc_b" "2026-04-23")))
  (check-pred "different edge target ⇒ different SAID (edges SAID-covered)"
              (not (equal? (cred-said v-plain) (cred-said v-diff)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. holds-live-phc? and phc-for via ^acdc-store
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. PHC queries over acdc-store ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define phc   (make-personhood-credential "E_eco" "E_alice" 100))

  ($ store 'issue phc)

  (check-pred "holds-live-phc? true for alice in E_eco"
              (holds-live-phc? store "E_eco" "E_alice"))
  (check-pred "holds-live-phc? false for alice in unknown ecosystem"
              (not (holds-live-phc? store "E_other" "E_alice")))
  (check-pred "holds-live-phc? false for unknown holder"
              (not (holds-live-phc? store "E_eco" "E_nobody")))

  ;; Revoke → should read as no live PHC.
  ($ store 'revoke (cred-said phc))
  (check-pred "revoked PHC no longer live"
              (not (holds-live-phc? store "E_eco" "E_alice"))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Sybil case: VRCs referencing PHCs in *different* ecosystems fail I2I
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Sybil / cross-ecosystem I2I check ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define phc-a-real
    (make-personhood-credential "E_eco1" "E_alice" 100))
  (define phc-b-foreign
    (make-personhood-credential "E_eco2" "E_bob" 100))

  ($ store 'issue phc-a-real)
  ($ store 'issue phc-b-foreign)

  ;; Forge mutual VRCs — each party points at their own (wrong-ecosystem) PHC.
  ($ store 'issue
     (make-relationship-credential "E_alice" "E_bob" 'trust
                                    (cred-said phc-a-real) 101))
  ($ store 'issue
     (make-relationship-credential "E_bob" "E_alice" 'trust
                                    (cred-said phc-b-foreign) 102))

  ;; Triangle must fail in *both* ecosystems — bob has no PHC in E_eco1,
  ;; alice has no PHC in E_eco2.
  (check-pred "triangle #f in E_eco1 (bob has no PHC there)"
              (not (trust-triangle-holds? store "E_alice" "E_bob" "E_eco1" #:require-signatures? #f)))
  (check-pred "triangle #f in E_eco2 (alice has no PHC there)"
              (not (trust-triangle-holds? store "E_alice" "E_bob" "E_eco2" #:require-signatures? #f))))

;; I2I-operator negative case: a VRC whose issuer ≠ holder of the
;; referenced PHC must fail edge verification even when both PHCs are
;; in the same ecosystem. This proves the edge operator is doing real
;; work, not just shape-matching.
(with-vat vat
  (define store (spawn-acdc-store))
  (define phc-a (make-personhood-credential "E_eco" "E_alice" 100))
  (define phc-b (make-personhood-credential "E_eco" "E_bob"   100))
  ($ store 'issue phc-a)
  ($ store 'issue phc-b)

  ;; Forged VRC: alice issues, but the edge points at BOB's PHC.
  ;; I2I requires issuer (alice) = holder of target (bob) — fails.
  ($ store 'issue
     (make-relationship-credential "E_alice" "E_bob" 'trust
                                    (cred-said phc-b) 101))
  ($ store 'issue
     (make-relationship-credential "E_bob" "E_alice" 'trust
                                    (cred-said phc-a) 102))

  (check-pred "triangle #f when VRC edges violate I2I (issuer ≠ target holder)"
              (not (trust-triangle-holds? store "E_alice" "E_bob" "E_eco" #:require-signatures? #f))))


;;; ════════════════════════════════════════════════════════════════════════════

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Real KERI signatures on VRCs (Phase B)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Ed25519-signed VRCs ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define alice (fresh-identity 1))
  (define bob   (fresh-identity 2))
  (define eve   (fresh-identity 99))
  (define eco   "E_real_eco")

  ;; PHCs for alice and bob — ecosystem issues (unsigned in this test).
  ($ store 'issue
     (make-personhood-credential eco (keri-identity-aid alice) 100))
  ($ store 'issue
     (make-personhood-credential eco (keri-identity-aid bob)   100))

  ;; Alice vouches for bob with her real keypair — signed VRC.
  (let* ((phc-a (phc-for store eco (keri-identity-aid alice)))
         (vrc   (make-relationship-credential
                  (keri-identity-aid alice) (keri-identity-aid bob)
                  'trust (cred-said phc-a) 101
                  #:signing-keypair (keri-identity-keypair alice))))
    (check-pred "signed VRC carries a signature"
                (and (cred-signature vrc) #t))
    (check-pred "signature verifies against alice's AID"
                (cred-signature-valid? vrc))
    (check-pred "signature does NOT verify against bob's AID"
                (not (verify-said-signature (cred-said vrc)
                                            (cred-signature vrc)
                                            (keri-identity-aid bob)))))

  ;; Forgery resistance: eve constructs a VRC claiming alice is the
  ;; issuer but signs with her own (eve's) keypair. Since issuer ≠
  ;; keypair owner, the signature will verify against eve's AID but
  ;; NOT against alice's AID (which `cred-signature-valid?` checks).
  (let* ((phc-a  (phc-for store eco (keri-identity-aid alice)))
         (forged (make-relationship-credential
                   (keri-identity-aid alice) (keri-identity-aid bob)
                   'trust (cred-said phc-a) 101
                   #:signing-keypair (keri-identity-keypair eve))))
    (check-pred "forged VRC (eve signing as alice) fails cred-signature-valid?"
                (not (cred-signature-valid? forged))))

  ;; Trust triangle with require-signatures?: the whole thing must
  ;; verify structurally AND cryptographically.
  (let* ((phc-a (phc-for store eco (keri-identity-aid alice)))
         (phc-b (phc-for store eco (keri-identity-aid bob))))
    ($ store 'issue
       (make-relationship-credential
         (keri-identity-aid alice) (keri-identity-aid bob)
         'trust (cred-said phc-a) 101
         #:signing-keypair (keri-identity-keypair alice)))
    ($ store 'issue
       (make-relationship-credential
         (keri-identity-aid bob) (keri-identity-aid alice)
         'trust (cred-said phc-b) 102
         #:signing-keypair (keri-identity-keypair bob)))

    (check-pred "signed triangle holds without signature requirement"
                (trust-triangle-holds? store
                                       (keri-identity-aid alice)
                                       (keri-identity-aid bob) eco))
    (check-pred "signed triangle holds with #:require-signatures? #t"
                (trust-triangle-holds? store
                                       (keri-identity-aid alice)
                                       (keri-identity-aid bob) eco
                                       #:require-signatures? #t))))

;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
