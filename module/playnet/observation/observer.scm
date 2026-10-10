;;; observer.scm — Goblins actor for the VF event-sourced stockbook
;;;
;;; Architecture: The Observer is a FOLD.
;;;
;;;   observer-record-event : (state, event) -> (state, affected)
;;;
;;; Each event is folded over the observer state through a pipeline of
;;; pure phases:
;;;
;;;   1. phase-append-event        — prepend event to log
;;;   2. phase-index-event         — update lookup indexes
;;;   3. phase-apply-effects       — VF action effects on resources
;;;   4. phase-containment-cascade — what a stock holds follows its draw
;;;   5. phase-location-cascade    — what a stock holds follows its move
;;;   6. phase-breadcrumb-chain    — the resource's previous event
;;;   7. phase-implied-transfer    — cross-agent rights transfer
;;;   8. phase-follow-count        — the stored figure follows the stock's latest count
;;;
;;; The actor's bcom IS the fold's commit step. Each message delivery
;;; is one fold iteration; bcom commits the new accumulator.

(define-module (playnet observation observer)
  #:use-module (playnet vf serdes)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet observation states)
  #:use-module (playnet vf beyond lot)
  #:use-module (playnet utils store-utils)
  #:use-module ((playnet vf facts parts) #:select (make-part covers?))
  #:use-module ((playnet utils units) #:select (unit-factor hours-in time-unit? placeholder-unit? unit-measurable-substance %count-unit))
  #:use-module ((playnet vf formulas counting) #:select (count-target count-figure count-base-id %count-tolerance))
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module (playnet utils clock)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap)
  #:re-export (measure-qty get-action-def)   ; a measure's number and an action's table row are the records' (vf/schemas.scm)
  #:export (standing-events standing-event void-event void-correction?
           <observer-state> make-observer-state observer-state? os-events
            os-resources os-commitment-targets os-intent-targets os-claim-targets os-satisfiers
            os-terms os-idx-by-link
            os-idx-by-resource os-idx-by-process os-idx-by-agent os-idx-by-action
            os-events-by-id os-idx-by-spec os-agreements os-batches
            os-resource-batches os-plan-validations os-intent-validations
            empty-observer-state os-rebuild <fold-ctx> make-fold-ctx
            fold-ctx? ctx-state ctx-affected ctx-update-state  event-qty
            resource-unit append-index apply-quantity-effect
            apply-resource-effects phase-append-event phase-index-event
            apply-direction-effects economic-resource-set-lot
            economic-resource-set-location economic-resource-set-custodian-scope economic-resource-set-onhand-quantity
            scale-measure economic-resource-scale-quantities split-custody?
            override-action-def create-batch-for-produce capture-container-location
            apply-container-location economic-resource-set-previous-event
            make-cascade-event cascade-emit phase-containment-cascade
            cascade-parent-id event-onhand-delta onhand-as-of
            count-anchor? standing-anchors latest-anchor anchored-onhand phase-follow-count
            relocate-contents phase-location-cascade
            economic-resource-set-tracking-identifier legacy-corrections->canonical
            standing-of correction? back-out
            phase-breadcrumb-chain phase-apply-effects phase-implied-transfer
            fulfillment-of satisfaction-of claim-state-of counted-quantity target-passed? reach-slack with-process os-processes process-spec-of
            validated-effort event-fraction intent-counts-at? recognized-at?
            ss-fraction fraction-for-intent events-with-action ledger-gross
            %validation-window event-instant window-lapsed? window-pending?
            pending-gross
            fold-by hours-by hours-on event-terms
            ledger-claimed skill-hours-of work-practice earned-skills practiced-hours
            event-stamps event-interval event-process arc-observations
            fraction-for-process  observer-record-event
            check-process-completion economic-event->list list->economic-event
            economic-resource->list list->economic-resource
            serialize-observer-state
            deserialize-observer-state %hm-tag state->portable portable->state
            serialize-observer-state-portable deserialize-observer-state-portable
            ^observer observer-env)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

(cond-expand (guile) (else
  (define (string-contains s pat)          ; the first index of PAT in S, or #f (Hoot has no srfi-13)
    (let ((n (string-length s)) (m (string-length pat)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) pat) i)
              (else (loop (+ i 1)))))))))



;; Assumes schemas.scm and store-utils.scm are loaded.


;; ═════════════════════════════════════════════════════════════════════════
;; Observer state + functional updaters
;; ═════════════════════════════════════════════════════════════════════════

