;;; goblin-chat lite
;;;
;;; Copyright 2023-2025 Jessica Tallon <jessica@spritely.institute>
;;; Copyright 2020-2022 Christine Lemmer-Webber <christine@spritely.institute>
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;; http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.


(use-modules (hoot ffi)
             (fibers channels)
             (ice-9 match)
             (goblins)
             (goblins ghash)
             (goblins actor-lib common)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             (goblins actor-lib pubsub)
             (goblins ocapn ids)
             (goblins ocapn captp)
             (goblins ocapn netlayer fake))

;; Hoot FFI stuff for UI.
(define-foreign make-element
  "document" "makeElement"
  (ref string) -> (ref extern))
(define-foreign make-text-node
  "document" "makeTextNode"
  (ref string) -> (ref extern))
(define-foreign get-element-by-id
  "document" "getElementById"
  (ref string) -> (ref extern))
(define-foreign get-document-body
  "document" "getBody"
  -> (ref extern))
(define-foreign append-child!
  "element" "appendChild"
  (ref extern) (ref extern) -> (ref extern))
(define-foreign set-attribute!
  "element" "setAttribute"
  (ref extern) (ref string) (ref string) -> none)
(define-foreign get-element-attribute
  "element" "getAttribute"
  (ref extern) (ref string) -> (ref string))
(define-foreign element-value
  "element" "value"
  (ref extern) -> (ref string))
(define-foreign set-element-value!
  "element" "setValue"
  (ref extern) (ref string) -> none)
(define-foreign set-element-inner-html!
  "element" "setInnerHTML"
  (ref extern) (ref string) -> none)
(define-foreign add-event-listener!
  "element" "addEventListener"
  (ref extern) (ref string) (ref extern) -> none)
(define-foreign event-prevent-default
  "event" "preventDefault"
  (ref extern) -> none)

