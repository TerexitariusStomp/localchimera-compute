;;; test-client-signing.scm — citizen client-side signing + the unified verifier
;;;
;;; The governance write surface is client-signed: a citizen's key never leaves
;;; their client, so the server hands out a credential PREIMAGE, the client
;;; re-derives the SAID (via the shared compute-said) and signs it, and the
;;; server verifies the signature against the caller's self-certifying AID
;;; before issuing. This suite locks in that round-trip for every shape —
;;; stance, liquid delegation, mandated delegation — plus the unified verifier
;;; that both the live tally and boot-time recovery depend on.
;;;
;;; Until now this whole family lived only in throwaway scratch tests. The
;;; security-critical properties it pins:
;;;   • the issued ACDC carries the CITIZEN's signature, not the scope's;
;;;   • a wrong-key / forged signature is rejected;
;;;   • a self-certifying AID needs NO registry entry — which is exactly what
;;;     lets boot-time recovery (empty sealer registry, zero clients online)
;;;     reconstruct castable ballots. See test-recovery.scm for the replay side.

(use-modules (playnet voice ballot) (playnet credentials commitments) (playnet credentials delegation) (playnet credentials voting) (playnet keri acdc) (playnet voice delegation-map) (playnet federation rebuild) (playnet boot scope) (playnet governance service) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet scope root) (srfi srfi-1) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said verify-said-signature))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (preimage-fields pre)
  "Turn a credential-preimage-fields alist into an accessor (k -> value)."
  (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))

