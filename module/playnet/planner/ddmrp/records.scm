;;; ddmrp/records.scm — the records of the buffer planner (DDMRP).
;;;
;;; Nine record types ValueFlows does not define: strategic positioning and the
;;; decoupling tests, buffer profiles and zones, replenishment signals, demand
;;; adjustment factors, buffer snapshots and the capacity buffer of a work
;;; centre. They stood in vf/schemas.scm among the ValueFlows classes; they stand
;;; here so the vocabulary file is what docs/valueflows/assets/all_vf.TTL says,
;;; and so this family can be read against ValueFlows whole
;;; (docs/planning/codebase-organization.md §7 names the route each may take
;;; into the core: a buffer as a standing Intent, a profile as a classification,
;;; a signal as an Intent, a snapshot as a reading of events).
;;;
;;; A ValueFlows record holds one of these as a field value only
;;; (`resource-specification-positioning-analysis`, `-buffer-profile-id`, the
;;; ProcessSpecification flags): no code of the core reads them.
;;;
;;; The module registers its own types with the generic serdes, so a store that
;;; holds them persists by importing this module alone. The serialized form is
;;; keyed by record type name, which the move leaves as it was.

(define-module (playnet planner ddmrp records)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet planner vf serdes) #:select (register-vf-records!))
  #:export (<positioning-analysis> make-positioning-analysis positioning-analysis?
            positioning-analysis-customer-tolerance-time-days
            positioning-analysis-market-potential-lead-time-days
            positioning-analysis-sales-order-visibility-horizon-days
            positioning-analysis-inventory-leverage-flexibility positioning-analysis-vrd
            positioning-analysis-vrs positioning-analysis-critical-operation-protection
            positioning-analysis-decoupling-recommended positioning-analysis-note
            *decoupling-tests* decoupling-test? <decoupling-test-entry>
            make-decoupling-test-entry decoupling-test-entry? decoupling-test-entry-test
            decoupling-test-entry-passed decoupling-test-entry-note
            <decoupling-test-result> make-decoupling-test-result decoupling-test-result?
            decoupling-test-result-spec-id decoupling-test-result-results
            decoupling-test-result-approved-at decoupling-test-result-approved-by
            <capacity-buffer> make-capacity-buffer capacity-buffer? capacity-buffer-id
            capacity-buffer-process-spec-id capacity-buffer-total-capacity-hours
            capacity-buffer-period-days capacity-buffer-current-load-hours
            capacity-buffer-green-threshold capacity-buffer-yellow-threshold
            capacity-buffer-note *buffer-item-types* buffer-item-type? <buffer-profile>
            make-buffer-profile buffer-profile? buffer-profile-id buffer-profile-name
            buffer-profile-item-type buffer-profile-lead-time-factor buffer-profile-vrd
            buffer-profile-vrs buffer-profile-variability-factor
            buffer-profile-order-cycle-days buffer-profile-ost-multiplier
            buffer-profile-recalculation-cadence buffer-profile-lead-time-category
            buffer-profile-variability-category buffer-profile-code buffer-profile-note
            *buffer-classifications* buffer-classification? *override-reasons*
            override-reason? <buffer-zone> make-buffer-zone buffer-zone? buffer-zone-id
            buffer-zone-spec-id buffer-zone-profile-id buffer-zone-buffer-classification
            buffer-zone-at-location buffer-zone-upstream-location-id
            buffer-zone-replenishment-recipe-id buffer-zone-upstream-stage-id
            buffer-zone-downstream-stage-id buffer-zone-adu buffer-zone-adu-unit
            buffer-zone-adu-blend-ratio buffer-zone-adu-window-days
            buffer-zone-adu-computed-from buffer-zone-adu-alert-high-pct
            buffer-zone-adu-alert-low-pct buffer-zone-adu-alert-window-days
            buffer-zone-estimated-adu buffer-zone-bootstrap-days-accumulated
            buffer-zone-ost-horizon-days buffer-zone-dlt-days buffer-zone-moq
            buffer-zone-moq-unit buffer-zone-order-cycle-days buffer-zone-override-reason
            buffer-zone-override-note buffer-zone-transport-days buffer-zone-staging-days
            buffer-zone-tor buffer-zone-toy buffer-zone-tog buffer-zone-tipping-point
            buffer-zone-red-base buffer-zone-red-safety buffer-zone-demand-adj-factor
            buffer-zone-zone-adj-factor buffer-zone-lead-time-adj-factor
            buffer-zone-supply-offset-days buffer-zone-active-adjustment-ids
            buffer-zone-last-computed-at *buffer-zones-enum* buffer-zone-enum?
            *replenishment-statuses* replenishment-status? <replenishment-signal>
            make-replenishment-signal replenishment-signal? replenishment-signal-id
            replenishment-signal-spec-id replenishment-signal-at-location
            replenishment-signal-buffer-zone-id replenishment-signal-onhand
            replenishment-signal-onorder replenishment-signal-qualified-demand
            replenishment-signal-nfp replenishment-signal-priority
            replenishment-signal-zone replenishment-signal-recommended-qty
            replenishment-signal-due-date replenishment-signal-status
            replenishment-signal-approved-commitment-id replenishment-signal-created-at
            *adjustment-types* adjustment-type? *target-zones* target-zone?
            <demand-adjustment-factor> make-demand-adjustment-factor
            demand-adjustment-factor? demand-adjustment-factor-id
            demand-adjustment-factor-spec-id demand-adjustment-factor-at-location
            demand-adjustment-factor-type demand-adjustment-factor-target-zone
            demand-adjustment-factor-factor demand-adjustment-factor-valid-from
            demand-adjustment-factor-valid-to demand-adjustment-factor-supply-offset-days
            demand-adjustment-factor-note demand-adjustment-factor-is-active
            <buffer-snapshot> make-buffer-snapshot buffer-snapshot?
            buffer-snapshot-spec-id buffer-snapshot-date buffer-snapshot-onhand
            buffer-snapshot-tor buffer-snapshot-toy buffer-snapshot-tog
            buffer-snapshot-zone))

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
  (vf-record-type 'PositioningAnalysis
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
  (vf-record-constructor <positioning-analysis>))
