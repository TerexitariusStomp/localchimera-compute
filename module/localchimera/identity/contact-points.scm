;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; identity/contact-points.scm — a contact point, presented to a commune.
;;;
;;; A person holds their ways to be reached, and tells a commune one of them
;;; so it can notify them there. What they tell it is a contact-point
;;; credential ((localchimera keri first-person credentials)): self-issued, blinded, in
;;; their own signature. This module is the commune's side of that:
;;;
;;;   the WIRE     the credential as the browser sends it, rebuilt here through
;;;                the constructor itself, so a wire that verifies is one the
;;;                constructor would have written;
;;;   the VERDICT  it is the presenter's own, signed, of a kind a commune may
;;;                be told, with a value of that kind's shape;
;;;   the DESK     a commune delivers only to an address that answered. A
;;;                presented point waits at the desk while a code travels to
;;;                the address itself; the code, said back, is what binds it.
;;;
;;; The session's doors (doors/lobby.scm present-, confirm-, withdraw-
;;; contact-point, my-contact-points) are thin over these.

(define-module (localchimera identity contact-points)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (json)
  #:use-module (localchimera keri acdc)
  #:use-module (localchimera keri first-person credentials)
  #:use-module ((localchimera identity reach-kinds) #:select (reach-value-fault commune-reach-kinds))
  #:use-module ((localchimera utils clock) #:select (instant->unix (now . clock-now)))
  #:export (contact-point-wire->cred contact-point-verdict
            make-contact-point-desk
            %confirm-ttl %confirm-attempts %confirm-budget %confirm-window))

;; ── the wire ────────────────────────────────────────────────────────────
;; {"said","issuer","holder","claims":{"u","kind","ctx","style","issued-at",
;;  "expires-at"},"sig"} — the shape the device-authorization wire has
;; (identity/devices.scm). KIND and STYLE are symbols in the
;; credential, and they are SAID material, so they are read back as symbols.

