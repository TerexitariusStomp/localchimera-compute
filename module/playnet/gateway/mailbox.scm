;;; module/playnet/gateway/mailbox.scm — Offline message queuing
;;;
;;; When a user is offline, messages are stored in their mailbox.
;;; On reconnect the client fetches and drains the queue.

(define-module (playnet gateway mailbox)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^mailbox
            ^mailbox-manager
            mailbox-env))

(define-actor (^mailbox bcom messages)
  ;; messages: list of (from-name . content) pairs
  #:version 1
  #:portrait (lambda () (list messages))
  #:restore
  (lambda (version messages)
    (case version
      ((1) (spawn ^mailbox messages))
      (else (error "Unknown ^mailbox version" version))))
  (methods
   ((deliver from-name content)
    (bcom (^mailbox bcom (append messages (list (cons from-name content))))))

   ;; Return all queued messages and clear the queue.
   ((fetch)
    (bcom (^mailbox bcom '()) messages))

   ((count) (length messages))))

(define-actor (^mailbox-manager bcom mailboxes)
  ;; mailboxes: hashmap of identity-key -> ^mailbox ref
  #:version 1
  #:portrait (lambda () (list mailboxes))
  #:restore
  (lambda (version mailboxes)
    (case version
      ((1) (spawn ^mailbox-manager mailboxes))
      (else (error "Unknown ^mailbox-manager version" version))))
  (methods
   ;; `bcom` takes effect only as the method's return value: the mailbox
   ;; rides as its second argument so the manager keeps what it made.
   ((get-or-create identity-key)
    (or (hashmap-ref mailboxes identity-key #f)
        (let ((mb (spawn ^mailbox '())))
          (bcom (^mailbox-manager bcom
                                  (hashmap-set mailboxes identity-key mb))
                mb))))
   ;; erasure: the identity's mailbox and whatever waited in it go together;
   ;; replies how many messages went (0 when no mailbox stood)
   ((forget identity-key)
    (let ((mb (hashmap-ref mailboxes identity-key #f)))
      (if mb
          (bcom (^mailbox-manager bcom (hashmap-remove mailboxes identity-key))
                ($ mb 'count))
          0)))))

(define mailbox-env
  (make-persistence-env
    `((((playnet gateway mailbox) ^mailbox) ,^mailbox)
      (((playnet gateway mailbox) ^mailbox-manager) ,^mailbox-manager))))
