;;; tests/doors/test-cards.scm — cards on ^lobby-session
;;;
;;; A card is how to reach one person, handed to another: sealed to the
;;; receiver, signed by the giver, kept by the commune as ciphertext.
;;;
;;; What this pins:
;;;   • a card is kept only when it is the caller's own, signed, whole, and
;;;     for someone in the caller's contacts;
;;;   • the receiver reads it, the giver reads when theirs was made, and a
;;;     third person reads nothing of it;
;;;   • a new card takes the place of the last, and a withdrawn card is gone
;;;     from the commune's disk;
;;;   • an identifier that is no identifier never reaches a file's name.
;;;
;;; Run: guile -L module -L tests tests/doors/test-cards.scm

(use-modules (playnet test harness)
             (playnet doors lobby)
             (playnet identity cards)
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-keypair keri-identity-aid sign-said))
             ((playnet keri signify-portable) #:select (scm->json-canonical))
             (goblins) (goblins vat) (goblins actor-lib methods)
             (ice-9 ftw)
             ((srfi srfi-1) #:select (find filter)))

(define data (string-append (or (getenv "TMPDIR") "/tmp") "/playnet-cards-test-" (number->string (getpid))))
(mkdir data)
(setenv "PLAYNET_DATA_DIR" data)

(define ana-id (make-keri-identity)) (define ben-id (make-keri-identity)) (define cy-id (make-keri-identity))
(define ANA (keri-identity-aid ana-id)) (define BEN (keri-identity-aid ben-id)) (define CY (keri-identity-aid cy-id))

(define* (wire-of from-id to sealed #:key (at "2026-10-02T10:00:00Z") (signer from-id) (said #f))
  (let* ((from (keri-identity-aid from-id))
         (id (card-said from to at sealed)))
    (scm->json-canonical
     `(("from" . ,from) ("to" . ,to) ("at" . ,at) ("sealed" . ,sealed)
       ("said" . ,(or said id)) ("sig" . ,(sign-said id (keri-identity-keypair signer)))))))

(define vat (spawn-vat))
(define (session aid)
  (with-vat vat (spawn ^lobby-session aid #f #f #f #f)))
(define ana (session ANA)) (define ben (session BEN)) (define cy (session CY))
(define (ask s . msg) (with-vat vat (apply $ s msg)))
(define (refused? r) (and (pair? r) (eq? 'error (car r)) (string? (cdr r))))
(define (book-of . aids) (map (lambda (a) `((alias . "x") (prefix . ,a))) aids))
(define (rows s) (cdr (ask s 'cards)))
(define (row s aid) (find (lambda (r) (equal? aid (assq-ref r 'aid))) (rows s)))
(define (card-files) (filter (lambda (f) (string-suffix? ".card" f))
                             (or (scandir (string-append data "/cards")) '())))

(ask ana 'sync-contacts (book-of BEN))
(ask ben 'sync-contacts (book-of ANA CY))
(ask cy  'sync-contacts (book-of ANA BEN))

(display "\n── giving ──\n")
(check "no cards stand at first" (rows ben) '())
(check "Ana gives Ben a card" (ask ana 'give-card BEN (wire-of ana-id BEN "c0ffee")) '(ok . #t))
(check "Ben reads the card Ana gave, as she sealed it"
       (let ((r (row ben ANA)))
         (list (assq-ref (card-wire->card (assq-ref r 'card)) 'sealed) (assq-ref r 'given)))
       '("c0ffee" #f))
(check "Ana reads when hers was made, and holds no card from Ben"
       (let ((r (row ana BEN))) (list (assq-ref r 'given) (assq-ref r 'card)))
       '("2026-10-02T10:00:00Z" #f))
(check "Cy, who knows both, reads nothing of it" (rows cy) '())

(display "\n── what is refused ──\n")
(check "a card for someone outside the giver's contacts"
       (refused? (ask ana 'give-card CY (wire-of ana-id CY "c0ffee"))))
(check "a card signed by someone else"
       (refused? (ask ana 'give-card BEN (wire-of ana-id BEN "beef" #:signer cy-id))))
(check "a card given in another's name"
       (refused? (ask cy 'give-card BEN (wire-of ana-id BEN "beef"))))
(check "a card whose content was changed after signing"
       (refused? (ask ana 'give-card BEN (wire-of ana-id BEN "beef" #:said (card-said ANA BEN "2026-10-02T10:00:00Z" "c0ffee")))))
(check "a card addressed to one person and handed to another"
       (refused? (ask ben 'give-card ANA (wire-of ben-id CY "beef"))))
(check "a card to oneself"
       (begin (ask ana 'sync-contacts (book-of BEN ANA))
              (refused? (ask ana 'give-card ANA (wire-of ana-id ANA "beef")))))
(check "content that is not sealed bytes"
       (refused? (ask ana 'give-card BEN (wire-of ana-id BEN "plain text"))))
(check "content past the size of a card"
       (refused? (ask ana 'give-card BEN (wire-of ana-id BEN (make-string (+ %card-max-sealed 2) #\a)))))
(check "what is not JSON" (refused? (ask ana 'give-card BEN "nope")))
(check "none of the refused cards took the place of the first"
       (assq-ref (card-wire->card (assq-ref (row ben ANA) 'card)) 'sealed) "c0ffee")

(display "\n── one card per pair; withdrawing erases ──\n")
(check "a new card takes the place of the last"
       (begin (ask ana 'give-card BEN (wire-of ana-id BEN "deadbeef" #:at "2026-10-03T10:00:00Z"))
              (list (assq-ref (card-wire->card (assq-ref (row ben ANA) 'card)) 'sealed)
                    (assq-ref (row ana BEN) 'given) (length (card-files))))
       '("deadbeef" "2026-10-03T10:00:00Z" 1))
(check "Ben gives one back; each reads the other's"
       (begin (ask ben 'give-card ANA (wire-of ben-id ANA "abcd"))
              (list (and (assq-ref (row ana BEN) 'card) #t) (and (assq-ref (row ben ANA) 'card) #t)
                    (length (card-files))))
       '(#t #t 2))
(check "Cy cannot withdraw Ana's card to Ben"
       (begin (ask cy 'withdraw-card BEN) (and (assq-ref (row ben ANA) 'card) #t)))
(check "Ana withdraws hers" (ask ana 'withdraw-card BEN) '(ok . #t))
(check "Ben no longer reads it, and still reads when his own was made"
       (let ((r (row ben ANA))) (list (assq-ref r 'card) (and (assq-ref r 'given) #t))) '(#f #t))
(check "the withdrawn card's file is gone from the commune's disk" (length (card-files)) 1)
(check "withdrawing where none stands is the same ok" (ask ana 'withdraw-card BEN) '(ok . #t))

(display "\n── an identifier is an identifier ──\n")
(check "a name that would leave the cards directory is no person"
       (list (person-aid? "../../etc/passwd") (person-aid? (string-append "E" (make-string 43 #\/)))
             (person-aid? ANA))
       '(#f #f #t))
(check "…and withdrawing by such a name is refused" (refused? (ask ana 'withdraw-card "../../x")))

(system* "rm" "-rf" data)
(test-summary!)
