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

(define-module (playnet ddmrp records)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor vf-record-modifier vf-record-type-name vf-record-type-fields vf-record-copier))
  #:use-module ((playnet vf serdes) #:select (register-vf-records! register-vf-record!))
  #:export (make-positioning-analysis
            *decoupling-tests*
            decoupling-test?
            make-decoupling-test-entry
            make-decoupling-test-result
            make-capacity-buffer
            *buffer-item-types*
            buffer-item-type?
            make-buffer-profile
            *buffer-classifications*
            buffer-classification?
            *override-reasons*
            override-reason?
            make-buffer-zone
            *buffer-zones-enum*
            buffer-zone-enum?
            *replenishment-statuses*
            replenishment-status?
            make-replenishment-signal
            *adjustment-types*
            adjustment-type?
            *target-zones*
            target-zone?
            make-demand-adjustment-factor
            make-buffer-snapshot))

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
(define-vf-record <positioning-analysis> PositioningAnalysis
  (customer-tolerance-time-days market-potential-lead-time-days sales-order-visibility-horizon-days inventory-leverage-flexibility vrd vrs critical-operation-protection decoupling-recommended note)
  #:register register-vf-record!)

(define make-positioning-analysis
  (vf-record-constructor <positioning-analysis>))


;;; DecouplingTestEntry — a single test result within a DecouplingTestResult.
;;; Fields: test (symbol: decoupling | bi-directional | order-independence |
;;;               primary-planning | relative-priority | dynamic-adjustment),
;;;         passed (boolean), note? (string).
(define *decoupling-tests*
  '(decoupling bi-directional order-independence
    primary-planning relative-priority dynamic-adjustment))

(define (decoupling-test? x)
  (and (symbol? x) (memq x *decoupling-tests*) #t))

(define-vf-record <decoupling-test-entry> DecouplingTestEntry
  (test passed note)
  #:register register-vf-record!)

(define make-decoupling-test-entry
  (vf-record-constructor <decoupling-test-entry>))


;;; DecouplingTestResult — outcome of a formal decoupling-point approval.
;;; Fields: spec-id (string), results (list of <decoupling-test-entry>),
;;;         approved-at? (ISO datetime string), approved-by? (string).
(define-vf-record <decoupling-test-result> DecouplingTestResult
  (spec-id results approved-at approved-by)
  #:register register-vf-record!)

(define make-decoupling-test-result
  (vf-record-constructor <decoupling-test-result>))

;;; CapacityBuffer — capacity buffer for a work center.
;;; Fields: id (string), process-spec-id (string: ProcessSpecification ID),
;;;         total-capacity-hours (number, positive),
;;;         period-days (number, positive),
;;;         current-load-hours (number, nonneg),
;;;         green-threshold? (number, 0-1), yellow-threshold? (number, 0-1),
;;;         note? (string).
(define-vf-record <capacity-buffer> CapacityBuffer
  (id process-spec-id total-capacity-hours period-days current-load-hours green-threshold yellow-threshold note)
  #:register register-vf-record!)

(define make-capacity-buffer
  (vf-record-constructor <capacity-buffer>))

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

(define-vf-record <buffer-profile> BufferProfile
  (id name item-type lead-time-factor vrd vrs variability-factor order-cycle-days ost-multiplier recalculation-cadence lead-time-category variability-category code note)
  #:register register-vf-record!)

(define make-buffer-profile
  (vf-record-constructor <buffer-profile>))


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

(define-vf-record <buffer-zone> BufferZone
  (id spec-id profile-id buffer-classification at-location upstream-location-id replenishment-recipe-id upstream-stage-id downstream-stage-id adu adu-unit adu-blend-ratio adu-window-days adu-computed-from adu-alert-high-pct adu-alert-low-pct adu-alert-window-days estimated-adu bootstrap-days-accumulated ost-horizon-days dlt-days moq moq-unit order-cycle-days override-reason override-note transport-days staging-days tor toy tog tipping-point red-base red-safety demand-adj-factor zone-adj-factor lead-time-adj-factor supply-offset-days active-adjustment-ids last-computed-at)
  #:register register-vf-record!)

(define make-buffer-zone
  (vf-record-constructor <buffer-zone>))


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

(define-vf-record <replenishment-signal> ReplenishmentSignal
  (id spec-id at-location buffer-zone-id onhand onorder qualified-demand nfp priority zone recommended-qty due-date status approved-commitment-id created-at)
  #:register register-vf-record!)

(define make-replenishment-signal
  (vf-record-constructor <replenishment-signal>))


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

(define-vf-record <demand-adjustment-factor> DemandAdjustmentFactor
  (id spec-id at-location type target-zone factor valid-from valid-to supply-offset-days note is-active)
  #:register register-vf-record!)

(define make-demand-adjustment-factor
  (vf-record-constructor <demand-adjustment-factor>))


;; ═══════════════════════════════════════════════════════════════════════
;; BUFFER SNAPSHOTS (time-series health tracking)
;; ═══════════════════════════════════════════════════════════════════════

;;; BufferSnapshot — a point-in-time buffer health reading.
;;; Fields: spec-id (string), date (string "YYYY-MM-DD"),
;;;         onhand (number), tor (number), toy (number), tog (number),
;;;         zone (symbol: red | yellow | green | excess).
(define-vf-record <buffer-snapshot> BufferSnapshot
  (spec-id date onhand tor toy tog zone)
  #:register register-vf-record!)

(define make-buffer-snapshot        (vf-record-constructor <buffer-snapshot>))

;; ── persistence: this family registers its own types ────────────────────────
;; each type registers itself as it is declared (define-vf-record #:register)
