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
;;; tests/planner/vf-conformance-classes-test.scm holds the file to the TTL both
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
;;; `(use-modules (playnet planner))` still sees them.

(define-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier vf-record-maker))
  #:export (<measure> make-measure measure? measure-has-numerical-value measure-has-unit
            <duration> make-duration duration? duration-has-numerical-value
            duration-has-unit <unit> make-unit unit? unit-id unit-label unit-symbol
            unit-classified-as <spatial-thing> %make-spatial-thing make-spatial-thing
            spatial-thing? spatial-thing-id spatial-thing-name spatial-thing-note
            spatial-thing-lat spatial-thing-long spatial-thing-alt
            spatial-thing-mappable-address spatial-thing-contained-in
            spatial-thing-boundary *vf-actions* vf-action? *quantity-effects*
            quantity-effect? *property-effects* property-effect? <action-definition>
            make-action-definition action-definition? action-definition-event-quantity
            action-definition-input-output action-definition-pairs-with
            
            action-definition-create-resource
            action-definition-accounting-effect action-definition-onhand-effect
            action-definition-location-effect action-definition-contained-effect
            action-definition-accountable-effect action-definition-stage-effect
            action-definition-state-effect action-definition-implies-transfer
            action-definition-eligible-for-exchange *action-definitions* get-action-def
            measure-qty *agent-types* agent-type? <agent>
            make-agent agent? agent-id agent-type agent-name agent-note agent-image
            agent-primary-location agent-classified-as agent-availability-window
            <agent-relationship-role> make-agent-relationship-role
            agent-relationship-role? agent-relationship-role-id
            agent-relationship-role-label agent-relationship-role-inverse-label
            agent-relationship-role-note agent-relationship-role-classified-as
            <agent-relationship> make-agent-relationship agent-relationship?
            agent-relationship-id agent-relationship-subject agent-relationship-object
            agent-relationship-relationship agent-relationship-in-scope-of
            agent-relationship-note <resource-specification> %make-resource-specification
            make-resource-specification copy-resource-specification resource-specification? resource-specification-id
            resource-specification-name resource-specification-note
            resource-specification-image resource-specification-resource-classified-as
            resource-specification-keep-in-place resource-spec-keep-in-place?
            resource-specification-composition resource-specification-with-composition
            resource-specification-default-unit-of-resource specs->units
            resource-specification-default-unit-of-effort
            resource-specification-substitutable
            resource-specification-medium-of-exchange
            resource-specification-buffer-profile-id
            resource-specification-positioning-analysis
            resource-specification-satisfied-by <process-specification>
            make-process-specification process-specification? process-specification-id
            process-specification-name process-specification-note
            process-specification-image process-specification-is-decoupling-point
            process-specification-is-control-point process-specification-buffer-type
            process-specification-is-divergent-point
            process-specification-is-convergent-point <recipe-flow> make-recipe-flow
            recipe-flow? recipe-flow-id recipe-flow-action
            recipe-flow-resource-conforms-to recipe-flow-resource-classified-as
            recipe-flow-resource-quantity recipe-flow-effort-quantity
            recipe-flow-recipe-input-of recipe-flow-recipe-output-of
            recipe-flow-recipe-clause-of recipe-flow-stage recipe-flow-state
            recipe-flow-note recipe-flow-is-primary recipe-flow-resolve-from-flow copy-recipe-flow
            <recipe-process> make-recipe-process recipe-process? recipe-process-id
            recipe-process-name recipe-process-note recipe-process-image
            recipe-process-process-conforms-to recipe-process-process-classified-as
            recipe-process-has-duration recipe-process-sequence-group
            recipe-process-minimum-batch-quantity <recipe-exchange> make-recipe-exchange
            recipe-exchange? recipe-exchange-id recipe-exchange-name recipe-exchange-note
            <recipe> make-recipe recipe? recipe-id recipe-name recipe-note
            recipe-based-on recipe-primary-output recipe-recipe-processes
            recipe-recipe-exchanges <recipe-group> make-recipe-group recipe-group?
            recipe-group-id recipe-group-name recipe-group-note recipe-group-recipes
            <economic-resource> %mode-from-tags %strip-mode-tags %make-economic-resource
            make-economic-resource copy-economic-resource economic-resource?
            economic-resource-id economic-resource-name economic-resource-note
            economic-resource-image economic-resource-tracking-identifier
            economic-resource-conforms-to economic-resource-classified-as
            economic-resource-distribution-mode economic-resource-accounting-quantity
            economic-resource-onhand-quantity economic-resource-current-location
            economic-resource-current-virtual-location
            economic-resource-primary-accountable economic-resource-custodian-scope
            economic-resource-stage economic-resource-state
            economic-resource-contained-in economic-resource-unit-of-effort
            economic-resource-lot economic-resource-previous-event
            economic-resource-availability-window resource-rented? resource-sovereign?
            %rented-frag-profile %rented-frag-profiles rented-frag-profile
            rented-frag-tip %rented-frag-tip rented-goods <economic-event>
            %make-economic-event make-economic-event economic-event? economic-event-id
            economic-event-action economic-event-input-of economic-event-output-of
            economic-event-resource-inventoried-as
            economic-event-to-resource-inventoried-as economic-event-resource-conforms-to
            economic-event-resource-classified-as economic-event-distribution-mode
            resource-distribution-mode event-distribution-mode economic-event-provider
            economic-event-receiver economic-event-resource-quantity
            economic-event-effort-quantity economic-event-has-beginning
            economic-event-has-end economic-event-has-point-in-time
            economic-event-created economic-event-at-location economic-event-to-location
            economic-event-state economic-event-fulfills economic-event-satisfies
            economic-event-corrects economic-event-realization-of economic-event-settles
            economic-event-note economic-event-in-scope-of economic-event-previous-event
            copy-economic-event <process> make-process process? process-id process-name
            process-note process-based-on process-classified-as process-planned-within
            process-nested-in process-in-scope-of process-has-beginning process-has-end
            process-finished <intent> make-intent intent? intent-id intent-action
            intent-name intent-note intent-image intent-input-of intent-output-of
            intent-resource-inventoried-as intent-resource-conforms-to
            intent-resource-classified-as intent-resource-quantity intent-effort-quantity
            intent-available-quantity intent-minimum-quantity intent-provider
            intent-receiver intent-has-beginning intent-has-end intent-has-point-in-time
            intent-due intent-at-location intent-stage intent-state intent-planned-within
            intent-satisfies intent-in-scope-of intent-finished
            intent-availability-window copy-intent intent->commitment <commitment>
            make-commitment commitment? commitment-id commitment-action commitment-note
            commitment-input-of commitment-output-of commitment-resource-inventoried-as
            commitment-resource-conforms-to commitment-resource-classified-as
            commitment-resource-quantity commitment-effort-quantity commitment-provider
            commitment-receiver commitment-has-beginning commitment-has-end
            commitment-has-point-in-time commitment-due commitment-created
            commitment-at-location commitment-in-scope-of commitment-stage
            commitment-state commitment-satisfies commitment-clause-of
            commitment-independent-demand-of commitment-planned-within
            commitment-finished commitment-availability-window copy-commitment <claim>
            make-claim claim? claim-id claim-action claim-provider claim-receiver
            claim-triggered-by claim-resource-quantity claim-effort-quantity
            claim-resource-conforms-to claim-resource-classified-as claim-due
            claim-created claim-note claim-finished <plan> make-plan plan? plan-id
            plan-name plan-note plan-due plan-created plan-has-independent-demand
            plan-refinement-of plan-classified-as <scenario-definition>
            make-scenario-definition scenario-definition? scenario-definition-id
            scenario-definition-name scenario-definition-note
            scenario-definition-has-duration scenario-definition-in-scope-of <scenario>
            make-scenario scenario? scenario-id scenario-name scenario-note
            scenario-defined-as scenario-refinement-of scenario-has-beginning
            scenario-has-end scenario-in-scope-of <agreement> make-agreement agreement?
            agreement-id agreement-name agreement-note agreement-created
            agreement-stipulates agreement-stipulates-reciprocal <agreement-bundle>
            make-agreement-bundle agreement-bundle? agreement-bundle-id
            agreement-bundle-name agreement-bundle-note agreement-bundle-created
            agreement-bundle-bundles <proposal> make-proposal proposal? proposal-id
            proposal-name proposal-note proposal-has-beginning proposal-has-end
            proposal-unit-based proposal-created proposal-purpose
            proposal-eligible-location proposal-in-scope-of proposal-publishes
            proposal-reciprocal proposal-proposed-to <proposal-list> make-proposal-list
            proposal-list? proposal-list-id proposal-list-name proposal-list-note
            proposal-list-created proposal-list-lists))

