;;; module/playnet/gateway/presence.scm — Presence tracking via OCapN
;;;
;;; Replaces the relay's *sessions* + *presence* hash tables with a
;;; Goblins actor.  Connected users announce themselves with a display
;;; name and an inbox actor ref.  The presence actor broadcasts updates
;;; and introduces peers for direct P2P messaging.
;;;
;;; It also holds the MEETING ROSTERS: a room is a topic string, its roster is
;;; the announced names inside it, and the walkie meshes over that roster
;;; rather than over everyone online (docs/planning/faces/meeting-station.md, Layer 0).

(define-module (playnet gateway presence)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:export (^presence))

(define (online-user-list sessions)
  (hashmap-fold (lambda (name _inbox acc) (cons name acc))
                '() sessions))

;; A dead or wedged inbox must never take a broadcast down with it — one peer
;; whose session is closing would otherwise stop everyone else being told.
(define (notify! inbox msg . args)
  (catch #t
    (lambda () (apply <-np inbox msg args))
    (lambda _ #f)))

(define (broadcast-presence! sessions)
  (let ((users (online-user-list sessions)))
    (hashmap-fold
     (lambda (_name inbox _acc) (notify! inbox 'presence-update users) #f)
     #f sessions)))

;;; ── meeting rooms ────────────────────────────────────────────────────
;;; A room is a topic string (`meeting/<scope>/<slug>`) and its roster is the
;;; set of announced names currently in it. The roster is what the walkie
;;; meshes over: a peer offers to the roster, not to everyone online. Empty
;;; rooms drop out of the map — a room with nobody in it is not live.

(define (roster-of rooms room)
  (hashmap-ref rooms room '()))

(define (rooms-with rooms name)          ; every room NAME is currently in
  (hashmap-fold (lambda (room members acc)
                  (if (member name members) (cons room acc) acc))
                '() rooms))

(define (room-drop rooms room name)
  (let ((members (delete name (roster-of rooms room))))
    (if (null? members)
        (hashmap-remove rooms room)
        (hashmap-set rooms room members))))

;; Tell every member of ROOM who is in it now. Departing members are notified
;; by their own reply, so this is addressed to the roster as it now stands.
(define (broadcast-roster! sessions rooms room)
  (let ((members (roster-of rooms room)))
    (for-each (lambda (name)
                (let ((inbox (hashmap-ref sessions name #f)))
                  (when inbox (notify! inbox 'room-roster room members))))
              members)))

(define* (^presence bcom sessions
                    #:optional (notification-sink #f)
                               (notification-adapter #f)
                               (rooms (make-hashmap)))
  ;; sessions: hashmap of display-name → inbox actor ref
  ;; notification-sink: ^output-sink ref (queues alerts when no user connected)
  ;; notification-adapter: ^browser-adapter ref (translates send-message → notify)
  ;; rooms: hashmap of room-topic → list of member names (the meeting rosters)

  (define (self s r)
    (^presence bcom s notification-sink notification-adapter r))

  ;; Every room write ends the same way: tell the room who is in it now, then
  ;; become the new state and answer with the roster. Naming it keeps join and
  ;; leave down to the one line that actually differs between them.
  (define (settle new-rooms room)
    (broadcast-roster! sessions new-rooms room)
    (bcom (self sessions new-rooms) (roster-of new-rooms room)))

  (methods

   ;; NOTE: `bcom` seals a record that only takes effect when it is the
   ;; method's RETURN value (goblins/core.scm checks `bcom-sealed?` on what
   ;; the handler returned). Every state-changing method below therefore ends
   ;; in `(bcom <new-behavior> <reply>)` — the reply rides as the 2nd argument.
   ;; Side effects (broadcasts, sink binding) run first, on the new state.
   ((announce name user-inbox)
    (let ((new-sessions (hashmap-set sessions name user-inbox)))
      ;; Bind notification sink to this user's inbox (flushes queued alerts).
      ;; <-np because the sink may be in a different vat (planner-vat).
      (when (and notification-sink notification-adapter)
        (<-np notification-sink 'bind-transport notification-adapter user-inbox))
      (broadcast-presence! new-sessions)
      (bcom (self new-sessions rooms)
            (online-user-list new-sessions))))

   ;; Leaving the gateway leaves every room too — a disconnected peer is not
   ;; in a meeting, and a roster that outlives the session would have the
   ;; walkie offering to a dead inbox.
   ;; A name that is neither a session nor in any room is a no-op: nothing
   ;; is broadcast and the sink keeps whatever transport it has — a forget
   ;; (identity/forget.scm) leaves by several names, and a name presence
   ;; never held must not cut another live user's alerts.
   ((leave name)
    (let* ((held?        (and (hashmap-ref sessions name #f) #t))
           (was-in       (rooms-with rooms name)))
      (if (not (or held? (pair? was-in)))
          (online-user-list sessions)
          (let* ((new-sessions (hashmap-remove sessions name))
                 (new-rooms    (fold (lambda (room acc) (room-drop acc room name))
                                     rooms was-in)))
            (when (and held? notification-sink)
              (<-np notification-sink 'unbind-transport))
            (broadcast-presence! new-sessions)
            (for-each (lambda (room) (broadcast-roster! new-sessions new-rooms room))
                      was-in)
            (bcom (self new-sessions new-rooms)
                  (online-user-list new-sessions))))))

   ;; ── rooms ─────────────────────────────────────────────────────────
   ;; Join is idempotent: re-joining a room you are in returns the roster
   ;; unchanged, so a reconnecting client can call it freely.
   ((join-room room name)
    (let ((members (roster-of rooms room)))
      (settle (if (member name members)
                  rooms
                  (hashmap-set rooms room (cons name members)))
              room)))

   ((leave-room room name)
    (settle (room-drop rooms room name) room))

   ((room-roster room) (roster-of rooms room))

   ;; Every live room and who is in it. The seed of the meeting wake: it is
   ;; the whole always-on index at counts-and-names resolution.
   ((live-rooms)
    (hashmap-fold (lambda (room members acc) (cons (cons room members) acc))
                  '() rooms))

   ((online-users)
    (online-user-list sessions))

   ((introduce target-name)
    (hashmap-ref sessions target-name #f))

   ((signal target-name from-name signal-type signal-data)
    (let ((target-inbox (hashmap-ref sessions target-name #f)))
      (when target-inbox
        (<-np target-inbox 'webrtc-signal from-name signal-type signal-data))
      (if target-inbox 'sent 'peer-not-found)))

   ;; Push a structured event alist through the sink. The adapter
   ;; handles all formatting. Queued if no user is connected.
   ((notify-event event-alist)
    (when notification-sink
      (<-np notification-sink 'print event-alist)))))
