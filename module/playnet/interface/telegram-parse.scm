;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/telegram-parse.scm — pure parsing helpers
;;;
;;; Split out of server/telegram-bridge.scm so the parsing logic is
;;; importable from tests. Nothing here touches the network or any
;;; actor — pure functions over alists / strings.

(define-module (playnet interface telegram-parse)
  #:use-module (srfi srfi-1)
  #:export (alist?
            extract-message
            channel-id-for))

(define (alist? x)
  (and (list? x) (every pair? x)))

(define (extract-message update)
  "Pull (chat-id user-id text) out of a Telegram Update alist, or #f
   if the update isn't a plain text message we can route. Accepts the
   shape produced by guile-json's json-string->scm (string keys)."
  (let* ((message (and (alist? update) (assoc-ref update "message")))
         (chat    (and (alist? message) (assoc-ref message "chat")))
         (chat-id (and (alist? chat) (assoc-ref chat "id")))
         (from    (and (alist? message) (assoc-ref message "from")))
         (uid-num (and (alist? from) (assoc-ref from "id")))
         (uname   (and (alist? from) (assoc-ref from "username")))
         (user-id (cond
                   ((string? uname) uname)
                   ((number? uid-num) (number->string uid-num))
                   (else #f)))
         (text    (and (alist? message) (assoc-ref message "text"))))
    (and chat-id user-id (string? text)
         (list chat-id user-id text))))

(define (channel-id-for chat-id)
  (string-append "tg-" (number->string chat-id)))
