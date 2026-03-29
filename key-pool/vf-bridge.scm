;;; key-pool/vf-bridge.scm — ValueFlows bridge for the key-pool
;;;
;;; Wraps ^key-pool to emit ValueFlows economic records alongside
;;; normal operation. Keys become EconomicResources, API calls become
;;; EconomicEvents (action: 'use), donors become Agents, the pool
;;; becomes a Process.
;;;
;;; This is the first concrete example of "agents as scopes, actors
;;; as agents" — the planner can reason about key usage as economic
;;; resource flows.
;;;
;;; Usage:
;;;   (use-modules (key-pool vf-bridge))
;;;   (define vf-pool (make-vf-key-pool vat "sk-or-aaa,sk-or-bbb"
;;;                     '(("donor-1" "Alice") ("donor-2" "Bob"))))
;;;   (with-vat vat ($ vf-pool 'request "/chat/completions" body))
;;;   (with-vat vat ($ vf-pool 'vf-events))
;;;   (with-vat vat ($ vf-pool 'vf-summary))

(define-module (vf-bridge)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (key-pool)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:export (^vf-key-pool
            make-vf-key-pool
            ;; VF record constructors for key-pool domain
            vf-api-key-spec
            vf-donor-agent
            vf-key-resource
            vf-usage-event
            vf-pool-process
            health->vf-state
            ;; Re-export VF accessors used by callers
            resource-specification-name
            agent-name agent-id
            economic-resource-state economic-resource-id
            economic-event-action economic-event-effort-quantity
            economic-event-provider
            process-name process-id))

;; Load planner schemas via primitive-load (the planner doesn't use Guile modules).
;; This defines make-agent, make-economic-resource, etc. in the current module.
(primitive-load (or (getenv "PLANNER_SCHEMAS_PATH")
                    "planner/lib/schemas.scm"))

;;; ── VF record constructors ────────────────────────────────────────────────

(define (current-iso-time)
  (date->string (current-date 0) "~4"))

(define *event-counter* 0)
(define (next-event-id)
  (set! *event-counter* (+ *event-counter* 1))
  (string-append "ev-keypool-" (number->string *event-counter*)))

(define (vf-api-key-spec)
  "ResourceSpecification for OpenRouter API keys."
  (make-resource-specification
   "rs-openrouter-key"        ;; id
   "OpenRouter API Key"       ;; name
   "Donated API key for community transcription and voice-to-code" ;; note
   #f                         ;; image
   '("openrouter" "api-key")  ;; resource-classified-as
   "each"                     ;; default-unit-of-resource
   "USD"                      ;; default-unit-of-effort
   #f                         ;; substitutable
   #f                         ;; medium-of-exchange
   #f                         ;; buffer-profile-id
   #f))                       ;; positioning-analysis

(define (vf-donor-agent donor-id donor-name)
  "Agent record for a key donor."
  (make-agent
   donor-id                   ;; id
   'person                    ;; type
   donor-name                 ;; name
   "API key donor"            ;; note
   #f                         ;; image
   #f                         ;; primary-location
   '("donor" "commons")       ;; classified-as
   #f))                       ;; availability-window

(define (vf-key-resource key-id donor-agent-id spec-id state)
  "EconomicResource for one API key."
  (make-economic-resource
   key-id                     ;; id
   #f                         ;; name
   #f                         ;; note
   #f                         ;; image
   #f                         ;; tracking-identifier
   spec-id                    ;; conforms-to
   #f                         ;; classified-as
   #f                         ;; accounting-quantity
   #f                         ;; onhand-quantity
   #f                         ;; current-location
   #f                         ;; current-virtual-location
   donor-agent-id             ;; primary-accountable
   #f                         ;; custodian-scope
   #f                         ;; stage
   state                      ;; state (available, restricted, exhausted)
   #f                         ;; contained-in
   "USD"                      ;; unit-of-effort
   #f                         ;; lot
   #f                         ;; previous-event
   #f))                       ;; availability-window

(define (vf-usage-event resource-id provider-id cost process-id)
  "EconomicEvent for one API call (action: 'use)."
  (make-economic-event
   (next-event-id)            ;; id
   'use                       ;; action
   process-id                 ;; input-of (the pool process)
   #f                         ;; output-of
   resource-id                ;; resource-inventoried-as
   #f                         ;; to-resource-inventoried-as
   "rs-openrouter-key"        ;; resource-conforms-to
   #f                         ;; resource-classified-as
   provider-id                ;; provider (donor)
   "community"                ;; receiver
   #f                         ;; resource-quantity
   cost                       ;; effort-quantity (cost in USD)
   #f                         ;; has-beginning
   #f                         ;; has-end
   (current-iso-time)         ;; has-point-in-time
   (current-iso-time)         ;; created
   #f                         ;; at-location
   #f                         ;; to-location
   #f                         ;; state
   #f                         ;; fulfills
   #f                         ;; satisfies
   #f                         ;; corrects
   #f                         ;; realization-of
   #f                         ;; settles
   #f                         ;; note
   #f                         ;; in-scope-of
   #f                         ;; previous-event
   #f                         ;; exclude-from-adu
   cost))                     ;; market-value

(define (vf-pool-process)
  "Process representing the key pool's transcription/express service."
  (make-process
   "proc-keypool"             ;; id
   "Community Key Pool"       ;; name
   "Round-robin API key pool for community voice transcription and NL→code" ;; note
   #f                         ;; based-on
   '("transcription" "voice-to-code" "commons") ;; classified-as
   #f                         ;; planned-within
   #f                         ;; nested-in
   #f                         ;; in-scope-of
   #f                         ;; has-beginning
   #f                         ;; has-end
   #f))                       ;; finished

;;; ── Health → VF state mapping ─────────────────────────────────────────────

(define (health->vf-state health)
  (case health
    ((healthy)      "available")
    ((degraded)     "degraded")
    ((rate-limited) "restricted")
    ((depleted)     "exhausted")
    ((failed)       "failed")
    (else           "unknown")))

;;; ── ^vf-key-pool actor ────────────────────────────────────────────────────

(define (^vf-key-pool bcom inner-pool process spec agents resources events)
  ;; inner-pool: the wrapped ^key-pool ref
  ;; process: VF Process record
  ;; spec: VF ResourceSpecification record
  ;; agents: alist of (key-id . Agent)
  ;; resources: alist of (key-id . EconomicResource)
  ;; events: list of EconomicEvent records (newest first)

  (methods

   ;; ── Core: proxy request through inner pool, emit VF event ──

   [(request path body-string)
    (let ((response-str ($ inner-pool 'request path body-string)))
      ;; Extract cost from response if available
      (let* ((cost (catch #t
                     (lambda ()
                       (let* ((json (json-string->scm response-str))
                              (usage (assoc-ref json "usage")))
                         (or (and usage (assoc-ref usage "total_cost")) 0)))
                     (lambda args 0)))
             ;; Find which key was used (first healthy resource)
             (used-resource-id
              (let loop ((rs resources))
                (if (null? rs) "unknown"
                    (let ((r (cdar rs)))
                      (if (equal? (economic-resource-state r)
                                  "available")
                          (caar rs)
                          (loop (cdr rs)))))))
             (provider-id
              (let ((agent-entry (assoc used-resource-id agents)))
                (if agent-entry
                    (agent-id (cdr agent-entry))
                    "unknown")))
             (ev (vf-usage-event used-resource-id provider-id cost
                                 (process-id process))))
        (bcom (^vf-key-pool bcom inner-pool process spec
                            agents resources (cons ev events)))
        response-str))]

   ;; ── VF queries ──

   [(vf-events) events]
   [(vf-event-count) (length events)]
   [(vf-agents) (map cdr agents)]
   [(vf-resources) (map cdr resources)]
   [(vf-process) process]
   [(vf-spec) spec]

   [(vf-summary)
    (let ((total-cost (fold (lambda (ev acc)
                              (+ acc (or (economic-event-effort-quantity ev) 0)))
                            0 events)))
      `((total-cost . ,total-cost)
        (event-count . ,(length events))
        (agent-count . ,(length agents))
        (resource-count . ,(length resources))))]

   ;; ── Delegate all other messages to inner pool ──

   [(pool-status) ($ inner-pool 'pool-status)]
   [(pool-health) ($ inner-pool 'pool-health)]
   [(add-key key-string donor-id donor-name)
    ($ inner-pool 'add-key key-string donor-id donor-name)
    ;; TODO: add VF Agent + Resource for new key
    ]
   [(tick-recovery) ($ inner-pool 'tick-recovery)]
   [(check-all-credits) ($ inner-pool 'check-all-credits)]))

;;; ── Constructor ───────────────────────────────────────────────────────────

(define (make-vf-key-pool vat key-csv donor-alist)
  "Create a VF-wrapped key-pool.
   KEY-CSV: comma-separated API key strings.
   DONOR-ALIST: list of (donor-id donor-name) pairs, one per key."
  (with-vat vat
    (let* ((inner-pool (make-key-pool vat key-csv))
           (spec (vf-api-key-spec))
           (process (vf-pool-process))
           (keys (filter (lambda (s) (not (string=? s "")))
                         (string-split key-csv #\,)))
           (pairs (map (lambda (key donor-info)
                         (let* ((donor-id (car donor-info))
                                (donor-name (cadr donor-info))
                                (key-id (string-append "kr-"
                                          (substring key 0 (min 8 (string-length key)))))
                                (agent (vf-donor-agent donor-id donor-name))
                                (resource (vf-key-resource key-id donor-id
                                            "rs-openrouter-key" "available")))
                           (list key-id agent resource)))
                       keys
                       (if (>= (length donor-alist) (length keys))
                           donor-alist
                           ;; Pad with anonymous donors if fewer names than keys
                           (append donor-alist
                                   (map (lambda (i)
                                          (list (string-append "anon-" (number->string i))
                                                "Anonymous"))
                                        (iota (- (length keys) (length donor-alist))
                                              (length donor-alist)))))))
           (agents (map (lambda (p) (cons (car p) (cadr p))) pairs))
           (resources (map (lambda (p) (cons (car p) (caddr p))) pairs)))
      (spawn ^vf-key-pool inner-pool process spec agents resources '()))))
