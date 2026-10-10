;;; module/playnet/boot/prelude.scm — the operator REPL's prelude: the planner and governance surface, bound unqualified.
;;;
;;; An operator evaluates in (guile-user) over the gateway's REPL socket
;;; (boot/repl) or in the planner REPL guix.scm wraps; this module makes the
;;; whole planner and governance surface available there unqualified, the
;;; way the two umbrellas (playnet planner) and (playnet governance) did. No
;;; code imports it: every module names its own dependencies, and
;;; tools/retire-umbrella.py rewrites an import of this prelude into the
;;; modules a file actually uses. The dev ledger's doors are here too, which
;;; tools/dev-loop-close.scm evaluates against the live dev commune; the
;;; Goblins and fibers forms an operator types come from server/gateway.scm's
;;; own imports.

(define-module (playnet boot prelude)
  #:use-module (playnet solve compile)
  #:use-module (playnet legal crossings)
  #:use-module (playnet knowledge catalogues eco)
  #:use-module (playnet vf formulas stocks)
  #:use-module (playnet solve recipe-response)
  #:use-module (playnet knowledge recipes berlin-flotte)
  #:use-module (playnet knowledge catalogues conformance)
  #:use-module (playnet knowledge recipes berlin-commune-seed)
  #:use-module (playnet knowledge recipes berlin-festival-seed)
  #:use-module (playnet knowledge recipes berlin-food-seed)
  #:use-module (playnet knowledge recipes berlin-transit)
  #:use-module (playnet knowledge worlds feel-the-food)
  #:use-module (playnet vf formulas cadence)
  #:use-module (playnet vf formulas capacity)
  #:use-module (playnet vf formulas skill-law)
  #:use-module (playnet vf facts validity)
  #:use-module (playnet execution scope-execution)
  #:use-module (playnet scope earth)
  #:use-module (playnet scope root)
  #:use-module (playnet ddmrp monitors)
  #:use-module (playnet ddmrp buffers)
  #:use-module (playnet observation live-registry)
  #:use-module (playnet observation account)
  #:use-module (playnet algorithms elastic)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet algorithms rollup)
  #:use-module (playnet algorithms rollup relative-snlt)
  #:use-module (playnet knowledge recipes foodsharing-kit)
  #:use-module (playnet knowledge recipes household)
  #:use-module (playnet algorithms rollup common)
  #:use-module (playnet plan store)
  #:use-module (playnet knowledge recipes transit-shed)
  #:use-module (playnet knowledge recipes stone-paper)
  #:use-module (playnet knowledge recipes beenius-wax)
  #:use-module (playnet knowledge recipes transport)
  #:use-module (playnet algorithms value-equations)
  #:use-module (playnet knowledge recipes bay-area-commune-seed)
  #:use-module (playnet algorithms correlation)
  #:use-module (playnet observation observer)
  #:use-module (playnet plan schedule-book)
  #:use-module (playnet federation remote-transport)
  #:use-module (playnet federation store-registry)
  #:use-module (playnet execution capacity-execute)
  #:use-module (playnet execution alerts)
  #:use-module (playnet observation live-resource)
  #:use-module (playnet observation host-facts)
  #:use-module (playnet observation transition)
  #:use-module (playnet observation demand-policy)
  #:use-module (playnet ddmrp buffer-zones)
  #:use-module (playnet ddmrp capacity-buffers)
  #:use-module (playnet scope spatial-things)
  #:use-module (playnet ddmrp buffer-snapshots)
  #:use-module (playnet plan recurrence)
  #:use-module (playnet scope agents)
  #:use-module (playnet scope process-registry)
  #:use-module (playnet knowledge recipes humisoil)
  #:use-module (playnet knowledge recipes grow)
  #:use-module (playnet knowledge recipes meeting)
  #:use-module (playnet knowledge recipes mimir)
  #:use-module (playnet knowledge recipes cold-chain)
  #:use-module (playnet knowledge recipes food-surplus)
  #:use-module (playnet knowledge recipes food-chain-seed)
  #:use-module (playnet knowledge recipes federation-demo)
  #:use-module (playnet knowledge recipes farm-commune-seed)
  #:use-module (playnet knowledge recipes bread-commune-seed)
  #:use-module (playnet knowledge recipes dwelling)
  #:use-module (playnet knowledge recipes flat-key)
  #:use-module (playnet knowledge recipes currency)
  #:use-module (playnet knowledge recipes container)
  #:use-module (playnet knowledge recipes infrastructure)
  #:use-module (playnet dev recipes)
  #:use-module (playnet algorithms sne)
  #:use-module (playnet algorithms signals)
  #:use-module (playnet algorithms skill-matcher)
  #:use-module (playnet algorithms critical-path)
  #:use-module (playnet algorithms custody)
  #:use-module (playnet ddmrp otif)
  #:use-module (playnet algorithms track-trace)
  #:use-module (playnet algorithms resource-flows)
  #:use-module (playnet indexes membership)
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet algorithms propagation)
  #:use-module (playnet vf serdes)
  #:use-module (playnet utils store-utils)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet observation states)
  #:use-module (playnet vf beyond schedules)
  #:use-module (playnet vf beyond scenario)
  #:use-module (playnet vf beyond lot)
  #:use-module (playnet ddmrp records)
  #:use-module (playnet vf aggregation containment)
  #:use-module (playnet utils clock)
  #:use-module ((playnet utils units) #:select (convert-unit unit->substance unit-rate? unit-rate-parts unit-known?))
  #:use-module (playnet voice ballot-store)
  #:use-module (playnet voice demand-registry)
  #:use-module (playnet knowledge recipes federation)
  #:use-module (playnet federation auditor)
  #:use-module (playnet federation structural-invariants)
  #:use-module (playnet boot scope)
  #:use-module (playnet boot governance)
  #:use-module (playnet federation communes)
  #:use-module (playnet voice scope-ballots)
  #:use-module (playnet keri first-person sybil-detect)
  #:use-module (playnet federation rebuild)
  #:use-module (playnet voice expression)
  #:use-module (playnet personhood enrollment)
  #:use-module (playnet keri first-person personhood-policy)
  #:use-module (playnet federation vows)
  #:use-module (playnet economy recipe-standing)
  #:use-module (playnet economy means-fold)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet federation root-lineage)
  #:use-module (playnet voice ballot)
  #:use-module (playnet economy socialization)
  #:use-module (playnet economy debts)
  #:use-module (playnet voice index-oracle)
  #:use-module (playnet voice delegation-map)
  #:use-module (playnet keys bran-custody)
  #:use-module (playnet federation bootstrap)
  #:use-module ((playnet keri acdc-store) #:hide (hashmap-count))   ; the store's count; utils/store-utils' hashmap-count is the one the planner reads
  #:use-module ((playnet observation credentials) #:hide (held-by))   ; algorithms/custody's held-by is the planner's
  #:use-module (playnet voice voice-signer)
  #:use-module (playnet voice snapshot)
  #:use-module (playnet economy guardianship)
  #:use-module (playnet economy demand-fold)
  #:use-module (playnet credentials audit)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials custody)
  #:use-module (playnet credentials declarations)
  #:use-module (playnet credentials delegation)
  #:use-module (playnet credentials keys)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet credentials registry)
  #:use-module (playnet credentials voting)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module (playnet personhood attestation-ceremony)
  #:use-module (playnet voice affected-interest)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri citizen-sig)
  #:use-module (playnet keri said-portable)
  #:use-module ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes keri-crypto-hmac-sha256))
  #:use-module ((playnet keri signify-portable) #:select (hkdf bran->signing-keypair bran->next-keypair bran->rotation-keypair build-ixn sign-event))
  #:use-module ((playnet utils hex) #:select (bv->hex hex->bv))
  #:use-module ((playnet keri inception) #:select (governance-create-scope-aid! <scope-inception> make-scope-inception scope-inception? scope-inception-aid scope-inception-bran scope-inception-keypair scope-inception-next-keypair scope-inception-signed-icp))
  #:use-module ((playnet keys peers) #:select (known-uc-aid))
  #:use-module (playnet org endorsement)
  #:use-module ((playnet scope live) #:select (cell declared-period-hours period-span plan-scope plan-scope->alist resource-window-hours set-daily-horizon! scenario-shocks shock-action shock-key shock-factor))
  #:use-module (playnet vf aggregation scope-tree)
  #:use-module (playnet vf aggregation fold-node)
  #:use-module ((playnet utils units) #:select (unit-rate? unit->substance unit-rate-parts))
  #:use-module (playnet observation event-log-store)
  #:use-module (playnet utils said-store)
  #:use-module (playnet crypto shamir)
  #:use-module (playnet utils paths)
  #:use-module (playnet keys kel-store)
  #:use-module (playnet keys scope-witness)
  #:use-module (playnet identity oobi-host-mirror)
  #:use-module (playnet federation scope-graph)
  #:use-module (playnet federation audit-scheduler)
  #:use-module (playnet keys http-witness-publisher)
  #:use-module ((playnet keri witness-publisher) #:select (witness-push-urls keri-publish-event! keri-fetch-kel-from-witness))
  #:use-module ((playnet keys exchange) #:select (scope-deliver-grant! governance-cred->wire))
  #:use-module ((playnet dev ledger) #:select (book-issue-done! booked?))
  ;; the list forms, multiple values and match an operator reaches for
  #:use-module ((srfi srfi-1) #:select (fold filter find remove partition append-map delete-duplicates
                                        iota first second third fourth any every count reduce))
  #:use-module ((srfi srfi-11) #:select (let-values let*-values))
  #:use-module ((ice-9 match) #:select (match match-lambda match-lambda*))
  #:re-export (book-issue-done! booked?)
  #:re-export (*spec-names* seed-federation-specs seed-federation-recipes
               seed-federation-inventory let-values let*-values fold filter
               find remove partition append-map delete-duplicates iota first
               second third fourth any every count reduce match match-lambda
               match-lambda* ^ballot-store spawn-ballot-store ballot-store-env
               ^demand-registry spawn-demand-registry demand-registry-env
               %rented-frag-profile %rented-frag-profiles %rented-frag-tip
               *action-definitions* *adjustment-types* *agent-types*
               *buffer-classifications* *buffer-item-types*
               *buffer-zones-enum* *days-of-week* *decoupling-tests*
               *override-reasons* *property-effects* *quantity-effects*
               *replenishment-statuses* *target-zones* *vf-actions* <account>
               <action-definition> <agent-relationship-role>
               <agent-relationship> <agent> <agreement-bundle> <agreement>
               <availability-window> <batch-lot-record> <buffer-profile>
               <buffer-snapshot> <buffer-zone> <capacity-buffer> <claim-state>
               <claim> <commitment> <day-schedule> <decoupling-test-entry>
               <decoupling-test-result> <demand-adjustment-factor> <duration>
               <economic-event> <economic-resource> <fulfillment-state>
               <intent> <measure> <month-schedule> <plan> <planning-scenario>
               <positioning-analysis> <process-specification> <process>
               <proposal-list> <proposal> <recipe-exchange> <recipe-flow>
               <recipe-group> <recipe-process> <recipe> <replenishment-signal>
               <resource-specification> <satisfaction-state>
               <scenario-definition> <scenario> <spatial-thing>
               <specific-date-window> <time-range> <unit> <week-schedule>
               account-agent-id account-claimed-capacity
               account-contribution-capacity-factor account?
               action-definition-accountable-effect
               action-definition-accounting-effect
               action-definition-contained-effect
               action-definition-create-resource
               action-definition-eligible-for-exchange
               action-definition-event-quantity
               action-definition-implies-transfer
               action-definition-input-output
               action-definition-location-effect
               action-definition-onhand-effect action-definition-pairs-with
               action-definition-stage-effect action-definition-state-effect
               action-definition? adjustment-type? agent-availability-window
               agent-classified-as agent-id agent-image agent-name agent-note
               agent-primary-location agent-relationship-id
               agent-relationship-in-scope-of agent-relationship-note
               agent-relationship-object agent-relationship-relationship
               agent-relationship-role-classified-as
               agent-relationship-role-id
               agent-relationship-role-inverse-label
               agent-relationship-role-label agent-relationship-role-note
               agent-relationship-role? agent-relationship-subject
               agent-relationship? agent-type agent-type? agent?
               agreement-bundle-bundles agreement-bundle-created
               agreement-bundle-id agreement-bundle-name agreement-bundle-note
               agreement-bundle? agreement-created agreement-id agreement-name
               agreement-note agreement-stipulates
               agreement-stipulates-reciprocal agreement?
               availability-window-day-schedules
               availability-window-month-schedules
               availability-window-time-ranges
               availability-window-week-schedules availability-window?
               batch-lot-record-batch-lot-code
               batch-lot-record-expiration-date
               batch-lot-record-expiration-kind batch-lot-record-id
               batch-lot-record? buffer-classification? buffer-item-type?
               buffer-profile-code buffer-profile-id buffer-profile-item-type
               buffer-profile-lead-time-category
               buffer-profile-lead-time-factor buffer-profile-name
               buffer-profile-note buffer-profile-order-cycle-days
               buffer-profile-ost-multiplier
               buffer-profile-recalculation-cadence
               buffer-profile-variability-category
               buffer-profile-variability-factor buffer-profile-vrd
               buffer-profile-vrs buffer-profile? buffer-snapshot-date
               buffer-snapshot-onhand buffer-snapshot-spec-id
               buffer-snapshot-tog buffer-snapshot-tor buffer-snapshot-toy
               buffer-snapshot-zone buffer-snapshot?
               buffer-zone-active-adjustment-ids buffer-zone-adu
               buffer-zone-adu-alert-high-pct buffer-zone-adu-alert-low-pct
               buffer-zone-adu-alert-window-days buffer-zone-adu-blend-ratio
               buffer-zone-adu-computed-from buffer-zone-adu-unit
               buffer-zone-adu-window-days buffer-zone-at-location
               buffer-zone-bootstrap-days-accumulated
               buffer-zone-buffer-classification buffer-zone-demand-adj-factor
               buffer-zone-dlt-days buffer-zone-downstream-stage-id
               buffer-zone-enum? buffer-zone-estimated-adu buffer-zone-id
               buffer-zone-last-computed-at buffer-zone-lead-time-adj-factor
               buffer-zone-moq buffer-zone-moq-unit
               buffer-zone-order-cycle-days buffer-zone-ost-horizon-days
               buffer-zone-override-note buffer-zone-override-reason
               buffer-zone-profile-id buffer-zone-red-base
               buffer-zone-red-safety buffer-zone-replenishment-recipe-id
               buffer-zone-spec-id buffer-zone-staging-days
               buffer-zone-supply-offset-days buffer-zone-tipping-point
               buffer-zone-tog buffer-zone-tor buffer-zone-toy
               buffer-zone-transport-days buffer-zone-upstream-location-id
               buffer-zone-upstream-stage-id buffer-zone-zone-adj-factor
               buffer-zone? capacity-buffer-current-load-hours
               capacity-buffer-green-threshold capacity-buffer-id
               capacity-buffer-note capacity-buffer-period-days
               capacity-buffer-process-spec-id
               capacity-buffer-total-capacity-hours
               capacity-buffer-yellow-threshold capacity-buffer? claim-action
               claim-created claim-due claim-effort-quantity claim-finished
               claim-id claim-note claim-provider claim-receiver
               claim-resource-classified-as claim-resource-conforms-to
               claim-resource-quantity claim-state-claim-id
               claim-state-finished claim-state-settling-events
               claim-state-total-claimed claim-state-total-settled
               claim-state? claim-triggered-by claim? commitment-action
               commitment-at-location commitment-availability-window
               copy-commitment copy-economic-event copy-intent
               intent->commitment commitment-clause-of commitment-created
               commitment-due commitment-effort-quantity commitment-finished
               commitment-has-beginning commitment-has-end
               commitment-has-point-in-time commitment-id
               commitment-in-scope-of commitment-independent-demand-of
               commitment-input-of commitment-note commitment-output-of
               commitment-planned-within commitment-provider
               commitment-receiver commitment-resource-classified-as
               commitment-resource-conforms-to
               commitment-resource-inventoried-as commitment-resource-quantity
               commitment-satisfies commitment-stage commitment-state
               commitment? day-of-week? day-schedule-days
               day-schedule-time-ranges day-schedule?
               decoupling-test-entry-note decoupling-test-entry-passed
               decoupling-test-entry-test decoupling-test-entry?
               decoupling-test-result-approved-at
               decoupling-test-result-approved-by
               decoupling-test-result-results decoupling-test-result-spec-id
               decoupling-test-result? decoupling-test?
               demand-adjustment-factor-at-location
               demand-adjustment-factor-factor demand-adjustment-factor-id
               demand-adjustment-factor-is-active
               demand-adjustment-factor-note demand-adjustment-factor-spec-id
               demand-adjustment-factor-supply-offset-days
               demand-adjustment-factor-target-zone
               demand-adjustment-factor-type
               demand-adjustment-factor-valid-from
               demand-adjustment-factor-valid-to demand-adjustment-factor?
               duration-has-numerical-value duration-has-unit duration?
               economic-event-action economic-event-at-location
               economic-event-corrects economic-event-created
               economic-event-distribution-mode economic-event-effort-quantity
               economic-event-fulfills economic-event-has-beginning
               economic-event-has-end economic-event-has-point-in-time
               economic-event-id economic-event-in-scope-of
               economic-event-input-of economic-event-note
               economic-event-output-of economic-event-previous-event
               economic-event-provider economic-event-realization-of
               economic-event-receiver economic-event-resource-classified-as
               economic-event-resource-conforms-to
               economic-event-resource-inventoried-as
               economic-event-resource-quantity economic-event-satisfies
               economic-event-settles economic-event-state
               economic-event-to-location
               economic-event-to-resource-inventoried-as economic-event?
               economic-resource-accounting-quantity
               economic-resource-availability-window
               economic-resource-classified-as economic-resource-conforms-to
               economic-resource-contained-in
               economic-resource-current-location
               economic-resource-current-virtual-location
               economic-resource-custodian-scope
               economic-resource-distribution-mode economic-resource-id
               economic-resource-image economic-resource-lot
               economic-resource-name economic-resource-note
               economic-resource-onhand-quantity
               economic-resource-previous-event
               economic-resource-primary-accountable economic-resource-stage
               economic-resource-state economic-resource-tracking-identifier
               economic-resource-unit-of-effort economic-resource?
               event-distribution-mode fulfillment-state-commitment-id
               fulfillment-state-finished fulfillment-state-fulfilling-events
               fulfillment-state-over-fulfilled
               fulfillment-state-total-committed
               fulfillment-state-total-fulfilled fulfillment-state?
               intent-action intent-at-location intent-availability-window
               intent-available-quantity intent-due intent-effort-quantity
               intent-finished intent-has-beginning intent-has-end
               intent-has-point-in-time intent-id intent-image
               intent-in-scope-of intent-input-of intent-minimum-quantity
               intent-name intent-note intent-output-of intent-planned-within
               intent-provider intent-receiver intent-resource-classified-as
               intent-resource-conforms-to intent-resource-inventoried-as
               intent-resource-quantity intent-satisfies intent-stage
               intent-state intent? make-account make-action-definition
               make-agent make-agent-relationship make-agent-relationship-role
               make-agreement make-agreement-bundle make-availability-window
               make-batch-lot-record make-buffer-profile make-buffer-snapshot
               make-buffer-zone make-capacity-buffer make-claim
               make-claim-state make-commitment make-day-schedule
               make-decoupling-test-entry make-decoupling-test-result
               make-demand-adjustment-factor make-duration make-economic-event
               make-economic-resource copy-economic-resource
               make-fulfillment-state make-intent make-measure
               make-month-schedule make-plan make-planning-scenario
               make-positioning-analysis make-process
               make-process-specification make-proposal make-proposal-list
               make-recipe make-recipe-exchange make-recipe-flow
               make-recipe-group make-recipe-process make-replenishment-signal
               make-resource-specification make-satisfaction-state
               make-scenario make-scenario-definition make-spatial-thing
               make-specific-date-window make-time-range make-unit
               make-week-schedule measure-has-numerical-value measure-has-unit
               measure? month-schedule-day-schedules month-schedule-month
               month-schedule-time-ranges month-schedule-week-schedules
               month-schedule? override-reason? plan-classified-as
               plan-created plan-due plan-has-independent-demand plan-id
               plan-name plan-note plan-refinement-of plan?
               planning-scenario-id planning-scenario-note
               planning-scenario-path planning-scenario-probability
               planning-scenario-scenario planning-scenario-yield-multipliers
               planning-scenario?
               positioning-analysis-critical-operation-protection
               positioning-analysis-customer-tolerance-time-days
               positioning-analysis-decoupling-recommended
               positioning-analysis-inventory-leverage-flexibility
               positioning-analysis-market-potential-lead-time-days
               positioning-analysis-note
               positioning-analysis-sales-order-visibility-horizon-days
               positioning-analysis-vrd positioning-analysis-vrs
               positioning-analysis? process-based-on process-classified-as
               process-finished process-has-beginning process-has-end
               process-id process-in-scope-of process-name process-nested-in
               process-note process-planned-within
               process-specification-buffer-type process-specification-id
               process-specification-image
               process-specification-is-control-point
               process-specification-is-convergent-point
               process-specification-is-decoupling-point
               process-specification-is-divergent-point
               process-specification-name process-specification-note
               process-specification? process? property-effect?
               proposal-created proposal-eligible-location
               proposal-has-beginning proposal-has-end proposal-id
               proposal-in-scope-of proposal-list-created proposal-list-id
               proposal-list-lists proposal-list-name proposal-list-note
               proposal-list? proposal-name proposal-note proposal-proposed-to
               proposal-publishes proposal-purpose proposal-reciprocal
               proposal-unit-based proposal? quantity-effect? recipe-based-on
               recipe-exchange-id recipe-exchange-name recipe-exchange-note
               recipe-exchange? recipe-flow-action recipe-flow-effort-quantity
               recipe-flow-id recipe-flow-is-primary recipe-flow-note
               recipe-flow-recipe-clause-of recipe-flow-recipe-input-of
               recipe-flow-recipe-output-of recipe-flow-resolve-from-flow
               recipe-flow-resource-classified-as
               recipe-flow-resource-conforms-to recipe-flow-resource-quantity
               recipe-flow-stage recipe-flow-state recipe-flow?
               recipe-group-id recipe-group-name recipe-group-note
               recipe-group-recipes recipe-group? recipe-id recipe-name
               recipe-note recipe-primary-output recipe-process-has-duration
               recipe-process-id recipe-process-image
               recipe-process-minimum-batch-quantity recipe-process-name
               recipe-process-note recipe-process-process-classified-as
               recipe-process-process-conforms-to
               recipe-process-sequence-group recipe-process?
               recipe-recipe-exchanges recipe-recipe-processes recipe?
               rented-frag-profile rented-frag-tip rented-goods
               replenishment-signal-approved-commitment-id
               replenishment-signal-at-location
               replenishment-signal-buffer-zone-id
               replenishment-signal-created-at replenishment-signal-due-date
               replenishment-signal-id replenishment-signal-nfp
               replenishment-signal-onhand replenishment-signal-onorder
               replenishment-signal-priority
               replenishment-signal-qualified-demand
               replenishment-signal-recommended-qty
               replenishment-signal-spec-id replenishment-signal-status
               replenishment-signal-zone replenishment-signal?
               replenishment-status? resource-distribution-mode
               resource-rented? resource-sovereign?
               resource-spec-keep-in-place?
               resource-specification-buffer-profile-id
               resource-specification-default-unit-of-effort
               resource-specification-default-unit-of-resource specs->units
               resource-specification-id resource-specification-image
               resource-specification-keep-in-place
               resource-specification-medium-of-exchange
               resource-specification-name resource-specification-note
               resource-specification-positioning-analysis
               resource-specification-resource-classified-as
               resource-specification-satisfied-by
               resource-specification-substitutable resource-specification?
               satisfaction-state-finished satisfaction-state-intent-id
               satisfaction-state-plan-id
               satisfaction-state-satisfying-commitments
               satisfaction-state-satisfying-events
               satisfaction-state-total-desired
               satisfaction-state-total-satisfied satisfaction-state?
               scenario-defined-as scenario-definition-has-duration
               scenario-definition-id scenario-definition-in-scope-of
               scenario-definition-name scenario-definition-note
               scenario-definition? scenario-has-beginning scenario-has-end
               scenario-id scenario-in-scope-of scenario-name scenario-note
               scenario-refinement-of scenario? spatial-thing-alt
               spatial-thing-boundary spatial-thing-contained-in
               spatial-thing-id spatial-thing-lat spatial-thing-long
               spatial-thing-mappable-address spatial-thing-name
               spatial-thing-note spatial-thing?
               specific-date-window-specific-dates
               specific-date-window-time-ranges specific-date-window?
               target-zone? temporal-expression? time-range-end-time
               time-range-start-time time-range? unit-classified-as unit-id
               unit-label unit-symbol unit? vf-action?
               week-schedule-day-schedules week-schedule-weeks week-schedule?
               deserialize-hashmap generate-id hashmap-any? hashmap-count
               hashmap-filter hashmap-filter-pairs hashmap-find hashmap-keys
               hashmap-map-values hashmap-values iso-datetime->epoch
               serialize-hashmap *vf-serdes-registry* register-vf-record!
               register-vf-records! vf-deserialize vf-record-instance?
               vf-serdes-clear! vf-serdes-lookup-by-instance
               vf-serdes-lookup-by-name vf-serialize *days-per-ms*
               *ms-per-day* *ms-per-hour* *ms-per-minute* *ms-per-second*
               *non-consuming-actions* compute-snlt create-flow-record
               min-snlt-for-spec recipe-output-qty rp-duration-days
               rp-duration-ms ^recipe-store action-input-output find-flow
               recipe-deliverable list->process-specification list->recipe
               list->recipe-exchange list->recipe-flow list->recipe-group
               list->recipe-process list->resource-specification
               process-inputs process-outputs process-specification->list
               recipe->list recipe-exchange->list recipe-flow->list
               recipe-group->list recipe-process->list recipe-store-env
               resource-specification->list seed-spec-rows! spec-row-classes
               spec-row-id spec-row-name spec-row-unit build-membership-index
               citizen-share commune-share cash-flow-report trace track
               compute-otif apply-penalty apply-transfer-custody
               build-custody-ledger current-custodian custody-level
               entrustment-limit held-by incentive-compatible ledger-by-agent
               ledger-records make-custody-ledger penalty-svc
               scope-entrustment-capacity settle-custody tranche-coverage
               critical-path match-work-flows *plan-tags* intent->signal
               plan-tag signal->intent *non-consuming-actions-sne*
               build-sne-index/actor compute-recipe-sne/actor
               compute-sne-for-recipe direct-sne-for-spec seed-dev-knowledge!
               infra-bandwidth-spec infra-compute-spec infra-dataset-spec
               infra-memory-spec infra-storage-spec infra-transcript-spec
               infrastructure-specs seed-infrastructure-recipes
               *dwelling-specs* seed-dwelling-recipe seed-dwelling-specs
               %rent-eur-per-night seed-rent-recipe flat-key-world
               seed-flat-key-recipes! *currency-fiat-specs*
               *currency-store-of-value-specs* seed-currency-specs
               seed-container-specs seed-farm-commune! seed-holds!
               seed-farm-holds! seed-bread-recipes! seed-bread-commune!
               seed-fed-commune! food-stage seed-food-chain!
               food-surplus-collected-spec food-surplus-produce-spec
               food-surplus-reefer-van-spec food-surplus-sorted-produce-spec
               food-surplus-volunteer-spec seed-food-surplus-3step-recipe
               seed-food-surplus-donor-specs seed-food-surplus-recipe
               seed-food-surplus-recipient-specs cold-chain-food-specs
               cold-chain-process-specs cold-chain-storage-specs
               cold-chain-vehicle-specs cold-chain-skill-specs pa-dairy
               pa-frozen pa-pantry pa-perishable pspec-deliver pspec-pack
               pspec-pre-cool pspec-receive pspec-sort-inspect
               seed-cold-chain-recipe seed-cold-chain-specs spec-ambient-shelf
               spec-cargo-van spec-chilled-bay spec-cc-handling spec-dairy
               spec-dry-pantry spec-frozen-bay spec-frozen-meals-nut
               spec-frozen-meals-soy spec-leafy-greens spec-reefer-van
               meeting-whole-acts seed-meeting-recipe mimir-whole-acts
               seed-mimir-specs seed-mimir-recipes seed-grow-recipe
               seed-grow-specs seed-humisoil-recipe seed-humisoil-specs
               ^process-registry list->process* process->list
               process-registry-env ^agent-store agent->list
               agent-relationship->list agent-relationship-role->list
               agent-store-env list->agent list->agent-relationship
               list->agent-relationship-role date-matches-window
               epoch->iso-date get-occurrence-status
               group-events-by-occurrence materialize-occurrence-dates
               occurrence-date-key unfulfilled-occurrences ^snapshot-store
               buffer-snapshot->list list->buffer-snapshot snapshot-store-env
               ^spatial-thing-store circle-boundary is-descendant-or-equal-hm
               list->spatial-thing resolve-chain-hm resolve-coordinates-hm
               spatial-thing->list spatial-thing-store-env
               ^capacity-buffer-store capacity-buffer->list
               capacity-buffer-store-env list->capacity-buffer
               ^buffer-zone-store buffer-zone->list buffer-zone-store-env
               list->buffer-zone portrait->zones-hashmap
               zones-hashmap->portrait derive-communal-demand
               derive-dependent-demand compute-claim-capacities
               compute-collective-metrics compute-communal-satisfaction-ratio
               compute-dollar-balance compute-dollar-wage-phase-out-factor
               compute-dollar-wages-per-worker
               compute-effective-net-market-wage compute-flow-fractions
               compute-real-wages compute-scope-transition-report
               compute-substitution-ratio compute-total-social-value
               compute-validated-hours compute-wage-rate-normalized
               extract-worker-hours ^live-resource live-resource-env
               parse-meminfo parse-loadavg parse-herd-running
               parse-running-value parse-ps-table process-tree-usage
               placement-ledger read-host-facts sync-host-facts! ^alert-store
               alert-kind alert-spec-id alert-store-env alert-timestamp
               dispatch-async execute-with-event now-iso with-capacity
               with-enforced-capacity with-resources ^store-registry parse-ref
               qualify store-registry-env hydrate-store snapshot-store
               can-commit-work? can-use-resource? committed-effort-on
               has-use-conflict schedule-blocks-for <fold-ctx>
               <observer-state> ^observer append-index
               apply-container-location apply-direction-effects
               apply-quantity-effect apply-resource-effects
               capture-container-location check-process-completion
               create-batch-for-produce ctx-affected ctx-state
               ctx-update-state deserialize-observer-state
               economic-event->list economic-resource->list
               economic-resource-set-custodian-scope
               economic-resource-set-onhand-quantity
               economic-resource-set-location
               economic-resource-set-tracking-identifier
               economic-resource-set-lot empty-observer-state event-qty
               fold-ctx? get-action-def list->economic-event
               list->economic-resource make-fold-ctx make-observer-state
               measure-qty observer-env observer-record-event observer-state?
               os-agreements os-batches os-claim-targets os-events
               os-events-by-id os-commitment-targets os-idx-by-action
               os-idx-by-agent os-idx-by-process os-idx-by-resource
               os-idx-by-spec os-rebuild os-resource-batches os-resources
               os-intent-targets os-satisfiers override-action-def
               phase-append-event phase-apply-effects phase-breadcrumb-chain
               phase-implied-transfer phase-index-event
               serialize-observer-state split-custody? <covariance-view>
               compute-correlation correlate-pairs
               covariance-view-bucket-seconds covariance-view-id
               covariance-view-method covariance-view? make-covariance-view
               pearson-rho series-stddev seed-bay-area-commune!
               distribute-income distribute-multiple-income effort-equation
               effort-scorer equal-equation equal-scorer
               make-depreciation-scorer make-hybrid-equation resource-scorer
               score-event car-ride consume-flow* dropoff-flow mode-recipe
               pickup-flow pspec-transport recipe-carry recipe-hold
               relocation-recipe seed-recipe-entry! seed-baseline-modes!
               baseline-modes seed-transport-recipe seed-transport-specs
               spec-car spec-petrol spec-rider transport-specs use-flow
               work-flow* seed-beenius-build-recipe seed-beenius-journey
               seed-beenius-remelt-recipe seed-beenius-specs
               seed-beenius-sticks-recipe seed-beenius-wax-recipe
               seed-stone-paper-bio-recipe seed-stone-paper-compost-recipe
               seed-stone-paper-recipe seed-stone-paper-reclaim-recipe
               seed-stone-paper-specs network-resource pass-resource
               seed-relocation-recipe! transit-manners vehicle-resource
               <plan-store-state> ^plan-store append-to-index
               deserialize-plan-store-state empty-plan-store-state
               fold-promotions index-commitment-spec index-intent-spec
               index-intent-tags make-plan-store-state plan-store-env
               plan-store-state? pss-add-agreement pss-add-commitment
               pss-add-plan pss-agreement-bundles pss-agreements pss-claims
               pss-commitments pss-commitments-by-plan
               pss-commitments-by-process pss-commitments-by-spec pss-intents
               pss-intents-by-plan pss-intents-by-spec pss-meta pss-plans
               pss-promote-intent pss-proposal-lists pss-proposals
               pss-scenario-definitions pss-scenarios pss-tag-index
               pss-with-commitments pss-with-intents remove-from-index
               serialize-plan-store-state recipe-gross-effort
               recipe-net-outputs rollup-recipes-producing
               standalone-snlt-for-spec *household-bin-runs* *household-kit*
               *household-specs* *household-waste-streams* household-flows
               household-living-defs household-living-flows
               household-processes household-recipe-defs household-waste-flows
               household-waste-processes household-waste-recipe-defs
               seed-household-kit! seed-household-recipes seed-household-specs
               seed-household-waste-recipes household-care-flows
               household-care-processes household-care-recipe-defs
               seed-household-care-recipes *foodsaver-skill-args*
               *foodsharing-kit* declare-foodsaver-skill!
               enrol-foodsaver-trainee! foodsaver-skill foodsaver-skill-args
               foodsharing-cold-uses foodsharing-hand-uses
               foodsharing-kit-uses kit-per-pickup kit-spec-id kit-spec-name
               kit-unit seed-foodsharing-kit! seed-foodsharing-kit-specs!
               rollup-relative-snlt rollup-relative-snlt-for cost-variance
               crystallized-snlt-for-spec recipe-unit-snlt rollup-actual-cost
               rollup-producers-of rollup-standard-cost ^account-store
               account->list account-store-env consumer-voice
               current-social-free-time global-citizen-claimed
               global-citizen-count global-citizen-gross global-citizen-unmet
               global-citizenship-share set-person-substrate! person-aid?
               global-contribution-claim global-citizen-ability
               global-ability-norm global-effective-balance
               global-elastic-context global-embodied-labor-in-pool
               global-social-free-time global-sum-met-capacity
               global-sum-unmet-capacity global-total-claim-capacity
               global-total-social-svc list->account set-social-free-time!
               universal-credit-balance voice-share claimable-specs
               spec-claimable? spec-rail ^live-registry live-registry-env
               live-availability *consuming-actions* *epsilon* *ltf-ranges*
               *seconds-per-day* *standard-ltf* *standard-vf* *vf-ranges*
               adjust-vf-for-capacity adu-drift-alert
               aggregate-adjustment-factors analyze-recipe-topology assq-put
               average-on-hand-target blend-adu bootstrap-adu
               buffer-eligibility buffer-health-history buffer-status
               build-buffer-health-report build-profile-code
               capacity-buffer-status capacity-in-time cascade-component-daf
               check-item-type-consistency classify-analytics-zone
               classify-flow-speed compute-adu-differential compute-adu/events
               compute-buffer-zone-levels compute-decoupled-lead-time
               compute-execution-priority compute-forward-adu
               compute-lead-time-alerts compute-material-sync-alerts
               compute-min-max-buffer compute-nfp compute-otif-ddmrp
               compute-signal-integrity compute-time-buffer
               derive-variability-factor detect-adu-alerts flow-index
               generate-replenishment-signal leg-lead-time
               location-matches-ddmrp ltm-alert-zone ltm-alert-zone-full
               material-release-date material-sync-shortfall on-hand-alert
               orchestrate-buffer-recalibration order-activity-summary
               parse-profile-code prioritized-share project-buffer-zones
               project-on-hand qualify-demand recalibrate-buffer-zone
               recipe-lead-time recommend-buffer-type
               resolve-adjustment-factor run-recalibration-cycle
               score-positioning-analysis signal-compliance-history
               signal-integrity-report sort-by-priority-and-sequence
               standard-profile sum-onhand-at-location time-buffer-state
               time-in-zone validate-buffer-profile zone-distribution
               zone-transitions buffer-status-monitor create-adu-shift-monitor
               create-recalibration-sink create-snapshot-sink
               material-sync-monitor standard-monitors standard-sinks
               ^scope-root scope-root-env spawn-scope-root ^earth earth-env
               spawn-earth make-execution-context record-and-monitor
               holding-capacity apply-recert-schedule cred-claim-of
               cred-with-valid-until cred-live? custody-cred-live?
               conformance-recert-schedule edge-reliance inspection-intensity
               recert-interval-discrete reliance->valid-until effective-skills
               held-svc-caps svc-cap-key svc-eco-caps *batch-homogeneity*
               *feel-the-food-profiles* *feel-the-food-senses*
               chargenvermutung-asserts-rho chargenvermutung-condemns?
               chargenvermutung-sample feel-the-food-profile
               feel-the-food-rate feel-the-food-sample
               feel-the-food-saturates? feel-the-food-verdict homogeneity
               sample->implied-rho seed-feel-the-food! sense-criteria
               sense-destructive? spec-perishability unpresumed-units
               *berlin-mode-recipes* berlin-network-resources
               berlin-transit-manners berlin-transit-resources
               berlin-transit-svc-caps bt-cargo-bike-resource
               bt-network-resource bt-transit-pass-resource
               seed-berlin-cargo-bike-recipe seed-berlin-transit!
               seed-berlin-transit-haul-recipe seed-berlin-transit-specs
               *berlin-food-batch* *berlin-food-chain-stages*
               berlin-food-chain-stages seed-berlin-food-recipe!
               seed-berlin-food-scope! seed-berlin-commune!
               seed-berlin-transit-arm! seed-berlin-festival-arm!
               attach-festival-futures! *conformance-catalogue*
               conformance-frag-weight *flotte-kommunal-bikes*
               *flotte-max-loan-days* *flotte-stations* *flotte-total-bikes*
               flotte-berlin-resources flotte-kommunal-lender
               flotte-loan-window flotte-spread-resources observed-capture
               recipe-response-report *climate-tipping-points*
               *limit-reversibility* *planetary-boundaries*
               *planetary-catalogue* catalogue->policy catalogue->wire
               limit-attenuation-rate limit-monitoring-cadence limit-roster
               migrate-limit migrated->caps migrated->flows migrated->procs
               migrated->resources migrated->stock-frag migrated->storables
               migrated-limits migrated-place migrated-rate migrated-spec
               migrated-stock monitored-alpha reversibility-character
               reversibility-years roster-of-verdict
               witnessed-tipping-characters crossing-gloss crossing-kind
               recipe-channel rail-channel recipe-crossings register-crossing!
               clear-use-unit-gaps! compile-process compile-recipe
               use-unit-gaps batch-unit-gaps clear-batch-unit-gaps!
               canonical-string compute-said said-sort-pairs
               install-said-blake3! ^affected-interest-voice
               affected-interest-env spawn-affected-interest-voice
               ^attestation-ceremony attestation-ceremony-for
               land-witness-attestation! register-attestation-ceremony!
               witness-attest-handler current-aid-key-resolver
               *contact-point-kinds* *playnet-schemas*
               *schema-playnet-agreement* *schema-playnet-audit-pass*
               *schema-playnet-authorized-issuer*
               *schema-playnet-ballot-snapshot* *schema-playnet-bran-share*
               *schema-playnet-ccf-assessment* *schema-playnet-claim*
               *schema-playnet-commitment*
               *schema-playnet-commitment-fulfillment*
               *schema-playnet-conflict-resolution*
               *schema-playnet-contact-point*
               *schema-playnet-custody-attestation*
               *schema-playnet-custody-transfer-commitment*
               *schema-playnet-delegation*
               *schema-playnet-derived-state-snapshot*
               *schema-playnet-exclusion* *schema-playnet-expression-stance*
               *schema-playnet-external-index-observation*
               *schema-playnet-federation-membership*
               *schema-playnet-federation-sturdyref*
               *schema-playnet-federation-census*
               *schema-playnet-hosting-willingness*
               *schema-playnet-incoherence-alert* *schema-playnet-intent*
               *schema-playnet-membership* *schema-playnet-personhood*
               *schema-playnet-recomposition-ratification*
               *schema-playnet-redistribution-mandate*
               *schema-playnet-regime-claim* *schema-playnet-relationship*
               *schema-playnet-reversion-attestation*
               *schema-playnet-scope-merger* *schema-playnet-scope-rejoin*
               *schema-playnet-scope-split* *schema-playnet-skill*
               *schema-playnet-span-declaration* *schema-playnet-stance*
               *schema-playnet-tally-result*
               *schema-playnet-witness-assignment* *schema-playnet-work-event*
               audit-witness-quorum-independence compile-mandate-spec
               compute-plan-said contact-point-acceptable?
               contact-point-binding-fields contact-point-identifying?
               contact-point-kind? count-witness-attestors cred-claim
               cred-claims cred-edge cred-edges cred-holder cred-issuer
               cred-recompute-said cred-revoked? cred-said
               cred-said-consistent? cred-schema cred-signature
               cred-signed-by-scope cred-timestamp cred-with-revoked
               cred-with-signature edge-i2i-holds? edge-operator edge-schema
               edge-target indexed-claims-for iso-utc-now
               make-agreement-credential make-audit-pass-credential
               make-authorized-issuer-credential
               make-ballot-snapshot-credential make-bran-share-credential
               make-ccf-credential make-claim-event-credential
               make-commitment-credential
               make-commitment-fulfillment-credential
               make-conflict-resolution-credential
               make-contact-point-credential make-credential
               make-custody-attestation-credential
               make-custody-transfer-commitment-credential
               make-delegation-credential
               make-derived-state-snapshot-credential make-edge
               make-exclusion-credential make-expression-stance-credential
               make-external-index-observation-credential
               make-federation-membership-credential
               make-federation-sturdyref-credential
               make-federation-census-credential
               make-hosting-willingness-credential
               make-incoherence-alert-credential make-intent-credential
               make-membership-credential make-personhood-credential
               make-recomposition-ratification-credential
               make-redistribution-mandate-credential
               make-regime-claim-credential make-relationship-credential
               make-reversion-attestation-credential
               make-scope-merger-credential make-scope-rejoin-credential
               make-scope-split-credential make-skill-credential
               make-span-declaration-credential make-stance-credential
               make-tally-result-credential make-witness-assignment-credential
               make-work-event-credential mandate mandate-spec-of
               parse-time-value predicate->spec register-mandate-predicate
               timestamp-claim-for witness-assignments-for-federation
               ^demand-node cells->horizon demand-cells-of demand-for
               demand-monoid demand-of demand-scope-horizon federation-home-of
               merge-demand scope-own-demand scope-subtree-demand
               wire-demand-node! ^guardianship guardianship-env
               spawn-guardianship build-citizen-registry build-voice-snapshot
               citizen-record-delegation-map citizen-record-id
               citizen-record-keri-aid ^voice-signer spawn-keri-voice-signer
               spawn-voice-signer voice-signer-env ^work-witness
               attest-contribution! event-log-reconcile!
               gather-witnessed-attestation! open-work-witnessing!
               witness-work-inbox scope-acdc-store current-vouch-reader
               witness-pending-context remember-remote-witness-request!
               forget-remote-witness-request! remote-witness-request
               held-skill-cred install-credentialing! kel-anchored-saids
               make-credentialing-on-event make-plan-credentialing-callbacks
               mint-skill-if-new! reconstruct-claimed-hours
               reconstruct-credit-balance reconstruct-earned-skills
               reconstruct-practiced-hours skill-held? snapshot-complete?
               snapshot-input-saids snapshot-missing snapshot-over
               spawn-witnessed-work-ceremony witness-quorum
               work-events-for-skill ^acdc-store non-revoked-by-schema
               spawn-acdc-store ^bootstrap-ceremony bootstrap-ceremony!
               spawn-bootstrap-ceremony ^bran-custodian host-vault-key
               read-vault-bran read-vault-secret
               reconstitute-bran-from-custodians reconstitute-bran-from-store
               restore-bran-custodian spawn-bran-custodian
               split-and-issue-bran-shares! split-and-spawn-custodians!
               with-host-vault-key write-vault-bran! write-vault-secret!
               ^delegation-map delegation-map-env delegation-sum
               entry-fraction entry-mandate make-entry mandate-satisfied?
               merge-overrides resolve-delegation spawn-delegation-map
               ^index-oracle credential-stream->pairs-fn observation-value
               spawn-index-oracle commune-care-breaches commune-resource-view
               labour-specs-of verb-specs-of commune-socialized-caps
               consented-span-of desocialize-private-resource!
               federation-resource-resolver live-span-of live-willingness-of
               plan-commune-scope project-socialized-custody
               socialization-care-breaches socialization-care-demand
               socialization-care-terms socialization-credential
               grant-consume? grant-kind-claim socialization-owner-reverter
               socialize-private-resource socialized-readers
               commune-socialized-slots commune-world commune-demand
               commune-stamp title-rights-of grant-steward-rule
               commune-steward-rules make-may-steward make-knows vrc-groups-of
               ownership-credential ownership-ok? title-permits?
               %live-ownership-attestations %grant-over?
               member-consume-grant-total member-consume-grant-over money-rate
               debt-commitment purchase-claim open-debts debt-remaining
               debt->alist open-debts-alist debts-owed-in-xmr settle-debts!
               %payout-spec ^ballot ballot-env make-citizen-verifier
               make-sealer-verifier open-ballot tally-snapshot voice-snap
               voice-snap-delegation voice-snap-share
               *default-sponsor-fanout-cap* *default-sponsor-fanout-window*
               aic-valid-by-root? any-live-phc-for assert-sponsor-fanout!
               authorized-issuer-cred cred-live-at? cred-multisig-valid?
               cred-signature-valid? ecosystem-chains-to-any-root?
               holds-any-live-phc? holds-live-phc? issuer-chains-to-root?
               multi-ecosystem-triangle-holds? mutual-vrcs
               personhood-bootstrapped? phc-chains-to-root? phc-for
               phc-issuer-authz-edge phc-live? phcs-by-ecosystem
               phcs-in-ecosystem root-lineage-closure sponsor-recent-invites
               trust-triangle-holds? vrc-from-to ^means-pool capacity-bars
               capacity-cells capacity-facts common-span-defaults means-monoid
               means-refold-listener means-withholding scope-own-capacity
               scope-subtree-capacity wire-means-node! withholding-snapshot
               live-regime-of observer-runs standing-position
               realized-scenario scope-standing async-sum-over-scopes
               commune-weight-async global-citizen-claimed-async
               global-citizen-gross-async global-citizen-unmet-async
               global-effective-balance-async
               global-embodied-labor-in-pool-async
               global-sum-met-capacity-async global-sum-unmet-capacity-async
               global-total-social-svc-async global-citizen-ability-async
               global-ability-norm-async on-> open-ballot-async
               spawn-ballot-from-snapshot tally-mandated-async
               voice-share-async vow-fold-async vow-let*
               enrollment-statement-said spawn-enrollment-ceremony
               enroll-ceremony-for-candidate enroll-asks enrollment-record
               witness-recent-enrollments expire-stale-enrollments!
               rehydrate-enrollment-ceremonies! current-enroll-announcer
               *self-request-evidence* personhood-policy
               *personhood-policy-defaults* effective-k ^expression
               distribution-sum express expression-env open-expression
               tally-expression-snapshot validate-distribution latest-by-claim
               recover-ballot-state recover-ballots-into-scope!
               recover-commitments recover-commune-state
               recover-delegation-map recover-economic-state
               recover-federation-state recover-federation-state-remote
               recover-intents recover-lineage recover-personhood-state
               recover-work-events detect-suspicious-subgraphs
               sponsor-fanout-counts suspicious-clusters suspicious-sponsors
               vrc-edges ^scope clear-spec-generalizations!
               federation-memberships-of-holder may-govern?
               open-recomposition-ballot ratification-edges
               register-spec-generalization! resolve-merge-ratifier scope-env
               spawn-scope kel-identifier register-rotation-keypair-fn!
               rotation-keypair-fn split-scope-with-aids
               stale-membership-edges verify-parent-ratification!
               ^governance-service governance-service-env
               spawn-governance-service plan-part-hands-of
               contrary-observations-of contrary-readings-of spawn-commune
               spawn-federation compile-threshold-spec
               compose-federation-admitting federation-aid-paths
               federation-double-counted-members federation-leaves
               federation-members-attested?
               federation-membership-paths-unique? federation-tree-coherent?
               federation-unattested-members leaf-member-aids
               leaf-only-labor-coherent? leaf-only-labor-violations
               recomposition-acdc-ratified? recomposition-acdcs-in-tree
               recomposition-ratified? redistribution-coherent?
               redistribution-mandate-breaches scope-has-contributors?
               scope-leaf? tree-credentials-of-schema tree-work-events
               unratified-recomposition-acdcs verify-kind-from-lineage
               ownership-coherent? ownership-violations records-held-once?
               records-held-twice *auditor-methods-readonly*
               ^custody-half-life-watcher ^federation-auditor
               spawn-auditor-facet spawn-custody-half-life-watcher
               spawn-federation-auditor make-keri-identity keri-identity?
               keri-identity-aid keri-identity-keypair
               keri-identity-public-key keri-identity-from-seed
               aid-prefix->pubkey sign-said verify-said-signature
               sign-said-multisig verify-said-multisig
               governance-create-scope-aid! <scope-inception>
               make-scope-inception scope-inception? scope-inception-aid
               scope-inception-bran scope-inception-keypair
               scope-inception-next-keypair scope-inception-signed-icp
               current-playnet-state-dir-override playnet-state-dir
               scope-state-dir scope-acdc-dir scope-kel-dir scope-vault-path
               custodian-share-path scope-kind-file read-scope-kind
               write-scope-kind! scope-aid-name-file read-scope-aid-name
               write-scope-aid-name! default-scope-aid-name durable-default?
               default-scope-witnesses ensure-directory! ^kel-store
               spawn-kel-store kel-event-said kel-event-seq kel-event-type
               kel-event-aid ^scope-witness spawn-scope-witness
               scope-witness-mirror! scope-witness-kel-for ^oobi-host-mirror
               spawn-oobi-host-mirror ^scope-graph current-scope-graph
               ^audit-scheduler spawn-audit-scheduler ^http-witness-publisher
               spawn-http-witness-publisher witness-push-urls
               keri-publish-event! keri-fetch-kel-from-witness))
