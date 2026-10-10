;;; module/playnet/interface/backends/scope.scm — Scope handler
;;;
;;; The interface to ONE scope. Translates the channel's backend protocol
;;; into observer / planner / alert-store operations via ^command-dispatch.
;;;
;;; This is the *atom* of the backend taxonomy. A channel can bind
;;; directly to one of these (1:1 chat ↔ scope), or to a ^scope-router
;;; that fans out to many. Either way the channel only ever sees a ref
;;; satisfying:
;;;
;;;   (handle request-ctx command-name args-string)
;;;       → ('response text) | ('error reason)
;;;   (available-commands) → list of command-name strings
;;;   (record-event event) → affected resources         [scope-extras]
;;;   (query method . args) → result from observer      [scope-extras]
;;;   (wire-output sink-ref) → void
;;;
;;; The handler extends the inbound request-ctx (user-id, channel-id,
;;; channel-ref, raw-text) with `scope-ref` + `org-ref` before passing it
;;; to dispatch. The accessors for those fields (ctx-scope, ctx-org) are
;;; exported from this module — they belong here, not in the layer-pure
;;; call-context.
;;;
;;; This module also owns the *standard command table* and its handlers
;;; (cmd-inventory, cmd-alerts, etc.) — they're entirely scope-specific
;;; and live with the scope-handler that uses them.
;;;
;;; Lives in any vat — local or, via OCapN, remote. The channel calls
;;; via <-, so location is transparent.

(define-module (playnet interface backends scope)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (playnet interface command-dispatch)
  #:use-module (playnet interface output-sink)
  #:use-module (playnet interface call-context)
  #:use-module (playnet notify registry)
  #:use-module (playnet vf schemas)   ; the resource and event accessors the commands print
  #:use-module ((playnet execution scope-execution) #:select (record-and-monitor))
  #:export (^scope-handler
            make-scope-handler
            ;; ctx accessors for scope-extended contexts
            ctx-scope
            ctx-org
            ;; standard command table (so callers can extend or replace it)
            standard-command-table
            ;; scope alert vocabulary + tee proxy
            scope-alert-formatter
            ^tee-alert-store))


;; =========================================================================
;; ^tee-alert-store — proxy interposition on ^alert-store
;; =========================================================================
;; Sits between the scope's real ^alert-store and any output sink. Reads
;; pass through unchanged; push-alert is teed to both the real store and
;; the sink. Belongs here because its method surface IS the alert-store
;; interface — entirely scope vocabulary.

