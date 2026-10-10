;;; identity/reach-kinds.scm — the kinds of way a person can be reached.
;;;
;;; A person keeps a list of ways to reach them, and discloses entries of it
;;; twice over: to a commune, so it can notify them there (a contact-point
;;; credential, identity/contact-points.scm), and to a person, on a card
;;; (identity/cards.scm). Both read one vocabulary, from here: each kind with
;;; the word it goes by, an example of its value, the link a value opens with,
;;; and whether a commune may be told it.
;;;
;;; A kind a commune may be told is one of the recipient registry's durable
;;; channels ((playnet notify recipient)) and one of the contact-point
;;; credential's kinds ((playnet keri first-person credentials)); tests/gateway/
;;; test-contact-points.scm holds the three lists to each other. The other
;;; kinds are for people: a card carries them, a commune never hears them.
;;;
;;; ui/app/reach-catalogue.ts is the browser's copy (tools/reach-emit.scm).

(define-module (playnet identity reach-kinds)
  #:use-module (srfi srfi-1)
  #:export (%reach-kinds reach-id reach-label reach-example reach-link reach-commune?
            reach-kind commune-reach-kinds reach-value-fault %reach-value-max))

;; (id label example link commune?) — the order the app offers them in.
;; LINK is what a value is appended to for a tap to open it; "" for none.
(define %reach-kinds
  '((email    "email"       "you@example.org"    "mailto:"               #t)
    (matrix   "Matrix"      "@you:example.org"   "https://matrix.to/#/"  #t)
    (telegram "Telegram"    "yourhandle"         "https://t.me/"         #t)
    (lxmf     "mesh (LXMF)" "a mesh address"     ""                      #t)
    (phone    "phone"       "+49 30 1234567"     "tel:"                  #f)
    (signal   "Signal"      "+49 30 1234567"     ""                      #f)
    (web      "web"         "https://example.org" ""                     #f)
    (note     "note"        "ring twice"         ""                      #f)))

(define reach-id first)
(define reach-label second)
(define reach-example third)
(define reach-link fourth)
(define reach-commune? fifth)

(define (reach-kind id)
  "The catalogue row for ID (a symbol or its name), or #f."
  (let ((id (if (string? id) (string->symbol id) id)))
    (find (lambda (k) (eq? id (reach-id k))) %reach-kinds)))

(define (commune-reach-kinds)
  "The kinds a commune may be told, in catalogue order."
  (map reach-id (filter reach-commune? %reach-kinds)))

;; a value is one line a person can read: this many characters at most
(define %reach-value-max 200)

(define (control-char? c) (or (char<? c #\space) (char=? c #\delete)))

(define (email-fault v)
  ;; one @, something either side, a dot in the domain, and none of the
  ;; characters that end a mail header or start a second address
  (let ((at (string-index v #\@)))
    (cond ((string-any (lambda (c) (or (char-whitespace? c) (memv c '(#\, #\; #\< #\> #\( #\) #\[ #\] #\\ #\")))) v)
           "an email address has no spaces or separators")
          ((not at) "an email address has an @")
          ((string-index v #\@ (+ at 1)) "an email address has one @")
          ((or (= at 0) (= at (- (string-length v) 1))) "an email address has a name and a domain")
          ((not (string-index v #\. at)) "an email address's domain has a dot")
          (else #f))))

(define (reach-value-fault kind value)
  "What is wrong with VALUE as a KIND, in words, or #f when it stands."
  (cond ((not (reach-kind kind)) "an unknown kind of contact point")
        ((not (string? value)) "a contact point is text")
        ((string-null? value) "a contact point has a destination")
        ((> (string-length value) %reach-value-max) "a contact point is one short line")
        ((string-any control-char? value) "a contact point is one line")
        ((eq? (reach-id (reach-kind kind)) 'email) (email-fault value))
        (else #f)))
