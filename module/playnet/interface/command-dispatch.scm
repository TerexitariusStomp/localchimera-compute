;;; module/playnet/interface/command-dispatch.scm — Generic /command router
;;;
;;; Pure actor: hashmap of command-name -> handler procedure.
;;; Transport-agnostic — knows nothing about / vs , vs ! prefixes.
;;; The transport adapter handles prefix parsing; this actor handles
;;; semantic routing to scope and org operations.

(define-module (playnet interface command-dispatch)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:export (^command-dispatch
            standard-command-table))


;; =========================================================================
;; ^command-dispatch — command routing actor
;; =========================================================================

(define (^command-dispatch bcom command-table)
  ;; command-table: hashmap of string -> handler procedure
  ;; handler signature: (scope-ref org-ref user-id args-string) -> response string

  (methods

    ((dispatch scope-ref org-ref user-id command-name args-string)
     ;; Look up command in table and execute.
     ;; Returns (list 'response text) or (list 'error reason).
     (let ((handler (hashmap-ref command-table command-name #f)))
       (if handler
           (catch #t
             (lambda ()
               (list 'response (handler scope-ref org-ref user-id args-string)))
             (lambda (key . rest)
               (list 'error (format #f "~a: ~a" key rest))))
           (list 'error (format #f "Unknown command: ~a. Try /help" command-name)))))

    ((register-command name handler)
     ;; Add or replace a command handler.
     (bcom (^command-dispatch bcom
             (hashmap-set command-table name handler))))

    ((remove-command name)
     (bcom (^command-dispatch bcom
             (hashmap-remove command-table name))))

    ((available-commands)
     ;; Return list of command names.
     (hashmap-fold (lambda (k v acc) (cons k acc)) '() command-table))))


;; =========================================================================
;; Standard command handlers
;; =========================================================================

(define (cmd-inventory scope-ref org-ref user-id args)
  "Show resource inventory, optionally filtered by spec-id."
  (let ((obs ($ scope-ref 'observer)))
    (if (and args (not (string-null? args)))
        (let ((resources ($ obs 'inventory-for-spec (string-trim-both args))))
          (format-inventory resources))
        (let ((resources ($ obs 'enriched-inventory)))
          (format-inventory resources)))))

(define (cmd-alerts scope-ref org-ref user-id args)
  "Show accumulated alerts, optionally filtered by kind."
  (let ((als ($ scope-ref 'alert-store)))
    (if (and args (not (string-null? args)))
        (let ((kind (string->symbol (string-trim-both args))))
          (format-alerts ($ als 'of-kind kind)))
        (format-alerts ($ als 'all-alerts)))))

(define (cmd-resources scope-ref org-ref user-id args)
  "List all known resources."
  (let* ((obs ($ scope-ref 'observer))
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

(define (cmd-events scope-ref org-ref user-id args)
  "Show recent event history."
  (let* ((obs ($ scope-ref 'observer))
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

(define (cmd-status scope-ref org-ref user-id args)
  "Scope health overview: inventory summary + alert counts."
  (let* ((obs ($ scope-ref 'observer))
         (als ($ scope-ref 'alert-store))
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

(define (cmd-eval scope-ref org-ref user-id args)
  "Evaluate a Scheme expression in the org's environment."
  (if (or (not args) (string-null? args))
      "Usage: /eval <expression>"
      (let ((result ($ org-ref 'evaluate (call-with-input-string args read))))
        (format #f "~a" result))))

(define (cmd-define scope-ref org-ref user-id args)
  "Set a binding in the org: /define name value-expr"
  (if (or (not args) (string-null? args))
      "Usage: /define <name> <value-expression>"
      (let* ((port (open-input-string args))
             (name (read port))
             (value-expr (read port)))
        (if (not (symbol? name))
            (format #f "Error: ~a is not a valid binding name" name)
            (let ((value ($ org-ref 'evaluate value-expr)))
              ($ org-ref 'modify! name value
                 `((action . define)
                   (user . ,user-id)
                   (name . ,name)))
              (format #f "Defined ~a" name))))))

(define (cmd-plan scope-ref org-ref user-id args)
  "Query the plan store: intents, commitments."
  (let ((ps ($ scope-ref 'plan-store)))
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

(define (cmd-buffer scope-ref org-ref user-id args)
  "Query buffer zone status."
  (let ((bzs ($ scope-ref 'buffer-zone-store)))
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

(define (cmd-help scope-ref org-ref user-id args)
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
     "  /help                 — This message")
   "\n"))


;; =========================================================================
;; Inventory/alert formatters
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
;; Standard command table constructor
;; =========================================================================

(define (standard-command-table)
  "Build the default command table hashmap."
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
