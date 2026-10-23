;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/adapters/matrix.scm — Matrix transport adapter
;;;
;;; Two actors:
;;;
;;;   ^matrix-token    — Sealed credentials. Captures a homeserver URL
;;;                      and access_token in closure. Exposes (request
;;;                      method path body-or-#f) which dispatches to
;;;                      http-get/post/put with Bearer auth attached.
;;;                      Token never leaves the actor boundary.
;;;
;;;   ^matrix-adapter  — Transport adapter. send-message PUTs to
;;;                      /_matrix/client/v3/rooms/{room}/send/m.room.message/{txn},
;;;                      parse-command extracts !prefixed commands.
;;;
;;; E2EE NOTE: this adapter speaks plain Client-Server API. Olm/Megolm
;;; isn't implemented. To run in E2EE rooms, point the bot's homeserver
;;; URL at a local pantalaimon proxy — pantalaimon does the crypto and
;;; exposes plaintext API on loopback. Otherwise the bot only works in
;;; unencrypted rooms.

(define-module (playnet interface adapters matrix)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface transport)
  #:use-module (playnet notify rendered)
  #:use-module (playnet utils http-auth)
  #:use-module (web client)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:export (^matrix-token
            ^matrix-adapter))


;; =========================================================================
;; ^matrix-token — sealed homeserver URL + access token
;; =========================================================================

(define (^matrix-token _bcom homeserver access-token)
  ;; homeserver:    "https://matrix.example.org"  (no trailing slash)
  ;; access-token:  long-lived bearer token (from /login or admin-issued)

  (define base-headers
    (cons '(content-type . (application/json))
          (bearer-auth-header access-token)))

  (define (do-request method path body-string)
    (let ((url (string-append homeserver path)))
      (call-with-values
          (lambda ()
            (case method
              ((GET)
               (http-get url
                         #:headers base-headers
                         #:streaming? #f
                         #:decode-body? #f
                         #:verify-certificate? #t))
              ((POST)
               (http-post url
                          #:body (and body-string (string->utf8 body-string))
                          #:headers base-headers
                          #:streaming? #f
                          #:decode-body? #f
                          #:verify-certificate? #t))
              ((PUT)
               (http-put url
                         #:body (and body-string (string->utf8 body-string))
                         #:headers base-headers
                         #:streaming? #f
                         #:decode-body? #f
                         #:verify-certificate? #t))
              (else
               (error "matrix-token: unsupported method" method))))
        (lambda (_response body-bv)
          (if (bytevector? body-bv)
              (utf8->string body-bv)
              body-bv)))))

  (methods
    ((request method path body-string)
     (do-request method path body-string))
    ((get path)
     (do-request 'GET path #f))
    ((post path body-string)
     (do-request 'POST path body-string))
    ((put path body-string)
     (do-request 'PUT path body-string))))


;; =========================================================================
;; ^matrix-adapter — transport adapter
;; =========================================================================
;;
;; Each send needs a unique transaction ID for idempotency. We use a
;; monotonic counter; the seed is supplied at spawn time (typically
;; epoch-ms) so two adapter instances don't collide if a restart races.

(define (^matrix-adapter bcom token-ref txn-counter)

  (define (send-text room-id text)
    (let* ((next (+ txn-counter 1))
           (txn (number->string next))
           (path (string-append "/_matrix/client/v3/rooms/"
                                (uri-encode room-id)
                                "/send/m.room.message/" txn))
           (body (scm->json-string
                  `((msgtype . "m.text")
                    (body    . ,text)))))
      ($ token-ref 'put path body)
      (bcom (^matrix-adapter bcom token-ref next))))

  (methods

    ((deliver room-id rendered)
     (send-text room-id (rendered->text rendered)))

    ((send-message room-id text)
     (send-text room-id (if (string? text) text (rendered->text text))))

    ((send-formatted room-id blocks)
     (let ((text (string-join
                  (map (lambda (b)
                         (if (string? b) b (format #f "~a" b)))
                       blocks)
                  "\n\n")))
       (send-text room-id text)))

    ((parse-command raw-text)
     ;; Matrix bot convention: ! prefix.
     (let ((trimmed (string-trim-both raw-text)))
       (if (and (> (string-length trimmed) 0)
                (char=? (string-ref trimmed 0) #\!))
           (let* ((space-idx (string-index trimmed #\space))
                  (cmd (if space-idx
                           (substring trimmed 1 space-idx)
                           (substring trimmed 1)))
                  (args (if space-idx
                            (string-trim-both (substring trimmed (+ space-idx 1)))
                            "")))
             (cons cmd args))
           (cons #f #f))))))
