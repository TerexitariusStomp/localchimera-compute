;;; test-matrix-bridge.scm — parsing tests for the Matrix bridge
;;;
;;; Covers parse-command on ^matrix-adapter, plus the two pure helpers
;;; in (playnet interface matrix-parse). No network, no homeserver, no
;;; access token required.
;;;
;;; Run from project root:
;;;   guile -L module tests/playnet/test-matrix-bridge.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules (playnet test harness)
             (goblins)
             (goblins vat)
             (ice-9 receive)
             (playnet interface adapters matrix)
             (playnet interface matrix-parse))

;;; ── Setup ──────────────────────────────────────────────────────────────────

(define test-vat (spawn-vat #:name "test"))

;; parse-command never touches token-ref. txn-counter just increments
;; on each send-message; doesn't matter for parse-command tests.
(define adapter
  (with-vat test-vat (spawn ^matrix-adapter 'unused 0)))

(define (parse text)
  (with-vat test-vat
    (let ((p ($ adapter 'parse-command text)))
      (list (car p) (cdr p)))))

;;; ── parse-command ──────────────────────────────────────────────────────────

(display "\n── parse-command ──\n")

(check "bare bang command"
       (parse "!inventory")
       '("inventory" ""))

(check "command with args"
       (parse "!alerts buffer-status")
       '("alerts" "buffer-status"))

(check "args trimmed"
       (parse "!plan   intents   ")
       '("plan" "intents"))

(check "leading whitespace tolerated"
       (parse "   !status")
       '("status" ""))

(check "non-command text → (#f #f)"
       (parse "regular Matrix message")
       '(#f #f))

(check "slash prefix is NOT a Matrix command"
       (parse "/inventory")
       '(#f #f))

(check "empty string → (#f #f)"
       (parse "")
       '(#f #f))

;;; ── extract-message-from-event ─────────────────────────────────────────────

(display "\n── extract-message-from-event ──\n")

(define %self "@bot:example.org")

(define (text-event sender body)
  `(("type"    . "m.room.message")
    ("sender"  . ,sender)
    ("event_id" . "$xyz")
    ("content" . (("msgtype" . "m.text")
                  ("body"    . ,body)))))

(check "extracts (sender body) for plain text from another user"
       (extract-message-from-event (text-event "@alice:example.org" "!help") %self)
       '("@alice:example.org" "!help"))

(check "drops event from self"
       (extract-message-from-event (text-event %self "echo!") %self)
       #f)

(check "drops non-message event"
       (extract-message-from-event
        '(("type" . "m.room.member")
          ("sender" . "@alice:example.org"))
        %self)
       #f)

(check "drops non-text msgtype (m.image, etc.)"
       (extract-message-from-event
        `(("type" . "m.room.message")
          ("sender" . "@alice:example.org")
          ("content" . (("msgtype" . "m.image") ("body" . "pic.png"))))
        %self)
       #f)

(check "malformed event returns #f"
       (extract-message-from-event "not an alist" %self)
       #f)

;;; ── joined-rooms-from-sync ─────────────────────────────────────────────────

(display "\n── joined-rooms-from-sync ──\n")

(define example-sync
  `(("next_batch" . "s12345_678")
    ("rooms" . (("join" . (("!abc:example.org"
                            . (("timeline"
                                . (("events" . #(,(text-event "@alice:example.org" "!help")
                                                 ,(text-event "@bob:example.org" "hi")))))))
                           ("!def:example.org"
                            . (("timeline"
                                . (("events" . #())))))))))))

(define rooms (joined-rooms-from-sync example-sync))

(check "returns one room (the empty timeline is dropped)"
       (length rooms) 1)

(check "first entry is (room-id . events-list)"
       (car (car rooms)) "!abc:example.org")

(check "events list has both events"
       (length (cdr (car rooms))) 2)

(check "empty sync → empty list"
       (joined-rooms-from-sync '(("next_batch" . "x"))) '())

;;; ── channel-id-for-room ────────────────────────────────────────────────────

(display "\n── channel-id-for-room ──\n")

(check "prefixes mx-"
       (channel-id-for-room "!abc:example.org")
       "mx-!abc:example.org")

(check "deterministic"
       (equal? (channel-id-for-room "!abc:x") (channel-id-for-room "!abc:x"))
       #t)

(test-summary!)
