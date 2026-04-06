;;; module/weave/meeting.scm — ^meeting Goblins actor
;;;
;;; A ^meeting is the umbrella actor for a full Weave meeting session.
;;; It owns one main room and optionally N breakout rooms, tracks the
;;; current phase, records participant assignments, and collects help signals.
;;;
;;; VF grounding:
;;;   - meeting  = <agent> type=organization (short-lived org, social container)
;;;                AND <process> (economic activity being carried out)
;;;   - phase    = child <process> of the meeting process
;;;   - breakout assignment = <agent-relationship>: participant plays-in breakout-org
;;;   - help signal = <intent> action=work, triggered by a participant's need
;;;
;;; Breakout dispatch uses LiveKit SendData to tell each participant
;;; their new room assignment.  The browser WASM receives the message via
;;; the DataReceived callback, disconnects from the current room, and
;;; reconnects to the assigned breakout room.

(define-module (weave meeting)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-9)
  #:use-module (weave livekit)
  #:use-module (weave room)
  #:export (^meeting
            ^meeting-manager
            make-meeting-id))

;;; ── Meeting ID generation ─────────────────────────────────────────────────────

(define (make-meeting-id)
  "Generate a short, URL-safe meeting identifier."
  (let loop ((n 8) (acc "mtg-"))
    (if (= n 0)
        acc
        (loop (- n 1)
              (string-append acc (number->string (random 256) 16))))))

;;; ── ^meeting actor ────────────────────────────────────────────────────────────

