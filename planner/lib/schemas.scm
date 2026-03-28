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


;; ═══════════════════════════════════════════════════════════════════════
;; TEMPORAL (from utils/time.ts)
;; ═══════════════════════════════════════════════════════════════════════

;;; TimeRange — a time span within a day.
;;; Fields: start-time (string "HH:MM"), end-time (string "HH:MM").
(define <time-range>
  (make-record-type 'TimeRange
    '((immutable start-time)
      (immutable end-time))))

(define make-time-range       (record-constructor <time-range>))
(define time-range?           (record-predicate   <time-range>))
(define time-range-start-time (record-accessor    <time-range> 'start-time))
(define time-range-end-time   (record-accessor    <time-range> 'end-time))


;;; DaySchedule — associates specific days of the week with time ranges.
;;; Fields: days (list of day-of-week symbols), time-ranges (list of <time-range>).
(define *days-of-week*
  '(monday tuesday wednesday thursday friday saturday sunday))

(define (day-of-week? x)
  (and (symbol? x) (memq x *days-of-week*) #t))

(define <day-schedule>
  (make-record-type 'DaySchedule
    '((immutable days)
      (immutable time-ranges))))

(define make-day-schedule           (record-constructor <day-schedule>))
(define day-schedule?               (record-predicate   <day-schedule>))
(define day-schedule-days           (record-accessor    <day-schedule> 'days))
(define day-schedule-time-ranges    (record-accessor    <day-schedule> 'time-ranges))


;;; WeekSchedule — associates specific weeks of a month with day/time patterns.
;;; Fields: weeks (list of integers 1-5), day-schedules (list of <day-schedule>).
(define <week-schedule>
  (make-record-type 'WeekSchedule
    '((immutable weeks)
      (immutable day-schedules))))

(define make-week-schedule              (record-constructor <week-schedule>))
(define week-schedule?                  (record-predicate   <week-schedule>))
(define week-schedule-weeks             (record-accessor    <week-schedule> 'weeks))
(define week-schedule-day-schedules     (record-accessor    <week-schedule> 'day-schedules))


;;; MonthSchedule — associates a specific month with week/day/time patterns.
;;; Fields: month (integer 1-12),
;;;         week-schedules (optional: list of <week-schedule> | #f),
;;;         day-schedules  (optional: list of <day-schedule>  | #f),
;;;         time-ranges    (optional: list of <time-range>    | #f).
(define <month-schedule>
  (make-record-type 'MonthSchedule
    '((immutable month)
      (immutable week-schedules)
      (immutable day-schedules)
      (immutable time-ranges))))

(define make-month-schedule              (record-constructor <month-schedule>))
(define month-schedule?                  (record-predicate   <month-schedule>))
(define month-schedule-month             (record-accessor    <month-schedule> 'month))
(define month-schedule-week-schedules    (record-accessor    <month-schedule> 'week-schedules))
(define month-schedule-day-schedules     (record-accessor    <month-schedule> 'day-schedules))
(define month-schedule-time-ranges       (record-accessor    <month-schedule> 'time-ranges))


;;; AvailabilityWindow — hierarchical recurring availability definition.
;;; Priority: month-schedules > week-schedules > day-schedules > time-ranges.
;;; All fields optional (but at least one must be non-#f at runtime).
(define <availability-window>
  (make-record-type 'AvailabilityWindow
    '((immutable month-schedules)
      (immutable week-schedules)
      (immutable day-schedules)
      (immutable time-ranges))))

(define make-availability-window              (record-constructor <availability-window>))
(define availability-window?                  (record-predicate   <availability-window>))
(define availability-window-month-schedules   (record-accessor    <availability-window> 'month-schedules))
(define availability-window-week-schedules    (record-accessor    <availability-window> 'week-schedules))
(define availability-window-day-schedules     (record-accessor    <availability-window> 'day-schedules))
(define availability-window-time-ranges       (record-accessor    <availability-window> 'time-ranges))


;;; SpecificDateWindow — one-time or ad-hoc multi-date temporal expression.
;;; Fields: specific-dates (list of "YYYY-MM-DD" strings),
;;;         time-ranges (optional: list of <time-range> | #f).
(define <specific-date-window>
  (make-record-type 'SpecificDateWindow
    '((immutable specific-dates)
      (immutable time-ranges))))

(define make-specific-date-window              (record-constructor <specific-date-window>))
(define specific-date-window?                  (record-predicate   <specific-date-window>))
(define specific-date-window-specific-dates    (record-accessor    <specific-date-window> 'specific-dates))
(define specific-date-window-time-ranges       (record-accessor    <specific-date-window> 'time-ranges))


;;; TemporalExpression — union of SpecificDateWindow | AvailabilityWindow.
;;; Discriminate at runtime via specific-date-window? / availability-window?.
(define (temporal-expression? x)
  (or (specific-date-window? x)
      (availability-window? x)))


;; ═══════════════════════════════════════════════════════════════════════
;; PRIMITIVES
;; ═══════════════════════════════════════════════════════════════════════

;;; Measure — a quantity with a unit.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "kg", "hours", OM2 URI).
(define <measure>
  (make-record-type 'Measure
    '((immutable has-numerical-value)
      (immutable has-unit))))

(define make-measure                   (record-constructor <measure>))
(define measure?                       (record-predicate   <measure>))
(define measure-has-numerical-value    (record-accessor    <measure> 'has-numerical-value))
(define measure-has-unit               (record-accessor    <measure> 'has-unit))


;;; Duration — time span for processes and recipes.
;;; Fields: has-numerical-value (number), has-unit (string, e.g. "hours", "days").
(define <duration>
  (make-record-type 'Duration
    '((immutable has-numerical-value)
      (immutable has-unit))))

(define make-duration                   (record-constructor <duration>))
(define duration?                       (record-predicate   <duration>))
(define duration-has-numerical-value    (record-accessor    <duration> 'has-numerical-value))
(define duration-has-unit               (record-accessor    <duration> 'has-unit))


;;; Unit — measurement unit definition.
;;; Fields: id (string), label (string), symbol (string),
;;;         classified-as (optional: list of strings | #f).
(define <unit>
  (make-record-type 'Unit
    '((immutable id)
      (immutable label)
      (immutable symbol)
      (immutable classified-as))))

(define make-unit              (record-constructor <unit>))
(define unit?                  (record-predicate   <unit>))
(define unit-id                (record-accessor    <unit> 'id))
(define unit-label             (record-accessor    <unit> 'label))
(define unit-symbol            (record-accessor    <unit> 'symbol))
(define unit-classified-as     (record-accessor    <unit> 'classified-as))


;;; SpatialThing — a location in space.
;;; Fields: id (string), name? (string), note? (string),
;;;         lat? (number), long? (number), alt? (number),
;;;         mappable-address? (string).
(define <spatial-thing>
  (make-record-type 'SpatialThing
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable lat)
      (immutable long)
      (immutable alt)
      (immutable mappable-address))))

(define make-spatial-thing                  (record-constructor <spatial-thing>))
(define spatial-thing?                      (record-predicate   <spatial-thing>))
(define spatial-thing-id                    (record-accessor    <spatial-thing> 'id))
(define spatial-thing-name                  (record-accessor    <spatial-thing> 'name))
(define spatial-thing-note                  (record-accessor    <spatial-thing> 'note))
(define spatial-thing-lat                   (record-accessor    <spatial-thing> 'lat))
(define spatial-thing-long                  (record-accessor    <spatial-thing> 'long))
(define spatial-thing-alt                   (record-accessor    <spatial-thing> 'alt))
(define spatial-thing-mappable-address      (record-accessor    <spatial-thing> 'mappable-address))


;;; BatchLotRecord — tracking for serialized/lot-controlled resources.
;;; Fields: id (string), batch-lot-code? (string), expiration-date? (ISO datetime string).
(define <batch-lot-record>
  (make-record-type 'BatchLotRecord
    '((immutable id)
      (immutable batch-lot-code)
      (immutable expiration-date))))

(define make-batch-lot-record              (record-constructor <batch-lot-record>))
(define batch-lot-record?                  (record-predicate   <batch-lot-record>))
(define batch-lot-record-id                (record-accessor    <batch-lot-record> 'id))
(define batch-lot-record-batch-lot-code    (record-accessor    <batch-lot-record> 'batch-lot-code))
(define batch-lot-record-expiration-date   (record-accessor    <batch-lot-record> 'expiration-date))


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
  (make-record-type 'ActionDefinition
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

(define make-action-definition
  (record-constructor <action-definition>))
(define action-definition?
  (record-predicate <action-definition>))
(define action-definition-event-quantity
  (record-accessor <action-definition> 'event-quantity))
(define action-definition-input-output
  (record-accessor <action-definition> 'input-output))
(define action-definition-pairs-with
  (record-accessor <action-definition> 'pairs-with))
(define action-definition-create-resource
  (record-accessor <action-definition> 'create-resource))
(define action-definition-accounting-effect
  (record-accessor <action-definition> 'accounting-effect))
(define action-definition-onhand-effect
  (record-accessor <action-definition> 'onhand-effect))
(define action-definition-location-effect
  (record-accessor <action-definition> 'location-effect))
(define action-definition-contained-effect
  (record-accessor <action-definition> 'contained-effect))
(define action-definition-accountable-effect
  (record-accessor <action-definition> 'accountable-effect))
(define action-definition-stage-effect
  (record-accessor <action-definition> 'stage-effect))
(define action-definition-state-effect
  (record-accessor <action-definition> 'state-effect))
(define action-definition-implies-transfer
  (record-accessor <action-definition> 'implies-transfer))
(define action-definition-eligible-for-exchange
  (record-accessor <action-definition> 'eligible-for-exchange))

;;; *action-definitions* — complete behavioral table for all 19 VF actions.
;;; An alist mapping vf-action symbols to <action-definition> records.
(define *action-definitions*
  (list
    (cons 'produce
      (make-action-definition
        'resource-quantity 'output #f 'optional
        'increment 'increment 'new 'no-effect 'new 'update 'update
        'all-rights #t))
    (cons 'consume
      (make-action-definition
        'resource-quantity 'input #f 'no-effect
        'decrement 'decrement 'no-effect 'no-effect 'no-effect 'no-effect 'update
        'all-rights #t))
    (cons 'use
      (make-action-definition
        'both 'input #f 'no-effect
        'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'update
        #f #t))
    (cons 'work
      (make-action-definition
        'effort-quantity 'input #f 'no-effect
        'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect
        #f #t))
    (cons 'cite
      (make-action-definition
        'resource-quantity 'input #f 'no-effect
        'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'update
        #f #t))
    (cons 'deliver-service
      (make-action-definition
        'resource-quantity 'output-input #f 'no-effect
        'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect 'no-effect
        #f #t))
    (cons 'pickup
      (make-action-definition
        'resource-quantity 'input 'dropoff 'no-effect
        'no-effect 'decrement 'update 'no-effect 'no-effect 'no-effect 'update
        'custody #f))
    (cons 'dropoff
      (make-action-definition
        'resource-quantity 'output 'pickup 'no-effect
        'no-effect 'increment 'update 'no-effect 'no-effect 'update 'update
        'custody #f))
    (cons 'accept
      (make-action-definition
        'resource-quantity 'input 'modify 'no-effect
        'no-effect 'decrement 'update 'no-effect 'no-effect 'no-effect 'update
        'custody #f))
    (cons 'modify
      (make-action-definition
        'resource-quantity 'output 'accept 'no-effect
        'no-effect 'increment 'update 'no-effect 'no-effect 'update 'update
        'custody #f))
    (cons 'combine
      (make-action-definition
        'resource-quantity 'input #f 'no-effect
        'no-effect 'decrement 'no-effect 'update 'no-effect 'no-effect 'update
        #f #t))
    (cons 'separate
      (make-action-definition
        'resource-quantity 'output #f 'no-effect
        'no-effect 'increment 'no-effect 'remove 'no-effect 'update 'update
        #f #t))
    (cons 'transfer-all-rights
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional-to
        'decrement-increment 'no-effect 'no-effect 'no-effect 'update-to 'no-effect 'update-to
        #f #t))
    (cons 'transfer-custody
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional-to
        'no-effect 'decrement-increment 'update-to 'no-effect 'no-effect 'no-effect 'update-to
        #f #t))
    (cons 'transfer
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional-to
        'decrement-increment 'decrement-increment 'update-to 'no-effect 'update-to 'no-effect 'update-to
        #f #t))
    (cons 'move
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional-to
        'decrement-increment 'decrement-increment 'update-to 'no-effect 'no-effect 'no-effect 'update-to
        #f #t))
    (cons 'copy
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional-to
        'increment-to 'increment-to 'new 'no-effect 'new 'no-effect 'update-to
        #f #t))
    (cons 'raise
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional
        'increment 'increment 'no-effect 'no-effect 'new 'no-effect 'update
        #f #t))
    (cons 'lower
      (make-action-definition
        'resource-quantity 'not-applicable #f 'optional
        'decrement 'decrement 'no-effect 'no-effect 'new 'no-effect 'update
        #f #t))))


;; ═══════════════════════════════════════════════════════════════════════
;; AGENTS
;; ═══════════════════════════════════════════════════════════════════════

;;; AgentType — Person | Organization | EcologicalAgent.
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
  (make-record-type 'Agent
    '((immutable id)
      (immutable type)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable primary-location)
      (immutable classified-as)
      (immutable availability-window))))

(define make-agent                      (record-constructor <agent>))
(define agent?                          (record-predicate   <agent>))
(define agent-id                        (record-accessor    <agent> 'id))
(define agent-type                      (record-accessor    <agent> 'type))
(define agent-name                      (record-accessor    <agent> 'name))
(define agent-note                      (record-accessor    <agent> 'note))
(define agent-image                     (record-accessor    <agent> 'image))
(define agent-primary-location          (record-accessor    <agent> 'primary-location))
(define agent-classified-as             (record-accessor    <agent> 'classified-as))
(define agent-availability-window       (record-accessor    <agent> 'availability-window))


;;; AgentRelationshipRole — a named role an agent plays relative to another.
;;; Fields: id (string), label (string), inverse-label? (string),
;;;         note? (string), classified-as? (list of strings).
(define <agent-relationship-role>
  (make-record-type 'AgentRelationshipRole
    '((immutable id)
      (immutable label)
      (immutable inverse-label)
      (immutable note)
      (immutable classified-as))))

(define make-agent-relationship-role
  (record-constructor <agent-relationship-role>))
(define agent-relationship-role?
  (record-predicate <agent-relationship-role>))
(define agent-relationship-role-id
  (record-accessor <agent-relationship-role> 'id))
(define agent-relationship-role-label
  (record-accessor <agent-relationship-role> 'label))
(define agent-relationship-role-inverse-label
  (record-accessor <agent-relationship-role> 'inverse-label))
(define agent-relationship-role-note
  (record-accessor <agent-relationship-role> 'note))
(define agent-relationship-role-classified-as
  (record-accessor <agent-relationship-role> 'classified-as))


;;; AgentRelationship — a directed relationship between two agents.
;;; subject plays relationship (role) toward object.
;;; Fields: id (string), subject (string: Agent ID), object (string: Agent ID),
;;;         relationship (string: AgentRelationshipRole ID),
;;;         in-scope-of? (string: Agent ID), note? (string).
(define <agent-relationship>
  (make-record-type 'AgentRelationship
    '((immutable id)
      (immutable subject)
      (immutable object)
      (immutable relationship)
      (immutable in-scope-of)
      (immutable note))))

(define make-agent-relationship
  (record-constructor <agent-relationship>))
(define agent-relationship?
  (record-predicate <agent-relationship>))
(define agent-relationship-id
  (record-accessor <agent-relationship> 'id))
(define agent-relationship-subject
  (record-accessor <agent-relationship> 'subject))
(define agent-relationship-object
  (record-accessor <agent-relationship> 'object))
(define agent-relationship-relationship
  (record-accessor <agent-relationship> 'relationship))
(define agent-relationship-in-scope-of
  (record-accessor <agent-relationship> 'in-scope-of))
(define agent-relationship-note
  (record-accessor <agent-relationship> 'note))


;; ═══════════════════════════════════════════════════════════════════════
;; KNOWLEDGE LAYER — Specifications
;; ═══════════════════════════════════════════════════════════════════════

;;; PositioningAnalysis — DDMRP Ch 6 strategic positioning factors.
;;; All fields optional.
;;; Fields:
;;;   customer-tolerance-time-days?       (number, nonneg)
;;;   market-potential-lead-time-days?    (number, nonneg)
;;;   sales-order-visibility-horizon-days? (number, nonneg)
;;;   inventory-leverage-flexibility?     (symbol: low | medium | high)
;;;   vrd?                               (symbol: low | medium | high)
;;;   vrs?                               (symbol: low | medium | high)
;;;   critical-operation-protection?      (boolean)
;;;   decoupling-recommended?             (boolean)
;;;   note?                              (string)
(define <positioning-analysis>
  (make-record-type 'PositioningAnalysis
    '((immutable customer-tolerance-time-days)
      (immutable market-potential-lead-time-days)
      (immutable sales-order-visibility-horizon-days)
      (immutable inventory-leverage-flexibility)
      (immutable vrd)
      (immutable vrs)
      (immutable critical-operation-protection)
      (immutable decoupling-recommended)
      (immutable note))))

(define make-positioning-analysis
  (record-constructor <positioning-analysis>))
(define positioning-analysis?
  (record-predicate <positioning-analysis>))
(define positioning-analysis-customer-tolerance-time-days
  (record-accessor <positioning-analysis> 'customer-tolerance-time-days))
(define positioning-analysis-market-potential-lead-time-days
  (record-accessor <positioning-analysis> 'market-potential-lead-time-days))
(define positioning-analysis-sales-order-visibility-horizon-days
  (record-accessor <positioning-analysis> 'sales-order-visibility-horizon-days))
(define positioning-analysis-inventory-leverage-flexibility
  (record-accessor <positioning-analysis> 'inventory-leverage-flexibility))
(define positioning-analysis-vrd
  (record-accessor <positioning-analysis> 'vrd))
(define positioning-analysis-vrs
  (record-accessor <positioning-analysis> 'vrs))
(define positioning-analysis-critical-operation-protection
  (record-accessor <positioning-analysis> 'critical-operation-protection))
(define positioning-analysis-decoupling-recommended
  (record-accessor <positioning-analysis> 'decoupling-recommended))
(define positioning-analysis-note
  (record-accessor <positioning-analysis> 'note))


;;; DecouplingTestEntry — a single test result within a DecouplingTestResult.
;;; Fields: test (symbol: decoupling | bi-directional | order-independence |
;;;               primary-planning | relative-priority | dynamic-adjustment),
;;;         passed (boolean), note? (string).
(define *decoupling-tests*
  '(decoupling bi-directional order-independence
    primary-planning relative-priority dynamic-adjustment))

(define (decoupling-test? x)
  (and (symbol? x) (memq x *decoupling-tests*) #t))

(define <decoupling-test-entry>
  (make-record-type 'DecouplingTestEntry
    '((immutable test)
      (immutable passed)
      (immutable note))))

(define make-decoupling-test-entry
  (record-constructor <decoupling-test-entry>))
(define decoupling-test-entry?
  (record-predicate <decoupling-test-entry>))
(define decoupling-test-entry-test
  (record-accessor <decoupling-test-entry> 'test))
(define decoupling-test-entry-passed
  (record-accessor <decoupling-test-entry> 'passed))
(define decoupling-test-entry-note
  (record-accessor <decoupling-test-entry> 'note))


;;; DecouplingTestResult — outcome of a formal decoupling-point approval.
;;; Fields: spec-id (string), results (list of <decoupling-test-entry>),
;;;         approved-at? (ISO datetime string), approved-by? (string).
(define <decoupling-test-result>
  (make-record-type 'DecouplingTestResult
    '((immutable spec-id)
      (immutable results)
      (immutable approved-at)
      (immutable approved-by))))

(define make-decoupling-test-result
  (record-constructor <decoupling-test-result>))
(define decoupling-test-result?
  (record-predicate <decoupling-test-result>))
(define decoupling-test-result-spec-id
  (record-accessor <decoupling-test-result> 'spec-id))
(define decoupling-test-result-results
  (record-accessor <decoupling-test-result> 'results))
(define decoupling-test-result-approved-at
  (record-accessor <decoupling-test-result> 'approved-at))
(define decoupling-test-result-approved-by
  (record-accessor <decoupling-test-result> 'approved-by))


;;; ResourceSpecification — the catalog "type" of a resource.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         resource-classified-as? (list of strings),
;;;         default-unit-of-resource? (string), default-unit-of-effort? (string),
;;;         substitutable? (boolean), medium-of-exchange? (boolean),
;;;         buffer-profile-id? (string: BufferProfile ID),
;;;         positioning-analysis? (<positioning-analysis>).
(define <resource-specification>
  (make-record-type 'ResourceSpecification
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
      (immutable positioning-analysis))))

(define make-resource-specification
  (record-constructor <resource-specification>))
(define resource-specification?
  (record-predicate <resource-specification>))
(define resource-specification-id
  (record-accessor <resource-specification> 'id))
(define resource-specification-name
  (record-accessor <resource-specification> 'name))
(define resource-specification-note
  (record-accessor <resource-specification> 'note))
(define resource-specification-image
  (record-accessor <resource-specification> 'image))
(define resource-specification-resource-classified-as
  (record-accessor <resource-specification> 'resource-classified-as))
(define resource-specification-default-unit-of-resource
  (record-accessor <resource-specification> 'default-unit-of-resource))
(define resource-specification-default-unit-of-effort
  (record-accessor <resource-specification> 'default-unit-of-effort))
(define resource-specification-substitutable
  (record-accessor <resource-specification> 'substitutable))
(define resource-specification-medium-of-exchange
  (record-accessor <resource-specification> 'medium-of-exchange))
(define resource-specification-buffer-profile-id
  (record-accessor <resource-specification> 'buffer-profile-id))
(define resource-specification-positioning-analysis
  (record-accessor <resource-specification> 'positioning-analysis))


;;; ProcessSpecification — the "type" of a process.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         is-decoupling-point? (boolean), is-control-point? (boolean),
;;;         buffer-type? (symbol: stock | time | capacity),
;;;         is-divergent-point? (boolean), is-convergent-point? (boolean).
(define <process-specification>
  (make-record-type 'ProcessSpecification
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable is-decoupling-point)
      (immutable is-control-point)
      (immutable buffer-type)
      (immutable is-divergent-point)
      (immutable is-convergent-point))))

(define make-process-specification
  (record-constructor <process-specification>))
(define process-specification?
  (record-predicate <process-specification>))
(define process-specification-id
  (record-accessor <process-specification> 'id))
(define process-specification-name
  (record-accessor <process-specification> 'name))
(define process-specification-note
  (record-accessor <process-specification> 'note))
(define process-specification-image
  (record-accessor <process-specification> 'image))
(define process-specification-is-decoupling-point
  (record-accessor <process-specification> 'is-decoupling-point))
(define process-specification-is-control-point
  (record-accessor <process-specification> 'is-control-point))
(define process-specification-buffer-type
  (record-accessor <process-specification> 'buffer-type))
(define process-specification-is-divergent-point
  (record-accessor <process-specification> 'is-divergent-point))
(define process-specification-is-convergent-point
  (record-accessor <process-specification> 'is-convergent-point))


;;; CapacityBuffer — capacity buffer for a work center.
;;; Fields: id (string), process-spec-id (string: ProcessSpecification ID),
;;;         total-capacity-hours (number, positive),
;;;         period-days (number, positive),
;;;         current-load-hours (number, nonneg),
;;;         green-threshold? (number, 0-1), yellow-threshold? (number, 0-1),
;;;         note? (string).
(define <capacity-buffer>
  (make-record-type 'CapacityBuffer
    '((immutable id)
      (immutable process-spec-id)
      (immutable total-capacity-hours)
      (immutable period-days)
      (immutable current-load-hours)
      (immutable green-threshold)
      (immutable yellow-threshold)
      (immutable note))))

(define make-capacity-buffer
  (record-constructor <capacity-buffer>))
(define capacity-buffer?
  (record-predicate <capacity-buffer>))
(define capacity-buffer-id
  (record-accessor <capacity-buffer> 'id))
(define capacity-buffer-process-spec-id
  (record-accessor <capacity-buffer> 'process-spec-id))
(define capacity-buffer-total-capacity-hours
  (record-accessor <capacity-buffer> 'total-capacity-hours))
(define capacity-buffer-period-days
  (record-accessor <capacity-buffer> 'period-days))
(define capacity-buffer-current-load-hours
  (record-accessor <capacity-buffer> 'current-load-hours))
(define capacity-buffer-green-threshold
  (record-accessor <capacity-buffer> 'green-threshold))
(define capacity-buffer-yellow-threshold
  (record-accessor <capacity-buffer> 'yellow-threshold))
(define capacity-buffer-note
  (record-accessor <capacity-buffer> 'note))


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
  (make-record-type 'RecipeFlow
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

(define make-recipe-flow
  (record-constructor <recipe-flow>))
(define recipe-flow?
  (record-predicate <recipe-flow>))
(define recipe-flow-id
  (record-accessor <recipe-flow> 'id))
(define recipe-flow-action
  (record-accessor <recipe-flow> 'action))
(define recipe-flow-resource-conforms-to
  (record-accessor <recipe-flow> 'resource-conforms-to))
(define recipe-flow-resource-classified-as
  (record-accessor <recipe-flow> 'resource-classified-as))
(define recipe-flow-resource-quantity
  (record-accessor <recipe-flow> 'resource-quantity))
(define recipe-flow-effort-quantity
  (record-accessor <recipe-flow> 'effort-quantity))
(define recipe-flow-recipe-input-of
  (record-accessor <recipe-flow> 'recipe-input-of))
(define recipe-flow-recipe-output-of
  (record-accessor <recipe-flow> 'recipe-output-of))
(define recipe-flow-recipe-clause-of
  (record-accessor <recipe-flow> 'recipe-clause-of))
(define recipe-flow-stage
  (record-accessor <recipe-flow> 'stage))
(define recipe-flow-state
  (record-accessor <recipe-flow> 'state))
(define recipe-flow-note
  (record-accessor <recipe-flow> 'note))
(define recipe-flow-is-primary
  (record-accessor <recipe-flow> 'is-primary))
(define recipe-flow-resolve-from-flow
  (record-accessor <recipe-flow> 'resolve-from-flow))


;;; RecipeProcess — a template process step in a recipe.
;;; Fields: id (string), name (string), note? (string), image? (string),
;;;         process-conforms-to? (string: ProcessSpecification ID),
;;;         process-classified-as? (list of strings),
;;;         has-duration? (<duration>),
;;;         sequence-group? (integer),
;;;         minimum-batch-quantity? (<measure>).
(define <recipe-process>
  (make-record-type 'RecipeProcess
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable image)
      (immutable process-conforms-to)
      (immutable process-classified-as)
      (immutable has-duration)
      (immutable sequence-group)
      (immutable minimum-batch-quantity))))

(define make-recipe-process
  (record-constructor <recipe-process>))
(define recipe-process?
  (record-predicate <recipe-process>))
(define recipe-process-id
  (record-accessor <recipe-process> 'id))
(define recipe-process-name
  (record-accessor <recipe-process> 'name))
(define recipe-process-note
  (record-accessor <recipe-process> 'note))
(define recipe-process-image
  (record-accessor <recipe-process> 'image))
(define recipe-process-process-conforms-to
  (record-accessor <recipe-process> 'process-conforms-to))
(define recipe-process-process-classified-as
  (record-accessor <recipe-process> 'process-classified-as))
(define recipe-process-has-duration
  (record-accessor <recipe-process> 'has-duration))
(define recipe-process-sequence-group
  (record-accessor <recipe-process> 'sequence-group))
(define recipe-process-minimum-batch-quantity
  (record-accessor <recipe-process> 'minimum-batch-quantity))


;;; RecipeExchange — a template exchange agreement in a recipe.
;;; Fields: id (string), name? (string), note? (string).
(define <recipe-exchange>
  (make-record-type 'RecipeExchange
    '((immutable id)
      (immutable name)
      (immutable note))))

(define make-recipe-exchange
  (record-constructor <recipe-exchange>))
(define recipe-exchange?
  (record-predicate <recipe-exchange>))
(define recipe-exchange-id
  (record-accessor <recipe-exchange> 'id))
(define recipe-exchange-name
  (record-accessor <recipe-exchange> 'name))
(define recipe-exchange-note
  (record-accessor <recipe-exchange> 'note))


;;; Recipe — groups RecipeProcesses and RecipeExchanges into a reusable template.
;;; Fields: id (string), name (string), note? (string),
;;;         based-on? (string: ResourceSpecification ID),
;;;         primary-output? (string: ResourceSpecification ID),
;;;         recipe-processes? (list of strings: RecipeProcess IDs),
;;;         recipe-exchanges? (list of strings: RecipeExchange IDs).
(define <recipe>
  (make-record-type 'Recipe
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable based-on)
      (immutable primary-output)
      (immutable recipe-processes)
      (immutable recipe-exchanges))))

(define make-recipe              (record-constructor <recipe>))
(define recipe?                  (record-predicate   <recipe>))
(define recipe-id                (record-accessor    <recipe> 'id))
(define recipe-name              (record-accessor    <recipe> 'name))
(define recipe-note              (record-accessor    <recipe> 'note))
(define recipe-based-on          (record-accessor    <recipe> 'based-on))
(define recipe-primary-output    (record-accessor    <recipe> 'primary-output))
(define recipe-recipe-processes  (record-accessor    <recipe> 'recipe-processes))
(define recipe-recipe-exchanges  (record-accessor    <recipe> 'recipe-exchanges))


;;; RecipeGroup — groups multiple Recipes that together produce more than one output.
;;; Fields: id (string), name (string), note? (string),
;;;         recipes (list of strings: Recipe IDs).
(define <recipe-group>
  (make-record-type 'RecipeGroup
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable recipes))))

(define make-recipe-group      (record-constructor <recipe-group>))
(define recipe-group?          (record-predicate   <recipe-group>))
(define recipe-group-id        (record-accessor    <recipe-group> 'id))
(define recipe-group-name      (record-accessor    <recipe-group> 'name))
(define recipe-group-note      (record-accessor    <recipe-group> 'note))
(define recipe-group-recipes   (record-accessor    <recipe-group> 'recipes))


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
;;;         stage? (string: ProcessSpecification ID), state? (string),
;;;         contained-in? (string: EconomicResource ID),
;;;         unit-of-effort? (string),
;;;         lot? (<batch-lot-record>),
;;;         previous-event? (string: EconomicEvent ID),
;;;         availability-window? (temporal-expression).
(define <economic-resource>
  (make-record-type 'EconomicResource
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
      (immutable availability-window))))

(define make-economic-resource
  (record-constructor <economic-resource>))
(define economic-resource?
  (record-predicate <economic-resource>))
(define economic-resource-id
  (record-accessor <economic-resource> 'id))
(define economic-resource-name
  (record-accessor <economic-resource> 'name))
(define economic-resource-note
  (record-accessor <economic-resource> 'note))
(define economic-resource-image
  (record-accessor <economic-resource> 'image))
(define economic-resource-tracking-identifier
  (record-accessor <economic-resource> 'tracking-identifier))
(define economic-resource-conforms-to
  (record-accessor <economic-resource> 'conforms-to))
(define economic-resource-classified-as
  (record-accessor <economic-resource> 'classified-as))
(define economic-resource-accounting-quantity
  (record-accessor <economic-resource> 'accounting-quantity))
(define economic-resource-onhand-quantity
  (record-accessor <economic-resource> 'onhand-quantity))
(define economic-resource-current-location
  (record-accessor <economic-resource> 'current-location))
(define economic-resource-current-virtual-location
  (record-accessor <economic-resource> 'current-virtual-location))
(define economic-resource-primary-accountable
  (record-accessor <economic-resource> 'primary-accountable))
(define economic-resource-custodian-scope
  (record-accessor <economic-resource> 'custodian-scope))
(define economic-resource-stage
  (record-accessor <economic-resource> 'stage))
(define economic-resource-state
  (record-accessor <economic-resource> 'state))
(define economic-resource-contained-in
  (record-accessor <economic-resource> 'contained-in))
(define economic-resource-unit-of-effort
  (record-accessor <economic-resource> 'unit-of-effort))
(define economic-resource-lot
  (record-accessor <economic-resource> 'lot))
(define economic-resource-previous-event
  (record-accessor <economic-resource> 'previous-event))
(define economic-resource-availability-window
  (record-accessor <economic-resource> 'availability-window))


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
;;;         previous-event? (string: EconomicEvent ID),
;;;         exclude-from-adu? (boolean),
;;;         market-value? (number).
(define <economic-event>
  (make-record-type 'EconomicEvent
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
      (immutable exclude-from-adu)
      (immutable market-value))))

(define make-economic-event
  (record-constructor <economic-event>))
(define economic-event?
  (record-predicate <economic-event>))
(define economic-event-id
  (record-accessor <economic-event> 'id))
(define economic-event-action
  (record-accessor <economic-event> 'action))
(define economic-event-input-of
  (record-accessor <economic-event> 'input-of))
(define economic-event-output-of
  (record-accessor <economic-event> 'output-of))
(define economic-event-resource-inventoried-as
  (record-accessor <economic-event> 'resource-inventoried-as))
(define economic-event-to-resource-inventoried-as
  (record-accessor <economic-event> 'to-resource-inventoried-as))
(define economic-event-resource-conforms-to
  (record-accessor <economic-event> 'resource-conforms-to))
(define economic-event-resource-classified-as
  (record-accessor <economic-event> 'resource-classified-as))
(define economic-event-provider
  (record-accessor <economic-event> 'provider))
(define economic-event-receiver
  (record-accessor <economic-event> 'receiver))
(define economic-event-resource-quantity
  (record-accessor <economic-event> 'resource-quantity))
(define economic-event-effort-quantity
  (record-accessor <economic-event> 'effort-quantity))
(define economic-event-has-beginning
  (record-accessor <economic-event> 'has-beginning))
(define economic-event-has-end
  (record-accessor <economic-event> 'has-end))
(define economic-event-has-point-in-time
  (record-accessor <economic-event> 'has-point-in-time))
(define economic-event-created
  (record-accessor <economic-event> 'created))
(define economic-event-at-location
  (record-accessor <economic-event> 'at-location))
(define economic-event-to-location
  (record-accessor <economic-event> 'to-location))
(define economic-event-state
  (record-accessor <economic-event> 'state))
(define economic-event-fulfills
  (record-accessor <economic-event> 'fulfills))
(define economic-event-satisfies
  (record-accessor <economic-event> 'satisfies))
(define economic-event-corrects
  (record-accessor <economic-event> 'corrects))
(define economic-event-realization-of
  (record-accessor <economic-event> 'realization-of))
(define economic-event-settles
  (record-accessor <economic-event> 'settles))
(define economic-event-note
  (record-accessor <economic-event> 'note))
(define economic-event-in-scope-of
  (record-accessor <economic-event> 'in-scope-of))
(define economic-event-previous-event
  (record-accessor <economic-event> 'previous-event))
(define economic-event-exclude-from-adu
  (record-accessor <economic-event> 'exclude-from-adu))
(define economic-event-market-value
  (record-accessor <economic-event> 'market-value))


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
  (make-record-type 'Process
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

(define make-process              (record-constructor <process>))
(define process?                  (record-predicate   <process>))
(define process-id                (record-accessor    <process> 'id))
(define process-name              (record-accessor    <process> 'name))
(define process-note              (record-accessor    <process> 'note))
(define process-based-on          (record-accessor    <process> 'based-on))
(define process-classified-as     (record-accessor    <process> 'classified-as))
(define process-planned-within    (record-accessor    <process> 'planned-within))
(define process-nested-in         (record-accessor    <process> 'nested-in))
(define process-in-scope-of       (record-accessor    <process> 'in-scope-of))
(define process-has-beginning     (record-accessor    <process> 'has-beginning))
(define process-has-end           (record-accessor    <process> 'has-end))
(define process-finished          (record-accessor    <process> 'finished))


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
  (make-record-type 'Intent
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

(define make-intent                          (record-constructor <intent>))
(define intent?                              (record-predicate   <intent>))
(define intent-id                            (record-accessor    <intent> 'id))
(define intent-action                        (record-accessor    <intent> 'action))
(define intent-name                          (record-accessor    <intent> 'name))
(define intent-note                          (record-accessor    <intent> 'note))
(define intent-image                         (record-accessor    <intent> 'image))
(define intent-input-of                      (record-accessor    <intent> 'input-of))
(define intent-output-of                     (record-accessor    <intent> 'output-of))
(define intent-resource-inventoried-as       (record-accessor    <intent> 'resource-inventoried-as))
(define intent-resource-conforms-to          (record-accessor    <intent> 'resource-conforms-to))
(define intent-resource-classified-as        (record-accessor    <intent> 'resource-classified-as))
(define intent-resource-quantity             (record-accessor    <intent> 'resource-quantity))
(define intent-effort-quantity               (record-accessor    <intent> 'effort-quantity))
(define intent-available-quantity            (record-accessor    <intent> 'available-quantity))
(define intent-minimum-quantity              (record-accessor    <intent> 'minimum-quantity))
(define intent-provider                      (record-accessor    <intent> 'provider))
(define intent-receiver                      (record-accessor    <intent> 'receiver))
(define intent-has-beginning                 (record-accessor    <intent> 'has-beginning))
(define intent-has-end                       (record-accessor    <intent> 'has-end))
(define intent-has-point-in-time             (record-accessor    <intent> 'has-point-in-time))
(define intent-due                           (record-accessor    <intent> 'due))
(define intent-at-location                   (record-accessor    <intent> 'at-location))
(define intent-stage                         (record-accessor    <intent> 'stage))
(define intent-state                         (record-accessor    <intent> 'state))
(define intent-planned-within                (record-accessor    <intent> 'planned-within))
(define intent-satisfies                     (record-accessor    <intent> 'satisfies))
(define intent-in-scope-of                   (record-accessor    <intent> 'in-scope-of))
(define intent-finished                      (record-accessor    <intent> 'finished))
(define intent-availability-window           (record-accessor    <intent> 'availability-window))


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
  (make-record-type 'Commitment
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

(define make-commitment
  (record-constructor <commitment>))
(define commitment?
  (record-predicate <commitment>))
(define commitment-id
  (record-accessor <commitment> 'id))
(define commitment-action
  (record-accessor <commitment> 'action))
(define commitment-note
  (record-accessor <commitment> 'note))
(define commitment-input-of
  (record-accessor <commitment> 'input-of))
(define commitment-output-of
  (record-accessor <commitment> 'output-of))
(define commitment-resource-inventoried-as
  (record-accessor <commitment> 'resource-inventoried-as))
(define commitment-resource-conforms-to
  (record-accessor <commitment> 'resource-conforms-to))
(define commitment-resource-classified-as
  (record-accessor <commitment> 'resource-classified-as))
(define commitment-resource-quantity
  (record-accessor <commitment> 'resource-quantity))
(define commitment-effort-quantity
  (record-accessor <commitment> 'effort-quantity))
(define commitment-provider
  (record-accessor <commitment> 'provider))
(define commitment-receiver
  (record-accessor <commitment> 'receiver))
(define commitment-has-beginning
  (record-accessor <commitment> 'has-beginning))
(define commitment-has-end
  (record-accessor <commitment> 'has-end))
(define commitment-has-point-in-time
  (record-accessor <commitment> 'has-point-in-time))
(define commitment-due
  (record-accessor <commitment> 'due))
(define commitment-created
  (record-accessor <commitment> 'created))
(define commitment-at-location
  (record-accessor <commitment> 'at-location))
(define commitment-in-scope-of
  (record-accessor <commitment> 'in-scope-of))
(define commitment-stage
  (record-accessor <commitment> 'stage))
(define commitment-state
  (record-accessor <commitment> 'state))
(define commitment-satisfies
  (record-accessor <commitment> 'satisfies))
(define commitment-clause-of
  (record-accessor <commitment> 'clause-of))
(define commitment-independent-demand-of
  (record-accessor <commitment> 'independent-demand-of))
(define commitment-planned-within
  (record-accessor <commitment> 'planned-within))
(define commitment-finished
  (record-accessor <commitment> 'finished))
(define commitment-availability-window
  (record-accessor <commitment> 'availability-window))


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
  (make-record-type 'Claim
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

(define make-claim                        (record-constructor <claim>))
(define claim?                            (record-predicate   <claim>))
(define claim-id                          (record-accessor    <claim> 'id))
(define claim-action                      (record-accessor    <claim> 'action))
(define claim-provider                    (record-accessor    <claim> 'provider))
(define claim-receiver                    (record-accessor    <claim> 'receiver))
(define claim-triggered-by                (record-accessor    <claim> 'triggered-by))
(define claim-resource-quantity            (record-accessor    <claim> 'resource-quantity))
(define claim-effort-quantity              (record-accessor    <claim> 'effort-quantity))
(define claim-resource-conforms-to         (record-accessor    <claim> 'resource-conforms-to))
(define claim-resource-classified-as       (record-accessor    <claim> 'resource-classified-as))
(define claim-due                          (record-accessor    <claim> 'due))
(define claim-created                      (record-accessor    <claim> 'created))
(define claim-note                         (record-accessor    <claim> 'note))
(define claim-finished                     (record-accessor    <claim> 'finished))


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
  (make-record-type 'Plan
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable due)
      (immutable created)
      (immutable has-independent-demand)
      (immutable refinement-of)
      (immutable classified-as))))

(define make-plan                       (record-constructor <plan>))
(define plan?                           (record-predicate   <plan>))
(define plan-id                         (record-accessor    <plan> 'id))
(define plan-name                       (record-accessor    <plan> 'name))
(define plan-note                       (record-accessor    <plan> 'note))
(define plan-due                        (record-accessor    <plan> 'due))
(define plan-created                    (record-accessor    <plan> 'created))
(define plan-has-independent-demand     (record-accessor    <plan> 'has-independent-demand))
(define plan-refinement-of              (record-accessor    <plan> 'refinement-of))
(define plan-classified-as              (record-accessor    <plan> 'classified-as))


;; ═══════════════════════════════════════════════════════════════════════
;; ESTIMATION / ANALYSIS LAYER — Scenarios
;; ═══════════════════════════════════════════════════════════════════════

;;; ScenarioDefinition — a named category or template for a kind of scenario.
;;; Fields: id (string), name (string), note? (string),
;;;         has-duration? (<duration>), in-scope-of? (string: Agent ID).
(define <scenario-definition>
  (make-record-type 'ScenarioDefinition
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable has-duration)
      (immutable in-scope-of))))

(define make-scenario-definition
  (record-constructor <scenario-definition>))
(define scenario-definition?
  (record-predicate <scenario-definition>))
(define scenario-definition-id
  (record-accessor <scenario-definition> 'id))
(define scenario-definition-name
  (record-accessor <scenario-definition> 'name))
(define scenario-definition-note
  (record-accessor <scenario-definition> 'note))
(define scenario-definition-has-duration
  (record-accessor <scenario-definition> 'has-duration))
(define scenario-definition-in-scope-of
  (record-accessor <scenario-definition> 'in-scope-of))


;;; Scenario — a grouping of processes, intents, plans for analysis/budgeting.
;;; Fields: id (string), name (string), note? (string),
;;;         defined-as? (string: ScenarioDefinition ID),
;;;         refinement-of? (string: Scenario ID),
;;;         has-beginning? (ISO datetime), has-end? (ISO datetime),
;;;         in-scope-of? (string: Agent ID).
(define <scenario>
  (make-record-type 'Scenario
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable defined-as)
      (immutable refinement-of)
      (immutable has-beginning)
      (immutable has-end)
      (immutable in-scope-of))))

(define make-scenario              (record-constructor <scenario>))
(define scenario?                  (record-predicate   <scenario>))
(define scenario-id                (record-accessor    <scenario> 'id))
(define scenario-name              (record-accessor    <scenario> 'name))
(define scenario-note              (record-accessor    <scenario> 'note))
(define scenario-defined-as        (record-accessor    <scenario> 'defined-as))
(define scenario-refinement-of     (record-accessor    <scenario> 'refinement-of))
(define scenario-has-beginning     (record-accessor    <scenario> 'has-beginning))
(define scenario-has-end           (record-accessor    <scenario> 'has-end))
(define scenario-in-scope-of       (record-accessor    <scenario> 'in-scope-of))


;; ═══════════════════════════════════════════════════════════════════════
;; AGREEMENTS & EXCHANGES
;; ═══════════════════════════════════════════════════════════════════════

;;; Agreement — a mutual agreement between agents.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime),
;;;         stipulates? (list of strings: primary Commitment IDs),
;;;         stipulates-reciprocal? (list of strings: reciprocal Commitment IDs).
(define <agreement>
  (make-record-type 'Agreement
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable stipulates)
      (immutable stipulates-reciprocal))))

(define make-agreement                       (record-constructor <agreement>))
(define agreement?                           (record-predicate   <agreement>))
(define agreement-id                         (record-accessor    <agreement> 'id))
(define agreement-name                       (record-accessor    <agreement> 'name))
(define agreement-note                       (record-accessor    <agreement> 'note))
(define agreement-created                    (record-accessor    <agreement> 'created))
(define agreement-stipulates                 (record-accessor    <agreement> 'stipulates))
(define agreement-stipulates-reciprocal      (record-accessor    <agreement> 'stipulates-reciprocal))


;;; AgreementBundle — groups multiple Agreements.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), bundles? (list of strings: Agreement IDs).
(define <agreement-bundle>
  (make-record-type 'AgreementBundle
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable bundles))))

(define make-agreement-bundle          (record-constructor <agreement-bundle>))
(define agreement-bundle?              (record-predicate   <agreement-bundle>))
(define agreement-bundle-id            (record-accessor    <agreement-bundle> 'id))
(define agreement-bundle-name          (record-accessor    <agreement-bundle> 'name))
(define agreement-bundle-note          (record-accessor    <agreement-bundle> 'note))
(define agreement-bundle-created       (record-accessor    <agreement-bundle> 'created))
(define agreement-bundle-bundles       (record-accessor    <agreement-bundle> 'bundles))


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
  (make-record-type 'Proposal
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

(define make-proposal                  (record-constructor <proposal>))
(define proposal?                      (record-predicate   <proposal>))
(define proposal-id                    (record-accessor    <proposal> 'id))
(define proposal-name                  (record-accessor    <proposal> 'name))
(define proposal-note                  (record-accessor    <proposal> 'note))
(define proposal-has-beginning         (record-accessor    <proposal> 'has-beginning))
(define proposal-has-end               (record-accessor    <proposal> 'has-end))
(define proposal-unit-based            (record-accessor    <proposal> 'unit-based))
(define proposal-created               (record-accessor    <proposal> 'created))
(define proposal-purpose               (record-accessor    <proposal> 'purpose))
(define proposal-eligible-location     (record-accessor    <proposal> 'eligible-location))
(define proposal-in-scope-of           (record-accessor    <proposal> 'in-scope-of))
(define proposal-publishes             (record-accessor    <proposal> 'publishes))
(define proposal-reciprocal            (record-accessor    <proposal> 'reciprocal))
(define proposal-proposed-to           (record-accessor    <proposal> 'proposed-to))


;;; ProposalList — groups multiple Proposals.
;;; Fields: id (string), name? (string), note? (string),
;;;         created? (ISO datetime), lists? (list of strings: Proposal IDs).
(define <proposal-list>
  (make-record-type 'ProposalList
    '((immutable id)
      (immutable name)
      (immutable note)
      (immutable created)
      (immutable lists))))

(define make-proposal-list          (record-constructor <proposal-list>))
(define proposal-list?              (record-predicate   <proposal-list>))
(define proposal-list-id            (record-accessor    <proposal-list> 'id))
(define proposal-list-name          (record-accessor    <proposal-list> 'name))
(define proposal-list-note          (record-accessor    <proposal-list> 'note))
(define proposal-list-created       (record-accessor    <proposal-list> 'created))
(define proposal-list-lists         (record-accessor    <proposal-list> 'lists))


;; ═══════════════════════════════════════════════════════════════════════
;; DDMRP BUFFER MANAGEMENT
;; ═══════════════════════════════════════════════════════════════════════

;;; BufferProfile — DDS&OP master settings for a category of buffered items.
;;; One profile per (itemType x leadTimeBand x variabilityBand) combination.
;;; Fields:
;;;   id (string), name (string),
;;;   item-type (symbol: purchased | manufactured | intermediate | distributed),
;;;   lead-time-factor (number, positive),
;;;   vrd? (symbol: low | medium | high),
;;;   vrs? (symbol: low | medium | high),
;;;   variability-factor (number, nonneg),
;;;   order-cycle-days? (number, positive),
;;;   ost-multiplier? (number, positive),
;;;   recalculation-cadence? (symbol: daily | weekly | monthly),
;;;   lead-time-category? (symbol: short | medium | long),
;;;   variability-category? (symbol: low | medium | high),
;;;   code? (string: 3-letter profile code),
;;;   note? (string).
(define *buffer-item-types*
  '(purchased manufactured intermediate distributed))

(define (buffer-item-type? x)
  (and (symbol? x) (memq x *buffer-item-types*) #t))

(define <buffer-profile>
  (make-record-type 'BufferProfile
    '((immutable id)
      (immutable name)
      (immutable item-type)
      (immutable lead-time-factor)
      (immutable vrd)
      (immutable vrs)
      (immutable variability-factor)
      (immutable order-cycle-days)
      (immutable ost-multiplier)
      (immutable recalculation-cadence)
      (immutable lead-time-category)
      (immutable variability-category)
      (immutable code)
      (immutable note))))

(define make-buffer-profile
  (record-constructor <buffer-profile>))
(define buffer-profile?
  (record-predicate <buffer-profile>))
(define buffer-profile-id
  (record-accessor <buffer-profile> 'id))
(define buffer-profile-name
  (record-accessor <buffer-profile> 'name))
(define buffer-profile-item-type
  (record-accessor <buffer-profile> 'item-type))
(define buffer-profile-lead-time-factor
  (record-accessor <buffer-profile> 'lead-time-factor))
(define buffer-profile-vrd
  (record-accessor <buffer-profile> 'vrd))
(define buffer-profile-vrs
  (record-accessor <buffer-profile> 'vrs))
(define buffer-profile-variability-factor
  (record-accessor <buffer-profile> 'variability-factor))
(define buffer-profile-order-cycle-days
  (record-accessor <buffer-profile> 'order-cycle-days))
(define buffer-profile-ost-multiplier
  (record-accessor <buffer-profile> 'ost-multiplier))
(define buffer-profile-recalculation-cadence
  (record-accessor <buffer-profile> 'recalculation-cadence))
(define buffer-profile-lead-time-category
  (record-accessor <buffer-profile> 'lead-time-category))
(define buffer-profile-variability-category
  (record-accessor <buffer-profile> 'variability-category))
(define buffer-profile-code
  (record-accessor <buffer-profile> 'code))
(define buffer-profile-note
  (record-accessor <buffer-profile> 'note))


;;; BufferZone — per-ResourceSpecification computed DDMRP buffer parameters.
;;; Zone boundaries (all in adu-unit units):
;;;   red base   = ADU x DLT x LTF
;;;   red safety = red base x VF
;;;   TOR        = red base + red safety = ADU x DLT x LTF x (1 + VF)
;;;   TOY        = TOR + ADU x DLT
;;;   TOG        = TOY + max(ADU x orderCycleDays, MOQ)
;;;
;;; Fields:
;;;   id (string), spec-id (string: ResourceSpecification ID),
;;;   profile-id (string: BufferProfile ID),
;;;   buffer-classification (symbol: replenished | replenished-override | min-max),
;;;   at-location? (string: SpatialThing ID),
;;;   upstream-location-id? (string: SpatialThing ID),
;;;   replenishment-recipe-id? (string: Recipe ID),
;;;   upstream-stage-id? (string), downstream-stage-id? (string),
;;;   adu (number, nonneg), adu-unit (string),
;;;   adu-blend-ratio? (number, 0-1), adu-window-days? (number, positive),
;;;   adu-computed-from? (string: ISO date),
;;;   adu-alert-high-pct? (number, positive),
;;;   adu-alert-low-pct? (number, positive),
;;;   adu-alert-window-days? (number, positive),
;;;   estimated-adu? (number, nonneg),
;;;   bootstrap-days-accumulated? (number, nonneg),
;;;   ost-horizon-days? (number, positive),
;;;   dlt-days (number, nonneg), moq (number, nonneg), moq-unit (string),
;;;   order-cycle-days? (number, positive),
;;;   override-reason? (symbol: space | cash | contractual | other),
;;;   override-note? (string),
;;;   transport-days? (number, nonneg), staging-days? (number, nonneg),
;;;   tor (number, nonneg), toy (number, nonneg), tog (number, nonneg),
;;;   tipping-point? (number, nonneg),
;;;   red-base? (number, nonneg), red-safety? (number, nonneg),
;;;   demand-adj-factor? (number, positive),
;;;   zone-adj-factor? (number, positive),
;;;   lead-time-adj-factor? (number, positive),
;;;   supply-offset-days? (number),
;;;   active-adjustment-ids? (list of strings),
;;;   last-computed-at (ISO datetime string).
(define *buffer-classifications*
  '(replenished replenished-override min-max))

(define (buffer-classification? x)
  (and (symbol? x) (memq x *buffer-classifications*) #t))

(define *override-reasons* '(space cash contractual other))

(define (override-reason? x)
  (and (symbol? x) (memq x *override-reasons*) #t))

(define <buffer-zone>
  (make-record-type 'BufferZone
    '((immutable id)
      (immutable spec-id)
      (immutable profile-id)
      (immutable buffer-classification)
      (immutable at-location)
      (immutable upstream-location-id)
      (immutable replenishment-recipe-id)
      (immutable upstream-stage-id)
      (immutable downstream-stage-id)
      (immutable adu)
      (immutable adu-unit)
      (immutable adu-blend-ratio)
      (immutable adu-window-days)
      (immutable adu-computed-from)
      (immutable adu-alert-high-pct)
      (immutable adu-alert-low-pct)
      (immutable adu-alert-window-days)
      (immutable estimated-adu)
      (immutable bootstrap-days-accumulated)
      (immutable ost-horizon-days)
      (immutable dlt-days)
      (immutable moq)
      (immutable moq-unit)
      (immutable order-cycle-days)
      (immutable override-reason)
      (immutable override-note)
      (immutable transport-days)
      (immutable staging-days)
      (immutable tor)
      (immutable toy)
      (immutable tog)
      (immutable tipping-point)
      (immutable red-base)
      (immutable red-safety)
      (immutable demand-adj-factor)
      (immutable zone-adj-factor)
      (immutable lead-time-adj-factor)
      (immutable supply-offset-days)
      (immutable active-adjustment-ids)
      (immutable last-computed-at))))

(define make-buffer-zone
  (record-constructor <buffer-zone>))
(define buffer-zone?
  (record-predicate <buffer-zone>))
(define buffer-zone-id
  (record-accessor <buffer-zone> 'id))
(define buffer-zone-spec-id
  (record-accessor <buffer-zone> 'spec-id))
(define buffer-zone-profile-id
  (record-accessor <buffer-zone> 'profile-id))
(define buffer-zone-buffer-classification
  (record-accessor <buffer-zone> 'buffer-classification))
(define buffer-zone-at-location
  (record-accessor <buffer-zone> 'at-location))
(define buffer-zone-upstream-location-id
  (record-accessor <buffer-zone> 'upstream-location-id))
(define buffer-zone-replenishment-recipe-id
  (record-accessor <buffer-zone> 'replenishment-recipe-id))
(define buffer-zone-upstream-stage-id
  (record-accessor <buffer-zone> 'upstream-stage-id))
(define buffer-zone-downstream-stage-id
  (record-accessor <buffer-zone> 'downstream-stage-id))
(define buffer-zone-adu
  (record-accessor <buffer-zone> 'adu))
(define buffer-zone-adu-unit
  (record-accessor <buffer-zone> 'adu-unit))
(define buffer-zone-adu-blend-ratio
  (record-accessor <buffer-zone> 'adu-blend-ratio))
(define buffer-zone-adu-window-days
  (record-accessor <buffer-zone> 'adu-window-days))
(define buffer-zone-adu-computed-from
  (record-accessor <buffer-zone> 'adu-computed-from))
(define buffer-zone-adu-alert-high-pct
  (record-accessor <buffer-zone> 'adu-alert-high-pct))
(define buffer-zone-adu-alert-low-pct
  (record-accessor <buffer-zone> 'adu-alert-low-pct))
(define buffer-zone-adu-alert-window-days
  (record-accessor <buffer-zone> 'adu-alert-window-days))
(define buffer-zone-estimated-adu
  (record-accessor <buffer-zone> 'estimated-adu))
(define buffer-zone-bootstrap-days-accumulated
  (record-accessor <buffer-zone> 'bootstrap-days-accumulated))
(define buffer-zone-ost-horizon-days
  (record-accessor <buffer-zone> 'ost-horizon-days))
(define buffer-zone-dlt-days
  (record-accessor <buffer-zone> 'dlt-days))
(define buffer-zone-moq
  (record-accessor <buffer-zone> 'moq))
(define buffer-zone-moq-unit
  (record-accessor <buffer-zone> 'moq-unit))
(define buffer-zone-order-cycle-days
  (record-accessor <buffer-zone> 'order-cycle-days))
(define buffer-zone-override-reason
  (record-accessor <buffer-zone> 'override-reason))
(define buffer-zone-override-note
  (record-accessor <buffer-zone> 'override-note))
(define buffer-zone-transport-days
  (record-accessor <buffer-zone> 'transport-days))
(define buffer-zone-staging-days
  (record-accessor <buffer-zone> 'staging-days))
(define buffer-zone-tor
  (record-accessor <buffer-zone> 'tor))
(define buffer-zone-toy
  (record-accessor <buffer-zone> 'toy))
(define buffer-zone-tog
  (record-accessor <buffer-zone> 'tog))
(define buffer-zone-tipping-point
  (record-accessor <buffer-zone> 'tipping-point))
(define buffer-zone-red-base
  (record-accessor <buffer-zone> 'red-base))
(define buffer-zone-red-safety
  (record-accessor <buffer-zone> 'red-safety))
(define buffer-zone-demand-adj-factor
  (record-accessor <buffer-zone> 'demand-adj-factor))
(define buffer-zone-zone-adj-factor
  (record-accessor <buffer-zone> 'zone-adj-factor))
(define buffer-zone-lead-time-adj-factor
  (record-accessor <buffer-zone> 'lead-time-adj-factor))
(define buffer-zone-supply-offset-days
  (record-accessor <buffer-zone> 'supply-offset-days))
(define buffer-zone-active-adjustment-ids
  (record-accessor <buffer-zone> 'active-adjustment-ids))
(define buffer-zone-last-computed-at
  (record-accessor <buffer-zone> 'last-computed-at))


;;; ReplenishmentSignal — an NFP-triggered supply order proposal.
;;; Created when NFP <= TOY. Carries all inputs to the replenishment decision.
;;; Fields:
;;;   id (string), spec-id (string: ResourceSpecification ID),
;;;   at-location? (string: SpatialThing ID),
;;;   buffer-zone-id (string: BufferZone ID),
;;;   onhand (number), onorder (number, nonneg),
;;;   qualified-demand (number, nonneg),
;;;   nfp (number — can be negative),
;;;   priority (number: NFP / TOG),
;;;   zone (symbol: red | yellow | green | excess),
;;;   recommended-qty (number, positive),
;;;   due-date (string: ISO date),
;;;   status (symbol: open | approved | rejected),
;;;   approved-commitment-id? (string: Commitment ID),
;;;   created-at (ISO datetime string).
(define *buffer-zones-enum* '(red yellow green excess))

(define (buffer-zone-enum? x)
  (and (symbol? x) (memq x *buffer-zones-enum*) #t))

(define *replenishment-statuses* '(open approved rejected))

(define (replenishment-status? x)
  (and (symbol? x) (memq x *replenishment-statuses*) #t))

(define <replenishment-signal>
  (make-record-type 'ReplenishmentSignal
    '((immutable id)
      (immutable spec-id)
      (immutable at-location)
      (immutable buffer-zone-id)
      (immutable onhand)
      (immutable onorder)
      (immutable qualified-demand)
      (immutable nfp)
      (immutable priority)
      (immutable zone)
      (immutable recommended-qty)
      (immutable due-date)
      (immutable status)
      (immutable approved-commitment-id)
      (immutable created-at))))

(define make-replenishment-signal
  (record-constructor <replenishment-signal>))
(define replenishment-signal?
  (record-predicate <replenishment-signal>))
(define replenishment-signal-id
  (record-accessor <replenishment-signal> 'id))
(define replenishment-signal-spec-id
  (record-accessor <replenishment-signal> 'spec-id))
(define replenishment-signal-at-location
  (record-accessor <replenishment-signal> 'at-location))
(define replenishment-signal-buffer-zone-id
  (record-accessor <replenishment-signal> 'buffer-zone-id))
(define replenishment-signal-onhand
  (record-accessor <replenishment-signal> 'onhand))
(define replenishment-signal-onorder
  (record-accessor <replenishment-signal> 'onorder))
(define replenishment-signal-qualified-demand
  (record-accessor <replenishment-signal> 'qualified-demand))
(define replenishment-signal-nfp
  (record-accessor <replenishment-signal> 'nfp))
(define replenishment-signal-priority
  (record-accessor <replenishment-signal> 'priority))
(define replenishment-signal-zone
  (record-accessor <replenishment-signal> 'zone))
(define replenishment-signal-recommended-qty
  (record-accessor <replenishment-signal> 'recommended-qty))
(define replenishment-signal-due-date
  (record-accessor <replenishment-signal> 'due-date))
(define replenishment-signal-status
  (record-accessor <replenishment-signal> 'status))
(define replenishment-signal-approved-commitment-id
  (record-accessor <replenishment-signal> 'approved-commitment-id))
(define replenishment-signal-created-at
  (record-accessor <replenishment-signal> 'created-at))


;;; DemandAdjustmentFactor — DDS&OP planned multipliers for buffer zone recalculation.
;;; Three types: demand (multiplies ADU), zone (multiplies zone size), leadTime (multiplies DLT).
;;; Fields:
;;;   id (string), spec-id (string: ResourceSpecification ID),
;;;   at-location? (string: SpatialThing ID),
;;;   type (symbol: demand | zone | lead-time),
;;;   target-zone? (symbol: green | yellow | red),
;;;   factor (number, positive: 1.0 = no change),
;;;   valid-from (string: ISO date), valid-to (string: ISO date),
;;;   supply-offset-days? (number),
;;;   note? (string), is-active? (boolean).
(define *adjustment-types* '(demand zone lead-time))

(define (adjustment-type? x)
  (and (symbol? x) (memq x *adjustment-types*) #t))

(define *target-zones* '(green yellow red))

(define (target-zone? x)
  (and (symbol? x) (memq x *target-zones*) #t))

(define <demand-adjustment-factor>
  (make-record-type 'DemandAdjustmentFactor
    '((immutable id)
      (immutable spec-id)
      (immutable at-location)
      (immutable type)
      (immutable target-zone)
      (immutable factor)
      (immutable valid-from)
      (immutable valid-to)
      (immutable supply-offset-days)
      (immutable note)
      (immutable is-active))))

(define make-demand-adjustment-factor
  (record-constructor <demand-adjustment-factor>))
(define demand-adjustment-factor?
  (record-predicate <demand-adjustment-factor>))
(define demand-adjustment-factor-id
  (record-accessor <demand-adjustment-factor> 'id))
(define demand-adjustment-factor-spec-id
  (record-accessor <demand-adjustment-factor> 'spec-id))
(define demand-adjustment-factor-at-location
  (record-accessor <demand-adjustment-factor> 'at-location))
(define demand-adjustment-factor-type
  (record-accessor <demand-adjustment-factor> 'type))
(define demand-adjustment-factor-target-zone
  (record-accessor <demand-adjustment-factor> 'target-zone))
(define demand-adjustment-factor-factor
  (record-accessor <demand-adjustment-factor> 'factor))
(define demand-adjustment-factor-valid-from
  (record-accessor <demand-adjustment-factor> 'valid-from))
(define demand-adjustment-factor-valid-to
  (record-accessor <demand-adjustment-factor> 'valid-to))
(define demand-adjustment-factor-supply-offset-days
  (record-accessor <demand-adjustment-factor> 'supply-offset-days))
(define demand-adjustment-factor-note
  (record-accessor <demand-adjustment-factor> 'note))
(define demand-adjustment-factor-is-active
  (record-accessor <demand-adjustment-factor> 'is-active))


;; ═══════════════════════════════════════════════════════════════════════
;; BUFFER SNAPSHOTS (time-series health tracking)
;; ═══════════════════════════════════════════════════════════════════════

;;; BufferSnapshot — a point-in-time buffer health reading.
;;; Fields: spec-id (string), date (string "YYYY-MM-DD"),
;;;         onhand (number), tor (number), toy (number), tog (number),
;;;         zone (symbol: red | yellow | green | excess).
(define <buffer-snapshot>
  (make-record-type 'BufferSnapshot
    '((immutable spec-id)
      (immutable date)
      (immutable onhand)
      (immutable tor)
      (immutable toy)
      (immutable tog)
      (immutable zone))))

(define make-buffer-snapshot        (record-constructor <buffer-snapshot>))
(define buffer-snapshot?            (record-predicate   <buffer-snapshot>))
(define buffer-snapshot-spec-id     (record-accessor    <buffer-snapshot> 'spec-id))
(define buffer-snapshot-date        (record-accessor    <buffer-snapshot> 'date))
(define buffer-snapshot-onhand      (record-accessor    <buffer-snapshot> 'onhand))
(define buffer-snapshot-tor         (record-accessor    <buffer-snapshot> 'tor))
(define buffer-snapshot-toy         (record-accessor    <buffer-snapshot> 'toy))
(define buffer-snapshot-tog         (record-accessor    <buffer-snapshot> 'tog))
(define buffer-snapshot-zone        (record-accessor    <buffer-snapshot> 'zone))


;; ═══════════════════════════════════════════════════════════════════════
;; OBSERVER TRACKING STATE
;; ═══════════════════════════════════════════════════════════════════════

;;; FulfillmentState — tracks how much of a Commitment has been fulfilled.
;;; Fields: commitment-id (string), total-committed (<measure>),
;;;         total-fulfilled (<measure>), fulfilling-events (list of event IDs),
;;;         finished (boolean), over-fulfilled (boolean).
(define <fulfillment-state>
  (make-record-type 'FulfillmentState
    '((immutable commitment-id)
      (immutable total-committed)
      (immutable total-fulfilled)
      (immutable fulfilling-events)
      (immutable finished)
      (immutable over-fulfilled))))

(define make-fulfillment-state              (record-constructor <fulfillment-state>))
(define fulfillment-state?                  (record-predicate   <fulfillment-state>))
(define fulfillment-state-commitment-id     (record-accessor    <fulfillment-state> 'commitment-id))
(define fulfillment-state-total-committed   (record-accessor    <fulfillment-state> 'total-committed))
(define fulfillment-state-total-fulfilled   (record-accessor    <fulfillment-state> 'total-fulfilled))
(define fulfillment-state-fulfilling-events (record-accessor    <fulfillment-state> 'fulfilling-events))
(define fulfillment-state-finished          (record-accessor    <fulfillment-state> 'finished))
(define fulfillment-state-over-fulfilled    (record-accessor    <fulfillment-state> 'over-fulfilled))


;;; SatisfactionState — tracks how much of an Intent has been satisfied.
;;; Fields: intent-id (string), total-desired (<measure>),
;;;         total-satisfied (<measure>), satisfying-events (list of event IDs),
;;;         satisfying-commitments (list of commitment IDs), finished (boolean).
(define <satisfaction-state>
  (make-record-type 'SatisfactionState
    '((immutable intent-id)
      (immutable total-desired)
      (immutable total-satisfied)
      (immutable satisfying-events)
      (immutable satisfying-commitments)
      (immutable finished))))

(define make-satisfaction-state                  (record-constructor <satisfaction-state>))
(define satisfaction-state?                      (record-predicate   <satisfaction-state>))
(define satisfaction-state-intent-id             (record-accessor    <satisfaction-state> 'intent-id))
(define satisfaction-state-total-desired         (record-accessor    <satisfaction-state> 'total-desired))
(define satisfaction-state-total-satisfied       (record-accessor    <satisfaction-state> 'total-satisfied))
(define satisfaction-state-satisfying-events     (record-accessor    <satisfaction-state> 'satisfying-events))
(define satisfaction-state-satisfying-commitments (record-accessor   <satisfaction-state> 'satisfying-commitments))
(define satisfaction-state-finished              (record-accessor    <satisfaction-state> 'finished))


;;; ClaimState — tracks how much of a Claim has been settled.
;;; Fields: claim-id (string), total-claimed (<measure>),
;;;         total-settled (<measure>), settling-events (list of event IDs),
;;;         finished (boolean).
(define <claim-state>
  (make-record-type 'ClaimState
    '((immutable claim-id)
      (immutable total-claimed)
      (immutable total-settled)
      (immutable settling-events)
      (immutable finished))))

(define make-claim-state              (record-constructor <claim-state>))
(define claim-state?                  (record-predicate   <claim-state>))
(define claim-state-claim-id          (record-accessor    <claim-state> 'claim-id))
(define claim-state-total-claimed     (record-accessor    <claim-state> 'total-claimed))
(define claim-state-total-settled     (record-accessor    <claim-state> 'total-settled))
(define claim-state-settling-events   (record-accessor    <claim-state> 'settling-events))
(define claim-state-finished          (record-accessor    <claim-state> 'finished))


;; ═══════════════════════════════════════════════════════════════════════
;; COMMUNE ACCOUNT (labor-credit system)
;; ═══════════════════════════════════════════════════════════════════════

;;; Account — per-agent labor-credit and claim-capacity tracker.
;;; Fields: agent-id (string),
;;;         gross-contribution-credited (number, running total of SVC hours),
;;;         claimed-capacity (number, running total claimed from pool),
;;;         contribution-capacity-factor (number 0-1, ability to contribute).
(define <account>
  (make-record-type 'Account
    '((immutable agent-id)
      (immutable gross-contribution-credited)
      (immutable claimed-capacity)
      (immutable contribution-capacity-factor))))

(define make-account                              (record-constructor <account>))
(define account?                                  (record-predicate   <account>))
(define account-agent-id                          (record-accessor    <account> 'agent-id))
(define account-gross-contribution-credited       (record-accessor    <account> 'gross-contribution-credited))
(define account-claimed-capacity                  (record-accessor    <account> 'claimed-capacity))
(define account-contribution-capacity-factor      (record-accessor    <account> 'contribution-capacity-factor))