(define (contact-point-wire->cred wire)
  "The credential WIRE (a JSON string) carries, with its signature attached,
   or a string saying why it is no contact point."
  (catch #t
    (lambda ()
      (let* ((o (json-string->scm wire))
             (claims (assoc-ref o "claims"))
             (str (lambda (al k) (let ((v (and (pair? al) (assoc-ref al k)))) (and (string? v) v))))
             (issuer (str o "issuer")) (holder (str o "holder"))
             (said (str o "said")) (sig (str o "sig"))
             (kind (str claims "kind")) (style (str claims "style"))
             (ctx (str claims "ctx")) (u (str claims "u"))
             (issued-at (str claims "issued-at"))
             (expires (and (pair? claims) (assoc-ref claims "expires-at"))))
        (cond
         ((not (and issuer holder said kind style ctx u issued-at))
          "a contact point names its issuer, kind, destination, nonce and time")
         ((not (equal? issuer holder)) "a contact point is self-issued")
         (else
          ;; rebuilt by the constructor: the SAID it derives is the SAID a
          ;; faithful wire states
          (let ((cred (make-contact-point-credential
                       #:subject-aid issuer
                       #:kind (string->symbol kind)
                       #:ctx ctx
                       #:style (string->symbol style)
                       #:issued-at issued-at
                       #:expires-at (and (number? expires) expires)
                       #:u u)))
            (if (equal? said (cred-said cred))
                (if sig (cred-with-signature cred sig) cred)
                "the contact point's identifier does not match its content"))))))
    (lambda _ "a contact point is a JSON credential")))

;; ── the verdict ─────────────────────────────────────────────────────────

(define* (contact-point-verdict cred presenter-aid #:key (now (instant->unix (clock-now))))
  "#t when CRED is PRESENTER-AID's own signed contact point of a kind a
   commune may be told, else a string saying why."
  (let ((fields (contact-point-binding-fields cred)))
    (cond
     ((not fields) "not a contact point")
     ((not (cred-signature cred)) "a contact point is signed by the person it reaches")
     ((not (memq (car fields) (commune-reach-kinds)))
      "a commune is told an email, Matrix, Telegram or mesh address")
     ((reach-value-fault (car fields) (cadr fields)) => identity)
     (else (contact-point-acceptable? cred presenter-aid #:now now)))))

;; ── the desk ────────────────────────────────────────────────────────────

(define %confirm-ttl 3600)        ; a code stands for an hour
(define %confirm-attempts 5)      ; wrong codes before the point is put down
(define %confirm-budget 3)        ; codes sent for one person…
(define %confirm-window 3600)     ; …in this many seconds

(define (six-digits)
  (let ((n (random 1000000 %desk-random)))
    (string-append (make-string (- 6 (string-length (number->string n))) #\0)
                   (number->string n))))
(define %desk-random (random-state-from-platform))

(define* (make-contact-point-desk channels
                                  #:key (now (lambda () (instant->unix (clock-now))))
                                        (mint six-digits))
  "The desk of a commune that delivers on CHANNELS, an alist kind →
   (lambda (ctx title body) …) that sends one message to an address. A
   procedure of an operation and its arguments:

     ('delivers)                     the kinds this commune delivers on
     ('present aid kind ctx style)   hold the point and send its code:
                                     'pending, or (error . words)
     ('confirm aid kind ctx code)    the held point's style when CODE is its
                                     code, or (error . words)
     ('pending aid)                  the (kind ctx) pairs AID has waiting
     ('drop aid kind ctx)            put a held point down
     ('forget aid)                   put down all AID's points and the record
                                     of codes sent to them (erasure)

   One vat calls it (the gateway's), so its tables are plain."
  (let ((held (make-hash-table))      ; (aid kind ctx) → (code expires attempts style)
        (sent (make-hash-table)))     ; aid → times a code was sent, newest first
    (define (recent aid)
      (filter (lambda (t) (< (- (now) t) %confirm-window)) (hash-ref sent aid '())))
    (lambda (op . args)
      (match (cons op args)
        (('delivers) (map car channels))
        (('present aid kind ctx style)
         (let ((send (assq-ref channels kind)))
           (cond
            ((not send) (cons 'error (format #f "this commune does not deliver to ~a" kind)))
            ((>= (length (recent aid)) %confirm-budget)
             (cons 'error "too many codes asked for — try again in an hour"))
            (else
             (let ((code (mint)))
               (hash-set! held (list aid kind ctx) (list code (+ (now) %confirm-ttl) 0 style))
               (hash-set! sent aid (cons (now) (recent aid)))
               (send ctx "localchimera: confirm this address"
                     (string-append
                      "Someone signed in to localchimera asked for their notifications to arrive here.\n\n"
                      "If that was you, enter this code under settings › how to reach you:\n\n    "
                      code "\n\nIt stands for an hour. If it was not you, do nothing: "
                      "nothing more is sent to this address.\n"))
               'pending)))))
        (('confirm aid kind ctx code)
         (let* ((key (list aid kind ctx)) (h (hash-ref held key #f)))
           (match h
             (#f (cons 'error "nothing is waiting to be confirmed for that address"))
             ((want expires attempts style)
              (cond
               ((> (now) expires) (hash-remove! held key)
                (cons 'error "that code has lapsed — tell the commune again"))
               ((and (string? code) (string=? (string-trim-both code) want))
                (hash-remove! held key) style)
               ((>= (+ attempts 1) %confirm-attempts) (hash-remove! held key)
                (cons 'error "too many wrong codes — tell the commune again"))
               (else (hash-set! held key (list want expires (+ attempts 1) style))
                     (cons 'error "that is not the code")))))))
        (('pending aid)
         (hash-fold (lambda (k v acc)
                      (if (and (equal? aid (car k)) (<= (now) (cadr v))) (cons (cdr k) acc) acc))
                    '() held))
        (('drop aid kind ctx) (hash-remove! held (list aid kind ctx)) #t)
        ;; erasure: every point AID has waiting, and the record of codes
        ;; sent to them; replies how many points went
        (('forget aid)
         (let ((keys (hash-fold (lambda (k v acc) (if (equal? aid (car k)) (cons k acc) acc))
                                '() held)))
           (for-each (lambda (k) (hash-remove! held k)) keys)
           (hash-remove! sent aid)
           (length keys)))))))
