;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/channel.scm — Generic interface channel
;;;
;;; A ^channel is one interface surface (a Matrix room, a Telegram chat,
;;; a web tab, a voice line) bound to one backend. The backend is just
;;; an actor ref implementing the 3-method protocol below — could be a
;;; single VF planning scope (^scope-handler), an N-way fan-out
;;; (^scope-router), or anything else satisfying the contract.
;;;
;;; The channel never sees a scope directly. It holds a backend ref and
;;; talks to it asynchronously (<-) so the backend can live anywhere
;;; (local vat, remote machine over OCapN). This is what makes scopes
;;; movable and channels light.
;;;
;;; Backend protocol (3 methods):
;;;   (handle request-ctx command-name args-string)
;;;       → ('response text) | ('error reason)
;;;   (available-commands) → list of command-name strings
;;;   (wire-output sink-ref) → void   (register output channel for
;;;                                    async pushes like alerts)
;;;
;;; The channel holds an optional ^flow-runner for multi-turn flows.
;;; While a user has an active flow, raw input is fed to the flow runner
;;; rather than the backend. Two channel-level commands manage flows:
;;;
;;;   /start <flow-name>   begin a flow
;;;   /cancel              abort the currently-active flow
;;;
;;; ── Participants ─────────────────────────────────────────────────────
;;; The channel tracks `participants`: who is present in the room right
;;; now, plus their *transport-level* room capabilities (can-speak,
;;; can-mute, can-admin-this-room). This is purely an interface-layer
;;; concept, derived from transport events. It is NEVER a scope roster
;;; and never governance. Voice in any scope is computed from validated
;;; labour at that scope (see docs/commons.typ §Scopes), independently
;;; of room presence.
;;;
;;; The channel self-ref is captured via 'set-self after spawn (so flows
;;; and handlers can reach back into the channel via ctx-reply etc.).
;;; Use `make-channel` rather than calling spawn directly — it primes
;;; the self-ref for you.

(define-module (playnet interface channel)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 match)
  #:use-module (playnet interface call-context)
  #:export (^channel
            make-channel))


;; =========================================================================
;; make-channel — keyword-arg constructor
;; =========================================================================
;; Goblins constructors take positional args; ^channel takes nine of them
;; and needs a post-spawn `set-self` call to learn its own ref. Wrapping
;; both in a single keyword constructor means callers never spawn ^channel
;; directly and never see the self-ref priming.

