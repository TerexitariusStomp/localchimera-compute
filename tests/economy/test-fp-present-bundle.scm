;;; test-fp-present-bundle.scm — a vouch that travels.
;;;
;;; Alice, recognised at commune A, vouches for Tia. Tia carries the bundle
;;; A hands her — Alice's vouch, Alice's personhood, the root's blessing of
;;; A, and Alice's KEY LOG (a browser-born E-prefix AID a foreign gateway
;;; could not otherwise check) — and presents it at commune B, whose store
;;; never held any of it. B lands the log, verifies every card in order,
;;; imports what stands; then every reader of a vouch at B sees Alice's.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/economy/test-fp-present-bundle.scm

(use-modules (playnet test harness)
             (playnet scope root) (srfi srfi-1)
             (playnet boot governance) (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates)
             (playnet keri signify-portable)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        aid-signer-keys-resolver))
             ((playnet identity seat) #:select (verify-carried-kel))
             ((playnet identity oobi-host)
              #:select (oobi-write-entry-to-dir! read-oobi-entry-from-dir oobi-current-key-from-dir))
             (goblins) (goblins vat) (goblins utils hashmap)
             (rnrs bytevectors) (ice-9 ftw) (srfi srfi-1) (srfi srfi-13))

(define TMP (string-append (or (getenv "TMPDIR") "/tmp") "/pn-bundle-" (number->string (getpid))))
(define DIR-A (string-append TMP "/oobi-a"))
(define DIR-B (string-append TMP "/oobi-b"))
(define (aid id) (keri-identity-aid id))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define (nd kp) (next-key-digest (ed25519-keypair-public kp)))

