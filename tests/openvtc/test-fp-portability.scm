;;; test-fp-portability.scm — First-Person layer survives process death
;;;
;;; Two round trips:
;;;   (A) in-vat export/import — peer A's full credential set replicates to peer B.
;;;   (B) on-disk durability — durable-dir survives a vat kill + fresh spawn.
;;;
;;; Both endpoints must reproduce identical trust-triangle results from
;;; nothing but the credential corpus, validating KERI's "end-verifiable
;;; on ambient infrastructure" property for our PHC + VRC layer.

(use-modules (playnet test harness))
(use-modules (playnet keri acdc) (playnet keri acdc-store)
             (playnet openvtc credentials) (playnet openvtc first-person)
             (playnet keri citizen-sig) (playnet keri signify-portable))
(use-modules ((playnet keri signify) #:select (ed25519-keypair-public)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1)
             (ice-9 ftw))


(define (fresh-identity seed-byte)
  (make-keri-identity (make-bytevector 32 seed-byte)))

(define (rm-rf path)
  "Recursively remove a directory tree. Test cleanup."
  (when (file-exists? path)
    (file-system-fold
      (const #t)
      (lambda (p _stat acc) (delete-file p) acc)        ;; leaf
      (lambda (p _stat acc) acc)                          ;; pre-dir
      (lambda (p _stat acc) (rmdir p) acc)                ;; post-dir
      (lambda (_p _stat _err acc) acc)                    ;; skip
      (lambda (_p _stat _err acc) acc)
      #f path)))

(define (seed-trust-triangle store eco alice bob)
  "Seed STORE with PHCs + signed mutual VRCs for ALICE and BOB inside ECO.
   Returns nothing; STORE is mutated. Uses real Ed25519 keypairs so the
   default require-signatures? #t is honoured."
  (let* ((aid-a (keri-identity-aid alice))
         (aid-b (keri-identity-aid bob))
         (kp-a  (keri-identity-keypair alice))
         (kp-b  (keri-identity-keypair bob))
         ;; PHCs are unsigned (issued "by the ecosystem" in this test —
         ;; eco is a synthetic AID, no keypair). The triangle still
         ;; requires VRCs to be signed; PHC sig requirement is separate.
         (phc-a (make-personhood-credential eco aid-a 100))
         (phc-b (make-personhood-credential eco aid-b 100)))
    ($ store 'issue phc-a)
    ($ store 'issue phc-b)
    ($ store 'issue
       (make-relationship-credential aid-a aid-b 'trust
                                      (cred-said phc-a) 101
                                      #:signing-keypair kp-a))
    ($ store 'issue
       (make-relationship-credential aid-b aid-a 'trust
                                      (cred-said phc-b) 102
                                      #:signing-keypair kp-b))))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. In-vat export → import: store-A → store-B reproduces the triangle
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. In-vat export/import round trip ──\n")

(with-vat vat
  (define eco "E_eco_inmem")
  (define alice (fresh-identity 11))
  (define bob   (fresh-identity 12))
  (define store-a (spawn-acdc-store))
  (define store-b (spawn-acdc-store))

  (seed-trust-triangle store-a eco alice bob)

  (check-pred "store-A: triangle holds with require-signatures? #t (default)"
              (trust-triangle-holds? store-a
                                     (keri-identity-aid alice)
                                     (keri-identity-aid bob)
                                     eco))

  ;; Export from A, import into a brand-new B.
  (let ((export ($ store-a 'export-since 0)))
    (check "exported 4 entries (2 PHC + 2 VRC)" (length export) 4)
    ($ store-b 'import export))

  (check-pred "store-B: same triangle reconstructs from imported corpus"
              (trust-triangle-holds? store-b
                                     (keri-identity-aid alice)
                                     (keri-identity-aid bob)
                                     eco))

  ;; Re-importing the same payload is a no-op.
  (let ((again ($ store-a 'export-since 0)))
    ($ store-b 'import again))
  (check "store-B credential count unchanged after re-import"
         (length ($ store-b 'all)) 4)

  ;; Revocation propagates: revoke a PHC on A, re-export, re-import → B agrees.
  (let* ((phc-a-said (cred-said
                       (phc-for store-a eco (keri-identity-aid alice))))
         (_revoke    ($ store-a 'revoke phc-a-said))
         (delta      ($ store-a 'export-since 0)))
    ($ store-b 'import delta)
    (check-pred "store-B: triangle collapses after revocation propagates"
                (not (trust-triangle-holds? store-b
                                            (keri-identity-aid alice)
                                            (keri-identity-aid bob)
                                            eco)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. On-disk durability: kill the vat, respawn, triangle still verifies
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Durable-dir round trip ──\n")

(define disk-dir "/tmp/playnet-fp-portability-test")
(rm-rf disk-dir)

(define vat-c (spawn-vat))
(define vat-d (spawn-vat))

(with-vat vat-c
  (define eco "E_eco_disk")
  (define alice (fresh-identity 21))
  (define bob   (fresh-identity 22))
  (define store-c (spawn-acdc-store #:durable-dir disk-dir))

  (seed-trust-triangle store-c eco alice bob)

  (check-pred "store-C: triangle holds before vat death"
              (trust-triangle-holds? store-c
                                     (keri-identity-aid alice)
                                     (keri-identity-aid bob)
                                     eco))

  ;; Persist a revocation too — and verify it reloads as revoked.
  (let ((bad-aid (keri-identity-aid (fresh-identity 99))))
    ($ store-c 'issue
       (make-personhood-credential eco bad-aid 200))
    (let ((bad-phc (phc-for store-c eco bad-aid)))
      ($ store-c 'revoke (cred-said bad-phc))
      (check-pred "store-C: revoked PHC is not live"
                  (not (holds-live-phc? store-c eco bad-aid))))))

;; Vat-c is now done with. Spawn fresh vat-d, fresh store, same dir.
(with-vat vat-d
  (define eco "E_eco_disk")
  (define alice (fresh-identity 21))
  (define bob   (fresh-identity 22))
  (define store-d (spawn-acdc-store #:durable-dir disk-dir))

  (check-pred "store-D: alice's PHC reloaded from disk"
              (holds-live-phc? store-d eco (keri-identity-aid alice)))
  (check-pred "store-D: bob's PHC reloaded from disk"
              (holds-live-phc? store-d eco (keri-identity-aid bob)))

  (check-pred "store-D: signed VRCs reloaded — triangle re-verifies"
              (trust-triangle-holds? store-d
                                     (keri-identity-aid alice)
                                     (keri-identity-aid bob)
                                     eco))

  (let ((bad-aid (keri-identity-aid (fresh-identity 99))))
    (check-pred "store-D: revocation log replayed — bad PHC stays revoked"
                (not (holds-live-phc? store-d eco bad-aid)))))

;; Vat-c is now done with. Spawn fresh vat-d, fresh store, same dir.
(rm-rf disk-dir)


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. The portable fold: personhood is any-ecosystem and recomposes
;;;    (UC-fold / refederation invariant — docs/planning/
;;;     first-person-portable-citizen-index.md). holds-any-live-phc? must
;;;     honour a PHC from ANY ecosystem in the store (a federated store
;;;     recognises a person no matter which commune issued them), and must
;;;     recompute when a credential drops — no central registry, no rebuild.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Portable any-ecosystem fold ──\n")

(define vat-e (spawn-vat))
(with-vat vat-e
  (define eco-1 "E_commune_one")
  (define eco-2 "E_commune_two")
  (define alice (fresh-identity 31))   ; a person in commune one
  (define bob   (fresh-identity 32))   ; a person in commune two
  (define carol (fresh-identity 33))   ; never enrolled anywhere
  (define a-aid (keri-identity-aid alice))
  (define b-aid (keri-identity-aid bob))
  (define c-aid (keri-identity-aid carol))
  ;; ONE store holding PHCs from TWO ecosystems — the federated fold.
  (define store (spawn-acdc-store))
  ($ store 'issue (make-personhood-credential eco-1 a-aid 100))
  ($ store 'issue (make-personhood-credential eco-2 b-aid 100))

  ;; portable: a person from EITHER ecosystem is recognised
  (check-pred "alice (eco-1) is a person, portably"
              (holds-any-live-phc? store a-aid))
  (check-pred "bob (eco-2) is a person, portably"
              (holds-any-live-phc? store b-aid))
  (check-pred "carol holds no PHC anywhere"
              (not (holds-any-live-phc? store c-aid)))
  (check-pred "any-live-phc-for returns alice's actual PHC"
              (let ((c (any-live-phc-for store a-aid)))
                (and c (equal? (cred-holder c) a-aid))))

  ;; the per-ecosystem query stays precise (alice is NOT in eco-2)
  (check-pred "alice IS in eco-1 (scoped query)"
              (holds-live-phc? store eco-1 a-aid))
  (check-pred "alice is NOT in eco-2 (scoped query)"
              (not (holds-live-phc? store eco-2 a-aid)))

  ;; the fold recomputes: revoke alice's PHC → no longer a person, no rebuild
  ($ store 'revoke (cred-said (any-live-phc-for store a-aid)))
  (check-pred "after revoke, alice is no longer a person (fold recomputed)"
              (not (holds-any-live-phc? store a-aid)))
  (check-pred "bob is unaffected by alice's revocation"
              (holds-any-live-phc? store b-aid)))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
