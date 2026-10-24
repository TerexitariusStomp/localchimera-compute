;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/interface/adapters/telegram.scm — Telegram transport adapter
;;;
;;; Two actors:
;;;
;;;   ^telegram-token  — Sealed token actor. Captures the bot token in
;;;                      closure and exposes (post path body-string) which
;;;                      POSTs to https://api.telegram.org/bot<token><path>.
;;;                      The token never leaves the actor boundary.
;;;
;;;   ^telegram-adapter — Transport adapter. Implements send-message,
;;;                       send-formatted, and parse-command. Talks to
;;;                       Telegram exclusively via a ^telegram-token ref.
;;;
;;; Telegram's auth model (token-as-path-segment, one bot per token) does
;;; not fit the ^key-pool shape (header-based, rotatable). A dedicated
;;; sealed actor is the right capability shape: one per bot, one process
;;; per bot, no rotation.

(define-module (localchimera interface adapters telegram)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (localchimera interface transport)
  #:use-module (localchimera notify rendered)
  #:use-module (web client)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:export (^telegram-token
            ^telegram-adapter))


;; =========================================================================
;; ^telegram-token — sealed bot token + private HTTP client
;; =========================================================================

(define (^telegram-token _bcom token)
  ;; token: bot token string, captured in closure, never returned.
  (define base-url
    (string-append "https://api.telegram.org/bot" token))

  (define (http-post-json path body-string)
    (let ((url (string-append base-url path)))
      (call-with-values
          (lambda ()
            (http-post url
                       #:body (string->utf8 body-string)
                       #:headers '((content-type . (application/json)))
                       #:streaming? #f
                       #:decode-body? #f
                       #:verify-certificate? #t))
        (lambda (_response body-bv)
          (if (bytevector? body-bv)
              (utf8->string body-bv)
              body-bv)))))

  (methods
    ((post path body-string)
     (http-post-json path body-string))))


;; =========================================================================
;; ^telegram-adapter — transport adapter
;; =========================================================================

(define (^telegram-adapter _bcom token-ref)
  (define (post-text chat-id text)
    ($ token-ref 'post "/sendMessage"
       (scm->json-string
        `((chat_id . ,chat-id)
          (text . ,text)
          (parse_mode . "Markdown")))))
  (methods

    ((deliver chat-id rendered)
     (post-text chat-id (rendered->text rendered)))

    ((send-message chat-id text)
     (post-text chat-id (if (string? text) text (rendered->text text))))

    ((send-formatted chat-id blocks)
     (let ((text (string-join
                  (map (lambda (b)
                         (if (string? b) b (format #f "~a" b)))
                       blocks)
                  "\n\n")))
       ($ token-ref 'post "/sendMessage"
          (scm->json-string
           `((chat_id . ,chat-id)
             (text . ,text)
             (parse_mode . "Markdown"))))))

    ((parse-command raw-text)
     ;; Telegram commands start with /. Also handle @botname suffix:
     ;; /inventory@mybot args
     (let ((trimmed (string-trim-both raw-text)))
       (if (and (> (string-length trimmed) 0)
                (char=? (string-ref trimmed 0) #\/))
           (let* ((space-idx (string-index trimmed #\space))
                  (cmd-part (if space-idx
                                (substring trimmed 1 space-idx)
                                (substring trimmed 1)))
                  (args (if space-idx
                            (string-trim-both (substring trimmed (+ space-idx 1)))
                            ""))
                  (at-idx (string-index cmd-part #\@))
                  (cmd (if at-idx
                           (substring cmd-part 0 at-idx)
                           cmd-part)))
             (cons cmd args))
           (cons #f #f))))))