(define positioning-analysis?
  (vf-record-predicate <positioning-analysis>))
(define positioning-analysis-customer-tolerance-time-days
  (vf-record-accessor <positioning-analysis> 'customer-tolerance-time-days))
(define positioning-analysis-market-potential-lead-time-days
  (vf-record-accessor <positioning-analysis> 'market-potential-lead-time-days))
(define positioning-analysis-sales-order-visibility-horizon-days
  (vf-record-accessor <positioning-analysis> 'sales-order-visibility-horizon-days))
(define positioning-analysis-inventory-leverage-flexibility
  (vf-record-accessor <positioning-analysis> 'inventory-leverage-flexibility))
(define positioning-analysis-vrd
  (vf-record-accessor <positioning-analysis> 'vrd))
(define positioning-analysis-vrs
  (vf-record-accessor <positioning-analysis> 'vrs))
(define positioning-analysis-critical-operation-protection
  (vf-record-accessor <positioning-analysis> 'critical-operation-protection))
(define positioning-analysis-decoupling-recommended
  (vf-record-accessor <positioning-analysis> 'decoupling-recommended))
(define positioning-analysis-note
  (vf-record-accessor <positioning-analysis> 'note))


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
  (vf-record-type 'DecouplingTestEntry
    '((immutable test)
      (immutable passed)
      (immutable note))))

(define make-decoupling-test-entry
  (vf-record-constructor <decoupling-test-entry>))
(define decoupling-test-entry?
  (vf-record-predicate <decoupling-test-entry>))
(define decoupling-test-entry-test
  (vf-record-accessor <decoupling-test-entry> 'test))
(define decoupling-test-entry-passed
  (vf-record-accessor <decoupling-test-entry> 'passed))
(define decoupling-test-entry-note
  (vf-record-accessor <decoupling-test-entry> 'note))


;;; DecouplingTestResult — outcome of a formal decoupling-point approval.
;;; Fields: spec-id (string), results (list of <decoupling-test-entry>),
;;;         approved-at? (ISO datetime string), approved-by? (string).
(define <decoupling-test-result>
  (vf-record-type 'DecouplingTestResult
    '((immutable spec-id)
      (immutable results)
      (immutable approved-at)
      (immutable approved-by))))

(define make-decoupling-test-result
  (vf-record-constructor <decoupling-test-result>))
(define decoupling-test-result?
  (vf-record-predicate <decoupling-test-result>))
(define decoupling-test-result-spec-id
  (vf-record-accessor <decoupling-test-result> 'spec-id))
(define decoupling-test-result-results
  (vf-record-accessor <decoupling-test-result> 'results))
(define decoupling-test-result-approved-at
  (vf-record-accessor <decoupling-test-result> 'approved-at))
(define decoupling-test-result-approved-by
  (vf-record-accessor <decoupling-test-result> 'approved-by))

;;; CapacityBuffer — capacity buffer for a work center.
;;; Fields: id (string), process-spec-id (string: ProcessSpecification ID),
;;;         total-capacity-hours (number, positive),
;;;         period-days (number, positive),
;;;         current-load-hours (number, nonneg),
;;;         green-threshold? (number, 0-1), yellow-threshold? (number, 0-1),
;;;         note? (string).
(define <capacity-buffer>
  (vf-record-type 'CapacityBuffer
    '((immutable id)
      (immutable process-spec-id)
      (immutable total-capacity-hours)
      (immutable period-days)
      (immutable current-load-hours)
      (immutable green-threshold)
      (immutable yellow-threshold)
      (immutable note))))

(define make-capacity-buffer
  (vf-record-constructor <capacity-buffer>))
(define capacity-buffer?
  (vf-record-predicate <capacity-buffer>))
(define capacity-buffer-id
  (vf-record-accessor <capacity-buffer> 'id))
(define capacity-buffer-process-spec-id
  (vf-record-accessor <capacity-buffer> 'process-spec-id))
(define capacity-buffer-total-capacity-hours
  (vf-record-accessor <capacity-buffer> 'total-capacity-hours))
(define capacity-buffer-period-days
  (vf-record-accessor <capacity-buffer> 'period-days))
(define capacity-buffer-current-load-hours
  (vf-record-accessor <capacity-buffer> 'current-load-hours))
(define capacity-buffer-green-threshold
  (vf-record-accessor <capacity-buffer> 'green-threshold))
(define capacity-buffer-yellow-threshold
  (vf-record-accessor <capacity-buffer> 'yellow-threshold))
(define capacity-buffer-note
  (vf-record-accessor <capacity-buffer> 'note))

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
  (vf-record-type 'BufferProfile
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
  (vf-record-constructor <buffer-profile>))
(define buffer-profile?
  (vf-record-predicate <buffer-profile>))
(define buffer-profile-id
  (vf-record-accessor <buffer-profile> 'id))
(define buffer-profile-name
  (vf-record-accessor <buffer-profile> 'name))
(define buffer-profile-item-type
  (vf-record-accessor <buffer-profile> 'item-type))
(define buffer-profile-lead-time-factor
  (vf-record-accessor <buffer-profile> 'lead-time-factor))
(define buffer-profile-vrd
  (vf-record-accessor <buffer-profile> 'vrd))
(define buffer-profile-vrs
  (vf-record-accessor <buffer-profile> 'vrs))
(define buffer-profile-variability-factor
  (vf-record-accessor <buffer-profile> 'variability-factor))
(define buffer-profile-order-cycle-days
  (vf-record-accessor <buffer-profile> 'order-cycle-days))
(define buffer-profile-ost-multiplier
  (vf-record-accessor <buffer-profile> 'ost-multiplier))
(define buffer-profile-recalculation-cadence
  (vf-record-accessor <buffer-profile> 'recalculation-cadence))
(define buffer-profile-lead-time-category
  (vf-record-accessor <buffer-profile> 'lead-time-category))
(define buffer-profile-variability-category
  (vf-record-accessor <buffer-profile> 'variability-category))
(define buffer-profile-code
  (vf-record-accessor <buffer-profile> 'code))
(define buffer-profile-note
  (vf-record-accessor <buffer-profile> 'note))


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
  (vf-record-type 'BufferZone
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
  (vf-record-constructor <buffer-zone>))
(define buffer-zone?
  (vf-record-predicate <buffer-zone>))
(define buffer-zone-id
  (vf-record-accessor <buffer-zone> 'id))
(define buffer-zone-spec-id
  (vf-record-accessor <buffer-zone> 'spec-id))
(define buffer-zone-profile-id
  (vf-record-accessor <buffer-zone> 'profile-id))
(define buffer-zone-buffer-classification
  (vf-record-accessor <buffer-zone> 'buffer-classification))
(define buffer-zone-at-location
  (vf-record-accessor <buffer-zone> 'at-location))
(define buffer-zone-upstream-location-id
  (vf-record-accessor <buffer-zone> 'upstream-location-id))
(define buffer-zone-replenishment-recipe-id
  (vf-record-accessor <buffer-zone> 'replenishment-recipe-id))
(define buffer-zone-upstream-stage-id
  (vf-record-accessor <buffer-zone> 'upstream-stage-id))
(define buffer-zone-downstream-stage-id
  (vf-record-accessor <buffer-zone> 'downstream-stage-id))
(define buffer-zone-adu
  (vf-record-accessor <buffer-zone> 'adu))
(define buffer-zone-adu-unit
  (vf-record-accessor <buffer-zone> 'adu-unit))
(define buffer-zone-adu-blend-ratio
  (vf-record-accessor <buffer-zone> 'adu-blend-ratio))
(define buffer-zone-adu-window-days
  (vf-record-accessor <buffer-zone> 'adu-window-days))
(define buffer-zone-adu-computed-from
  (vf-record-accessor <buffer-zone> 'adu-computed-from))
(define buffer-zone-adu-alert-high-pct
  (vf-record-accessor <buffer-zone> 'adu-alert-high-pct))
(define buffer-zone-adu-alert-low-pct
  (vf-record-accessor <buffer-zone> 'adu-alert-low-pct))
(define buffer-zone-adu-alert-window-days
  (vf-record-accessor <buffer-zone> 'adu-alert-window-days))
(define buffer-zone-estimated-adu
  (vf-record-accessor <buffer-zone> 'estimated-adu))
(define buffer-zone-bootstrap-days-accumulated
  (vf-record-accessor <buffer-zone> 'bootstrap-days-accumulated))
(define buffer-zone-ost-horizon-days
  (vf-record-accessor <buffer-zone> 'ost-horizon-days))
(define buffer-zone-dlt-days
  (vf-record-accessor <buffer-zone> 'dlt-days))
(define buffer-zone-moq
  (vf-record-accessor <buffer-zone> 'moq))
(define buffer-zone-moq-unit
  (vf-record-accessor <buffer-zone> 'moq-unit))
(define buffer-zone-order-cycle-days
  (vf-record-accessor <buffer-zone> 'order-cycle-days))
(define buffer-zone-override-reason
  (vf-record-accessor <buffer-zone> 'override-reason))
(define buffer-zone-override-note
  (vf-record-accessor <buffer-zone> 'override-note))
(define buffer-zone-transport-days
  (vf-record-accessor <buffer-zone> 'transport-days))
(define buffer-zone-staging-days
  (vf-record-accessor <buffer-zone> 'staging-days))
(define buffer-zone-tor
  (vf-record-accessor <buffer-zone> 'tor))
(define buffer-zone-toy
  (vf-record-accessor <buffer-zone> 'toy))
(define buffer-zone-tog
  (vf-record-accessor <buffer-zone> 'tog))
(define buffer-zone-tipping-point
  (vf-record-accessor <buffer-zone> 'tipping-point))
(define buffer-zone-red-base
  (vf-record-accessor <buffer-zone> 'red-base))
(define buffer-zone-red-safety
  (vf-record-accessor <buffer-zone> 'red-safety))
(define buffer-zone-demand-adj-factor
  (vf-record-accessor <buffer-zone> 'demand-adj-factor))
(define buffer-zone-zone-adj-factor
  (vf-record-accessor <buffer-zone> 'zone-adj-factor))
(define buffer-zone-lead-time-adj-factor
  (vf-record-accessor <buffer-zone> 'lead-time-adj-factor))
(define buffer-zone-supply-offset-days
  (vf-record-accessor <buffer-zone> 'supply-offset-days))
(define buffer-zone-active-adjustment-ids
  (vf-record-accessor <buffer-zone> 'active-adjustment-ids))
(define buffer-zone-last-computed-at
  (vf-record-accessor <buffer-zone> 'last-computed-at))


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
  (vf-record-type 'ReplenishmentSignal
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
  (vf-record-constructor <replenishment-signal>))
(define replenishment-signal?
  (vf-record-predicate <replenishment-signal>))
(define replenishment-signal-id
  (vf-record-accessor <replenishment-signal> 'id))
(define replenishment-signal-spec-id
  (vf-record-accessor <replenishment-signal> 'spec-id))
(define replenishment-signal-at-location
  (vf-record-accessor <replenishment-signal> 'at-location))
(define replenishment-signal-buffer-zone-id
  (vf-record-accessor <replenishment-signal> 'buffer-zone-id))
(define replenishment-signal-onhand
  (vf-record-accessor <replenishment-signal> 'onhand))
(define replenishment-signal-onorder
  (vf-record-accessor <replenishment-signal> 'onorder))
(define replenishment-signal-qualified-demand
  (vf-record-accessor <replenishment-signal> 'qualified-demand))
(define replenishment-signal-nfp
  (vf-record-accessor <replenishment-signal> 'nfp))
(define replenishment-signal-priority
  (vf-record-accessor <replenishment-signal> 'priority))
(define replenishment-signal-zone
  (vf-record-accessor <replenishment-signal> 'zone))
(define replenishment-signal-recommended-qty
  (vf-record-accessor <replenishment-signal> 'recommended-qty))
(define replenishment-signal-due-date
  (vf-record-accessor <replenishment-signal> 'due-date))
(define replenishment-signal-status
  (vf-record-accessor <replenishment-signal> 'status))
(define replenishment-signal-approved-commitment-id
  (vf-record-accessor <replenishment-signal> 'approved-commitment-id))
(define replenishment-signal-created-at
  (vf-record-accessor <replenishment-signal> 'created-at))


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
  (vf-record-type 'DemandAdjustmentFactor
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
  (vf-record-constructor <demand-adjustment-factor>))
(define demand-adjustment-factor?
  (vf-record-predicate <demand-adjustment-factor>))
(define demand-adjustment-factor-id
  (vf-record-accessor <demand-adjustment-factor> 'id))
(define demand-adjustment-factor-spec-id
  (vf-record-accessor <demand-adjustment-factor> 'spec-id))
(define demand-adjustment-factor-at-location
  (vf-record-accessor <demand-adjustment-factor> 'at-location))
(define demand-adjustment-factor-type
  (vf-record-accessor <demand-adjustment-factor> 'type))
(define demand-adjustment-factor-target-zone
  (vf-record-accessor <demand-adjustment-factor> 'target-zone))
(define demand-adjustment-factor-factor
  (vf-record-accessor <demand-adjustment-factor> 'factor))
(define demand-adjustment-factor-valid-from
  (vf-record-accessor <demand-adjustment-factor> 'valid-from))
(define demand-adjustment-factor-valid-to
  (vf-record-accessor <demand-adjustment-factor> 'valid-to))
(define demand-adjustment-factor-supply-offset-days
  (vf-record-accessor <demand-adjustment-factor> 'supply-offset-days))
(define demand-adjustment-factor-note
  (vf-record-accessor <demand-adjustment-factor> 'note))
(define demand-adjustment-factor-is-active
  (vf-record-accessor <demand-adjustment-factor> 'is-active))


;; ═══════════════════════════════════════════════════════════════════════
;; BUFFER SNAPSHOTS (time-series health tracking)
;; ═══════════════════════════════════════════════════════════════════════

;;; BufferSnapshot — a point-in-time buffer health reading.
;;; Fields: spec-id (string), date (string "YYYY-MM-DD"),
;;;         onhand (number), tor (number), toy (number), tog (number),
;;;         zone (symbol: red | yellow | green | excess).
(define <buffer-snapshot>
  (vf-record-type 'BufferSnapshot
    '((immutable spec-id)
      (immutable date)
      (immutable onhand)
      (immutable tor)
      (immutable toy)
      (immutable tog)
      (immutable zone))))

(define make-buffer-snapshot        (vf-record-constructor <buffer-snapshot>))
(define buffer-snapshot?            (vf-record-predicate   <buffer-snapshot>))
(define buffer-snapshot-spec-id     (vf-record-accessor    <buffer-snapshot> 'spec-id))
(define buffer-snapshot-date        (vf-record-accessor    <buffer-snapshot> 'date))
(define buffer-snapshot-onhand      (vf-record-accessor    <buffer-snapshot> 'onhand))
(define buffer-snapshot-tor         (vf-record-accessor    <buffer-snapshot> 'tor))
(define buffer-snapshot-toy         (vf-record-accessor    <buffer-snapshot> 'toy))
(define buffer-snapshot-tog         (vf-record-accessor    <buffer-snapshot> 'tog))
(define buffer-snapshot-zone        (vf-record-accessor    <buffer-snapshot> 'zone))

;; ── persistence: this family registers its own types ────────────────────────
(register-vf-records!
  <positioning-analysis>
  <decoupling-test-entry>
  <decoupling-test-result>
  <capacity-buffer>
  <buffer-profile>
  <buffer-zone>
  <replenishment-signal>
  <demand-adjustment-factor>
  <buffer-snapshot>)