(define* (make-channel channel-id backend sink-ref
                       #:key
                       (transport #f)
                       (channel-context #f)
                       (participants (hashmap))
                       (flow-runner #f))
  "Spawn a ^channel and prime it with its own self-ref. Call inside a
   vat context. CHANNEL-ID is a string; BACKEND implements the backend
   protocol; SINK-REF is an ^output-sink. All other arguments are keyword
   options. PARTICIPANTS, if provided, is a hashmap user-id → room-caps."
  (let ((ref (spawn ^channel channel-id backend sink-ref
                    transport channel-context participants
                    flow-runner #f)))
    ($ ref 'set-self ref)
    ref))


;; =========================================================================
;; Input routing
;; =========================================================================
;; A single decision table: given a parsed (cmd, args) plus whether the
;; user is mid-flow, return a result or vow that `deliver-result` will
;; render to the transport.  Pulled out of ^channel so the routing
;; rules stand on their own and read top-down.

(define (route-input ctx cmd args raw-text in-flow? backend flow-runner)
  (cond
   ;; /cancel always honoured — escape hatch from any flow.
   ((and flow-runner (equal? cmd "cancel"))
    ($ flow-runner 'cancel ctx))

   ;; Mid-flow: every other line is input to the current step.
   (in-flow?
    ($ flow-runner 'feed ctx raw-text))

   ;; /start <flow-name>
   ((and flow-runner (equal? cmd "start"))
    (start-flow-from-cmd ctx flow-runner args))

   ;; Nothing parseable.
   ((not cmd)
    (list 'error "No command found in input"))

   ;; Normal backend dispatch (async — works for remote backends too).
   (else
    (<- backend 'handle ctx cmd args))))

(define (start-flow-from-cmd ctx flow-runner args)
  (let* ((trimmed (and args (string-trim-both args)))
         (name    (and trimmed (not (string-null? trimmed))
                       (string->symbol trimmed))))
    (if name
        ($ flow-runner 'start ctx name)
        (let ((names ($ flow-runner 'names)))
          (list 'response
                (if (null? names)
                    "Usage: /start <flow-name>  (no flows registered)"
                    (format #f "Usage: /start <flow-name>\nAvailable: ~a"
                            (string-join (map symbol->string names)
                                         ", "))))))))


;; =========================================================================
;; ^channel — backend-agnostic interface channel
;; =========================================================================

(define (^channel bcom
                  channel-id        ;; string: unique identifier ("tg-12345", "mx-!abc:server")
                  backend           ;; actor ref implementing backend protocol (local or remote)
                  sink-ref          ;; ^output-sink actor ref
                  transport         ;; ^transport-adapter actor ref, or #f
                  channel-context   ;; opaque transport destination, or #f
                  participants      ;; hashmap: user-id string -> room-caps alist
                  flow-runner       ;; ^flow-runner actor ref, or #f
                  self-ref)         ;; this channel's own ref (set post-spawn), or #f

  (define* (rebuild #:key
                    (cid channel-id) (be backend) (sk sink-ref)
                    (tr transport) (cc channel-context)
                    (ps participants) (fr flow-runner) (sr self-ref))
    (bcom (^channel bcom cid be sk tr cc ps fr sr)))

  (define (reply-text text)
    ;; Send TEXT back through the bound transport, if any.
    (when (and transport text)
      (<-np transport 'send-message channel-context text)))

  (define (deliver-result result-vow)
    ;; Wait for ('response text) / ('error reason) and surface to transport.
    (on result-vow
        (lambda (result)
          (match result
            (('response text) (reply-text text))
            (('error reason)  (reply-text (format #f "Error: ~a" reason)))
            (('silent) #t)
            (_ (reply-text (format #f "~a" result))))
          result)))

  (methods

    ;; --- Identity --------------------------------------------------------
    ((id) channel-id)
    ((backend) backend)
    ((self) self-ref)

    ((set-self ref)
     ;; Called by make-channel immediately after spawn so the channel
     ;; can include itself in call-contexts handed to handlers and flows.
     (rebuild #:sr ref))

    ;; --- Participants ----------------------------------------------------
    ;; Room presence + transport-level room caps. NOT governance.
    ;; ROOM-CAPS is an alist; conventional keys:
    ;;   display-name  — for UX
    ;;   room-caps     — list of symbols, e.g. '(speak admin)
    ;;                    — purely transport-level: ability to talk in
    ;;                      this room, mute the room, admin the room.
    ;;                      NEVER scope-governance roles.

    ((participant-joined user-id display-name room-caps)
     (rebuild #:ps (hashmap-set participants user-id
                                `((display-name . ,display-name)
                                  (room-caps    . ,room-caps)))))

    ((participant-left user-id)
     (rebuild #:ps (hashmap-remove participants user-id)))

    ((participants)
     (hashmap-fold (lambda (k v acc) (cons (cons k v) acc))
                   '() participants))

    ((participant? user-id)
     (hashmap-ref participants user-id #f))

    ;; --- Flow attachment -------------------------------------------------
    ((set-flow-runner fr)
     (rebuild #:fr fr))

    ((flow-runner) flow-runner)

    ((start-flow user-id flow-name)
     ;; Programmatic flow entry (independent of /start command). Returns
     ;; the ('response text) | ('error reason) tuple.
     (if (not flow-runner)
         (list 'error "No flow runner attached to this channel.")
         (let ((ctx (make-request-ctx user-id channel-id self-ref #f)))
           (let ((result ($ flow-runner 'start ctx flow-name)))
             (deliver-result result)
             result))))

    ((cancel-flow user-id)
     (when flow-runner
       (let ((ctx (make-request-ctx user-id channel-id self-ref #f)))
         (let ((result ($ flow-runner 'cancel ctx)))
           (deliver-result result)
           result))))

    ;; --- Output side -----------------------------------------------------
    ((send-out text)
     ;; Public helper for handlers/flows: push TEXT out as an extra
     ;; message via the bound transport (or queue through the sink if
     ;; offline). Goes through sink-ref so offline queueing works.
     (<-np sink-ref 'print text))

    ;; --- Command entry point (from transport) ---------------------------
    ((handle-input user-id raw-text)
     ;; Routing precedence:
     ;;   1. No transport bound → error (defensive).
     ;;   2. Parse the transport's command prefix (e.g. /, !, ,).
     ;;   3. /cancel — always honoured, even mid-flow (escape hatch).
     ;;   4. /start <name> — begin a flow.
     ;;   5. Mid-flow text — feed the flow-runner.
     ;;   6. Otherwise → backend.
     (if (not transport)
         (list 'error "No transport bound")
         (let* ((ctx     (make-request-ctx user-id channel-id
                                           self-ref raw-text))
                (parsed  ($ transport 'parse-command raw-text))
                (cmd     (car parsed))
                (args    (cdr parsed))
                (in-flow? (and flow-runner
                               ($ flow-runner 'active? user-id))))
           (deliver-result
            (route-input ctx cmd args raw-text in-flow?
                         backend flow-runner)))))

    ;; --- Transport binding ----------------------------------------------
    ((bind-transport new-transport new-context)
     ($ sink-ref 'bind-transport new-transport new-context)
     (<-np backend 'wire-output sink-ref)
     (rebuild #:tr new-transport #:cc new-context))

    ((unbind-transport)
     ($ sink-ref 'unbind-transport)
     (rebuild #:tr #f #:cc #f))

    ;; --- Backend delegation ---------------------------------------------
    ((available-commands)
     (<- backend 'available-commands))))
