;;; tests/gateway/test-contact-binding.scm — contact points on ^lobby-session
;;;
;;; How a commune comes to hold a way to reach a person: the person presents
;;; their own contact-point credential, the commune sends a code to the
;;; address itself, and the code said back binds the channel.
;;;
;;; What this pins:
;;;   • what binds is a credential the presenter issued and signed: an
;;;     unsigned one, one issued by someone else, one whose content was
;;;     changed, and one of a kind a commune is never told are each refused;
;;;   • nothing is bound until the address answers with the code, a wrong
;;;     code is refused, and codes are rationed per person;
;;;   • a session binds, lists and drops ONLY its own AID's channels — the AID
;;;     is closed over, so notifications cannot be redirected to another party;
;;;   • `withdraw-contact-point` really removes it (a working erasure path);
;;;   • a commune that delivers on no channel binds none;
;;;   • the registry tells its keeper each durable change, and a registry
;;;     seeded from what the keeper wrote holds the same channels;
;;;   • the catalogue of reach kinds, the registry's durable kinds and the
;;;     credential's kinds agree.
;;;
;;; NOTE ON TURNS: the session reaches the registry with `<-np` (the registry
;;; may live in another vat), so a bind is NOT visible to a synchronous read in
;;; the same turn. Every assertion therefore runs in a LATER `with-vat` block
;;; than the mutation it checks — that is what flushes the queue.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-contact-binding.scm

