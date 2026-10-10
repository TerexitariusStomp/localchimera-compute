;;; tests/gateway/test-device-doors.scm — a session answers only its device's doors
;;;
;;; What this pins:
;;;   • a session spawned with a doors allowlist answers those methods and
;;;     refuses every other with an error, before the method runs;
;;;   • a session without an allowlist is unchanged;
;;;   • the allowlist read from a device entry is the credential's doors
;;;     claim as symbols, and #f when the claim is absent.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-device-doors.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet identity devices)
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair public-key->aid-prefix seed->ed25519-keypair))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes ed25519-keypair-public))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             
             ((playnet keri first-person credentials) #:select (make-device-authorization-credential))
             (goblins) (goblins vat))

(define vat (spawn-vat))
(define %alice "EAliceDoorsTestAID0000000000000000000000000")

(define (spawn-session doors)
  (with-vat vat
    (spawn ^lobby-session %alice
           #f #f #f #f              ; terminal, mailbox, governance, signup-agent
           #f #f #f #f #f #f #f     ; oobi-host, acdc-store, folksonomy, presence, push, registry, planner
           'device #f doors)))

(display "\n── 1. the gate ──\n")

(define narrow (spawn-session '(whoami tier)))
(check "an allowed door answers" (equal? %alice (with-vat vat ($ narrow 'whoami))))
(check "tier is allowed too" (eq? 'device (with-vat vat ($ narrow 'tier))))
(define refused (with-vat vat ($ narrow 'my-contact-points)))
(check "a door outside the list is an error"
       (and (pair? refused) (eq? 'error (car refused))))
(define open-session (spawn-session #f))
(check "no allowlist: every device door answers"
       (equal? %alice (with-vat vat ($ open-session 'whoami))))

(display "\n── 2. the allowlist comes from the credential ──\n")

(define tmp (let ((d (string-append "/tmp/playnet-device-doors-" (number->string (getpid)))))
              (mkdir d) d))
(device-registry-dir tmp)
(define kp0 (bran->signing-keypair "device-doors-passcode-21ch"))
(define (device-keypair) (seed->ed25519-keypair (keri-crypto-random-bytes 32)))
(define (device-aid kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))
(define bot (device-keypair)) (define phone (device-keypair))
(define person (public-key->aid-prefix (ed25519-keypair-public kp0)))
(device-enroll! person (make-device-authorization-credential person (device-aid bot) "bot" "software"
                                                            1760000000 #:doors '("whoami" "my-slots")
                                                            #:signing-keypair kp0) 1760000000)
(device-enroll! person (make-device-authorization-credential person (device-aid phone) "phone" "software"
                                                            1760000000 #:signing-keypair kp0) 1760000000)
(define (entry-of kp) (cdr (device-owner-of (device-aid kp) 1760000001)))
(check "a doors claim reads back as symbols"
       (equal? '(whoami my-slots) (device-entry-doors (entry-of bot))))
(check "no claim reads back as #f" (eq? #f (device-entry-doors (entry-of phone))))

(test-summary!)
