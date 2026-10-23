;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/gateway/test-presence-rooms.scm — ^presence keeps state, and rooms.
;;;
;;; WHY THIS EXISTS: `bcom` seals a record that only takes effect when it is
;;; the method's RETURN value (goblins/core.scm checks `bcom-sealed?` on what
;;; the handler returned). `announce` and `leave` used to CALL bcom and then
;;; return a freshly-computed list, so the become was dropped every time: each
;;; announce returned a plausible-looking roster while the actor's own
;;; `sessions` stayed empty. Nothing caught it because the return value — the
;;; only thing anyone read — was computed from the correct local value. The
;;; consequence was total: `online-users` empty, `introduce` #f, and every
;;; WebRTC signal answering 'peer-not-found, i.e. no P2P at all.
;;;
;;; So §1 pins retention directly, not through a return value.
;;;
;;; Run: guile -L module -L tests tests/gateway/test-presence-rooms.scm

(use-modules (playnet test harness)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (playnet gateway presence)
             ((playnet doors lobby) #:select (^lobby-session))
             (srfi srfi-1))

(define vat (spawn-vat))

;; A stand-in browser inbox that records what the gateway pushed to it.
(define (^probe bcom name signals rosters)
  (methods
   ((presence-update _users) #t)
   ((webrtc-signal from ty da)
    (bcom (^probe bcom name (cons (list from ty da) signals) rosters) #t))
   ((room-roster room members)
    (bcom (^probe bcom name signals (cons (cons room members) rosters)) #t))
   ((signals-seen) signals)
   ((rosters-seen) rosters)))

(define (spawn-probe name) (spawn ^probe name '() '()))


;;; ── 1. the actor RETAINS what it is told ─────────────────────────────
(with-vat vat
  (define p (spawn ^presence (make-hashmap)))
  (define a (spawn-probe "alice"))
  (define b (spawn-probe "bob"))
  ($ p 'announce "alice" a)
  ($ p 'announce "bob" b)

  (check "both sessions retained across announces" (sort ($ p 'online-users) string<?) '("alice" "bob"))

  (check "introduce finds a retained session"
    (and ($ p 'introduce "alice") #t))

  (check "signal reaches a retained peer" ($ p 'signal "bob" "alice" "walkie-offer" "{\"sdp\":1}") 'sent)

  ;; leave really removes
  ($ p 'leave "alice")
  (check "leave removes the session" ($ p 'online-users) '("bob"))
  (check "signalling a departed peer fails cleanly" ($ p 'signal "alice" "bob" "walkie-offer" "{}") 'peer-not-found))

;;; ── 2. rooms: roster membership ──────────────────────────────────────
(with-vat vat
  (define p (spawn ^presence (make-hashmap)))
  (define a (spawn-probe "alice"))
  (define b (spawn-probe "bob"))
  (define c (spawn-probe "carol"))
  ($ p 'announce "alice" a)
  ($ p 'announce "bob" b)
  ($ p 'announce "carol" c)

  (define kitchen "meeting/commune-berlin/kitchen")
  (define cold    "meeting/commune-berlin/cold-chain")

  ($ p 'join-room kitchen "alice")
  (check "first joiner is the whole roster" ($ p 'room-roster kitchen) '("alice"))

  ($ p 'join-room kitchen "bob")
  (check "roster accumulates" (sort ($ p 'room-roster kitchen) string<?) '("alice" "bob"))

  ($ p 'join-room kitchen "bob")
  (check "join is idempotent" (sort ($ p 'room-roster kitchen) string<?) '("alice" "bob"))

  ;; a second room is independent — this is the whole point of rooms
  ($ p 'join-room cold "carol")
  (check "rooms are disjoint" ($ p 'room-roster cold) '("carol"))
  (check "carol is not in the kitchen"
    (not (member "carol" ($ p 'room-roster kitchen))))

  (check "live-rooms indexes every live room" (length ($ p 'live-rooms)) 2)

  ($ p 'leave-room kitchen "bob")
  (check "leave-room removes just that member" ($ p 'room-roster kitchen) '("alice"))

  ;; emptying a room retires it
  ($ p 'leave-room cold "carol")
  (check "an empty room stops being live" ($ p 'room-roster cold) '())
  (check "and drops out of the index" (length ($ p 'live-rooms)) 1))

;;; ── 3. disconnecting leaves every room ───────────────────────────────
(with-vat vat
  (define p (spawn ^presence (make-hashmap)))
  (define a (spawn-probe "alice"))
  (define b (spawn-probe "bob"))
  ($ p 'announce "alice" a)
  ($ p 'announce "bob" b)
  (define r1 "meeting/s/one")
  (define r2 "meeting/s/two")
  ($ p 'join-room r1 "alice") ($ p 'join-room r1 "bob")
  ($ p 'join-room r2 "alice")

  ($ p 'leave "alice")
  (check "a disconnect drops the member from room one" ($ p 'room-roster r1) '("bob"))
  (check "…and retires the room she was alone in" ($ p 'room-roster r2) '())
  (check "only the still-populated room stays live" (length ($ p 'live-rooms)) 1))

;;; ── 4. the roster is PUSHED to members ───────────────────────────────
;;; The walkie needs to hear about a joiner without polling: that push is
;;; what triggers the offer to the new peer.
(define alice-probe #f)
(define bob-probe   #f)
(define push-room   "meeting/s/push")

(with-vat vat
  (let ((p (spawn ^presence (make-hashmap)))
        (a (spawn-probe "alice"))
        (b (spawn-probe "bob")))
    (set! alice-probe a)
    (set! bob-probe b)
    ($ p 'announce "alice" a)
    ($ p 'announce "bob" b)
    ($ p 'join-room push-room "alice")
    ($ p 'join-room push-room "bob")))

(with-vat vat
  ;; assertions in a LATER turn: broadcast-roster! is <-np, so the probes'
  ;; becomes have not landed until the queue flushes.
  (let ((seen ($ alice-probe 'rosters-seen)))
    (check "alice was pushed a roster for the room"
      (and (assoc push-room seen) #t))
    (check "the newest push carries both members" (sort (cdr (assoc push-room seen)) string<?) '("alice" "bob")))
  (check "bob was pushed the roster too"
    (and (assoc push-room ($ bob-probe 'rosters-seen)) #t)))

;;; ── 5. entering a room is an act performed AS someone ────────────────
;;; The roster decides who the walkie offers a mic connection to, so a client
;;; that could name someone else could pull an AID into a meeting it never
;;; joined. `^lobby-session` closes over the AID and supplies it itself; the
;;; anonymous `^lobby` carries only the READ side.
(define sess-presence #f)
(define sess-alice    #f)
(define sess-room     "meeting/s/bound")

(with-vat vat
  (let* ((p (spawn ^presence (make-hashmap)))
         ;; ^lobby-session: aid terminal mailbox governance signup
         ;;                 [oobi acdc folksonomy presence …]
         (s (spawn ^lobby-session "EAlice" #f #f #f #f #f #f #f p)))
    (set! sess-presence p)
    (set! sess-alice s)
    ($ p 'announce "EAlice" (spawn-probe "EAlice"))
    ($ s 'join-room sess-room)))

(with-vat vat
  (check "the session joins under its OWN aid"
    ($ sess-presence 'room-roster sess-room) '("EAlice"))

  ;; the write side is gone from the anonymous surface: a session's join-room
  ;; takes ONLY a room, so there is no argument left to name a victim with.
  (check "session join-room takes no name to spoof"
    (catch #t
      (lambda () ($ sess-alice 'join-room sess-room "EBob") 'accepted)
      (lambda _ 'refused))
    'refused)

  (check "…and the roster is untouched by the attempt"
    ($ sess-presence 'room-roster sess-room) '("EAlice"))

  ($ sess-alice 'leave-room sess-room))

(with-vat vat
  (check "a session can take itself back out"
    ($ sess-presence 'room-roster sess-room) '()))

(test-summary!)
