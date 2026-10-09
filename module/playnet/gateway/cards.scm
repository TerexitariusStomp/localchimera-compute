;;; gateway/cards.scm — a card: how to reach one person, handed to another.
;;;
;;; A person's ways to be reached are theirs. A card is a selection of them
;;; handed to one contact (the First Person Project's relationship card: a
;;; signed, self-asserted object passed between two people, updated one way).
;;; The commune carries it and cannot read it:
;;;
;;;   SEALED   the card's content is sealed in the giver's browser to the
;;;            receiver's own encryption key (the key their inception event
;;;            anchors), so what is kept here is ciphertext;
;;;   SIGNED   the giver signs the card's identifier, which is over (giver,
;;;            receiver, time, ciphertext), so the commune knows whose it is
;;;            and that it is whole without opening it;
;;;   ONE      there is one card per pair and direction. A new one takes the
;;;            place of the last, and withdrawing deletes the file — a card
;;;            withdrawn is a card erased.
;;;
;;; The wire is {"from","to","at","sealed","said","sig"}; the session's doors
;;; (gateway/lobby.scm give-card, withdraw-card, cards) are thin over this.

(define-module (playnet gateway cards)
  #:use-module (srfi srfi-1)
  #:use-module (json)
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((playnet keri said) #:select (compute-said))
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature))
  #:export (%card-schema %card-max-sealed
            person-aid? card-said card-wire->card card-verdict card-at
            card-put! card-get card-drop! cards-forget!))

(define %card-schema "playnet-card/v1")
;; the ciphertext as hex: a name and a handful of lines, with room to spare
(define %card-max-sealed 16384)

(define (aid-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\-) (char=? c #\_)))
(define (person-aid? s)
  "Whether S has the shape of an identifier: 44 base64url characters, which
   is also what makes it safe as part of a file's name."
  (and (string? s) (= 44 (string-length s))
       (char-upper-case? (string-ref s 0))
       (string-every aid-char? s)
       (string-every (lambda (c) (char<? c #\delete)) s)))

(define (hex-string? s)
  (and (string? s) (even? (string-length s))
       (string-every (lambda (c) (or (char-numeric? c) (memv c '(#\a #\b #\c #\d #\e #\f)))) s)))

(define (card-said from to at sealed)
  "The identifier a card's giver signs: over who gives, who receives, when,
   and the ciphertext itself."
  (compute-said from to %card-schema `((at . ,at) (sealed . ,sealed)) '()))

(define (card-wire->card wire)
  "WIRE (a JSON string) as an alist of from, to, at, sealed, said, sig — or a
   string saying why it is no card."
  (catch #t
    (lambda ()
      (let* ((o (json-string->scm wire))
             (str (lambda (k) (let ((v (assoc-ref o k))) (and (string? v) v))))
             (card (map (lambda (k) (cons (string->symbol k) (str k)))
                        '("from" "to" "at" "sealed" "said" "sig"))))
        (if (every cdr card) card "a card names its giver, receiver, time, content and signature")))
    (lambda _ "a card is a JSON object")))

(define (card-at card) (assq-ref card 'at))

(define (card-verdict card presenter-aid)
  "#t when CARD is PRESENTER-AID's own signed card to another person, else a
   string saying why."
  (let ((from (assq-ref card 'from)) (to (assq-ref card 'to))
        (at (assq-ref card 'at)) (sealed (assq-ref card 'sealed))
        (said (assq-ref card 'said)) (sig (assq-ref card 'sig)))
    (cond
     ((not (equal? from presenter-aid)) "a card is given by the person signed in")
     ((not (person-aid? to)) "a card is given to a person")
     ((equal? to from) "a card is given to someone else")
     ((or (string-null? at) (> (string-length at) 40)) "a card states when it was made")
     ((not (hex-string? sealed)) "a card's content is sealed")
     ((string-null? sealed) "a card has content")
     ((> (string-length sealed) %card-max-sealed) "a card is a name and a few lines")
     ((not (equal? said (card-said from to at sealed))) "the card's identifier does not match its content")
     ((not (verify-said-signature said sig from)) "the card's signature is not its giver's")
     (else #t))))

;; ── the store: one file per pair and direction ──────────────────────────

(define (card-file dir to from)
  (and (person-aid? to) (person-aid? from)
       (string-append dir "/" to "." from ".card")))

(define (card-put! dir card wire)
  "Keep WIRE as the card from CARD's giver to its receiver, in place of any
   earlier one."
  (unless (file-exists? dir) (mkdir dir))
  (let* ((file (card-file dir (assq-ref card 'to) (assq-ref card 'from)))
         (tmp (string-append file ".tmp")))
    (call-with-output-file tmp (lambda (p) (display wire p)))
    (rename-file tmp file)))

(define (card-get dir to from)
  "The card FROM gave TO, as its wire, or #f."
  (let ((file (card-file dir to from)))
    (and file (file-exists? file)
         (catch #t
           (lambda () (call-with-input-file file get-string-all))
           (lambda _ #f)))))

(define (card-drop! dir to from)
  "Erase the card FROM gave TO. #t whether or not one stood."
  (let ((file (card-file dir to from)))
    (when (and file (file-exists? file)) (delete-file file))
    #t))

(define (cards-forget! dir aid)
  "Erase every card AID gave and every card AID was given — its AID is in
   the name of each — and reply how many went. A card someone else gave
   them is theirs to read and nobody's once they are forgotten; a card they
   gave carries their name to the receiver, who keeps a copy of their own
   (the wire is sealed to the receiver) and loses nothing readable here.
   Idempotent: no directory, or no card of theirs, replies 0."
  (if (and (person-aid? aid) (file-exists? dir))
      (let ((mine (or (scandir dir
                               (lambda (f)
                                 (and (string-suffix? ".card" f)
                                      (let ((stem (substring f 0 (- (string-length f) 5))))
                                        (or (string-prefix? (string-append aid ".") stem)
                                            (string-suffix? (string-append "." aid) stem))))))
                      '())))
        (for-each (lambda (f) (delete-file (string-append dir "/" f))) mine)
        (length mine))
      0))
