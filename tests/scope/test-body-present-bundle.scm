;;; test-body-present-bundle.scm — a body's standing travels.
;;;
;;; Commune A admits a cooperative — a body whose AID is its three stewards'
;;; 2-of-3 group — and issues it a body credential chained to the root's
;;; blessing of A. The body issues Tia a steward role, signed by two of the
;;; stewards and chained to the body credential. Tia carries the bundle — the
;;; blessing, the body credential, her role and the body's KEY LOG (the
;;; group inception that names the stewards' keys) — to commune B, whose
;;; store never held any of it. B lands the log, verifies every card in
;;; dependency order and imports what stands; a role whose body is not
;;; admitted anywhere B can see is refused.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/scope/test-body-present-bundle.scm

(use-modules (playnet test harness)
             (playnet scope root) (srfi srfi-1)
             (playnet governance service) (playnet keri acdc) (playnet keri acdc-store)
             (playnet keri first-person credentials) (playnet keri first-person predicates)
             (playnet keri signify-portable)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        aid-signer-keys-resolver sign-said-multisig))
             ((playnet keys exchange) #:select (governance-cred->wire))
             ((playnet identity seat) #:select (verify-carried-kel))
             ((playnet identity oobi-host)
              #:select (oobi-write-entry-to-dir! read-oobi-entry-from-dir oobi-current-key-from-dir))
             (goblins) (goblins vat)
             (rnrs bytevectors) (srfi srfi-1) (srfi srfi-13))

(define TMP (string-append (or (getenv "TMPDIR") "/tmp") "/pn-body-bundle-" (number->string (getpid))))
(define DIR-B (string-append TMP "/oobi-b"))
(define (aid id) (keri-identity-aid id))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define (nd kp) (next-key-digest (ed25519-keypair-public kp)))

;; ── the body: its stewards' 2-of-3 group AID, with a key log ────────────────
(define brans '("steward-alice-000000000" "steward-bob-00000000000" "steward-carol-000000000"))
(define kps (map bran->signing-keypair brans))
(define nkps (map (lambda (b) (bran->rotation-keypair b 1)) brans))
(define stewards (map q kps))                 ; D-prefix AIDs: the key is the AID
(define signers (map cons stewards kps))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys stewards #:isith 2 #:nkeys (map nd nkps) #:nsith 2))
(define BODY (assoc-ref icp-alist "i"))
(define icp-sigs (vector (sign-event/indexed icp-json (first kps) 0)
                         (sign-event/indexed icp-json (third kps) 2)))
(define body-kel `(("icp" . ,icp-alist) ("sigs" . ,icp-sigs) ("rotations" . #())))

(define (kel-of-dir dir)
  (lambda (a)
    (let ((e (read-oobi-entry-from-dir dir a)))
      (and e `(("icp" . ,(assq-ref e 'icp)) ("sigs" . ,(assq-ref e 'sigs))
               ("rotations" . ,(list->vector
                                (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                                     (or (assq-ref e 'rotations) '())))))))))
