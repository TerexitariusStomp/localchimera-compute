;;; test-enrollment-ceremony.scm — k-of-n witness co-signature for PHC issuance
;;;
;;; Covers:
;;;   1. Threshold gating: finalize fails until ≥k attestations land.
;;;   2. Witness signature verification: bad sig is rejected.
;;;   3. Witness must hold a live PHC; non-member rejected.
;;;   4. No double-attestation: the same witness can't sign twice.
;;;   5. Finalized PHC carries witness-edges (NI2I to each witness's PHC).
;;;   6. End-to-end via ^scope.open-enrollment.

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet personhood enrollment) (playnet boot scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules ((playnet keri signify) #:select (ed25519-keypair-public)))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (srfi srfi-1))


(define (fresh-identity seed-byte)
  (make-keri-identity (make-bytevector 32 seed-byte)))


(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Direct ^enrollment-ceremony, k=3 threshold
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Threshold ceremony with 3 witnesses ──\n")

(with-vat vat
  (define eco "E_eco_enroll")
  ;; Three pre-existing members who will witness; one candidate.
  (define alice (fresh-identity 31))
  (define bob   (fresh-identity 32))
  (define carol (fresh-identity 33))
  (define dave  (fresh-identity 34))   ;; the candidate
  (define eve   (fresh-identity 35))   ;; outsider, no PHC

  (define store (spawn-acdc-store))

  ;; Seed three witnesses with PHCs (issued unilaterally — these are founders).
  (for-each
    (lambda (id)
      ($ store 'issue
         (make-personhood-credential eco (keri-identity-aid id) 100)))
    (list alice bob carol))

  (define ceremony
    (spawn-enrollment-ceremony eco
                                (keri-identity-aid dave)
                                "evidence:dave"
                                (keri-identity-aid alice)   ;; sponsor
                                3                            ;; k
                                store))

  (check "ceremony state = collecting"
         ($ ceremony 'status) 'collecting)
  (check "no attestations yet"
         ($ ceremony 'attestation-count) 0)

  ;; Compute the statement-SAID and sign it with each witness.
  (define stmt-said ($ ceremony 'statement-said))
  (define alice-sig (sign-said stmt-said (keri-identity-keypair alice)))
  (define bob-sig   (sign-said stmt-said (keri-identity-keypair bob)))
  (define carol-sig (sign-said stmt-said (keri-identity-keypair carol)))

  ;; Finalize before threshold met → error.
  ($ ceremony 'attest (keri-identity-aid alice) alice-sig)
  (check "1 attestation logged"
         ($ ceremony 'attestation-count) 1)
  (check-pred "finalize before threshold rejects"
              (catch #t
                (lambda () ($ ceremony 'finalize) #f)
                (lambda _ #t)))

  ;; Outsider with no PHC tries to attest → reject.
  (let ((eve-sig (sign-said stmt-said (keri-identity-keypair eve))))
    (check-pred "non-member witness rejected"
                (catch #t
                  (lambda ()
                    ($ ceremony 'attest (keri-identity-aid eve) eve-sig)
                    #f)
                  (lambda _ #t))))

  ;; Bad signature (from a different keypair) → reject.
  (let ((forged (sign-said stmt-said (keri-identity-keypair bob))))
    (check-pred "signature mismatch rejected"
                (catch #t
                  (lambda ()
                    ($ ceremony 'attest (keri-identity-aid carol) forged)
                    #f)
                  (lambda _ #t))))

  ;; Real attestations from bob + carol close the threshold.
  ($ ceremony 'attest (keri-identity-aid bob)   bob-sig)
  ($ ceremony 'attest (keri-identity-aid carol) carol-sig)
  (check "3 attestations logged"
         ($ ceremony 'attestation-count) 3)

  ;; Double-attestation rejected.
  (check-pred "double-attestation rejected"
              (catch #t
                (lambda ()
                  ($ ceremony 'attest (keri-identity-aid alice) alice-sig)
                  #f)
                (lambda _ #t)))

  ;; Finalize → PHC issued.
  (define phc-said ($ ceremony 'finalize))
  (check "ceremony state = finalized"
         ($ ceremony 'status) 'finalized)
  (check-pred "candidate now holds live PHC"
              (holds-live-phc? store eco (keri-identity-aid dave)))

  ;; Verify witness edges.
  (let* ((dave-phc (phc-for store eco (keri-identity-aid dave)))
         (edges    (cred-edges dave-phc)))
    (check "PHC carries 3 witness edges"
           (length edges) 3)
    (check-pred "first edge operator = NI2I"
                (eq? 'NI2I (edge-operator (cdr (car edges)))))
    (check-pred "edge target points at a witness PHC SAID"
                (let ((alice-phc (phc-for store eco (keri-identity-aid alice))))
                  (member (cred-said alice-phc)
                          (map (lambda (e) (edge-target (cdr e))) edges)))))

  ;; Sponsor recorded on PHC.
  (check "sponsor recorded on PHC"
         (cred-claim (phc-for store eco (keri-identity-aid dave))
                     'sponsor-aid)
         (keri-identity-aid alice)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. End-to-end via ^scope.open-enrollment
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. ^scope.open-enrollment full flow ──\n")

(with-vat vat
  (define alice (fresh-identity 41))
  (define bob   (fresh-identity 42))
  (define carol (fresh-identity 43))   ;; candidate

  (define store (spawn-acdc-store))
  (define scope-root (spawn-scope-root "Enroll"))
  (define scope (spawn-scope "Enroll"
                             #:kind 'commune
                             #:scope-aid "E_enroll"
                             #:scope-root-ref scope-root
                             #:acdc-store store))
  (define gov-cap ($ scope 'mint-gov-cap "op"))

  ;; Seed alice + bob as founders.
  ($ scope 'issue-phc gov-cap (keri-identity-aid alice) "ev:alice")
  ($ scope 'issue-phc gov-cap (keri-identity-aid bob)   "ev:bob")

  ;; Open a 2-of-2 enrollment for carol.
  (define ceremony
    ($ scope 'open-enrollment gov-cap
       (keri-identity-aid carol) "ev:carol"
       (keri-identity-aid alice) 2))

  (define stmt ($ ceremony 'statement-said))
  ($ ceremony 'attest (keri-identity-aid alice)
     (sign-said stmt (keri-identity-keypair alice)))
  ($ ceremony 'attest (keri-identity-aid bob)
     (sign-said stmt (keri-identity-keypair bob)))
  ($ ceremony 'finalize)

  (check-pred "carol enrolled via ceremony"
              (holds-live-phc? store "E_enroll" (keri-identity-aid carol)))
  (check "carol's PHC has 2 witness edges"
         (length (cred-edges
                   (phc-for store "E_enroll" (keri-identity-aid carol))))
         2))


;;; ════════════════════════════════════════════════════════════════════════════

;;; ════════════════════════════════════════════════════════════════════════════
;;; Signed + root-anchored enrollment: with the scope's key + blessing, a
;;; witnessed PHC is signed AND structurally rooted, like any other issuance.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Signed + root-anchored witnessed enrollment ──\n")

(with-vat vat
  (define eco     (fresh-identity 41))
  (define eco-aid (keri-identity-aid eco))
  (define spon    (fresh-identity 42))
  (define w1      (fresh-identity 43))
  (define w2      (fresh-identity 44))
  (define cand    (fresh-identity 45))
  (define store   (spawn-acdc-store))
  ;; Self-blessing AIC (root == eco), signed — so own-aic-said finds it.
  ($ store 'issue (make-authorized-issuer-credential
                    eco-aid eco-aid 5 #:signing-keypair (keri-identity-keypair eco)))
  (for-each (lambda (id)
              ($ store 'issue (make-personhood-credential eco-aid (keri-identity-aid id) 100)))
            (list spon w1 w2))
  (define ceremony
    (spawn-enrollment-ceremony eco-aid (keri-identity-aid cand) "evidence:cand"
                               (keri-identity-aid spon) 2 store
                               #:signing-keypair (keri-identity-keypair eco)))
  (define stmt ($ ceremony 'statement-said))
  ($ ceremony 'attest (keri-identity-aid w1) (sign-said stmt (keri-identity-keypair w1)))
  ($ ceremony 'attest (keri-identity-aid w2) (sign-said stmt (keri-identity-keypair w2)))
  ($ ceremony 'finalize)
  (let ((phc (phc-for store eco-aid (keri-identity-aid cand))))
    (check-pred "witnessed PHC is signed by the scope and verifies"
                (cred-signature-valid? phc))
    (check-pred "witnessed PHC carries the issuer-authz root edge"
                (and (phc-issuer-authz-edge phc) #t))
    (check-pred "witnessed PHC also carries the witness edges (2 + authz)"
                (>= (length (cred-edges phc)) 3))
    (check-pred "witnessed PHC chains to root"
                (phc-chains-to-root? store phc eco-aid))))


(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
