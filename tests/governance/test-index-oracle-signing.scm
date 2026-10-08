;;; test-index-oracle-signing.scm — ^index-oracle issues issuer-signed observations
;;;
;;; An external-index observation is an (untargeted §7.5) assertion BY the
;;; oracle, so a conformant ACDC carries the oracle-aid's own signature. The
;;; oracle owns its keypair, so this is self-signing (the Group-1 pattern), not
;;; a client round-trip. The rollover-pricing suite exercises the oracle's
;;; read/write behaviour but spawns it WITHOUT a keypair (unsigned), so the
;;; signing path had no permanent coverage until this file.

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet governance index-oracle) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        verify-said-signature))
             (goblins) (srfi srfi-1))

(display "\n── index-oracle: signed vs unsigned observations ──\n")

(with-vat (spawn-vat)
  (let* ((oid (make-keri-identity)) (oaid (keri-identity-aid oid)))

    ;; Signed: keypair supplied → each observation carries the oracle's sig.
    (let* ((store  (spawn-acdc-store))
           (oracle (spawn-index-oracle store oaid "fred:gdp-us"
                                       (keri-identity-keypair oid))))
      ($ oracle 'observe 42.0 1700000000 "q1")
      (let ((c (car ($ oracle 'series))))
        (check "signed observation carries a signature" (and (cred-signature c) #t))
        (check "signature verifies against the oracle-aid"
               (verify-said-signature (cred-said c) (cred-signature c) oaid))
        (check "issuer is the oracle-aid" (equal? (cred-issuer c) oaid))))

    ;; Unsigned: no keypair → still issues (fixtures / tests), just no sig.
    (let* ((store2 (spawn-acdc-store))
           (o2 (spawn-index-oracle store2 oaid "fred:gdp-us")))
      ($ o2 'observe 7.0 1700000001)
      (check "no-keypair path issues an observation with no signature"
             (not (cred-signature (car ($ o2 'series))))))))

(test-summary!)
