;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/transport.scm — Transport adapter protocol
;;;
;;; A transport adapter implements 3 methods:
;;;
;;;   (send-message channel-context text)
;;;     Deliver a text message to the interface destination.
;;;     channel-context is opaque — chat_id for Telegram, room_id for Matrix, etc.
;;;
;;;   (send-formatted channel-context blocks)
;;;     Deliver a rich/structured message. Optional — adapters may fall back
;;;     to send-message with plain text.
;;;
;;;   (parse-command raw-text)
;;;     Extract command name and args from raw input.
;;;     Returns (values command-name args-string) or (values #f #f).
;;;     Transport-specific: Telegram uses /, IRC uses !, REPL uses , etc.
;;;
;;; Adding a new transport = implementing these 3 methods as a Goblins actor.

(define-module (playnet interface transport)
  #:use-module (srfi srfi-1)
  #:export (parse-slash-command
            parse-comma-command))


;; =========================================================================
;; Shared command parsing helpers
;; =========================================================================

(define (parse-prefixed-command prefix raw-text)
  "Parse a command with the given prefix character.
   Returns (values command-name args-string) or (values #f #f)."
  (let ((trimmed (string-trim-both raw-text)))
    (if (and (> (string-length trimmed) 0)
             (char=? (string-ref trimmed 0) prefix))
        (let* ((rest (substring trimmed 1))
               (space-idx (string-index rest #\space)))
          (if space-idx
              (values (substring rest 0 space-idx)
                      (string-trim-both (substring rest (+ space-idx 1))))
              (values rest "")))
        (values #f #f))))

(define (parse-slash-command raw-text)
  "Parse /command args. Returns (values cmd args) or (values #f #f)."
  (parse-prefixed-command #\/ raw-text))

(define (parse-comma-command raw-text)
  "Parse ,command args. Returns (values cmd args) or (values #f #f)."
  (parse-prefixed-command #\, raw-text))
