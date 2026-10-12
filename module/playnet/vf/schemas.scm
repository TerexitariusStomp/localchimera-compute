;;; schemas.scm — Guile Scheme records for the ValueFlows ontology
;;; Translated from src/lib/schemas.ts + src/lib/utils/time.ts
;;;
;;; Three-level model:
;;;   Specification (catalog type)  -> ResourceSpecification, ProcessSpecification
;;;   Classification (loose tags)   -> classified-as: list of strings (URIs, taxonomy refs)
;;;   Instance (observed/tracked)   -> EconomicResource, Process, EconomicEvent
;;;
;;; Temporal layers (future -> past):
;;;   Intent  ->  Commitment  ->  EconomicEvent
;;;
;;; Knowledge layer (templates):
;;;   Recipe  ->  RecipeProcess  ->  RecipeFlow
;;;
;;; Convention:
;;;   - Optional fields hold #f when absent.
;;;   - All fields are immutable (value objects).
;;;   - Enums are symbols; validated by predicate helpers.
;;;   - Lists/arrays are Scheme lists; optional lists are #f or a list.
;;;   - Nested record fields hold the nested record value (or #f if optional).


;;; WHAT THE FILE HOLDS. The classes of docs/valueflows/assets/all_vf.TTL, the
;;; action table, and the Duration the TTL's hasDuration points at: nothing else.
;;; tests/ddmrp/vf-conformance-classes-test.scm holds the file to the TTL both
;;; ways. What playnet adds stands in a module per family: the buffer planner
;;; (ddmrp/records), recurring schedules (beyond/schedules), the lot
;;; (beyond/lot), the planning scenario (beyond/scenario) and the books' states
;;; (observation/states). A record that is no class of the TTL takes a family.
;;;
;;; A MODULE, not an include-fragment. It was the latter, and that cost two
;;; things. Guile checks .go freshness per module by source mtime, and an
;;; edited fragment moves no such mtime — its text is compiled into whatever
;;; included it, so the edit goes unseen. And every loader had to guard against
;;; defining a SECOND, incompatible set of record types: the `(unless (defined?
;;; 'make-economic-resource) ...)` in planner/planner.scm existed for exactly
;;; that. A module is loaded once and yields one set of record types, which is
;;; what that guard was hand-rolling.
;;;
;;; Self-contained: needs nothing beyond core Guile, which is why this is the
;;; first fragment liftable out. The umbrella re-exports every name below, so
;;; `(use-modules (playnet boot prelude))` still sees them.

(define-module (playnet vf schemas)
  #:use-module ((playnet vf facts located) #:select (svc-good))
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier vf-record-maker))
  #:use-module ((playnet vf serdes) #:select (register-vf-record!))
  #:export (copy-agent copy-recipe-process copy-process
            measure->qty measure->unit
            make-measure
            make-duration
            make-unit
            %make-spatial-thing
            make-spatial-thing
            *vf-actions*
            vf-action?
            *quantity-effects*
            quantity-effect?
            *property-effects*
            property-effect?
            make-action-definition
            *action-definitions*
            get-action-def
            measure-qty
            *agent-types*
            agent-type?
            make-agent
            make-agent-relationship-role
            make-agent-relationship
            %make-resource-specification
            make-resource-specification
            copy-resource-specification
            resource-spec-keep-in-place?
            resource-specification-with-composition
            specs->units
            make-process-specification
            make-recipe-flow
            copy-recipe-flow
            make-recipe-process
            make-recipe-exchange
            make-recipe
            make-recipe-group
            %mode-from-tags
            %strip-mode-tags
            %make-economic-resource
            make-economic-resource
            copy-economic-resource
            resource-rented?
            resource-sovereign?
            %rented-frag-profile
            %rented-frag-profiles
            rented-frag-profile
            rented-frag-tip
            %rented-frag-tip
            rented-goods
            %make-economic-event
            make-economic-event
            resource-distribution-mode
            event-distribution-mode
            copy-economic-event
            make-process
            make-intent
            copy-intent
            intent->commitment
            make-commitment
            copy-commitment
            make-claim
            make-plan
            make-scenario-definition
            make-scenario
            make-agreement
            make-agreement-bundle
            make-proposal
            make-proposal-list
            ;; the record declarations below define these (define-vf-record; check-record-exports holds the list)
            <measure> measure? measure-has-numerical-value measure-has-unit <duration> duration?
            duration-has-numerical-value duration-has-unit <unit> unit? unit-id unit-label
            unit-symbol unit-classified-as <spatial-thing> spatial-thing? spatial-thing-id spatial-thing-name
            spatial-thing-note spatial-thing-lat spatial-thing-long spatial-thing-alt spatial-thing-mappable-address spatial-thing-contained-in
            spatial-thing-boundary <action-definition> action-definition? action-definition-event-quantity action-definition-input-output action-definition-pairs-with
            action-definition-create-resource action-definition-accounting-effect action-definition-onhand-effect action-definition-location-effect action-definition-contained-effect action-definition-accountable-effect
            action-definition-stage-effect action-definition-state-effect action-definition-implies-transfer action-definition-eligible-for-exchange <agent> agent?
            agent-id agent-type agent-name agent-note agent-image agent-primary-location
            agent-classified-as agent-availability-window <agent-relationship-role> agent-relationship-role? agent-relationship-role-id agent-relationship-role-label
            agent-relationship-role-inverse-label agent-relationship-role-note agent-relationship-role-classified-as <agent-relationship> agent-relationship? agent-relationship-id
            agent-relationship-subject agent-relationship-object agent-relationship-relationship agent-relationship-in-scope-of agent-relationship-note <resource-specification>
            resource-specification? resource-specification-id resource-specification-name resource-specification-note resource-specification-image resource-specification-resource-classified-as
            resource-specification-default-unit-of-resource resource-specification-default-unit-of-effort resource-specification-substitutable resource-specification-medium-of-exchange resource-specification-buffer-profile-id resource-specification-positioning-analysis
            resource-specification-satisfied-by resource-specification-keep-in-place resource-specification-composition <process-specification> process-specification? process-specification-id
            process-specification-name process-specification-note process-specification-image process-specification-is-decoupling-point process-specification-is-control-point process-specification-buffer-type
            process-specification-is-divergent-point process-specification-is-convergent-point <recipe-flow> recipe-flow? recipe-flow-id recipe-flow-action
            recipe-flow-resource-conforms-to recipe-flow-resource-classified-as recipe-flow-resource-quantity recipe-flow-effort-quantity recipe-flow-recipe-input-of recipe-flow-recipe-output-of
            recipe-flow-recipe-clause-of recipe-flow-stage recipe-flow-state recipe-flow-note recipe-flow-is-primary recipe-flow-resolve-from-flow
            <recipe-process> recipe-process? recipe-process-id recipe-process-name recipe-process-note recipe-process-image
            recipe-process-process-conforms-to recipe-process-process-classified-as recipe-process-has-duration recipe-process-sequence-group recipe-process-minimum-batch-quantity <recipe-exchange>
            recipe-exchange? recipe-exchange-id recipe-exchange-name recipe-exchange-note <recipe> recipe?
            recipe-id recipe-name recipe-note recipe-based-on recipe-primary-output recipe-recipe-processes
            recipe-recipe-exchanges <recipe-group> recipe-group? recipe-group-id recipe-group-name recipe-group-note
            recipe-group-recipes <economic-resource> economic-resource? economic-resource-id economic-resource-name economic-resource-note
            economic-resource-image economic-resource-tracking-identifier economic-resource-conforms-to economic-resource-classified-as economic-resource-accounting-quantity economic-resource-onhand-quantity
            economic-resource-current-location economic-resource-current-virtual-location economic-resource-primary-accountable economic-resource-custodian-scope economic-resource-stage economic-resource-state
            economic-resource-contained-in economic-resource-unit-of-effort economic-resource-lot economic-resource-previous-event economic-resource-availability-window economic-resource-distribution-mode
            <economic-event> economic-event? economic-event-id economic-event-action economic-event-input-of economic-event-output-of
            economic-event-resource-inventoried-as economic-event-to-resource-inventoried-as economic-event-resource-conforms-to economic-event-resource-classified-as economic-event-provider economic-event-receiver
            economic-event-resource-quantity economic-event-effort-quantity economic-event-has-beginning economic-event-has-end economic-event-has-point-in-time economic-event-created
            economic-event-at-location economic-event-to-location economic-event-state economic-event-fulfills economic-event-satisfies economic-event-corrects
            economic-event-realization-of economic-event-settles economic-event-note economic-event-in-scope-of economic-event-previous-event economic-event-distribution-mode
            <process> process? process-id process-name process-note process-based-on
            process-classified-as process-planned-within process-nested-in process-in-scope-of process-has-beginning process-has-end
            process-finished <intent> intent? intent-id intent-action intent-name
            intent-note intent-image intent-input-of intent-output-of intent-resource-inventoried-as intent-resource-conforms-to
            intent-resource-classified-as intent-resource-quantity intent-effort-quantity intent-available-quantity intent-minimum-quantity intent-provider
            intent-receiver intent-has-beginning intent-has-end intent-has-point-in-time intent-due intent-at-location
            intent-stage intent-state intent-planned-within intent-satisfies intent-in-scope-of intent-finished
            intent-availability-window <commitment> commitment? commitment-id commitment-action commitment-note
            commitment-input-of commitment-output-of commitment-resource-inventoried-as commitment-resource-conforms-to commitment-resource-classified-as commitment-resource-quantity
            commitment-effort-quantity commitment-provider commitment-receiver commitment-has-beginning commitment-has-end commitment-has-point-in-time
            commitment-due commitment-created commitment-at-location commitment-in-scope-of commitment-stage commitment-state
            commitment-satisfies commitment-clause-of commitment-independent-demand-of commitment-planned-within commitment-finished commitment-availability-window
            <claim> claim? claim-id claim-action claim-provider claim-receiver
            claim-triggered-by claim-resource-quantity claim-effort-quantity claim-resource-conforms-to claim-resource-classified-as claim-due
            claim-created claim-note claim-finished <plan> plan? plan-id
            plan-name plan-note plan-due plan-created plan-has-independent-demand plan-refinement-of
            plan-classified-as <scenario-definition> scenario-definition? scenario-definition-id scenario-definition-name scenario-definition-note
            scenario-definition-has-duration scenario-definition-in-scope-of <scenario> scenario? scenario-id scenario-name
            scenario-note scenario-defined-as scenario-refinement-of scenario-has-beginning scenario-has-end scenario-in-scope-of
            <agreement> agreement? agreement-id agreement-name agreement-note agreement-created
            agreement-stipulates agreement-stipulates-reciprocal <agreement-bundle> agreement-bundle? agreement-bundle-id agreement-bundle-name
            agreement-bundle-note agreement-bundle-created agreement-bundle-bundles <proposal> proposal? proposal-id
            proposal-name proposal-note proposal-has-beginning proposal-has-end proposal-unit-based proposal-created
            proposal-purpose proposal-eligible-location proposal-in-scope-of proposal-publishes proposal-reciprocal proposal-proposed-to
            <proposal-list> proposal-list? proposal-list-id proposal-list-name proposal-list-note proposal-list-created
            proposal-list-lists))