;; ═══════════════════════════════════════════════════════════════════════
;; PRIMITIVES
;; ═══════════════════════════════════════════════════════════════════════

;;; Measure — a quantity with a unit.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "kg", "hours", OM2 URI).
(define <measure>
  (vf-record-type 'Measure
    '((immutable has-numerical-value)
      (immutable has-unit))))

(define make-measure                   (vf-record-constructor <measure>))
(define measure?                       (vf-record-predicate   <measure>))
(define measure-has-numerical-value    (vf-record-accessor    <measure> 'has-numerical-value))
(define measure-has-unit               (vf-record-accessor    <measure> 'has-unit))


;;; Duration — time span for processes and recipes.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "hours", "days").
(define <duration>
  (vf-record-type 'Duration
    '((immutable has-numerical-value)
      (immutable has-unit))))

(define make-duration                   (vf-record-constructor <duration>))
(define duration?                       (vf-record-predicate   <duration>))
(define duration-has-numerical-value    (vf-record-accessor    <duration> 'has-numerical-value))
(define duration-has-unit               (vf-record-accessor    <duration> 'has-unit))


;;; Unit — measurement unit definition.
;;; Fields: id (string), label (string), symbol (string),
;;;         classified-as (optional: list of strings | #f).
(define <unit>
  (vf-record-type 'Unit
    '((immutable id)
      (immutable label)
      (immutable symbol)
      (immutable classified-as))))

(define make-unit              (vf-record-constructor <unit>))
(define unit?                  (vf-record-predicate   <unit>))
(define unit-id                (vf-record-accessor    <unit> 'id))
(define unit-label             (vf-record-accessor    <unit> 'label))
(define unit-symbol            (vf-record-accessor    <unit> 'symbol))
(define unit-classified-as     (vf-record-accessor    <unit> 'classified-as))


;;; SpatialThing — a location in space.
;;; Fields: id (string), name? (string), note? (string),
;;;         lat? (number), long? (number), alt? (number),
;;;         mappable-address? (string), contained-in? (string — parent SpatialThing ID).
(define <spatial-thing>
  (vf-record-type 'SpatialThing
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable lat)
      (immutable long)
      (immutable alt)
      (immutable mappable-address)
      (immutable contained-in)
      (immutable boundary))))     ; GeoJSON geometry (Polygon/MultiPolygon) or #f — the EXTENT

;; A SpatialThing spatializes as GeoJSON. By default it is a POINT (lat/long) — a farm,
;; a venue. When `boundary` is set (a GeoJSON geometry: real, concave, ridgeline-
;; following), it is a REGION — an ecoregion/bioregion/watershed. So point and polygon
;; are one ontology; the map draws whichever the thing carries (browser containers.js),
;; and containment can be DERIVED by point-in-polygon (a farm sits in the shed whose
;; boundary holds it). `boundary` is optional, so every existing 8-arg call is unchanged.
(define %make-spatial-thing                 (vf-record-constructor <spatial-thing>))
(define make-spatial-thing (vf-record-maker <spatial-thing>))
(define spatial-thing?                      (vf-record-predicate   <spatial-thing>))
(define spatial-thing-id                    (vf-record-accessor    <spatial-thing> 'id))
(define spatial-thing-name                  (vf-record-accessor    <spatial-thing> 'name))
(define spatial-thing-note                  (vf-record-accessor    <spatial-thing> 'note))
(define spatial-thing-lat                   (vf-record-accessor    <spatial-thing> 'lat))
(define spatial-thing-long                  (vf-record-accessor    <spatial-thing> 'long))
(define spatial-thing-alt                   (vf-record-accessor    <spatial-thing> 'alt))
(define spatial-thing-mappable-address      (vf-record-accessor    <spatial-thing> 'mappable-address))
(define spatial-thing-contained-in          (vf-record-accessor    <spatial-thing> 'contained-in))
(define spatial-thing-boundary              (vf-record-accessor    <spatial-thing> 'boundary))


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
(define <action-definition>
  (vf-record-type 'ActionDefinition
    '((immutable event-quantity)
      (immutable input-output)
      (immutable pairs-with)
      (immutable create-resource)
      (immutable accounting-effect)
      (immutable onhand-effect)
      (immutable location-effect)
      (immutable contained-effect)
      (immutable accountable-effect)
      (immutable stage-effect)
      (immutable state-effect)
      (immutable implies-transfer)
      (immutable eligible-for-exchange))))

(define make-action-definition (vf-record-maker <action-definition>))
(define action-definition?
  (vf-record-predicate <action-definition>))
(define action-definition-event-quantity
  (vf-record-accessor <action-definition> 'event-quantity))
(define action-definition-input-output
  (vf-record-accessor <action-definition> 'input-output))
(define action-definition-pairs-with
  (vf-record-accessor <action-definition> 'pairs-with))
(define action-definition-create-resource
  (vf-record-accessor <action-definition> 'create-resource))
(define action-definition-accounting-effect
  (vf-record-accessor <action-definition> 'accounting-effect))
(define action-definition-onhand-effect
  (vf-record-accessor <action-definition> 'onhand-effect))
(define action-definition-location-effect
  (vf-record-accessor <action-definition> 'location-effect))
(define action-definition-contained-effect
  (vf-record-accessor <action-definition> 'contained-effect))
(define action-definition-accountable-effect
  (vf-record-accessor <action-definition> 'accountable-effect))
(define action-definition-stage-effect
  (vf-record-accessor <action-definition> 'stage-effect))
(define action-definition-state-effect
  (vf-record-accessor <action-definition> 'state-effect))
(define action-definition-implies-transfer
  (vf-record-accessor <action-definition> 'implies-transfer))
(define action-definition-eligible-for-exchange
  (vf-record-accessor <action-definition> 'eligible-for-exchange))

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
(define <agent>
  (vf-record-type 'Agent
    '((immutable id)
      (immutable type)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable primary-location)
      (immutable classified-as)
      (immutable availability-window))))

(define make-agent (vf-record-maker <agent>))
(define agent?                          (vf-record-predicate   <agent>))
(define agent-id                        (vf-record-accessor    <agent> 'id))
(define agent-type                      (vf-record-accessor    <agent> 'type))
(define agent-name                      (vf-record-accessor    <agent> 'name))
(define agent-note                      (vf-record-accessor    <agent> 'note))
(define agent-image                     (vf-record-accessor    <agent> 'image))
(define agent-primary-location          (vf-record-accessor    <agent> 'primary-location))
(define agent-classified-as             (vf-record-accessor    <agent> 'classified-as))
(define agent-availability-window       (vf-record-accessor    <agent> 'availability-window))


;;; AgentRelationshipRole — a named role an agent plays relative to another.
;;; Fields: id (string), label (string), inverse-label? (string),
;;;         note? (string), classified-as? (list of strings).
(define <agent-relationship-role>
  (vf-record-type 'AgentRelationshipRole
    '((immutable id)
      (immutable label)
      (immutable inverse-label)
      (immutable note)
      (immutable classified-as))))

(define make-agent-relationship-role (vf-record-maker <agent-relationship-role>))
(define agent-relationship-role?
  (vf-record-predicate <agent-relationship-role>))
(define agent-relationship-role-id
  (vf-record-accessor <agent-relationship-role> 'id))
(define agent-relationship-role-label
  (vf-record-accessor <agent-relationship-role> 'label))
(define agent-relationship-role-inverse-label
  (vf-record-accessor <agent-relationship-role> 'inverse-label))
(define agent-relationship-role-note
  (vf-record-accessor <agent-relationship-role> 'note))
(define agent-relationship-role-classified-as
  (vf-record-accessor <agent-relationship-role> 'classified-as))


;;; AgentRelationship — a directed relationship between two agents.
;;; subject plays relationship (role) toward object.
;;; Fields: id (string), subject (string: Agent ID), object (string: Agent ID),
;;;         relationship (string: AgentRelationshipRole ID),
;;;         in-scope-of? (string: Agent ID), note? (string).
(define <agent-relationship>
  (vf-record-type 'AgentRelationship
    '((immutable id)
      (immutable subject)
      (immutable object)
      (immutable relationship)
      (immutable in-scope-of)
      (immutable note))))

(define make-agent-relationship (vf-record-maker <agent-relationship>))
(define agent-relationship?
  (vf-record-predicate <agent-relationship>))
(define agent-relationship-id
  (vf-record-accessor <agent-relationship> 'id))
(define agent-relationship-subject
  (vf-record-accessor <agent-relationship> 'subject))
(define agent-relationship-object
  (vf-record-accessor <agent-relationship> 'object))
(define agent-relationship-relationship
  (vf-record-accessor <agent-relationship> 'relationship))
(define agent-relationship-in-scope-of
  (vf-record-accessor <agent-relationship> 'in-scope-of))
(define agent-relationship-note
  (vf-record-accessor <agent-relationship> 'note))


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
(define <resource-specification>
  (vf-record-type 'ResourceSpecification
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable resource-classified-as)
      (immutable default-unit-of-resource)
      (immutable default-unit-of-effort)
      (immutable substitutable)
      (immutable medium-of-exchange)
      (immutable buffer-profile-id)
      (immutable positioning-analysis)
      ;; satisfied-by (skills): the substitution/equivalence relation. A DNF —
      ;; a list of CLAUSES, each clause a list of (component-skill . min-hours).
      ;; An agent CONFORMS to this spec if it holds the spec directly OR holds
      ;; every component of SOME clause at ≥ its min validated hours. '() / #f =
      ;; direct conformance only. This is what lets {electrician,surgeon} satisfy
      ;; an electrosurgery requirement without holding "electrosurgeon" directly.
      (immutable satisfied-by)
      ;; keep-in-place: a container whose `use` relocates its contents through
      ;; TIME (storage) rather than space (transport) — drives proc-temporal? /
      ;; arc-scale. Promoted from the legacy "stationary" classifiedAs tag, and
      ;; the promotion is COMPLETE: the smart constructor below folds any such
      ;; tag into this field and strips it, so the field is the only thing read.
      (immutable keep-in-place)
      ;; composition: what one unit of this spec CARRIES, stated by the scope that
      ;; holds it — ((leaf . amount) …) in knowledge/catalogues/substances.scm's grammar (an
      ;; element's mass fraction, "heat" in kWh, "entropy" in kWh/K). A warmed form
      ;; states its excess here (knowledge/thermal.scm); the recipe store hands
      ;; every stated row to the solve and the lint in front of the fallback table.
      ;; '() / #f = nothing stated: the table or a recipe's derivation speaks.
      (immutable composition))))

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
(define resource-specification?
  (vf-record-predicate <resource-specification>))
(define resource-specification-id
  (vf-record-accessor <resource-specification> 'id))
(define resource-specification-name
  (vf-record-accessor <resource-specification> 'name))
(define resource-specification-note
  (vf-record-accessor <resource-specification> 'note))
(define resource-specification-image
  (vf-record-accessor <resource-specification> 'image))
(define resource-specification-resource-classified-as
  (vf-record-accessor <resource-specification> 'resource-classified-as))
(define resource-specification-keep-in-place
  (vf-record-accessor <resource-specification> 'keep-in-place))
(define resource-specification-composition
  (vf-record-accessor <resource-specification> 'composition))
(define (resource-specification-with-composition spec composition)
  "SPEC with COMPOSITION stated on it and every other field as it was: the one
   place a specification is copied to change what it carries."
  (make-resource-specification
   #:id (resource-specification-id spec) #:name (resource-specification-name spec)
   #:note (resource-specification-note spec) #:image (resource-specification-image spec)
   #:resource-classified-as (resource-specification-resource-classified-as spec)
   #:default-unit-of-resource (resource-specification-default-unit-of-resource spec) #:default-unit-of-effort (resource-specification-default-unit-of-effort spec)
   #:substitutable (resource-specification-substitutable spec) #:medium-of-exchange (resource-specification-medium-of-exchange spec)
   #:buffer-profile-id (resource-specification-buffer-profile-id spec) #:positioning-analysis (resource-specification-positioning-analysis spec)
   #:satisfied-by (resource-specification-satisfied-by spec)
   #:keep-in-place (resource-specification-keep-in-place spec)
   #:composition composition))
;; Field-only read — the constructor normalises any legacy "stationary" tag
;; into keep-in-place at construction, so no tag is consulted at query time.
(define (resource-spec-keep-in-place? s)
  (and (resource-specification-keep-in-place s) #t))
(define resource-specification-default-unit-of-resource
  (vf-record-accessor <resource-specification> 'default-unit-of-resource))
(define resource-specification-default-unit-of-effort
  (vf-record-accessor <resource-specification> 'default-unit-of-effort))
(define (specs->units specs)
  "The unit each of SPECS counts in, ((spec-id . unit) …): the specification's own
   default-unit-of-resource, for every spec that states one."
  (filter-map (lambda (sp) (and=> (resource-specification-default-unit-of-resource sp)
                                  (lambda (u) (cons (resource-specification-id sp) u))))
              specs))
(define resource-specification-substitutable
  (vf-record-accessor <resource-specification> 'substitutable))
(define resource-specification-medium-of-exchange
  (vf-record-accessor <resource-specification> 'medium-of-exchange))
(define resource-specification-buffer-profile-id
  (vf-record-accessor <resource-specification> 'buffer-profile-id))
(define resource-specification-positioning-analysis
  (vf-record-accessor <resource-specification> 'positioning-analysis))
(define resource-specification-satisfied-by
  (vf-record-accessor <resource-specification> 'satisfied-by))


;;; ProcessSpecification — the "type" of a process.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         is-decoupling-point? (boolean), is-control-point? (boolean),
;;;         buffer-type? (symbol: stock | time | capacity),
;;;         is-divergent-point? (boolean), is-convergent-point? (boolean).
(define <process-specification>
  (vf-record-type 'ProcessSpecification
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable is-decoupling-point)
      (immutable is-control-point)
      (immutable buffer-type)
      (immutable is-divergent-point)
      (immutable is-convergent-point))))

(define make-process-specification (vf-record-maker <process-specification>))
(define process-specification?
  (vf-record-predicate <process-specification>))
(define process-specification-id
  (vf-record-accessor <process-specification> 'id))
(define process-specification-name
  (vf-record-accessor <process-specification> 'name))
(define process-specification-note
  (vf-record-accessor <process-specification> 'note))
(define process-specification-image
  (vf-record-accessor <process-specification> 'image))
(define process-specification-is-decoupling-point
  (vf-record-accessor <process-specification> 'is-decoupling-point))
(define process-specification-is-control-point
  (vf-record-accessor <process-specification> 'is-control-point))
(define process-specification-buffer-type
  (vf-record-accessor <process-specification> 'buffer-type))
(define process-specification-is-divergent-point
  (vf-record-accessor <process-specification> 'is-divergent-point))
(define process-specification-is-convergent-point
  (vf-record-accessor <process-specification> 'is-convergent-point))


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
(define <recipe-flow>
  (vf-record-type 'RecipeFlow
    '((immutable id)
      (immutable action)
      (immutable resource-conforms-to)
      (immutable resource-classified-as)
      (immutable resource-quantity)
      (immutable effort-quantity)
      (immutable recipe-input-of)
      (immutable recipe-output-of)
      (immutable recipe-clause-of)
      (immutable stage)
      (immutable state)
      (immutable note)
      (immutable is-primary)
      (immutable resolve-from-flow))))

(define make-recipe-flow (vf-record-maker <recipe-flow>))
(define recipe-flow?
  (vf-record-predicate <recipe-flow>))
(define recipe-flow-id
  (vf-record-accessor <recipe-flow> 'id))
(define recipe-flow-action
  (vf-record-accessor <recipe-flow> 'action))
(define recipe-flow-resource-conforms-to
  (vf-record-accessor <recipe-flow> 'resource-conforms-to))
(define recipe-flow-resource-classified-as
  (vf-record-accessor <recipe-flow> 'resource-classified-as))
(define recipe-flow-resource-quantity
  (vf-record-accessor <recipe-flow> 'resource-quantity))
(define recipe-flow-effort-quantity
  (vf-record-accessor <recipe-flow> 'effort-quantity))
(define recipe-flow-recipe-input-of
  (vf-record-accessor <recipe-flow> 'recipe-input-of))
(define recipe-flow-recipe-output-of
  (vf-record-accessor <recipe-flow> 'recipe-output-of))
(define recipe-flow-recipe-clause-of
  (vf-record-accessor <recipe-flow> 'recipe-clause-of))
(define recipe-flow-stage
  (vf-record-accessor <recipe-flow> 'stage))
(define recipe-flow-state
  (vf-record-accessor <recipe-flow> 'state))
(define recipe-flow-note
  (vf-record-accessor <recipe-flow> 'note))
(define recipe-flow-is-primary
  (vf-record-accessor <recipe-flow> 'is-primary))
(define recipe-flow-resolve-from-flow
  (vf-record-accessor <recipe-flow> 'resolve-from-flow))
(define copy-recipe-flow (vf-record-copier <recipe-flow>))


;;; RecipeProcess — a template process step in a recipe.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         process-conforms-to? (string: ProcessSpecification ID),
;;;         process-classified-as? (list of strings),
;;;         has-duration? (<duration>),
;;;         sequence-group? (integer),
;;;         minimum-batch-quantity? (<measure>).
(define <recipe-process>
  (vf-record-type 'RecipeProcess
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable process-conforms-to)
      (immutable process-classified-as)
      (immutable has-duration)
      (immutable sequence-group)
      (immutable minimum-batch-quantity))))

(define make-recipe-process (vf-record-maker <recipe-process>))
(define recipe-process?
  (vf-record-predicate <recipe-process>))
(define recipe-process-id
  (vf-record-accessor <recipe-process> 'id))
(define recipe-process-name
  (vf-record-accessor <recipe-process> 'name))
(define recipe-process-note
  (vf-record-accessor <recipe-process> 'note))
(define recipe-process-image
  (vf-record-accessor <recipe-process> 'image))
(define recipe-process-process-conforms-to
  (vf-record-accessor <recipe-process> 'process-conforms-to))
(define recipe-process-process-classified-as
  (vf-record-accessor <recipe-process> 'process-classified-as))
(define recipe-process-has-duration
  (vf-record-accessor <recipe-process> 'has-duration))
(define recipe-process-sequence-group
  (vf-record-accessor <recipe-process> 'sequence-group))
(define recipe-process-minimum-batch-quantity
  (vf-record-accessor <recipe-process> 'minimum-batch-quantity))


;;; RecipeExchange — a template exchange agreement in a recipe.
;;; Fields: id (string), name? (string), note? (string).
(define <recipe-exchange>
  (vf-record-type 'RecipeExchange
    '((immutable id)
      (immutable name)
      (immutable note))))

(define make-recipe-exchange (vf-record-maker <recipe-exchange>))
(define recipe-exchange?
  (vf-record-predicate <recipe-exchange>))
(define recipe-exchange-id
  (vf-record-accessor <recipe-exchange> 'id))
(define recipe-exchange-name
  (vf-record-accessor <recipe-exchange> 'name))
(define recipe-exchange-note
  (vf-record-accessor <recipe-exchange> 'note))


;;; Recipe — groups RecipeProcesses and RecipeExchanges into a reusable template.
;;; Fields: id (string), name (string), note? (string),
;;;         based-on? (string: ResourceSpecification ID),
;;;         primary-output? (string: ResourceSpecification ID),
;;;         recipe-processes? (list of strings: RecipeProcess IDs),
;;;         recipe-exchanges? (list of strings: RecipeExchange IDs).
(define <recipe>
  (vf-record-type 'Recipe
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable based-on)
      (immutable primary-output)
      (immutable recipe-processes)
      (immutable recipe-exchanges))))

(define make-recipe (vf-record-maker <recipe>))
(define recipe?                  (vf-record-predicate   <recipe>))
(define recipe-id                (vf-record-accessor    <recipe> 'id))
(define recipe-name              (vf-record-accessor    <recipe> 'name))
(define recipe-note              (vf-record-accessor    <recipe> 'note))
(define recipe-based-on          (vf-record-accessor    <recipe> 'based-on))
(define recipe-primary-output    (vf-record-accessor    <recipe> 'primary-output))
(define recipe-recipe-processes  (vf-record-accessor    <recipe> 'recipe-processes))
(define recipe-recipe-exchanges  (vf-record-accessor    <recipe> 'recipe-exchanges))


;;; RecipeGroup — groups multiple Recipes that together produce more than one output.
;;; Fields: id (string), name (string), note? (string),
;;;         recipes (list of strings: Recipe IDs).
(define <recipe-group>
  (vf-record-type 'RecipeGroup
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable recipes))))

(define make-recipe-group (vf-record-maker <recipe-group>))
(define recipe-group?          (vf-record-predicate   <recipe-group>))
(define recipe-group-id        (vf-record-accessor    <recipe-group> 'id))
(define recipe-group-name      (vf-record-accessor    <recipe-group> 'name))
(define recipe-group-note      (vf-record-accessor    <recipe-group> 'note))
(define recipe-group-recipes   (vf-record-accessor    <recipe-group> 'recipes))


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
(define <economic-resource>
  (vf-record-type 'EconomicResource
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable tracking-identifier)
      (immutable conforms-to)
      (immutable classified-as)
      (immutable accounting-quantity)
      (immutable onhand-quantity)
      (immutable current-location)
      (immutable current-virtual-location)
      (immutable primary-accountable)
      (immutable custodian-scope)
      (immutable stage)
      (immutable state)
      (immutable contained-in)
      (immutable unit-of-effort)
      (immutable lot)
      (immutable previous-event)
      (immutable availability-window)
      ;; distribution-mode: 'communal | 'individual-claimable | #f — import
      ;; vocabulary, normalised from the legacy "communal"/"individually-claimable"
      ;; classifiedAs tag, and provenance on the events a claim writes. The rail
      ;; a good is actually on is read off the recipes (rail.scm rails-of,
      ;; published by the plan): a claim recipe for someone puts it on the
      ;; individual rail, the scope's own consumption keeps it communal, `use`
      ;; makes it a means, and a made good that is nobody's input is individual.
      ;; This field decides nothing; the accountability invariant (communal ⟹
      ;; accountable = commune) checks the published rail (algorithms/custody.scm).
      (immutable distribution-mode))))

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
(define economic-resource?
  (vf-record-predicate <economic-resource>))

;; The one functional update on an <economic-resource> — copy-commitment's
;; sibling: every field defaults to the record's own, and a field added to the
;; record is carried by every setter written over this.
(define copy-economic-resource (vf-record-copier <economic-resource>))
(define economic-resource-id
  (vf-record-accessor <economic-resource> 'id))
(define economic-resource-name
  (vf-record-accessor <economic-resource> 'name))
(define economic-resource-note
  (vf-record-accessor <economic-resource> 'note))
(define economic-resource-image
  (vf-record-accessor <economic-resource> 'image))
(define economic-resource-tracking-identifier
  (vf-record-accessor <economic-resource> 'tracking-identifier))
(define economic-resource-conforms-to
  (vf-record-accessor <economic-resource> 'conforms-to))
(define economic-resource-classified-as
  (vf-record-accessor <economic-resource> 'classified-as))
(define economic-resource-distribution-mode
  (vf-record-accessor <economic-resource> 'distribution-mode))
(define economic-resource-accounting-quantity
  (vf-record-accessor <economic-resource> 'accounting-quantity))
(define economic-resource-onhand-quantity
  (vf-record-accessor <economic-resource> 'onhand-quantity))
(define economic-resource-current-location
  (vf-record-accessor <economic-resource> 'current-location))
(define economic-resource-current-virtual-location
  (vf-record-accessor <economic-resource> 'current-virtual-location))
(define economic-resource-primary-accountable
  (vf-record-accessor <economic-resource> 'primary-accountable))
(define economic-resource-custodian-scope
  (vf-record-accessor <economic-resource> 'custodian-scope))
(define economic-resource-stage
  (vf-record-accessor <economic-resource> 'stage))
(define economic-resource-state
  (vf-record-accessor <economic-resource> 'state))
(define economic-resource-contained-in
  (vf-record-accessor <economic-resource> 'contained-in))
(define economic-resource-unit-of-effort
  (vf-record-accessor <economic-resource> 'unit-of-effort))
(define economic-resource-lot
  (vf-record-accessor <economic-resource> 'lot))
(define economic-resource-previous-event
  (vf-record-accessor <economic-resource> 'previous-event))
(define economic-resource-availability-window
  (vf-record-accessor <economic-resource> 'availability-window))

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
              (let ((g (string-append "Svc|" (economic-resource-conforms-to r))))
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
(define <economic-event>
  (vf-record-type 'EconomicEvent
    '((immutable id)
      (immutable action)
      (immutable input-of)
      (immutable output-of)
      (immutable resource-inventoried-as)
      (immutable to-resource-inventoried-as)
      (immutable resource-conforms-to)
      (immutable resource-classified-as)
      (immutable provider)
      (immutable receiver)
      (immutable resource-quantity)
      (immutable effort-quantity)
      (immutable has-beginning)
      (immutable has-end)
      (immutable has-point-in-time)
      (immutable created)
      (immutable at-location)
      (immutable to-location)
      (immutable state)
      (immutable fulfills)
      (immutable satisfies)
      (immutable corrects)
      (immutable realization-of)
      (immutable settles)
      (immutable note)
      (immutable in-scope-of)
      (immutable previous-event)
      ;; distribution-mode: carried on the transfer — 'communal |
      ;; 'individual-claimable | #f. Promoted from the legacy
      ;; "individually-claimable" classifiedAs tag on the event.
      (immutable distribution-mode))))

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
(define economic-event?
  (vf-record-predicate <economic-event>))
(define economic-event-id
  (vf-record-accessor <economic-event> 'id))
(define economic-event-action
  (vf-record-accessor <economic-event> 'action))
(define economic-event-input-of
  (vf-record-accessor <economic-event> 'input-of))
(define economic-event-output-of
  (vf-record-accessor <economic-event> 'output-of))
(define economic-event-resource-inventoried-as
  (vf-record-accessor <economic-event> 'resource-inventoried-as))
(define economic-event-to-resource-inventoried-as
  (vf-record-accessor <economic-event> 'to-resource-inventoried-as))
(define economic-event-resource-conforms-to
  (vf-record-accessor <economic-event> 'resource-conforms-to))
(define economic-event-resource-classified-as
  (vf-record-accessor <economic-event> 'resource-classified-as))
(define economic-event-distribution-mode
  (vf-record-accessor <economic-event> 'distribution-mode))
;; distribution-mode lives in the FIELD. The smart constructors normalise a
;; legacy "communal"/"individually-claimable" classifiedAs tag INTO the field
;; (and strip it from classifiedAs) at construction — %mode-from-tags /
;; %strip-mode-tags are defined above the records for that — so reads here are
;; field-only. No tag is consulted at query time.
(define (resource-distribution-mode r) (economic-resource-distribution-mode r))
(define (event-distribution-mode e)    (economic-event-distribution-mode e))
(define economic-event-provider
  (vf-record-accessor <economic-event> 'provider))
(define economic-event-receiver
  (vf-record-accessor <economic-event> 'receiver))
(define economic-event-resource-quantity
  (vf-record-accessor <economic-event> 'resource-quantity))
(define economic-event-effort-quantity
  (vf-record-accessor <economic-event> 'effort-quantity))
(define economic-event-has-beginning
  (vf-record-accessor <economic-event> 'has-beginning))
(define economic-event-has-end
  (vf-record-accessor <economic-event> 'has-end))
(define economic-event-has-point-in-time
  (vf-record-accessor <economic-event> 'has-point-in-time))
(define economic-event-created
  (vf-record-accessor <economic-event> 'created))
(define economic-event-at-location
  (vf-record-accessor <economic-event> 'at-location))
(define economic-event-to-location
  (vf-record-accessor <economic-event> 'to-location))
(define economic-event-state
  (vf-record-accessor <economic-event> 'state))
(define economic-event-fulfills
  (vf-record-accessor <economic-event> 'fulfills))
(define economic-event-satisfies
  (vf-record-accessor <economic-event> 'satisfies))
(define economic-event-corrects
  (vf-record-accessor <economic-event> 'corrects))
(define economic-event-realization-of
  (vf-record-accessor <economic-event> 'realization-of))
(define economic-event-settles
  (vf-record-accessor <economic-event> 'settles))
(define economic-event-note
  (vf-record-accessor <economic-event> 'note))
(define economic-event-in-scope-of
  (vf-record-accessor <economic-event> 'in-scope-of))
(define economic-event-previous-event
  (vf-record-accessor <economic-event> 'previous-event))

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
(define <process>
  (vf-record-type 'Process
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable based-on)
      (immutable classified-as)
      (immutable planned-within)
      (immutable nested-in)
      (immutable in-scope-of)
      (immutable has-beginning)
      (immutable has-end)
      (immutable finished))))

(define make-process (vf-record-maker <process>))
(define process?                  (vf-record-predicate   <process>))
(define process-id                (vf-record-accessor    <process> 'id))
(define process-name              (vf-record-accessor    <process> 'name))
(define process-note              (vf-record-accessor    <process> 'note))
(define process-based-on          (vf-record-accessor    <process> 'based-on))
(define process-classified-as     (vf-record-accessor    <process> 'classified-as))
(define process-planned-within    (vf-record-accessor    <process> 'planned-within))
(define process-nested-in         (vf-record-accessor    <process> 'nested-in))
(define process-in-scope-of       (vf-record-accessor    <process> 'in-scope-of))
(define process-has-beginning     (vf-record-accessor    <process> 'has-beginning))
(define process-has-end           (vf-record-accessor    <process> 'has-end))
(define process-finished          (vf-record-accessor    <process> 'finished))


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
(define <intent>
  (vf-record-type 'Intent
    '((immutable id)
      (immutable action)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable input-of)
      (immutable output-of)
      (immutable resource-inventoried-as)
      (immutable resource-conforms-to)
      (immutable resource-classified-as)
      (immutable resource-quantity)
      (immutable effort-quantity)
      (immutable available-quantity)
      (immutable minimum-quantity)
      (immutable provider)
      (immutable receiver)
      (immutable has-beginning)
      (immutable has-end)
      (immutable has-point-in-time)
      (immutable due)
      (immutable at-location)
      (immutable stage)
      (immutable state)
      (immutable planned-within)
      (immutable satisfies)
      (immutable in-scope-of)
      (immutable finished)
      (immutable availability-window))))

(define make-intent (vf-record-maker <intent>))
(define intent?                              (vf-record-predicate   <intent>))
(define intent-id                            (vf-record-accessor    <intent> 'id))
(define intent-action                        (vf-record-accessor    <intent> 'action))
(define intent-name                          (vf-record-accessor    <intent> 'name))
(define intent-note                          (vf-record-accessor    <intent> 'note))
(define intent-image                         (vf-record-accessor    <intent> 'image))
(define intent-input-of                      (vf-record-accessor    <intent> 'input-of))
(define intent-output-of                     (vf-record-accessor    <intent> 'output-of))
(define intent-resource-inventoried-as       (vf-record-accessor    <intent> 'resource-inventoried-as))
(define intent-resource-conforms-to          (vf-record-accessor    <intent> 'resource-conforms-to))
(define intent-resource-classified-as        (vf-record-accessor    <intent> 'resource-classified-as))
(define intent-resource-quantity             (vf-record-accessor    <intent> 'resource-quantity))
(define intent-effort-quantity               (vf-record-accessor    <intent> 'effort-quantity))
(define intent-available-quantity            (vf-record-accessor    <intent> 'available-quantity))
(define intent-minimum-quantity              (vf-record-accessor    <intent> 'minimum-quantity))
(define intent-provider                      (vf-record-accessor    <intent> 'provider))
(define intent-receiver                      (vf-record-accessor    <intent> 'receiver))
(define intent-has-beginning                 (vf-record-accessor    <intent> 'has-beginning))
(define intent-has-end                       (vf-record-accessor    <intent> 'has-end))
(define intent-has-point-in-time             (vf-record-accessor    <intent> 'has-point-in-time))
(define intent-due                           (vf-record-accessor    <intent> 'due))
(define intent-at-location                   (vf-record-accessor    <intent> 'at-location))
(define intent-stage                         (vf-record-accessor    <intent> 'stage))
(define intent-state                         (vf-record-accessor    <intent> 'state))
(define intent-planned-within                (vf-record-accessor    <intent> 'planned-within))
(define intent-satisfies                     (vf-record-accessor    <intent> 'satisfies))
(define intent-in-scope-of                   (vf-record-accessor    <intent> 'in-scope-of))
(define intent-finished                      (vf-record-accessor    <intent> 'finished))
(define intent-availability-window           (vf-record-accessor    <intent> 'availability-window))


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
(define <commitment>
  (vf-record-type 'Commitment
    '((immutable id)
      (immutable action)
      (immutable note)
      (immutable input-of)
      (immutable output-of)
      (immutable resource-inventoried-as)
      (immutable resource-conforms-to)
      (immutable resource-classified-as)
      (immutable resource-quantity)
      (immutable effort-quantity)
      (immutable provider)
      (immutable receiver)
      (immutable has-beginning)
      (immutable has-end)
      (immutable has-point-in-time)
      (immutable due)
      (immutable created)
      (immutable at-location)
      (immutable in-scope-of)
      (immutable stage)
      (immutable state)
      (immutable satisfies)
      (immutable clause-of)
      (immutable independent-demand-of)
      (immutable planned-within)
      (immutable finished)
      (immutable availability-window))))

(define make-commitment (vf-record-maker <commitment>))
(define commitment?
  (vf-record-predicate <commitment>))
(define commitment-id
  (vf-record-accessor <commitment> 'id))
(define commitment-action
  (vf-record-accessor <commitment> 'action))
(define commitment-note
  (vf-record-accessor <commitment> 'note))
(define commitment-input-of
  (vf-record-accessor <commitment> 'input-of))
(define commitment-output-of
  (vf-record-accessor <commitment> 'output-of))
(define commitment-resource-inventoried-as
  (vf-record-accessor <commitment> 'resource-inventoried-as))
(define commitment-resource-conforms-to
  (vf-record-accessor <commitment> 'resource-conforms-to))
(define commitment-resource-classified-as
  (vf-record-accessor <commitment> 'resource-classified-as))
(define commitment-resource-quantity
  (vf-record-accessor <commitment> 'resource-quantity))
(define commitment-effort-quantity
  (vf-record-accessor <commitment> 'effort-quantity))
(define commitment-provider
  (vf-record-accessor <commitment> 'provider))
(define commitment-receiver
  (vf-record-accessor <commitment> 'receiver))
(define commitment-has-beginning
  (vf-record-accessor <commitment> 'has-beginning))
(define commitment-has-end
  (vf-record-accessor <commitment> 'has-end))
(define commitment-has-point-in-time
  (vf-record-accessor <commitment> 'has-point-in-time))
(define commitment-due
  (vf-record-accessor <commitment> 'due))
(define commitment-created
  (vf-record-accessor <commitment> 'created))
(define commitment-at-location
  (vf-record-accessor <commitment> 'at-location))
(define commitment-in-scope-of
  (vf-record-accessor <commitment> 'in-scope-of))
(define commitment-stage
  (vf-record-accessor <commitment> 'stage))
(define commitment-state
  (vf-record-accessor <commitment> 'state))
(define commitment-satisfies
  (vf-record-accessor <commitment> 'satisfies))
(define commitment-clause-of
  (vf-record-accessor <commitment> 'clause-of))
(define commitment-independent-demand-of
  (vf-record-accessor <commitment> 'independent-demand-of))
(define commitment-planned-within
  (vf-record-accessor <commitment> 'planned-within))
(define commitment-finished
  (vf-record-accessor <commitment> 'finished))
(define commitment-availability-window
  (vf-record-accessor <commitment> 'availability-window))

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
(define <claim>
  (vf-record-type 'Claim
    '((immutable id)
      (immutable action)
      (immutable provider)
      (immutable receiver)
      (immutable triggered-by)
      (immutable resource-quantity)
      (immutable effort-quantity)
      (immutable resource-conforms-to)
      (immutable resource-classified-as)
      (immutable due)
      (immutable created)
      (immutable note)
      (immutable finished))))

(define make-claim (vf-record-maker <claim>))
(define claim?                            (vf-record-predicate   <claim>))
(define claim-id                          (vf-record-accessor    <claim> 'id))
(define claim-action                      (vf-record-accessor    <claim> 'action))
(define claim-provider                    (vf-record-accessor    <claim> 'provider))
(define claim-receiver                    (vf-record-accessor    <claim> 'receiver))
(define claim-triggered-by                (vf-record-accessor    <claim> 'triggered-by))
(define claim-resource-quantity            (vf-record-accessor    <claim> 'resource-quantity))
(define claim-effort-quantity              (vf-record-accessor    <claim> 'effort-quantity))
(define claim-resource-conforms-to         (vf-record-accessor    <claim> 'resource-conforms-to))
(define claim-resource-classified-as       (vf-record-accessor    <claim> 'resource-classified-as))
(define claim-due                          (vf-record-accessor    <claim> 'due))
(define claim-created                      (vf-record-accessor    <claim> 'created))
(define claim-note                         (vf-record-accessor    <claim> 'note))
(define claim-finished                     (vf-record-accessor    <claim> 'finished))


;; ═══════════════════════════════════════════════════════════════════════
;; PLANNING LAYER — Plans
;; ═══════════════════════════════════════════════════════════════════════

;;; Plan — a schedule of related processes constituting a body of work.
;;; Fields: id (string), name (string), note? (string),
;;;         due? (ISO datetime), created? (ISO datetime),
;;;         has-independent-demand? (list of strings: Commitment/Intent IDs),
;;;         refinement-of? (string: Scenario ID),
;;;         classified-as? (list of strings).
(define <plan>
  (vf-record-type 'Plan
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable due)
      (immutable created)
      (immutable has-independent-demand)
      (immutable refinement-of)
      (immutable classified-as))))

(define make-plan (vf-record-maker <plan>))
(define plan?                           (vf-record-predicate   <plan>))
(define plan-id                         (vf-record-accessor    <plan> 'id))
(define plan-name                       (vf-record-accessor    <plan> 'name))
(define plan-note                       (vf-record-accessor    <plan> 'note))
(define plan-due                        (vf-record-accessor    <plan> 'due))
(define plan-created                    (vf-record-accessor    <plan> 'created))
(define plan-has-independent-demand     (vf-record-accessor    <plan> 'has-independent-demand))
(define plan-refinement-of              (vf-record-accessor    <plan> 'refinement-of))
(define plan-classified-as              (vf-record-accessor    <plan> 'classified-as))


;; ═══════════════════════════════════════════════════════════════════════
;; ESTIMATION / ANALYSIS LAYER — Scenarios
;; ═══════════════════════════════════════════════════════════════════════

;;; ScenarioDefinition — a named category or template for a kind of scenario.
;;; Fields: id (string), name (string), note? (string),
;;;         has-duration? (<duration>), in-scope-of? (string: Agent ID).
(define <scenario-definition>
  (vf-record-type 'ScenarioDefinition
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable has-duration)
      (immutable in-scope-of))))

(define make-scenario-definition (vf-record-maker <scenario-definition>))
(define scenario-definition?
  (vf-record-predicate <scenario-definition>))
(define scenario-definition-id
  (vf-record-accessor <scenario-definition> 'id))
(define scenario-definition-name
  (vf-record-accessor <scenario-definition> 'name))
(define scenario-definition-note
  (vf-record-accessor <scenario-definition> 'note))
(define scenario-definition-has-duration
  (vf-record-accessor <scenario-definition> 'has-duration))
(define scenario-definition-in-scope-of
  (vf-record-accessor <scenario-definition> 'in-scope-of))


;;; Scenario — a grouping of processes, intents, plans for analysis/budgeting.
;;; Fields: id (string), name (string), note? (string),
;;;         defined-as? (string: ScenarioDefinition ID),
;;;         refinement-of? (string: Scenario ID),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         in-scope-of? (string: Agent ID).
(define <scenario>
  (vf-record-type 'Scenario
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable defined-as)
      (immutable refinement-of)
      (immutable has-beginning)
      (immutable has-end)
      (immutable in-scope-of))))

(define make-scenario (vf-record-maker <scenario>))
(define scenario?                  (vf-record-predicate   <scenario>))
(define scenario-id                (vf-record-accessor    <scenario> 'id))
(define scenario-name              (vf-record-accessor    <scenario> 'name))
(define scenario-note              (vf-record-accessor    <scenario> 'note))
(define scenario-defined-as        (vf-record-accessor    <scenario> 'defined-as))
(define scenario-refinement-of     (vf-record-accessor    <scenario> 'refinement-of))
(define scenario-has-beginning     (vf-record-accessor    <scenario> 'has-beginning))
(define scenario-has-end           (vf-record-accessor    <scenario> 'has-end))
(define scenario-in-scope-of       (vf-record-accessor    <scenario> 'in-scope-of))


;; ═══════════════════════════════════════════════════════════════════════
;; AGREEMENTS & EXCHANGES
;; ═══════════════════════════════════════════════════════════════════════

;;; Agreement — a mutual agreement between agents.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime),
;;;         stipulates? (list of strings: primary Commitment IDs),
;;;         stipulates-reciprocal? (list of strings: reciprocal Commitment IDs).
(define <agreement>
  (vf-record-type 'Agreement
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable stipulates)
      (immutable stipulates-reciprocal))))

(define make-agreement (vf-record-maker <agreement>))
(define agreement?                           (vf-record-predicate   <agreement>))
(define agreement-id                         (vf-record-accessor    <agreement> 'id))
(define agreement-name                       (vf-record-accessor    <agreement> 'name))
(define agreement-note                       (vf-record-accessor    <agreement> 'note))
(define agreement-created                    (vf-record-accessor    <agreement> 'created))
(define agreement-stipulates                 (vf-record-accessor    <agreement> 'stipulates))
(define agreement-stipulates-reciprocal      (vf-record-accessor    <agreement> 'stipulates-reciprocal))


;;; AgreementBundle — groups multiple Agreements.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), bundles? (list of strings: Agreement IDs).
(define <agreement-bundle>
  (vf-record-type 'AgreementBundle
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable bundles))))

(define make-agreement-bundle (vf-record-maker <agreement-bundle>))
(define agreement-bundle?              (vf-record-predicate   <agreement-bundle>))
(define agreement-bundle-id            (vf-record-accessor    <agreement-bundle> 'id))
(define agreement-bundle-name          (vf-record-accessor    <agreement-bundle> 'name))
(define agreement-bundle-note          (vf-record-accessor    <agreement-bundle> 'note))
(define agreement-bundle-created       (vf-record-accessor    <agreement-bundle> 'created))
(define agreement-bundle-bundles       (vf-record-accessor    <agreement-bundle> 'bundles))


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
(define <proposal>
  (vf-record-type 'Proposal
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable has-beginning)
      (immutable has-end)
      (immutable unit-based)
      (immutable created)
      (immutable purpose)
      (immutable eligible-location)
      (immutable in-scope-of)
      (immutable publishes)
      (immutable reciprocal)
      (immutable proposed-to))))

(define make-proposal (vf-record-maker <proposal>))
(define proposal?                      (vf-record-predicate   <proposal>))
(define proposal-id                    (vf-record-accessor    <proposal> 'id))
(define proposal-name                  (vf-record-accessor    <proposal> 'name))
(define proposal-note                  (vf-record-accessor    <proposal> 'note))
(define proposal-has-beginning         (vf-record-accessor    <proposal> 'has-beginning))
(define proposal-has-end               (vf-record-accessor    <proposal> 'has-end))
(define proposal-unit-based            (vf-record-accessor    <proposal> 'unit-based))
(define proposal-created               (vf-record-accessor    <proposal> 'created))
(define proposal-purpose               (vf-record-accessor    <proposal> 'purpose))
(define proposal-eligible-location     (vf-record-accessor    <proposal> 'eligible-location))
(define proposal-in-scope-of           (vf-record-accessor    <proposal> 'in-scope-of))
(define proposal-publishes             (vf-record-accessor    <proposal> 'publishes))
(define proposal-reciprocal            (vf-record-accessor    <proposal> 'reciprocal))
(define proposal-proposed-to           (vf-record-accessor    <proposal> 'proposed-to))


;;; ProposalList — groups multiple Proposals.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), lists? (list of strings: Proposal IDs).
(define <proposal-list>
  (vf-record-type 'ProposalList
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable lists))))

(define make-proposal-list (vf-record-maker <proposal-list>))
(define proposal-list?              (vf-record-predicate   <proposal-list>))
(define proposal-list-id            (vf-record-accessor    <proposal-list> 'id))
(define proposal-list-name          (vf-record-accessor    <proposal-list> 'name))
(define proposal-list-note          (vf-record-accessor    <proposal-list> 'note))
(define proposal-list-created       (vf-record-accessor    <proposal-list> 'created))
(define proposal-list-lists         (vf-record-accessor    <proposal-list> 'lists))
