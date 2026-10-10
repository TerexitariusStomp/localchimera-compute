;;; test-fp-present-phc.scm — inbound-PHC ingest hardening (FPP portability)
;;;
;;; A person's PHC is a PORTABLE card: `fp-my-phc` hands out the SAD-shaped
;;; wire (d/i/s/a + the issuer's signature) so it can be presented to a
;;; gateway that never replicated the issuing commune's store. `present-phc`
;;; is therefore an untrusted-input boundary and must bind everything it
;;; trusts to what the issuer actually signed.
;;;
;;; The wire carries `d` (the SAID) and the attributes (`a`, incl. the holder
;;; `a.i`) as SEPARATE fields, and a foreign gateway reconstructs the
;;; credential by re-reading those fields. If it trusts the issuer's
;;; signature over `d` without re-deriving `d` from the presented content,
;;; an attacker can graft a validly-signed `d`+signature onto a swapped
;;; holder AID and be recognised as a person the issuer never attested
;;; (the OpenVTC #83/#142 class; ACDC §2.5 — a signature on a SAID only
;;; authenticates the block when the SAID was derived from the block).
;;;
;;; This is the regression harness for that binding. It also pins the
;;; enabling invariant: SAIDs are order-INDEPENDENT, so a legitimate card
;;; survives a JSON round trip (which reorders object keys) yet a tampered
;;; one still fails re-derivation.

;; loading (playnet federation root-lineage) installs the recomposition walk as the root lineage
(use-modules ((playnet federation root-lineage) #:select ()))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness))
(use-modules (playnet voice ballot-store) (playnet credentials membership) (playnet credentials recomposition) (playnet keri acdc) (playnet keri first-person credentials) (playnet governance service) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (playnet voice ballot-store))
(use-modules ((playnet keys exchange) #:select (governance-cred->wire)))
(use-modules (goblins) (goblins vat) (goblins actor-lib methods)
             (goblins utils hashmap)
             (json) (rnrs bytevectors) (srfi srfi-1))

;; Minimal scope-root/account-store mocks (mirrors test-integration.scm) —
;; present-phc only needs the service to hold refs; it queries the acdc-store.
(define (^mock-account-store _bcom gross-by-id total)
  (methods
    ((total-social-svc . _level) total)
    ((citizen-gross cid . _level) (hashmap-ref gross-by-id cid 0))))
(define (^mock-scope-root _bcom account-store-ref ballot-store-ref)
  (methods
    ((account-store) account-store-ref)
    ((ballot-store)  ballot-store-ref)))

(define (fresh-identity seed-byte)
  (make-keri-identity (make-bytevector 32 seed-byte)))

;; Local mirror of service.scm's private `fp-wire->cred` — the ingest
;; transform present-phc applies. Kept here so section 2 can exercise the
;; reconstruction directly; section 3 drives the real present-phc.
(define (fp-wire->cred* w)
  (define (wref k) (let ((p (assoc k w))) (and p (cdr p))))
  (define (s->sym k) (if (string? k) (string->symbol k) k))
  (let* ((a (or (wref "a") '()))
         (claims (let loop ((ps a) (acc '()))
                   (cond ((null? ps) (reverse acc))
                         ((equal? (caar ps) "i") (loop (cdr ps) acc))
                         (else (loop (cdr ps)
                                     (cons (cons (s->sym (caar ps)) (cdar ps)) acc))))))
         (edges (let ((e (wref "e")))
                  (if (pair? e) (map (lambda (p) (cons (s->sym (car p)) (cdr p))) e) '()))))
    (list (cons 'said (wref "d")) (cons 'schema (wref "s")) (cons 'issuer (wref "i"))
          (cons 'holder (let ((p (assoc "i" a))) (and p (cdr p))))
          (cons 'claims claims) (cons 'edges edges)
          (cons 'signature (wref "sig")) (cons 'revoked? #f))))

(define (phc->wire-json cred)
  "Exactly what a holder transmits: `fp-my-phc`'s SAD projection plus the
   issuer signature, serialised to JSON — the shape `present-phc` ingests."
  (scm->json-string
   (append (governance-cred->wire cred)
           (list (cons "sig" (or (cred-signature cred) ""))))))

(define (swap-holder-in-json json-str new-holder)
  "Tamper: rewrite `a.i` (the holder AID) in a PHC wire, leaving `d` and
   the issuer signature untouched — the graft attack."
  (scm->json-string
   (map (lambda (p)
          (if (equal? (car p) "a")
              (cons "a" (map (lambda (q)
                               (if (equal? (car q) "i") (cons "i" new-holder) q))
                             (cdr p)))
              p))
        (json-string->scm json-str))))

(define vat (spawn-vat))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. SAID is order-independent AND tamper-evident (the enabling invariant)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. SAID: order-independent, tamper-evident ──\n")

(let* ((claims-a '((ecosystem-aid . "E_eco") (enrolled-at . 100) (active . #t)))
       (claims-b '((active . #t) (enrolled-at . 100) (ecosystem-aid . "E_eco")))) ; reordered
  (check "reordered claims → same SAID (survives serialization reorder)"
         (compute-said "E_eco" "E_alice" 'phc claims-a)
         (compute-said "E_eco" "E_alice" 'phc claims-b))
  (check-pred "swapped holder → different SAID"
              (not (equal? (compute-said "E_eco" "E_alice" 'phc claims-a)
                           (compute-said "E_eco" "E_mallory" 'phc claims-a))))
  (check-pred "swapped issuer → different SAID"
              (not (equal? (compute-said "E_eco" "E_alice" 'phc claims-a)
                           (compute-said "E_other" "E_alice" 'phc claims-a))))
  (check-pred "changed claim value → different SAID"
              (not (equal? (compute-said "E_eco" "E_alice" 'phc claims-a)
                           (compute-said "E_eco" "E_alice" 'phc
                                         '((ecosystem-aid . "E_eco") (enrolled-at . 100)
                                           (active . #f)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. A legitimate signed PHC survives the JSON wire round trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Legit PHC: consistent + signature verifies after round trip ──\n")

(with-vat vat
  (define foreign-eco (fresh-identity 200))     ; a trusted federated commune
  (define alice       (fresh-identity 11))
  (define eco-aid     (keri-identity-aid foreign-eco))
  (define alice-aid   (keri-identity-aid alice))
  ;; Foreign commune issues alice a SIGNED PHC (issuer signs the SAID).
  (define phc (make-personhood-credential
                eco-aid alice-aid 100
                #:signing-keypair (keri-identity-keypair foreign-eco)))

  (check-pred "in-store PHC is digest-consistent" (cred-said-consistent? phc))
  (check-pred "in-store PHC signature verifies"   (cred-signature-valid? phc))

  ;; Round-trip through JSON exactly as present-phc receives it.
  (let* ((wire (phc->wire-json phc))
         (recon (fp-wire->cred* (json-string->scm wire))))
    (check-pred "reconstructed PHC still digest-consistent (order-independent)"
                (cred-said-consistent? recon))
    (check-pred "reconstructed PHC signature still verifies"
                (cred-signature-valid? recon))
    (check "holder preserved" (cred-holder recon) alice-aid)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. present-phc end-to-end: legit accepted, graft rejected
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. present-phc: accept legit, reject holder-graft ──\n")

(with-vat vat
  (define foreign-eco (fresh-identity 201))
  (define alice       (fresh-identity 12))
  (define mallory     (fresh-identity 13))
  (define eco-aid     (keri-identity-aid foreign-eco))
  (define alice-aid   (keri-identity-aid alice))
  (define mallory-aid (keri-identity-aid mallory))

  (define bs    (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root
                       (spawn ^mock-account-store (hashmap) 1) bs))
  (define store (spawn-acdc-store))
  (define svc   (spawn-governance-service (list scope) bs #:acdc-store store))
  ($ svc 'set-fp-trusted-issuers! (list eco-aid))

  (define phc (make-personhood-credential
                eco-aid alice-aid 100
                #:signing-keypair (keri-identity-keypair foreign-eco)))
  (define wire (phc->wire-json phc))

  ;; (a) Legit presentation by the true holder → accepted, alice recognised.
  (let ((r ($ svc 'present-phc alice-aid wire)))
    (check-pred "legit present-phc → ok" (and (pair? r) (eq? (car r) 'ok))))
  (check-pred "alice is now a recognised person"
              (let ((s ($ svc 'fp-status alice-aid "scope")))
                (and (eq? (car s) 'ok) (assoc-ref (cdr s) 'person))))

  ;; (b) THE ATTACK: mallory grafts alice's signed d+sig onto her own AID.
  (let* ((forged (swap-holder-in-json wire mallory-aid))
         (r ($ svc 'present-phc mallory-aid forged)))
    (check-pred "grafted present-phc → error" (and (pair? r) (eq? (car r) 'error)))
    (check "error names the digest binding, not a downstream check"
           (cdr r) "PHC digest does not commit to its contents"))
  (check-pred "mallory is NOT recognised as a person"
              (let ((s ($ svc 'fp-status mallory-aid "scope")))
                (not (assoc-ref (cdr s) 'person))))

  ;; (c) A PHC from an UNTRUSTED commune is rejected even if internally valid.
  (let* ((rogue     (fresh-identity 202))
         (rogue-aid (keri-identity-aid rogue))
         (bob       (fresh-identity 14))
         (bob-aid   (keri-identity-aid bob))
         (rogue-phc (make-personhood-credential
                      rogue-aid bob-aid 100
                      #:signing-keypair (keri-identity-keypair rogue)))
         (r ($ svc 'present-phc bob-aid (phc->wire-json rogue-phc))))
    (check "untrusted issuer rejected" (cdr r) "issuer is not a federated commune"))

  ;; (d) An EXPIRED PHC is refused at ingest (liveness gate).
  (let* ((expired (make-personhood-credential
                    eco-aid alice-aid 100 #:expires-at 50   ; expired before now
                    #:signing-keypair (keri-identity-keypair foreign-eco)))
         (carol     (fresh-identity 15))
         (carol-aid (keri-identity-aid carol))
         (expired2 (make-personhood-credential
                     eco-aid carol-aid 100 #:expires-at 50
                     #:signing-keypair (keri-identity-keypair foreign-eco)))
         (r ($ svc 'present-phc carol-aid (phc->wire-json expired2))))
    (check "expired PHC refused at ingest" (cdr r) "presented PHC is not live")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Root trust registry: issuer trust DERIVES from chaining to root
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Root registry: chains-to-root replaces the whitelist ──\n")

(with-vat vat
  (define uc-root  (fresh-identity 250))     ; the Universal Commune = root
  (define eco      (fresh-identity 251))     ; an ecosystem root blesses
  (define rogue    (fresh-identity 252))     ; an ecosystem root never blessed
  (define alice    (fresh-identity 16))
  (define bob      (fresh-identity 17))
  (define root-aid (keri-identity-aid uc-root))
  (define eco-aid  (keri-identity-aid eco))
  (define rogue-aid (keri-identity-aid rogue))
  (define alice-aid (keri-identity-aid alice))
  (define bob-aid   (keri-identity-aid bob))

  (define bs    (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root
                       (spawn ^mock-account-store (hashmap) 1) bs))
  (define store (spawn-acdc-store))
  (define svc   (spawn-governance-service (list scope) bs #:acdc-store store))
  ;; NOTE: no set-fp-trusted-issuers! — trust must come from the root chain.
  ($ svc 'set-fp-root! root-aid)

  ;; Root blesses `eco` as an authorized PHC issuer (signed by root).
  (define aic (make-authorized-issuer-credential
                root-aid eco-aid 10
                #:signing-keypair (keri-identity-keypair uc-root)))
  ($ store 'issue aic)

  (check-pred "authorized-issuer credential is signed + verifies"
              (cred-signature-valid? aic))
  (check-pred "blessed ecosystem chains to root"
              (issuer-chains-to-root? store root-aid eco-aid))
  (check-pred "unblessed ecosystem does NOT chain to root"
              (not (issuer-chains-to-root? store root-aid rogue-aid)))
  (check-pred "root chains to itself (its own origin)"
              (issuer-chains-to-root? store root-aid root-aid))

  ;; A PHC from the blessed ecosystem is honoured with NO whitelist entry.
  (let* ((phc (make-personhood-credential
                eco-aid alice-aid 100
                #:signing-keypair (keri-identity-keypair eco)))
         (r ($ svc 'present-phc alice-aid (phc->wire-json phc))))
    (check-pred "PHC from root-blessed ecosystem accepted (no whitelist)"
                (and (pair? r) (eq? (car r) 'ok))))

  ;; A PHC from an unblessed ecosystem is refused — no chain, no whitelist.
  (let* ((phc (make-personhood-credential
                rogue-aid bob-aid 100
                #:signing-keypair (keri-identity-keypair rogue)))
         (r ($ svc 'present-phc bob-aid (phc->wire-json phc))))
    (check "unblessed ecosystem rejected" (cdr r) "issuer is not a federated commune"))

  ;; Root retires the ecosystem's authority → its PHCs stop being honoured.
  ($ store 'revoke (cred-said aic))
  (check-pred "after root revokes the blessing, ecosystem no longer chains"
              (not (issuer-chains-to-root? store root-aid eco-aid)))
  (let* ((carol     (fresh-identity 18))
         (carol-aid (keri-identity-aid carol))
         (phc (make-personhood-credential
                eco-aid carol-aid 100
                #:signing-keypair (keri-identity-keypair eco)))
         (r ($ svc 'present-phc carol-aid (phc->wire-json phc))))
    (check "PHC refused once blessing revoked" (cdr r) "issuer is not a federated commune")))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Structural root chain: a PHC walks its own edge to root (end-verifiable)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Structural: PHC → issuer-authz edge → AIC → root ──\n")

(with-vat vat
  (define uc-root  (fresh-identity 240))
  (define eco      (fresh-identity 241))
  (define alice    (fresh-identity 19))
  (define root-aid (keri-identity-aid uc-root))
  (define eco-aid  (keri-identity-aid eco))
  (define alice-aid (keri-identity-aid alice))
  (define store (spawn-acdc-store))

  ;; Root blesses eco (signed), eco issues alice a PHC anchored to that AIC.
  (define aic (make-authorized-issuer-credential
                root-aid eco-aid 10
                #:signing-keypair (keri-identity-keypair uc-root)))
  (define aic-said ($ store 'issue aic))
  (define phc (make-personhood-credential
                eco-aid alice-aid 100
                #:issuer-authz-said aic-said
                #:signing-keypair (keri-identity-keypair eco)))

  (check-pred "PHC carries an issuer-authz edge" (phc-issuer-authz-edge phc))
  (check-pred "PHC structurally chains to root (signature-checked)"
              (phc-chains-to-root? store phc root-aid))
  (check-pred "PHC does NOT chain to an unrelated root"
              (not (phc-chains-to-root? store phc (keri-identity-aid (fresh-identity 99)))))

  ;; Graft the edge onto a foreign holder: I2I still pins issuer==AIC.holder,
  ;; so a PHC minted by a DIFFERENT (unblessed) issuer can't borrow eco's AIC.
  (let ((rogue (fresh-identity 242)))
    (define rogue-phc (make-personhood-credential
                        (keri-identity-aid rogue) alice-aid 100
                        #:issuer-authz-said aic-said         ; points at eco's blessing
                        #:signing-keypair (keri-identity-keypair rogue)))
    (check-pred "unblessed issuer borrowing eco's AIC edge is rejected (I2I)"
                (not (phc-chains-to-root? store rogue-phc root-aid))))

  ;; Schema confusion: point the edge at some OTHER credential root issued
  ;; the ecosystem (here a membership cred, issuer==root, holder==eco). I2I
  ;; holds, but it is not an authorized-issuer credential → must be rejected.
  (let* ((decoy (make-membership-credential root-aid eco-aid "eco" 5))
         (decoy-said ($ store 'issue decoy))
         (confused (make-personhood-credential
                     eco-aid alice-aid 100
                     #:issuer-authz-said decoy-said
                     #:signing-keypair (keri-identity-keypair eco))))
    (check-pred "edge pointing at a non-AIC credential is rejected (schema gate)"
                (not (phc-chains-to-root? store confused root-aid #:require-signature? #f)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Root-anchored trust triangle (+ multi-root cross-recognition)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Root-anchored trust triangle ──\n")

(with-vat vat
  (define uc-root   (fresh-identity 243))
  (define other-root (fresh-identity 245))     ; a different, unrecognized root
  (define eco       (fresh-identity 244))
  (define alice     (fresh-identity 32))
  (define bob       (fresh-identity 33))
  (define root-aid  (keri-identity-aid uc-root))
  (define other-aid (keri-identity-aid other-root))
  (define eco-aid   (keri-identity-aid eco))
  (define a-aid     (keri-identity-aid alice))
  (define b-aid     (keri-identity-aid bob))
  (define store (spawn-acdc-store))

  ;; Root blesses eco; eco enrolls alice + bob; they mutually vouch.
  (define aic (make-authorized-issuer-credential
                root-aid eco-aid 10 #:signing-keypair (keri-identity-keypair uc-root)))
  (define aic-said ($ store 'issue aic))
  (define phc-a (make-personhood-credential
                  eco-aid a-aid 100 #:issuer-authz-said aic-said
                  #:signing-keypair (keri-identity-keypair eco)))
  (define phc-b (make-personhood-credential
                  eco-aid b-aid 100 #:issuer-authz-said aic-said
                  #:signing-keypair (keri-identity-keypair eco)))
  ($ store 'issue phc-a)
  ($ store 'issue phc-b)
  ($ store 'issue (make-relationship-credential
                    a-aid b-aid 'trust (cred-said phc-a) 101
                    #:signing-keypair (keri-identity-keypair alice)))
  ($ store 'issue (make-relationship-credential
                    b-aid a-aid 'trust (cred-said phc-b) 102
                    #:signing-keypair (keri-identity-keypair bob)))

  (check-pred "plain triangle holds (no root check)"
              (trust-triangle-holds? store a-aid b-aid eco-aid))
  (check-pred "root-anchored triangle holds under the blessing root"
              (trust-triangle-holds? store a-aid b-aid eco-aid #:root root-aid))
  (check-pred "root-anchored triangle FAILS under an unrecognized root"
              (not (trust-triangle-holds? store a-aid b-aid eco-aid #:root other-aid)))

  ;; Multi-root cross-recognition: a recognized-root SET; chaining to one suffices.
  (check-pred "triangle holds when eco chains to ANY root in the set"
              (trust-triangle-holds? store a-aid b-aid eco-aid
                                     #:root (list other-aid root-aid)))
  (check-pred "triangle fails when eco chains to NO root in the set"
              (not (trust-triangle-holds? store a-aid b-aid eco-aid
                                          #:root (list other-aid))))

  ;; Root retires the ecosystem → the relationship leaves the trust domain,
  ;; even though the PHCs and VRCs are all still individually valid.
  ($ store 'revoke aic-said)
  (check-pred "after root revokes the blessing, root-anchored triangle collapses"
              (not (trust-triangle-holds? store a-aid b-aid eco-aid #:root root-aid)))
  (check-pred "but the plain (unrooted) triangle still holds"
              (trust-triangle-holds? store a-aid b-aid eco-aid)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. The root recomposes: trust survives the root's own merge / split
;;;    (the root is a scope; merge/split mint a NEW AID — anchoring to a fixed
;;;     root AID would detach the graph. We anchor to the ratified lineage.)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Root recomposition: graph stays anchored ──\n")

(with-vat vat
  (define r1    (fresh-identity 246))          ; the original root
  (define eco   (fresh-identity 247))
  (define alice (fresh-identity 34))
  (define r1-aid  (keri-identity-aid r1))
  (define eco-aid (keri-identity-aid eco))
  (define a-aid   (keri-identity-aid alice))
  (define store (spawn-acdc-store))

  ;; R1 blesses eco; eco enrolls alice with the structural edge.
  (define aic (make-authorized-issuer-credential
                r1-aid eco-aid 10 #:signing-keypair (keri-identity-keypair r1)))
  (define aic-said ($ store 'issue aic))
  (define phc (make-personhood-credential
                eco-aid a-aid 100 #:issuer-authz-said aic-said
                #:signing-keypair (keri-identity-keypair eco)))
  ($ store 'issue phc)

  (check-pred "before recomposition: eco chains to R1"
              (issuer-chains-to-root? store r1-aid eco-aid))
  (check-pred "before recomposition: PHC chains to R1 (structural)"
              (phc-chains-to-root? store phc r1-aid))

  ;; R1 merges with R2 into a NEW root AID R3 (ratified scope-merger ACDC).
  (define r2-aid "E_other_root_R2")
  (define r3-aid "E_merged_root_R3")
  ($ store 'issue (make-scope-merger-credential
                    r1-aid r2-aid r3-aid 'universal-commune 200))

  (check-pred "R3's lineage closure reaches back to R1"
              (and (member r1-aid (root-lineage-closure store r3-aid)) #t))
  (check-pred "after root MERGE: eco still chains to the new root R3"
              (issuer-chains-to-root? store r3-aid eco-aid))
  (check-pred "after root MERGE: PHC still chains to R3 (edge → R1's AIC, R1 ∈ lineage)"
              (phc-chains-to-root? store phc r3-aid))
  (check-pred "a root the graph never grew from does NOT anchor it"
              (not (issuer-chains-to-root? store "E_unrelated_root" eco-aid)))

  ;; R3 splits into R4 and R5 (ratified scope-split). The pre-merge blessing
  ;; (by R1) must anchor under EITHER successor — a split multiplies roots.
  (define r4-aid "E_split_root_R4")
  (define r5-aid "E_split_root_R5")
  ($ store 'issue (make-scope-split-credential
                    r3-aid (list r4-aid r5-aid) 'federation 300))

  (check-pred "R4's closure reaches transitively through R3 to R1"
              (and (member r1-aid (root-lineage-closure store r4-aid)) #t))
  (check-pred "after root SPLIT: eco chains to successor R4"
              (issuer-chains-to-root? store r4-aid eco-aid))
  (check-pred "after root SPLIT: eco chains to successor R5 too (both inherit)"
              (issuer-chains-to-root? store r5-aid eco-aid)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Strict-root mode: drop the whitelist bypass once the chain is live
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. Strict-root mode retires the whitelist ──\n")

(with-vat vat
  (define uc-root (fresh-identity 248))
  (define blessed (fresh-identity 249))     ; chains to root
  (define listed  (fresh-identity 250))     ; only on the flat whitelist
  (define alice   (fresh-identity 35))
  (define bob     (fresh-identity 36))
  (define root-aid    (keri-identity-aid uc-root))
  (define blessed-aid (keri-identity-aid blessed))
  (define listed-aid  (keri-identity-aid listed))
  (define a-aid (keri-identity-aid alice))
  (define b-aid (keri-identity-aid bob))

  (define bs    (spawn-ballot-store))
  (define scope (spawn ^mock-scope-root
                       (spawn ^mock-account-store (hashmap) 1) bs))
  (define store (spawn-acdc-store))
  (define svc   (spawn-governance-service (list scope) bs #:acdc-store store))
  ($ svc 'set-fp-root! root-aid)
  ($ svc 'set-fp-trusted-issuers! (list listed-aid))

  ;; Root blesses `blessed`; `listed` is only on the whitelist.
  (define aic-said
    ($ store 'issue (make-authorized-issuer-credential
                      root-aid blessed-aid 10
                      #:signing-keypair (keri-identity-keypair uc-root))))

  (define blessed-phc (make-personhood-credential
                        blessed-aid a-aid 100 #:issuer-authz-said aic-said
                        #:signing-keypair (keri-identity-keypair blessed)))
  (define listed-phc (make-personhood-credential
                       listed-aid b-aid 100
                       #:signing-keypair (keri-identity-keypair listed)))

  ;; Non-strict (default): BOTH are honoured — chain OR whitelist.
  (check-pred "non-strict: root-blessed issuer accepted"
              (eq? 'ok (car ($ svc 'present-phc a-aid (phc->wire-json blessed-phc)))))
  (check-pred "non-strict: whitelisted issuer accepted (fallback)"
              (eq? 'ok (car ($ svc 'present-phc b-aid (phc->wire-json listed-phc)))))

  ;; Flip strict-root: the whitelist bypass is dropped.
  ($ svc 'set-fp-strict-root! #t)
  (check-pred "strict: root-blessed issuer STILL accepted"
              (let ((carol (fresh-identity 37)))
                (eq? 'ok (car ($ svc 'present-phc (keri-identity-aid carol)
                                    (phc->wire-json
                                     (make-personhood-credential
                                       blessed-aid (keri-identity-aid carol) 100
                                       #:issuer-authz-said aic-said
                                       #:signing-keypair (keri-identity-keypair blessed))))))))
  (check "strict: whitelist-only issuer now REJECTED"
         (let ((dave (fresh-identity 38)))
           (cdr ($ svc 'present-phc (keri-identity-aid dave)
                     (phc->wire-json
                      (make-personhood-credential
                        listed-aid (keri-identity-aid dave) 100
                        #:signing-keypair (keri-identity-keypair listed))))))
         "issuer is not a federated commune"))


(newline)
(test-summary!)
