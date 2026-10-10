;;; test-accept-ballot-pipeline.scm — the full ballot pipeline, wired to a
;;; real accept-socialization.
;;;
;;; open (real labour-voice) → citizens cast-signed → close #:ratify (mints
;;; the recomposition-ratification from THIS close's own tally) →
;;; accept-socialization 'ratification <said>. Every piece already existed
;;; separately (^governance-service's ballot lifecycle, require-ratification!,
;;; make-recomposition-ratification-credential); this is the first test that
;;; composes all of them into one real accept, end to end, through the
;;; gateway's own RPC surface rather than by hand-fabricating a tally.

(use-modules (playnet test harness))
(use-modules (playnet scope root) (srfi srfi-1))
(use-modules (playnet governance scope) (playnet governance service) (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri said-portable))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        sign-said))
             (goblins) (goblins vat) (goblins utils hashmap))

(define (preimage-fields pre) (lambda (k) (let ((p (assq k pre))) (and p (cdr p)))))
(define (said-of ar) (compute-said (ar 'issuer) (ar 'holder) (ar 'schema) (ar 'claims) (or (ar 'edges) '())))

(define (cast-signed-stance svc citizen-aid citizen-kp pid position)
  (let* ((ar (preimage-fields (cadr ($ svc 'stance-preimage citizen-aid pid position))))
         (ts (let ((p (assq 'timestamp (ar 'claims)))) (and p (cdr p))))
         (u  (let ((p (assq 'u (ar 'claims)))) (and p (cdr p))))
         (sig (sign-said (said-of ar) citizen-kp)))
    ($ svc 'cast-signed citizen-aid pid position ts sig u)))

(define vat (spawn-vat))
(define OWNER "EOwner00000000000000000000000000000000000000")
(define FUTURE "2099-01-01T00:00:00Z")

(with-vat vat
  (let* ((commune-id (make-keri-identity)) (commune-aid (keri-identity-aid commune-id))
         (root  (spawn-scope-root "Commune"))
         (store (spawn-acdc-store))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid commune-aid #:keypair (keri-identity-keypair commune-id)
                             #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (alice (make-keri-identity)) (alice-aid (keri-identity-aid alice))
         (bob   (make-keri-identity)) (bob-aid   (keri-identity-aid bob))
         (svc   (spawn-governance-service (list root) ($ root 'ballot-store)
                                          #:acdc-store store #:home-scope scope
                                          #:governor? (lambda (a) (equal? a commune-aid)))))
    ;; real labour-voice, not a fabricated tally
    ($ ($ root 'account-store) 'add-contribution alice-aid 10)
    ($ ($ root 'account-store) 'add-contribution bob-aid 20)

    ;; this commune now requires a passing ballot for accept-socialization
    ($ scope 'set-governance-policy! gov '((require-ratification . #t)))

    (let ((grant (socialize-private-resource store OWNER commune-aid "spec:cargo-bike" 4
                                             #:until FUTURE)))
      (check-pred "opted-in policy: accept-socialization with no ratification is refused"
                  (equal? 'error (car ($ svc 'accept-socialization commune-aid commune-aid
                                          (cred-said grant)))))

      ;; a citizen must be registered with the SERVICE (ensure-citizen) before
      ;; open() snapshots voice — real contribution in the account-store
      ;; alone isn't enough; delegation-map is the cheap way to register
      ;; without casting anything yet, mirroring test-client-signing.scm.
      ($ svc 'delegation-map alice-aid)
      ($ svc 'delegation-map bob-aid)
      ;; open the real ballot over this specific grant
      ($ svc 'open commune-aid 'ballot 'accept-socialization "p-accept-1"
         "accept the bike grant" 'federation)
      (check-pred "alice casts accept"
                  (eq? 'ok (cast-signed-stance svc alice-aid (keri-identity-keypair alice)
                                               "p-accept-1" 'accept)))
      (check-pred "bob casts accept"
                  (eq? 'ok (cast-signed-stance svc bob-aid (keri-identity-keypair bob)
                                               "p-accept-1" 'accept)))

      ;; close, minting the ratification from THIS ballot's own tally
      (let ((close-result ($ svc 'close commune-aid "p-accept-1"
                             'ratify (cons 'accept-socialization (cred-said grant)))))
        (check-pred "close returns a ratification SAID" (= 3 (length close-result)))
        (let ((ratification-said (caddr close-result)))
          (check-pred "the ratification credential exists and is self-issued by the commune"
                      (let ((cred (find (lambda (c) (equal? ratification-said (cred-said c)))
                                        ($ store 'all))))
                        (and cred (equal? commune-aid (cred-issuer cred)))))
          (check-pred "accept-socialization now succeeds, ratification in hand"
                      (equal? 'ok (car ($ svc 'accept-socialization commune-aid commune-aid
                                          (cred-said grant) 'ratification ratification-said))))
          ;; a ratification minted for a DIFFERENT grant doesn't rescue a mismatch
          (let ((grant2 (socialize-private-resource store OWNER commune-aid "spec:cargo-bike" 5
                                                    #:until FUTURE)))
            (check-pred "a mismatched ratification (wrong grant) is refused"
                        (equal? 'error (car ($ svc 'accept-socialization commune-aid commune-aid
                                              (cred-said grant2) 'ratification ratification-said))))))))))

(display "\n")
(test-summary!)