(use-modules (playnet test harness)
             (playnet gateway lobby)
             (playnet identity contact-points)
             ((playnet notify recipient)
              #:select (^recipient-registry binding-kind binding-ctx binding-style
                        durable-kind? recipient-table->datum datum->recipient-table))
             ((playnet keri first-person credentials)
              #:select (make-contact-point-credential *contact-point-kinds*))
             ((playnet identity reach-kinds)
              #:select (commune-reach-kinds reach-value-fault))
             ((playnet keri acdc) #:select (cred-said cred-issuer cred-holder cred-claims cred-signature))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             ((playnet keri signify-portable) #:select (scm->json-canonical))
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             ((srfi srfi-1) #:select (find every lset=)))

(define alice-id (make-keri-identity))
(define bob-id   (make-keri-identity))
(define %alice (keri-identity-aid alice-id))
(define %bob   (keri-identity-aid bob-id))

;; the wire a browser sends: the credential's own fields, and the signature
(define* (wire-of id kind ctx #:key (signer id) (style 'rich) (said #f) (sign? #t))
  (let* ((cred (make-contact-point-credential (keri-identity-aid id) kind ctx
                                              #:style style #:issued-at "2026-10-02T09:00:00Z"))
         (claim (lambda (k) (assq-ref (cred-claims cred) k))))
    (scm->json-canonical
     `(("said" . ,(or said (cred-said cred)))
       ("issuer" . ,(cred-issuer cred)) ("holder" . ,(cred-holder cred))
       ("claims" . (("u" . ,(claim 'u)) ("kind" . ,(symbol->string kind)) ("ctx" . ,ctx)
                    ("style" . ,(symbol->string style)) ("issued-at" . ,(claim 'issued-at))
                    ("expires-at" . null)))
       ,@(if sign? `(("sig" . ,(sign-said (cred-said cred) (keri-identity-keypair signer)))) '())))))

;; the desk's channel: what it sends is kept, so a test reads the code
(define sent '())
(define clock 1000)
(define (code-in body)
  (let loop ((i 0))
    (cond ((> (+ i 6) (string-length body)) #f)
          ((string-every char-numeric? (substring body i (+ i 6))) (substring body i (+ i 6)))
          (else (loop (+ i 1))))))
(define desk
  (make-contact-point-desk
   `((email . ,(lambda (ctx title body) (set! sent (cons (cons ctx (code-in body)) sent)))))
   #:now (lambda () clock)))
(define (code-for ctx) (assoc-ref sent ctx))

;; ^lobby-session takes a long positional tail; everything except the
;; recipient-registry and the desk is irrelevant here, so stub it all out.
(define (spawn-session aid registry desk)
  (spawn ^lobby-session aid
         #f #f #f #f          ; terminal, mailbox, governance, signup-agent
         #f #f #f #f #f       ; oobi-host, acdc-store, folksonomy, presence, push
         registry
         #f 'root #f #f #f    ; planner, tier, pins, doors, ai
         desk))

(define vat (spawn-vat))
(define kept #f)             ; what the registry last told its keeper
(define registry #f)
(define alice #f)
(define bob #f)

(with-vat vat
  (set! registry (spawn ^recipient-registry '() (lambda (t) (set! kept (recipient-table->datum t)))))
  (set! alice    (spawn-session %alice registry desk))
  (set! bob      (spawn-session %bob   registry desk)))

(define (bindings-of aid) (with-vat vat ($ registry 'bindings-for aid)))
(define (kind-of aid k) (find (lambda (b) (eq? k (binding-kind b))) (bindings-of aid)))
(define (ask session . msg) (with-vat vat (apply $ session msg)))
(define (points session) (assq-ref (ask session 'my-contact-points) 'points))
(define (refused? r) (and (pair? r) (eq? 'error (car r)) (string? (cdr r))))


(display "\n── 1. Presenting: the credential is the person's own ──\n")

(check "the commune says which kinds it delivers on"
       (assq-ref (ask alice 'my-contact-points) 'delivers) '(email))
(check "presenting a signed email point leaves it pending"
       (ask alice 'present-contact-point (wire-of alice-id 'email "alice@example.org"))
       '(ok . pending))
(check "nothing is bound while the code is on its way" (kind-of %alice 'email) #f)
(check "the point reads as pending" (points alice) '((email "alice@example.org" pending)))
(check "a code went to the address itself" (and (string? (code-for "alice@example.org")) #t))
(check "an unsigned point is refused"
       (refused? (ask alice 'present-contact-point (wire-of alice-id 'email "a2@example.org" #:sign? #f))))
(check "a point signed by someone else is refused"
       (refused? (ask alice 'present-contact-point (wire-of alice-id 'email "a3@example.org" #:signer bob-id))))
(check "Bob cannot present Alice's point as his"
       (refused? (ask bob 'present-contact-point (wire-of alice-id 'email "alice@example.org"))))
(check "a point whose identifier does not match its content is refused"
       (refused? (ask alice 'present-contact-point
                      (wire-of alice-id 'email "a4@example.org" #:said "EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))))
(check "a kind a commune is never told is refused"
       (refused? (ask alice 'present-contact-point (wire-of alice-id 'push "device-7"))))
(check "an address that would end a mail header is refused"
       (refused? (ask alice 'present-contact-point (wire-of alice-id 'email "a@example.org\nBcc: x@example.org"))))
(check "a kind this commune does not deliver on is refused"
       (refused? (ask alice 'present-contact-point (wire-of alice-id 'matrix "@alice:example.org"))))
(check "what is not JSON is refused" (refused? (ask alice 'present-contact-point "not json")))


(display "\n── 2. Confirming: the address answers ──\n")

(check "a wrong code is refused"
       (refused? (ask alice 'confirm-contact-point 'email "alice@example.org" "000000x")))
(check "Bob cannot confirm Alice's point, even with her code"
       (refused? (ask bob 'confirm-contact-point 'email "alice@example.org" (code-for "alice@example.org"))))
(check "the code binds it"
       (ask alice 'confirm-contact-point 'email "alice@example.org" (code-for "alice@example.org"))
       '(ok . #t))
(check "it reaches the registry under the session's AID, in the style the credential states"
       (let ((b (kind-of %alice 'email)))
         (and b (list (binding-ctx b) (binding-style b))))
       '("alice@example.org" rich))
(check "the point reads as bound" (points alice) '((email "alice@example.org" bound)))
(check "the registry told its keeper" kept `((,%alice (email "alice@example.org" rich))))
(check "a code is spent once"
       (refused? (ask alice 'confirm-contact-point 'email "alice@example.org" (code-for "alice@example.org"))))


(display "\n── 3. Codes are rationed, and lapse ──\n")

(ask bob 'present-contact-point (wire-of bob-id 'email "bob@example.org"))
(set! clock (+ clock %confirm-ttl 1))
(check "a lapsed code is refused"
       (refused? (ask bob 'confirm-contact-point 'email "bob@example.org" (code-for "bob@example.org"))))
(check "…and the lapsed point is no longer pending" (points bob) '())
(set! clock (+ clock %confirm-window))
(for-each (lambda (n) (ask bob 'present-contact-point
                           (wire-of bob-id 'email (format #f "bob~a@example.org" n))))
          '(1 2 3))
(check "a person is sent only so many codes in a window"
       (refused? (ask bob 'present-contact-point (wire-of bob-id 'email "bob4@example.org"))))
(for-each (lambda (n) (ask bob 'confirm-contact-point 'email "bob1@example.org" "nope"))
          '(1 2 3 4 5))
(check "too many wrong codes put the point down"
       (refused? (ask bob 'confirm-contact-point 'email "bob1@example.org" (code-for "bob1@example.org"))))
(check "Bob confirms another of his"
       (ask bob 'confirm-contact-point 'email "bob2@example.org" (code-for "bob2@example.org"))
       '(ok . #t))


(display "\n── 4. Isolation and erasure ──\n")

(check "Bob's withdrawal of Alice's address leaves hers standing"
       (begin (ask bob 'withdraw-contact-point 'email "alice@example.org")
              (and (kind-of %alice 'email) #t)))
(check "Alice withdraws hers" (ask alice 'withdraw-contact-point 'email "alice@example.org") '(ok . #t))
(check "it is gone from the registry" (kind-of %alice 'email) #f)
(check "…and from what the keeper holds" (assoc %alice kept) #f)
(check "withdrawing a pending point puts it down"
       (begin (ask bob 'withdraw-contact-point 'email "bob3@example.org")
              (points bob))
       '((email "bob2@example.org" bound)))


(display "\n── 5. Live kinds stay out; a commune with no channel binds none ──\n")

(with-vat vat ($ registry 'bind %alice 'push "device-7" 'terse))
(check "a push binding is live state, outside the person's points" (points alice) '())
(define bare #f)
(with-vat vat (set! bare (spawn-session %alice registry (make-contact-point-desk '()))))
(check "a commune that delivers on nothing refuses every point"
       (refused? (ask bare 'present-contact-point (wire-of alice-id 'email "alice@example.org"))))
(define deskless #f)
(with-vat vat (set! deskless (spawn-session %alice registry #f)))
(check "…and so does a session with no desk"
       (refused? (ask deskless 'present-contact-point (wire-of alice-id 'email "alice@example.org"))))


(display "\n── 6. What the keeper wrote seeds the next boot ──\n")

(define reborn #f)
(with-vat vat (set! reborn (spawn ^recipient-registry (datum->recipient-table kept))))
(check "the reborn registry holds Bob's confirmed address"
       (map (lambda (b) (list (binding-kind b) (binding-ctx b) (binding-style b)))
            (with-vat vat ($ reborn 'bindings-for %bob)))
       '((email "bob2@example.org" rich)))
(check "a malformed datum seeds nothing"
       (datum->recipient-table '(("EX" (carrier-pigeon "loft" terse)) nonsense ("EY" (email 7 terse)))) '())


(display "\n── 7. One vocabulary ──\n")

(check "the kinds a commune may be told are the registry's durable kinds"
       (every durable-kind? (commune-reach-kinds)))
(check "…and each is a kind the credential carries"
       (every (lambda (k) (and (memq k *contact-point-kinds*) #t)) (commune-reach-kinds)))
(check "the credential's other kinds are the live ones"
       (lset= eq? (filter (lambda (k) (not (durable-kind? k))) *contact-point-kinds*) '(push browser)))
(check "an email's shape is read" 
       (list (reach-value-fault 'email "a@b.org") (and (reach-value-fault 'email "a b@c.org") #t)
             (and (reach-value-fault 'email "nobody") #t) (and (reach-value-fault 'email "a@b") #t)
             (and (reach-value-fault 'carrier-pigeon "loft") #t))
       '(#f #t #t #t #t))

(test-summary!)