(define (said-of ar)
  "Re-derive the SAID from a preimage accessor, exactly as a client would."
  (compute-said (ar 'issuer) (ar 'holder) (ar 'schema)
                (ar 'claims) (or (ar 'edges) '())))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 1. Stance: client-signed cast round-trip ──\n")

(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (skp (keri-identity-keypair sid))
         (scope-aid (keri-identity-aid sid))
         (cid (make-keri-identity)) (ckp (keri-identity-keypair cid))
         (citizen (keri-identity-aid cid))
         (root (spawn-scope-root "Vote")) (store (spawn-acdc-store))
         (scope (spawn-scope "Vote" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid #:keypair skp #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope)))
    ($ ($ root 'account-store) 'add-contribution citizen 10)
    ($ svc 'open citizen 'ballot 'policy "p-1" "Test" 'federation)
    (let* ((ar  (preimage-fields (cadr ($ svc 'stance-preimage citizen "p-1" 'yes))))
           (claims (ar 'claims))
           (ts  (let ((p (assq 'timestamp claims))) (and p (cdr p))))
           ;; the blinding nonce is server-issued and SAID-committed, so it
           ;; must be echoed back exactly like the timestamp
           (u   (let ((p (assq 'u claims))) (and p (cdr p))))
           (said (said-of ar))
           (sig  (sign-said said ckp)))
      (check "preimage carries a blinding nonce (u)"
             (and (string? u) (= 24 (string-length u))))
      (check "preimage issuer = caller (session-bound)" (equal? (ar 'issuer) citizen))
      (check "preimage holder = recording scope" (equal? (ar 'holder) scope-aid))
      (check "cast-signed accepted" (eq? 'ok ($ svc 'cast-signed citizen "p-1" 'yes ts sig u)))
      ;; the nonce is part of the signed SAID, so a call that omits it is
      ;; rejected EXPLICITLY rather than rebuilt into an unverifiable cred
      (check "cast-signed WITHOUT the echoed nonce is rejected"
             (let ((r ($ svc 'cast-signed citizen "p-1" 'yes ts sig)))
               (and (pair? r) (eq? 'error (car r))
                    (string-contains (cadr r) "nonce"))))
      (let ((st (find (lambda (c) (equal? (cred-schema c) *schema-playnet-stance*))
                      ($ store 'all))))
        (check "stance ACDC issued" (and st #t))
        (check "client SAID == issued SAID" (equal? (cred-said st) said))
        (check "issuer = the CITIZEN" (equal? (cred-issuer st) citizen))
        (check "carries the CITIZEN's signature"
               (and (cred-signature st)
                    (verify-said-signature (cred-said st) (cred-signature st) citizen)))
        (check "does NOT verify as the scope (proves citizen-signed, not scope-signed)"
               (not (verify-said-signature (cred-said st) (cred-signature st) scope-aid))))
      (let* ((eve (make-keri-identity))
             (r ($ svc 'cast-signed citizen "p-1" 'yes ts
                    (sign-said said (keri-identity-keypair eve)) u)))
        (check "wrong-key signature REJECTED" (and (pair? r) (eq? 'error (car r))))))))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 2. Liquid delegation: client-signed round-trip ──\n")

(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (scope-aid (keri-identity-aid sid))
         (alice (make-keri-identity)) (alice-kp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice))
         (bob "Ebob000000000000000000000000000000000000000")
         (root (spawn-scope-root "D")) (store (spawn-acdc-store))
         (scope (spawn-scope "D" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid
                             #:keypair (keri-identity-keypair sid) #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope)))
    (let* ((ar (preimage-fields (cadr ($ svc 'delegation-preimage alice-aid bob 0.6))))
           (said (said-of ar))
           (sig  (sign-said said alice-kp)))
      (check "preimage issuer = delegator" (equal? (ar 'issuer) alice-aid))
      (check "preimage holder = delegate"  (equal? (ar 'holder) bob))
      (check "set-delegation-signed accepted"
             (eq? 'ok ($ svc 'set-delegation-signed alice-aid bob 0.6 sig)))
      (let ((dc (find (lambda (c) (equal? (cred-schema c) *schema-playnet-delegation*))
                      ($ store 'all))))
        (check "delegation ACDC citizen-issued" (equal? (cred-issuer dc) alice-aid))
        (check "carries the delegator's signature"
               (and (cred-signature dc)
                    (verify-said-signature (cred-said dc) (cred-signature dc) alice-aid))))
      (let* ((eve (make-keri-identity))
             (r ($ svc 'set-delegation-signed alice-aid bob 0.6
                    (sign-said said (keri-identity-keypair eve)))))
        (check "wrong-key delegation signature REJECTED" (and (pair? r) (eq? 'error (car r)))))
      (let* ((dm2 (recover-delegation-map alice-aid store))
             (e   (hashmap-ref ($ dm2 'federation-default) bob #f)))
        (check "signed delegation recovers by issuer index"
               (and e (= 0.6 (entry-fraction e))))))))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 3. Mandated delegation: client-signed, mandate as a spec (not a closure) ──\n")

(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (scope-aid (keri-identity-aid sid))
         (alice (make-keri-identity)) (alice-kp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice))
         (bob "Ebob000000000000000000000000000000000000000")
         (spec '(equal-position yes))
         (root (spawn-scope-root "D")) (store (spawn-acdc-store))
         (scope (spawn-scope "D" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid
                             #:keypair (keri-identity-keypair sid) #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope)))
    (let* ((ar (preimage-fields
                (cadr ($ svc 'delegation-mandated-preimage alice-aid bob 0.6 spec))))
           (said (said-of ar))
           (sig  (sign-said said alice-kp)))
      (check "preimage claims carry the mandate SPEC (data, not a closure)"
             (equal? spec (assq-ref (ar 'claims) 'mandate)))
      (check "set-delegation-mandated-signed accepted"
             (eq? 'ok ($ svc 'set-delegation-mandated-signed alice-aid bob 0.6 spec sig)))
      (let ((dc (find (lambda (c) (equal? (cred-schema c) *schema-playnet-delegation*))
                      ($ store 'all))))
        (check "ACDC carries the mandate spec"
               (equal? spec (assq-ref (cred-claims dc) 'mandate)))
        (check "citizen-signed" (and (cred-signature dc)
                                      (verify-said-signature (cred-said dc)
                                                             (cred-signature dc) alice-aid))))
      (let* ((eve (make-keri-identity))
             (r ($ svc 'set-delegation-mandated-signed alice-aid bob 0.6 spec
                    (sign-said said (keri-identity-keypair eve)))))
        (check "wrong-key mandated signature REJECTED" (and (pair? r) (eq? 'error (car r)))))
      (let ((r ($ svc 'set-delegation-mandated-signed alice-aid bob 0.6
                   '(nonsense-directive foo) sig)))
        (check "unrecognized mandate spec REJECTED" (and (pair? r) (eq? 'error (car r)))))
      ;; recovery recompiles the predicate from the spec in the ACDC
      (let* ((dm2 (recover-delegation-map alice-aid store))
             (e   (hashmap-ref ($ dm2 'federation-default) bob #f)))
        (check "recovered mandated delegation recompiles its predicate"
               (and e (procedure? (entry-mandate e))))))))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 4. Unified verifier: self-certifying AID needs no registry (server-only restore) ──\n")

(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (scope-aid (keri-identity-aid sid))
         (opener (make-keri-identity)) (opener-aid (keri-identity-aid opener))
         ;; `late` is absent from the ballot's frozen open-time registry — the
         ;; situation at every boot: no client has reconnected, registry empty.
         (late (make-keri-identity)) (late-kp (keri-identity-keypair late))
         (late-aid (keri-identity-aid late))
         (root (spawn-scope-root "V")) (store (spawn-acdc-store))
         (scope (spawn-scope "V" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid
                             #:keypair (keri-identity-keypair sid) #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope)))
    ($ ($ root 'account-store) 'add-contribution opener-aid 10)
    ($ ($ root 'account-store) 'add-contribution late-aid 10)
    ($ svc 'open opener-aid 'ballot 'policy "p-1" "Test" 'federation)
    (check "legacy sealer cast by an unregistered citizen is rejected"
           (let ((r ($ svc 'cast late-aid "p-1" 'yes)))
             (and (pair? r) (eq? 'error (car r)))))
    (let* ((ar (preimage-fields (cadr ($ svc 'stance-preimage late-aid "p-1" 'yes))))
           (claims (ar 'claims))
           (ts  (let ((p (assq 'timestamp claims))) (and p (cdr p))))
           (u   (let ((p (assq 'u claims))) (and p (cdr p))))
           (said (said-of ar))
           (sig  (sign-said said late-kp)))
      (check "KERI-signed cast by a citizen ABSENT from the frozen registry SUCCEEDS"
             (eq? 'ok ($ svc 'cast-signed late-aid "p-1" 'yes ts sig u)))
      (check "their stance ACDC exists and is citizen-signed"
             (let ((st (find (lambda (c)
                               (and (equal? (cred-schema c) *schema-playnet-stance*)
                                    (equal? (cred-issuer c) late-aid)))
                             ($ store 'all))))
               (and st (cred-signature st) #t))))))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 5. make-citizen-verifier — direct unit tests ──\n")

;; The verifier is a pure function of (citizen-id, cleartext, auth-proof). Test
;; both branches directly, including the invariant that the KERI branch is
;; blind to the registry — the property boot-time recovery leans on.
(with-vat (spawn-vat)
  (let* ((alice (make-keri-identity)) (akp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice))
         (eve (make-keri-identity))
         ;; a payload SAID to sign — any 44-char qb64-ish string the citizen commits to
         (said "EJ7xq8nQ9wKQv0m3n0aBcDeFgHiJkLmNoPqRsTuVwXyZ")
         (good (sign-said said akp))
         (bad  (sign-said said (keri-identity-keypair eve)))
         (empty-registry (hashmap))
         (verify (make-citizen-verifier empty-registry)))
    (check "KERI branch: valid (said . sig) verifies against the AID"
           (eq? #t (verify alice-aid #f (cons said good))))
    (check "KERI branch: works with an EMPTY registry (no entry needed — server-only-restore)"
           (eq? #t (verify alice-aid #f (cons said good))))
    (check "KERI branch: wrong-key signature raises"
           (catch #t (lambda () (verify alice-aid #f (cons said bad)) #f)
                  (lambda _ #t)))
    (check "KERI branch: signature over a DIFFERENT said raises"
           (catch #t
             (lambda () (verify alice-aid #f
                                (cons "EdifferentXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" good))
                     #f)
             (lambda _ #t)))
    (check "sealer branch: unknown citizen (empty registry, non-KERI proof) raises"
           (catch #t (lambda () (verify alice-aid #f 'some-sealed-blob) #f)
                  (lambda _ #t)))))


;;; ════════════════════════════════════════════════════════════════════════
(display "\n── 6. Mandate ENFORCED at tally through the signed path (end-to-end) ──\n")

;; A mandate set via set-delegation-mandated-signed must gate the vote exactly
;; like the in-vat closure path (test-ballot §14–18): the delegator's voice
;; flows to the delegate only when the delegate's stance satisfies the mandate.
;; This drives the real service tally — open / cast / get-result — so it proves
;; the whole chain: client signature → compiled predicate → live delegation-map
;; → tally resolution.

(define (sign-mandated-delegation svc citizen-aid citizen-kp delegate fraction spec)
  "Client-sign a mandated delegation through the service. Returns the 'ok/'error."
  (let* ((ar  (preimage-fields
               (cadr ($ svc 'delegation-mandated-preimage citizen-aid delegate fraction spec))))
         (sig (sign-said (said-of ar) citizen-kp)))
    ($ svc 'set-delegation-mandated-signed citizen-aid delegate fraction spec sig)))

(define (cast-signed-stance svc citizen-aid citizen-kp pid position)
  "Client-sign a stance and cast it via the KERI path (no registry needed)."
  (let* ((ar (preimage-fields (cadr ($ svc 'stance-preimage citizen-aid pid position))))
         (ts (let ((p (assq 'timestamp (ar 'claims)))) (and p (cdr p))))
         (u  (let ((p (assq 'u (ar 'claims)))) (and p (cdr p))))
         (sig (sign-said (said-of ar) citizen-kp)))
    ($ svc 'cast-signed citizen-aid pid position ts sig u)))

(define (yes-weight svc pid)
  (hashmap-ref (assoc-ref (cdr ($ svc 'get-result pid)) 'tally) 'yes 0))
(define (no-weight svc pid)
  (hashmap-ref (assoc-ref (cdr ($ svc 'get-result pid)) 'tally) 'no 0))
(define (abstain-weight svc pid)
  (assoc-ref (cdr ($ svc 'get-result pid)) 'abstain))

;; Scenario A — delegate COMPLIES: alice's mandated voice flows to bob.
(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (scope-aid (keri-identity-aid sid))
         (alice (make-keri-identity)) (alice-kp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice))
         (bob (make-keri-identity)) (bob-aid (keri-identity-aid bob))
         (carol-aid "Ecarol0000000000000000000000000000000000000")  ;; governor
         (root (spawn-scope-root "M")) (store (spawn-acdc-store))
         (scope (spawn-scope "M" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid
                             #:keypair (keri-identity-keypair sid) #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope
                                        #:governor? (lambda (a) (equal? a carol-aid)))))
    ($ ($ root 'account-store) 'add-contribution alice-aid 10)
    ($ ($ root 'account-store) 'add-contribution bob-aid 20)
    (check "signed mandated delegation (alice→bob, must vote yes) accepted"
           (eq? 'ok (sign-mandated-delegation svc alice-aid alice-kp bob-aid 1 '(equal-position yes))))
    ;; Make bob known to the service so his base voice (20) is in the open-time
    ;; snapshot — voice = labour captured at open, and the snapshot only holds
    ;; citizens already spawned (test-integration §1 does the same). Alice is
    ;; already spawned via her delegation above.
    ($ svc 'delegation-map bob-aid)
    ($ svc 'open carol-aid 'ballot 'policy "p-A" "comply" 'federation)
    (check "bob's signed compliant cast accepted"
           (eq? 'ok (cast-signed-stance svc bob-aid (keri-identity-keypair bob) "p-A" 'yes)))
    ;; Mandate satisfied → alice's 10 flows to bob's 'yes. Full franchise (30)
    ;; on yes, nothing held. (Mirrors test-ballot §14, now via the signed path.)
    (check "delegate complies: full franchise on yes (alice 10 + bob 20 = all)"
           (= 1 (yes-weight svc "p-A")))
    (check "delegate complies: nothing on no" (= 0 (no-weight svc "p-A")))
    (check "delegate complies: nothing abstained" (= 0 (abstain-weight svc "p-A")))))

;; Scenario B — delegate DEVIATES: alice's mandated voice is held, NOT flowed.
(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (scope-aid (keri-identity-aid sid))
         (alice (make-keri-identity)) (alice-kp (keri-identity-keypair alice))
         (alice-aid (keri-identity-aid alice))
         (bob (make-keri-identity)) (bob-aid (keri-identity-aid bob))
         (carol-aid "Ecarol0000000000000000000000000000000000000")
         (root (spawn-scope-root "M")) (store (spawn-acdc-store))
         (scope (spawn-scope "M" #:kind 'commune #:scope-root-ref root
                             #:scope-aid scope-aid
                             #:keypair (keri-identity-keypair sid) #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope
                                        #:governor? (lambda (a) (equal? a carol-aid)))))
    ($ ($ root 'account-store) 'add-contribution alice-aid 10)
    ($ ($ root 'account-store) 'add-contribution bob-aid 20)
    (sign-mandated-delegation svc alice-aid alice-kp bob-aid 1 '(equal-position yes))
    ($ svc 'delegation-map bob-aid)
    ($ svc 'open carol-aid 'ballot 'policy "p-B" "deviate" 'federation)
    (check "bob's signed deviating cast accepted"
           (eq? 'ok (cast-signed-stance svc bob-aid (keri-identity-keypair bob) "p-B" 'no)))
    ;; Mandate violated (bob voted 'no, mandate said 'yes) → alice's 10 is HELD,
    ;; not flowed. Bob's own 20 counts on 'no; alice's 10 abstains. Franchise 30:
    ;; no = 20/30 = 2/3, abstain = 10/30 = 1/3, yes = 0. (Mirrors test-ballot §15,
    ;; via the signed path — the mandate gates alice's delegated voice at tally.)
    (check "delegate deviates: NOTHING on yes (mandate blocked alice's flow)"
           (= 0 (yes-weight svc "p-B")))
    (check "delegate deviates: bob's own voice (20/30) counts on no"
           (= 2/3 (no-weight svc "p-B")))
    (check "delegate deviates: alice's voice (10/30) is HELD as abstain, not flowed"
           (= 1/3 (abstain-weight svc "p-B")))))


(test-summary!)
