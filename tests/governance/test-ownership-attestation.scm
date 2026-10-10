;;; test-ownership-attestation.scm — title as a credential, live on the
;;; governance service: the rights-side twin of the socialize legs.
;;;
;;; A citizen titles the means they declared: the browser signs the ownership
;;; attestation (issuer = holder = OWNER, key never leaves the client), the
;;; server verifies against the caller's self-certifying AID and issues.
;;; Titles list, withdraw (issuer-gated), and stand under the compat rule
;;; ownership-ok? states: silence leaves the field-only trust standing, one
;;; spoken title becomes the only voice the gates hear.
;;;
;;; Run:  guile -L module -L tests tests/governance/test-ownership-attestation.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet governance scope) (playnet governance service) (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable) (playnet scope root) (playnet vf schemas) (srfi srfi-1) (playnet test harness)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said verify-said-signature))
             (goblins) (goblins utils hashmap) (srfi srfi-1))

(define (pre-ar pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema)
                                   (ar 'claims) (or (ar 'edges) '())))

(display "\n── own-means: client-signed title on the governance service ──\n")
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
                                        #:acdc-store store #:home-scope scope))
         (rid (string-append "means:" owner ":lathe")))

    ;; the SAID is stable across the two legs, and self-issued
    (let* ((pre  (cadr ($ svc 'own-means-preimage owner rid "lathe" "" "" "t1")))
           (ar   (pre-ar pre))
           (said (said-of ar))
           (sig  (sign-said said owner-kp)))
      (check "preimage issuer = holder = the owner (a self-assertion)"
             (and (equal? (ar 'issuer) owner) (equal? (ar 'holder) owner)))

      (check "a wrong-key signature is rejected"
             (eq? 'error (car ($ svc 'own-means-signed owner rid "lathe" "" "" "t1"
                                  (sign-said said eve-kp)))))

      (let ((r ($ svc 'own-means-signed owner rid "lathe" "" "" "t1" sig)))
        (check "own-means-signed accepted, returns the title SAID"
               (and (eq? 'ok (car r)) (equal? (cadr r) said)))
        (check "the issued title carries the OWNER's signature"
               (let ((c (find (lambda (c) (equal? said (cred-said c))) ($ store 'all))))
                 (and c (verify-said-signature said (cred-signature c) owner)))))

      (display "\n── my-titles / disown ──\n")
      (let ((titles (cadr ($ svc 'my-titles owner))))
        (check "my-titles lists the one live title (said, rid, spec, kind)"
               (equal? titles (list (list said rid "lathe" "declared")))))
      (check "a stranger cannot withdraw it"
             (eq? 'error (car ($ svc 'disown-means (keri-identity-aid eve) said))))

      (display "\n── the compat rule: ownership-ok? ──\n")
      (let ((res (make-economic-resource
                  #:id rid #:conforms-to "lathe"
                  #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable owner))
            (forged (make-economic-resource
                     #:id rid #:conforms-to "lathe"
                     #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable (keri-identity-aid eve)))
            (untitled (make-economic-resource
                       #:id "means:someone:kiln" #:conforms-to "kiln"
                       #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable "E_whoever")))
        (check "the titled owner passes" (ownership-ok? store res) #t)
        (check "a forged primary-accountable fails against the standing title"
               (ownership-ok? store forged) #f)
        (check "silence leaves field-only trust standing (compat)"
               (ownership-ok? store untitled) #t)
        (check "no store at all: field-only trust (unit-test worlds)"
               (ownership-ok? #f forged) #t)

        (display "\n── the gates: a forged grant neither issues nor projects ──\n")
        ;; Eve claims the field on a copy of the lathe and grants it away.
        ;; Field-only, that always passed; against the standing title, both
        ;; doors refuse.
        (let* ((eve-aid (keri-identity-aid eve))
               (fpre (cadr ($ svc 'socialize-preimage eve-aid commune-aid
                              "lathe" 1 "" #f "" "" rid "use" "o1")))
               (far  (pre-ar fpre))
               (fsaid (said-of far))
               (fsig (sign-said fsaid eve-kp)))
          (check "issuance refused: the standing title names another owner"
                 (car ($ svc 'socialize-signed eve-aid commune-aid
                         "lathe" 1 "" #f "" "" rid "use" "o1" fsig))
                 'error)
          (let ((fgrant (socialization-credential eve-aid commune-aid "lathe" 1
                                                  #:resource rid)))
            (check "field-only, the forged grant would have projected"
                   (%grant-over? fgrant forged) #t)
            (check "against the store, it never projects"
                   (%grant-over? fgrant forged store) #f)))
        ;; …while the titled owner's own grant passes both doors
        (let* ((opre (cadr ($ svc 'socialize-preimage owner commune-aid
                              "lathe" 1 "" #f "" "" rid "use" "o1")))
               (oar  (pre-ar opre))
               (osig (sign-said (said-of oar) owner-kp)))
          (check "the titled owner's grant issues"
                 (car ($ svc 'socialize-signed owner commune-aid
                         "lathe" 1 "" #f "" "" rid "use" "o1" osig))
                 'ok)
          (let ((ogrant (socialization-credential owner commune-aid "lathe" 1
                                                  #:resource rid)))
            (check "and projects over the titled resource"
                   (%grant-over? ogrant res store) #t)))

        (display "\n── withdrawal: a revoked-only title blocks, absence permits ──\n")
        (check "the owner withdraws their own title"
               (car ($ svc 'disown-means owner said)) 'ok)
        (check "revoked-only ⇒ the gate refuses even the field-matching owner"
               (ownership-ok? store res) #f)
        (check "my-titles is empty again"
               (cadr ($ svc 'my-titles owner)) '())))))

(test-summary!)
