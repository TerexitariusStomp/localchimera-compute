;;; module/xorg/gateway/mailbox.scm — Offline message queuing
;;;
;;; When a user is offline, messages are stored in their mailbox.
;;; On reconnect the client fetches and drains the queue.

(define-module (xorg gateway mailbox)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^mailbox
            ^mailbox-manager))

(define (^mailbox bcom messages)
  ;; messages: list of (from-name . content) pairs
  (methods
   ((deliver from-name content)
    (bcom (^mailbox bcom (append messages (list (cons from-name content))))))

   ;; Return all queued messages and clear the queue.
   ((fetch)
    (bcom (^mailbox bcom '()) messages))

   ((count) (length messages))))

(define (^mailbox-manager bcom mailboxes)
  ;; mailboxes: hashmap of identity-key -> ^mailbox ref
  (methods
   ((get-or-create identity-key)
    (or (hashmap-ref mailboxes identity-key #f)
        (let ((mb (spawn ^mailbox '())))
          (bcom (^mailbox-manager bcom
                                  (hashmap-set mailboxes identity-key mb)))
          mb)))))
