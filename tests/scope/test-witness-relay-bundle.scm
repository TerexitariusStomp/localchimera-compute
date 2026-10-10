;;; test-witness-relay-bundle.scm — a witness from another gateway.
;;;
;;; Bo asks to be recognised at commune A. Tia is recognised at commune B —
;;; a browser-born AID whose key A has never seen. Tia's dial at B signs
;;; A's ask from her witness rail: the co-signature leaves B beside her
;;; bundle (personhood, the root's blessing of B, her key log); A's poll
;;; presents the bundle, then lands the signature, and A's ceremony counts
;;; her. The two gateways share nothing but files.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/scope/test-witness-relay-bundle.scm

(use-modules (playnet test harness)
             (playnet scope root)
             (playnet personhood attestation-ceremony) (playnet personhood enrollment) (playnet utils paths) (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates)
             ((playnet utils paths) #:select (current-playnet-state-dir-override))
             ((playnet personhood witness-relay)
              #:select (publish-witness-attest! land-remote-attests!))
             ((playnet personhood attestation-ceremony)
              #:select (current-aid-key-resolver))
             (playnet keri signify-portable)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid
                        aid-signer-keys-resolver sign-said))
             ((playnet identity seat) #:select (verify-carried-kel))
             ((playnet identity oobi-host)
              #:select (oobi-write-entry-to-dir! read-oobi-entry-from-dir oobi-current-key-from-dir))
             (json)
             (goblins) (goblins vat) (goblins utils hashmap)
             (ice-9 textual-ports) (ice-9 ftw) (srfi srfi-1))

(define TMP (string-append (or (getenv "TMPDIR") "/tmp") "/pn-relay-" (number->string (getpid))))
(define STATE-A (string-append TMP "/state-a"))
(define STATE-B (string-append TMP "/state-b"))
(define DIR-A (string-append TMP "/oobi-a"))
(define DIR-B (string-append TMP "/oobi-b"))
(define (aid id) (keri-identity-aid id))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define (nd kp) (next-key-digest (ed25519-keypair-public kp)))
(define (at-state dir thunk) (parameterize ((current-playnet-state-dir-override dir)) (thunk)))

;; Tia: a browser-born AID, her log held at B
(define bran "tia-witnesses-from-afar-00")
(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (nd kp1))))
(define TIA (assoc-ref icp-alist "i"))
(define tia-entry
  `((aid . ,TIA) (icp . ,icp-alist) (sigs . ,(vector (sign-event icp-json kp0)))
    (rotations . ()) (replies . #()) (registered-at . "0")))
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

;; A is the verifier: both key resolvers read A's dir
(aid-signer-keys-resolver
 (lambda (a _at) (let ((k (oobi-current-key-from-dir DIR-A a))) (if k (list k) '()))))
(current-aid-key-resolver (lambda (a) (oobi-current-key-from-dir DIR-A a)))

(define vat (spawn-vat))
(with-vat vat
  (let* ((root (make-keri-identity)) (ROOT (aid root))
         (eco-a (make-keri-identity)) (ECO-A (aid eco-a))
         (eco-b (make-keri-identity)) (ECO-B (aid eco-b))
         (ana (make-keri-identity)) (ANA (aid ana))
         (bo (make-keri-identity)) (BO (aid bo))
         (store-a (spawn-acdc-store)) (store-b (spawn-acdc-store))
         (root-a (spawn-scope-root "A")) (root-b (spawn-scope-root "B"))
         (svc-a (spawn-governance-service (list root-a) ($ root-a 'ballot-store)
                                          #:acdc-store store-a #:kel-landing (landing-into DIR-A)))
         (svc-b (spawn-governance-service (list root-b) ($ root-b 'ballot-store)
                                          #:acdc-store store-b #:kel-of (kel-of-dir DIR-B))))
    ($ svc-a 'set-fp-root! ROOT) ($ svc-b 'set-fp-root! ROOT)
    ;; A: blessed by the root; Ana recognised
    ($ store-a 'issue (make-authorized-issuer-credential ROOT ECO-A 5
                        #:signing-keypair (keri-identity-keypair root)))
    ($ store-a 'issue (make-personhood-credential ECO-A ANA 100
                        #:signing-keypair (keri-identity-keypair eco-a)))
    ;; B: blessed by the root; Tia recognised, her log held
    ($ store-b 'issue (make-authorized-issuer-credential ROOT ECO-B 5
                        #:signing-keypair (keri-identity-keypair root)))
    ($ store-b 'issue (make-personhood-credential ECO-B TIA 100
                        #:signing-keypair (keri-identity-keypair eco-b)))
    (oobi-write-entry-to-dir! DIR-B tia-entry)

    (display "\n── Bo asks at A; the ask is published ──\n")
    (define ceremony
      (at-state STATE-A
        (lambda () (spawn-enrollment-ceremony ECO-A BO *self-request-evidence* #f 2 store-a
                                              #:root-aid ROOT))))
    (define said ($ ceremony 'statement-said))
    (check "A's ask is on its rail"
           (file-exists? (string-append STATE-A "/witness/requests/" said ".json")) #t)
    (check "A does not know Tia" (holds-any-live-phc? store-a TIA) #f)

    (display "\n── B's poll remembers the ask; Tia signs from B ──\n")
    (define req (json-string->scm
                 (call-with-input-file (string-append STATE-A "/witness/requests/" said ".json")
                   get-string-all)))
    ;; B's door, as a separate process would run it: no ceremony of its own
    ;; under this said, so the signature is published beside Tia's bundle
    ;; (the door's remote branch; in one process the shared registry would
    ;; hand it A's ceremony, which is why the branch is called directly)
    (define bundle-of
      (lambda (a) (let ((r ($ svc-b 'fp-my-vouches a)))
                    (and (eq? 'ok (car r)) (string? (cdr r)) (not (string-null? (cdr r))) (cdr r)))))
    (at-state STATE-B
      (lambda ()
        (publish-witness-attest! said TIA (sign-said said kp0) (bundle-of TIA))
        (check "Tia's signature leaves B for A"
               (file-exists? (string-append STATE-B "/witness/attests/" said "." TIA ".json")) #t)))
    (define att-file (string-append STATE-B "/witness/attests/" said "." TIA ".json"))
    (define att (json-string->scm (call-with-input-file att-file get-string-all)))
    (check "the attest carries Tia's bundle" (string? (assoc-ref att "bundle")) #t)

    (display "\n── A lands it: the bundle first, then the signature ──\n")
    (check "without presenting the bundle, A refuses her — unknown key, no personhood"
           (at-state STATE-A
             (lambda () (land-remote-attests!
                         (list (filter (lambda (p) (not (equal? "bundle" (car p)))) att)))))
           0)
    (check "with the bundle presented, her signature lands"
           (at-state STATE-A
             (lambda () (land-remote-attests! (list att)
                          #:present (lambda (w b) ($ svc-a 'present-bundle w b)))))
           1)
    (check "Tia's key stands at A now" (oobi-current-key-from-dir DIR-A TIA) (q kp0))
    (check "Tia is a person at A, by B's word chained to the root" (holds-any-live-phc? store-a TIA) #t)
    (check "the ceremony counts her" ($ ceremony 'attestation-count) 1)
    (check "landing the same attest again is a no-op"
           (at-state STATE-A (lambda () (land-remote-attests! (list att)))) 0)
    (check "Ana signs — quorum, Bo is recognised with Tia's edge among the witnesses"
           (begin ($ ceremony 'attest ANA (sign-said said (keri-identity-keypair ana)))
                  ($ ceremony 'finalize)
                  (and (holds-live-phc? store-a ECO-A BO)
                       (assq (string->symbol (string-append "witness-" TIA))
                             (cred-edges (phc-for store-a ECO-A BO)))
                       #t))
           #t)))

(test-summary!)
