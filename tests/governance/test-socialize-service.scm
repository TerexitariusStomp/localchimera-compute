;;; test-socialize-service.scm — the client-signed socialization grant, live on
;;; the governance service. The owner lends a means into a commune's use-pool:
;;; the browser signs the custody attestation (issuer = OWNER, key never leaves
;;; the client), the server verifies against the caller's self-certifying AID and
;;; issues; the owner lists their grants and recalls one. This is the credential
;;; core of the share face's lend path — the twin of stance client-signing.
;;;
;;; Run:  guile -L module -L tests tests/governance/test-socialize-service.scm

(use-modules (playnet boot scope) (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet scope root) (srfi srfi-1) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said verify-said-signature))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (pre-ar pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema)
                                   (ar 'claims) (or (ar 'edges) '())))
(define FUTURE "2099-12-31T00:00:00Z")

(display "\n── socialize: client-signed custody grant on the governance service ──\n")
(with-vat (spawn-vat)
  (let* ((sid (make-keri-identity)) (skp (keri-identity-keypair sid))
         (commune-aid (keri-identity-aid sid))
         (owner-id (make-keri-identity)) (owner-kp (keri-identity-keypair owner-id))
         (owner (keri-identity-aid owner-id))
         (eve (make-keri-identity)) (eve-kp (keri-identity-keypair eve))
         (root (spawn-scope-root "Commune")) (store (spawn-acdc-store))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair skp #:acdc-store store))
         (svc (spawn-governance-service (list root) ($ root 'ballot-store)
                                        #:acdc-store store #:home-scope scope)))
    ;; owner asks to lend 12 lathe-hours to the commune until FUTURE
    (let* ((pre  (cadr ($ svc 'socialize-preimage owner commune-aid "lathe" 12 FUTURE #f "" "" "" "use" "s1")))
           (ar   (pre-ar pre))
           (said (said-of ar))
           (sig  (sign-said said owner-kp)))
      (check "preimage issuer = the owner (session-bound caller)" (equal? (ar 'issuer) owner))
      (check "preimage holder = the commune" (equal? (ar 'holder) commune-aid))

      ;; a forged (wrong-key) signature is rejected
      (check "a wrong-key signature is rejected"
             (eq? 'error (car ($ svc 'socialize-signed owner commune-aid "lathe" 12 FUTURE #f "" "" "" "use" "s1"
                                  (sign-said said eve-kp)))))

      ;; the owner's real signature is accepted and issued as an OWNER-signed ACDC
      (let ((r ($ svc 'socialize-signed owner commune-aid "lathe" 12 FUTURE #f "" "" "" "use" "s1" sig)))
        (check "socialize-signed accepted, returns the grant SAID"
               (and (eq? 'ok (car r)) (equal? (cadr r) said)))
        (check "the issued grant carries the OWNER's signature (not the scope's)"
               (let ((c (find (lambda (c) (equal? said (cred-said c))) ($ store 'all))))
                 (and c (equal? owner (cred-issuer c)) (equal? commune-aid (cred-holder c))
                      (verify-said-signature said (cred-signature c) owner)))))

      ;; my-grants lists exactly the owner's live grant
      (let ((grants (cadr ($ svc 'my-grants owner))))
        (check "my-grants lists the owner's live grant (said, spec, holder)"
               (and (= 1 (length grants))
                    (equal? said (list-ref (car grants) 0))
                    (equal? "lathe" (list-ref (car grants) 1))
                    (equal? commune-aid (list-ref (car grants) 2)))))
      (check "a stranger cannot see it as theirs" (null? (cadr ($ svc 'my-grants eve))))

      ;; only the owner may recall; a stranger is refused
      (check "a stranger cannot recall the owner's grant"
             (eq? 'error (car ($ svc 'desocialize eve said))))
      (check "the owner recalls it — ok" (eq? 'ok (car ($ svc 'desocialize owner said))))
      (check "after recall, the owner's live grants are empty"
             (null? (cadr ($ svc 'my-grants owner))))

      ;; a PURSE: the same two legs with kind "consume" — the claim rides the
      ;; SAID the browser signs, and my-grants reports the verb
      (let* ((cpre  (cadr ($ svc 'socialize-preimage owner commune-aid "spec-eur" 50 FUTURE #f "" "" "" "consume" "s2")))
             (csaid (said-of (pre-ar cpre)))
             (csig  (sign-said csaid owner-kp))
             (r     ($ svc 'socialize-signed owner commune-aid "spec-eur" 50 FUTURE #f "" "" "" "consume" "s2" csig)))
        (check "a consume-grant issues through the same signed legs"
               (and (eq? 'ok (car r)) (equal? (cadr r) csaid)))
        (check "the kind claim is in the signed SAID: the use-kind preimage is a different credential"
               (not (equal? csaid (said-of (pre-ar (cadr ($ svc 'socialize-preimage owner commune-aid
                                                              "spec-eur" 50 FUTURE #f "" "" "" "use" "s2")))))))
        (check "my-grants reports the verb"
               (equal? "consume" (list-ref (car (cadr ($ svc 'my-grants owner))) 5))))

      ;; ELIGIBLE: the owner's steward rule — an optional last argument at
      ;; both legs (was a bare `. more` tail, positional index 0), forwarded
      ;; verbatim into the credential's #:eligible claim
      (let* ((rule  "{\"skill\":\"baking\"}")
             (epre  (cadr ($ svc 'socialize-preimage owner commune-aid "oven" 1 FUTURE #f "" "" "" "use" "s3" rule)))
             (esaid (said-of (pre-ar epre)))
             (esig  (sign-said esaid owner-kp))
             (r     ($ svc 'socialize-signed owner commune-aid "oven" 1 FUTURE #f "" "" "" "use" "s3" esig rule)))
        (check "socialize-signed accepted with an eligible rule attached" (eq? 'ok (car r)))
        (check "omitting eligible on the preimage yields a DIFFERENT SAID than supplying it"
               (not (equal? esaid (said-of (pre-ar (cadr ($ svc 'socialize-preimage owner commune-aid
                                                              "oven" 1 FUTURE #f "" "" "" "use" "s3")))))))))))

(test-summary!)
