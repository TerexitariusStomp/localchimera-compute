;;; tests/gateway/test-body-doors.scm — the body doors on ^lobby-session
;;;
;;; A legal body is declared by a recognised person, stewarded by the people
;;; it names, incepted by k of them signing from their own seats, read whole
;;; by its stewards and members, and admitted by a governor
;;; (identity/body-doors.scm). The backend is a stub body service that
;;; records every call, so what this pins is the DOORS' own conduct:
;;;   • a person without a live personhood credential cannot declare;
;;;   • a declaration makes its caller the first steward, under a provisional id;
;;;   • only a steward adds a steward, opens the ceremony, presents a holding;
;;;   • a signature that is not the caller's own is refused; below k nothing
;;;     publishes; at k the ceremony reports the AID;
;;;   • the read is one alist with the body's stewards, holdings and findings,
;;;     open to stewards and members alone;
;;;   • admission is a governor's act; `my-bodies` lists only the caller's.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-body-doors.scm

(use-modules (playnet test harness)
             (playnet gateway lobby)
             ((playnet identity body-doors) #:select (current-body-service provisional-body-id))
             ((playnet planner vf schemas) #:select (make-agent agent-id agent-name agent-classified-as))
             ((playnet openvtc credentials) #:select (make-personhood-credential))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said verify-said-signature))
             (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             ((srfi srfi-1) #:select (find filter-map)))

(define alice-id (make-keri-identity))
(define bob-id   (make-keri-identity))
(define carol-id (make-keri-identity))
(define %alice (keri-identity-aid alice-id))
(define %bob   (keri-identity-aid bob-id))
(define %carol (keri-identity-aid carol-id))
(define %scope "EScopeAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define %eco   "EEcosystemAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define %group-aid "EGroupBodyAIDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

;;; ── the stubs ─────────────────────────────────────────────────────────────
;; the credential store: Alice and Bob are recognised persons, Carol is not
(define phcs (list (make-personhood-credential %eco %alice 1700000000)
                   (make-personhood-credential %eco %bob 1700000000)))
(define (^acdc-store bcom)
  (methods
   ((by-schema schema) phcs)
   ((by-holder aid) (filter (lambda (c) #t) '()))))

;; governance: Alice is a governor, nobody else
(define (^governance bcom)
  (methods
   ((fp-status aid scope-id)
    (cons 'ok (list (cons 'person #t) (cons 'scope scope-id)
                    (cons 'governor (equal? aid %alice)))))))

;; the ceremony: k signatures publish; one per steward counts
(define (^ceremony bcom k said)
  (define signed '())
  (define published #f)
  (methods
   ((preimage) `((what . "inception") (said . ,said) (fields . ())))
   ((sign aid sig)
    (unless (member aid signed) (set! signed (cons aid signed)))
    (when (and (>= (length signed) k) (not published)) (set! published %group-aid))
    `((have . ,(length signed)) (need . ,k) (published . ,published)))
   ((status) `((what . inception) (have . ,(length signed)) (need . ,k) (published . ,published)))))

;; the body service: tables, the stewardship gate read here as the real one
;; reads it on the records (planner/doors/bodies.scm), and every call recorded
(define calls '())
(define bodies '())        ; (id . agent)
(define scopes '())        ; (id . scope-id)
(define stewards '())      ; (id . aids)
(define members '())       ; (id . aids)
(define holdings '())      ; (id . rows)
(define ceremonies '())    ; (id . actor)
(define (record! op . args) (set! calls (cons (cons op args) calls)))
(define (put! table-get table-set! id v)
  (table-set! (cons (cons id v) (filter (lambda (p) (not (equal? (car p) id))) (table-get)))))
(define (ok x) (cons 'ok x))
(define (fail m) (cons 'error m))
(define (stewards-of id) (or (assoc-ref stewards id) '()))
(define (steward? id aid) (and (member aid (stewards-of id)) #t))
(define (standing cer) (and cer (let ((st ($ cer 'status)))
                                  `(("have" . ,(assq-ref st 'have)) ("need" . ,(assq-ref st 'need))
                                    ("published" . ,(assq-ref st 'published)) ("what" . "inception")))))
(define (as-steward aid id thunk)
  (cond ((not (assoc-ref bodies id)) (fail "no such body"))
        ((not (steward? id aid)) (fail "only a steward of the body acts for it"))
        (else (thunk))))
(define (body->wire b)
  `(("id" . ,(agent-id b)) ("name" . ,(agent-name b))
    ("tags" . ,(list->vector (agent-classified-as b)))))
(define (body-service op . args)
  (apply record! op args)
  (case op
    ((declare!)
     (let* ((aid (list-ref args 0)) (scope-id (list-ref args 1)) (id (list-ref args 2))
            (name (list-ref args 3)) (alist (list-ref args 4))
            (b (or (assoc-ref bodies id)
                   (make-agent #:id id #:type 'organization #:name name
                               #:classified-as (list "body" (string-append "kind:" (assq-ref alist 'kind)))))))
       (put! (lambda () bodies) (lambda (t) (set! bodies t)) id b)
       (put! (lambda () scopes) (lambda (t) (set! scopes t)) id scope-id)
       (unless (steward? id aid)
         (put! (lambda () stewards) (lambda (t) (set! stewards t)) id (cons aid (stewards-of id))))
       (ok (body->wire b))))
    ((add-steward!)
     (let ((aid (list-ref args 0)) (id (list-ref args 1)) (who (list-ref args 2)))
       (as-steward aid id
         (lambda ()
           (unless (steward? id who)
             (put! (lambda () stewards) (lambda (t) (set! stewards t)) id (cons who (stewards-of id))))
           (ok #t)))))
    ((stewards) (stewards-of (car args)))
    ((open-ceremony!)
     (let ((aid (list-ref args 0)) (id (list-ref args 1)) (k (list-ref args 2)))
       (as-steward aid id
         (lambda ()
           (cond ((> k (length (stewards-of id))) (fail "k cannot exceed the stewards"))
                 ((assoc-ref ceremonies id) (fail "a ceremony is already open"))
                 (else
                  (let ((cer (spawn ^ceremony k "ESaidOfTheInceptionAAAAAAAAAAAAAAAAAAAAAAAA")))
                    (put! (lambda () ceremonies) (lambda (t) (set! ceremonies t)) id cer)
                    (ok (standing cer)))))))))
    ((preimage)
     (let ((aid (list-ref args 0)) (id (list-ref args 1)) (what (list-ref args 2)))
       (as-steward aid id
         (lambda ()
           (let ((cer (assoc-ref ceremonies id)))
             (cond ((not cer) (fail "no ceremony is open for this body"))
                   ((not (equal? what "inception")) (fail "the ceremony is at inception"))
                   (else (ok `(("what" . "inception") ("said" . ,(assq-ref ($ cer 'preimage) 'said)))))))))))
    ((sign)
     (let ((aid (list-ref args 0)) (id (list-ref args 1)) (said (list-ref args 3)) (sig (list-ref args 4)))
       (as-steward aid id
         (lambda ()
           (let ((cer (assoc-ref ceremonies id)))
             (cond ((not cer) (fail "no ceremony is open for this body"))
                   ((not (equal? said (assq-ref ($ cer 'preimage) 'said))) (fail "that is not the statement open for signing"))
                   ((not (verify-said-signature said sig aid)) (fail "the signature is not yours"))
                   (else ($ cer 'sign aid sig) (ok (standing cer)))))))))
    ((present-holding!)
     (let* ((aid (list-ref args 0)) (id (list-ref args 1)) (kind (list-ref args 2)) (valid-until (list-ref args 5)))
       (as-steward aid id
         (lambda ()
           (let* ((rid (string-append "res:" kind))
                  (row `(("id" . ,rid) ("spec" . ,kind) ("name" . ,(or (list-ref args 3) kind))
                         ("validUntil" . ,(or valid-until #f))
                         ("status" . ,(if (and valid-until (string<? valid-until "2026")) "expired" "satisfied")))))
             (put! (lambda () holdings) (lambda (t) (set! holdings t)) id
                   (cons row (or (assoc-ref holdings id) '())))
             (ok rid))))))
    ((read)
     (let* ((aid (list-ref args 0)) (id (list-ref args 1)) (b (assoc-ref bodies id)))
       (cond ((not b) (fail "no such body"))
             ((not (or (steward? id aid) (member aid (or (assoc-ref members id) '()))))
              (fail "the body is read by its stewards and members"))
             (else
              (ok (append (body->wire b)
                          `(("stewards" . ,(list->vector (stewards-of id)))
                            ("members" . ,(list->vector (or (assoc-ref members id) '())))
                            ("crossings" . #("organise" "public-sale"))
                            ("holdings" . ,(list->vector (or (assoc-ref holdings id) '())))
                            ("findings" . #((("severity" . "warning") ("kind" . "selling") ("subject" . ,id) ("detail" . "sells bread"))))
                            ("exposure" . (("stance" . "notice")))
                            ("ceremony" . ,(standing (assoc-ref ceremonies id))))))))))
    ((list)
     (let ((aid (list-ref args 0)))
       (ok (list->vector
            (filter-map (lambda (p)
                          (and (steward? (car p) aid)
                               (append (body->wire (cdr p))
                                       `(("steward" . #t)
                                         ("ceremony" . ,(standing (assoc-ref ceremonies (car p))))))))
                        bodies)))))
    ((admit!) (ok #((("severity" . "info") ("kind" . "admitted") ("subject" . ,(list-ref args 2)) ("detail" . "admitted")))))
    (else (error "stub: no such op" op))))

(current-body-service body-service)

(define vat (spawn-vat))
(define store #f) (define gov #f)
(define alice #f) (define bob #f) (define carol #f)
(define (spawn-session aid)
  (spawn ^lobby-session aid
         #f #f gov #f           ; terminal, mailbox, governance, signup-agent
         #f store #f #f #f #f   ; oobi-host, acdc-store, folksonomy, presence, push, registry
         #f 'device #f #f #f #f))
(with-vat vat
  (set! store (spawn ^acdc-store))
  (set! gov   (spawn ^governance))
  (set! alice (spawn-session %alice))
  (set! bob   (spawn-session %bob))
  (set! carol (spawn-session %carol)))

(define (ask session . msg) (with-vat vat (apply $ session msg)))
(define (ask-promise session . msg)
  "A door that answers a promise: its settled value."
  (let ((got (list 'unsettled)))
    (with-vat vat (on (apply $ session msg) (lambda (r) (set! got r)) #:catch (lambda (e) (set! got (cons 'error e)))))
    (with-vat vat #t)
    got))
(define (refused? r) (and (pair? r) (eq? 'error (car r)) (string? (cdr r))))
(define (ok? r) (and (pair? r) (eq? 'ok (car r))))
(define (called? op) (and (find (lambda (c) (eq? (car c) op)) calls) #t))
(define (wire-ref r key) (and (ok? r) (list? (cdr r)) (assoc-ref (cdr r) key)))

(define body-json "{\"name\":\"Le Four Commun\",\"kind\":\"association\",\"role\":\"provider\",\"jurisdiction\":\"fr\",\"assetLock\":true,\"register\":\"inspectable\"}")


(display "\n── 1. Declaring takes a recognised person ──\n")

(check "Carol, unrecognised, cannot declare a body"
       (refused? (ask carol 'declare-body %scope body-json)))
(check "the stub was never asked to declare for her" (not (called? 'declare!)))
(check "what is not JSON is refused" (refused? (ask alice 'declare-body %scope "not json")))
(check "a body without a name is refused" (refused? (ask alice 'declare-body %scope "{\"kind\":\"x\"}")))
(define declared (ask alice 'declare-body %scope body-json))
(check "Alice declares the body" (ok? declared))
(define %body (wire-ref declared "id"))
(check "its id is the provisional one, from name, scope and initiator"
       %body (provisional-body-id "Le Four Commun" %scope %alice))
(check "the declaration carries the name" (wire-ref declared "name") "Le Four Commun")
(check "the tags cross as a vector" (vector? (wire-ref declared "tags")))
(check "the declarer is the first steward" (body-service 'stewards %body) (list %alice))
(check "the record went to the service with the alist's keys"
       (let ((c (find (lambda (c) (eq? (car c) 'declare!)) calls)))
         (and c (equal? (map car (list-ref c 5)) '(kind role jurisdiction asset-lock register quorum))
              (eq? #t (assq-ref (list-ref c 5) 'asset-lock))
              (eq? 'inspectable (assq-ref (list-ref c 5) 'register)))))


(display "\n── 2. Stewards: only a steward names one ──\n")

(check "Bob, no steward, cannot add himself" (refused? (ask bob 'body-add-steward %body %bob)))
(check "a body nobody declared is refused" (refused? (ask alice 'body-add-steward "body:nope" %bob)))
(check "Alice names Bob a steward" (ask alice 'body-add-steward %body %bob) '(ok . #t))
(check "the stewards are now both" (and (member %bob (body-service 'stewards %body)) #t))
(check "naming a steward twice is idempotent" (ask alice 'body-add-steward %body %bob) '(ok . #t))
(check "Bob cannot open a ceremony for 3 of 2" (refused? (ask bob 'body-open-ceremony %body 3)))
(check "Carol cannot open the ceremony" (refused? (ask carol 'body-open-ceremony %body 2)))


(display "\n── 3. The inception: k of n sign from their own seats ──\n")

(define opened (ask bob 'body-open-ceremony %body 2))
(check "Bob, a steward, opens the ceremony at k=2" (ok? opened))
(check "it reports 0 of 2 signed" (and (equal? (wire-ref opened "have") 0) (equal? (wire-ref opened "need") 2)))
(check "a second opening is refused" (refused? (ask alice 'body-open-ceremony %body 2)))
(check "Carol cannot read the statement" (refused? (ask carol 'body-sign-preimage %body "inception")))
(check "a rotation is not what is open" (refused? (ask alice 'body-sign-preimage %body "rotation")))
(define pre (ask alice 'body-sign-preimage %body "inception"))
(check "a steward reads the statement" (ok? pre))
(define %said (wire-ref pre "said"))
(check "the statement is the ceremony's SAID" (string? %said))
(check "the kind may arrive as a symbol (the HTTP form)" (ok? (ask alice 'body-sign-preimage %body 'inception)))
(check "a signature by someone else is refused"
       (refused? (ask alice 'body-sign-signed %body "inception" %said (sign-said %said (keri-identity-keypair bob-id)))))
(check "a signature over another statement is refused"
       (refused? (ask alice 'body-sign-signed %body "inception" "EOtherAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                      (sign-said "EOtherAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" (keri-identity-keypair alice-id)))))
(define one (ask alice 'body-sign-signed %body "inception" %said (sign-said %said (keri-identity-keypair alice-id))))
(check "Alice's own signature counts" (ok? one))
(check "1 of 2: nothing published" (and (equal? (wire-ref one "have") 1) (not (wire-ref one "published"))))
(check "Carol's signature does not count" (refused? (ask carol 'body-sign-signed %body "inception" %said (sign-said %said (keri-identity-keypair carol-id)))))
(define two (ask bob 'body-sign-signed %body "inception" %said (sign-said %said (keri-identity-keypair bob-id))))
(check "Bob's signature reaches k" (equal? (wire-ref two "have") 2))
(check "at k the AID is published" (wire-ref two "published") %group-aid)


(display "\n── 4. Holdings, the read and admission ──\n")

(check "Carol cannot present a holding" (refused? (ask carol 'body-present-holding %body "{\"kind\":\"fr/rc-auto\"}")))
(check "a holding without a kind is refused" (refused? (ask alice 'body-present-holding %body "{\"name\":\"x\"}")))
(check "a steward presents a policy"
       (ask alice 'body-present-holding %body "{\"kind\":\"fr/rc-auto\",\"name\":\"RC auto\",\"issuer\":\"MAIF\",\"validUntil\":\"2025-01-01\"}")
       '(ok . "res:fr/rc-auto"))
(check "Carol cannot read the body" (refused? (ask carol 'body %body)))
(define read (ask bob 'body %body))
(check "a steward reads the body whole" (ok? read))
(check "the stewards are in it" (and (vector? (wire-ref read "stewards")) (= 2 (vector-length (wire-ref read "stewards")))))
(check "the holding carries the law's status"
       (let ((hs (wire-ref read "holdings")))
         (and (vector? hs) (= 1 (vector-length hs))
              (equal? "expired" (assoc-ref (vector-ref hs 0) "status")))))
(check "the findings cross on the wire"
       (let ((fs (wire-ref read "findings")))
         (and (vector? fs) (= 1 (vector-length fs))
              (equal? "warning" (assoc-ref (vector-ref fs 0) "severity"))
              (equal? "selling" (assoc-ref (vector-ref fs 0) "kind")))))
(check "the crossings cross as strings" (wire-ref read "crossings") #("organise" "public-sale"))
(check "the ceremony's standing is in the read" (wire-ref (cons 'ok (wire-ref read "ceremony")) "published") %group-aid)
(check "Bob, no governor, cannot admit" (refused? (ask-promise bob 'body-admit %scope %body)))
(check "the stub was not asked to admit" (not (called? 'admit!)))
(define admitted (ask-promise alice 'body-admit %scope %body))
(check "Alice, a governor, admits the body" (ok? admitted))
(check "the admission's findings come back"
       (and (vector? (cdr admitted)) (equal? "admitted" (assoc-ref (vector-ref (cdr admitted) 0) "kind"))))


(display "\n── 5. my-bodies lists only the caller's ──\n")

(define mine (ask alice 'my-bodies %scope))
(check "Alice sees the body she stewards" (and (ok? mine) (= 1 (vector-length (cdr mine)))))
(check "and that she stewards it" (eq? #t (assoc-ref (vector-ref (cdr mine) 0) "steward")))
(check "with the ceremony's standing" (equal? %group-aid (assoc-ref (assoc-ref (vector-ref (cdr mine) 0) "ceremony") "published")))
(check "Carol sees none" (ask carol 'my-bodies %scope) '(ok . #()))


(display "\n── 6. A commune that keeps no bodies ──\n")

(current-body-service #f)
(define none #f)
(with-vat vat (set! none (spawn-session %alice)))
(check "every door answers the absence" (refused? (ask none 'my-bodies %scope)))
(check "declaring too" (refused? (ask none 'declare-body %scope body-json)))

(test-summary!)
