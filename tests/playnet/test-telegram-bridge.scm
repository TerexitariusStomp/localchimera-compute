;;; test-telegram-bridge.scm — parsing tests for the Telegram bridge
;;;
;;; Covers the pure parsing surface — what the bridge does between
;;; "JSON arrived from Telegram" and "dispatch into a channel":
;;;   - parse-command on ^telegram-adapter (command extraction)
;;;   - extract-message (Update → (chat-id user-id text))
;;;   - channel-id-for (deterministic chat-id → channel-id mapping)
;;;
;;; No network. No real bot token. Run from project root:
;;;   guile -L module tests/playnet/test-telegram-bridge.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (playnet test harness)
             (goblins)
             (goblins vat)
             (ice-9 receive)
             (playnet interface adapters telegram)
             (playnet interface telegram-parse))

;;; ── Setup ──────────────────────────────────────────────────────────────────

(define test-vat (spawn-vat #:name "test"))

;; parse-command never touches the token-ref, so a dummy will do.
(define adapter
  (with-vat test-vat (spawn ^telegram-adapter 'unused)))

(define (parse text)
  "Return (list cmd args) or (list #f #f)."
  (with-vat test-vat
    (let ((p ($ adapter 'parse-command text)))
      (list (car p) (cdr p)))))

;;; ── parse-command ──────────────────────────────────────────────────────────

(display "\n── parse-command ──\n")

(check "bare slash command"
       (parse "/inventory")
       '("inventory" ""))

(check "command with args"
       (parse "/alerts buffer-status")
       '("alerts" "buffer-status"))

(check "command with multiple args, args trimmed"
       (parse "/plan   intents   ")
       '("plan" "intents"))

(check "@botname suffix stripped"
       (parse "/inventory@playnetbot spec-1")
       '("inventory" "spec-1"))

(check "@botname suffix with no args"
       (parse "/help@playnetbot")
       '("help" ""))

(check "leading whitespace tolerated"
       (parse "   /status")
       '("status" ""))

(check "non-command text → (#f #f)"
       (parse "just a regular message")
       '(#f #f))

(check "empty string → (#f #f)"
       (parse "")
       '(#f #f))

;;; ── extract-message ────────────────────────────────────────────────────────

(display "\n── extract-message ──\n")

(define* (update-of chat-id user-id text #:key (username #f))
  "Build an Update alist matching guile-json's shape."
  `(("update_id" . 12345)
    ("message"
     . (("chat" . (("id" . ,chat-id)))
        ("from" . ,(if username
                       `(("id" . ,user-id) ("username" . ,username))
                       `(("id" . ,user-id))))
        ("text" . ,text)))))

(check "extracts chat-id, prefers username over numeric id"
       (extract-message (update-of 42 7 "/help" #:username "alice"))
       '(42 "alice" "/help"))

(check "falls back to numeric user-id when username missing"
       (extract-message (update-of -100 9999 "/inventory"))
       '(-100 "9999" "/inventory"))

(check "negative chat-id (group chat) preserved"
       (extract-message (update-of -100456 1 "/status" #:username "bob"))
       '(-100456 "bob" "/status"))

(check "missing message returns #f"
       (extract-message '(("update_id" . 1)))
       #f)

(check "non-text message (e.g. photo-only) returns #f"
       (extract-message
        '(("update_id" . 2)
          ("message" . (("chat" . (("id" . 1)))
                        ("from" . (("id" . 1)))
                        ("photo" . #(()))))))
       #f)

(check "totally malformed update returns #f"
       (extract-message "this is not an alist")
       #f)

;;; ── channel-id-for ─────────────────────────────────────────────────────────

(display "\n── channel-id-for ──\n")

(check "positive chat-id"
       (channel-id-for 42)
       "tg-42")

(check "negative chat-id (group)"
       (channel-id-for -1001234567890)
       "tg--1001234567890")

(check "deterministic"
       (equal? (channel-id-for 42) (channel-id-for 42))
       #t)

(test-summary!)
