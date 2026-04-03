;;; module/playnet/interface/scope-backend.scm — Scope-backed channel backend
;;;
;;; Implements the backend protocol for a VF planning scope:
;;;
;;;   (handle user-id command-name args-string) → ('response text) | ('error reason)
;;;   (available-commands) → list of command name strings
;;;   (record-event event) → affected resources
;;;   (query method . args) → result from observer
;;;   (wire-output sink-ref) → void
;;;
;;; The scope-backend closes over its own scope-ref, org-ref, command
;;; dispatch, and tee-alert-store. The channel never sees these internals.
;;;
;;; Because the backend is just an actor ref, it can live in any vat on
;;; any machine. OCapN makes local/remote transparent — the channel uses
;;; <- to talk to it, so a scope running on a remote server works the
;;; same as a local one. This means scopes can be migrated between
;;; machines, and compute/memory for hosting them can be tracked as
;;; economic resources in the planner itself.

(define-module (playnet interface scope-backend)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet interface command-dispatch)
  #:use-module (playnet interface notification-sink)
  #:export (^scope-backend
            make-scope-backend))


;; =========================================================================
;; ^scope-backend — backend protocol for a VF planning scope
;; =========================================================================

(define (^scope-backend bcom
                         scope-ref       ;; ^scope-root actor ref (near)
                         org-ref         ;; ^org actor ref (near)
                         dispatch-ref    ;; ^command-dispatch actor ref (near)
                         tee-store-ref)  ;; ^tee-alert-store (near, interposed on alert-store)

  (methods

    ;; --- Backend protocol ---

    ((handle user-id command-name args-string)
     ;; Dispatch a command. The dispatch-ref knows the command table;
     ;; scope-ref and org-ref provide the data.
     ($ dispatch-ref 'dispatch scope-ref org-ref user-id
        command-name args-string))

    ((available-commands)
     ($ dispatch-ref 'available-commands))

    ;; --- Scope-specific operations ---
    ;; These go beyond the generic backend protocol — callers that know
    ;; they're talking to a scope-backend can use them directly.

    ((record-event event)
     ;; Record through the observer with monitors firing through the tee.
     ;; The tee-alert-store automatically forwards alerts to any wired sink.
     (let* ((obs ($ scope-ref 'observer))
            (ctx (make-execution-context scope-ref)))
       (record-and-monitor obs event ctx tee-store-ref)))

    ((query method . args)
     ;; Proxy to scope's observer.
     (let ((obs ($ scope-ref 'observer)))
       (apply $ obs method args)))

    ((register-command name handler)
     ($ dispatch-ref 'register-command name handler))

    ;; --- Notification wiring ---

    ((wire-output sink-ref)
     ;; The tee-alert-store was wired at construction time to forward
     ;; push-alert calls to the sink. Nothing extra needed here —
     ;; the sink is already receiving alerts.
     'ok)

    ;; --- Introspection ---

    ((scope) scope-ref)
    ((org) org-ref)))


;; =========================================================================
;; Execution context builder
;; =========================================================================

(define (make-execution-context scope-ref)
  "Build an execution context alist from a ^scope-root ref."
  `((observer          . ,($ scope-ref 'observer))
    (plan-store        . ,($ scope-ref 'plan-store))
    (buffer-zone-store . ,($ scope-ref 'buffer-zone-store))
    (snapshot-store    . ,($ scope-ref 'snapshot-store))))


;; =========================================================================
;; Convenience constructor
;; =========================================================================

(define (make-scope-backend scope-ref org-ref)
  "Spawn a complete scope-backend with standard command table and
   tee-alert-store wiring. Call within a vat context.
   Returns (values backend-ref sink-ref) — caller wires sink to transport."
  (let* ((alert-st   ($ scope-ref 'alert-store))
         (sink-ref   (spawn ^output-sink
                            #f    ;; no channel-context yet
                            #f    ;; no transport yet
                            default-alert-formatter
                            '())) ;; empty queue
         (tee-ref    (spawn ^tee-alert-store alert-st sink-ref))
         (dispatch   (spawn ^command-dispatch (standard-command-table)))
         (backend    (spawn ^scope-backend scope-ref org-ref dispatch tee-ref)))
    (values backend sink-ref)))
