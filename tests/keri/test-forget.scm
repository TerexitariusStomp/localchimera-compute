;;; tests/keri/test-forget.scm — forget-me: erasure as one act, the link last.
;;;
;;; A member with everything a gateway can hold of theirs — a seat, a presence
;;; entry, bindings (browser, push, email), a point waiting at the desk, an
;;; enrolled device, cards given and received, every kind of user file, an
;;; offline mailbox, a spooled mail — is forgotten through the root session's
;;; one door. The properties (gateway/forget.scm, gdpr-analysis.md §3.1):
;;;   every store of the gateway's own is empty of them, and the receipt
;;;   counts what went; the old cap refuses; the key log STANDS (the
;;;   pseudonym can take a seat again — disassociation with the chain intact);
;;;   a second forget is all zeros; a device-tier session cannot forget;
;;;   a rotation naming no next key is witnessed, and no rotation follows it.
;;;
;;; The data dir is set before any module reads it (device-registry's boot
;;; cell reads the environment at load).

(define tmp (let ((d (string-append "/tmp/playnet-forget-" (number->string (getpid)))))
              (mkdir d) d))
(setenv "PLAYNET_DATA_DIR" tmp)
(setenv "PLAYNET_MAIL_DIR" (string-append tmp "/mail"))

(use-modules (playnet test harness)
             (playnet test keri-identity)
             (playnet keri signify-portable)
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes))
             ((playnet governance credentials)
              #:select (make-device-authorization-credential cred-said cred-claims
                        cred-signature cred-schema cred-issuer cred-holder))
             ((playnet planner knowledge law product) #:select (product-feature feature-doors))
             (playnet gateway device-registry)
             (playnet gateway forget)
             (playnet gateway presence)
             (playnet gateway mailbox)
             (playnet gateway lobby)
             (playnet push store)
             (playnet notify recipient)
             ((playnet gateway contact-points) #:select (make-contact-point-desk))
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (json)
             (ice-9 format)
             (srfi srfi-1))

(device-registry-dir tmp)
(mkdir (string-append tmp "/mail"))
(mkdir (string-append tmp "/cards"))

;; ── the gateway's real stores, in the vat the lobby will share ─────────────
(define gateway-vat (spawn-vat #:name "gateway"))
(define durable-seen 'untold)          ; the keeper hears every durable snapshot
(define presence    (with-vat gateway-vat (spawn ^presence (hashmap))))
(define push-store  (with-vat gateway-vat (spawn ^push-subscription-store '())))
(define registry    (with-vat gateway-vat
                      (spawn ^recipient-registry '() (lambda (t) (set! durable-seen t)))))
(define mailbox-mgr (with-vat gateway-vat (spawn ^mailbox-manager (hashmap))))
(define desk (make-contact-point-desk `((email . ,(lambda (ctx title body) #t)))))

(define bran "forget-me-passcode-21chars")
(define-values (kp0 kp1 icp-json icp-said icp-alist aid icp-sigs)
  (test-identity bran))
(define-values (_gv signup-vat signup-agent oobi-host lobby settle)
  (lobby-fixture #:gateway-vat gateway-vat #:presence presence #:mailbox-mgr mailbox-mgr
                 #:push-store push-store #:recipient-registry registry
                 #:contact-desk desk))

(define (sign-nonce nonce kp) (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp)))
(define (root-auth)
  (let ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid))))
    (settle (with-vat gateway-vat ($ lobby 'keri-authenticate aid (sign-nonce nonce kp0) nonce)))))
(define (session-of r) (and (pair? r) (eq? 'ok (car r)) (cadr r)))
(define (err-with? r what)
  (and (pair? r) (eq? 'error (car r)) (string? (cadr r)) (string-contains (cadr r) what)))
(define (dropped receipt kind) (assq-ref (assq-ref receipt 'dropped) kind))

;; a device, as test-device-auth makes one
(define (device-keypair) (seed->ed25519-keypair (keri-crypto-random-bytes 32)))
(define (device-aid kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))
(define (cred->wire cred)
  (scm->json-string
   `(("said" . ,(cred-said cred)) ("schema" . ,(cred-schema cred))
     ("issuer" . ,(cred-issuer cred)) ("holder" . ,(cred-holder cred))
     ("claims" . ,(map (lambda (kv) (cons (symbol->string (car kv))
                                          (if (eq? (cdr kv) #f) 'null (cdr kv))))
                       (cred-claims cred)))
     ("sig" . ,(cred-signature cred)))))
(define laptop (device-keypair))
(define laptop-wire
  (cred->wire (make-device-authorization-credential
               aid (device-aid laptop) "laptop" "software" 1700000000 #:signing-keypair kp0)))
(define (device-auth)
  (let ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid))))
    (settle (with-vat gateway-vat
              ($ lobby 'keri-authenticate-device aid laptop-wire (sign-nonce nonce laptop) nonce)))))

(define aid16 (substring aid 0 16))
(define (user-file kind) (string-append tmp "/" kind "-" aid16 ".scm"))
(define %kinds '("contacts" "credentials" "taxonomy" "log" "pins" "allotment" "shamir"))
(define (write-file! path text)
  (call-with-output-file path (lambda (p) (display text p))))
(define other "EOTHERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define third "ETHIRDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define (card-file to from) (string-append tmp "/cards/" to "." from ".card"))
(define email "alice@example.org")
(define sub-json "{\"endpoint\":\"https://push.example/x\",\"keys\":{\"p256dh\":\"a\",\"auth\":\"b\"}}")

(format #t "~%=== a member with everything a gateway holds ===~%")
(check "witness-kel" (eq? 'ok (settle (with-vat gateway-vat
                                        ($ lobby 'witness-kel aid icp-alist icp-sigs (vector))))))
(check "join" (eq? 'ok (settle (with-vat gateway-vat ($ lobby 'join "" "" aid)))))
(define root (session-of (root-auth)))
(check "root session" (and root #t))
(define inbox (with-vat gateway-vat (spawn (lambda (_bcom) (lambda _ #t)))))
(with-vat gateway-vat ($ root 'announce "Alice" inbox))
(check "present" (let ((users (with-vat gateway-vat ($ presence 'online-users))))
                   (and (list? users) (member "Alice" users) #t)))
(check "push bound" (eq? 'ok (with-vat gateway-vat ($ root 'register-push "dev1" sub-json))))
(with-vat gateway-vat ($ registry 'bind aid 'email email 'rich))
(check "the keeper heard the email binding"
       (and (pair? durable-seen) (assoc aid durable-seen) #t))
(check "a point waits at the desk" (eq? 'pending (desk 'present aid 'email email 'rich)))
(write-file! (string-append tmp "/mail/1-1.eml") (string-append "To: " email "\nSubject: s\n\nbody\n"))
(write-file! (string-append tmp "/mail/1-2.eml") "To: someone@else.org\nSubject: s\n\nbody\n")
(check "the root enrolls a device"
       (eq? 'ok (with-vat gateway-vat ($ root 'enroll-device laptop-wire))))
(define dev (session-of (device-auth)))
(check "device session" (and dev #t))
(for-each (lambda (f) (write-file! f "sealed")) (list (card-file aid other) (card-file other aid) (card-file other third)))
(for-each (lambda (k) (write-file! (user-file k) "(stuff)\n")) %kinds)
(define mb (with-vat gateway-vat ($ mailbox-mgr 'get-or-create aid)))
(with-vat gateway-vat ($ mb 'deliver "bob" "hello"))
(check "the manager kept the mailbox it made"
       (eq? mb (with-vat gateway-vat ($ mailbox-mgr 'get-or-create aid))))

(format #t "~%=== a device cannot forget its person ===~%")
(check "device-tier forget-me refused, naming the passcode"
       (err-with? (with-vat gateway-vat ($ dev 'forget-me)) "passcode"))
(check "…and nothing went" (file-exists? (user-file "pins")))

(format #t "~%=== forget-me, from the root ===~%")
(define receipt (settle (with-vat gateway-vat ($ root 'forget-me))))
(check "a receipt came back" (and (pair? receipt) (assq 'dropped receipt) #t))
(check "member record went"        (equal? 1 (dropped receipt 'member)))
(check "three bindings went"       (equal? 3 (dropped receipt 'bindings)))
(check "one push subscription"     (equal? 1 (dropped receipt 'push)))
(check "one point at the desk"     (equal? 1 (dropped receipt 'contact-points)))
(check "one device"                (equal? 1 (dropped receipt 'devices)))
(check "two cards"                 (equal? 2 (dropped receipt 'cards)))
(check "every user file"           (equal? (length %kinds) (dropped receipt 'files)))
(check "the mailbox, one message"  (equal? 1 (dropped receipt 'mailbox)))
(check "one spooled mail"          (equal? 1 (dropped receipt 'mail)))
(check "what stays is named"       (memq 'key-log (assq-ref receipt 'kept)))

(format #t "~%=== every store is empty of them ===~%")
(check "no seat" (not (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))
(check "no handle for the AID"
       (not (settle (with-vat gateway-vat (<- signup-agent 'lookup-aid aid)))))
(check "registry does not know them" (not (with-vat gateway-vat ($ registry 'known? aid))))
(check "the keeper heard the row go" (and (list? durable-seen) (not (assoc aid durable-seen))))
(check "no push subscription" (= 0 (with-vat gateway-vat ($ push-store 'count))))
(check "not present" (not (member "Alice" (with-vat gateway-vat ($ presence 'online-users)))))
(check "no device file" (null? (devices-of aid)))
(check "a device signature is nobody's" (null? (live-device-keys aid (current-time))))
(check "no point at the desk" (null? (desk 'pending aid)))
(check "their cards went, the stranger's stayed"
       (and (not (file-exists? (card-file aid other))) (not (file-exists? (card-file other aid)))
            (file-exists? (card-file other third))))
(check "no user file" (not (any (lambda (k) (file-exists? (user-file k))) %kinds)))
(check "their mail went, the other's stayed"
       (and (not (file-exists? (string-append tmp "/mail/1-1.eml")))
            (file-exists? (string-append tmp "/mail/1-2.eml"))))
(check "the mailbox is gone from the manager"
       (not (eq? mb (with-vat gateway-vat ($ mailbox-mgr 'get-or-create aid)))))
(check "the old cap refuses" (err-with? (with-vat gateway-vat ($ root 'whoami)) "forgotten"))
(check "the device is refused at the door as never enrolled" (err-with? (device-auth) "enrolled"))

(format #t "~%=== the key log stands: data about a pseudonym ===~%")
(check "the oobi-host still serves the log" (with-vat gateway-vat ($ oobi-host 'known? aid)))
;; forget reaches no ledger by construction: the module imports nothing of
;; the planner, the governance stores, the observation log or the KERI stores
(check "forget.scm imports no planner, governance, observation or KERI-store module"
       (every (lambda (m)
                (let ((name (module-name m)))
                  (not (and (pair? name) (>= (length name) 2) (eq? 'playnet (car name))
                            (memq (cadr name) '(planner governance keri observation))))))
              (module-uses (resolve-module '(playnet gateway forget)))))
(check "the pseudonym can take a seat again"
       (eq? 'ok (settle (with-vat gateway-vat ($ lobby 'join "" "" aid)))))
(check "the product feature erasure names exactly this door"
       (equal? (feature-doors (product-feature 'erasure)) '((session . forget-me))))

(format #t "~%=== idempotent ===~%")
(define (forget-again)
  (settle (with-vat gateway-vat
            (forget-member! aid #:signup-agent signup-agent #:registry registry
                            #:push-store push-store #:presence presence #:desk desk
                            #:mailbox-mgr mailbox-mgr
                            #:user-files (map user-file %kinds)
                            #:cards-dir (string-append tmp "/cards")
                            #:mail-dir (string-append tmp "/mail")))))
(define again (forget-again))
(check "the seat just taken goes" (equal? 1 (dropped again 'member)))
(check "everything else is zero"
       (every (lambda (k) (equal? 0 (dropped again k)))
              '(bindings push contact-points devices cards files mailbox mail)))
(check "a third time, all zeros" (equal? 0 (dropped (forget-again) 'member)))

(format #t "~%=== retiring the identity: a rotation naming no next key ===~%")
(define-values (rot-json rot-said rot-alist)
  (build-rot aid (assoc-ref icp-alist "d")
             #:keys (list (keypair->aid-prefix kp1)) #:nkeys '() #:nsith 0 #:sn 1))
(check "the terminal rotation is witnessed"
       (eq? 'ok (settle (with-vat gateway-vat
                          ($ lobby 'witness-kel aid icp-alist icp-sigs
                             (vector (cons rot-alist (vector (sign-event rot-json kp1)))))))))
(define kp2 (bran->rotation-keypair bran 2))
(define-values (rot2-json rot2-said rot2-alist)
  (build-rot aid rot-said #:keys (list (keypair->aid-prefix kp2))
             #:nkeys (list (next-key-digest (ed25519-keypair-public kp2))) #:sn 2))
(check "no rotation follows it"
       (err-with? (settle (with-vat gateway-vat
                            ($ lobby 'witness-kel aid icp-alist icp-sigs
                               (vector (cons rot-alist (vector (sign-event rot-json kp1)))
                                       (cons rot2-alist (vector (sign-event rot2-json kp2)))))))
                  "next-key digest"))

(test-summary!)