;; Copied directly from backend.scm
(define (^chatroom _bcom self-proposed-name)
  ;; TODO: is ghash the same as ^hasheq?
  (define subscribers
    (spawn ^ghash))

  (define (send-to-subscribers . args)
    ;; TODO: add 'values method to ^ghash.
    (ghash-for-each
     (lambda (_associated-user subscriber)
       (apply <-np subscriber args))
     ($ subscribers 'data)))

  (define (^user-messaging-channel bcom associated-user user-inbox)
    (define dead-beh
      (lambda _
        'CONNECTION-CLOSED))

    (methods
     ((leave)
      ($ subscribers 'remove associated-user)
      (send-to-subscribers 'user-left associated-user)
      (bcom dead-beh))
     ((send-message sealed-msg)
      (send-to-subscribers 'new-message associated-user sealed-msg)
      'OK)
     ((list-users)
      ;; TODO: add 'keys to ^ghash
      (ghash-for-each
       (lambda (user _subscriber)
         user)
       ($ subscribers 'data)))))

  (define (^finalize-subscription bcom associated-user)
    (define (post-finalize-beh . _args)
      (error "Already finalized"))
    (define (pre-finalize-beh user-inbox)
      ;; send to subscribers other than this user first
      (send-to-subscribers 'user-joined associated-user)
      ;; now subscribe this user
      ($ subscribers 'set associated-user user-inbox)
      ;; send to the user who just joined a bunch of messages
      ;; as if everyone *else* already in the channel just joined
      (ghash-for-each
       (lambda (present-user _subscriber)
         (<-np user-inbox 'user-joined present-user))
       ($ subscribers 'data))
      (bcom post-finalize-beh
            (spawn ^user-messaging-channel
                   associated-user user-inbox)))
    pre-finalize-beh)

  (methods
   ((self-proposed-name) self-proposed-name)
   ((subscribe user)
    (define subscription-sealer-vow
      (<- user 'get-subscription-sealer))
    (on subscription-sealer-vow
        (lambda (subscription-sealer)
          (define finalize-sub
            (spawn ^finalize-subscription user))
          (<- subscription-sealer finalize-sub))
        #:promise? #t))))

(define (spawn-user-controller-pair self-proposed-name)
  "Spawn a user and an actor to control the user"
  (define-values (chat-msg-sealer chat-msg-unsealer chat-msg-sealed?)
    (spawn-sealer-triplet))
  (define-values (subscription-sealer subscription-unsealer
                                      subscription-sealed?)
    (spawn-sealer-triplet))
  (define-values (controller-warden controller-incanter)
    (spawn-warding-pair))

  (define rooms->inboxes/channels
    (spawn ^ghash))
  (define client-subscribers
    (spawn ^seteq))

  ;; Here's our user object.  More or less it's a profile that
  ;; provides'a self-proposed name, an unsealer, and a predicate to
  ;; check whether we sealed things.
  (define (^user _bcom)
    (methods
     ((self-proposed-name) self-proposed-name)
     ((get-chat-sealed?) chat-msg-sealed?)
     ((get-chat-unsealer) chat-msg-unsealer)
     ((get-subscription-sealer) subscription-sealer)))
  (define user
    (spawn ^user))

  ;; TODO: is this correct?
  (define (send-to-clients . args)
    (map
     (lambda (client)
       (apply <-np client args))
     ($ client-subscribers 'as-list)))

  (define (^user-inbox bcom context)
    (define room-users
      (spawn ^seteq))
    (define inbox-pubsub
      (spawn ^pubsub))

    (define (revoked-beh . rest)
      (error "Revoked!"))

    (define controller-methods
      (methods
       ((revoke) (bcom revoked-beh))
       ((subscribe subscriber)
        ($ inbox-pubsub 'subscribe subscriber)
        (map
         (lambda (user)
           (<-np subscriber 'user-joined user))
         ($ room-users 'as-list))
        #t)))
    (define public-methods
      (methods
       ((new-message from-user sealed-msg)
        ;; TODO: this should work
        ;; (define chat-unsealer-vow
        ;;   (<- from-user 'get-chat-unsealer))
        ;; (define message-vow
        ;;   (<- chat-unsealer-vow sealed-msg))

        (define message-vow
          (on (<- from-user 'get-chat-unsealer)
              (lambda (chat-unsealer)
                (on (<- chat-unsealer sealed-msg)
                    (lambda (unsealed-message)
                      unsealed-message)
                    #:promise? #t))
              #:promise? #t))

        (on message-vow
            (lambda (message)
              ($ inbox-pubsub 'publish 'new-message
                 context from-user message))))
       ((user-joined user)
        ($ room-users 'add user)
        ($ inbox-pubsub 'publish 'user-joined user))
       ((user-left user)
        ($ room-users 'remove user)
        ($ inbox-pubsub 'publish 'user-left user))
       ((context) context)))

    (ward controller-warden controller-methods
          #:extends public-methods))

  (define (^authenticated-channel _bcom room-channel inbox)
    (extend-methods
     room-channel
     ((send-message contents)
      (on (<- chat-msg-sealer contents)
          (lambda (sealed-msg)
            (<- room-channel 'send-message sealed-msg))))
     ((subscribe subscriber)
      (define (^unsubscribe _bcom)
        (lambda ()
          ($ controller-incanter inbox 'unsubscribe subscriber)))
      ($ controller-incanter inbox 'subscribe subscriber)
      `#(OK ,(spawn ^unsubscribe)))))

  (define (^user-controller _bcom)
    (methods
     ((whoami) user)
     ((connect-client client)
      ($ client-subscribers 'add client)
      `#(OK ,($ rooms->inboxes/channels 'data)))
     ((join-room room)
      (when ($ rooms->inboxes/channels 'has-key? room)
        (error "Already subscribed to the room"))
      (define inbox
        (spawn ^user-inbox room))
      (define sealed-finalizer-vow
        (<- room 'subscribe user))
      ;; First we request to subscribe, unseal it
      (define subscription-finalizer-vow
        (<- subscription-unsealer sealed-finalizer-vow))

      (on (<- subscription-finalizer-vow inbox)
          (lambda (room-channel)
            (define authenticated-ch
              (spawn ^authenticated-channel room-channel inbox))
            ($ rooms->inboxes/channels 'set room authenticated-ch)
            (send-to-clients 'we-joined-room room authenticated-ch)
            authenticated-ch)
          #:promise? #t))))

  (define user-controller
    (spawn ^user-controller))
  (values user user-controller))
;; --- END OF COPY ---

;; ;; UI stuff lifted from fantasary
(define (sxml->dom exp)
  (match exp
    ;; The simple case: a string representing a text node.
    ((? string? str)
     (make-text-node str))
    ((? number? num)
     (make-text-node (number->string num)))
    ;; An element tree.  The first item is the HTML tag.
    (((? symbol? tag) . body)
     ;; Create a new element with the given tag.
     (let ((elem (make-element (symbol->string tag))))
       (define (add-children children)
         ;; Recursively call sxml->dom for each child node and
         ;; append it to elem.
         (for-each (lambda (child)
                     (append-child! elem (sxml->dom child)))
                   children))
       (match body
         ((('@ . attrs) . children)
          (for-each (lambda (attr)
                      (match attr
                        (((? symbol? name) (? string? val))
                         (set-attribute! elem
                                         (symbol->string name)
                                         val))
                        (((? symbol? name) (? number? val))
                         (set-attribute! elem
                                         (symbol->string name)
                                         (number->string val)))

                        (((? symbol? name) (? procedure? proc))
                         (add-event-listener! elem
                                              (symbol->string name)
                                              (procedure->external proc)))))
                    attrs)
          (add-children children))
         (children (add-children children)))
       elem))))
;; ;; --- END OF FANTASARY ---

;; Setup goblins
(define ocapn-vat
  (spawn-vat #:name "OCapN"))
(define chatroom-vat
  (spawn-vat #:name "chatroom"))

(define fake-network
  (with-vat ocapn-vat
    (spawn ^fake-network)))

(define chatroom-sref
  (with-vat chatroom-vat
    (let* ((new-conn-ch (make-channel))
           (location (make-ocapn-node 'fake "chatroom" #f))
           (netlayer
            (spawn ^fake-netlayer "chatroom" fake-network new-conn-ch))
           (mycapn (spawn-mycapn netlayer))
           (chatroom (spawn ^chatroom "chatroom")))
      (<-np fake-network 'register "chatroom" new-conn-ch)
      (<- mycapn 'register chatroom 'fake))))

;; ----

(define (make-chat-client username dom-id)
  (define ui-area (get-element-by-id dom-id))
  (define user-controller #f)
  (define authorized-channel #f)
  (define msgs '())
  (define new-message-input-id
    (format #f "new-message-input-~a" username))
  (define vat (spawn-vat #:name username))

  (define (send-new-message event)
    (event-prevent-default event)
    (define message-input-element
      (get-element-by-id new-message-input-id))
    (define message-str
      (element-value message-input-element))
    ;; Clear the message input...
    (set-element-value! message-input-element "")

    (unless (string-null? message-str)
      (with-vat vat
        (<-np authorized-channel 'send-message message-str))))

  (define (^client _bcom)
    (methods
     [(we-joined-room room channel)
      (define inbox (spawn ^channel-inbox room))
      (<- authorized-channel 'subscribe inbox)]
     [(new-message from msg) 'noop]))

  (define (^channel-inbox bcom room)
    (define (add-to-chatlog! msg)
      (set! msgs (append msgs `((p ,msg))))
      (draw-ui!))
    (methods
     ([user-joined user]
      (on (<- user 'self-proposed-name)
          (lambda (spn)
            (add-to-chatlog! (format #f "~a joined" spn)))))
     ([user-left user]
      (on (<- user 'self-proposed-name)
          (lambda (spn)
            (add-to-chatlog! (format #f "~a left" spn)))))
     ([new-message room from message]
      (on (<- from 'self-proposed-name)
          (lambda (spn)
            (add-to-chatlog! (format #f "<~a> ~a" spn message)))))))

  (define (goblin-chat-ui)
    `(div
      (h2 ,username)
      (div (@ (class "chatlog")) ,@msgs)
      (form (@ (class "chat-input")
               (submit ,send-new-message))
            (label (@ (for ,new-message-input-id))
		   ,(format #f "<~a> " username))
            (input (@ (id ,new-message-input-id)
                      (type "text")))
            (button (@ (type "submit")) "Send!"))))

  ;; Draw the goblin chat GUI
  (define (draw-ui!)
    (set-element-inner-html! ui-area "")
    (append-child! ui-area (sxml->dom (goblin-chat-ui))))
  (draw-ui!)

  ;; Setup OCapN
  (define location (make-ocapn-node 'fake username #f))
  (with-vat vat
    (define new-conn-ch (make-channel))
    (<-np fake-network 'register username new-conn-ch)
    (define netlayer
      (spawn ^fake-netlayer username fake-network new-conn-ch))
    (define mycapn
      (spawn-mycapn netlayer))
    (on (<- mycapn 'enliven chatroom-sref)
        (lambda (chatroom)
          (define-values (user my-user-controller)
            (spawn-user-controller-pair username))
          (set! user-controller my-user-controller)
          (<-np user-controller 'connect-client (spawn ^client))
          (set! authorized-channel (<- user-controller 'join-room chatroom))
          #f))))

(make-chat-client "Alice" "goblin-chat-client-a")
(make-chat-client "Bob" "goblin-chat-client-b")