(define (^meeting bcom meeting-id main-room-id room-manager)
  "Manages one full meeting session.
   MAIN-ROOM-ID — LiveKit/Weave room id of the plenary room.
   ROOM-MANAGER — ref to the ^room-manager actor."

  ;; ── Mutable state ────────────────────────────────────────────────────────────
  (define phase        'lobby)         ; 'lobby | 'active | 'breakout | 'closed
  (define breakouts    '())            ; list of (room-id . lk-room-name) pairs
  (define assignments  (make-hash-table)) ; livekit-identity → room-id
  (define help-signals '())            ; list of alists: ((identity . ..) (room . ..) (ts . ..))

  ;; ── Helpers ──────────────────────────────────────────────────────────────────

  (define (assign-round-robin identities count)
    "Distribute IDENTITIES into COUNT groups. Returns alist: identity → group-index."
    (let loop ((ids identities) (n 0) (acc '()))
      (if (null? ids)
          acc
          (loop (cdr ids)
                (modulo (+ n 1) count)
                (cons (cons (car ids) n) acc)))))

  ;; ── Methods ──────────────────────────────────────────────────────────────────

  (methods
   ;; ── Read ──────────────────────────────────────────────────────────────────
   ((get-info)
    `((meeting-id    . ,meeting-id)
      (main-room-id  . ,main-room-id)
      (phase         . ,phase)
      (breakout-count . ,(length breakouts))))

   ((get-phase) phase)

   ((get-breakouts) breakouts)

   ((get-assignment identity)
    (hash-ref assignments identity #f))

   ((get-all-assignments)
    (hash-fold (lambda (id room acc) (cons (cons id room) acc))
               '() assignments))

   ;; ── Phase transitions ─────────────────────────────────────────────────────
   ((start!)
    (set! phase 'active)
    #t)

   ((close!)
    (set! phase 'closed)
    #t)

   ;; ── Breakout dispatch ─────────────────────────────────────────────────────
   ((dispatch-breakouts! identities count)
    "Create COUNT breakout rooms, assign IDENTITIES round-robin, signal them via LiveKit.
     Returns a list of ((room-id . lk-name) . '(identity ...)) for the host overview."
    (set! phase 'breakout)

    ;; Create breakout rooms in LiveKit and register them.
    ;; We're already inside the vat, so $ works directly on room-manager.
    (let* ((rooms (let loop ((n count) (acc '()))
                    (if (= n 0)
                        acc
                        (let* ((lk-name (string-append meeting-id "-b"
                                                       (number->string n)))
                               (id+ref  ($ room-manager 'create-room! lk-name)))
                          (livekit-create-room lk-name)
                          (loop (- n 1) (cons (cons (car id+ref) lk-name) acc))))))
           (group-map (assign-round-robin identities count)))

      (set! breakouts rooms)

      ;; Record per-participant room assignment
      (for-each (lambda (id+group)
                  (let* ((identity   (car id+group))
                         (group-idx  (cdr id+group))
                         (room-entry (list-ref rooms group-idx))
                         (room-id    (car room-entry)))
                    (hash-set! assignments identity room-id)))
                group-map)

      ;; Signal each participant via LiveKit SendData
      ;; Message format: "move:<room-id>"
      (for-each (lambda (id+group)
                  (let* ((identity (car id+group))
                         (room-id  (hash-ref assignments identity #f)))
                    (when room-id
                      (livekit-send-data
                       main-room-id
                       (string-append "move:" room-id)
                       (list identity)))))
                group-map)

      ;; Return overview: list of (room-id lk-name . identities-in-room)
      (map (lambda (room-entry)
             (let* ((room-id  (car room-entry))
                    (lk-name  (cdr room-entry))
                    (members  (hash-fold
                               (lambda (id rid acc)
                                 (if (string=? rid room-id)
                                     (cons id acc)
                                     acc))
                               '() assignments)))
               `((room-id  . ,room-id)
                 (lk-name  . ,lk-name)
                 (members  . ,members))))
           rooms)))

   ((dispatch-custom! assignment-alist)
    "Dispatch breakouts with an explicit ASSIGNMENT-ALIST: ((identity . room-id) ...).
     Rooms must already exist.  Signals each participant."
    (set! phase 'breakout)
    (for-each (lambda (id+room)
                (let ((identity (car id+room))
                      (room-id  (cdr id+room)))
                  (hash-set! assignments identity room-id)
                  (livekit-send-data
                   main-room-id
                   (string-append "move:" room-id)
                   (list identity))))
              assignment-alist)
    #t)

   ((recall!)
    "Send all participants back to the main room."
    (set! phase 'active)
    ;; Signal everyone currently assigned to a breakout
    (hash-fold (lambda (identity _room-id _acc)
                 (livekit-send-data
                  main-room-id
                  (string-append "move:" main-room-id)
                  (list identity))
                 #f)
               #f assignments)
    ;; Reset assignment table
    (set! assignments (make-hash-table))
    ;; Delete breakout rooms from LiveKit
    (for-each (lambda (room-entry)
                (catch #t
                  (lambda () (livekit-delete-room (cdr room-entry)))
                  (lambda _ #f)))
              breakouts)
    (set! breakouts '())
    #t)

   ;; ── Help signals ──────────────────────────────────────────────────────────
   ((signal-help! identity room-id)
    "Record a help request from IDENTITY in ROOM-ID."
    (set! help-signals
      (cons `((identity . ,identity)
              (room-id  . ,room-id)
              (ts       . ,(car (gettimeofday))))
            help-signals))
    #t)

   ((get-help-signals)
    "Return accumulated help signals and clear the queue."
    (let ((signals help-signals))
      (set! help-signals '())
      signals))))

;;; ── ^meeting-manager actor ───────────────────────────────────────────────────
;;; One instance per server vat; owns the registry of all ^meeting actors.

(define (^meeting-manager bcom room-manager)
  "Registry of all active ^meeting actors."
  (define meetings (make-hash-table))

  (methods
   ((create-meeting! name)
    "Create a LiveKit main room, a ^room actor, and a ^meeting actor.
     Returns (meeting-id . meeting-ref).
     Called from inside the vat — spawn works directly here."
    (let* ((mid     (make-meeting-id))
           (rm-name (string-append mid "-main"))
           ;; Register the room actor (also creates in LiveKit below)
           (id+ref  ($ room-manager 'create-room! rm-name))
           (room-id (car id+ref))
           ;; Create the LiveKit room (after room actor is registered)
           (_       (catch #t
                      (lambda () (livekit-create-room rm-name))
                      (lambda _ #f)))
           (meeting (spawn ^meeting mid room-id room-manager)))
      (hash-set! meetings mid meeting)
      (cons mid meeting)))

   ((get-meeting id)
    (hash-ref meetings id #f))

   ((list-meetings)
    (hash-fold (lambda (id m acc) (cons (cons id m) acc)) '() meetings))

   ((delete-meeting! id)
    (hash-remove! meetings id)
    #t)))
