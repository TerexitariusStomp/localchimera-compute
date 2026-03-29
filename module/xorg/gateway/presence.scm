;;; module/xorg/gateway/presence.scm — Presence tracking via OCapN
;;;
;;; Replaces the relay's *sessions* + *presence* hash tables with a
;;; Goblins actor.  Connected users announce themselves with a display
;;; name and an inbox actor ref.  The presence actor broadcasts updates
;;; and introduces peers for direct P2P messaging.

(define-module (xorg gateway presence)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (^presence))

(define (online-user-list sessions)
  "Return a list of display names from the sessions hashmap."
  (hashmap-fold (lambda (name _inbox acc) (cons name acc))
                '() sessions))

(define (broadcast-presence! sessions)
  "Fire-and-forget presence update to all connected inboxes."
  (let ((users (online-user-list sessions)))
    (hashmap-fold
     (lambda (_name inbox _acc)
       (catch #t
         (lambda () (<-np inbox 'presence-update users))
         (lambda args #f))  ;; ignore unreachable inboxes
       #f)
     #f sessions)))

(define (^presence bcom sessions)
  ;; sessions: hashmap of display-name -> inbox actor ref

  (methods

   ;; Register a user and broadcast updated presence.
   ;; Returns the current user list.
   ((announce name user-inbox)
    (let ((new-sessions (hashmap-set sessions name user-inbox)))
      (bcom (^presence bcom new-sessions))
      (broadcast-presence! new-sessions)
      (online-user-list new-sessions)))

   ;; Remove a user and broadcast.
   ((leave name)
    (let ((new-sessions (hashmap-remove sessions name)))
      (bcom (^presence bcom new-sessions))
      (broadcast-presence! new-sessions)))

   ;; List currently connected users.
   ((online-users)
    (online-user-list sessions))

   ;; Introduce caller to another user by returning their inbox ref.
   ;; Returns #f if the target is not online.
   ((introduce target-name)
    (hashmap-ref sessions target-name #f))

   ;; Relay a WebRTC signaling message to a target peer.
   ;; signal-type is 'offer, 'answer, or 'ice-candidate.
   ;; Returns 'sent or 'peer-not-found.
   ((signal target-name from-name signal-type signal-data)
    (let ((target-inbox (hashmap-ref sessions target-name #f)))
      (when target-inbox
        (<-np target-inbox 'webrtc-signal from-name signal-type signal-data))
      (if target-inbox 'sent 'peer-not-found)))))
