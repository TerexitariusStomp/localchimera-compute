;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-scope-persistence.scm — full kill+restore round-trip for
;;; durable autonomous-signer scopes (vault and Shamir modes).
;;;
;;; Covers Phase 3 of the persistence/portability plan: durable
;;; acdc-store + kel-store + bran custody (vault & Shamir) + scope-
;;; recovery. The proof of portability is that, after killing the
;;; original vat, a second vat reads the same state-dir, restores the
;;; scope, and signs a credential whose signature validates against
;;; the original AID prefix.

(use-modules (localchimera test harness))
(use-modules )
(use-modules (localchimera credentials keys) (localchimera keri acdc) (localchimera utils paths) (localchimera boot scope) (localchimera keri acdc) (localchimera keri acdc-store) (localchimera keri citizen-sig))
(use-modules (localchimera keys keri-backend live))
(use-modules (localchimera scope recovery))
(use-modules (localchimera keri signify))   ;; install crypto backend
(use-modules (rnrs bytevectors))
(use-modules (goblins) (goblins vat))
(use-modules (ice-9 format))

(define (rand-suffix)
  (number->string (random 100000000)))

(define base-state-dir
  (string-append "/tmp/localchimera-persistence-"
                 (number->string (current-time)) "-" (rand-suffix)))

(setenv "LOCALCHIMERA_STATE_DIR" base-state-dir)
(setenv "LOCALCHIMERA_VAULT_KEY"
        ;; A deterministic but obviously-test-only host vault key
        ;; (32 bytes of 0xAB, encoded as 64 hex chars).
        (let loop ((i 0) (acc ""))
          (if (= i 32) acc
              (loop (+ i 1) (string-append acc "ab")))))

(define vat (spawn-vat))


