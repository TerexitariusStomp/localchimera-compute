;;; tests/keri/test-device-auth.scm — cold root, hot device keys.
;;;
;;; The root (KEL key, passcode in hand) authorizes a device's key with a
;;; device-authorization credential; the gateway records it; from then on
;;; the device authenticates by challenge-response under its own key and
;;; its SAID signatures verify as the person's (aid-signer-keys-resolver).
;;; Root-only acts refuse a device session; revocation ends both the
;;; session door and the signature door. docs/planning/identity/device-keys.md.

(use-modules (playnet test harness)
             (playnet identity fixture)
             (playnet keri signify-portable)
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             ((playnet keri citizen-sig)
              #:select (aid-signer-keys-resolver verify-said-signature sign-said))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes))
             ((playnet keri acdc) #:select (make-credential))
             ((playnet keri first-person predicates) #:select (cred-signature-valid?))
             ((playnet keri acdc) #:select (cred-said cred-claims cred-signature cred-schema cred-issuer cred-holder)) ((playnet keri first-person credentials) #:select (make-device-authorization-credential))
             (playnet identity devices)
             (playnet identity seat)
             (playnet identity oobi-host)
             (playnet gateway lobby)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (json)
             (ice-9 format))

(define tmp (let ((d (string-append "/tmp/playnet-device-auth-" (number->string (getpid)))))
              (mkdir d) d))
(device-registry-dir tmp)

(define bran "device-auth-passcode-21ch")
(define-values (kp0 kp1 icp-json icp-said icp-alist aid icp-sigs)
  (test-identity bran))
(define-values (gateway-vat signup-vat signup-agent oobi-host lobby settle)
  (lobby-fixture))

;; two devices, each a fresh key; the AID is the B-prefixed public key
(define (device-keypair) (seed->ed25519-keypair (keri-crypto-random-bytes 32)))
(define (device-aid kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))
(define laptop (device-keypair))
(define phone  (device-keypair))
(define other-aid "EOTHERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")   ; a credential's holder

(define (sign-nonce nonce kp) (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp)))
(define (root-auth)
  (let ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid))))
    (settle (with-vat gateway-vat ($ lobby 'keri-authenticate aid (sign-nonce nonce kp0) nonce)))))
(define (device-auth wire kp)
  (let ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid))))
    (settle (with-vat gateway-vat
              ($ lobby 'keri-authenticate-device aid wire (sign-nonce nonce kp) nonce)))))
(define (err-with? r what)
  (and (pair? r) (eq? 'error (car r)) (string? (cadr r)) (string-contains (cadr r) what)))

;; the wire the browser builds: SAID fields + the root's signature
(define (cred->wire cred)
  (scm->json-string
   `(("said" . ,(cred-said cred)) ("schema" . ,(cred-schema cred))
     ("issuer" . ,(cred-issuer cred)) ("holder" . ,(cred-holder cred))
     ("claims" . ,(map (lambda (kv) (cons (symbol->string (car kv))
                                          (if (eq? (cdr kv) #f) 'null (cdr kv))))
                       (cred-claims cred)))
     ("sig" . ,(cred-signature cred)))))
(define (authorize kp label signer)
  (cred->wire (make-device-authorization-credential
               aid (device-aid kp) label "software" 1700000000
               #:signing-keypair signer)))

(format #t "~%=== seat the root ===~%")
(check "witness-kel" (eq? 'ok (settle (with-vat gateway-vat
                                        ($ lobby 'witness-kel aid icp-alist icp-sigs (vector))))))
(check "join" (eq? 'ok (settle (with-vat gateway-vat ($ lobby 'join "" "" aid)))))
(define root (let ((r (root-auth))) (and (pair? r) (eq? 'ok (car r)) (cadr r))))
(check "root session" (and root #t))
(check "root tier" (eq? 'root (with-vat gateway-vat ($ root 'tier))))

(format #t "~%=== enroll ===~%")
(define laptop-wire (authorize laptop "laptop" kp0))
(check "the root enrolls a device"
       (eq? 'ok (with-vat gateway-vat ($ root 'enroll-device laptop-wire))))
(check "a device authorized by a device is refused"
       (err-with? (with-vat gateway-vat ($ root 'enroll-device (authorize phone "phone" laptop)))
                  "root"))
(check "a wire whose digest was tampered is refused"
       (err-with? (with-vat gateway-vat
                    ($ root 'enroll-device
                       (let ((w (json-string->scm laptop-wire)))
                         (scm->json-string
                          (map (lambda (kv)
                                 (if (equal? (car kv) "claims")
                                     (cons "claims"
                                           (map (lambda (c) (if (equal? (car c) "label")
                                                                (cons "label" "stolen") c))
                                                (cdr kv)))
                                     kv))
                               w)))))
                  "digest"))
(check "my-devices lists it"
       (let ((ds (with-vat gateway-vat ($ root 'my-devices))))
         (and (= 1 (length ds)) (equal? (assoc-ref (car ds) "label") "laptop"))))

(format #t "~%=== the device signs in ===~%")
(define dev (let ((r (device-auth laptop-wire laptop))) (and (pair? r) (eq? 'ok (car r)) (cadr r))))
(check "device session" (and dev #t))
(check "…as the person" (and dev (equal? aid (with-vat gateway-vat ($ dev 'whoami)))))
(check "…at tier device" (and dev (eq? 'device (with-vat gateway-vat ($ dev 'tier)))))
(check "an unenrolled device with a valid root authorization is refused"
       (err-with? (device-auth (authorize phone "phone" kp0) phone) "enrolled"))
(check "the wrong device key for an enrolled wire is refused"
       (err-with? (device-auth laptop-wire phone) "signature"))
(check "a device session cannot enroll another device"
       (and dev (err-with? (with-vat gateway-vat ($ dev 'enroll-device (authorize phone "phone" kp0)))
                           "passcode")))
(check "a device session cannot rotate"
       (and dev (err-with? (with-vat gateway-vat ($ dev 'rotate-aid '() (vector))) "passcode")))

(format #t "~%=== the device's signatures are the person's ===~%")
(define said "EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define dev-sig (sign-said said laptop))
(check "unbound resolver: a device signature is nobody's"
       (not (verify-said-signature said dev-sig aid)))
(aid-signer-keys-resolver
 (lambda (a at) (append (let ((k ($ oobi-host 'current-key a))) (if (string? k) (list k) '()))
                        (device-keys-at a (or at (current-time))))))
(check "bound: the device signs as the person"
       (with-vat gateway-vat (verify-said-signature said dev-sig aid)))
(check "…and the root still does"
       (with-vat gateway-vat (verify-said-signature said (sign-said said kp0) aid)))
(check "…and a stranger's device does not"
       (not (with-vat gateway-vat (verify-said-signature said (sign-said said phone) aid))))

(format #t "~%=== revoke ===~%")
(define laptop-said (assoc-ref (json-string->scm laptop-wire) "said"))
(check "the device revokes itself" (and dev (eq? 'ok (with-vat gateway-vat ($ dev 'revoke-device laptop-said)))))
(check "revoked: sign-in refused" (err-with? (device-auth laptop-wire laptop) "revoked"))
(check "revoked: signature is nobody's — as of now"
       (not (with-vat gateway-vat (verify-said-signature said dev-sig aid))))
;; the registry is the device key's log: a statement is verified at its own
;; time, and the laptop was authorized then (enrolled 1700000000, revoked
;; today) — so what it signed while live stays the person's, as a
;; rotated-away root key keeps what it signed
(check "…but a statement made while the device was live stays the person's"
       (with-vat gateway-vat (verify-said-signature said dev-sig aid 1700000001)))
(check "…and not one dated before the device was authorized"
       (not (with-vat gateway-vat (verify-said-signature said dev-sig aid 1699999999))))
;; the same at the credential layer: a credential the laptop signed as the
;; person, timestamped while it was live, is valid to cred-signature-valid?
;; after the revocation — the personhood audit reads such a vouch as signed
(check "a credential the device signed while live is still the person's signed credential"
       (with-vat gateway-vat
         (cred-signature-valid?
          (make-credential "playnet-test/v1" aid other-aid '((timestamp . 1700000001))
                           #:signing-keypair laptop))))
(check "…and one it dates after its revocation is not"
       (not (with-vat gateway-vat
              (cred-signature-valid?
               (make-credential "playnet-test/v1" aid other-aid '((timestamp . 4102444800))
                                #:signing-keypair laptop)))))
(check "my-devices shows the revocation"
       (let ((ds (with-vat gateway-vat ($ root 'my-devices))))
         (and (= 1 (length ds)) (integer? (assoc-ref (car ds) "revokedAt")))))
(check "unknown said → no such device"
       (err-with? (with-vat gateway-vat ($ root 'revoke-device "Enope")) "no such"))

;; ── a rotation of the root retires its devices at the door ─────────────────
;; An authorization verifies under the key in force. The root rotates (its
;; next key revealed, the log levelled up through witness-kel): the phone it
;; authorized before is refused as revoked, and the laptop, retired in the
;; registry, is told the same thing it was told before the rotation.
(format #t "~%=== a rotation retires the devices ===~%")
(define phone-wire (authorize phone "phone" kp0))
(check "the root enrolls a second device"
       (eq? 'ok (with-vat gateway-vat ($ root 'enroll-device phone-wire))))
(check "…which signs in"
       (let ((r (device-auth phone-wire phone))) (and (pair? r) (eq? 'ok (car r)))))
(define kp2 (bran->rotation-keypair bran 2))
(define-values (rot-json rot-said rot-alist)
  (build-rot aid (assoc-ref icp-alist "d")
             #:keys (list (keypair->aid-prefix kp1))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp2)))
             #:sn 1))
(check "the root rotates"
       (eq? 'ok (settle (with-vat gateway-vat
                          ($ lobby 'witness-kel aid icp-alist icp-sigs
                             (vector (cons rot-alist (vector (sign-event rot-json kp1)))))))))
(check "a device authorized before the rotation is refused as revoked"
       (let ((r (device-auth phone-wire phone)))
         (and (err-with? r "revoked") (err-with? r "predates the key now in force"))))
(check "a device retired in the registry is told so, as before"
       (err-with? (device-auth laptop-wire laptop) "revoked or expired"))

(test-summary!)