(define (^tee-alert-store bcom inner-store output-sink)
  ;; inner-store : the real ^alert-store actor ref
  ;; output-sink : ^output-sink actor ref
  (methods
    ;; The interposition point: tee push-alert to both targets
    ((push-alert alert)
     ($ inner-store 'push-alert alert)
     (<-np output-sink 'print alert))
    ;; All read methods delegate unchanged
    ((of-kind kind)        ($ inner-store 'of-kind kind))
    ((for-spec spec-id)    ($ inner-store 'for-spec spec-id))
    ((since timestamp)     ($ inner-store 'since timestamp))
    ((all-alerts)          ($ inner-store 'all-alerts))
    ((alert-count)         ($ inner-store 'alert-count))
    ((clear)               ($ inner-store 'clear))))


;; =========================================================================
;; Scope-specific call-context accessors
;; =========================================================================
;; The scope-handler extends the request-ctx with these fields. Anything
;; downstream of the handler (commands, formatters, future scope-aware
;; tooling) reads them via these accessors.

(define (ctx-scope ctx) (assq-ref ctx 'scope-ref))
(define (ctx-org   ctx) (assq-ref ctx 'org-ref))


;; =========================================================================
;; ^scope-handler — backend protocol for one VF planning scope
;; =========================================================================

(define (^scope-handler bcom
                        scope-ref       ;; ^scope-root actor ref (near)
                        org-ref         ;; ^org actor ref (near)
                        dispatch-ref    ;; ^command-dispatch actor ref (near)
                        tee-store-ref)  ;; ^tee-alert-store (near)

  (methods

    ;; --- Backend protocol ---

    ((handle request-ctx command-name args-string)
     ;; Extend the request-ctx with backend-local refs and dispatch.
     (let ((handler-ctx (extend-ctx request-ctx
                                    'scope-ref scope-ref
                                    'org-ref   org-ref)))
       ($ dispatch-ref 'dispatch handler-ctx command-name args-string)))

    ((available-commands)
     ($ dispatch-ref 'available-commands))

    ;; --- Scope-specific operations ---
    ;; Beyond the generic protocol — callers who know they're talking
    ;; to a scope-handler can use these directly.

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
     ;; push-alert calls to the sink. Nothing extra needed here.
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
;; Standard scope command handlers
;; =========================================================================
;; All scope-specific: they reach into observer / plan-store / alert-store
;; / buffer-zone-store / org via ctx-scope and ctx-org.

(define (cmd-inventory ctx args)
  "Show resource inventory, optionally filtered by spec-id."
  (let ((obs ($ (ctx-scope ctx) 'observer)))
    (if (and args (not (string-null? args)))
        (let ((resources ($ obs 'inventory-for-spec (string-trim-both args))))
          (format-inventory resources))
        (let ((resources ($ obs 'enriched-inventory)))
          (format-inventory resources)))))

(define (cmd-alerts ctx args)
  "Show accumulated alerts, optionally filtered by kind."
  (let ((als ($ (ctx-scope ctx) 'alert-store)))
    (if (and args (not (string-null? args)))
        (let ((kind (string->symbol (string-trim-both args))))
          (format-alerts ($ als 'of-kind kind)))
        (format-alerts ($ als 'all-alerts)))))

(define (cmd-resources ctx args)
  "List all known resources."
  (let* ((obs ($ (ctx-scope ctx) 'observer))
         (resources ($ obs 'all-resources)))
    (if (null? resources)
        "No resources recorded."
        (string-join
         (map (lambda (r)
                (format #f "  ~a: ~a ~a ~a"
                        (economic-resource-id r)
                        (or (economic-resource-name r) "(unnamed)")
                        (or (economic-resource-accounting-quantity r) "")
                        (or (economic-resource-current-location r) "")))
              resources)
         "\n"))))

(define (cmd-events ctx args)
  "Show recent event history."
  (let* ((obs ($ (ctx-scope ctx) 'observer))
         (events ($ obs 'all-events))
         (shown (if (> (length events) 20)
                    (take events 20)
                    events)))
    (if (null? shown)
        "No events recorded."
        (string-join
         (map (lambda (e)
                (format #f "  ~a ~a ~a qty:~a"
                        (economic-event-id e)
                        (economic-event-action e)
                        (or (economic-event-resource-conforms-to e) "")
                        (or (economic-event-resource-quantity e) "?")))
              shown)
         "\n"))))

(define (cmd-status ctx args)
  "Scope health overview: inventory summary + alert counts."
  (let* ((obs ($ (ctx-scope ctx) 'observer))
         (als ($ (ctx-scope ctx) 'alert-store))
         (resources ($ obs 'all-resources))
         (alerts ($ als 'all-alerts))
         (alert-kinds (map (lambda (a) (assq-ref a 'kind)) alerts)))
    (string-append
     (format #f "Resources: ~a\n" (length resources))
     (format #f "Alerts: ~a total" (length alerts))
     (if (null? alert-kinds) ""
         (let ((counts (fold (lambda (k acc)
                               (let ((existing (assq k acc)))
                                 (if existing
                                     (map (lambda (p)
                                            (if (eq? (car p) k)
                                                (cons k (+ 1 (cdr p)))
                                                p))
                                          acc)
                                     (cons (cons k 1) acc))))
                             '() alert-kinds)))
           (format #f " (~a)"
                   (string-join
                    (map (lambda (p) (format #f "~a: ~a" (car p) (cdr p)))
                         counts)
                    ", ")))))))

(define (cmd-eval ctx args)
  "Evaluate a Scheme expression in the org's environment."
  (if (or (not args) (string-null? args))
      "Usage: /eval <expression>"
      (let ((result ($ (ctx-org ctx) 'evaluate (call-with-input-string args read))))
        (format #f "~a" result))))

(define (cmd-define ctx args)
  "Set a binding in the org: /define name value-expr"
  (if (or (not args) (string-null? args))
      "Usage: /define <name> <value-expression>"
      (let* ((port (open-input-string args))
             (name (read port))
             (value-expr (read port))
             (org-ref (ctx-org ctx)))
        (if (not (symbol? name))
            (format #f "Error: ~a is not a valid binding name" name)
            (let ((value ($ org-ref 'evaluate value-expr)))
              ($ org-ref 'modify! name value
                 `((action . define)
                   (user . ,(ctx-user ctx))
                   (name . ,name)))
              (format #f "Defined ~a" name))))))

(define (cmd-plan ctx args)
  "Query the plan store: intents, commitments."
  (let ((ps ($ (ctx-scope ctx) 'plan-store)))
    (if (and args (not (string-null? args)))
        (match (string-trim-both args)
          ("intents"
           (let ((intents ($ ps 'all-intents)))
             (if (null? intents) "No intents."
                 (format #f "~a intents recorded." (length intents)))))
          ("commitments"
           (let ((commitments ($ ps 'all-commitments)))
             (if (null? commitments) "No commitments."
                 (format #f "~a commitments recorded." (length commitments)))))
          (other (format #f "Unknown plan query: ~a. Try: intents, commitments" other)))
        "Usage: /plan <intents|commitments>")))

(define (cmd-buffer ctx args)
  "Query buffer zone status."
  (let ((bzs ($ (ctx-scope ctx) 'buffer-zone-store)))
    (let ((zones ($ bzs 'all-zones)))
      (if (null? zones) "No buffer zones configured."
          (string-join
           (map (lambda (z)
                  (format #f "  ~a: green=~a yellow=~a red=~a"
                          (assq-ref z 'spec-id)
                          (assq-ref z 'top-of-green)
                          (assq-ref z 'top-of-yellow)
                          (assq-ref z 'top-of-red)))
                zones)
           "\n")))))

(define (cmd-help ctx args)
  "List available commands."
  (string-join
   '("Available commands:"
     "  /inventory [spec-id]  — Show resource inventory"
     "  /alerts [kind]        — Show execution alerts"
     "  /resources            — List all resources"
     "  /events               — Recent event history"
     "  /status               — Scope health overview"
     "  /eval <expr>          — Evaluate Scheme expression"
     "  /define <name> <expr> — Set a binding"
     "  /plan <query>         — Plan store queries"
     "  /buffer               — Buffer zone status"
     "  /start <flow>         — Begin a conversational flow"
     "  /cancel               — Abort the active flow"
     "  /help                 — This message")
   "\n"))


;; =========================================================================
;; Scope alert formatter
;; =========================================================================
;; Recognises the DDMRP/VF alert kinds (buffer-status, material-sync,
;; adu-shift). Unknown kinds fall through to a generic line.

(define (scope-alert-formatter alert)
  "Format a scope alert alist as a human-readable string for a text
   transport. Delegates to the one notification registry (terse style) so
   there is a single source of truth for wording; falls back to a generic
   line for kinds the registry does not know."
  (call-with-values
    (lambda () (render-notification alert 'terse))
    (lambda (type title body tag)
      (if body
          body
          (format #f "[ALERT] ~a: ~a (~a)"
                  (or (assq-ref alert 'kind) 'unknown)
                  (or (assq-ref alert 'spec-id) "")
                  (or (assq-ref alert 'timestamp) ""))))))


;; =========================================================================
;; Formatters (inventory + alerts list)
;; =========================================================================

(define (format-inventory resources)
  (if (null? resources)
      "Inventory is empty."
      (string-join
       (map (lambda (r)
              (let ((name (or (assq-ref r 'name)
                              (assq-ref r 'resource-id)
                              "(unknown)"))
                    (qty (or (assq-ref r 'onhand-qty)
                             (assq-ref r 'accounting-quantity)
                             "?")))
                (format #f "  ~a: ~a" name qty)))
            resources)
       "\n")))

(define (format-alerts alerts)
  (if (null? alerts)
      "No alerts."
      (string-join
       (map (lambda (a)
              (let ((kind (or (assq-ref a 'kind) "unknown"))
                    (spec (or (assq-ref a 'spec-id) ""))
                    (ts (or (assq-ref a 'timestamp) "")))
                (match kind
                  ('buffer-status
                   (format #f "  [~a] ~a zone:~a onhand:~a"
                           ts spec
                           (or (assq-ref a 'zone) "?")
                           (or (assq-ref a 'onhand) "?")))
                  ('material-sync
                   (format #f "  [~a] ~a shortage:~a"
                           ts spec
                           (or (assq-ref a 'shortage) "?")))
                  ('adu-shift
                   (format #f "  [~a] ~a ADU ~a ~a%"
                           ts spec
                           (or (assq-ref a 'direction) "?")
                           (or (assq-ref a 'change-pct) "?")))
                  (_
                   (format #f "  [~a] ~a: ~a" ts kind spec)))))
            alerts)
       "\n")))


;; =========================================================================
;; Standard command table
;; =========================================================================

(define (standard-command-table)
  "Build the default scope command table hashmap. Callers can pass this
   into ^command-dispatch or extend/replace entries before doing so."
  (let ((h (hashmap)))
    (fold (lambda (pair acc)
            (hashmap-set acc (car pair) (cdr pair)))
          h
          `(("inventory" . ,cmd-inventory)
            ("alerts"    . ,cmd-alerts)
            ("resources" . ,cmd-resources)
            ("events"    . ,cmd-events)
            ("status"    . ,cmd-status)
            ("eval"      . ,cmd-eval)
            ("define"    . ,cmd-define)
            ("plan"      . ,cmd-plan)
            ("buffer"    . ,cmd-buffer)
            ("help"      . ,cmd-help)))))


;; =========================================================================
;; Convenience constructor
;; =========================================================================

(define (make-scope-handler scope-ref org-ref)
  "Spawn a complete scope-handler with the standard command table and
   tee-alert-store wiring. Call within a vat context.
   Returns (values handler-ref sink-ref) — caller wires sink to transport."
  (let* ((alert-st ($ scope-ref 'alert-store))
         (sink-ref (spawn ^output-sink
                          #f    ;; no channel-context yet
                          #f    ;; no transport yet
                          scope-alert-formatter
                          '())) ;; empty queue
         (tee-ref    (spawn ^tee-alert-store alert-st sink-ref))
         (dispatch   (spawn ^command-dispatch (standard-command-table)))
         (handler    (spawn ^scope-handler scope-ref org-ref dispatch tee-ref)))
    (values handler sink-ref)))