(define (landing-into dir)
  (lambda (a icp sigs rots)
    (call-with-values (lambda () (verify-carried-kel a icp sigs rots (read-oobi-entry-from-dir dir a)))
      (lambda (v entry) (if (eq? v #t) (begin (oobi-write-entry-to-dir! dir entry) #t) v)))))
(define (card c) (append (governance-cred->wire c) (list (cons "sig" (or (cred-signature c) "")))))
(define (bundle creds . kels)
  (scm->json-canonical `(("creds" . ,(list->vector (map card creds))) ("kels" . ,kels))))
(define (block cred . who)
  (sign-said-multisig (cred-said cred) (filter (lambda (s) (member (car s) who)) signers)))

;; B's verifier reads every signer's key from its own oobi dir; the stewards
;; are D-prefix, so their AIDs are their keys and need no entry
(aid-signer-keys-resolver
 (lambda (a _at) (let ((k (oobi-current-key-from-dir DIR-B a))) (if k (list k) '()))))

(define vat (spawn-vat))
(with-vat vat
  (let* ((root (make-keri-identity)) (ROOT (aid root))
         (eco-a (make-keri-identity)) (ECO-A (aid eco-a))
         (eco-x (make-keri-identity)) (ECO-X (aid eco-x))      ; blessed by no root
         (tia (make-keri-identity)) (TIA (aid tia))
         (sam (make-keri-identity)) (SAM (aid sam))
         (store-b (spawn-acdc-store))
         (root-b (spawn-scope-root "B"))
         (svc-b (spawn-governance-service (list root-b) ($ root-b 'ballot-store)
                                          #:acdc-store store-b #:kel-landing (landing-into DIR-B)
                                          #:kel-of (kel-of-dir DIR-B)))
         ;; what A issued
         (aic (make-authorized-issuer-credential ROOT ECO-A 5 #:signing-keypair (keri-identity-keypair root)))
         (body (make-body-credential ECO-A BODY 100 #:kind 'cooperative #:quorum 2
                                     #:legal-ids '((lei . "506700GE1G29325QX363"))
                                     #:issuer-authz-said (cred-said aic)
                                     #:signing-keypair (keri-identity-keypair eco-a)))
         (role0 (make-body-role-credential BODY TIA 'steward "2026-10-10T00:00:00Z" #:quorum 2
                                           #:body-cred-said (cred-said body)))
         (role (body-role-credential-with-block role0 (block role0 (first stewards) (second stewards)))))
    ($ svc-b 'set-fp-root! ROOT)

    (display "\n── presented at B, which never held any of it ──\n")
    (check "B holds no body credential yet" ($ store-b 'get (cred-said body)) #f)
    (let ((r ($ svc-b 'present-bundle TIA (bundle (list aic body role) (cons BODY body-kel)))))
      (check "B accepts the bundle" (car r) 'ok)
      (check "three cards imported" (cdr r) 3))
    (check "the body's key log stands in B's oobi dir" (string? (oobi-current-key-from-dir DIR-B BODY)))
    (check "the body credential is held at B, with its claims whole"
           (let ((b ($ store-b 'get (cred-said body))))
             (and b (list (cred-claim b 'kind) (assq-ref (cred-claim b 'legal-ids) 'lei))))
           '(cooperative "506700GE1G29325QX363"))
    (check "it chains to the root at B" #t (body-credential-valid? ($ store-b 'get (cred-said body)) #:roots ROOT #:store store-b))
    (check "the role is held at B and verifies k-of-n AND the chain there"
           #t (body-role-credential-valid? ($ store-b 'get (cred-said role)) stewards 2 #:roots ROOT #:store store-b))
    (check "presenting again imports nothing and refuses nothing"
           ($ svc-b 'present-bundle TIA (bundle (list aic body role) (cons BODY body-kel))) '(ok . 0))
    (check "a second role rides on the body credential B already holds, log or no log"
           (let* ((r0 (make-body-role-credential BODY TIA 'member "2026-10-11T00:00:00Z" #:body-cred-said (cred-said body)))
                  (r (body-role-credential-with-block r0 (block r0 (second stewards) (third stewards)))))
             ($ svc-b 'present-bundle TIA (bundle (list r))))
           '(ok . 1))

    (display "\n── what B refuses ──\n")
    (let* ((store-c (spawn-acdc-store)) (dir-c (string-append TMP "/oobi-c"))
           (root-c (spawn-scope-root "C"))
           (svc-c (spawn-governance-service (list root-c) ($ root-c 'ballot-store)
                                            #:acdc-store store-c #:kel-landing (landing-into dir-c)))
           (refused? (lambda (r) (eq? 'error (car r)))))
      ($ svc-c 'set-fp-root! ROOT)
      (aid-signer-keys-resolver
       (lambda (a _at) (let ((k (oobi-current-key-from-dir dir-c a))) (if k (list k) '()))))
      (check "a role without its body credential is refused"
             (refused? ($ svc-c 'present-bundle TIA (bundle (list aic role) (cons BODY body-kel)))))
      (check "…and nothing landed" ($ store-c 'get (cred-said role)) #f)
      (check "a role presented by someone it does not name is refused"
             (refused? ($ svc-c 'present-bundle SAM (bundle (list aic body role) (cons BODY body-kel)))))
      (check "a role signed by one steward of two is refused"
             (refused? ($ svc-c 'present-bundle TIA
                          (bundle (list aic body (body-role-credential-with-block role0 (block role0 (first stewards))))
                                  (cons BODY body-kel)))))
      (check "a role signed by strangers is refused"
             (let* ((mallory (bran->signing-keypair "mallory-000000000000000"))
                    (mo (bran->signing-keypair "mallory-two-00000000000"))
                    (b (sign-said-multisig (cred-said role0) (list (cons (q mallory) mallory) (cons (q mo) mo)))))
               (refused? ($ svc-c 'present-bundle TIA
                            (bundle (list aic body (body-role-credential-with-block role0 b)) (cons BODY body-kel))))))
      (check "a role whose edge names another body is refused"
             (let* ((other (make-body-credential ECO-A "EOTHERBODYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" 100
                                                 #:issuer-authz-said (cred-said aic)
                                                 #:signing-keypair (keri-identity-keypair eco-a)))
                    (r0 (make-body-role-credential BODY TIA 'steward "2026-10-10T00:00:00Z" #:quorum 2
                                                   #:body-cred-said (cred-said other)))
                    (r (body-role-credential-with-block r0 (block r0 (first stewards) (second stewards)))))
               (refused? ($ svc-c 'present-bundle TIA (bundle (list aic body other r) (cons BODY body-kel))))))
      (check "a body credential from a scope no root blessed is refused"
             (let* ((bx (make-body-credential ECO-X BODY 100 #:signing-keypair (keri-identity-keypair eco-x)))
                    (r0 (make-body-role-credential BODY TIA 'steward "2026-10-10T00:00:00Z" #:quorum 2
                                                   #:body-cred-said (cred-said bx)))
                    (r (body-role-credential-with-block r0 (block r0 (first stewards) (second stewards)))))
               (refused? ($ svc-c 'present-bundle TIA (bundle (list bx r) (cons BODY body-kel))))))
      (check "a tampered body credential is refused"
             (let* ((json (string-copy (bundle (list aic body role) (cons BODY body-kel))))
                    (i (string-contains json "cooperative")))
               (string-copy! json i "foundation!")
               (refused? ($ svc-c 'present-bundle TIA json))))
      (check "without the body's key log, the stewards cannot be read — refused"
             (refused? ($ svc-c 'present-bundle TIA (bundle (list aic body role)))))
      (check "nothing of it landed" ($ store-c 'get (cred-said body)) #f)
      (check "with the log, accepted" ($ svc-c 'present-bundle TIA (bundle (list aic body role) (cons BODY body-kel))) '(ok . 3)))))

(test-summary!)
