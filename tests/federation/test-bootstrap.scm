;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-bootstrap.scm — governance bootstrap ceremony
;;;
;;; Tests the full founding ceremony: register founders, create governance
;;; AID, create registry, issue credentials, split bran, distribute shares,
;;; reconstruct bran from k shares.

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness))
(use-modules (playnet federation bootstrap) (playnet credentials keys) (playnet credentials membership) (playnet keri acdc) (playnet keri first-person credentials) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (playnet crypto shamir))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define vat (spawn-vat))
(define test-bran "0ABCDEFGHIJKLMNOPQRSTu")


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Full ceremony — 3 founders, k=2 threshold
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Full bootstrap ceremony ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define ceremony (spawn-bootstrap-ceremony store))

  (check "initial state = awaiting-founders"
         ($ ceremony 'status) 'awaiting-founders)

  ;; Register 3 founders
  ($ ceremony 'add-founder "alice" "E_alice_aid" "http://alice.local/oobi")
  ($ ceremony 'add-founder "bob"   "E_bob_aid"   "http://bob.local/oobi")
  ($ ceremony 'add-founder "carol" "E_carol_aid" "http://carol.local/oobi")

  (check "3 founders registered"
         (length ($ ceremony 'founders)) 3)

  ;; Create governance group
  (define gov-aid ($ ceremony 'create-governance "river-federation" 2))
  (check-pred "governance AID created" (string? gov-aid))

  (check "state after create-governance"
         ($ ceremony 'status) 'creating-registry)

  ;; Create registry
  (let ((rid ($ ceremony 'create-registry "river-registry")))
    (check-pred "registry ID created"
                (string? rid)))

  (check "state after create-registry"
         ($ ceremony 'status) 'issuing-credentials)

  ;; Issue founding credentials: 1 genesis self-blessing AIC + membership
  ;; + PHC per founder.
  (let ((issued ($ ceremony 'issue-founding-credentials)))
    (check "7 credentials issued (genesis AIC + membership + PHC × 3)"
           (length issued) 7))

  ;; Genesis root: the founding commune self-blesses as authorized issuer,
  ;; and every founder PHC is structurally rooted to it.
  (check-pred "genesis self-blessing AIC exists (root == ecosystem == gov-aid)"
              (issuer-chains-to-root? store gov-aid gov-aid))
  (let ((phc (phc-for store gov-aid "E_alice_aid")))
    (check-pred "founder PHC carries an issuer-authz edge"
                (and phc (phc-issuer-authz-edge phc)))
    (check-pred "founder PHC structurally chains to the genesis root"
                (phc-chains-to-root? store phc gov-aid #:require-signature? #f)))

  (check "state after credentials"
         ($ ceremony 'status) 'splitting-bran)

  ;; Split bran (k=2, n=3)
  (let ((n-shares ($ ceremony 'split-bran test-bran 2 3)))
    (check "3 shares created"
           n-shares 3))

  (check "state after split"
         ($ ceremony 'status) 'distributing-shares)

  ;; Distribute shares
  (let ((s1 ($ ceremony 'get-share 1))
        (s2 ($ ceremony 'get-share 2)))
    (check-pred "share 1 retrieved"
                (= (share-index s1) 1))
    (check-pred "share 2 retrieved"
                (= (share-index s2) 2))

    (check "1 share remaining"
           ($ ceremony 'shares-remaining) 1)

    ;; Reconstruct from any 2 shares
    (let ((reconstructed (utf8->string (shamir-combine (list s1 s2)))))
      (check "bran reconstructed from shares 1+2"
             reconstructed test-bran)))

  (let ((s3 ($ ceremony 'get-share 3)))
    (check "ceremony complete"
           ($ ceremony 'status) 'complete)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. run-full convenience
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. run-full convenience ──\n")

(with-vat vat
  (define store2 (spawn-acdc-store))
  (define ceremony2 (spawn-bootstrap-ceremony store2))

  ($ ceremony2 'add-founder "dave"  "E_dave_aid"  "http://dave.local/oobi")
  ($ ceremony2 'add-founder "eve"   "E_eve_aid"   "http://eve.local/oobi")
  ($ ceremony2 'add-founder "frank" "E_frank_aid" "http://frank.local/oobi")

  (let ((result (bootstrap-ceremony! ceremony2 "test-fed" 2 "test-reg" test-bran 2 3)))
    (check-pred "run-full returns status alist"
                (assoc-ref result 'governance-aid))
    (check "run-full threshold"
           (assoc-ref result 'threshold) 2)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. ACDC store has bran-share credentials after ceremony
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Bran-share credentials in store ──\n")

(with-vat vat
  (define store3 (spawn-acdc-store))
  (define ceremony3 (spawn-bootstrap-ceremony store3))

  ($ ceremony3 'add-founder "gina"  "E_gina_aid"  "http://gina.local/oobi")
  ($ ceremony3 'add-founder "hank"  "E_hank_aid"  "http://hank.local/oobi")

  (bootstrap-ceremony! ceremony3 "cred-test" 2 "cred-reg" test-bran 2 2)

  (let ((share-creds ($ store3 'by-schema *schema-playnet-bran-share*)))
    (check "2 bran-share credentials in store"
           (length share-creds) 2)
    (check-pred "share credential has threshold=2"
                (= 2 (cred-claim (car share-creds) 'threshold))))

  (let ((member-creds ($ store3 'by-schema *schema-playnet-membership*)))
    (check "2 membership credentials in store"
           (length member-creds) 2))

  (let ((phc-creds ($ store3 'by-schema *schema-playnet-personhood*)))
    (check "2 PHCs in store (one per founder)"
           (length phc-creds) 2)
    (check-pred "founder PHC is live (not revoked)"
                (not (cred-revoked? (car phc-creds))))
    (check-pred "founder PHC active = #t"
                (cred-claim (car phc-creds) 'active))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. State enforcement — wrong-state errors
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. State enforcement ──\n")

(with-vat vat
  (define store4 (spawn-acdc-store))
  (define ceremony4 (spawn-bootstrap-ceremony store4))

  (check-pred "can't split-bran in wrong state"
              (catch #t
                (lambda () ($ ceremony4 'split-bran "x" 1 1) #f)
                (lambda _ #t)))

  (check-pred "can't create-registry before governance"
              (catch #t
                (lambda () ($ ceremony4 'create-registry "r") #f)
                (lambda _ #t))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Signed genesis: with a real group signing key (real-mode KERI backend),
;;; the self-blessing AIC and founder PHCs carry verifiable signatures — the
;;; precondition for require-signature? #t verifiers and foreign end-
;;; verifiability. (Synthetic test mode leaves them unsigned; see suite 1.)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Signed genesis (real group signing key) ──\n")

(define vat-s (spawn-vat))
(with-vat vat-s
  (define store (spawn-acdc-store))
  ;; The governance group AID IS a real KERI identity, so signatures by it
  ;; verify. The backend hands the ceremony the group's signing key.
  (define group     (make-keri-identity (make-bytevector 32 55)))
  (define group-aid (keri-identity-aid group))
  (define backend
    (list (cons 'create-group    (lambda (members threshold) group-aid))
          (cons 'create-registry (lambda (a b) "reg_signed"))
          (cons 'resolve-oobi    (lambda (u) #t))
          (cons 'signing-keypair (keri-identity-keypair group))))
  (define ceremony (spawn-bootstrap-ceremony store #:keri-backend backend))

  ($ ceremony 'add-founder "alice" "E_alice_signed" "http://a/oobi")
  ($ ceremony 'create-governance "signed-fed" 1)
  ($ ceremony 'create-registry "signed-registry")
  ($ ceremony 'issue-founding-credentials)

  (check-pred "self-blessing AIC signature verifies"
              (cred-signature-valid? (authorized-issuer-cred store group-aid group-aid)))
  (let ((phc (phc-for store group-aid "E_alice_signed")))
    (check-pred "founder PHC is signed and verifies"
                (cred-signature-valid? phc))
    (check-pred "signed PHC chains to root under require-signature? #t"
                (phc-chains-to-root? store phc group-aid))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