(format #t "~%=== Vault-mode persistence: spawn → kill → restore → sign ===~%")

(define vault-aid #f)
(define ed25519-public-from-original #f)

(with-vat vat
  (let* ((be (live-keri-backend))
         (s  (spawn-scope "alice-bakery"
                          #:kind 'commune
                          #:durable? #t
                          #:keri-backend be)))
    (set! vault-aid ($ s 'scope-aid))
    (format #t "  spawned scope: ~a~%" vault-aid)

    (check "scope has keypair after spawn"
           ($ s 'has-keypair?))
    (check "vault file exists on disk"
           (file-exists? (scope-vault-path vault-aid)))
    (check "kel-store has icp event"
           (= 1 (length ($ s 'kel-events))))

    ;; Sign a SAID with the original keypair so we can compare later
    (let ((sig-original ($ s 'sign-said "ETESTSAID0000000000000000000000000000000000")))
      (check "original scope signs"
             (string? sig-original))
      (set! ed25519-public-from-original sig-original))))

;; "Kill" the original actor by losing the reference (Goblins' actor GC
;; will reclaim it). Spawn a fresh vat and restore.
(format #t "~%-- restoring in fresh vat --~%")

(define vat2 (spawn-vat))

(define restored-ref #f)

(with-vat vat2
  (let ((s (restore-scope! vault-aid
                           #:kind 'commune
                           #:keri-backend (live-keri-backend))))
    (set! restored-ref s)
    (check "restore-scope! produces a ref"
           (and s #t))
    (check "restored AID matches original"
           (equal? vault-aid ($ s 'scope-aid)))
    (check "restored scope has keypair"
           ($ s 'has-keypair?))
    (check "restored kel-store sees the original icp"
           (>= (length ($ s 'kel-events)) 1))

    ;; Sign the same SAID with the recovered keypair.
    (let ((sig-recovered ($ s 'sign-said "ETESTSAID0000000000000000000000000000000000")))
      (check "recovered scope signs"
             (string? sig-recovered))
      ;; Ed25519 signatures are deterministic for a given (key, message).
      ;; A matching signature proves the same private key was reconstructed.
      (check "signature matches original (deterministic Ed25519)"
             (equal? ed25519-public-from-original sig-recovered)))))

(format #t "~%=== Shamir-mode persistence: spawn with share-holders, restore ===~%")

(setenv "LOCALCHIMERA_STATE_DIR"
        (string-append base-state-dir "-shamir"))

(define vat3 (spawn-vat))
(define shamir-aid #f)
(define shamir-share-dir (string-append base-state-dir "-shamir-shares"))
(define sig-from-shamir-original #f)

(with-vat vat3
  (let* ((be (live-keri-backend))
         ;; Durable share-store so the second vat can reopen by reading
         ;; the same disk dir (federation peers in production each carry
         ;; their own copy on disk; this test models that with a single
         ;; shared dir).
         (_ (ensure-directory! shamir-share-dir))
         (share-store (spawn-acdc-store #:durable-dir shamir-share-dir))
         (holders '("E_holder1" "E_holder2" "E_holder3"))
         (s (spawn-scope "shamir-bakery"
                         #:kind 'commune
                         #:durable? #t
                         #:keri-backend be
                         #:share-holders holders
                         #:share-store share-store
                         #:threshold 2
                         #:issuer-aid "E_test_uc"))
         (aid ($ s 'scope-aid)))
    (set! shamir-aid aid)

    (check "shamir scope minted"
           (string-prefix? "D" aid))
    (check "no vault file (shamir mode)"
           (not (file-exists? (scope-vault-path aid))))
    (check "share-store carries 3 bran-share ACDCs"
           (= 3 (length (filter
                         (lambda (c)
                           (and (equal? *schema-localchimera-bran-share*
                                        (cred-schema c))
                                (equal? aid (cred-claim c 'subject-aid))))
                         ($ share-store 'all)))))
    (let ((sig ($ s 'sign-said "ESHAMIRSAID00000000000000000000000000000000")))
      (set! sig-from-shamir-original sig))))

(format #t "~%-- restoring shamir scope in fresh vat (k=2 of 3) --~%")

(define vat4 (spawn-vat))

(with-vat vat4
  (let* ((reopened-share-store
          (spawn-acdc-store #:durable-dir shamir-share-dir))
         (s (restore-scope! shamir-aid
                            #:kind 'commune
                            #:share-store reopened-share-store
                            #:threshold 2
                            #:keri-backend (live-keri-backend))))
    (check "shamir restore produces ref"
           (and s #t))
    (check "shamir restored AID matches"
           (equal? shamir-aid ($ s 'scope-aid)))
    (let ((sig ($ s 'sign-said "ESHAMIRSAID00000000000000000000000000000000")))
      (check "shamir-restored signature matches original"
             (equal? sig-from-shamir-original sig)))))

(format #t "~%=== a rotated scope restores at its log's depth ===~%")

(use-modules ((localchimera keri key-state) #:select (events->key-state state-key state-sn))
             ((localchimera keri citizen-sig) #:select (verify-said-signature-under-key)))

(setenv "LOCALCHIMERA_STATE_DIR" (string-append base-state-dir "-rotated"))
(define vat4 (spawn-vat))
(define rotated-aid #f)
(with-vat vat4
  (let ((s (spawn-scope "rotating-bakery" #:kind 'commune #:durable? #t #:keri-backend (live-keri-backend))))
    (set! rotated-aid ($ s 'scope-aid))
    ($ s 'rotate-keys)
    ($ s 'rotate-keys)))

(define vat5 (spawn-vat))
(with-vat vat5
  (let* ((s (restore-scope! rotated-aid #:kind 'commune #:keri-backend (live-keri-backend)))
         (said "EROTATEDSAID0000000000000000000000000000000")
         (state (events->key-state rotated-aid ($ s 'kel-events))))
    (check "the restored scope's log holds both rotations (icp, rot, rot)" (and (not (string? state)) (state-sn state)) 2)
    (check "it signs under the key the log leaves in force, not the inception key"
           (verify-said-signature-under-key said ($ s 'sign-said said) (state-key state))
           #t)
    (check "and no longer under the inception key"
           (verify-said-signature-under-key said ($ s 'sign-said said) rotated-aid)
           #f)
    ($ s 'rotate-keys)
    (let ((after (events->key-state rotated-aid ($ s 'kel-events))))
      (check "a rotation after the restart continues the log (the next committed key was derived again)"
             (and (not (string? after)) (state-sn after)) 3))))

(format #t "~%=== list-known-scopes inventory ===~%")

;; Switch back to the vault state-dir to enumerate
(setenv "LOCALCHIMERA_STATE_DIR" base-state-dir)
(let ((known (list-known-scopes)))
  (check "list-known-scopes finds the vault scope"
         (member vault-aid known)))

;; Cleanup
(system* "rm" "-rf" base-state-dir
         (string-append base-state-dir "-rotated")
         (string-append base-state-dir "-shamir")
         shamir-share-dir)

(test-summary!)