;; ═══════════════════════════════════════════════════════════════════════
;; PRIMITIVES
;; ═══════════════════════════════════════════════════════════════════════

;;; Measure — a quantity with a unit.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "kg", "hours", OM2 URI).
(define-vf-record <measure> Measure
  (has-numerical-value has-unit)
  #:register register-vf-record!)

(define make-measure                   (vf-record-constructor <measure>))
;; a measure's number and its unit, where there is a measure at all
(define (measure->qty m)  (and m (measure-has-numerical-value m)))
(define (measure->unit m) (and m (measure-has-unit m)))


;;; Duration — time span for processes and recipes.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "hours", "days").
(define-vf-record <duration> Duration
  (has-numerical-value has-unit)
  #:register register-vf-record!)

(define make-duration                   (vf-record-constructor <duration>))


;;; Unit — measurement unit definition.
;;; Fields: id (string), label (string), symbol (string),
;;;         classified-as (optional: list of strings | #f).
(define-vf-record <unit> Unit
  (id label symbol classified-as)
  #:register register-vf-record!)

(define make-unit              (vf-record-constructor <unit>))


;;; SpatialThing — a location in space.
;;; Fields: id (string), name? (string), note? (string),
;;;         lat? (number), long? (number), alt? (number),
;;;         mappable-address? (string), contained-in? (string — parent SpatialThing ID).
(define-vf-record <spatial-thing> SpatialThing
  (id name note lat long alt mappable-address contained-in boundary)
  #:register register-vf-record!)     ; GeoJSON geometry (Polygon/MultiPolygon) or #f — the EXTENT

;; A SpatialThing spatializes as GeoJSON. By default it is a POINT (lat/long) — a farm,
;; a venue. When `boundary` is set (a GeoJSON geometry: real, concave, ridgeline-
;; following), it is a REGION — an ecoregion/bioregion/watershed. So point and polygon
;; are one ontology; the map draws whichever the thing carries (browser containers.js),
;; and containment can be DERIVED by point-in-polygon (a farm sits in the shed whose
;; boundary holds it). `boundary` is optional, so every existing 8-arg call is unchanged.
(define %make-spatial-thing                 (vf-record-constructor <spatial-thing>))
(define make-spatial-thing (vf-record-maker <spatial-thing>))


;; ═══════════════════════════════════════════════════════════════════════
;; ACTIONS — The 19 standard VF actions
;; ═══════════════════════════════════════════════════════════════════════

;;; VfAction — the fixed set of actions that flows can perform.
;;; Represented as symbols in kebab-case.
(define *vf-actions*
  '(produce
    consume
    use
    work
    cite
    deliver-service
    pickup
    dropoff
    accept
    modify
    combine
    separate
    transfer-all-rights
    transfer-custody
    transfer
    move
    copy
    raise
    lower))

(define (vf-action? x)
  (and (symbol? x) (memq x *vf-actions*) #t))

;;; QuantityEffect — effect on a resource quantity.
;;; Symbols: increment, decrement, decrement-increment, increment-to, no-effect.
(define *quantity-effects*
  '(increment decrement decrement-increment increment-to no-effect))

(define (quantity-effect? x)
  (and (symbol? x) (memq x *quantity-effects*) #t))

;;; PropertyEffect — effect on a resource property (location, stage, state, etc.).
;;; Symbols: update, update-to, remove, new, no-effect.
(define *property-effects*
  '(update update-to remove new no-effect))

(define (property-effect? x)
  (and (symbol? x) (memq x *property-effects*) #t))

;;; ActionDefinition — encodes behavioral rules for each VF action.
;;; Fields:
;;;   event-quantity       (symbol: resource-quantity | effort-quantity | both)
;;;   input-output         (symbol: input | output | output-input | not-applicable)
;;;   pairs-with           (optional: vf-action symbol | #f)
;;;   create-resource      (symbol: optional | optional-to | no-effect)
;;;   accounting-effect    (quantity-effect symbol)
;;;   onhand-effect        (quantity-effect symbol)
;;;   location-effect      (property-effect symbol)
;;;   contained-effect     (property-effect symbol)
;;;   accountable-effect   (property-effect symbol)
;;;   stage-effect         (property-effect symbol)
;;;   state-effect         (property-effect symbol)
;;;   implies-transfer     (symbol: all-rights | custody | #f for none)
;;;   eligible-for-exchange (boolean)
(define-vf-record <action-definition> ActionDefinition
  (event-quantity input-output pairs-with create-resource accounting-effect onhand-effect location-effect contained-effect accountable-effect stage-effect state-effect implies-transfer eligible-for-exchange)
  #:register register-vf-record!)

(define make-action-definition (vf-record-maker <action-definition>))

(define *action-definitions*
  (list
    (cons 'produce
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'output #:create-resource 'optional
        #:accounting-effect 'increment #:onhand-effect 'increment #:location-effect 'new #:contained-effect 'no-effect #:accountable-effect 'new #:stage-effect 'update #:state-effect 'update
        #:implies-transfer 'all-rights #:eligible-for-exchange #t))
    (cons 'consume
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'input #:create-resource 'no-effect
        #:accounting-effect 'decrement #:onhand-effect 'decrement #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update
        #:implies-transfer 'all-rights #:eligible-for-exchange #t))
    (cons 'use
      (make-action-definition
        #:event-quantity 'both #:input-output 'input #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'no-effect #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update #:eligible-for-exchange #t))
    (cons 'work
      (make-action-definition
        #:event-quantity 'effort-quantity #:input-output 'input #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'no-effect #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'no-effect #:eligible-for-exchange #t))
    (cons 'cite
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'input #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'no-effect #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update #:eligible-for-exchange #t))
    (cons 'deliver-service
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'output-input #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'no-effect #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'no-effect #:eligible-for-exchange #t))
    (cons 'pickup
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'input #:pairs-with 'dropoff #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'decrement #:location-effect 'update #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update
        #:implies-transfer 'custody))
    (cons 'dropoff
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'output #:pairs-with 'pickup #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'increment #:location-effect 'update #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'update #:state-effect 'update
        #:implies-transfer 'custody))
    (cons 'accept
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'input #:pairs-with 'modify #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'decrement #:location-effect 'update #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update
        #:implies-transfer 'custody))
    (cons 'modify
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'output #:pairs-with 'accept #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'increment #:location-effect 'update #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'update #:state-effect 'update
        #:implies-transfer 'custody))
    (cons 'combine
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'input #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'decrement #:location-effect 'no-effect #:contained-effect 'update #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update #:eligible-for-exchange #t))
    (cons 'separate
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'output #:create-resource 'no-effect
        #:accounting-effect 'no-effect #:onhand-effect 'increment #:location-effect 'no-effect #:contained-effect 'remove #:accountable-effect 'no-effect #:stage-effect 'update #:state-effect 'update #:eligible-for-exchange #t))
    (cons 'transfer-all-rights
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional-to
        #:accounting-effect 'decrement-increment #:onhand-effect 'no-effect #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'update-to #:stage-effect 'no-effect #:state-effect 'update-to #:eligible-for-exchange #t))
    (cons 'transfer-custody
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional-to
        #:accounting-effect 'no-effect #:onhand-effect 'decrement-increment #:location-effect 'update-to #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update-to #:eligible-for-exchange #t))
    (cons 'transfer
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional-to
        #:accounting-effect 'decrement-increment #:onhand-effect 'decrement-increment #:location-effect 'update-to #:contained-effect 'no-effect #:accountable-effect 'update-to #:stage-effect 'no-effect #:state-effect 'update-to #:eligible-for-exchange #t))
    (cons 'move
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional-to
        #:accounting-effect 'decrement-increment #:onhand-effect 'decrement-increment #:location-effect 'update-to #:contained-effect 'no-effect #:accountable-effect 'no-effect #:stage-effect 'no-effect #:state-effect 'update-to #:eligible-for-exchange #t))
    (cons 'copy
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional-to
        #:accounting-effect 'increment-to #:onhand-effect 'increment-to #:location-effect 'new #:contained-effect 'no-effect #:accountable-effect 'new #:stage-effect 'no-effect #:state-effect 'update-to #:eligible-for-exchange #t))
    (cons 'raise
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional
        #:accounting-effect 'increment #:onhand-effect 'increment #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'new #:stage-effect 'no-effect #:state-effect 'update #:eligible-for-exchange #t))
    (cons 'lower
      (make-action-definition
        #:event-quantity 'resource-quantity #:input-output 'not-applicable #:create-resource 'optional
        #:accounting-effect 'decrement #:onhand-effect 'decrement #:location-effect 'no-effect #:contained-effect 'no-effect #:accountable-effect 'new #:stage-effect 'no-effect #:state-effect 'update #:eligible-for-exchange #t))))


;; ═══════════════════════════════════════════════════════════════════════
;; AGENTS
;; ═══════════════════════════════════════════════════════════════════════

;;; AgentType — Person | Organization | EcologicalAgent.
;; a measure's number; no measure is no quantity
(define (measure-qty m)
  (if m (measure-has-numerical-value m) 0))

;; an action's row of the table; an action the table does not hold is an error
(define (get-action-def action-sym)
  (let ((entry (assq action-sym *action-definitions*)))
    (if entry (cdr entry)
        (error (format #f "Unknown VF action: ~a" action-sym)))))

;;; *action-definitions* — complete behavioral table for all 19 VF actions.
;;; An alist mapping vf-action symbols to <action-definition> records.
(define *agent-types* '(person organization ecological-agent))

(define (agent-type? x)
  (and (symbol? x) (memq x *agent-types*) #t))

;;; Agent — an economic agent (person, organization, or ecological agent).
;;; Fields: id (string), type (agent-type symbol, default 'person),
;;;         name? (string), note? (string), image? (string),
;;;         primary-location? (string: SpatialThing ID),
;;;         classified-as? (list of strings),
;;;         availability-window? (<availability-window> | <specific-date-window> | #f).
(define-vf-record <agent> Agent
  (id type name note image primary-location classified-as availability-window)
  #:register register-vf-record!)

(define make-agent (vf-record-maker <agent>))
(define copy-agent (vf-record-copier <agent>))


;;; AgentRelationshipRole — a named role an agent plays relative to another.
;;; Fields: id (string), label (string), inverse-label? (string),
;;;         note? (string), classified-as? (list of strings).
(define-vf-record <agent-relationship-role> AgentRelationshipRole
  (id label inverse-label note classified-as)
  #:register register-vf-record!)

(define make-agent-relationship-role (vf-record-maker <agent-relationship-role>))


;;; AgentRelationship — a directed relationship between two agents.
;;; subject plays relationship (role) toward object.
;;; Fields: id (string), subject (string: Agent ID), object (string: Agent ID),
;;;         relationship (string: AgentRelationshipRole ID),
;;;         in-scope-of? (string: Agent ID), note? (string).
(define-vf-record <agent-relationship> AgentRelationship
  (id subject object relationship in-scope-of note)
  #:register register-vf-record!)

(define make-agent-relationship (vf-record-maker <agent-relationship>))


;; ═══════════════════════════════════════════════════════════════════════
;; KNOWLEDGE LAYER — Specifications
;; ═══════════════════════════════════════════════════════════════════════

;;; ResourceSpecification — the catalog "type" of a resource.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         resource-classified-as? (list of strings),
;;;         default-unit-of-resource? (string), default-unit-of-effort? (string),
;;;         substitutable? (boolean), medium-of-exchange? (boolean),
;;;         buffer-profile-id? (string: BufferProfile ID),
;;;         positioning-analysis? (<positioning-analysis>),
;;;         satisfied-by? (skills: DNF of substitute clauses — see below).
(define-vf-record <resource-specification> ResourceSpecification
  (id name note image resource-classified-as default-unit-of-resource default-unit-of-effort substitutable medium-of-exchange buffer-profile-id positioning-analysis satisfied-by keep-in-place composition)
  #:register register-vf-record!)
  ;; satisfied-by (skills): the substitution/equivalence relation. A DNF —
  ;; a list of CLAUSES, each clause a list of (component-skill . min-hours).
  ;; An agent CONFORMS to this spec if it holds the spec directly OR holds
  ;; every component of SOME clause at ≥ its min validated hours. '() / #f =
  ;; direct conformance only. This is what lets {electrician,surgeon} satisfy
  ;; an electrosurgery requirement without holding "electrosurgeon" directly.
  ;; keep-in-place: a container whose `use` relocates its contents through
  ;; TIME (storage) rather than space (transport) — drives proc-temporal? /
  ;; arc-scale. Promoted from the legacy "stationary" classifiedAs tag, and
  ;; the promotion is COMPLETE: the smart constructor below folds any such
  ;; tag into this field and strips it, so the field is the only thing read.
  ;; composition: what one unit of this spec CARRIES, stated by the scope that
  ;; holds it — ((leaf . amount) …) in knowledge/catalogues/substances.scm's grammar (an
  ;; element's mass fraction, "heat" in kWh, "entropy" in kWh/K). A warmed form
  ;; states its excess here (knowledge/thermal.scm); the recipe store hands
  ;; every stated row to the solve and the lint in front of the fallback table.
  ;; '() / #f = nothing stated: the table or a recipe's derivation speaks.

;; Smart constructor: the keyword-only trailing fields (`satisfied-by`,
;; `keep-in-place`) keep every existing 11-positional call site working
;; unchanged. serdes reconstructs via the RAW record-constructor (captured at
;; register-vf-record! time), so it round-trips the trailing fields automatically.
(define %make-resource-specification
  (vf-record-constructor <resource-specification>))
(define %resource-specification (vf-record-maker <resource-specification>))
(define copy-resource-specification (vf-record-copier <resource-specification>))
;; a specification as stated, settled: the legacy "stationary" tag is
;; keep-in-place and leaves the classification; satisfied-by and composition
;; are lists
(define (%settle-resource-specification r)
  (let ((cls (resource-specification-resource-classified-as r)))
    (copy-resource-specification r
      #:resource-classified-as (if (list? cls) (delete "stationary" cls) cls)
      #:keep-in-place (or (resource-specification-keep-in-place r)
                          (and (list? cls) (member "stationary" cls) #t))
      #:satisfied-by (or (resource-specification-satisfied-by r) '())
      #:composition (or (resource-specification-composition r) '()))))
(define (make-resource-specification . args)
  "(make-resource-specification #:id … #:name … #:resource-classified-as …), settled."
  (%settle-resource-specification (apply %resource-specification args)))
(define (resource-specification-with-composition spec composition)
  "SPEC with COMPOSITION stated on it and every other field as it was: the one
   place a specification is copied to change what it carries."
  (copy-resource-specification spec #:composition composition))
;; Field-only read — the constructor normalises any legacy "stationary" tag
;; into keep-in-place at construction, so no tag is consulted at query time.
(define (resource-spec-keep-in-place? s)
  (and (resource-specification-keep-in-place s) #t))
(define (specs->units specs)
  "The unit each of SPECS counts in, ((spec-id . unit) …): the specification's own
   default-unit-of-resource, for every spec that states one."
  (filter-map (lambda (sp) (and=> (resource-specification-default-unit-of-resource sp)
                                  (lambda (u) (cons (resource-specification-id sp) u))))
              specs))


;;; ProcessSpecification — the "type" of a process.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         is-decoupling-point? (boolean), is-control-point? (boolean),
;;;         buffer-type? (symbol: stock | time | capacity),
;;;         is-divergent-point? (boolean), is-convergent-point? (boolean).
(define-vf-record <process-specification> ProcessSpecification
  (id name note image is-decoupling-point is-control-point buffer-type is-divergent-point is-convergent-point)
  #:register register-vf-record!)

(define make-process-specification (vf-record-maker <process-specification>))


;; ═══════════════════════════════════════════════════════════════════════
;; KNOWLEDGE LAYER — Recipes
;; ═══════════════════════════════════════════════════════════════════════

;;; RecipeFlow — a template flow in a recipe (what goes in/out of a RecipeProcess).
;;; Fields: id (string), action (vf-action symbol),
;;;         resource-conforms-to? (string: ResourceSpecification ID),
;;;         resource-classified-as? (list of strings),
;;;         resource-quantity? (<measure>), effort-quantity? (<measure>),
;;;         recipe-input-of? (string: RecipeProcess ID),
;;;         recipe-output-of? (string: RecipeProcess ID),
;;;         recipe-clause-of? (string: RecipeExchange ID),
;;;         stage? (string: ProcessSpecification ID), state? (string),
;;;         note? (string), is-primary? (boolean),
;;;         resolve-from-flow? (string: RecipeFlow ID).
(define-vf-record <recipe-flow> RecipeFlow
  (id action resource-conforms-to resource-classified-as resource-quantity effort-quantity recipe-input-of recipe-output-of recipe-clause-of stage state note is-primary resolve-from-flow)
  #:register register-vf-record!)

(define make-recipe-flow (vf-record-maker <recipe-flow>))
(define copy-recipe-flow (vf-record-copier <recipe-flow>))


;;; RecipeProcess — a template process step in a recipe.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         process-conforms-to? (string: ProcessSpecification ID),
;;;         process-classified-as? (list of strings),
;;;         has-duration? (<duration>),
;;;         sequence-group? (integer),
;;;         minimum-batch-quantity? (<measure>).
(define-vf-record <recipe-process> RecipeProcess
  (id name note image process-conforms-to process-classified-as has-duration sequence-group minimum-batch-quantity)
  #:register register-vf-record!)

(define make-recipe-process (vf-record-maker <recipe-process>))
(define copy-recipe-process (vf-record-copier <recipe-process>))


;;; RecipeExchange — a template exchange agreement in a recipe.
;;; Fields: id (string), name? (string), note? (string).
(define-vf-record <recipe-exchange> RecipeExchange
  (id name note)
  #:register register-vf-record!)

(define make-recipe-exchange (vf-record-maker <recipe-exchange>))


;;; Recipe — groups RecipeProcesses and RecipeExchanges into a reusable template.
;;; Fields: id (string), name (string), note? (string),
;;;         based-on? (string: ResourceSpecification ID),
;;;         primary-output? (string: ResourceSpecification ID),
;;;         recipe-processes? (list of strings: RecipeProcess IDs),
;;;         recipe-exchanges? (list of strings: RecipeExchange IDs).
(define-vf-record <recipe> Recipe
  (id name note based-on primary-output recipe-processes recipe-exchanges)
  #:register register-vf-record!)

(define make-recipe (vf-record-maker <recipe>))


;;; RecipeGroup — groups multiple Recipes that together produce more than one output.
;;; Fields: id (string), name (string), note? (string),
;;;         recipes (list of strings: Recipe IDs).
(define-vf-record <recipe-group> RecipeGroup
  (id name note recipes)
  #:register register-vf-record!)

(define make-recipe-group (vf-record-maker <recipe-group>))


;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVATION LAYER — Resources
;; ═══════════════════════════════════════════════════════════════════════

;;; EconomicResource — a tracked instance of a resource.
;;; State is derived from EconomicEvents:
;;;   accounting-quantity: rights-based balance
;;;   onhand-quantity:     custody-based balance
;;; conforms-to exactly ONE ResourceSpecification.
;;; Fields: id (string), name? (string), note? (string), image? (string),
;;;         tracking-identifier? (string),
;;;         conforms-to (string: ResourceSpecification ID — required),
;;;         classified-as? (list of strings),
;;;         accounting-quantity? (<measure>), onhand-quantity? (<measure>),
;;;         current-location? (string: SpatialThing ID),
;;;         current-virtual-location? (string: URI),
;;;         primary-accountable? (string: Agent ID),
;;;         custodian-scope? (string: Scope ID),
;;;           Custody is ALWAYS an agent's (here, a scope's) — never a thing's.
;;;           In VF's own transport example (docs/valueflows/examples/ex-complex.md
;;;           §Transportation with transfer) the carrier CLAUDIA receives custody
;;;           of Alice's apples; the truck never appears in the custody chain at
;;;           all. Being INSIDE a truck, a box or a silo is `contained-in`, a
;;;           resource→resource relation. The two are orthogonal, which is what
;;;           lets them come apart: a socialized stash is held by the commune
;;;           while it sits in the same box under the same bridge.
;;;         stage? (string: ProcessSpecification ID), state? (string),
;;;         contained-in? (string: EconomicResource ID),
;;;         unit-of-effort? (string),
;;;         lot? (<batch-lot-record>),
;;;         previous-event? (string: EconomicEvent ID),
;;;         availability-window? (temporal-expression).
(define-vf-record <economic-resource> EconomicResource
  (id name note image tracking-identifier conforms-to classified-as accounting-quantity onhand-quantity current-location current-virtual-location primary-accountable custodian-scope stage state contained-in unit-of-effort lot previous-event availability-window distribution-mode)
  #:register register-vf-record!)
  ;; distribution-mode: 'communal | 'individual-claimable | #f — import
  ;; vocabulary, normalised from the legacy "communal"/"individually-claimable"
  ;; classifiedAs tag, and provenance on the events a claim writes. The rail
  ;; a good is actually on is read off the recipes (rail.scm rails-of,
  ;; published by the plan): a claim recipe for someone puts it on the
  ;; individual rail, the scope's own consumption keeps it communal, `use`
  ;; makes it a means, and a made good that is nobody's input is individual.
  ;; This field decides nothing; the accountability invariant (communal ⟹
  ;; accountable = commune) checks the published rail (algorithms/custody.scm).

;; Migration normalisation: a legacy "communal"/"individually-claimable" tag in
;; classifiedAs is read INTO the distribution-mode field and stripped out, so
;; existing fixtures/data that still tag auto-migrate at construction and reads
;; are field-only. New code passes #:distribution-mode directly.
(define (%mode-from-tags cls)
  (cond ((not (list? cls)) #f)
        ((member "communal" cls) 'communal)
        ((or (member "individually-claimable" cls)
             (member "individual claimable" cls)) 'individual-claimable)
        (else #f)))
(define (%strip-mode-tags cls)
  (if (list? cls)
      (filter (lambda (t)
                (not (member t '("communal" "individually-claimable" "individual claimable"))))
              cls)
      cls))

;; Smart constructor: `distribution-mode` is keyword-only and last, so every
;; existing 20-positional call site keeps working unchanged; serdes round-trips
;; it via the raw constructor.
(define %make-economic-resource
  (vf-record-constructor <economic-resource>))
(define %economic-resource (vf-record-maker <economic-resource>))
;; a resource as stated, settled: its distribution mode is the one stated or
;; the one its tags name, and the mode tags leave the classification
(define (%settle-economic-resource r)
  (let* ((cls  (economic-resource-classified-as r))
         (mode (or (economic-resource-distribution-mode r) (%mode-from-tags cls))))
    (copy-economic-resource r
      #:classified-as (if mode (%strip-mode-tags cls) cls)
      #:distribution-mode mode)))
(define (make-economic-resource . args)
  "(make-economic-resource #:id … #:conforms-to … #:onhand-quantity …), settled."
  (%settle-economic-resource (apply %economic-resource args)))

;; The one functional update on an <economic-resource> — copy-commitment's
;; sibling: every field defaults to the record's own, and a field added to the
;; record is carried by every setter written over this.
(define copy-economic-resource (vf-record-copier <economic-resource>))

;; ── tenure: an agent's relationship to a resource's RIGHTS vs its CUSTODY ────
;; ValueFlows separates two relationships (concepts/resources.md §rights/custody),
;; and deliberately avoids the word "ownership":
;;   • primary-accountable — full (human-realm) rights & responsibilities.
;;   • custodian-scope     — custody / possession, irrespective of rights.
;; A resource is RENTED (loaned-in) to SCOPE when SCOPE holds custody but is NOT
;; primary-accountable: some other agent holds the rights and can revoke custody.
;; That is the ONE fragility shared by a rented social-media channel (the platform
;; can deplatform you), a temporarily-socialized means of production (the owner can
;; recall the grant), and a borrowed tool (it must be returned) — capacity you
;; depend on but hold under another's rights. SOVEREIGN is the negation: SCOPE is
;; itself primary-accountable, so nobody can pull it. This is the same custody/rights
;; test compliance.scm's resource-held-by? reads — no new state model, no tag.
(define* (resource-rented? resource #:optional (scope #f))
  "True iff RESOURCE is held under SPLIT tenure — its custodian is not its
   primary-accountable, so the rights-holder can revoke custody (deplatform /
   owner-recall / return). SCOPE restricts it to resources SCOPE itself custodies
   (rented *to me*); SCOPE #f asks only that custody be split from rights — the
   right test inside a scope's own resource view, where everything is already
   held here."
  (let ((cust (economic-resource-custodian-scope resource))
        (acct (economic-resource-primary-accountable resource)))
    (and cust (not (equal? cust acct))
         (or (not scope) (equal? scope cust)))))

(define (resource-sovereign? resource scope)
  "True iff SCOPE holds the RIGHTS (is primary-accountable) — nobody can revoke it."
  (equal? scope (economic-resource-primary-accountable resource)))

;; The default rented-fragility profile (lo hi alpha w) the frag barrier reads —
;; ONE source of truth for every rented resource, comms channels and socialized
;; means alike. It is a governance choice (how much dependence on revocable capacity
;; the federation tolerates), carried here so the solver's frag barrier and the wheel
;; share the same steepness. %rented-frag-tip = quantile_alpha(lo,hi) = 4 (lean on
;; ~4 units of borrowed capacity before it bites); the weight is the 4th field = 1.
(define %rented-frag-profile (list 3.0 5.0 0.5 1.0))

;; Per-spec overrides: recall does not cost every dependence equally. Pulling a
;; channel loses reach; pulling a BED loses someone's home — so housing bites
;; sooner (tip 2, not 4) and twice as steeply (w 2). Same (lo hi alpha w) shape,
;; same math; a spec not named here reads the shared profile above, so the one
;; source of truth stays one — this table is the governance dial for the kinds
;; whose recall is a displacement, not an inconvenience.
(define %rented-frag-profiles
  '(("spec-bed"    . (1.0 3.0 0.5 2.0))
    ("spec-dwelling" . (1.0 3.0 0.5 2.0))))
(define (rented-frag-profile spec)
  "The (lo hi alpha w) rented-fragility profile in force for SPEC — its own
   row in %rented-frag-profiles, else the shared %rented-frag-profile."
  (or (assoc-ref %rented-frag-profiles spec) %rented-frag-profile))
(define (rented-frag-tip spec)
  "quantile_alpha(lo,hi) of SPEC's profile — how many units of borrowed
   capacity a scope leans on before the wheel says it bites."
  (let ((p (rented-frag-profile spec)))
    (+ (list-ref p 0) (* (list-ref p 2) (- (list-ref p 1) (list-ref p 0))))))
;; the shared tip is the tip of any spec with no row of its own — ONE quantile
;; formula, read through the same seam every consumer uses
(define %rented-frag-tip (rented-frag-tip #f))

;; rented-goods — the Svc| service goods of every resource held under split tenure
;; (see resource-rented?), deduped. The rented family's goods as the wheel (and any
;; barrier) read them — the tenure counterpart to svc-eco-caps' capacity goods.
;; Base-Scheme only, so it loads wherever the schemas do.
(define* (rented-goods resources #:optional (scope #f))
  (let loop ((rs resources) (out '()))
    (if (null? rs)
        (reverse out)
        (let ((r (car rs)))
          (if (resource-rented? r scope)
              (let ((g (svc-good (economic-resource-conforms-to r))))
                (loop (cdr rs) (if (member g out) out (cons g out))))
              (loop (cdr rs) out))))))


;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVATION LAYER — Events
;; ═══════════════════════════════════════════════════════════════════════

;;; EconomicEvent — an observed, immutable economic fact.
;;; Events are the atoms of accounting. Resource state is derived from them.
;;; Fields: id (string), action (vf-action symbol),
;;;         input-of? (string: Process ID), output-of? (string: Process ID),
;;;         resource-inventoried-as? (string: EconomicResource ID),
;;;         to-resource-inventoried-as? (string: EconomicResource ID),
;;;         resource-conforms-to? (string: ResourceSpecification ID),
;;;         resource-classified-as? (list of strings),
;;;         provider? (string: Agent ID), receiver? (string: Agent ID),
;;;         resource-quantity? (<measure>), effort-quantity? (<measure>),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         has-point-in-time? (ISO datetime), created? (ISO datetime),
;;;         at-location? (string: SpatialThing ID),
;;;         to-location? (string: SpatialThing ID),
;;;         state? (string),
;;;         fulfills? (string: Commitment ID), satisfies? (string: Intent ID),
;;;         corrects? (string: EconomicEvent ID),
;;;         realization-of? (string: Agreement ID),
;;;         settles? (string: Claim ID),
;;;         note? (string), in-scope-of? (list of strings: Agent IDs),
;;;         previous-event? (string: EconomicEvent ID).
(define-vf-record <economic-event> EconomicEvent
  (id action input-of output-of resource-inventoried-as to-resource-inventoried-as resource-conforms-to resource-classified-as provider receiver resource-quantity effort-quantity has-beginning has-end has-point-in-time created at-location to-location state fulfills satisfies corrects realization-of settles note in-scope-of previous-event distribution-mode)
  #:register register-vf-record!)
  ;; distribution-mode: carried on the transfer — 'communal |
  ;; 'individual-claimable | #f. Promoted from the legacy
  ;; "individually-claimable" classifiedAs tag on the event.

;; Smart constructor: `distribution-mode` is keyword-only and last, so every
;; existing 29-positional call site (make-work-event / make-trip-event, etc.)
;; keeps working unchanged; serdes round-trips it via the raw constructor.
(define %make-economic-event
  (vf-record-constructor <economic-event>))
(define %economic-event (vf-record-maker <economic-event>))
;; an event as stated, settled: its distribution mode is the one stated or the
;; one its tags name, and the mode tags leave the classification
(define (%settle-economic-event e)
  (let* ((cls  (economic-event-resource-classified-as e))
         (mode (or (economic-event-distribution-mode e) (%mode-from-tags cls))))
    (copy-economic-event e
      #:resource-classified-as (if mode (%strip-mode-tags cls) cls)
      #:distribution-mode mode)))
(define (make-economic-event . args)
  "(make-economic-event #:id … #:action … #:resource-conforms-to …), settled."
  (%settle-economic-event (apply %economic-event args)))
;; distribution-mode lives in the FIELD. The smart constructors normalise a
;; legacy "communal"/"individually-claimable" classifiedAs tag INTO the field
;; (and strip it from classifiedAs) at construction — %mode-from-tags /
;; %strip-mode-tags are defined above the records for that — so reads here are
;; field-only. No tag is consulted at query time.
(define (resource-distribution-mode r) (economic-resource-distribution-mode r))
(define (event-distribution-mode e)    (economic-event-distribution-mode e))

;; The one functional update on an <economic-event>: copy-economic-resource's
;; sibling. Every field defaults to the record's own, so a field added to the
;; record is carried by every copy written over this. (An event is immutable once
;; recorded; a copy is a NEW event, as a correction is.)
(define copy-economic-event (vf-record-copier <economic-event>))


;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVATION LAYER — Processes
;; ═══════════════════════════════════════════════════════════════════════

;;; Process — an activity that transforms inputs into outputs.
;;; Fields: id (string), name (string), note? (string),
;;;         based-on? (string: ProcessSpecification ID),
;;;         classified-as? (list of strings),
;;;         planned-within? (string: Plan ID),
;;;         nested-in? (string: Scenario ID),
;;;         in-scope-of? (list of strings: Agent IDs),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         finished? (boolean).
(define-vf-record <process> Process
  (id name note based-on classified-as planned-within nested-in in-scope-of has-beginning has-end finished)
  #:register register-vf-record!)

(define make-process (vf-record-maker <process>))
(define copy-process (vf-record-copier <process>))


;; ═══════════════════════════════════════════════════════════════════════
;; PLANNING LAYER — Intents & Commitments
;; ═══════════════════════════════════════════════════════════════════════

;;; Intent — a unilateral desire/offer/request, not yet agreed to.
;;; Fields: id (string), action (vf-action symbol),
;;;         name? (string), note? (string), image? (string),
;;;         input-of? (string: Process ID), output-of? (string: Process ID),
;;;         resource-inventoried-as? (string: EconomicResource ID),
;;;         resource-conforms-to? (string: ResourceSpecification ID),
;;;         resource-classified-as? (list of strings),
;;;         resource-quantity? (<measure>), effort-quantity? (<measure>),
;;;         available-quantity? (<measure>), minimum-quantity? (<measure>),
;;;         provider? (string: Agent ID), receiver? (string: Agent ID),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         has-point-in-time? (ISO datetime), due? (ISO datetime),
;;;         at-location? (string: SpatialThing ID),
;;;         stage? (string: ProcessSpecification ID), state? (string),
;;;         planned-within? (string: Plan ID),
;;;         satisfies? (string: Intent ID),
;;;         in-scope-of? (list of strings: Agent IDs),
;;;         finished? (boolean),
;;;         availability-window? (temporal-expression).
(define-vf-record <intent> Intent
  (id action name note image input-of output-of resource-inventoried-as resource-conforms-to resource-classified-as resource-quantity effort-quantity available-quantity minimum-quantity provider receiver has-beginning has-end has-point-in-time due at-location stage state planned-within satisfies in-scope-of finished availability-window)
  #:register register-vf-record!)

(define make-intent (vf-record-maker <intent>))


;;; Commitment — a promised future event, agreed to by agents.
;;; Commitments satisfy Intents. Events fulfill Commitments.
;;; Fields: id (string), action (vf-action symbol), note? (string),
;;;         input-of? (string: Process ID), output-of? (string: Process ID),
;;;         resource-inventoried-as? (string: EconomicResource ID),
;;;         resource-conforms-to? (string: ResourceSpecification ID),
;;;         resource-classified-as? (list of strings),
;;;         resource-quantity? (<measure>), effort-quantity? (<measure>),
;;;         provider? (string: Agent ID), receiver? (string: Agent ID),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         has-point-in-time? (ISO datetime), due? (ISO datetime),
;;;         created? (ISO datetime),
;;;         at-location? (string: SpatialThing ID),
;;;         in-scope-of? (list of strings: Agent IDs),
;;;         stage? (string: ProcessSpecification ID), state? (string),
;;;         satisfies? (string: Intent ID),
;;;         clause-of? (string: Agreement ID),
;;;         independent-demand-of? (string: Plan ID),
;;;         planned-within? (string: Plan ID),
;;;         finished? (boolean),
;;;         availability-window? (temporal-expression).
(define-vf-record <commitment> Commitment
  (id action note input-of output-of resource-inventoried-as resource-conforms-to resource-classified-as resource-quantity effort-quantity provider receiver has-beginning has-end has-point-in-time due created at-location in-scope-of stage state satisfies clause-of independent-demand-of planned-within finished availability-window)
  #:register register-vf-record!)

(define make-commitment (vf-record-maker <commitment>))

(define copy-intent (vf-record-copier <intent>))

(define* (intent->commitment it id provider receiver
                             #:key (resource-conforms-to (intent-resource-conforms-to it)))
  "The one conversion of an <intent> into the <commitment> that would
   satisfy it — VF promotion's field map, shared by the promote door (the
   real commitment), the fresh check (a trial one) and the deployment's
   tentative bookings (a held offer as the commitment it would become),
   so the three can never disagree about which fields carry across. The
   commitment's `satisfies` is the intent; `clause-of`, `finished` and the
   timestamps are the caller's (#f here)."
  (make-commitment #:id id #:action (intent-action it)
                   #:input-of (intent-input-of it) #:output-of (intent-output-of it) #:resource-inventoried-as (intent-resource-inventoried-as it)
                   #:resource-conforms-to resource-conforms-to #:resource-classified-as (intent-resource-classified-as it)
                   #:resource-quantity (intent-resource-quantity it) #:effort-quantity (intent-effort-quantity it)
                   #:provider provider #:receiver receiver #:has-beginning (intent-has-beginning it) #:has-end (intent-has-end it)
                   #:has-point-in-time (intent-has-point-in-time it) #:due (intent-due it) #:at-location (intent-at-location it) #:in-scope-of (intent-in-scope-of it)
                   #:stage (intent-stage it) #:state (intent-state it) #:satisfies (intent-id it)
                   #:planned-within (intent-planned-within it) #:availability-window (intent-availability-window it)))

(define copy-commitment (vf-record-copier <commitment>))


;;; Claim — triggered by an event, resembles a Commitment but initiated by receiver.
;;; Fields: id (string), action (vf-action symbol),
;;;         provider? (string: Agent ID), receiver? (string: Agent ID),
;;;         triggered-by? (string: EconomicEvent ID),
;;;         resource-quantity? (<measure>), effort-quantity? (<measure>),
;;;         resource-conforms-to? (string: ResourceSpecification ID),
;;;         resource-classified-as? (list of strings),
;;;         due? (ISO datetime), created? (ISO datetime),
;;;         note? (string), finished? (boolean).
(define-vf-record <claim> Claim
  (id action provider receiver triggered-by resource-quantity effort-quantity resource-conforms-to resource-classified-as due created note finished)
  #:register register-vf-record!)

(define make-claim (vf-record-maker <claim>))


;; ═══════════════════════════════════════════════════════════════════════
;; PLANNING LAYER — Plans
;; ═══════════════════════════════════════════════════════════════════════

;;; Plan — a schedule of related processes constituting a body of work.
;;; Fields: id (string), name (string), note? (string),
;;;         due? (ISO datetime), created? (ISO datetime),
;;;         has-independent-demand? (list of strings: Commitment/Intent IDs),
;;;         refinement-of? (string: Scenario ID),
;;;         classified-as? (list of strings).
(define-vf-record <plan> Plan
  (id name note due created has-independent-demand refinement-of classified-as)
  #:register register-vf-record!)

(define make-plan (vf-record-maker <plan>))


;; ═══════════════════════════════════════════════════════════════════════
;; ESTIMATION / ANALYSIS LAYER — Scenarios
;; ═══════════════════════════════════════════════════════════════════════

;;; ScenarioDefinition — a named category or template for a kind of scenario.
;;; Fields: id (string), name (string), note? (string),
;;;         has-duration? (<duration>), in-scope-of? (string: Agent ID).
(define-vf-record <scenario-definition> ScenarioDefinition
  (id name note has-duration in-scope-of)
  #:register register-vf-record!)

(define make-scenario-definition (vf-record-maker <scenario-definition>))


;;; Scenario — a grouping of processes, intents, plans for analysis/budgeting.
;;; Fields: id (string), name (string), note? (string),
;;;         defined-as? (string: ScenarioDefinition ID),
;;;         refinement-of? (string: Scenario ID),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         in-scope-of? (string: Agent ID).
(define-vf-record <scenario> Scenario
  (id name note defined-as refinement-of has-beginning has-end in-scope-of)
  #:register register-vf-record!)

(define make-scenario (vf-record-maker <scenario>))


;; ═══════════════════════════════════════════════════════════════════════
;; AGREEMENTS & EXCHANGES
;; ═══════════════════════════════════════════════════════════════════════

;;; Agreement — a mutual agreement between agents.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime),
;;;         stipulates? (list of strings: primary Commitment IDs),
;;;         stipulates-reciprocal? (list of strings: reciprocal Commitment IDs).
(define-vf-record <agreement> Agreement
  (id name note created stipulates stipulates-reciprocal)
  #:register register-vf-record!)

(define make-agreement (vf-record-maker <agreement>))


;;; AgreementBundle — groups multiple Agreements.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), bundles? (list of strings: Agreement IDs).
(define-vf-record <agreement-bundle> AgreementBundle
  (id name note created bundles)
  #:register register-vf-record!)

(define make-agreement-bundle (vf-record-maker <agreement-bundle>))


;; ═══════════════════════════════════════════════════════════════════════
;; PROPOSALS — Offers & Requests
;; ═══════════════════════════════════════════════════════════════════════

;;; Proposal — an offer or request containing published intents.
;;; Fields: id (string), name? (string), note? (string),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         unit-based? (boolean), created? (ISO datetime),
;;;         purpose? (symbol: offer | request),
;;;         eligible-location? (string: SpatialThing ID),
;;;         in-scope-of? (list of strings: Agent IDs),
;;;         publishes? (list of strings: Intent IDs),
;;;         reciprocal? (list of strings: Intent IDs),
;;;         proposed-to? (list of strings: Agent IDs).
(define-vf-record <proposal> Proposal
  (id name note has-beginning has-end unit-based created purpose eligible-location in-scope-of publishes reciprocal proposed-to)
  #:register register-vf-record!)

(define make-proposal (vf-record-maker <proposal>))


;;; ProposalList — groups multiple Proposals.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), lists? (list of strings: Proposal IDs).
(define-vf-record <proposal-list> ProposalList
  (id name note created lists)
  #:register register-vf-record!)

(define make-proposal-list (vf-record-maker <proposal-list>))