;; One list of fields states the record, its empty value and its functional update, so a
;; field is added in one place and is carried by every update that does not name it.
(define-syntax-rule (define-state-record type (make empty update) pred (field accessor init) ...)
  (begin
    (define-record-type type (make field ...) pred (field accessor) ...)
    (define (empty) (make init ...))
    (define* (update st #:key (field (accessor st)) ...) (make field ...))))

;; (os-rebuild st #:field value …) is ST with the named fields replaced.
(define-state-record <observer-state>
  (make-observer-state empty-observer-state os-rebuild)
  observer-state?
  (events          os-events (quote ()))
  (resources       os-resources (hashmap))
  ;; What was REGISTERED, and nothing of what has happened since: how far a
  ;; commitment is fulfilled, an intent satisfied or a claim settled is read off
  ;; the events on every ask (fulfillment-of, satisfaction-of, claim-state-of), so
  ;; the books hold no count that could drift from the log.
  (commitment-targets os-commitment-targets (hashmap))   ;; commitment id -> its quantity, a <measure>
  (intent-targets  os-intent-targets (hashmap))          ;; intent id -> (its quantity . the plan it is part of, or #f)
  (claim-targets   os-claim-targets (hashmap))           ;; claim id -> its quantity, a <measure>
  (idx-by-resource os-idx-by-resource (hashmap))
  (idx-by-process  os-idx-by-process (hashmap))
  (idx-by-agent    os-idx-by-agent (hashmap))
  (idx-by-action   os-idx-by-action (hashmap))
  (events-by-id    os-events-by-id (hashmap))
  (idx-by-spec     os-idx-by-spec (hashmap))        ;; spec-id -> list of resource-ids
  (agreements      os-agreements (hashmap))          ;; agreement-id -> agreement alist
  (batches         os-batches (hashmap))             ;; batch-id -> <batch-lot-record>
  (resource-batches os-resource-batches (hashmap))   ;; resource-id -> list of batch-ids
  ;; Federation validation (§III.1). The Validation Gate is the union
  ;; of two recognition rails — plan-level and intent-level — read by
  ;; one predicate (intent-counts-at?). Both rails feed the single
  ;; chokepoint (validated-gross), so voice weighting and Credit
  ;; validity share the same universality measure.
  ;;
  ;;   plan-validations:   plan-id   -> list of scope-ids that recognize
  ;;                       the plan. Mirrors satisfaction-state.plan-id.
  ;;   intent-validations: intent-id -> list of scope-ids that recognize
  ;;                       the intent directly (closes the loose-intent
  ;;                       seam: uncoordinated work becomes recognisable
  ;;                       without forcing plan-membership).
  ;;
  ;; Recognition is binary; aggregation stays labor-proportional. These
  ;; maps are recognition's one home: a fact about this scope's own
  ;; record, written through the scope-root's confirm/recognize doors.
  (plan-validations  os-plan-validations (hashmap))    ;; plan-id   -> list of scope-ids
  (intent-validations os-intent-validations (hashmap))  ;; intent-id -> list of scope-ids
  ;; Fulfilment, satisfaction and settlement are READ from the events, never
  ;; counted: an event names the commitment it fulfils, the intent it satisfies,
  ;; the claim it settles, and these are the lists of events by those names
  ;; ("fulfills|c1" -> event ids, newest first). Derived from the log, so not
  ;; serialized: a loaded snapshot rebuilds them.
  (idx-by-link     os-idx-by-link (hashmap))
  ;; What a registered commitment says about the events that count toward it:
  ;; cid -> (action spec (intent-id ...)). The target quantity stands in
  ;; commitment-targets; these are the rest of the join.
  (terms           os-terms (hashmap))
  ;; The processes the books were told of: process id -> <process>. A process is
  ;; based on a ProcessSpecification (VF Process.basedOn): the stage effect of an event
  ;; that is the output of a process sets the resource's stage to that specification,
  ;; and a performed ride finds its mode's recipe through it.
  (processes       os-processes (hashmap))
  ;; The commitments that satisfy an intent (VF: "Commitments can satisfy Intents",
  ;; flows.md): intent id -> commitment ids, the terms read the other way. Derived
  ;; from the terms, so not serialized: a loaded snapshot rebuilds it.
  (satisfiers      os-satisfiers (hashmap)))

(define (with-process st process)
  "ST knowing PROCESS (a <process>, held under its id)."
  (if (process-id process)
      (os-rebuild st #:processes (hashmap-set (os-processes st) (process-id process) process))
      st))

(define (process-spec-of st pid)
  "The ProcessSpecification process PID is based on, #f for a process the books do not
   know or that is based on none."
  (let ((p (and pid (hashmap-ref (os-processes st) pid #f))))
    (and p (process-based-on p))))

(define (put-resource st id r)
  "ST with resource R held under ID."
  (os-rebuild st #:resources (hashmap-set (os-resources st) id r)))
(define (hold-resource st resource)
  "ST with RESOURCE held under its id and indexed under its specification."
  (let* ((rid  (economic-resource-id resource))
         (spec (economic-resource-conforms-to resource))
         (idx  (if spec
                   (let ((existing (hashmap-ref (os-idx-by-spec st) spec '())))
                     (if (member rid existing) (os-idx-by-spec st)
                         (hashmap-set (os-idx-by-spec st) spec (cons rid existing))))
                   (os-idx-by-spec st))))
    (os-rebuild st #:resources (hashmap-set (os-resources st) rid resource) #:idx-by-spec idx)))
(define (event-ref st id) (hashmap-ref (os-events-by-id st) id #f))
(define (events-named st ids)
  "The events among IDS the ledger holds, in IDS' order."
  (filter-map (lambda (id) (event-ref st id)) ids))


;; ═════════════════════════════════════════════════════════════════════════
;; Fold context: state + affected-resources accumulator
;; ═════════════════════════════════════════════════════════════════════════

(define-record-type <fold-ctx>
  (make-fold-ctx state affected)
  fold-ctx?
  (state    ctx-state)
  (affected ctx-affected))

(define (ctx-update-state ctx f)
  (make-fold-ctx (f (ctx-state ctx)) (ctx-affected ctx)))


;; ═════════════════════════════════════════════════════════════════════════
;; Quantity helpers
;; ═════════════════════════════════════════════════════════════════════════

(define (event-qty event)
  (or (economic-event-resource-quantity event)
      (economic-event-effort-quantity event)))

;; A RESOURCE KEEPS ITS OWN UNIT. What a stock is counted in is a fact about the
;; stock, and an event says nothing about it: `event-qty` falls through to
;; effortQuantity, so a `use` measured in hours would rename three vans
;; "3.0 hours" — same number, new substance, silently, and the next plan would
;; read that as three van-HOURS. Downstream now depends on this holding still:
;; ingest-located asks whether a holding is a count or already a flow, and it can
;; only ask if the answer stops changing under events.
;;
;; The event's unit is the fallback for a resource that has none yet, never an
;; override for one that does.
(define (resource-unit resource event)
  (or (resource-own-unit resource)
      (and (event-qty event) (measure-has-unit (event-qty event)))
      %count-unit))

;; ── an event's quantity, in the resource's unit ───────────────────────────────
;; A quantity is added to a stock in the stock's own unit: 500 g taken from a
;; kilogram stock is half a kilogram. Two units of one physical substance (mass,
;; volume, time, energy…) convert through the unit tables; units of different
;; substances refuse, since adding them has no meaning. Counts and names the
;; tables do not know ("each", "loaf"), and the placeholder "unit" the plan's
;; rows carry until its doors state the specification's own unit, read as the
;; resource's unit. Effort never moves stock (VF actions.md): only the
;; event's resourceQuantity counts here.
(define (resource-own-unit resource)
  (or (and (economic-resource-accounting-quantity resource)
           (measure-has-unit (economic-resource-accounting-quantity resource)))
      (and (economic-resource-onhand-quantity resource)
           (measure-has-unit (economic-resource-onhand-quantity resource)))))
(define (stock-qty event resource)
  "EVENT's resource quantity as a number of RESOURCE's own unit (as stated, with
   no resource to read it against)."
  (let ((m (economic-event-resource-quantity event)))
    (if (not m)
        0
        (let ((f (unit-factor (measure-has-unit m) (and resource (resource-own-unit resource)))))
          (unless f
            (error "an event's quantity must be in a unit the stock is counted in"
                   (economic-event-id event) (measure-has-unit m) (resource-own-unit resource)))
          (* f (measure-has-numerical-value m))))))


(define (append-index hm key val)
  (hashmap-set hm key (cons val (hashmap-ref hm key '()))))


;; ═════════════════════════════════════════════════════════════════════════
;; VF action effect application (pure — unchanged from before)
;; ═════════════════════════════════════════════════════════════════════════

(define (effect-delta effect direction qty)
  "What EFFECT does to a stock's quantity on DIRECTION's side of an event of QTY, signed."
  (case effect
    ((increment)           (if (eq? direction 'from) qty 0))
    ((decrement)           (if (eq? direction 'from) (- qty) 0))
    ((decrement-increment) (if (eq? direction 'from) (- qty) qty))
    ((increment-to)        (if (eq? direction 'to) qty 0))
    (else 0)))

(define (apply-quantity-effect resource field-accessor effect direction qty)
  (+ (measure-qty (field-accessor resource)) (effect-delta effect direction qty)))

(define (quantity-moves? effect direction)
  "EFFECT changes a stock's quantity on DIRECTION's side of the event."
  (case effect
    ((increment decrement) (eq? direction 'from))
    ((increment-to)        (eq? direction 'to))
    ((decrement-increment) #t)
    (else #f)))

(define* (apply-resource-effects resource event action-def direction #:optional (created? #f) (process-spec #f))
  "RESOURCE with EVENT's effects for one DIRECTION applied. CREATED? says the event
   just brought RESOURCE into being: the `new` location and accountable effects
   (produce, copy, raise, lower) are for a resource the event creates (VF
   actions.md: \"For `new`, the resource's location should be set only if it is a
   new resource\"). PROCESS-SPEC is the specification of the process EVENT is the
   output of, #f when it is based on none: the `update` stage effect sets the
   resource's stage to it (actions.md stageEffect)."
  (let* ((qty (if (or (quantity-moves? (action-definition-accounting-effect action-def) direction)
                      (quantity-moves? (action-definition-onhand-effect action-def) direction))
                  (stock-qty event resource)       ; read in the stock's unit where it is applied to it
                  0))
         (unit (resource-unit resource event))
         (new-acct (apply-quantity-effect resource economic-resource-accounting-quantity
                     (action-definition-accounting-effect action-def) direction qty))
         (new-onhand (apply-quantity-effect resource economic-resource-onhand-quantity
                       (action-definition-onhand-effect action-def) direction qty))
         (loc-eff (action-definition-location-effect action-def))
         (new-location
           (cond
             ((and (economic-event-to-location event)
                   (or (and (eq? loc-eff 'update) (eq? direction 'from))
                       (and (eq? loc-eff 'update-to) (eq? direction 'to))
                       (and (eq? loc-eff 'new) created?)))
              (economic-event-to-location event))
             ((and (economic-event-at-location event) (eq? loc-eff 'new) created?)
              (economic-event-at-location event))
             (else (economic-resource-current-location resource))))
         (contain-eff (action-definition-contained-effect action-def))
         (new-contained
           (cond
             ((and (eq? contain-eff 'update) (eq? direction 'from)
                   (economic-event-to-resource-inventoried-as event))
              (economic-event-to-resource-inventoried-as event))
             ((and (eq? contain-eff 'remove) (eq? direction 'from)) #f)
             (else (economic-resource-contained-in resource))))
         (acct-eff (action-definition-accountable-effect action-def))
         (new-accountable
           (cond
             ((or (and (eq? acct-eff 'new) created?)
                  (and (eq? acct-eff 'update-to) (eq? direction 'to)))
              ;; a resource the event creates is the receiver's (none named: no one's);
              ;; an existing one keeps its accountable agent when no receiver is named
              (if created?
                  (economic-event-receiver event)
                  (or (economic-event-receiver event)
                      (economic-resource-primary-accountable resource))))
             (else (economic-resource-primary-accountable resource))))
         (stage-eff (action-definition-stage-effect action-def))
         (new-stage
           (if (and (eq? stage-eff 'update) (eq? direction 'from) process-spec)
               process-spec
               (economic-resource-stage resource)))
         (state-eff (action-definition-state-effect action-def))
         (new-state
           (if (and (economic-event-state event)
                    (or (and (eq? state-eff 'update) (eq? direction 'from))
                        (and (eq? state-eff 'update-to) (eq? direction 'to))))
               (economic-event-state event)
               (economic-resource-state resource))))
    (copy-economic-resource resource
      #:accounting-quantity (make-measure new-acct unit)
      #:onhand-quantity (make-measure new-onhand unit)
      #:current-location new-location
      #:primary-accountable new-accountable
      #:stage new-stage
      #:state new-state
      #:contained-in new-contained
      #:previous-event (economic-event-id event))))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 1: Append event to log
;; ═════════════════════════════════════════════════════════════════════════

(define (phase-append-event st event)
  (os-rebuild st #:events (cons event (os-events st))))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 2: Index event (pure — no set!)
;; ═════════════════════════════════════════════════════════════════════════

;; the lists of events by the commitment, intent and claim they name
(define (link-key kind id) (keyed-id kind id))
(define (link-index ibl event)
  (fold (lambda (kind id ibl)
          (if id (append-index ibl (link-key kind id) (economic-event-id event)) ibl))
        ibl
        '("fulfills" "satisfies" "settles")
        (list (economic-event-fulfills event) (economic-event-satisfies event)
              (economic-event-settles event))))

(define (phase-index-event st event)
  (let* ((eid (economic-event-id event))
         (ibr (os-idx-by-resource st))
         (ibp (os-idx-by-process st))
         (iba (os-idx-by-agent st))
         (ibact (os-idx-by-action st))
         (ebi (os-events-by-id st))
         ;; Conditional index updates via let* threading
         (ibr (if (economic-event-resource-inventoried-as event)
                  (append-index ibr (economic-event-resource-inventoried-as event) eid)
                  ibr))
         (ibr (if (economic-event-to-resource-inventoried-as event)
                  (append-index ibr (economic-event-to-resource-inventoried-as event) eid)
                  ibr))
         ;; a count's record is indexed under the stock it counts
         (ibr (let ((rid (count-sighting-of event)))
                (if rid (append-index ibr (anchor-key rid) eid) ibr)))
         (ibp (if (economic-event-input-of event)
                  (append-index ibp (economic-event-input-of event) eid) ibp))
         (ibp (if (economic-event-output-of event)
                  (append-index ibp (economic-event-output-of event) eid) ibp))
         (iba (if (economic-event-provider event)
                  (append-index iba (economic-event-provider event) eid) iba))
         ;; the receiver is indexed when it is another agent: an event that one
         ;; agent gives and receives is that agent's once
         (iba (if (and (economic-event-receiver event)
                       (not (equal? (economic-event-receiver event) (economic-event-provider event))))
                  (append-index iba (economic-event-receiver event) eid) iba))
         (ibact (append-index ibact (economic-event-action event) eid))
         (ebi (hashmap-set ebi eid event)))
    (os-rebuild st #:idx-by-resource ibr #:idx-by-process ibp #:idx-by-agent iba #:idx-by-action ibact #:events-by-id ebi
                   #:idx-by-link (link-index (os-idx-by-link st) event))))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 3: Apply resource effects (via fold-ctx)
;; ═════════════════════════════════════════════════════════════════════════

(define (apply-direction-effects ctx event def resource-id direction)
  "Apply VF effects to a resource. Auto-creates if createResource allows.
   Returns updated fold-ctx."
  (if (not resource-id) ctx
      (let* ((st (ctx-state ctx))
             (existing (hashmap-ref (os-resources st) resource-id #f))
             ;; Auto-create resource if it doesn't exist and action allows it
             (create-flag (action-definition-create-resource def))
             (should-create (and (not existing)
                                 (or (and (eq? direction 'from) (eq? create-flag 'optional))
                                     (and (eq? direction 'to) (memq create-flag '(optional-to optional))))))
             (resource (or existing
                          (and should-create
                               (make-economic-resource
                                 #:id resource-id
                                 #:conforms-to (or (economic-event-resource-conforms-to event) "")
                                 #:classified-as (economic-event-resource-classified-as event)
                                 ;; born in the unit the event measures it in: a
                                 ;; resource that first appears as 100 kg is a
                                 ;; kilogram thing. `each` is only the fallback for
                                 ;; an event that names no unit either — and since
                                 ;; a resource now KEEPS its unit against later
                                 ;; events, the one it is born with is the one it
                                 ;; keeps, so it has to be right here.
                                 #:accounting-quantity (make-measure 0 (or (and (event-qty event)
                                                          (measure-has-unit (event-qty event)))
                                                     %count-unit))
                                 #:onhand-quantity (make-measure 0 (or (and (event-qty event)
                                                          (measure-has-unit (event-qty event)))
                                                     %count-unit))
                                 ;; the lot a pickup makes is the cargo on its way: it stands at no place
                                 #:current-location (and (not (and (eq? direction 'to) (eq? (economic-event-action event) 'pickup)))
                                      (or (economic-event-at-location event)
                                          (economic-event-to-location event)))
                                 ;; a resource the event brings into being starts with the
                                 ;; accountable agent of the stock it came from (rights stay
                                 ;; where they were); the action's accountable effect, applied
                                 ;; below, then sets the receiver where it says to
                                 #:primary-accountable (let ((origin (and (eq? direction 'to)
                                                    (economic-event-resource-inventoried-as event)
                                                    (hashmap-ref (os-resources st)
                                                                 (economic-event-resource-inventoried-as event) #f))))
                                   (and origin (economic-resource-primary-accountable origin)))
                                 #:distribution-mode (event-distribution-mode event))))))
        (if (not resource) ctx
            (let* ((updated (apply-resource-effects resource event def direction should-create
                              (let ((o (economic-event-output-of event)))
                                (and o (process-spec-of st o)))))
                   ;; Maintain spec index for new resources
                   (new-ibs (if (and should-create (economic-resource-conforms-to updated))
                                (let* ((spec (economic-resource-conforms-to updated))
                                       (existing-ids (hashmap-ref (os-idx-by-spec st) spec '())))
                                  (hashmap-set (os-idx-by-spec st) spec
                                    (cons resource-id existing-ids)))
                                (os-idx-by-spec st)))
                   (new-st (os-rebuild st
                             #:resources (hashmap-set (os-resources st) resource-id updated)
                             #:idx-by-spec new-ibs)))
              (make-fold-ctx new-st (cons updated (ctx-affected ctx))))))))

;; ── Resource field setters (functional — return new record) ─────────

(define (economic-resource-set-lot r lot)
  (copy-economic-resource r #:lot lot))

(define (economic-resource-set-tracking-identifier r code)
  (copy-economic-resource r #:tracking-identifier code))

(define (economic-resource-set-location r loc)
  (copy-economic-resource r #:current-location loc))

(define (economic-resource-set-onhand-quantity r m)
  "R with its onhand holding replaced by measure M — the per-solve VIEW of a
   holding bounded by a grant (a consume-grant lends 10 of 100 EUR), rights
   and every other field untouched."
  (copy-economic-resource r #:onhand-quantity m))

(define (economic-resource-set-custodian-scope r scope)
  (copy-economic-resource r #:custodian-scope scope))

;; scale a resource's quantities by FACTOR (for proportional containment
;; draw-down: consuming half a carrot consumes half of each contained nutrient).
(define (scale-measure m factor)
  (if m (make-measure (* factor (measure-has-numerical-value m)) (measure-has-unit m)) m))
(define (economic-resource-scale-quantities r factor)
  (copy-economic-resource r
    #:accounting-quantity (scale-measure (economic-resource-accounting-quantity r) factor)
    #:onhand-quantity (scale-measure (economic-resource-onhand-quantity r) factor)))

;; ── Split-custody predicate ──────────────────────────────────────────

(define (carried-lot? event)
  "A pickup or dropoff that names the lot the cargo moves into."
  (and (relocating-action? (economic-event-action event))
       (economic-event-to-resource-inventoried-as event)
       #t))

(define (split-custody? event)
  "Detect the implied custody transfer: pickup/dropoff or accept/modify with two
   resources and different agents (VF transfers.md: a different provider and
   receiver on these actions imply a transfer of custody)."
  (and (memq (economic-event-action event) in-place-actions)
       (economic-event-to-resource-inventoried-as event)
       (economic-event-provider event)
       (economic-event-receiver event)
       (not (equal? (economic-event-provider event)
                    (economic-event-receiver event)))))

(define (override-action-def def overrides)
  "Create a copy of action-def with specific fields overridden.
   overrides: alist of (field . value), any field of <action-definition>.
   A field whose override value is #f is still applied — presence in the alist
   decides, not truthiness, so 'no-effect and #f are both sayable."
  (define (field name accessor)
    (let ((cell (assq name overrides)))
      (if cell (cdr cell) (accessor def))))
  ;; argument order IS the record's field order (schemas.scm <action-definition>)
  (make-action-definition
    #:event-quantity (field 'event-quantity        action-definition-event-quantity)
    #:input-output (field 'input-output          action-definition-input-output)
    #:pairs-with (field 'pairs-with            action-definition-pairs-with)
    #:create-resource (field 'create-resource       action-definition-create-resource)
    #:accounting-effect (field 'accounting-effect     action-definition-accounting-effect)
    #:onhand-effect (field 'onhand-effect         action-definition-onhand-effect)
    #:location-effect (field 'location-effect       action-definition-location-effect)
    #:contained-effect (field 'contained-effect      action-definition-contained-effect)
    #:accountable-effect (field 'accountable-effect    action-definition-accountable-effect)
    #:stage-effect (field 'stage-effect          action-definition-stage-effect)
    #:state-effect (field 'state-effect          action-definition-state-effect)
    #:implies-transfer (field 'implies-transfer      action-definition-implies-transfer)
    #:eligible-for-exchange (field 'eligible-for-exchange action-definition-eligible-for-exchange)))

;; ── Batch creation on produce ───────────────────────────────────────

(define (create-batch-for-produce ctx event resource-id)
  "Create a BatchLotRecord when produce auto-creates a resource."
  (let* ((st (ctx-state ctx))
         (batch-id (generate-id "batch-"))
         (ts (or (economic-event-has-point-in-time event) "unknown"))
         (code (string-append "batch-" ts "-" (substring batch-id 0 (min 6 (string-length batch-id)))))
         (batch (make-batch-lot-record batch-id code #f))
         ;; Store batch
         (new-batches (hashmap-set (os-batches st) batch-id batch))
         ;; Link resource → batch
         (existing-batch-ids (hashmap-ref (os-resource-batches st) resource-id '()))
         (new-rb (hashmap-set (os-resource-batches st) resource-id
                   (cons batch-id existing-batch-ids)))
         ;; Update resource's lot field
         (resource (hashmap-ref (os-resources st) resource-id #f))
         (new-resources
           (if resource
               (hashmap-set (os-resources st) resource-id
                 (economic-resource-set-lot resource batch))
               (os-resources st)))
         (new-st (os-rebuild st
                   #:resources new-resources
                   #:batches new-batches
                   #:resource-batches new-rb)))
    (make-fold-ctx new-st (ctx-affected ctx))))

;; ── Container location capture for separate ─────────────────────────

(define (capture-container-location st event)
  "Pre-capture: get container's currentLocation before separate detaches."
  (if (not (eq? (economic-event-action event) 'separate)) #f
      (let ((rid (economic-event-resource-inventoried-as event)))
        (and rid
             (let ((resource (hashmap-ref (os-resources st) rid #f)))
               (and resource (economic-resource-contained-in resource)
                    (let ((container (hashmap-ref (os-resources st)
                                      (economic-resource-contained-in resource) #f)))
                      (and container (economic-resource-current-location container)))))))))

(define (apply-container-location ctx event container-location)
  "Post-apply: inherit container location after separate."
  (if (not (and (eq? (economic-event-action event) 'separate) container-location)) ctx
      (let* ((rid (economic-event-resource-inventoried-as event))
             (st (ctx-state ctx))
             (resource (and rid (hashmap-ref (os-resources st) rid #f))))
        (if (not resource) ctx
            (let* ((explicit-loc (economic-event-to-location event))
                   (new-loc (or explicit-loc container-location))
                   (updated (economic-resource-set-location resource new-loc))
                   (new-st (put-resource st rid updated)))
              (make-fold-ctx new-st (ctx-affected ctx)))))))

;; ── Containment cascade: an event on a CONTAINER reaches its contents ─
;; Contained resources (nutrients in a carrot, cargo in a vehicle) are inert in
;; the bare VF fold — an event names one resource and touches only it. This
;; phase propagates a pure draw-down (consume/lower) DOWN the containment tree:
;; consuming a fraction of a container consumes that fraction of each thing it
;; contains, recursively. Conserves mass (nothing appears or vanishes; the
;; contents shrink with their container). A `raise` is the lower's inverse: a
;; count that finds more of the container finds that much more of what it
;; holds, by the same factor, so a lower and the raise that answers it leave
;; the contents where they stood. Transfers (decrement-increment) and
;; relocation are deferred — they need re-parenting, handled separately.
;;
;; Crucially, the draw-down is EVENTED, not a silent state mutation: each content
;; gets a synthesized `consume` EconomicEvent sharing the container event's
;; process (inputOf), so the contents are first-class in the event/resource graph.
;; Without this, the contained matter is invisible to everything that walks that
;; graph — track-trace would lose its lineage, and rollup-actual-cost would lose
;; its embodied SNLT — at every containment boundary. (The parent consume event
;; is still the only logged decision; these are its deterministic consequences,
;; re-derived identically on replay.)

;; functional setter — a content's breadcrumb points at its cascade event
(define (economic-resource-set-previous-event r eid)
  (copy-economic-resource r #:previous-event eid))

;; A cascade event's id is its parent's id, this mark, and the content's id, so
;; the event a whole cascade hangs from is read off any id in it.
(define %cascade-mark "~contains~")

;; the adjustment that brings a stock back to what its latest count says is the
;; consequence of the event it follows, as a cascade event is of its parent
(define %rebase-mark "~rebases~")

(define (cascade-parent-id id)
  "The id of the logged event cascade or rebase event ID hangs from, however
   deep; #f for an event that is a decision of its own."
  (and (string? id)
       (let ((i (string-contains id %cascade-mark))
             (j (string-contains id %rebase-mark)))
         (and (or i j)
              (substring id 0 (if (and i j) (min i j) (or i j)))))))

;; synthesize the content's event from the container's event: same process
;; (inputOf), provider/receiver, time, location; previousEvent chains to the
;; parent so provenance threads container → content. ACTION is `consume` for a
;; draw-down and `raise` for a raise.
(define* (make-cascade-event parent content-id content-spec drawn
                             #:optional (action 'consume))
  (make-economic-event
   #:id (string-append (economic-event-id parent) %cascade-mark content-id) ; id
   #:action action                                         ; action
   #:input-of (economic-event-input-of parent)              ; inputOf — same process
                                             ; outputOf
   #:resource-inventoried-as content-id                                     ; resourceInventoriedAs
                                             ; toResourceInventoriedAs
   #:resource-conforms-to content-spec                                   ; resourceConformsTo
                                             ; resourceClassifiedAs
   #:provider (economic-event-provider parent)              ; provider
   #:receiver (economic-event-receiver parent)              ; receiver
   #:resource-quantity drawn                                          ; resourceQuantity (amount drawn)
                                        ; effort, hasBeginning, hasEnd
   #:has-point-in-time (economic-event-has-point-in-time parent)     ; hasPointInTime
                                             ; created
   #:at-location (economic-event-at-location parent)           ; atLocation
                                  ; toLocation, state, fulfills, satisfies, corrects
                                           ; realizationOf, settles
   #:note "containment cascade"                          ; note
   #:in-scope-of (economic-event-in-scope-of parent)           ; inScopeOf
   #:previous-event (economic-event-id parent)))                     ; previousEvent — lineage to parent

(define (cascade-emit st parent-id factor parent-event seen)
  (if (member parent-id seen) st
      (fold (lambda (kid s)
              (let* ((kid-id (economic-resource-id kid))
                     (onh    (economic-resource-onhand-quantity kid))
                     (pre    (and onh (measure-has-numerical-value onh)))
                     (unit   (and onh (measure-has-unit onh)))
                     (drawn  (and pre (make-measure (* pre (abs (- 1 factor))) (or unit %count-unit))))
                     (cev    (make-cascade-event parent-event kid-id
                                                 (economic-resource-conforms-to kid) drawn
                                                 (if (> factor 1) 'raise 'consume)))
                     (scaled (economic-resource-set-previous-event
                               (economic-resource-scale-quantities kid factor)
                               (economic-event-id cev)))
                     (s1     (phase-append-event s cev))
                     (s2     (phase-index-event s1 cev))
                     (s3     (put-resource s2 kid-id scaled)))
                ;; recurse with the child's event as parent → provenance chains down
                (cascade-emit s3 kid-id factor cev (cons parent-id seen))))
            st
            (filter (lambda (r) (equal? (economic-resource-contained-in r) parent-id))
                    (hashmap-values (os-resources st))))))

(define (phase-containment-cascade ctx event def)
  ;; only PURE decrements (consume, lower) and the lower's inverse, a raise —
  ;; transfers carry contents elsewhere, and a produce adds to the container
  ;; without saying what the new units hold
  (if (not (or (and (eq? (action-definition-onhand-effect def) 'decrement)
                    (eq? (action-definition-accounting-effect def) 'decrement))
               (eq? (economic-event-action event) 'raise)))
      ctx
      (let* ((st       (ctx-state ctx))
             (up?      (eq? (economic-event-action event) 'raise))
             (from-id  (economic-event-resource-inventoried-as event))
             (cont     (and from-id (hashmap-ref (os-resources st) from-id #f)))
             (m        (economic-event-resource-quantity event))
             (q        (and cont m (stock-qty event cont)))          ; in the container's own unit
             (onh      (and cont (economic-resource-onhand-quantity cont)))
             (post     (and onh (measure-has-numerical-value onh))))
        (if (or (not cont) (not q) (not post)
                ;; no contents → nothing to cascade
                (null? (filter (lambda (r) (equal? (economic-resource-contained-in r) from-id))
                               (hashmap-values (os-resources st)))))
            ctx
            (let* ((pre    (if up? (- post q) (+ post q))) ; onhand before this event
                   ;; The contents keep the share of the container's units that remain:
                   ;; consuming 3 of 10 leaves 7/10 of every content. A container that
                   ;; held nothing has no proportion to apply, and a draw beyond what it
                   ;; held takes all of the contents and never more (the factor stays at
                   ;; or above 0), so contents never go negative by this path.
                   (factor (cond ((<= pre 0) 1) (else (max 0 (/ post pre))))))
              (if (= factor 1) ctx
                  (make-fold-ctx (cascade-emit st from-id factor event '()) (ctx-affected ctx))))))))

;; ── Location cascade: a container that moves takes its contents along ─
;; An event that MOVES a container moves what is in it, all the way down: the
;; jars in a bin carried to another shelf are on that shelf. What goes along is
;; what was where the container was (or stated no place); a content that keeps a
;; place of its own, an oven in the kitchen of a flat, keeps it. A content's
;; place is a consequence of its container's, so the restamp is derived state,
;; re-derived identically on replay, and lands no event of its own; the
;; container's event is the one decision. `separate` is the act that gives a
;; content a place of its own again (apply-container-location).

(define (relocate-contents ctx parent-id from to seen)
  "CTX with PARENT-ID's contents restamped from FROM to TO, all the way down.
   Each content that moves joins the affected resources, so the listeners an
   event reaches hear of what its container carried."
  (if (member parent-id seen) ctx
      (fold (lambda (kid c)
              (let ((kid-id (economic-resource-id kid))
                    (at     (economic-resource-current-location kid)))
                (if (or (not at) (equal? at from))
                    (let* ((moved (economic-resource-set-location kid to))
                           (c2    (make-fold-ctx
                                   (put-resource (ctx-state c) kid-id moved)
                                   (cons moved (ctx-affected c)))))
                      (relocate-contents c2 kid-id from to (cons parent-id seen)))
                    c)))
            ctx
            (filter (lambda (r) (equal? (economic-resource-contained-in r) parent-id))
                    (hashmap-values (os-resources (ctx-state ctx)))))))

(define (phase-location-cascade ctx event def before)
  "BEFORE is the state ahead of this event's effects: a container whose place
   differs from the one it had there has moved."
  (if (eq? (action-definition-location-effect def) 'no-effect)
      ctx
      (fold (lambda (rid c)
              (let* ((was  (and rid (hashmap-ref (os-resources before) rid #f)))
                     (now  (and rid (hashmap-ref (os-resources (ctx-state c)) rid #f)))
                     (from (and was (economic-resource-current-location was)))
                     (to   (and now (economic-resource-current-location now))))
                (if (and was to (not (equal? from to)))
                    (relocate-contents c rid from to '())
                    c)))
            ctx
            (list (economic-event-resource-inventoried-as event)
                  (economic-event-to-resource-inventoried-as event)))))

;; ── previousEvent breadcrumb: link resource → event chain ────────────

(define (phase-breadcrumb-chain ctx event)
  "Set resource.previousEvent = event.id for each affected resource.
   This builds the chain that trace-resource walks backward."
  (let ((from-id (economic-event-resource-inventoried-as event))
        (to-id (economic-event-to-resource-inventoried-as event))
        (eid (economic-event-id event)))
    (let* ((st (ctx-state ctx))
           ;; Update from-resource
           (st (if from-id
                   (let ((r (hashmap-ref (os-resources st) from-id #f)))
                     (if r (put-resource st from-id (economic-resource-set-previous-event r eid))
                         st))
                   st))
           ;; Update to-resource
           (st (if (and to-id (not (equal? to-id from-id)))
                   (let ((r (hashmap-ref (os-resources st) to-id #f)))
                     (if r (put-resource st to-id (economic-resource-set-previous-event r eid))
                         st))
                   st)))
      (make-fold-ctx st (ctx-affected ctx)))))

;; ── Phase 3 main: apply effects with split-custody + container ──────

(define (custody-defs event def)
  "(FROM-DEF . TO-DEF): DEF's effects on the stock EVENT names and on the one it
   moves into. The implied custody transfer (provider ≠ receiver) composes with the
   action's own effect so that each quantity moves once (the spec's transport
   example, ex-complex.md: Alice 230 → 200, Claudia 0 → 0, Bob 0 → 30):
     an INPUT (pickup, accept) takes the goods out of the provider's resource R;
       custody passes through the carrier's resource T on the way in, so T nets 0;
     an OUTPUT (dropoff, modify) puts the goods out on R and hands them to T,
       so R nets 0 and T gains them.
   T is where custody lands: created if absent, placed and stated by the event.
   One agent carrying its own cargo passes no custody, but the cargo is still a thing
   of its own on the way: a pickup that names a lot moves the quantity from the lot it
   leaves into that one (made when absent, at no place: it is on the way), and a
   dropoff moves it from the carried lot into the lot it lands in, so the spec's total
   holds at every instant, as the quantities of a `move` do.
   The fold applies these effects and the ledger as of an instant takes them back."
  (let* ((is-split (split-custody? event))
         (carried? (and (not is-split) (carried-lot? event)))
         (input?   (eq? (action-definition-input-output def) 'input)))   ;; read where split: pickup, accept
    (cons (cond (carried? (override-action-def def '((accounting-effect . decrement-increment)
                                                     (onhand-effect . decrement-increment))))
                ((not is-split) def)
                (input?  (override-action-def def '((location-effect . no-effect))))
                (else    (override-action-def def '((accounting-effect . no-effect)
                                                    (onhand-effect . no-effect)))))
          (cond (carried?
                 (override-action-def def '((accounting-effect . decrement-increment)
                                            (onhand-effect . decrement-increment)
                                            (location-effect . no-effect)
                                            (create-resource . optional-to))))   ;; the cargo's lot, made when absent
                (is-split
                 (override-action-def def
                   `((accounting-effect . no-effect)
                     (onhand-effect . ,(if input? 'no-effect 'increment-to))
                     (location-effect . update-to)
                     (state-effect . update-to)
                     (create-resource . optional))))   ;; custody lands on T: create it when absent
                (else def)))))

(define (phase-apply-effects ctx event def)
  (let* ((is-split (split-custody? event))
         ;; Pre-capture container location for separate
         (container-loc (capture-container-location (ctx-state ctx) event))
         (defs     (custody-defs event def))
         (from-def (car defs))
         (to-def   (cdr defs))
         ;; Check if from-resource exists before apply (to detect auto-creation)
         (from-id (economic-event-resource-inventoried-as event))
         (from-existed (and from-id
                            (hashmap-ref (os-resources (ctx-state ctx)) from-id #f)))
         ;; Apply from direction
         (ctx (apply-direction-effects ctx event from-def from-id 'from))
         ;; Batch creation on produce (only when resource was just auto-created)
         (ctx (if (and (eq? (economic-event-action event) 'produce)   ; verb-meant: a batch is made, and a count recorded, by a produce
                       from-id (not from-existed)
                       (hashmap-ref (os-resources (ctx-state ctx)) from-id #f))
                  (create-batch-for-produce ctx event from-id)
                  ctx))
         ;; Apply to direction
         (ctx (apply-direction-effects ctx event to-def
                (economic-event-to-resource-inventoried-as event) 'to))
         ;; Post-apply: container location inheritance for separate
         (ctx (apply-container-location ctx event container-loc))
         ;; Split-custody: clear custodianScope on from-resource
         (ctx (if is-split
                  (let* ((from-id (economic-event-resource-inventoried-as event))
                         (st (ctx-state ctx))
                         (resource (and from-id (hashmap-ref (os-resources st) from-id #f))))
                    (if resource
                        (let* ((updated (economic-resource-set-custodian-scope resource #f))
                               (new-st (put-resource st from-id updated)))
                          (make-fold-ctx new-st (ctx-affected ctx)))
                        ctx))
                  ctx)))
    ctx))


;; ═════════════════════════════════════════════════════════════════════════
;; Phase 4: Implied transfer
;; ═════════════════════════════════════════════════════════════════════════

(define (phase-implied-transfer ctx event def)
  (let ((from-id (economic-event-resource-inventoried-as event))
        (transfer-type (action-definition-implies-transfer def))
        (provider (economic-event-provider event))
        (receiver (economic-event-receiver event)))
    (if (and transfer-type from-id provider receiver
             (not (equal? provider receiver)))
        (let ((r (hashmap-ref (os-resources (ctx-state ctx)) from-id #f)))
          (if (not r) ctx
              (let ((updated
                      (cond
                        ;; All-rights: transfer primary-accountable to receiver
                        ((eq? transfer-type 'all-rights)
                         (copy-economic-resource r #:primary-accountable receiver))
                        ;; Custody: transfer custodian-scope to receiver
                        ((eq? transfer-type 'custody)
                         (economic-resource-set-custodian-scope r receiver))
                        (else r))))
                (if (eq? updated r) ctx
                    (ctx-update-state ctx
                      (lambda (st)
                        (put-resource st from-id updated)))))))
        ctx)))


;; ═════════════════════════════════════════════════════════════════════════
;; Fulfilment, satisfaction, settlement: readings of the events
;; ═════════════════════════════════════════════════════════════════════════
;;
;; ValueFlows (concepts/flows.md): an event fulfils a commitment by naming it, a
;; commitment satisfies an intent, an event settles a claim. How much has been
;; fulfilled, satisfied or settled is derived information, "could be
;; re-calculated": the sum of the quantities of the events that name the target.
;; So the observer keeps what was REGISTERED (the target quantity, and what the
;; commitment says about the events that count) and reads the progress off the
;; log, through the lists of events by the name they carry (os-idx-by-link).
;; Nothing advances when an event arrives, so an event recorded before its
;; commitment counts, registering a commitment again moves its target and never
;; its progress, and a log folded anywhere reads the same. A correction is a
;; signed event carrying the same names, so it nets in the sum.
;;
;; An event counts toward a commitment when it is of the commitment's action and
;; spec and its quantity converts to the commitment's unit; every event that
;; names a commitment is still in the log, counted or not. Finished is one
;; comparison with one tolerance, over is the same comparison past the target, and
;; an over-run keeps its true sum: the remainder is readable, never clipped.

(define %reach-tolerance 1e-9)
(define (reach-slack target) (* %reach-tolerance (max 1 (abs target))))   ; relative, with an absolute floor
(define (target-reached? total target) (>= total (- target (reach-slack target))))
(define (target-passed?  total target) (>  total (+ target (reach-slack target))))

(define (linked-events st kind id)
  "The events that name ID under KIND (fulfills, satisfies, settles), newest first."
  (events-named st (hashmap-ref (os-idx-by-link st) (link-key kind id) '())))

(define (counted-quantity e unit)
  "E's quantity as a number of UNIT, or #f when it is in a unit that does not convert.
   A target of time is answered by the event's effort (the hours it took), any other
   target by its resource quantity (how many): an event that states both, a `use`,
   answers each target in its own kind."
  (let ((m (if (eq? (unit-measurable-substance unit) 'time)
               (or (economic-event-effort-quantity e) (economic-event-resource-quantity e))
               (economic-event-resource-quantity e))))
    (if (not m)
        0
        (let ((f (unit-factor (measure-has-unit m) unit)))
          (and f (* f (measure-has-numerical-value m)))))))

(define (derive-tally events target make-state)
  "MAKE-STATE applied to the total of EVENTS in TARGET's unit, the ids that
   counted, whether the target is reached (something counted, and no more than the
   tolerance short) and whether it is passed."
  (let* ((unit (measure-has-unit target))
         (t    (measure-has-numerical-value target))
         (hits (filter-map (lambda (e)
                             (let ((q (counted-quantity e unit))) (and q (cons (economic-event-id e) q))))
                           events))
         (total (fold (lambda (h acc) (+ acc (cdr h))) 0 hits)))
    (make-state (make-measure total unit) (map car hits)
                (and (pair? hits) (target-reached? total t)) (target-passed? total t))))

(define (fulfilling-events st cid)
  "The events that count toward commitment CID: those that name it, of its action
   and spec."
  (let ((terms (hashmap-ref (os-terms st) cid #f)))
    (filter (lambda (e)
              (or (not terms)
                  (and (same-flow? (economic-event-action e) (car terms))
                       (let ((spec (cadr terms)) (espec (economic-event-resource-conforms-to e)))
                         (or (not spec) (not espec) (equal? spec espec))))))
            (linked-events st "fulfills" cid))))

(define (fulfillment-of st cid)
  "Commitment CID's <fulfillment-state> as the events read, or #f when it is not registered."
  (let ((target (hashmap-ref (os-commitment-targets st) cid #f)))
    (and target
         (derive-tally (fulfilling-events st cid) target
                       (lambda (total ids done? over?)
                         (make-fulfillment-state cid target total ids done? over?))))))

(define (satisfaction-of st iid)
  "Intent IID's <satisfaction-state> as the events read: the events that satisfy it
   directly and those that fulfil a commitment satisfying it, each once."
  (let ((stated (hashmap-ref (os-intent-targets st) iid #f)))
    (and stated
         (let* ((target (car stated))
                (cids   (hashmap-ref (os-satisfiers st) iid '()))
                (events (delete-duplicates
                         (append (linked-events st "satisfies" iid)
                                 (append-map (lambda (cid) (fulfilling-events st cid)) cids))
                         (lambda (a b) (equal? (economic-event-id a) (economic-event-id b))))))
           (derive-tally events target
                         (lambda (total ids done? over?)
                           (make-satisfaction-state iid target total ids cids done?
                                                    (cdr stated))))))))

(define (claim-state-of st cid)
  "Claim CID's <claim-state> as the events read: the events that settle it."
  (let ((target (hashmap-ref (os-claim-targets st) cid #f)))
    (and target
         (derive-tally (linked-events st "settles" cid) target
                       (lambda (total ids done? over?)
                         (make-claim-state cid target total ids done?))))))

(define (link-satisfiers satisfiers cid was now)
  "SATISFIERS (intent id -> commitment ids) with commitment CID satisfying the
   intents NOW where it satisfied the intents WAS."
  (fold (lambda (iid acc)
          (let ((cids (hashmap-ref acc iid '())))
            (if (member cid cids) acc (hashmap-set acc iid (cons cid cids)))))
        (fold (lambda (iid acc) (hashmap-set acc iid (delete cid (hashmap-ref acc iid '()))))
              satisfiers was)
        now))

(define (rebuild-satisfiers st)
  "ST with its satisfiers read off its terms."
  (os-rebuild st #:satisfiers
              (hashmap-fold (lambda (cid terms acc) (link-satisfiers acc cid '() (caddr terms)))
                            (os-satisfiers st) (os-terms st))))

(define (states-of st table state-of)
  "The derived state of every key of TABLE, as a list."
  (hashmap-fold (lambda (k _ acc) (cons (state-of st k) acc)) '() table))
(define (fulfillments-of st)  (states-of st (os-commitment-targets st) fulfillment-of))
(define (satisfactions-of st) (states-of st (os-intent-targets st) satisfaction-of))
(define (claim-states-of st)
  "Every claim's derived state, in a hashmap by claim id."
  (hashmap-fold (lambda (k _ acc) (hashmap-set acc k (claim-state-of st k))) (hashmap) (os-claim-targets st)))

;; ── Corrections: events that add what the record got wrong ──────────────────
;; ValueFlows (accounting.md "Making Corrections"; ex-production.md "Correcting
;; errors"): a recorded event is never changed. A correction is another event of
;; the SAME action on the same resource and process, `corrects` naming the event,
;; with a SIGNED quantity: the amount to add. A consume of 3 is backed out by a
;; consume of -3; a work of 7 hours is adjusted by a work of -1. The original
;; stays in the log and the net effect is the sum, so the fold applies a
;; correction exactly as it applies any event, and the state is a function of the
;; SET of events whichever order they arrive in.
;;
;; "Standing" is a reading of that set: the acts that still happened, each at its
;; net quantity. An event stands unless its corrections net it to nothing, and a
;; correction is no act of its own.
(define (correction? e) (and (economic-event-corrects e) #t))

(define (corrections-by-target events)
  "id → the events among EVENTS that correct it."
  (let ((h (make-hash-table)))
    (for-each (lambda (e)
                (let ((t (economic-event-corrects e)))
                  (when t (hash-set! h t (cons e (hash-ref h t '()))))))
              events)
    h))

(define (net-quantity e field corrections)
  "The quantity FIELD (an accessor) states for E, plus its corrections' and theirs."
  (let loop ((e e))
    (let ((m (field e)))
      (+ (if m (measure-has-numerical-value m) 0)
         (fold + 0 (map loop (hash-ref corrections (economic-event-id e) '())))))))

(define (backed-out? e corrections)
  "E has corrections and states nothing that survives them."
  (and (pair? (hash-ref corrections (economic-event-id e) '()))
       (let ((rq (economic-event-resource-quantity e))
             (eq (economic-event-effort-quantity e)))
         (and (or (not rq) (< (abs (net-quantity e economic-event-resource-quantity corrections)) 1e-9))
              (or (not eq) (< (abs (net-quantity e economic-event-effort-quantity corrections)) 1e-9))))))

(define (netted-event e corrections)
  "E with the quantities it states replaced by their net, when it has corrections."
  (if (null? (hash-ref corrections (economic-event-id e) '()))
      e
      (let ((net (lambda (field)
                   (let ((m (field e)))
                     (and m (make-measure (net-quantity e field corrections) (measure-has-unit m)))))))
        (copy-economic-event e
          #:resource-quantity (net economic-event-resource-quantity)
          #:effort-quantity   (net economic-event-effort-quantity)))))

(define (gone-ids events corrections)
  "The ids of EVENTS whose corrections net them to nothing."
  (filter-map (lambda (e) (and (backed-out? e corrections) (economic-event-id e))) events))

(define (stands? gone ev)
  "EV is none of GONE and hangs from none of them: a cascade leaves the totals
   with the event it is the consequence of."
  (let ((id (economic-event-id ev)))
    (not (or (member id gone)
             (let ((up (cascade-parent-id id))) (and up (member up gone)))))))

(define (standing-of events)
  "EVENTS (oldest first) as they stand: the acts that still happened, each at its
   net quantity, the corrections folded into what they correct."
  (let* ((cs    (corrections-by-target events))
         (known (make-hash-table))
         (_     (for-each (lambda (e) (hash-set! known (economic-event-id e) #t)) events))
         ;; what stands leaves the totals with the acts backed out AND with the
         ;; corrections that back them out: a cascade is the consequence of the
         ;; event it hangs from, and a correction is no act
         (gone  (append (gone-ids events cs)
                        (filter-map (lambda (e)
                                      (and (correction? e) (hash-ref known (economic-event-corrects e) #f)
                                           (economic-event-id e)))
                                    events))))
    ;; a correction naming an event this log never held has nothing to net into:
    ;; it stands as an event of its own, at its own signed quantity
    (filter-map (lambda (e)
                  (and (or (not (correction? e))
                           (not (hash-ref known (economic-event-corrects e) #f)))
                       (stands? gone e) (netted-event e cs)))
                events)))

(define (standing-event st id)
  "The event ID as it stands in ST's log: at its net quantity, its corrections
   folded in; #f when the log never held it or its corrections back it out."
  (find (lambda (e) (equal? (economic-event-id e) id))
        (standing-of (reverse (os-events st)))))

(define (standing-events st action)
  "ACTION's events as they stand (see standing-of)."
  (filter (lambda (e) (eq? (economic-event-action e) action))
          (standing-of (reverse (os-events st)))))

(define (void-correction? event)
  "EVENT corrects another and states a negative quantity: a back-out, no act of
   its own (it earns nothing and issues nothing)."
  (and (correction? event)
       (let ((m (event-qty event)))
         (and m (< (measure-has-numerical-value m) 0)))))

(define* (back-out original #:key id note in-scope-of at created begin end)
  "The event that takes ORIGINAL back out: ORIGINAL's own action, resource,
   process and agents, each quantity it states negated, `corrects` naming it
   (accounting.md). AT, BEGIN, END and CREATED date the correction, since the
   record is corrected as of the day it is."
  (copy-economic-event original
    #:id id
    #:resource-quantity (scale-measure (economic-event-resource-quantity original) -1)
    #:effort-quantity   (scale-measure (economic-event-effort-quantity original) -1)
    #:corrects (economic-event-id original)
    #:has-beginning begin #:has-end end #:has-point-in-time at #:created created
    #:note note #:in-scope-of in-scope-of #:previous-event #f))

(define (void-event original id note scope-id at)
  "The correcting event that replaces ORIGINAL with nothing: its full back-out.
   ID is the correction's own id; NOTE says why; AT its instant."
  (back-out original #:id id #:note note
            #:in-scope-of (if (list? scope-id) scope-id (list scope-id))
            #:at at #:created at #:begin #f #:end #f))

;; ── Older logs: a correction that REPLACES its original ──────────────────────
;; Logs and snapshots written before the ValueFlows reading hold corrections
;; that REPLACE the event they name: a restated quantity (positive), or none (a
;; void). `legacy-corrections->canonical` reads such a list once, at the replay
;; seam, into the form above: a void becomes the full back-out, and a
;; restatement becomes the back-out plus the restated event (accounting.md: "back
;; out completely, then re-enter correctly"). A list already in the canonical
;; form passes through as it stands.
(define (legacy-correction? e)
  (and (correction? e) (not (void-correction? e))))

(define (legacy-corrections->canonical events)
  "EVENTS, oldest first, with every legacy correction turned into the ValueFlows
   form (see above)."
  (let ((seen (make-hash-table)))      ; id → the event as stated
    (append-map
     (lambda (e)
       (let ((target (and (legacy-correction? e)
                          (hash-ref seen (economic-event-corrects e) #f))))
         (hash-set! seen (economic-event-id e) e)
         (cond
           ((not (legacy-correction? e)) (list e))
           ;; names an event this log never held: it stands as a plain event
           ((not target) (list (copy-economic-event e #:corrects #f)))
           (else
            (let ((out (back-out target
                                 #:id (string-append (economic-event-id e) "~backout")
                                 #:note (economic-event-note e)
                                 #:in-scope-of (economic-event-in-scope-of e)
                                 #:at (economic-event-has-point-in-time e)
                                 #:created (economic-event-created e)
                                 #:begin (economic-event-has-beginning e)
                                 #:end (economic-event-has-end e)))
                  (m   (event-qty e)))
              (if (and m (> (measure-has-numerical-value m) 0))
                  (list out (copy-economic-event e #:corrects #f))
                  (list out)))))))
     events)))

;; ── The ledger as of an instant ──────────────────────────────────────────────
;; A count read from a picture states what was there when the picture was
;; taken, so its difference is from the ledger as it stood then: what stands
;; now, less what every standing event since has done to that stock.

(define* (event-onhand-delta ev rid #:optional resource)
  "What EV did to RID's on-hand figure, signed: its effect as the stock it
   names plus its effect as the stock it moves into. RESOURCE, when given, is
   the stock itself: the quantity is then read in its unit."
  (let* ((defs (custody-defs ev (get-action-def (economic-event-action ev))))
         ;; the quantity is read in the stock's unit only where the event moves stock,
         ;; as the fold applied it: a use measured in hours moves none
         (side (lambda (named effect direction)
                 (if (and (equal? rid named) (quantity-moves? effect direction))
                     (effect-delta effect direction (stock-qty ev resource))
                     0))))
    (+ (side (economic-event-resource-inventoried-as ev) (action-definition-onhand-effect (car defs)) 'from)
       (side (economic-event-to-resource-inventoried-as ev) (action-definition-onhand-effect (cdr defs)) 'to))))

(define (stock-events st rid)
  "The events the log holds that name stock RID, each once."
  (events-named st (delete-duplicates (hashmap-ref (os-idx-by-resource st) rid '()))))

(define (onhand-moved events rid r)
  "What EVENTS did to RID's on-hand figure, summed; R is the stock, whose unit the quantities are read in."
  (fold (lambda (ev acc) (+ acc (event-onhand-delta ev rid r))) 0 events))

(define (onhand-as-of st rid instant)
  "RID's on-hand figure as the ledger stood at INSTANT (event-instant's
   clock), never below nothing; #f for a stock the ledger does not hold. An
   event that states no time is taken to precede INSTANT."
  (let ((r (hashmap-ref (os-resources st) rid #f)))
    (and r
         (let ((since (filter (lambda (ev) (let ((t (event-instant ev))) (and t (> t instant))))
                              (stock-events st rid))))
           (max 0 (- (measure-qty (economic-resource-onhand-quantity r))
                     (onhand-moved since rid r)))))))

;; ── The anchor: a count is the ledger's figure at its instant ────────────────
;; A count's record states what was seen of a stock and when. The latest such
;; sighting is the stock's ANCHOR, and the ledger at any instant after it is the
;; anchor's figure plus every flow that came after the anchor's instant. A flow
;; whose instant is the anchor's or earlier is already in the figure the anchor
;; saw; it stays in the log, closes its commitment and vests its hours, and
;; leaves the stock's on-hand where the count put it. So the ledger is one
;; function of the standing events, whatever order they arrived in, and
;; `phase-follow-count` keeps the stored figure equal to it.

(define (anchor-key rid) (string-append "anchor|" rid))

(define (count-sighting-of ev)
  "The stock a count's record EV (or the back-out of one) is of, else #f: a
   `produce` held nowhere that names a stock by its count-of tag and states the
   figure it found."
  (and (eq? (economic-event-action ev) 'produce)   ; verb-meant: a batch is made, and a count recorded, by a produce
       (not (economic-event-resource-inventoried-as ev))
       (let ((tags (economic-event-resource-classified-as ev)))
         (and (count-figure tags) (count-target #f tags)))))

(define (count-anchor? ev)
  "The stock a count's record EV is of, else #f; a correction is no sighting."
  (and (not (economic-event-corrects ev)) (count-sighting-of ev)))

(define (standing-anchors st rid)
  "The records of the counts of RID that stand and state an instant, the
   latest landing first."
  (let ((evs (events-named st (hashmap-ref (os-idx-by-resource st) (anchor-key rid) '()))))
    (if (null? evs) '()
        (reverse (filter (lambda (e) (and (not (correction? e)) (event-instant e)))
                         (standing-of (reverse evs)))))))

(define (latest-anchor anchors)
  "The record of ANCHORS with the latest instant; of two at one instant the
   one that landed last. #f for none."
  (fold (lambda (e best)
          (if (or (not best) (> (event-instant e) (event-instant best))) e best))
        #f anchors))

(define (containers-of st rid)
  "The stocks RID sits in, nearest first."
  (let loop ((r (hashmap-ref (os-resources st) rid #f)) (acc '()))
    (let* ((up (and r (economic-resource-contained-in r)))
           (u  (and up (not (member up acc)) (hashmap-ref (os-resources st) up #f))))
      (if u (loop u (cons up acc)) (reverse acc)))))

(define (covered-by-container? st rid instant)
  "A count of something RID sits in, of a later instant than INSTANT, speaks
   for RID: its figure follows that container's by the factor the container
   was scaled by, and a count of RID of INSTANT no longer anchors it."
  (any (lambda (cid) (any (lambda (e) (> (event-instant e) instant))
                          (standing-anchors st cid)))
       (containers-of st rid)))

(define (rebase-id? id)
  (and (string? id) (string-contains id %rebase-mark) #t))

(define (anchored-onhand st rid)
  "What RID's on-hand figure is, as a function of the standing events: its
   latest count's figure plus the flows after that count's instant. #f for a
   stock no count anchors, or one a container's later count speaks for. An
   event that states no instant is a flow of the moment it landed, so it
   follows the anchor."
  (let* ((anchors (standing-anchors st rid))
         (a       (latest-anchor anchors))
         (r       (hashmap-ref (os-resources st) rid #f)))
    (and a r
         (not (covered-by-container? st rid (event-instant a)))
         (let* ((t     (event-instant a))
                (fig   (car (count-figure (economic-event-resource-classified-as a))))
                (bases (map (lambda (e) (count-base-id (economic-event-id e))) anchors))
                (evs   (standing-of (reverse (stock-events st rid))))
                ;; of two things at one instant, the one that landed last is the later
                (order (delay (let ((h (make-hash-table)))
                                (let loop ((l (os-events st)) (i 0))
                                  (unless (null? l)
                                    (hash-set! h (economic-event-id (car l)) i)
                                    (loop (cdr l) (+ i 1))))
                                h)))
                (newer? (lambda (ev) (< (hash-ref (force order) (economic-event-id ev) 0)
                                        (hash-ref (force order) (economic-event-id a) 0))))
                (after (filter (lambda (ev)
                                 (and (not (rebase-id? (economic-event-id ev)))
                                      (not (member (economic-event-id ev) bases))
                                      (let ((at (event-instant ev)))
                                        (or (not at) (> at t) (and (= at t) (newer? ev))))))
                               evs)))
           (max 0 (+ fig (onhand-moved after rid r)))))))

(define (ledger-target st rid cur)
  "What RID's on-hand figure should be, given the CUR it stands at: the
   anchored figure when a count anchors it; with every count gone (voided), the
   figure with the adjustments that followed those counts taken back; #f when
   nothing asks the stock to move."
  (cond
    ((pair? (standing-anchors st rid)) (anchored-onhand st rid))
    (else
     (let* ((r    (hashmap-ref (os-resources st) rid #f))
            (undo (onhand-moved (filter (lambda (e) (rebase-id? (economic-event-id e)))
                                        (stock-events st rid))
                                rid r)))
       (and (> (abs undo) %count-tolerance) (max 0 (- cur undo)))))))

(define (make-rebase-event cause rid spec diff unit)
  "The adjustment that brings RID's on-hand figure DIFF further, on CAUSE's
   instant: the consequence of CAUSE, as a cascade event is."
  (make-economic-event
   #:id (string-append (economic-event-id cause) %rebase-mark rid)
   #:action (if (> diff 0) 'raise 'lower) #:resource-inventoried-as rid #:resource-conforms-to spec
   #:resource-quantity (make-measure (abs diff) unit)
   #:has-point-in-time (or (economic-event-has-point-in-time cause) (economic-event-has-end cause))
   #:note "the ledger follows the count"
   #:in-scope-of (economic-event-in-scope-of cause)
   #:previous-event (economic-event-id cause)))

;; --- Validation Gate helpers (pure, read-only on observer state) ---
;;
;; §III.1 anchors on INTENT SATISFACTION, not commitment fulfillment.
;; Reason: a Commitment is a producer-side pledge ("I'll deliver X"),
;; therefore self-authorable by the producer scope. An Intent is a
;; recipient-side declaration of need ("we want X"), so it carries the
;; social validation — the recipient is the one whose need was met.
;; Fulfillment of commitments is read off the events (fulfillment-of) for
;; production-planning purposes, and does NOT gate social labor.
;;
;; Federation stratification: validation is plan-level. An intent
;; inherits its containing plan's validated-at set (see <plan-info>).
;; Credit at level L counts an event iff the satisfied intent's plan
;; has L in its validated-at. Loose intents (not yet in any plan)
;; only count when there is no level filter — uncoordinated work
;; doesn't propagate up the federation.

(define* (validated-effort st event #:optional level)
  "Effort hours of a work event, weighted by satisfied-intent fraction.
   If LEVEL is non-#f, only intents in plans validated-at LEVEL count."
  (let ((q (economic-event-effort-quantity event)))
    (if (not q) 0
        (* (effort-hours q) (event-fraction st event level)))))

(define (commitment-fraction st event level)
  "The fraction for EVENT read off the commitment it fulfils: the least of the
   satisfaction fractions of the registered intents that commitment satisfies (a
   word not fully answered does not vest in full), or #f when it fulfils none."
  (let* ((cid   (economic-event-fulfills event))
         (terms (and cid (hashmap-ref (os-terms st) cid #f)))
         (iids  (if terms
                    (filter (lambda (iid) (hashmap-ref (os-intent-targets st) iid #f)) (caddr terms))
                    '())))
    (and (pair? iids)
         (apply min (map (lambda (iid) (fraction-for-intent st iid level)) iids)))))

(define* (event-fraction st event #:optional level)
  "The Validation Gate fraction for EVENT against observer state ST.
   LEVEL filters by plan-confirmation; #f means no filter.
   Four rails, one per kind of word:
     1. a recipient's intent — their satisfaction governs (satisfies);
     2. the commitment the event fulfils — the satisfaction of the intents
        that commitment stands for governs, so one worker's hours answer
        that worker's word and no one else's;
     3. the process's intents — the aggregate satisfaction governs
        wherever a stated desire reaches the process (process-desired?);
     4. the scope's silence — work no recipient's word reaches vests when
        its window lapses uncontested (window-lapsed?): silence is the
        confirmation, and the contest door (governance contest-work) is
        the interruption — a settled void corrects the event out of the
        standing set, and this reading with it.
   Rail 4 is local: it counts in the unfiltered reading (LEVEL #f) alone,
   the discipline loose intents already follow — silence-vested work
   stays home; the federation counts coordinated work."
  (or (governing-fraction st event level)
      (if (and (not level) (window-lapsed? event)) 1 0)))

(define (governing-fraction st event level)
  "The fraction a recipient's word gives EVENT (rails 1–3 of event-fraction), or #f
   when no word reaches it and only the scope's silence can speak. The one routing
   event-fraction and silence-reached? both read."
  (cond
    ;; Direct: event satisfies an intent declared by a recipient.
    ((economic-event-satisfies event)
     => (lambda (iid) (fraction-for-intent st iid level)))
    ;; Through its own commitment: the intents that commitment satisfies.
    ((commitment-fraction st event level) => values)
    ;; Indirect: aggregate over intents tied to the event's process.
    ((let ((pid (event-process event))) (and pid (process-desired? st pid) pid))
     => (lambda (pid) (fraction-for-process st pid level)))
    (else #f)))

;; ── The lapse window: silence is the confirmation ────────────────────────────
;; Directed work has a confirmer: the recipient takes the bread and their
;; satisfaction is the validation, immediate. Diffuse work — tending the
;; commons, maintenance, care with no single recipient — has the scope
;; itself as the confirmer, and the scope speaks by objecting: the hours
;; stand in the window for %validation-window seconds, any member may
;; contest them there (governance contest-work; the door stays open after,
;; and a late void lowers the reading the same way), and an uncontested
;; lapse vests them in full. Hours in the window read through
;; pending-gross — visible on the certificate before they are drawable.

(define %validation-window
  ;; scope policy, one number: how long the scope's silence takes to
  ;; become its word. Seconds on the one clock.
  (make-parameter (days->seconds 7)))

;; ── One event, one time ───────────────────────────────────────────────────────
;; An event states when it happened as a beginning, an end, a point in time, or only
;; when it was recorded (`created`). Every reader takes that time from here: the
;; interval it was worked, before the moment it was recorded (an event worked on the
;; 21st and logged on the 2nd is of the 21st), a point standing for both ends.
(define (event-stamps ev)
  "(begin-iso . end-iso): the stamps EV states, by one precedence — the beginning,
   else the point, else the end, else `created` for the first; the end, else the
   point, else the beginning, else `created` for the second. #f when it states none."
  (let* ((first-of (lambda (fs) (find (lambda (x) (and (string? x) (not (string-null? x)))) fs)))
         (b (economic-event-has-beginning ev)) (e (economic-event-has-end ev))
         (p (economic-event-has-point-in-time ev)) (c (economic-event-created ev))
         (start (first-of (list b p e c))) (stop (first-of (list e p b c))))
    (and start (cons start stop))))

(define (event-interval ev)
  "(begin . end): the instants EV happened between, on the one clock (a stamp of
   any length the planner writes reads: a date, minutes, seconds). #f when EV
   states no time, or one that does not read."
  (let ((st (event-stamps ev)))
    (and st
         (let ((b (civil->instant (car st))) (e (civil->instant (cdr st))))
           (and b e (cons b e))))))

(define (event-instant ev)
  "The instant EVENT's window opens, one clock: the end of its interval. #f when the
   event states no time — an unopened window never lapses, so undated diffuse work
   waits for a recipient's word."
  (and=> (event-interval ev) cdr))

(define (window-close ev)
  "The instant EV's window closes, #f when it opens none (event-instant #f)
   — the one boundary window-lapsed? and window-pending? read from either
   side of."
  (let ((t (event-instant ev))) (and t (+ t (%validation-window)))))

(define (window-lapsed? ev)
  "EV's window has passed: the scope had its say and stood silent."
  (let ((wc (window-close ev))) (and wc (>= (now) wc))))

;; process-desired? is called once per work event from event-fraction, in
;; every ledger fold (pending-gross, hours-by, validated-effort) — each call
;; rescanning every satisfaction-state and its satisfying events was
;; O(intents × events-per-intent) PER PID, over a whole ledger read that's
;; already O(events). %desired-pids-cache keys by ST'S IDENTITY (hashq, on a
;; weak-key table): ST is one immutable snapshot held constant across a
;; fold's many calls, so this is the same "cache keyed by identity,
;; invalidated automatically when identity changes" shape as engine.scm's
;; template-index — except st is per-observer rather than a single global,
;; so a true cache (not one mutable slot) is needed to avoid cross-observer
;; thrash; the weak key lets a retired snapshot's entry collect once nothing
;; else references it.
(define %desired-pids-cache (make-weak-key-hash-table))
(define (desired-pids-of st)
  "Every process id some satisfaction-state's satisfying events reach, for ST."
  (or (hashq-ref %desired-pids-cache st #f)
      (let ((h (make-hash-table)))
        (for-each
         (lambda (ss)
           (when (> (measure-qty (satisfaction-state-total-desired ss)) 0)
             (for-each
              (lambda (eid)
                (let ((e (event-ref st eid)))
                  (when e
                    (let ((o (economic-event-output-of e)) (i (economic-event-input-of e)))
                      (when o (hash-set! h o #t))
                      (when i (hash-set! h i #t))))))
              (satisfaction-state-satisfying-events ss))))
         (satisfactions-of st))
        (hashq-set! %desired-pids-cache st h)
        h)))

(define (process-desired? st pid)
  "A recipient's word reaches PID: a satisfaction-state with stated desire
   links to it through a satisfying event. Wherever this holds the
   process rail governs and the window rail steps back."
  (and (hash-ref (desired-pids-of st) pid #f) #t))

(define (silence-reached? st ev)
  "No recipient's word reaches EV — the exact condition under which
   event-fraction falls through to its silence rail (governing-fraction answers
   #f). window-pending? reads this alongside the window's own clock."
  (not (governing-fraction st ev #f)))

(define (window-pending? st ev)
  "Standing work inside its open window, with no recipient's word to wait
   on: the hours the lapse will vest, and a contest void."
  (and (silence-reached? st ev)
       (let ((wc (window-close ev))) (and wc (< (now) wc)))))

(define (pending-gross st aid)
  "Hours in the window for AID (no AID: scope-wide): Σ effort over the
   standing work events window-pending? holds of. The certificate shows
   them beside the drawable hours; the fold counts them at the lapse."
  (fold (lambda (ev acc)
          (if (and (or (not aid) (equal? (economic-event-provider ev) aid))
                   (economic-event-effort-quantity ev)
                   (window-pending? st ev))
              (+ acc (effort-hours (economic-event-effort-quantity ev)))
              acc))
        0 (standing-events st 'work)))

(define (intent-counts-at? st iid level)
  "True iff the intent at IID counts toward voice/credit at federation
   LEVEL. #f level → no filter (universal baseline).
   Otherwise the universality measure is the union of two rails:
     1. plan-rail   — IID's plan (if any) is recognized by LEVEL.
     2. intent-rail — IID itself is recognized by LEVEL directly.
   Either suffices; loose intents (no plan) take rail 2."
  (or (not level)
      (let* ((stated  (hashmap-ref (os-intent-targets st) iid #f))      ; the plan it names is what was registered
             (plan-id (and stated (cdr stated))))
        (or (recognized-at? (os-plan-validations st)   plan-id level)
            (recognized-at? (os-intent-validations st) iid     level)))))

(define (recognized-at? validations target-id level)
  "Both rails of intent-counts-at? share this lookup shape: a
   target-id (plan-id or intent-id) maps to a list of scope-ids that
   recognize it. LEVEL is recognized when it's a member."
  (and target-id
       (let ((vs (hashmap-ref validations target-id #f)))
         (and vs (member level vs) #t))))

(define (ss-fraction ss)
  "Satisfied fraction of a satisfaction-state, capped at 1.
   Zero when desired is 0 (ungated or registration-only)."
  (let ((des (measure-qty (satisfaction-state-total-desired ss)))
        (sat (measure-qty (satisfaction-state-total-satisfied ss))))
    (if (= 0 des) 0 (min 1 (/ sat des)))))

(define* (fraction-for-intent st iid #:optional level)
  (let ((ss (satisfaction-of st iid)))
    (if (and ss (intent-counts-at? st iid level)) (ss-fraction ss) 0)))

;; Pure ledger helpers — same fold each method body would have inlined.

(define (events-with-action st action)
  (events-named st (hashmap-ref (os-idx-by-action st) action '())))

;; ── ONE fold of validated hours, the key an argument ─────────────────────────
;; Every reading of "how many validated hours" is this fold with a different
;; key: the credit ledger keys by provider, the skills view by (provider, skill),
;; producer voice by the PART an hour falls in (its terms). KEY-OF maps an event
;; to a key, or to #f for "not folded". Same standing events, same gate, so no
;; two readings can diverge and a corrected work event leaves every total at
;; once (docs/planning/voice/voice-follows-work.md, order of work step 1).
(define (fold-by st actions key-of value-of combine)
  "((key . value) …) over the standing events of ACTIONS (one action or a
   list), in first-seen key order: VALUE-OF : event → value, KEY-OF : event →
   key | #f (#f = not folded), COMBINE : value value → value joins a key's
   later values onto its first. THE fold of the observer: every reading of
   its events is this with a key, a value and a combine — hours by part sum
   validated effort (`hours-by`), readings of a spec by technique keep count,
   sum, extrema and the freshest value (pools/reading-fold.scm). One
   gate (`standing-events`), so no two readings can diverge and a corrected
   event leaves every keyed total at once."
  (let ((h (make-hash-table)) (order '()))
    (for-each (lambda (action)
                (for-each (lambda (ev)
                            (let ((k (key-of ev)))
                              (when k
                                (let ((cur (hash-ref h k #f)))
                                  (if cur
                                      (hash-set! h k (cons #t (combine (cdr cur) (value-of ev))))
                                      (begin (set! order (cons k order))
                                             (hash-set! h k (cons #t (value-of ev)))))))))
                          (standing-events st action)))
              (if (list? actions) actions (list actions)))
    (map (lambda (k) (cons k (cdr (hash-ref h k)))) (reverse order))))

(define* (hours-by st key-of #:optional level)
  "((key . validated-hours) …) over the standing work events, KEY-OF : event →
   key | #f. LEVEL, when given, counts only events whose intent is cosigned at
   that federation level (the gate `validated-effort` applies)."
  (fold-by st 'work key-of (lambda (ev) (validated-effort st ev level)) +))

(define (event-terms ev)
  "The TERMS a work event stands in, in the grammar parts.scm matches against
   (engine `column-terms` reads a column into the same alist): its process,
   place, skill, the instant it was worked (its beginning, else the moment it
   is dated) as a window of zero length, and its scope."
  (let ((t (and=> (event-stamps ev) car))
        (scope (economic-event-in-scope-of ev)))
    (append
     (let ((p (economic-event-input-of ev))) (if p (list (cons 'process p)) '()))
     (let ((p (economic-event-at-location ev))) (if p (list (cons 'place p)) '()))
     (let ((s (economic-event-resource-conforms-to ev))) (if s (list (cons 'skill s)) '()))
     (if (string? t) (list (cons 'window (cons t t))) '())
     (cond ((pair? scope) (list (cons 'scope scope)))
           ((string? scope) (list (cons 'scope (list scope))))
           (else '())))))

(define* (hours-on st part #:key (owner #f) (level #f) (terms-of event-terms))
  "THE reader of producer voice: the validated hours on PART — Σ over the
   standing work events whose TERMS-OF the part covers (parts.scm `covers?`),
   OWNER's alone when one is named, at federation LEVEL when one is given.
   `hours-by` keyed by the one constant. The widest part (`make-part`, nothing
   stated) is this scope's own fold, so a scope's producer voice is
   (hours-on scope owner) / (hours-on scope): the scope is the standing part,
   and every part narrower than it reads through the same sum."
  (let ((r (hours-by st (lambda (ev)
                          (and (or (not owner) (equal? (economic-event-provider ev) owner))
                               (covers? part (terms-of ev))
                               'on))
                     level)))
    (if (null? r) 0 (cdar r))))

(define* (ledger-gross st aid #:optional level)
  "Validated work hours for AID (no AID: scope-wide) at LEVEL: `hours-on` the
   widest part, the scope itself."
  (hours-on st (make-part) #:owner aid #:level level))

(define (ledger-claimed st aid)
  "Sum of effort-hours on individually-claimable transfers received by AID."
  (fold (lambda (ev acc)
          (if (and (equal? (economic-event-receiver ev) aid)
                   (eq? (event-distribution-mode ev) 'individual-claimable)
                   (economic-event-effort-quantity ev))
              (+ acc (effort-hours (economic-event-effort-quantity ev)))
              acc))
        0 (standing-events st 'transfer)))

;; ── Skills as a DERIVED view over the work-event log ─────────────────────────
;; No stored skill state: a person's skills are the distinct resource-conforms-to
;; of their work events, and their hours in a skill is the validated-effort fold
;; over those events — the SAME gate the credit ledger (ledger-gross) uses, over
;; the same STANDING events, so the two can never diverge and a corrected work
;; drops from both at once.

(define (skill-hours-of st aid)
  "AID's per-skill ledger: ((skill . validated-hours) …) over the work log — the
   single fold both earned-skills (its keys) and practiced-hours (a lookup) derive
   from. Validated by the SAME gate as ledger-gross, so it can't diverge; '100h a
   surgeon' is an entry here, never a stored field."
  ;; work that names no skill is labour all the same — it stands in the credit
  ;; ledger and in no skill's hours: the key is #f there, and #f is "not folded"
  (hours-by st (lambda (ev) (and (equal? (economic-event-provider ev) aid)
                                 (economic-event-resource-conforms-to ev)))))

(define (work-practice st aid)
  "AID's practice at this observer as rows (event-id skill instant hours): the
   standing work events they provided that name a skill, each with the hours
   this observer validates. The join across scopes reads these
   (planner/observation/practice.scm); skill-hours-of is their sum per skill."
  (filter-map (lambda (ev)
                (and (equal? (economic-event-provider ev) aid)
                     (economic-event-resource-conforms-to ev)
                     (list (economic-event-id ev) (economic-event-resource-conforms-to ev)
                           (and=> (event-interval ev) cdr) (validated-effort st ev))))
              (standing-events st 'work)))

(define (earned-skills st aid)         (map car (skill-hours-of st aid)))
(define (practiced-hours st aid skill)
  (cond ((assoc skill (skill-hours-of st aid)) => cdr) (else 0)))

;; ── Arc observations: performed trips as a DERIVED view ─────────────────────
;; Same discipline as skills: no stored state. A trip is a pickup→dropoff pair
;; sharing a process; its duration (has-beginning → has-end) is what relocation
;; a→b ACTUALLY took — the measurement the arc-time table folds (EWMA, in
;; solve/routing.scm) against the routing engine's prior, so the planner's transport
;; coefficients learn from the federation's own events. The observer reports
;; the raw fact — (from to process hours begin), chronological, the process being
;; the trip's own (a <process> the books hold, based on its mode's specification).
;; Resolving the process to a routing manner is policy vocabulary and happens at the
;; live boundary.

(define (event-process ev)
  (or (economic-event-input-of ev) (economic-event-output-of ev)))

(define (arc-observations st)
  "Performed trips, oldest first: ((from to process hours begin) …) — the raw trip,
   with no vocabulary: the process is the trip's own, and the live boundary reads its
   manner off the mode recipe the process is based on (live.scm trip-manner-of).
   Pickups and dropoffs join on their shared process,
   zipped CHRONOLOGICALLY within it (k-th pickup ↔ k-th dropoff), so a ride
   performed many times yields many trips, not one first-to-last smear. Both
   locations and both timestamps must be present, and the duration positive,
   for a trip to count. A trip states its own beginning (the pickup's
   `hasBeginning`) and its own end (the dropoff's `hasEnd`): a pickup or a dropoff
   stamped at a point in time says when the books were told, so it measures no
   duration, and the cargo a plan carries is confirmed that way."
  (define (stamped events stamp-of)          ; ((epoch . event) …), oldest first
    (sort (filter-map (lambda (e) (and=> (stamp-of e) (lambda (t) (cons t e))))
                      events)
          (lambda (a b) (< (car a) (car b)))))
  (define (by-process events)                ; process → events (insertion order)
    (let ((h (make-hash-table)))
      (for-each (lambda (e) (let ((p (event-process e)))
                              (when p (hash-set! h p (cons e (hash-ref h p '()))))))
                events)
      h))
  (let ((pus (by-process (events-with-action st 'pickup)))
        (drs (by-process (events-with-action st 'dropoff))))
    (map cdr                                               ; strip the sort key
     (sort
      (append-map
       (lambda (kv)
         (define proc (car kv))
         (let zip ((p* (stamped (cdr kv)
                                (lambda (e) (and (economic-event-has-beginning e)
                                                 (and=> (event-interval e) car)))))
                   (d* (stamped (hash-ref drs proc '())
                                (lambda (e) (and (economic-event-has-end e)
                                                 (and=> (event-interval e) cdr)))))
                   (acc '()))
           (if (or (null? p*) (null? d*)) (reverse acc)
               (let* ((beg (caar p*)) (pu (cdar p*))
                      (end (caar d*)) (dr (cdar d*))
                      (from (economic-event-at-location pu))
                      (to   (or (economic-event-to-location dr)
                                (economic-event-at-location dr))))
                 (zip (cdr p*) (cdr d*)
                      (if (and from to (> end beg))
                          ;; beg rides as a 5th element so the live boundary can
                          ;; period-class the trip; ewma-fold reads only 1–4.
                          (cons (cons beg (list from to proc
                                                (/ (- end beg) 3600.0) beg))
                                acc)
                          acc))))))
       (hash-map->list cons pus))
      (lambda (a b) (< (car a) (car b)))))))               ; chronological for the EWMA

(define* (fraction-for-process st pid #:optional level)
  "Aggregate fraction across all satisfaction-states whose satisfying
   events are tied to PID, restricted to intents whose plan is
   confirmed at LEVEL (no restriction when LEVEL is #f)."
  (let loop ((ss-list (satisfactions-of st)) (des 0) (sat 0))
    (if (null? ss-list)
        (if (= 0 des) 0 (min 1 (/ sat des)))
        (let* ((ss (car ss-list))
               (iid (satisfaction-state-intent-id ss))
               (linked?
                 (and (intent-counts-at? st iid level)
                      (any (lambda (eid)
                             (let ((e (event-ref st eid)))
                               (and e (or (equal? (economic-event-output-of e) pid)
                                          (equal? (economic-event-input-of e) pid)))))
                           (satisfaction-state-satisfying-events ss)))))
          (if linked?
              (loop (cdr ss-list)
                    (+ des (measure-qty (satisfaction-state-total-desired ss)))
                    (+ sat (measure-qty (satisfaction-state-total-satisfied ss))))
              (loop (cdr ss-list) des sat))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Action definition lookup
;; ═════════════════════════════════════════════════════════════════════════




;; Phase 5: the ledger follows the latest count
(define (cascaded-stocks st event)
  "The stocks EVENT's containment cascade reached: the cascade events hang
   from EVENT's id and sit at the head of the log, newest first."
  (let ((prefix (string-append (economic-event-id event) %cascade-mark)))
    (let loop ((evs (os-events st)) (acc '()))
      (if (or (null? evs) (not (string-prefix? prefix (economic-event-id (car evs)))))
          acc
          (loop (cdr evs)
                (cons (economic-event-resource-inventoried-as (car evs)) acc))))))

(define (phase-follow-count st event)
  "(values ST* affected): ST with each stock EVENT bears on brought to what its
   latest count says (ledger-target), by an adjustment that follows EVENT. A
   stock no count has touched is left as the effects put it."
  (let loop ((rids (delete-duplicates
                    (filter (lambda (rid)                       ; only a stock a count has touched
                              (pair? (hashmap-ref (os-idx-by-resource st) (anchor-key rid) '())))
                            (filter string?
                                    (append (list (economic-event-resource-inventoried-as event)
                                                  (economic-event-to-resource-inventoried-as event)
                                                  (count-sighting-of event))
                                            (cascaded-stocks st event))))))
             (st st) (affected '()))
    (if (null? rids) (values st affected)
        (let* ((rid  (car rids))
               (r    (hashmap-ref (os-resources st) rid #f))
               (onh  (and r (economic-resource-onhand-quantity r)))
               (cur  (and onh (measure-has-numerical-value onh)))
               (tgt  (and cur (ledger-target st rid cur)))
               (diff (and tgt (- tgt cur))))
          (if (and diff (> (abs diff) %count-tolerance))
              (let-values (((st2 aff)
                            (observer-record-event
                             st (make-rebase-event event rid (economic-resource-conforms-to r)
                                                   diff (or (measure-has-unit onh) %count-unit)))))
                (loop (cdr rids) st2 (append affected aff)))
              (loop (cdr rids) st affected))))))

;; ═════════════════════════════════════════════════════════════════════════
;; THE FOLD KERNEL: observer-record-event
;; ═════════════════════════════════════════════════════════════════════════

(define (fold-new-event st event)
  "The fold kernel for an event the log does not hold yet:
   (state, event) -> (values state affected-resources).

   Pipeline:
     0. validate mutual exclusivity constraints; a correction is an ordinary
        event of the action of the event it corrects
     1. append event to log
     2. index into lookup maps
     3. apply VF resource effects (from + to)
     4. apply implied transfer
   Fulfilment, satisfaction and settlement are readings of the log's links
   (fulfillment-of, satisfaction-of, claim-state-of); the fold keeps none."
  ;; VF rule: event cannot both fulfill a Commitment AND satisfy an Intent
  (when (and (economic-event-fulfills event) (economic-event-satisfies event))
    (error "Event cannot both fulfill and satisfy"))
  ;; VF pairs-with constraint: if action pairs with another (e.g., accept↔modify,
  ;; pickup↔dropoff), enforce that both reference the same resource-id.
  ;; This is a relational constraint, not a warning — mismatch = error = vat rollback.
  (let* ((def (get-action-def (economic-event-action event)))
         (paired-action (action-definition-pairs-with def))
         (from-id (economic-event-resource-inventoried-as event))
         (process-id (or (economic-event-input-of event)
                         (economic-event-output-of event))))
    (when (and paired-action from-id process-id)
      ;; Find the paired event in the SAME process
      (let ((process-events (hashmap-ref (os-idx-by-process st) process-id '())))
        ;; The pair names one thing travelling a chain: a dropoff's resource is the
        ;; resource its pickup named, or the carrier's resource (T) the pickup's
        ;; custody transfer created (ex-complex.md, Transportation with transfer). A
        ;; process may hold several pickups and dropoffs (several cargoes), so an
        ;; event is out of line only when NONE of the paired actions in its process
        ;; names a resource it is chained to.
        (let* ((paired (filter-map
                        (lambda (eid)
                          (let ((ev (event-ref st eid)))
                            (and ev (eq? (economic-event-action ev) paired-action) ev)))
                        process-events))
               (chained? (lambda (ev)
                           (let ((r  (economic-event-resource-inventoried-as ev))
                                 (t  (economic-event-to-resource-inventoried-as ev))
                                 (et (economic-event-to-resource-inventoried-as event)))
                             (or (not r)
                                 (equal? from-id r) (and t (equal? from-id t))
                                 ;; the pickup side: a pickup may continue from where a paired
                                 ;; dropoff left the goods
                                 (and et (or (equal? et r) (and t (equal? et t)))))))))
          (when (and (pair? paired) (not (any chained? paired)))
            (error (format #f
              "VF pairs-with violation: ~a references ~a but no paired ~a in process ~a names it"
              (economic-event-action event) from-id paired-action process-id)))))))
  (let* ((def (get-action-def (economic-event-action event)))
         ;; Phase 0: a correction is an ordinary event of its original's action
         (_   (check-correction-action! st event))
         ;; Phases 1-2: bare state
         (st  (phase-append-event st event))
         (st  (phase-index-event  st event))
         ;; Phases 3-4: fold-ctx (state + affected accumulator)
         (ctx (make-fold-ctx st '()))
         (ctx (phase-apply-effects    ctx event def))
         (ctx (phase-containment-cascade ctx event def))
         (ctx (phase-location-cascade ctx event def st))
         (ctx (phase-breadcrumb-chain ctx event))
         (ctx (phase-implied-transfer ctx event def))
         (st  (ctx-state ctx)))
    ;; the ledger follows the latest count
    (let-values (((st more) (phase-follow-count st event)))
      (values st (append (reverse (ctx-affected ctx)) more)))))

;; ── The door of the fold: an id names one event; a quantity is a number ──────
;; The log is a set keyed by event id. An event delivered twice (a re-delivered
;; message, a replayed log, a plan enacted twice) is one event and the second
;; delivery changes nothing; a different event under a used id is a conflict the
;; fold refuses, since events are immutable records. `created` states when a
;; record was made, so a second delivery of the same event may carry a later one.
(define (event-content e)
  (remove (lambda (f) (and (pair? f) (eq? (car f) 'created)))
          (economic-event->list e)))

(define (check-correction-action! st event)
  "A correction carries the action of the event it corrects (accounting.md)."
  (let ((original (and (economic-event-corrects event)
                       (event-ref st (economic-event-corrects event)))))
    (when (and original (not (eq? (economic-event-action original) (economic-event-action event))))
      (error "a correction carries the action of the event it corrects"
             (economic-event-action event) (economic-event-action original)))))

(define (effort-hours m)
  "The effort quantity M as a number of hours: the unit it states is the unit it is
   counted in, and credit counts time in one."
  (hours-in (measure-qty m) (measure-has-unit m)))

(define (check-event-quantities! event)
  "A quantity is a finite number; it is negative only on an event that corrects
   another (VF accounting.md: the only time negative quantities can be used). An
   effort quantity is a duration, so it is stated in a unit of time."
  (let ((e (economic-event-effort-quantity event)))
    (when (and e (not (or (placeholder-unit? (measure-has-unit e)) (time-unit? (measure-has-unit e)))))
      (error "effort is stated in a unit of time" (economic-event-id event) (measure-has-unit e))))
  (for-each
   (lambda (m)
     (when m
       (let ((v (measure-has-numerical-value m)))
         (unless (and (real? v) (finite? v))
           (error "an event quantity is a finite number" (economic-event-id event) v))
         (when (and (< v 0) (not (economic-event-corrects event)))
           (error "a negative quantity belongs to an event that corrects another"
                  (economic-event-id event) v)))))
   (list (economic-event-resource-quantity event)
         (economic-event-effort-quantity event))))

(define (observer-record-event st event)
  "(state, event) -> (values state affected-resources), idempotent by event id."
  (let* ((eid   (economic-event-id event))
         (prior (and eid (event-ref st eid))))
    (cond
      (prior
       (if (equal? (event-content prior) (event-content event))
           (values st '())
           (error "this event id already holds a different event" eid)))
      (else
       (check-event-quantities! event)
       (fold-new-event st event)))))


;; ═════════════════════════════════════════════════════════════════════════
;; Process completion detection (standalone — called after record-event)
;; ═════════════════════════════════════════════════════════════════════════

(define (check-process-completion st event process-registry)
  "Check if a process is complete after an event is recorded.
   A process is complete when every output commitment linked to it
   has been fully fulfilled. Called when event has outputOf set.
   process-registry: actor ref with 'mark-finished method."
  (let ((process-id (economic-event-output-of event)))
    (when (and process-id process-registry)
      ;; Find all fulfillment states whose fulfilling events are outputs of this process
      (let* ((all-fs (fulfillments-of st))
             (output-fs
               (filter (lambda (fs)
                         (any (lambda (eid)
                                (let ((e (event-ref st eid)))
                                  (and e (equal? (economic-event-output-of e) process-id))))
                              (fulfillment-state-fulfilling-events fs)))
                       all-fs)))
        (when (and (pair? output-fs)
                   (every fulfillment-state-finished output-fs))
          ($ process-registry 'mark-finished process-id))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Record <-> list serialization for persistence
;; ═════════════════════════════════════════════════════════════════════════
;;
;; Routed through the generic introspective walker in
;; `lib/utils/serdes.scm`. Each record type is registered once in
;; `define-vf-record` (vf/schemas.scm). Adding a field to <economic-event>
;; or <economic-resource> requires no change here — vf-serialize reads
;; the fields off the record-type-descriptor at registration time.

(define (economic-event->list e) (vf-serialize e))
(define (list->economic-event lst) (vf-deserialize lst))

(define (economic-resource->list r) (vf-serialize r))
(define (list->economic-resource lst) (vf-deserialize lst))

;; ── The snapshot ─────────────────────────────────────────────────────────────
;; A snapshot holds what the books were TOLD, each under its name: the log, the
;; resources, what was registered and recognized. What is read off those (the lists
;; of events by resource, process, agent, action, id and link, and the satisfiers) is
;; built again as it loads, by the same step that built it as the events came in
;; (phase-index-event), so no index can stand apart from the log it indexes.
;; The resources by specification are kept: the order of each list is the order the
;; resources came to be, which the resources alone do not say.

(define %snapshot-tag 'observer-snapshot)

(define (hashmap-of write) (lambda (hm) (serialize-hashmap hm write)))
(define (hashmap-from read) (lambda (hm) (deserialize-hashmap hm read)))

;; (name accessor write read): what a snapshot holds, in the order it is written.
(define %stated
  (list
   (list 'events os-events
         (lambda (es) (map economic-event->list es)) (lambda (es) (map list->economic-event es)))
   (list 'resources os-resources (hashmap-of economic-resource->list) (hashmap-from list->economic-resource))
   (list 'commitment-targets os-commitment-targets (hashmap-of vf-serialize) (hashmap-from vf-deserialize))
   (list 'intent-targets os-intent-targets
         (hashmap-of (lambda (stated) (list (vf-serialize (car stated)) (cdr stated))))
         (hashmap-from (lambda (v) (cons (vf-deserialize (car v)) (cadr v)))))
   (list 'claim-targets os-claim-targets (hashmap-of vf-serialize) (hashmap-from vf-deserialize))
   (list 'terms os-terms identity identity)                              ;; cid -> (action spec intents)
   (list 'idx-by-spec os-idx-by-spec identity identity)
   (list 'agreements os-agreements identity identity)                    ;; alists
   (list 'batches os-batches (hashmap-of vf-serialize) (hashmap-from vf-deserialize))
   (list 'resource-batches os-resource-batches identity identity)        ;; lists of batch ids
   (list 'plan-validations os-plan-validations identity identity)        ;; lists of scope ids
   (list 'intent-validations os-intent-validations identity identity)
   (list 'processes os-processes (hashmap-of vf-serialize) (hashmap-from vf-deserialize))))

(define (serialize-observer-state st)
  (cons %snapshot-tag
        (map (lambda (s) (list (car s) ((caddr s) ((cadr s) st)))) %stated)))

(define (state-of-stated stated)
  "The observer state that was told STATED: an alist of field name -> value, the
   events newest first. Every index is built from them."
  (let* ((events (or (assq-ref stated 'events) '()))
         (told   (fold (lambda (kv st)
                         (if (eq? (car kv) 'events) st
                             (apply os-rebuild st (list (symbol->keyword (car kv)) (cdr kv)))))
                       (empty-observer-state) stated)))
    (rebuild-satisfiers
     (fold (lambda (e s) (phase-index-event (phase-append-event s e) e))
           told (reverse events)))))

;; ── Snapshots in the earlier, positional form ────────────────────────────────
;; Before a snapshot named its parts it was a list by position: events, resources, a
;; state record per commitment, intent and claim, five stored indexes of the events,
;; the resources by specification, then slots added one at a time (agreements,
;; batches, resource batches, plan and intent validations, join terms, processes); an
;; older snapshot lacks the later ones. Three readings are specific to it:
;;   - a state record's target is read out of it and its counts are left, since the
;;     events say them; from an intent's record, the commitments it named too;
;;   - a snapshot that lacks the join terms holds corrections in the form where one
;;     REPLACES the event it names; its events are read afresh, once, as signed
;;     events (legacy-corrections->canonical), its resources already holding their net;
;;   - a process stored as its specification id alone is a process based on it.

(define (stored-target v state-target)
  "The target snapshot entry V holds; STATE-TARGET reads it out of a state record."
  (let ((x (vf-deserialize v)))
    (if (measure? x) x (state-target x))))

(define (legacy-intent-entry? v) (not (and (pair? v) (pair? (car v)))))
(define (list->intent-target v)
  (if (legacy-intent-entry? v)
      (let ((ss (vf-deserialize v)))
        (cons (satisfaction-state-total-desired ss) (satisfaction-state-plan-id ss)))
      (cons (vf-deserialize (car v)) (cadr v))))

(define (legacy-satisfiers sintents)
  "intent id -> the commitment ids its state record names, for the entries that are
   state records."
  (hashmap-fold (lambda (iid v acc)
                  (if (legacy-intent-entry? v)
                      (hashmap-set acc iid (satisfaction-state-satisfying-commitments (vf-deserialize v)))
                      acc))
                (hashmap) sintents))

(define (deserialize-processes procs)
  (hashmap-fold (lambda (pid v acc)
                  (hashmap-set acc pid (if (string? v)
                                           (make-process #:id pid #:name pid #:based-on v)
                                           (vf-deserialize v))))
                (hashmap) procs))

(define (positional->stated data)
  "What a snapshot in the positional form says it was told, as state-of-stated reads it."
  (match data
    ((sevents sresources scommitments sintents sclaims _ _ _ _ _ sibs . rest)
     (let* ((slot   (lambda (n) (and (> (length rest) n) (list-ref rest n))))
            (events (map list->economic-event sevents))
            (terms  (slot 5)))
       `((events . ,(if terms events (reverse (legacy-corrections->canonical (reverse events)))))
         (resources . ,(deserialize-hashmap sresources list->economic-resource))
         (commitment-targets . ,(deserialize-hashmap scommitments (lambda (v) (stored-target v fulfillment-state-total-committed))))
         (intent-targets . ,(deserialize-hashmap sintents list->intent-target))
         (claim-targets . ,(deserialize-hashmap sclaims (lambda (v) (stored-target v claim-state-total-claimed))))
         (satisfiers . ,(legacy-satisfiers sintents))
         (idx-by-spec . ,sibs)
         (agreements . ,(or (slot 0) (hashmap)))
         (batches . ,(let ((b (slot 1))) (if b (deserialize-hashmap b vf-deserialize) (hashmap))))
         (resource-batches . ,(or (slot 2) (hashmap)))
         (plan-validations . ,(or (slot 3) (hashmap)))
         (intent-validations . ,(or (slot 4) (hashmap)))
         (terms . ,(or terms (hashmap)))
         (processes . ,(deserialize-processes (or (slot 6) (hashmap)))))))))

(define (deserialize-observer-state data)
  "The observer state snapshot DATA holds, in today's named form or the positional one."
  (state-of-stated
   (if (and (pair? data) (eq? (car data) %snapshot-tag))
       (filter-map (lambda (entry)
                     (let ((s (assq (car entry) %stated)))      ; a name this build does not know is passed over
                       (and s (cons (car entry) ((cadddr s) (cadr entry))))))
                   (cdr data))
       (positional->stated data))))

;; ── Write-safe (portable) form of the snapshot ──────────────────────────────
;; `serialize-observer-state` produces the syrup portrait — a tree riddled with
;; hashmaps (serialize-hashmap keeps values keyed in a hashmap). Goblins syrup
;; serializes hashmaps; `write`/`read` do not. Since the serializer already
;; turns every RECORD into a list, the ONLY non-write-safe elements are the
;; hashmaps — so one generic deep converter (hashmap ⇄ tagged alist) makes the
;; whole blob round-trip through write/read, with the serializer left untouched.
;; The event-log checkpoint (gap #18) stores this portable form on disk.
(define %hm-tag '%playnet-hashmap)
(define (state->portable x)
  (cond
    ((hashmap? x)
     (cons %hm-tag (hashmap-fold
                    (lambda (k v acc) (cons (cons (state->portable k) (state->portable v)) acc))
                    '() x)))
    ((pair? x) (cons (state->portable (car x)) (state->portable (cdr x))))
    (else x)))
(define (portable->state x)
  (cond
    ((and (pair? x) (eq? (car x) %hm-tag))
     (fold (lambda (kv acc) (hashmap-set acc (portable->state (car kv)) (portable->state (cdr kv))))
           (hashmap) (cdr x)))
    ((pair? x) (cons (portable->state (car x)) (portable->state (cdr x))))
    (else x)))
(define (serialize-observer-state-portable st)
  (state->portable (serialize-observer-state st)))
(define (deserialize-observer-state-portable data)
  (deserialize-observer-state (portable->state data)))


;; ═════════════════════════════════════════════════════════════════════════
;; ^observer — persistent Goblins actor
;; ═════════════════════════════════════════════════════════════════════════

(define-actor (^observer bcom st callbacks)
  ;; callbacks: alist of (KEY . PROC). Known keys:
  ;;   on-event: (proc event affected-resources standing) — fired after
  ;;             record-event has folded the new state; gateway uses
  ;;             this to emit work-event ACDCs. STANDING, for a correction,
  ;;             is the event it corrects as it now stands (net quantity),
  ;;             or #f when that is backed out; #f for any other event.
  ;; Planner stays oblivious to credential schemas.

  #:portrait
  (lambda () (list (serialize-observer-state st)))

  ;; version 3: the snapshot names its parts and holds what was told; 1 and 2 are the
  ;; positional form, with state records (1) or targets (2) per registration. One
  ;; reader takes all three (deserialize-observer-state).
  #:version 3

  #:restore
  (lambda (version data)
    (case version
      ((1 2 3) (spawn ^observer (deserialize-observer-state data) '()))
      (else (error "Unknown ^observer version" version))))

  ;; Shadow callback slots as ordinary names so method bodies read
  ;; naturally. Re-evaluated each respawn.
  (let ((on-event  (assq-ref callbacks 'on-event))
        (log-sink  (assq-ref callbacks 'log-sink))
        ;; the ADDITIVE listeners — every fold that reads this scope's
        ;; events (means capacity, credit) hears each one, beside whatever
        ;; the single on-event slot carries. Same door the plan-store gives
        ;; its intent listeners; not serialized, re-added after restore.
        (listeners (or (assq-ref callbacks 'listeners) '())))

  ;; The one way an event enters: fold it, then tell everyone who listens —
  ;; the on-event slot (the credential bridge), the additive listeners, and the
  ;; portable log. A correction enters here too, so it becomes a record like
  ;; any other and a replay of the log reproduces the totals.
  ;; portable event log (gap #18): mirror a record — an event, or a resource the
  ;; books were told of — into the self-certifying stream. A logging failure must
  ;; never hold the canonical economic state hostage, so it is caught and dropped.
  (define (log! record)
    (when log-sink
      (catch* #t (lambda () (log-sink record))
        (lambda args
          (format (current-error-port) "event-log sink error: ~a~%" args)))))

  (define (record! event)
    (call-with-values
      (lambda () (observer-record-event st event))
      (lambda (new-st affected)
        (when on-event
          (on-event event affected
                    (and (correction? event) (standing-event new-st (economic-event-corrects event)))))
        (for-each (lambda (l)
                    (catch* #t (lambda () (l event affected))
                      (lambda args
                        (format (current-error-port)
                                "event listener error: ~a~%" args))))
                  listeners)
        (log! event)
        (bcom (^observer bcom new-st callbacks) affected))))

  (methods

    ;; --- Core: the fold step ---

    ((record-event event) (record! event))

    ;; Late-bind any emission callback (post-recovery). Prepends so
    ;; new bindings shadow older ones.
    ((set-callback key proc)
     (bcom (^observer bcom st (cons (cons key proc) callbacks))))

    ;; Back-compat wrapper.
    ((set-on-event proc)
     (bcom (^observer bcom st (cons (cons 'on-event proc) callbacks))))

    ;; additive: a listener joins, nothing it was beside is displaced
    ((add-event-listener proc)
     (bcom (^observer bcom st
                      (cons (cons 'listeners (cons proc listeners))
                            callbacks))))

    ;; --- Portable state snapshot (event-log compaction, gap #18) ---
    ;; `serialize` hands out the same blob the syrup portrait uses — the
    ;; event-log checkpoint carries it so the pruned prefix stays recoverable.
    ;; `load-snapshot` restores that blob in place (used on cross-gateway
    ;; restore, before folding the post-checkpoint tail).
    ((serialize) (serialize-observer-state-portable st))
    ((load-snapshot data)
     (bcom (^observer bcom (deserialize-observer-state-portable data) callbacks)))

    ;; --- Registration: what is stated, held as stated ---

    ;; The books hold PROCESS, with no entry in the portable log: registered before the
    ;; events that are its outputs, so their stage effect can name its specification.
    ((register-process process)
     (bcom (^observer bcom (with-process st process) callbacks)))

    ;; The books are told of PROCESS (a performed trip, a ride the plan asked for): held,
    ;; and written to the portable log as a resource record is. A record held unchanged
    ;; writes nothing.
    ((record-process process)
     (let ((held (and (process-id process) (hashmap-ref (os-processes st) (process-id process) #f))))
       (if (and held (equal? (vf-serialize held) (vf-serialize process)))
           #f
           (begin
             (log! process)
             (bcom (^observer bcom (with-process st process) callbacks))))))
    ((register-commitment commitment)
     (let* ((cid (commitment-id commitment))
            (qty (or (commitment-resource-quantity commitment)
                     (commitment-effort-quantity commitment)
                     (make-measure 0 %count-unit)))
            ;; registering is stating the TARGET: how much, and what counts toward
            ;; it. What has been fulfilled is read off the events (fulfillment-of),
            ;; so registering a commitment again moves its target and leaves its
            ;; progress where the log has it.
            ;; VF: "Commitments can satisfy Intents" (flows.md). The terms hold that
            ;; edge, and the satisfiers are the terms read from the intent's side, so
            ;; the quantity fulfilled flows through to the intent (satisfaction-of).
            ;; `satisfies` is one intent id or a matched list (live.scm's
            ;; (need-id offer-id)). Registering again states the edges afresh.
            (iids (let ((s (commitment-satisfies commitment)))
                    (cond ((pair? s) s) (s (list s)) (else '()))))
            (was  (let ((terms (hashmap-ref (os-terms st) cid #f)))
                    (if terms (caddr terms) '()))))
       (bcom (^observer bcom
               (os-rebuild st
                 #:commitment-targets (hashmap-set (os-commitment-targets st) cid qty)
                 #:terms (hashmap-set (os-terms st) cid
                                      (list (commitment-action commitment)
                                            (commitment-resource-conforms-to commitment)
                                            iids))
                 #:satisfiers (link-satisfiers (os-satisfiers st) cid was iids))
               callbacks))))

    ((register-intent intent)
     ;; Holds the intent's target and its intent.planned-within, so the
     ;; gate's level-filter can join through to plan-validations without a
     ;; separate index. Idempotent on re-registration: the target first
     ;; stated stands, and the plan stands when the new intent names none.
     (let* ((iid (intent-id intent))
            (qty (or (intent-resource-quantity intent)
                     (intent-effort-quantity intent)
                     (make-measure 0 %count-unit)))
            (existing (hashmap-ref (os-intent-targets st) iid #f))
            (plan-id  (or (intent-planned-within intent)
                          (and existing (cdr existing)))))
       (bcom (^observer bcom
               (os-rebuild st
                 #:intent-targets (hashmap-set (os-intent-targets st) iid
                                               (cons (if existing (car existing) qty) plan-id)))
               callbacks))))

    ((confirm-plan plan-id scope-id)
     ;; A federation level confirms a plan — adds scope-id to the plan's
     ;; validation set. Voice/credit at scope-id will then count events
     ;; satisfying any intent whose planned-within = plan-id. Idempotent;
     ;; auto-materializes the entry so the call sequence is independent
     ;; of intent registration order.
     (let* ((prev (or (hashmap-ref (os-plan-validations st) plan-id #f) '()))
            (next (if (member scope-id prev) prev (cons scope-id prev))))
       (bcom (^observer bcom
               (os-rebuild st
                 #:plan-validations (hashmap-set (os-plan-validations st) plan-id next))
               callbacks))))

    ((unconfirm-plan plan-id scope-id)
     ;; Withdrawal: remove scope-id from the plan's validation set.
     ;; Voice/credit at scope-id immediately drops past credits derived
     ;; from this plan on the next query (gate is query-time-joined, no
     ;; cache). Idempotent; no-op if plan-id or scope-id absent.
     (let ((prev (hashmap-ref (os-plan-validations st) plan-id #f)))
       (if (or (not prev) (not (member scope-id prev)))
           (bcom (^observer bcom st callbacks))
           (let ((next (filter (lambda (s) (not (equal? s scope-id))) prev)))
             (bcom (^observer bcom
                     (os-rebuild st
                       #:plan-validations (hashmap-set (os-plan-validations st) plan-id next))
                     callbacks))))))

    ((plan-validated-at plan-id)
     (or (hashmap-ref (os-plan-validations st) plan-id #f) '()))

    ((recognize-intent iid scope-id)
     ;; Intent-rail symmetric to confirm-plan: SCOPE-ID recognises IID
     ;; directly, without requiring it to be planned-within. Closes
     ;; the loose-intent seam — uncoordinated work counts at SCOPE-ID
     ;; once recognised. Idempotent.
     (let* ((prev (or (hashmap-ref (os-intent-validations st) iid #f) '()))
            (next (if (member scope-id prev) prev (cons scope-id prev))))
       (bcom (^observer bcom
               (os-rebuild st
                 #:intent-validations (hashmap-set (os-intent-validations st) iid next))
               callbacks))))

    ((unrecognize-intent iid scope-id)
     ;; Withdraw direct intent-recognition. Idempotent.
     (let ((prev (hashmap-ref (os-intent-validations st) iid #f)))
       (if (or (not prev) (not (member scope-id prev)))
           (bcom (^observer bcom st callbacks))
           (let ((next (filter (lambda (s) (not (equal? s scope-id))) prev)))
             (bcom (^observer bcom
                     (os-rebuild st
                       #:intent-validations (hashmap-set (os-intent-validations st) iid next))
                     callbacks))))))

    ((intent-validated-at iid)
     (or (hashmap-ref (os-intent-validations st) iid #f) '()))

    ((intent-plan-id iid)
     (let ((stated (hashmap-ref (os-intent-targets st) iid #f)))
       (and stated (cdr stated))))

    ((register-claim claim)
     (let* ((cid (claim-id claim))
            (qty (or (claim-resource-quantity claim)
                     (claim-effort-quantity claim)
                     (make-measure 0 %count-unit))))
       (bcom (^observer bcom
               (os-rebuild st #:claim-targets (hashmap-set (os-claim-targets st) cid qty))
               callbacks))))

    ;; The books hold RESOURCE, with no entry in the portable log: what a replay of the
    ;; log writes back (record-resource wrote the entry) and what a fixture states.
    ((seed-resource resource)
     (bcom (^observer bcom (hold-resource st resource) callbacks)))

    ;; The books are told of RESOURCE: held as it stands, and written to the portable log
    ;; so a gateway restored from the log alone holds it too, every field. A record the
    ;; books already hold unchanged writes nothing.
    ((record-resource resource)
     (let ((held (hashmap-ref (os-resources st) (economic-resource-id resource) #f)))
       (if (and held (equal? (economic-resource->list held) (economic-resource->list resource)))
           #f
           (begin
             (log! resource)
             (bcom (^observer bcom (hold-resource st resource) callbacks))))))

    ;; --- Queries (read-only, no state change) ---

    ((get-event id)      (event-ref st id))
    ;; recorded, and corrected by nothing — the event a contest may still open on
    ((event-standing? id)
     (and (any (lambda (e) (equal? (economic-event-id e) id))
               (standing-of (reverse (os-events st))))
          #t))
    ((all-events)        (reverse (os-events st)))
    ;; the log as it stands: the acts that still happened, each at its net quantity
    ;; (a correction is no act of its own; see standing-of)
    ((standing-log) (standing-of (reverse (os-events st))))
    ;; RID's on-hand figure as the ledger stood at INSTANT
    ((onhand-as-of rid instant) (onhand-as-of st rid instant))
    ((standing-anchors rid) (standing-anchors st rid))
    ((anchored-onhand rid) (anchored-onhand st rid))
    ((get-resource id)   (hashmap-ref (os-resources st) id #f))
    ((get-process id)    (hashmap-ref (os-processes st) id #f))
    ((process-spec id)   (process-spec-of st id))
    ((all-processes)     (hashmap-values (os-processes st)))
    ((all-resources)     (hashmap-values (os-resources st)))

    ((events-for-resource rid)
     (events-named st (hashmap-ref (os-idx-by-resource st) rid '())))

    ((events-for-process pid)
     (events-named st (hashmap-ref (os-idx-by-process st) pid '())))

    ((events-for-agent aid)
     (events-named st (hashmap-ref (os-idx-by-agent st) aid '())))
    ;; the coworkers of AID — the providers of standing work on the processes
    ;; AID's own standing work belongs to, AID aside — in ONE pass over what
    ;; stands: the fact governance reads for who may speak of whom
    ((coworkers-of aid)
     (let* ((work  (standing-events st 'work))
            (pid   (lambda (ev) (or (economic-event-input-of ev) (economic-event-output-of ev))))
            (mine  (delete-duplicates
                    (filter-map (lambda (ev) (and (equal? aid (economic-event-provider ev)) (pid ev)))
                                work))))
       (delete-duplicates
        (filter-map (lambda (ev)
                      (let ((who (economic-event-provider ev)))
                        (and who (not (equal? who aid)) (member (pid ev) mine) who)))
                    work))))

    ((events-with-action action)
     (events-named st (hashmap-ref (os-idx-by-action st) action '())))

    ((conforming-resources spec-id)
     ;; O(log n) via idx-by-spec instead of O(R) hashmap-filter
     (let ((rids (hashmap-ref (os-idx-by-spec st) spec-id '())))
       (filter-map (lambda (rid) (hashmap-ref (os-resources st) rid #f)) rids)))

    ((resources-contained-in container-id)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-contained-in r) container-id))
       (os-resources st)))

    ((get-fulfillment cid)  (fulfillment-of st cid))
    ((all-fulfillments)     (fulfillments-of st))
    ((open-fulfillments)    (filter (lambda (fs) (not (fulfillment-state-finished fs)))   ; every commitment still open
                                    (fulfillments-of st)))
    ;; a commitment the plan withdrew: its state leaves the books while it is
    ;; still open, so nothing can fulfil it again; a finished one is history
    ;; and stays
    ((retire-commitment cid)
     (let ((fs (fulfillment-of st cid)))
       (if (and fs (not (fulfillment-state-finished fs)))
           ;; the target is withdrawn; the terms stay, so the events already
           ;; recorded keep the join they were read through
           (bcom (^observer bcom (os-rebuild st
                                   #:commitment-targets (hashmap-remove (os-commitment-targets st) cid))
                            callbacks)
                 #t)
           #f)))
    ((get-satisfaction iid) (satisfaction-of st iid))
    ((all-satisfactions)    (satisfactions-of st))   ; comms Stage 0 reads these
    ((get-claim-state cid)  (claim-state-of st cid))

    ;; --- Validation Gate (§III.1) ---
    ;;
    ;; The gate lives in the observer because the observer owns the
    ;; satisfaction-state hashmap and the plan-validation index — the
    ;; two pieces of state the gate joins at query time. Account-store
    ;; reads through these methods; it never caches.

    ;; Fraction in [0, 1] of `event`'s effort that counts as social
    ;; labor. fulfills=C → fulfilled(C)/committed(C), capped at 1;
    ;; input/output-of → aggregate across the process; neither → 0.
    ((validated-fraction event) (event-fraction st event))

    ((validated-gross . rest)
     ;; Credit side of the ledger.
     ;;   (validated-gross)              → scope-wide total, all intents
     ;;   (validated-gross aid)          → AID's gross, all intents
     ;;   (validated-gross aid level)    → AID's gross, only intents in
     ;;                                    plans confirmed at LEVEL
     ;;   (validated-gross #f level)     → scope-wide total at LEVEL
     (let ((aid   (and (pair? rest) (car rest)))
           (level (and (pair? rest) (pair? (cdr rest)) (cadr rest))))
       (ledger-gross st aid level)))

    ((pending-gross . rest)
     ;; Hours in the window (the silence rail): scope-wide, or AID's alone.
     (pending-gross st (and (pair? rest) (car rest))))

    ((claim-effort aid)
     ;; Debit side of the ledger (individually-claimable receipts).
     (ledger-claimed st aid))

    ;; the LEVELS this scope's gate knows: every scope-id that recognizes a
    ;; plan or an intent here (both rails of intent-counts-at?). Finite and
    ;; derived, so a fold can carry one gross cell per level and answer a
    ;; level-stratified read off its standing total.
    ((validation-levels)
     (let ((acc '()))
       (define (note! vs) (for-each (lambda (l) (unless (member l acc) (set! acc (cons l acc)))) vs))
       (hashmap-for-each (lambda (_k vs) (note! vs)) (os-plan-validations st))
       (hashmap-for-each (lambda (_k vs) (note! vs)) (os-intent-validations st))
       acc))

    ;; Skills as a derived view over the work-event log (no stored skill state).
    ((fold-by actions key-of value-of combine) (fold-by st actions key-of value-of combine))  ;; THE fold of the events: key, value, combine
    ((hours-by key-of . rest)    (hours-by st key-of (and (pair? rest) (car rest))))  ;; the ONE fold, keyed by KEY-OF (event → key | #f), optional level
    ((hours-on part . kw)        (apply hours-on st part kw))  ;; THE reader: hours on a part, #:owner #:level #:terms-of
    ((skill-hours-of aid)        (skill-hours-of st aid))    ;; ((skill . hours) …) ledger — the primitive
    ((earned-skills aid)         (earned-skills st aid))     ;; its keys: distinct skills performed
    ((practiced-hours aid skill) (practiced-hours st aid skill)) ;; a lookup: validated hours in SKILL
    ;; the practice itself, dated: AID's standing work in SKILL as
    ;; ((instant . validated-hours) …), for the skill's law to fold
    ;; (planner/formulas/skill-law.scm competence-fold): decay through idle time,
    ;; renewal through satisfied practice
    ((skill-practice aid skill)
     (filter-map (lambda (r) (and (equal? (cadr r) skill) (cons (caddr r) (cadddr r))))
                 (work-practice st aid)))
    ;; the same practice as ROWS (event-id skill instant hours), hours validated
    ;; here, for the join across scopes (planner/observation/practice.scm)
    ((work-practice aid) (work-practice st aid))

    ;; Performed trips as a derived view over pickup→dropoff pairs (no stored
    ;; state) — the measurements the arc-time table folds against the routing
    ;; engine's priors. ((from to mode-or-#f hours) …), oldest first.
    ((arc-observations)          (arc-observations st))
    ;; Cheap staleness probe for derived-view caches (the event log only grows).
    ((event-count)               (length (os-events st)))
    ((resource-count)            (length (hashmap-values (os-resources st))))

    ((credit-balance aid)
     ;; Raw per-scope ledger balance: validated earnings minus claimed
     ;; consumption. The observer holds both sides of the ledger — it's
     ;; the natural place for this read. Governance voice uses gross
     ;; (unspent); claim authorization uses the elastic federation-wide
     ;; version layered on top by account-store.
     (- (ledger-gross st aid) (ledger-claimed st aid)))

    ((inventory)
     (hashmap-filter
       (lambda (r)
         (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
             (> (measure-qty (economic-resource-onhand-quantity r)) 0)))
       (os-resources st)))

    ;; --- Inventory slicing ---

    ((inventory-for-spec spec-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-conforms-to r) spec-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ((inventory-at-location location-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-current-location r) location-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ((inventory-for-agent agent-id)
     (hashmap-filter
       (lambda (r) (and (equal? (economic-resource-primary-accountable r) agent-id)
                        (or (> (measure-qty (economic-resource-accounting-quantity r)) 0)
                            (> (measure-qty (economic-resource-onhand-quantity r)) 0))))
       (os-resources st)))

    ;; --- Enriched inventory (InventoryEntry format) ---

    ((enriched-inventory . rest)
     ;; Returns list of alists with spec, accountingQty, onhandQty, unit,
     ;; location, accountable, batches for each non-empty resource.
     (let ((include-empty (and (pair? rest) (car rest))))
       (filter-map
         (lambda (r)
           (let ((acct (measure-qty (economic-resource-accounting-quantity r)))
                 (oh (measure-qty (economic-resource-onhand-quantity r))))
             (and (or include-empty (> acct 0) (> oh 0))
                  `((resource-id . ,(economic-resource-id r))
                    (spec-id . ,(economic-resource-conforms-to r))
                    (accounting-qty . ,acct)
                    (onhand-qty . ,oh)
                    (unit . ,(if (economic-resource-accounting-quantity r)
                                 (measure-has-unit (economic-resource-accounting-quantity r))
                                 %count-unit))
                    (location . ,(economic-resource-current-location r))
                    (accountable . ,(economic-resource-primary-accountable r))
                    (batches . ,(filter-map
                                  (lambda (bid) (hashmap-ref (os-batches st) bid #f))
                                  (hashmap-ref (os-resource-batches st)
                                    (economic-resource-id r) '())))))))
         (hashmap-values (os-resources st)))))

    ;; --- Additional query methods ---

    ((events-for-agreement agreement-id)
     (filter (lambda (e) (equal? (economic-event-realization-of e) agreement-id))
             (os-events st)))

    ((all-claims)
     (claim-states-of st))

    ;; A claims-triggered-by query would need the <claim> records themselves —
    ;; the observer keeps <claim-state>s, which carry no triggering event. Ask
    ;; the claim store, not the observer.

    ;; --- Inverse event queries ---

    ((fulfilled-by commitment-id) (linked-events st "fulfills" commitment-id))
    ((satisfied-by intent-id)     (linked-events st "satisfies" intent-id))
    ((settled-by claim-id)        (linked-events st "settles" claim-id))

    ;; --- Event trace ---

    ((trace-resource resource-id)
     ;; Walk previousEvent chain, return chronological (oldest first)
     (let ((resource (hashmap-ref (os-resources st) resource-id #f)))
       (if (not resource) '()
           (let loop ((eid (economic-resource-previous-event resource))
                      (seen '()) (result '()))
             (if (or (not eid) (member eid seen)) (reverse result)
                 (let ((event (event-ref st eid)))
                   (if (not event) (reverse result)
                       (loop (economic-event-previous-event event)
                             (cons eid seen)
                             (cons event result)))))))))

    ((active-events-for-resource resource-id)
     ;; This resource's events that still stand (see standing-of)
     (let ((ids (hashmap-ref (os-idx-by-resource st) resource-id '())))
       (filter (lambda (e) (member (economic-event-id e) ids))
               (standing-of (reverse (os-events st))))))

    ;; --- Skill queries ---

    ((skills-of agent-id)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-primary-accountable r) agent-id))
       (os-resources st)))

    ((agents-with-skill spec-id)
     ;; O(k) via idx-by-spec instead of O(R) scan over all resources
     (let ((rids (hashmap-ref (os-idx-by-spec st) spec-id '())))
       (delete-duplicates
         (filter-map (lambda (rid)
                       (let ((r (hashmap-ref (os-resources st) rid #f)))
                         (and r (economic-resource-primary-accountable r))))
                     rids))))

    ;; --- Resource queries ---

    ((resources-by-state state-val)
     (hashmap-filter
       (lambda (r) (equal? (economic-resource-state r) state-val))
       (os-resources st)))

    ((unplanned-events process-id)
     (filter (lambda (e) (not (economic-event-fulfills e)))
             (events-named st (hashmap-ref (os-idx-by-process st) process-id '()))))

    ;; --- Batch/lot tracking ---

    ((get-batch batch-id)
     (hashmap-ref (os-batches st) batch-id #f))

    ((batches-for-resource resource-id)
     (filter-map (lambda (bid) (hashmap-ref (os-batches st) bid #f))
                 (hashmap-ref (os-resource-batches st) resource-id '())))

    ;; --- Agreement storage ---

    ((register-agreement agreement)
     (let ((aid (if (pair? agreement) (assq-ref agreement 'id)
                    (agreement-id agreement))))
       (bcom (^observer bcom
               (os-rebuild st #:agreements
                 (hashmap-set (os-agreements st) aid agreement)) callbacks))))

    ((get-agreement id)
     (hashmap-ref (os-agreements st) id #f))

    ;; --- Exchange recording ---

    ((record-exchange agreement events-list)
     ;; Validate: need at least 2 events with different provider/receiver
     (when (< (length events-list) 2)
       (error "Exchange requires at least 2 events"))
     (let ((provs (delete-duplicates (filter-map economic-event-provider events-list)))
           (recvs (delete-duplicates (filter-map economic-event-receiver events-list))))
       (when (and (= (length provs) 1) (= (length recvs) 1)
                  (equal? (car provs) (car recvs)))
         (error "Exchange requires different agents")))
     ;; Register agreement, tag events with realizationOf, record each
     (let* ((aid (if (pair? agreement) (assq-ref agreement 'id)
                     (agreement-id agreement)))
            (new-agreements (hashmap-set (os-agreements st) aid agreement))
            ;; We need to record events sequentially, threading state
            ;; Use the fold kernel directly
            (initial-st (os-rebuild st #:agreements new-agreements)))
       ;; Fold events through observer-record-event
       (let loop ((evts events-list) (current-st initial-st) (all-affected '()))
         (if (null? evts)
             (bcom (^observer bcom current-st callbacks) (reverse all-affected))
             (call-with-values
               (lambda () (observer-record-event current-st (car evts)))
               (lambda (nst affected)
                 (loop (cdr evts) nst (append (reverse affected) all-affected))))))))

    ;; --- Correction ---

    ((apply-correction correction-event)
     ;; A correction is an event: the kernel records it as any event, with its
     ;; signed quantity, and it is told to every listener as any event is. Kept
     ;; as its own door for the callers that say what they mean; record-event
     ;; with a `corrects` edge does the same.
     (record! correction-event))

    ;; --- Recompute resource from events ---

    ((recompute-resource resource-id)
     ;; The resource as folding the log from nothing gives it: the same kernel,
     ;; the same events (the cascade events are consequences the fold derives
     ;; again, so they are not replayed). A resource that exists only because it
     ;; was seeded without an event is not in the log and so not in the result.
     (let ((fresh (fold (lambda (e s)
                          (call-with-values (lambda () (observer-record-event s e))
                            (lambda (s* _) s*)))
                        (empty-observer-state)
                        (filter (lambda (e) (not (cascade-parent-id (economic-event-id e))))
                                (reverse (os-events st))))))
       (hashmap-ref (os-resources fresh) resource-id #f)))

    ;; --- Clear ---

    ((clear)
     (bcom (^observer bcom (empty-observer-state) callbacks))))))


;; ═════════════════════════════════════════════════════════════════════════
;; Persistence environment
;; ═════════════════════════════════════════════════════════════════════════

(define observer-env
  (make-persistence-env
    `((((vf observation) ^observer) ,^observer))))
