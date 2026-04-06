;;; module/weave/room.scm — ^room Goblins actor
;;;
;;; A ^room actor represents one Weave meeting room in the server's vat.
;;; It tracks which agent IDs are currently present, their roles, and
;;; the room's lifecycle status.
;;;
;;; VF grounding:
;;;   - Each room corresponds to a VF <process> (meeting activity)
;;;   - Each occupant is a VF <agent> type=person
;;;   - Occupant roles are VF <agent-relationship-role> (facilitates / participates-in / observes)
;;;
;;; ^room does NOT manage LiveKit directly — that is the server's job.
;;; ^room is the authoritative source of room state; LiveKit is the AV substrate.

(define-module (weave room)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-9)
  #:export (^room
            ^room-manager
            make-room-id))

;;; ── Room ID generation ───────────────────────────────────────────────────────

(define (make-room-id)
  "Generate a short, URL-safe room identifier."
  ;; 8 random hex bytes → 16 char string
  (let loop ((n 8) (acc ""))
    (if (= n 0)
        acc
        (loop (- n 1)
              (string-append acc
                (number->string (random 256) 16))))))

;;; ── Occupant record ─────────────────────────────────────────────────────────

(define-record-type <occupant>
  (make-occupant agent-id display-name role attribution-mode livekit-identity joined-at)
  occupant?
  (agent-id         occupant-agent-id)
  (display-name     occupant-display-name)
  (role             occupant-role)            ; 'convener | 'participant | 'observer
  (attribution-mode occupant-attribution-mode) ; 'named | 'anonymous
  (livekit-identity occupant-livekit-identity)
  (joined-at        occupant-joined-at))       ; Unix timestamp

;;; ── ^room actor ──────────────────────────────────────────────────────────────

(define (^room bcom id name)
  "A room actor. ID is a string (URL-safe), NAME is a human-readable title.
   State: id, name, status, occupants (alist: livekit-identity → <occupant>)"
  (define state
    (list 'status 'open
          'occupants '()))

  (define (get-status)  (cadr (memq 'status state)))
  (define (get-occupants) (cadr (memq 'occupants state)))

  (define (set-status! s)
    (set! state (list 'status s 'occupants (get-occupants))))
  (define (set-occupants! o)
    (set! state (list 'status (get-status) 'occupants o)))

  (methods
   ;; ── Read ────────────────────────────────────────────────
   ((get-info)
    `((id      . ,id)
      (name    . ,name)
      (status  . ,(get-status))
      (count   . ,(length (get-occupants)))))

   ((get-status)     (get-status))
   ((get-occupants)  (get-occupants))

   ((get-occupant livekit-identity)
    (assoc livekit-identity (get-occupants)))

   ((count) (length (get-occupants)))

   ;; ── Occupant join/leave ──────────────────────────────────
   ((join! agent-id display-name role attribution-mode livekit-identity)
    (let ((occ (make-occupant agent-id display-name role attribution-mode
                              livekit-identity (car (gettimeofday)))))
      (set-occupants!
       (cons (cons livekit-identity occ) (get-occupants)))
      occ))

   ((leave! livekit-identity)
    (set-occupants!
     (filter (lambda (pair) (not (string=? (car pair) livekit-identity)))
             (get-occupants)))
    #t)

   ;; ── Lifecycle ────────────────────────────────────────────
   ((close!)
    (set-status! 'closed)
    #t)

   ((open!)
    (set-status! 'open)
    #t)))

;;; ── ^room-manager actor ──────────────────────────────────────────────────────
;;; Maintains the registry of all active rooms. One instance per server vat.

(define (^room-manager bcom)
  "Registry of active ^room actors. Keyed by room ID string."
  (define rooms (make-hash-table))

  (methods
   ((create-room! name)
    "Create a new room, spawn its actor, register it. Returns (id . room-ref)."
    (let* ((id   (make-room-id))
           (room (spawn ^room id name)))
      (hash-set! rooms id room)
      (cons id room)))

   ((get-room id)
    "Return the ^room actor ref for ID, or #f."
    (hash-ref rooms id #f))

   ((list-rooms)
    "Return list of (id . room-ref) pairs for all open rooms."
    (hash-fold (lambda (id room acc) (cons (cons id room) acc)) '() rooms))

   ((delete-room! id)
    "Remove a room from the registry."
    (hash-remove! rooms id)
    #t)))