;; ── Alice: a browser-born AID with a key log, one rotation deep ──────────────
(define bran "alice-carries-her-log-000")
(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define kp2 (bran->rotation-keypair bran 2))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (nd kp1))))
(define ALICE (assoc-ref icp-alist "i"))
(define icp-sigs (vector (sign-event icp-json kp0)))
(define-values (rot1-json rot1-said rot1-alist)
  (build-rot ALICE icp-said #:keys (list (q kp1)) #:nkeys (list (nd kp2)) #:sn 1))
(define rot1-sigs (vector (sign-event rot1-json kp1)))
(define alice-entry
  `((aid . ,ALICE) (icp . ,icp-alist) (sigs . ,icp-sigs)
    (rotations . ((,rot1-alist . ,rot1-sigs))) (replies . #())
    (registered-at . "0")))
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

;; every signature under an AID is checked against B's oobi dir — the
;; verifier's side; A never verifies in this test
(aid-signer-keys-resolver
 (lambda (a _at) (let ((k (oobi-current-key-from-dir DIR-B a))) (if k (list k) '()))))

(define vat (spawn-vat))
(with-vat vat
  (let* ((root (make-keri-identity)) (ROOT (aid root))
         (eco-a (make-keri-identity)) (ECO-A (aid eco-a))
         (eco-x (make-keri-identity)) (ECO-X (aid eco-x))      ; blessed by no root
         (tia (make-keri-identity)) (TIA (aid tia))
         (sam (make-keri-identity)) (SAM (aid sam))
         (store-a (spawn-acdc-store)) (store-b (spawn-acdc-store))
         (root-a (spawn-scope-root "A")) (root-b (spawn-scope-root "B"))
         (svc-a (spawn-governance-service (list root-a) ($ root-a 'ballot-store)
                                          #:acdc-store store-a #:kel-of (kel-of-dir DIR-A)))
         (svc-b (spawn-governance-service (list root-b) ($ root-b 'ballot-store)
                                          #:acdc-store store-b #:kel-landing (landing-into DIR-B))))
    ($ svc-a 'set-fp-root! ROOT)
    ($ svc-b 'set-fp-root! ROOT)
    ;; A holds: the root's blessing of A; Alice's personhood (issued by A);
    ;; Alice's key log; Alice's vouch for Tia, signed with her CURRENT key
    (oobi-write-entry-to-dir! DIR-A alice-entry)
    ($ store-a 'issue (make-authorized-issuer-credential #:root-aid ROOT
                                                         #:ecosystem-aid ECO-A
                                                         #:blessed-at 5
                        #:signing-keypair (keri-identity-keypair root)))
    ($ store-a 'issue (make-personhood-credential #:ecosystem-aid ECO-A
                                                  #:holder-aid ALICE
                                                  #:enrolled-at 100
                        #:signing-keypair (keri-identity-keypair eco-a)))
    ($ store-a 'issue (make-personhood-credential #:ecosystem-aid ECO-A
                                                  #:holder-aid TIA
                                                  #:enrolled-at 100
                        #:signing-keypair (keri-identity-keypair eco-a)))
    (let ((phc (any-live-phc-for store-a ALICE)))
      ($ store-a 'issue (make-relationship-credential #:issuer-aid ALICE
                                                      #:subject-aid TIA
                                                      #:relationship-type 'friends
                                                      #:issuer-phc-said (cred-said phc)
                          #:issued-at "2026-08-30T00:00:00Z"
                                                      #:signing-keypair kp1)))

    (display "\n── what Tia carries away from A ──\n")
    (let* ((r ($ svc-a 'fp-my-vouches TIA))
           (json (cdr r))
           (parsed (json-read-ordered json))
           (creds (vector->list (assoc-ref parsed "creds")))
           (schemas (map (lambda (c) (assoc-ref c "s")) creds)))
      (check "the bundle is a JSON string" (and (eq? 'ok (car r)) (string? json)) #t)
      (check "it carries the blessing, two personhoods and the vouch"
             (list (count (lambda (s) (equal? s *schema-playnet-authorized-issuer*)) schemas)
                   (count (lambda (s) (equal? s *schema-playnet-personhood*)) schemas)
                   (count (lambda (s) (equal? s *schema-playnet-relationship*)) schemas))
             '(1 2 1))
      (check "it carries Alice's key log, rotation included"
             (vector-length (assoc-ref (assoc-ref (assoc-ref parsed "kels") ALICE) "rotations")) 1)

      (display "\n── presented at B, which never held any of it ──\n")
      (check "B knows no one yet" (holds-any-live-phc? store-b ALICE) #f)
      (let ((r ($ svc-b 'present-bundle TIA json)))
        (check "B accepts the bundle" (car r) 'ok)
        (check "four cards imported" (cdr r) 4))
      (check "Alice's current key stands in B's oobi dir"
             (oobi-current-key-from-dir DIR-B ALICE) (q kp1))
      (check "Alice is a person at B" (holds-any-live-phc? store-b ALICE) #t)
      (check "Alice's ecosystem chains to the root at B"
             (ecosystem-chains-to-any-root? store-b ROOT ECO-A) #t)
      (check "the vouch reads as a group at B, by the kind's one name" (vrc-groups-of store-b ALICE TIA) '("friend"))
      (check "the steward gate at B admits Tia under Alice's rule"
             (let ((may (make-may-steward store-b)))
               (socialize-private-resource store-b ALICE "EHearthB" "oven" 1
                                           #:until "2099-01-01T00:00:00Z"
                                           #:eligible "{\"filter-rule\":[\"in-group\",\"friends\"]}")
               (list (may "EHearthB" TIA "oven") (may "EHearthB" SAM "oven")))
             '(#t #f))
      (check "presenting again imports nothing and refuses nothing"
             ($ svc-b 'present-bundle TIA json) '(ok . 0))

      (display "\n── what B refuses ──\n")
      (check "a stranger presenting Tia's bundle is refused"
             (car ($ svc-b 'present-bundle SAM json)) 'error)
      ;; a grafted card: the vouch's rel rewritten after signing
      (let* ((tampered (string-copy json))
             (i (string-contains tampered "friends")))
        (string-copy! tampered i "enemies")
        (check "a tampered card is refused" (car ($ svc-b 'present-bundle TIA tampered)) 'error))
      ;; a personhood from an ecosystem no root blessed
      (let* ((store-x (spawn-acdc-store))
             (svc-x (spawn-governance-service (list root-a) ($ root-a 'ballot-store)
                                              #:acdc-store store-x #:kel-of (kel-of-dir DIR-A))))
        ($ svc-x 'set-fp-root! ROOT)
        ($ store-x 'issue (make-personhood-credential #:ecosystem-aid ECO-X
                                                      #:holder-aid SAM
                                                      #:enrolled-at 100
                            #:signing-keypair (keri-identity-keypair eco-x)))
        (let ((jx (cdr ($ svc-x 'fp-my-vouches SAM))))
          (check "an unblessed ecosystem's personhood is refused"
                 (car ($ svc-b 'present-bundle SAM jx)) 'error)
          (check "…and nothing of it was imported" (holds-any-live-phc? store-b SAM) #f))))

    (display "\n── the key log is what makes the signature checkable ──\n")
    (let* ((store-c (spawn-acdc-store)) (dir-c (string-append TMP "/oobi-c"))
           (svc-c (spawn-governance-service (list root-b) ($ root-b 'ballot-store)
                                            #:acdc-store store-c #:kel-landing (landing-into dir-c)))
           (json (cdr ($ svc-a 'fp-my-vouches TIA)))
           (parsed (json-read-ordered json))
           ;; the same bundle with the log stripped
           (bare (scm->json-canonical (filter (lambda (p) (not (equal? "kels" (car p)))) parsed)))
           ;; …and with a log that stops before Alice's rotation
           (stale (scm->json-canonical
                   (map (lambda (p)
                          (if (equal? "kels" (car p))
                              (cons "kels"
                                    (map (lambda (k)
                                           (cons (car k)
                                                 (map (lambda (f) (if (equal? "rotations" (car f))
                                                                      (cons "rotations" (vector))
                                                                      f))
                                                      (cdr k))))
                                         (cdr p)))
                              p))
                        parsed))))
      ($ svc-c 'set-fp-root! ROOT)
      (aid-signer-keys-resolver
       (lambda (a _at) (let ((k (oobi-current-key-from-dir dir-c a))) (if k (list k) '()))))
      (check "without the log, Alice's signature cannot be checked — refused"
             (car ($ svc-c 'present-bundle TIA bare)) 'error)
      (check "with a log that stops before her rotation, the signature fails — refused"
             (car ($ svc-c 'present-bundle TIA stale)) 'error)
      (check "nothing landed" (holds-any-live-phc? store-c ALICE) #f)
      (check "with the whole log, accepted" (car ($ svc-c 'present-bundle TIA json)) 'ok))))

(test-summary!)
