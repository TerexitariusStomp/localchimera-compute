;;; module/playnet/interface/adapters/telegram.scm — Telegram transport adapter
;;;
;;; Uses ^key-pool with a telegram-provider profile to seal the bot token
;;; and make Telegram Bot API calls. The bot token never leaves the
;;; ^api-key actor boundary — same pattern as OpenRouter/OpenAI keys.
;;;
;;; The adapter itself is a transport actor (send-message, send-formatted,
;;; parse-command). It is paired with a telegram-bridge daemon that handles
;;; webhook/long-poll and feeds incoming messages to channels.

(define-module (playnet interface adapters telegram)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface transport)
  #:use-module (json)
  #:export (^telegram-adapter
            telegram-provider))


;; =========================================================================
;; Telegram provider profile — fits the ^key-pool provider pattern exactly
;; =========================================================================

(define (telegram-provider)
  "Provider profile for Telegram Bot API.
   Telegram puts the token in the URL path, not an Authorization header.
   The ^api-key actor's base-url is set to include the token."
  `((name             . "telegram")
    (base-url         . "https://api.telegram.org")
    ;; Telegram auth is token-in-URL, so no auth header needed.
    ;; The ^api-key actor appends /bot<token><path> to base-url.
    (auth-header-fn   . ,(lambda (_token) '()))
    (credit-check     . #f)
    (cost-extractor   . ,(lambda (_json) #f))  ;; Telegram API is free
    (error-classifier . ,(lambda (code _err-json msg)
                           (cond
                             ((eqv? code 429) 'rate-limited)
                             ((eqv? code 401) 'depleted)   ;; revoked token
                             ((eqv? code 403) 'depleted)   ;; bot blocked
                             (else 'degraded))))))


;; =========================================================================
;; ^telegram-adapter — transport adapter using ^key-pool for API calls
;; =========================================================================

(define (^telegram-adapter _bcom bot-pool)
  ;; bot-pool: ^key-pool ref holding one or more Telegram bot tokens
  ;;
  ;; Note: The ^key-pool 'request method POSTs to base-url + path.
  ;; For Telegram, path is e.g. "/sendMessage" and the key-pool's
  ;; ^api-key actor handles inserting the bot token in the request.

  (methods

    ((send-message chat-id text)
     ;; POST /sendMessage to Telegram Bot API via key-pool.
     ($ bot-pool 'request
        "/sendMessage"
        (scm->json-string
         `((chat_id . ,chat-id)
           (text . ,text)
           (parse_mode . "Markdown")))))

    ((send-formatted chat-id blocks)
     ;; Rich messages: join blocks as Markdown sections.
     (let ((text (string-join
                  (map (lambda (b)
                         (if (string? b) b (format #f "~a" b)))
                       blocks)
                  "\n\n")))
       ($ bot-pool 'request
          "/sendMessage"
          (scm->json-string
           `((chat_id . ,chat-id)
             (text . ,text)
             (parse_mode . "Markdown"))))))

    ((parse-command raw-text)
     ;; Telegram commands start with /
     ;; Also handle @botname suffix: /inventory@mybot args
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
                  ;; Strip @botname suffix if present
                  (at-idx (string-index cmd-part #\@))
                  (cmd (if at-idx
                           (substring cmd-part 0 at-idx)
                           cmd-part)))
             (values cmd args))
           (values #f #f))))))
