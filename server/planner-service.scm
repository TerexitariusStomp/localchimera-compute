;;; server/planner-service.scm — OCapN-facing facade for the planner
;;;
;;; This file is primitive-loaded from server/gateway.scm AFTER
;;; server/planner-loader.scm has loaded the planner. It depends on
;;; planner top-level definitions (record constructors, store actor
;;; constructors, scope-root accessors), so it cannot live inside a
;;; (define-module …) form.
;;;
;;; The actor lives INSIDE planner-vat alongside ^scope-root and the
;;; underlying stores, so its methods have synchronous near-call access
;;; to plan-store/observer/agent-store/recipe-store via `$`. The lobby
;;; (in gateway-vat) holds a reference to it; the browser (across the
;;; OCapN websocket) calls it via `<-`. The vat boundary is the OCapN
;;; wire — there are no `with-vat` hops inside the actor's methods.
;;;
;;; Return values are always plain alists (or primitives) — never actor
;;; refs or records — so the wire format is OCapN-friendly and the
;;; browser projection layer can consume them unchanged.

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Error envelope ───────────────────────────────────────────────────
;;; Mutation methods return either (ok . X) or (error . "message").
;;; The browser pattern-matches on (car result).

(define (success x) (cons 'ok x))
(define (failure msg) (cons 'error msg))

(define (catch-as-failure thunk)
  "Run THUNK and either return its value or wrap any raised exception
   into a failure envelope."
  (catch #t thunk
    (lambda (key . args)
      (failure (format #f "~a: ~a" key args)))))

;;; ── Time helpers ──────────────────────────────────────────────────────

(define (iso-now)
  "Current UTC instant as ISO 8601 string."
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define (iso-date-from-epoch secs)
  "Render an epoch-seconds count as a YYYY-MM-DD string in UTC."
  (and secs (strftime "%Y-%m-%d" (gmtime secs))))

(define (numeric-string? s)
  "True if S is a string of digits (optionally with a leading minus)."
  (and (string? s)
       (> (string-length s) 0)
       (let loop ((i (if (char=? (string-ref s 0) #\-) 1 0)))
         (cond
           ((>= i (string-length s)) #t)
           ((not (char-numeric? (string-ref s i))) #f)
           (else (loop (+ i 1)))))))

(define (planner-time->date-string s)
  "The planner stores has-beginning/has-end/due as either ISO datetime
   strings or as (number->string epoch-secs). Detect and convert to
   YYYY-MM-DD; return #f on failure."
  (cond
    ((not (string? s)) #f)
    ((numeric-string? s)
     (let ((n (string->number s)))
       (and n (iso-date-from-epoch n))))
    ((>= (string-length s) 10) (substring s 0 10))
    (else #f)))

(define (planner-time->hour-min s default-hour)
  "Pull (hour . minute) out of a planner time string. Handles both
   epoch-string and ISO formats. Falls back to (DEFAULT-HOUR . 0)."
  (cond
    ((not (string? s)) (cons default-hour 0))
    ((numeric-string? s)
     (let ((n (string->number s)))
       (if n
           (let* ((tm (gmtime n)))
             (cons (tm:hour tm) (tm:min tm)))
           (cons default-hour 0))))
    ((>= (string-length s) 16)
     (let ((h (string->number (substring s 11 13)))
           (m (string->number (substring s 14 16))))
       (cons (or h default-hour) (or m 0))))
    (else (cons default-hour 0))))

;;; ── Measure helpers ──────────────────────────────────────────────────

(define (measure->qty m)
  (and m (measure-has-numerical-value m)))

(define (measure->unit m)
  (and m (measure-has-unit m)))

;;; ── EconomicEvent builder ────────────────────────────────────────────
;;; Wraps the 29-positional-arg make-economic-event with keyword args.
;;; Field defaults are #f, so callers only specify what they care about.

(define* (make-work-event #:key id provider effort-qty (effort-unit "hours")
                                fulfills input-of resource-spec
                                (note "Effort recorded from calendar")
                                (timestamp (iso-now)))
  "Build a 'work EconomicEvent. PROVIDER is also used as the receiver
   (work events are self-contained). FULFILLS links the event to a
   commitment so observer.track-fulfillment can advance the FulfillmentState."
  (make-economic-event
    id                                 ; 1 id (auto-generated if #f)
    'work                              ; 2 action
    input-of #f                        ; 3-4 input-of, output-of
    #f #f                              ; 5-6 (to-)resource-inventoried-as
    resource-spec #f                   ; 7-8 resource-conforms-to, classified-as
    provider provider                  ; 9-10 provider, receiver
    #f                                 ; 11 resource-quantity
    (make-measure effort-qty effort-unit) ; 12 effort-quantity
    #f #f timestamp timestamp          ; 13-16 has-beginning, -end, -point-in-time, created
    #f #f #f                           ; 17-19 at-location, to-location, state
    fulfills                           ; 20 fulfills
    #f #f #f #f                        ; 21-24 satisfies, corrects, realization-of, settles
    note                               ; 25 note
    #f #f #f #f))                      ; 26-29 in-scope-of, prev-event, exclude-adu, market-value

;;; ── Member projection ────────────────────────────────────────────────

(define %member-palette
  (vector "#63b3ed" "#f6ad55" "#b794f4" "#4fd1c5" "#f687b3"
          "#7ee8a2" "#fc8181" "#d6bcfa" "#90cdf4" "#fbd38d"))

(define (palette-color idx)
  (vector-ref %member-palette
              (modulo idx (vector-length %member-palette))))

(define (agent-record->member-alist a idx)
  `((id . ,(agent-id a))
    (name . ,(or (agent-name a) (agent-id a)))
    (color . ,(palette-color idx))
    (visible . #t)))

(define (scope-members scope-root scope-id)
  "Return all agents that have a 'role-member' relationship in SCOPE-ID,
   shaped as calendar member alists."
  (let* ((as   ($ scope-root 'agent-store))
         (rels ($ as 'relationships-in-scope scope-id))
         ;; relationships-in-scope returns a list (per store-utils.scm:21)
         (subj-ids (delete-duplicates
                     (map agent-relationship-subject rels))))
    (let loop ((ids subj-ids) (idx 0) (acc '()))
      (if (null? ids)
          (reverse acc)
          (let ((agent ($ as 'get-agent (car ids))))
            (loop (cdr ids)
                  (+ idx 1)
                  (if agent
                      (cons (agent-record->member-alist agent idx) acc)
                      acc)))))))

;;; ── Plan projection ──────────────────────────────────────────────────

(define (plan-record->alist p)
  `((id . ,(plan-id p))
    (name . ,(or (plan-name p) (plan-id p)))))

;;; ── Process / recipe-process lookup helpers ──────────────────────────

(define (lookup-process-name preg rs process-id)
  "PROCESS-ID may be a recipe-process id (e.g. 'rp-meeting') OR a
   dynamically-generated process id from dependent-demand (e.g. 'dd-…').
   Try the process registry first (where dependent-demand registers its
   created processes), then fall back to the recipe-store, then the id."
  (and process-id
       (let ((p ($ preg 'get process-id)))
         (cond
           (p (or (process-name p) process-id))
           (else
            (let ((rp ($ rs 'get-recipe-process process-id)))
              (if rp (or (recipe-process-name rp) process-id) process-id)))))))

(define (lookup-spec-name rs spec-id)
  (and spec-id
       (let ((s ($ rs 'get-resource-spec spec-id)))
         (if s (or (resource-specification-name s) spec-id) spec-id))))

;;; ── Record → wire alist (intents and commitments) ───────────────────
;;;
;;; A single projection function handles both intents and commitments.
;;; The two records share most of their fields; the differences are
;;; centralized in three places below (id/effort/spec accessors, where
;;; the provider comes from, and whether to query the observer for
;;; fulfilled-qty). The browser's vf-record->grid-event reads
;;; (or 'provider 'suggested-provider), so we always populate both keys
;;; with the appropriate value for the kind.

(define (record->cal-alist kind record ps obs as rs preg scope-id)
  "KIND is 'intent or 'commitment. Returns the wire alist consumed by
   the browser's vf-record->grid-event projection."
  (let* ((intent? (eq? kind 'intent))
         ;; Field accessors (the only kind-dispatched part)
         (id        (if intent? (intent-id record) (commitment-id record)))
         (eff       (if intent? (intent-effort-quantity record)
                                (commitment-effort-quantity record)))
         (proc-id   (if intent? (intent-input-of record)
                                (commitment-input-of record)))
         (spec      (if intent? (intent-resource-conforms-to record)
                                (commitment-resource-conforms-to record)))
         (plan-id   (if intent? (intent-planned-within record)
                                (commitment-planned-within record)))
         (hb        (if intent? (intent-has-beginning record)
                                (commitment-has-beginning record)))
         (due       (if intent? (intent-due record)
                                (commitment-due record)))
         ;; Common derived fields
         (eff-q (or (measure->qty eff) 1))
         (eff-u (or (measure->unit eff) "hours"))
         ;; Provider: intent reads suggested from meta; commitment reads
         ;; the provider field directly.
         (provider     (if intent?
                           (assq-ref (or ($ ps 'get-meta id) '()) 'suggested-provider)
                           (commitment-provider record)))
         (provider-rec (and provider ($ as 'get-agent provider)))
         (provider-name (and provider-rec (agent-name provider-rec)))
         (match-status (cond
                         ((not intent?) 'accepted)
                         (provider 'matched)
                         (else 'unmatched)))
         ;; Fulfilled-qty: intents always 0; commitments join observer.
         (fulfilled-qty
          (if intent? 0
              (let ((fs ($ obs 'get-fulfillment id)))
                (if fs
                    (or (measure->qty (fulfillment-state-total-fulfilled fs)) 0)
                    0))))
         ;; Time positioning on the grid (folded inline; only used here)
         (date  (or (planner-time->date-string hb)
                    (planner-time->date-string due)
                    (iso-date-from-epoch (current-time))))
         (start (planner-time->hour-min hb 10))
         (sh    (car start))
         (sm    (cdr start))
         (eh    (min 23 (+ sh (max 1 (inexact->exact (ceiling eff-q)))))))
    `((id . ,id)
      (plan-id . ,plan-id)
      (process-id . ,proc-id)
      (process-name . ,(or (lookup-process-name preg rs proc-id) ""))
      (resource-spec . ,spec)
      (resource-spec-name . ,(or (lookup-spec-name rs spec) ""))
      (effort-qty . ,eff-q)
      (effort-unit . ,eff-u)
      (scope . ,scope-id)
      ;; Both provider keys populated; the browser projection prefers
      ;; 'provider when present and falls back to 'suggested-provider.
      (provider . ,(if intent? #f provider))
      (provider-name . ,(if intent? #f provider-name))
      (suggested-provider . ,(if intent? provider #f))
      (suggested-provider-name . ,(if intent? provider-name #f))
      (match-status . ,match-status)
      (date . ,date)
      (start-hour . ,sh) (start-min . ,sm)
      (end-hour . ,eh) (end-min . ,sm)
      (fulfilled-qty . ,fulfilled-qty))))

;;; ── Snapshot builder (read path) ─────────────────────────────────────

(define (build-snapshot scope-root scope-id plan-id)
  ;; NOTE: We filter all-commitments by plan-id manually rather than
  ;; using ($ ps 'commitments-for-plan plan-id) because the planner's
  ;; promote-to-commitment doesn't update the commitments-by-plan index
  ;; (planning.scm:436-529) — the index is reused unchanged. Filing a
  ;; separate planner fix; for now we work around it here.
  (let* ((rs   ($ scope-root 'recipe-store))
         (as   ($ scope-root 'agent-store))
         (obs  ($ scope-root 'observer))
         (ps   ($ scope-root 'plan-store))
         (als  ($ scope-root 'alert-store))
         (preg ($ scope-root 'process-registry))
         (intents-raw (if plan-id
                          (filter (lambda (i)
                                    (equal? (intent-planned-within i) plan-id))
                                  ($ ps 'all-intents))
                          ($ ps 'all-intents)))
         (cmts    (if plan-id
                      (filter (lambda (c)
                                (equal? (commitment-planned-within c) plan-id))
                              ($ ps 'all-commitments))
                      ($ ps 'all-commitments)))
         (open-intents (filter (lambda (i) (not (intent-finished i)))
                               intents-raw))
         (members (scope-members scope-root scope-id))
         (plans   (map plan-record->alist ($ ps 'all-plans)))
         (alerts  ($ als 'of-kind 'unmatched-role)))
    `((scope-id . ,scope-id)
      (scope-name . ,($ scope-root 'name))
      (members . ,members)
      (plans . ,plans)
      (intents . ,(map (lambda (i)
                         (record->cal-alist 'intent i ps obs as rs preg scope-id))
                       open-intents))
      (commitments . ,(map (lambda (c)
                             (record->cal-alist 'commitment c ps obs as rs preg scope-id))
                           cmts))
      (alerts . ,alerts))))

;;; ── Process context (detail panel) ───────────────────────────────────

(define (recipe-flow->flow-alist f rs is-input?)
  (let* ((spec (recipe-flow-resource-conforms-to f))
         (rq   (recipe-flow-resource-quantity f))
         (eq   (recipe-flow-effort-quantity f))
         (m    (or rq eq)))
    `((spec . ,spec)
      (spec-name . ,(or (lookup-spec-name rs spec) spec ""))
      (qty . ,(or (measure->qty m) 1))
      (unit . ,(or (measure->unit m) ""))
      (action . ,(recipe-flow-action f))
      (is-input . ,is-input?))))

(define (find-recipe-process-for-spec rs spec-id)
  "Search recipes for a recipe-process whose process-conforms-to matches
   SPEC-ID. Returns the <recipe-process> record or #f. Used to bridge
   dependent-demand's dynamically-generated process IDs back to recipe
   topology — both share the process-spec id via 'based-on / 'process-conforms-to."
  (and spec-id
       (let loop ((recipes ($ rs 'all-recipes)))
         (cond
           ((null? recipes) #f)
           (else
            (let ((rps ($ rs 'processes-for-recipe (recipe-id (car recipes)))))
              (or (find (lambda (rp)
                          (equal? (recipe-process-process-conforms-to rp) spec-id))
                        rps)
                  (loop (cdr recipes)))))))))

(define (build-process-context scope-root process-id)
  (let* ((rs   ($ scope-root 'recipe-store))
         (preg ($ scope-root 'process-registry))
         ;; The PROCESS-ID may be a recipe-process id (e.g. 'rp-meeting')
         ;; OR a dynamic id created by dependent-demand. Try the recipe
         ;; store first; if that fails, look up the <process> record in
         ;; the registry, get its 'based-on (process-spec id), and find
         ;; the recipe-process for that spec.
         (rp (or ($ rs 'get-recipe-process process-id)
                 (let ((p ($ preg 'get process-id)))
                   (and p (find-recipe-process-for-spec
                            rs (process-based-on p)))))))
    (cond
      ((not rp)
       `((process-id . ,process-id)
         (process-name . #f)
         (inputs . ())
         (outputs . ())
         (upstream . ())
         (downstream . ())))
      (else
       (let* ((rp-id (recipe-process-id rp))
              (flows-pair ($ rs 'flows-for-process rp-id))
              (in-flows  (car flows-pair))
              (out-flows (cdr flows-pair)))
         `((process-id . ,process-id)
           (process-name . ,(or (recipe-process-name rp) process-id))
           (inputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #t)) in-flows))
           (outputs . ,(map (lambda (f) (recipe-flow->flow-alist f rs #f)) out-flows))
           (upstream . ())
           (downstream . ())))))))

;;; ── Mutation paths ───────────────────────────────────────────────────

(define (do-accept-assignment scope-root iid provider scope-id)
  "Promote an intent to a commitment, register the new commitment with
   the observer so fulfillment tracking is armed, return (ok . cid)."
  (let ((ps  ($ scope-root 'plan-store))
        (obs ($ scope-root 'observer)))
    (catch-as-failure
      (lambda ()
        (let ((cid ($ ps 'promote-to-commitment iid
                       `((provider . ,provider)
                         (receiver . ,scope-id)))))
          (cond
            ((not cid) (failure "promote-to-commitment returned #f"))
            (else
             ;; CRITICAL: arm fulfillment tracking. record-event's
             ;; track-fulfillment is a no-op without a registered state.
             ($ obs 'register-commitment ($ ps 'get-commitment cid))
             (success cid))))))))

(define (do-decline-assignment scope-root iid acting-as)
  "Clear the suggested-provider metadata. The intent itself stays in
   place; the matcher can re-assign on the next planner run, or another
   agent can volunteer."
  (catch-as-failure
    (lambda ()
      ($ ($ scope-root 'plan-store) 'set-meta iid '())
      (success 'cleared))))

(define (do-record-effort scope-root cid provider qty unit)
  "Build a 'work <economic-event> and feed it to the observer.
   Observer's track-fulfillment increments the FulfillmentState for
   the commitment named in 'fulfills'."
  (let* ((ps  ($ scope-root 'plan-store))
         (obs ($ scope-root 'observer))
         (cmt ($ ps 'get-commitment cid)))
    (cond
      ((not cmt) (failure "commitment not found"))
      (else
       (catch-as-failure
         (lambda ()
           (let* ((eid (string-append "evt-" (number->string (current-time))
                                      "-" (number->string (random 100000))))
                  (evt (make-work-event
                         #:id eid
                         #:provider provider
                         #:effort-qty qty
                         #:effort-unit unit
                         #:fulfills cid
                         #:input-of (commitment-input-of cmt)
                         #:resource-spec (commitment-resource-conforms-to cmt))))
             ($ obs 'record-event evt)
             (success eid))))))))

;;; ── ^planner-service actor ───────────────────────────────────────────
;;;
;;; Lives inside planner-vat. The scopes hashmap maps a string scope-id
;;; to the corresponding ^scope-root reference (also in planner-vat).
;;; All store calls use synchronous `$` near-call semantics.
;;;
;;; The actor has no state, so `bcom` is unused. The scopes hashmap is
;;; closed over at spawn time. Future create-scope methods would bcom
;;; to a new instance with an extended hashmap.

(define-actor (^planner-service bcom scopes-hm)

  ;; Helper: resolve a scope-id to its scope-root or return a failure
  ;; envelope. Used by every method below to dedupe the lookup pattern.
  (define (with-scope scope-id proc)
    (let ((root (hashmap-ref scopes-hm scope-id #f)))
      (if root (proc root) (failure "scope not found"))))

  (methods

    ((scope-list)
     (hashmap-fold
       (lambda (sid root acc)
         (cons `((id . ,sid) (name . ,($ root 'name))) acc))
       '() scopes-hm))

    ((scope-snapshot scope-id plan-id)
     (with-scope scope-id
       (lambda (root) (build-snapshot root scope-id plan-id))))

    ((process-context scope-id process-id)
     (with-scope scope-id
       (lambda (root) (build-process-context root process-id))))

    ((accept-assignment scope-id intent-id acting-as)
     (with-scope scope-id
       (lambda (root) (do-accept-assignment root intent-id acting-as scope-id))))

    ((decline-assignment scope-id intent-id acting-as)
     (with-scope scope-id
       (lambda (root) (do-decline-assignment root intent-id acting-as))))

    ((record-effort scope-id commitment-id acting-as qty unit)
     (with-scope scope-id
       (lambda (root) (do-record-effort root commitment-id acting-as qty unit))))))
