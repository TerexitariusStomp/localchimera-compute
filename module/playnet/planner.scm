;;; module/playnet/planner.scm — the (playnet planner) umbrella module
;;;
;;; Every planner/lib file is now a plain include-fragment under
;;; module/playnet/planner/…, loaded by this umbrella in dependency
;;; order. External consumers import the whole planner via
;;; `(use-modules (playnet planner))` — precise sub-imports are
;;; unnecessary because the planner is one cohesive system.
;;;
;;; Files included (in load order):
;;   schemas.scm
;;   store-utils.scm
;;   utils/serdes.scm
;;   utils/serdes-bindings.scm
;;   process-registry.scm
;;   ddmrp/buffer-zones.scm
;;   ddmrp/capacity-buffers.scm
;;   scope/spatial-things.scm
;;   knowledge/recipes/store.scm
;;   ddmrp/buffer-snapshots.scm
;;   knowledge/recipes/federation.scm
;;   knowledge/recipes/humisoil.scm
;;   knowledge/recipes/transport.scm
;;   knowledge/recipes/stone-paper.scm
;;   knowledge/recipes/beenius-wax.scm
;;   legal/crossings.scm
;;   eco-catalogue.scm
;;   knowledge/recipes/transit-shed.scm
;;   knowledge/recipes/berlin-transit.scm
;;   knowledge/recipes/meeting.scm
;;   knowledge/recipes/cold-chain.scm
;;   knowledge/recipes/food-surplus.scm
;;   knowledge/recipes/household.scm
;;   knowledge/recipes/infrastructure.scm
;;   knowledge/recipes/dev.scm
;;   agents.scm
;;   execution/alerts.scm
;;   observation/observer.scm
;;   observation/live-resource.scm
;;   observation/live-registry.scm
;;   observation/account.scm
;;   observation/transition.scm
;;   observation/demand-policy.scm
;;   planning/planning.scm
;;   scope-root.scm
;;   algorithms/propagation.scm
;;   algorithms/sne.scm
;;   ddmrp/buffers.scm
;;   algorithms/signals.scm
;;   algorithms/netting.scm
;;   algorithms/skill-matcher.scm
;;   algorithms/dependent-demand.scm
;;   algorithms/dependent-supply.scm
;;   algorithms/critical-path.scm
;;   algorithms/shortest-path.scm
;;   algorithms/network-flow.scm
;;   algorithms/flow-graph.scm
;;   algorithms/custody.scm
;;   ddmrp/otif.scm
;;   algorithms/metabolism.scm
;;   algorithms/positioning.scm
;;   algorithms/track-trace.scm
;;   algorithms/value-equations.scm
;;   algorithms/rollup.scm
;;   algorithms/resource-flows.scm
;;   planning/plan-for-unit.scm
;;   planning/plan-for-scope.scm
;;   planning/plan-for-region.scm
;;   plan/schedule-book.scm
;;   federation/remote-transport.scm
;;   ddmrp/monitors.scm
;;   execution/scope-execution.scm
;;   execution/capacity-execute.scm
;;   indexes/index-utils.scm
;;   indexes/intents.scm
;;   indexes/commitments.scm
;;   indexes/economic-events.scm
;;   indexes/economic-resources.scm
;;   indexes/independent-demand.scm
;;   indexes/independent-supply.scm
;;   indexes/membership.scm
;;   indexes/proposals.scm
;;   indexes/agents.scm
;;   utils/buffer-type.scm
;;   plan/recurrence.scm
;;   utils/demand-priority.scm
;;   relational/planning-facts.scm
;;   relational/compute.scm
;;   relational/allocation.scm
;;   relational/trace.scm
;;   relational/lexicon.scm
;;   relational/grammar.scm
;;   relational/narrate.scm
;;   relational/signals.scm
;;   relational/ddmrp.scm
;;   relational/sne.scm
;;   relational/demand-relation.scm
;;   relational/plan-relation.scm
;;   relational/plan-walk.scm
;;   relational/plan-actor.scm
;;   relational/federation-result.scm
;;   relational/streams.scm
;;   relational/instrumentation.scm
;;   relational/strategy.scm
;;   relational/harmony.scm
;;   relational/federation.scm
;;   relational/ddmrp-leaf-planner.scm
;;   federation/store-registry.scm
;;   planning/plan-federation.scm
;;   vf-relations.scm

;; Top-level defines: 1455
;; use-modules specs (deduped): 8

(define-module (playnet planner)
  #:use-module (playnet planner solve compile)
  #:use-module (playnet planner legal crossings)
  #:use-module (playnet planner knowledge catalogues eco)
  #:use-module (playnet planner formulas stocks)
  #:use-module (playnet planner solve recipe-response)
  #:use-module (playnet planner knowledge recipes berlin-flotte)
  #:use-module (playnet planner knowledge catalogues conformance)
  #:use-module (playnet planner knowledge recipes berlin-commune-seed)
  #:use-module (playnet planner knowledge recipes berlin-festival-seed)
  #:use-module (playnet planner knowledge recipes berlin-food-seed)
  #:use-module (playnet planner knowledge recipes berlin-transit)
  #:use-module (playnet planner knowledge worlds feel-the-food)
  #:use-module (playnet planner formulas cadence)
  #:use-module (playnet planner formulas capacity)
  #:use-module (playnet planner formulas skill-law)
  #:use-module (playnet planner facts validity)
  #:use-module (playnet planner formulas capacity)
  #:use-module (playnet planner execution scope-execution)
  #:use-module (playnet planner scope earth)
  #:use-module (playnet planner scope root)
  #:use-module (playnet planner ddmrp monitors)
  #:use-module (playnet planner ddmrp buffers)
  #:use-module (playnet planner observation live-registry)
  #:use-module (playnet planner observation account)
  #:use-module (playnet planner algorithms elastic)       ; the credit identity's arithmetic, its two published facts
  #:use-module (playnet planner pools credit-fold)   ; the cross-scope reads: the walk is the fold
  #:use-module (playnet planner algorithms rollup)
  #:use-module (playnet planner algorithms rollup relative-snlt)
  #:use-module (playnet planner knowledge recipes foodsharing-kit)
  #:use-module (playnet planner knowledge recipes household)
  #:use-module (playnet planner algorithms rollup common)
  #:use-module (playnet planner plan store)
  #:use-module (playnet planner knowledge recipes transit-shed)
  #:use-module (playnet planner knowledge recipes stone-paper)
  #:use-module (playnet planner knowledge recipes beenius-wax)
  #:use-module (playnet planner knowledge recipes transport)
  #:use-module (playnet planner algorithms value-equations)
  #:use-module (playnet planner knowledge recipes bay-area-commune-seed)
  #:use-module (playnet planner algorithms correlation)
  #:use-module (playnet planner observation observer)
  #:use-module (playnet planner plan schedule-book)
  #:use-module (playnet planner federation remote-transport)
  #:use-module (playnet planner federation store-registry)
  #:use-module (playnet planner execution capacity-execute)
  #:use-module (playnet planner execution alerts)
  #:use-module (playnet planner observation live-resource)
  #:use-module (playnet planner observation host-facts)
  #:use-module (playnet planner observation transition)
  #:use-module (playnet planner observation demand-policy)
  #:use-module (playnet planner ddmrp buffer-zones)
  #:use-module (playnet planner ddmrp capacity-buffers)
  #:use-module (playnet planner scope spatial-things)
  #:use-module (playnet planner ddmrp buffer-snapshots)
  #:use-module (playnet planner plan recurrence)
  #:use-module (playnet planner scope agents)
  #:use-module (playnet planner scope process-registry)
  #:use-module (playnet planner knowledge recipes humisoil)
  #:use-module (playnet planner knowledge recipes grow)
  #:use-module (playnet planner knowledge recipes meeting)
  #:use-module (playnet planner knowledge recipes mimir)
  #:use-module (playnet planner knowledge recipes cold-chain)
  #:use-module (playnet planner knowledge recipes food-surplus)
  #:use-module (playnet planner knowledge recipes food-chain-seed)
  #:use-module (playnet planner knowledge recipes federation-demo)
  #:use-module (playnet planner knowledge recipes farm-commune-seed)
  #:use-module (playnet planner knowledge recipes bread-commune-seed)
  #:use-module (playnet planner knowledge recipes dwelling)
  #:use-module (playnet planner knowledge recipes flat-key)
  #:use-module (playnet planner knowledge recipes currency)
  #:use-module (playnet planner knowledge recipes container)
  #:use-module (playnet planner knowledge recipes infrastructure)
  #:use-module (playnet planner dev recipes)
  #:use-module (playnet planner algorithms sne)
  #:use-module (playnet planner algorithms signals)
  #:use-module (playnet planner algorithms skill-matcher)
  #:use-module (playnet planner algorithms critical-path)
  #:use-module (playnet planner algorithms custody)
  #:use-module (playnet planner ddmrp otif)
  #:use-module (playnet planner algorithms track-trace)
  #:use-module (playnet planner algorithms resource-flows)
  #:use-module (playnet planner indexes membership)
  #:use-module (playnet planner knowledge recipes store)
  #:use-module (playnet planner algorithms propagation)
  #:use-module (playnet planner vf serdes)
  #:use-module (playnet utils store-utils)
  #:use-module (srfi srfi-1)
  ;; §0 — the VF ontology. A real module: loaded once, so ONE set of record
  ;; types, which is what every loader's `(unless (defined? ...))` guard was
  ;; hand-rolling. Re-exported below, so consumers see no change.
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner observation states)
  #:use-module (playnet planner beyond schedules)
  #:use-module (playnet planner beyond scenario)
  #:use-module (playnet planner beyond lot)
  #:use-module (playnet planner ddmrp records)
  ;; the containment climb — a place inside a place, an oven inside a flat.
  ;; One walk, cycle-safe and depth-capped, for every reading taken up that tree.
  #:use-module (playnet planner aggregation containment)
  ;; the unit algebra, for the ONE stock→capacity conversion (utils/capacity.scm)
  #:use-module (playnet utils clock)
  #:use-module ((playnet utils units)
                #:select (convert-unit unit->substance unit-rate? unit-rate-parts
                          unit-known?))   ; compile.scm:218
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 match)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib facet)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (playnet governance ballot-store)
  #:use-module (playnet governance demand-registry)
  ;; Tests and external consumers historically got these via the
  ;; load-all.scm top-level pollution; re-export so `(use-modules
  ;; (playnet planner))` feels like the old load chain. The kanren
  ;; primitives come from kanren-constraints, which is the flavour the
  ;; main relational planner uses. vf-relations was retired with the
  ;; relational planner — it lives in (playnet deprecated planner vf-relations).
  ;; the federation recipe seeds are IMPORTED (knowledge recipes federation),
  ;; so they belong here — #:export of an imported name makes a hollow slot that
  ;; every importer resolves fine until the first call. The #:use-module must sit
  ;; in THIS form: #:re-export is settled at define-module time, and the
  ;; top-level (use-modules …) further down arrives far too late.
  #:use-module (playnet planner knowledge recipes federation)
  #:re-export (*spec-names* seed-federation-specs seed-federation-recipes
               seed-federation-inventory)
  #:re-export (let-values
            let*-values fold filter find remove partition append-map delete-duplicates iota
            first second third fourth any every count reduce match match-lambda match-lambda*
            ^ballot-store spawn-ballot-store ballot-store-env ^demand-registry
            spawn-demand-registry demand-registry-env
            ;; §0 — the VF ontology, now a module of its own
            %rented-frag-profile %rented-frag-profiles %rented-frag-tip
            *action-definitions* *adjustment-types* *agent-types*
            *buffer-classifications* *buffer-item-types* *buffer-zones-enum*
            *days-of-week* *decoupling-tests* *override-reasons* *property-effects*
            *quantity-effects* *replenishment-statuses* *target-zones* *vf-actions*
            <account> <action-definition> <agent-relationship-role>
            <agent-relationship> <agent> <agreement-bundle> <agreement>
            <availability-window> <batch-lot-record> <buffer-profile>
            <buffer-snapshot> <buffer-zone> <capacity-buffer> <claim-state> <claim>
            <commitment> <day-schedule> <decoupling-test-entry>
            <decoupling-test-result> <demand-adjustment-factor> <duration>
            <economic-event> <economic-resource> <fulfillment-state> <intent>
            <measure> <month-schedule> <plan> <planning-scenario>
            <positioning-analysis> <process-specification> <process> <proposal-list>
            <proposal> <recipe-exchange> <recipe-flow> <recipe-group> <recipe-process>
            <recipe> <replenishment-signal> <resource-specification>
            <satisfaction-state> <scenario-definition> <scenario> <spatial-thing>
            <specific-date-window> <time-range> <unit> <week-schedule>
            account-agent-id account-claimed-capacity
            account-contribution-capacity-factor account?
            action-definition-accountable-effect action-definition-accounting-effect
            action-definition-contained-effect action-definition-create-resource
            action-definition-eligible-for-exchange action-definition-event-quantity
            action-definition-implies-transfer action-definition-input-output
            action-definition-location-effect action-definition-onhand-effect
            action-definition-pairs-with action-definition-stage-effect
            action-definition-state-effect action-definition? adjustment-type?
            agent-availability-window agent-classified-as agent-id agent-image
            agent-name agent-note agent-primary-location agent-relationship-id
            agent-relationship-in-scope-of agent-relationship-note
            agent-relationship-object agent-relationship-relationship
            agent-relationship-role-classified-as agent-relationship-role-id
            agent-relationship-role-inverse-label agent-relationship-role-label
            agent-relationship-role-note agent-relationship-role?
            agent-relationship-subject agent-relationship? agent-type agent-type?
            agent? agreement-bundle-bundles agreement-bundle-created
            agreement-bundle-id agreement-bundle-name agreement-bundle-note
            agreement-bundle? agreement-created agreement-id agreement-name
            agreement-note agreement-stipulates agreement-stipulates-reciprocal
            agreement? availability-window-day-schedules
            availability-window-month-schedules availability-window-time-ranges
            availability-window-week-schedules availability-window?
            batch-lot-record-batch-lot-code batch-lot-record-expiration-date batch-lot-record-expiration-kind
            batch-lot-record-id batch-lot-record? buffer-classification?
            buffer-item-type? buffer-profile-code buffer-profile-id
            buffer-profile-item-type buffer-profile-lead-time-category
            buffer-profile-lead-time-factor buffer-profile-name buffer-profile-note
            buffer-profile-order-cycle-days buffer-profile-ost-multiplier
            buffer-profile-recalculation-cadence buffer-profile-variability-category
            buffer-profile-variability-factor buffer-profile-vrd buffer-profile-vrs
            buffer-profile? buffer-snapshot-date buffer-snapshot-onhand
            buffer-snapshot-spec-id buffer-snapshot-tog buffer-snapshot-tor
            buffer-snapshot-toy buffer-snapshot-zone buffer-snapshot?
            buffer-zone-active-adjustment-ids buffer-zone-adu
            buffer-zone-adu-alert-high-pct buffer-zone-adu-alert-low-pct
            buffer-zone-adu-alert-window-days buffer-zone-adu-blend-ratio
            buffer-zone-adu-computed-from buffer-zone-adu-unit
            buffer-zone-adu-window-days buffer-zone-at-location
            buffer-zone-bootstrap-days-accumulated buffer-zone-buffer-classification
            buffer-zone-demand-adj-factor buffer-zone-dlt-days
            buffer-zone-downstream-stage-id buffer-zone-enum?
            buffer-zone-estimated-adu buffer-zone-id buffer-zone-last-computed-at
            buffer-zone-lead-time-adj-factor buffer-zone-moq buffer-zone-moq-unit
            buffer-zone-order-cycle-days buffer-zone-ost-horizon-days
            buffer-zone-override-note buffer-zone-override-reason
            buffer-zone-profile-id buffer-zone-red-base buffer-zone-red-safety
            buffer-zone-replenishment-recipe-id buffer-zone-spec-id
            buffer-zone-staging-days buffer-zone-supply-offset-days
            buffer-zone-tipping-point buffer-zone-tog buffer-zone-tor buffer-zone-toy
            buffer-zone-transport-days buffer-zone-upstream-location-id
            buffer-zone-upstream-stage-id buffer-zone-zone-adj-factor buffer-zone?
            capacity-buffer-current-load-hours capacity-buffer-green-threshold
            capacity-buffer-id capacity-buffer-note capacity-buffer-period-days
            capacity-buffer-process-spec-id capacity-buffer-total-capacity-hours
            capacity-buffer-yellow-threshold capacity-buffer? claim-action
            claim-created claim-due claim-effort-quantity claim-finished claim-id
            claim-note claim-provider claim-receiver claim-resource-classified-as
            claim-resource-conforms-to claim-resource-quantity claim-state-claim-id
            claim-state-finished claim-state-settling-events claim-state-total-claimed
            claim-state-total-settled claim-state? claim-triggered-by claim?
            commitment-action commitment-at-location commitment-availability-window copy-commitment copy-economic-event copy-intent intent->commitment
            commitment-clause-of commitment-created commitment-due
            commitment-effort-quantity commitment-finished commitment-has-beginning
            commitment-has-end commitment-has-point-in-time commitment-id
            commitment-in-scope-of commitment-independent-demand-of
            commitment-input-of commitment-note commitment-output-of
            commitment-planned-within commitment-provider commitment-receiver
            commitment-resource-classified-as commitment-resource-conforms-to
            commitment-resource-inventoried-as commitment-resource-quantity
            commitment-satisfies commitment-stage commitment-state commitment?
            day-of-week? day-schedule-days day-schedule-time-ranges day-schedule?
            decoupling-test-entry-note decoupling-test-entry-passed
            decoupling-test-entry-test decoupling-test-entry?
            decoupling-test-result-approved-at decoupling-test-result-approved-by
            decoupling-test-result-results decoupling-test-result-spec-id
            decoupling-test-result? decoupling-test?
            demand-adjustment-factor-at-location demand-adjustment-factor-factor
            demand-adjustment-factor-id demand-adjustment-factor-is-active
            demand-adjustment-factor-note demand-adjustment-factor-spec-id
            demand-adjustment-factor-supply-offset-days
            demand-adjustment-factor-target-zone demand-adjustment-factor-type
            demand-adjustment-factor-valid-from demand-adjustment-factor-valid-to
            demand-adjustment-factor? duration-has-numerical-value duration-has-unit
            duration? economic-event-action economic-event-at-location
            economic-event-corrects economic-event-created
            economic-event-distribution-mode economic-event-effort-quantity
            economic-event-fulfills
            economic-event-has-beginning economic-event-has-end
            economic-event-has-point-in-time economic-event-id
            economic-event-in-scope-of economic-event-input-of
            economic-event-note economic-event-output-of
            economic-event-previous-event economic-event-provider
            economic-event-realization-of economic-event-receiver
            economic-event-resource-classified-as economic-event-resource-conforms-to
            economic-event-resource-inventoried-as economic-event-resource-quantity
            economic-event-satisfies economic-event-settles economic-event-state
            economic-event-to-location economic-event-to-resource-inventoried-as
            economic-event? economic-resource-accounting-quantity
            economic-resource-availability-window economic-resource-classified-as
            economic-resource-conforms-to economic-resource-contained-in
            economic-resource-current-location
            economic-resource-current-virtual-location
            economic-resource-custodian-scope economic-resource-distribution-mode
            economic-resource-id economic-resource-image economic-resource-lot
            economic-resource-name economic-resource-note
            economic-resource-onhand-quantity economic-resource-previous-event
            economic-resource-primary-accountable economic-resource-stage
            economic-resource-state economic-resource-tracking-identifier
            economic-resource-unit-of-effort economic-resource?
            event-distribution-mode fulfillment-state-commitment-id
            fulfillment-state-finished fulfillment-state-fulfilling-events
            fulfillment-state-over-fulfilled fulfillment-state-total-committed
            fulfillment-state-total-fulfilled fulfillment-state? intent-action
            intent-at-location intent-availability-window intent-available-quantity
            intent-due intent-effort-quantity intent-finished intent-has-beginning
            intent-has-end intent-has-point-in-time intent-id intent-image
            intent-in-scope-of intent-input-of intent-minimum-quantity intent-name
            intent-note intent-output-of intent-planned-within intent-provider
            intent-receiver intent-resource-classified-as intent-resource-conforms-to
            intent-resource-inventoried-as intent-resource-quantity intent-satisfies
            intent-stage intent-state intent? make-account make-action-definition
            make-agent make-agent-relationship make-agent-relationship-role
            make-agreement make-agreement-bundle make-availability-window
            make-batch-lot-record make-buffer-profile make-buffer-snapshot
            make-buffer-zone make-capacity-buffer make-claim make-claim-state
            make-commitment make-day-schedule make-decoupling-test-entry
            make-decoupling-test-result make-demand-adjustment-factor make-duration
            make-economic-event make-economic-resource copy-economic-resource make-fulfillment-state
            make-intent make-measure make-month-schedule make-plan
            make-planning-scenario make-positioning-analysis make-process
            make-process-specification make-proposal make-proposal-list make-recipe
            make-recipe-exchange make-recipe-flow make-recipe-group
            make-recipe-process make-replenishment-signal make-resource-specification
            make-satisfaction-state make-scenario make-scenario-definition
            make-spatial-thing make-specific-date-window make-time-range make-unit
            make-week-schedule measure-has-numerical-value measure-has-unit measure?
            month-schedule-day-schedules month-schedule-month
            month-schedule-time-ranges month-schedule-week-schedules month-schedule?
            override-reason? plan-classified-as plan-created plan-due
            plan-has-independent-demand plan-id plan-name plan-note plan-refinement-of
            plan? planning-scenario-id planning-scenario-note planning-scenario-path
            planning-scenario-probability planning-scenario-scenario
            planning-scenario-yield-multipliers planning-scenario?
            positioning-analysis-critical-operation-protection
            positioning-analysis-customer-tolerance-time-days
            positioning-analysis-decoupling-recommended
            positioning-analysis-inventory-leverage-flexibility
            positioning-analysis-market-potential-lead-time-days
            positioning-analysis-note
            positioning-analysis-sales-order-visibility-horizon-days
            positioning-analysis-vrd positioning-analysis-vrs positioning-analysis?
            process-based-on process-classified-as process-finished
            process-has-beginning process-has-end process-id process-in-scope-of
            process-name process-nested-in process-note process-planned-within
            process-specification-buffer-type process-specification-id
            process-specification-image process-specification-is-control-point
            process-specification-is-convergent-point
            process-specification-is-decoupling-point
            process-specification-is-divergent-point process-specification-name
            process-specification-note process-specification? process?
            property-effect? proposal-created proposal-eligible-location
            proposal-has-beginning proposal-has-end proposal-id proposal-in-scope-of
            proposal-list-created proposal-list-id proposal-list-lists
            proposal-list-name proposal-list-note proposal-list? proposal-name
            proposal-note proposal-proposed-to proposal-publishes proposal-purpose
            proposal-reciprocal proposal-unit-based proposal? quantity-effect?
            recipe-based-on recipe-exchange-id recipe-exchange-name
            recipe-exchange-note recipe-exchange? recipe-flow-action
            recipe-flow-effort-quantity recipe-flow-id recipe-flow-is-primary
            recipe-flow-note recipe-flow-recipe-clause-of recipe-flow-recipe-input-of
            recipe-flow-recipe-output-of recipe-flow-resolve-from-flow
            recipe-flow-resource-classified-as recipe-flow-resource-conforms-to
            recipe-flow-resource-quantity recipe-flow-stage recipe-flow-state
            recipe-flow? recipe-group-id recipe-group-name recipe-group-note
            recipe-group-recipes recipe-group? recipe-id recipe-name recipe-note
            recipe-primary-output recipe-process-has-duration recipe-process-id
            recipe-process-image recipe-process-minimum-batch-quantity
            recipe-process-name recipe-process-note
            recipe-process-process-classified-as recipe-process-process-conforms-to
            recipe-process-sequence-group recipe-process? recipe-recipe-exchanges
            recipe-recipe-processes recipe? rented-frag-profile rented-frag-tip
            rented-goods replenishment-signal-approved-commitment-id
            replenishment-signal-at-location replenishment-signal-buffer-zone-id
            replenishment-signal-created-at replenishment-signal-due-date
            replenishment-signal-id replenishment-signal-nfp
            replenishment-signal-onhand replenishment-signal-onorder
            replenishment-signal-priority replenishment-signal-qualified-demand
            replenishment-signal-recommended-qty replenishment-signal-spec-id
            replenishment-signal-status replenishment-signal-zone
            replenishment-signal? replenishment-status? resource-distribution-mode
            resource-rented? resource-sovereign? resource-spec-keep-in-place?
            resource-specification-buffer-profile-id
            resource-specification-default-unit-of-effort
            resource-specification-default-unit-of-resource specs->units resource-specification-id
            resource-specification-image resource-specification-keep-in-place
            resource-specification-medium-of-exchange resource-specification-name
            resource-specification-note resource-specification-positioning-analysis
            resource-specification-resource-classified-as
            resource-specification-satisfied-by resource-specification-substitutable
            resource-specification? satisfaction-state-finished
            satisfaction-state-intent-id satisfaction-state-plan-id
            satisfaction-state-satisfying-commitments
            satisfaction-state-satisfying-events satisfaction-state-total-desired
            satisfaction-state-total-satisfied satisfaction-state? scenario-defined-as
            scenario-definition-has-duration scenario-definition-id
            scenario-definition-in-scope-of scenario-definition-name
            scenario-definition-note scenario-definition? scenario-has-beginning
            scenario-has-end scenario-id scenario-in-scope-of scenario-name
            scenario-note scenario-refinement-of scenario? spatial-thing-alt
            spatial-thing-boundary spatial-thing-contained-in spatial-thing-id
            spatial-thing-lat spatial-thing-long spatial-thing-mappable-address
            spatial-thing-name spatial-thing-note spatial-thing?
            specific-date-window-specific-dates specific-date-window-time-ranges
            specific-date-window? target-zone? temporal-expression?
            time-range-end-time time-range-start-time time-range? unit-classified-as
            unit-id unit-label unit-symbol unit? vf-action?
            week-schedule-day-schedules week-schedule-weeks week-schedule?
            ;; from (playnet utils store-utils)
            deserialize-hashmap generate-id hashmap-any? hashmap-count hashmap-filter
            hashmap-filter-pairs hashmap-find hashmap-keys hashmap-map-values
            hashmap-values iso-datetime->epoch serialize-hashmap
            ;; from (playnet planner vf serdes)
            *vf-serdes-registry* register-vf-record! register-vf-records!
            vf-deserialize vf-record-instance? vf-serdes-clear!
            vf-serdes-lookup-by-instance vf-serdes-lookup-by-name vf-serialize
            ;; from (playnet planner algorithms propagation)
            *days-per-ms* *ms-per-day* *ms-per-hour* *ms-per-minute* *ms-per-second*
            *non-consuming-actions* compute-snlt create-flow-record min-snlt-for-spec
            recipe-output-qty rp-duration-days rp-duration-ms
            ;; from (playnet planner knowledge recipes store)
            ^recipe-store action-input-output find-flow recipe-deliverable list->process-specification
            list->recipe list->recipe-exchange list->recipe-flow list->recipe-group
            list->recipe-process list->resource-specification process-inputs
            process-outputs process-specification->list recipe->list
            recipe-exchange->list recipe-flow->list recipe-group->list
            recipe-process->list recipe-store-env resource-specification->list
            seed-spec-rows! spec-row-classes spec-row-id spec-row-name spec-row-unit



            ;; from (playnet planner indexes membership)
            build-membership-index citizen-share commune-share














            ;; from (playnet planner algorithms resource-flows)
            cash-flow-report
            ;; from (playnet planner algorithms track-trace)
            trace track

            ;; from (playnet planner ddmrp otif)
            compute-otif
            ;; from (playnet planner algorithms custody)
            apply-penalty apply-transfer-custody build-custody-ledger
            current-custodian custody-level
            entrustment-limit held-by incentive-compatible ledger-by-agent
            ledger-records make-custody-ledger penalty-svc scope-entrustment-capacity
            settle-custody tranche-coverage




            ;; from (playnet planner algorithms critical-path)
            critical-path
            ;; from (playnet planner algorithms skill-matcher)
            match-work-flows
            ;; from (playnet planner algorithms signals)
            *plan-tags* intent->signal plan-tag signal->intent
            ;; from (playnet planner algorithms sne)
            *non-consuming-actions-sne* build-sne-index/actor compute-recipe-sne/actor
            compute-sne-for-recipe direct-sne-for-spec
            ;; from (playnet planner dev recipes)
            seed-dev-knowledge!
            ;; from (playnet planner knowledge recipes infrastructure)
            infra-bandwidth-spec infra-compute-spec infra-dataset-spec
            infra-memory-spec infra-storage-spec infra-transcript-spec
            infrastructure-specs seed-infrastructure-recipes
                        
            *dwelling-specs* seed-dwelling-recipe seed-dwelling-specs
            %rent-eur-per-night seed-rent-recipe
            ;; from (playnet planner knowledge recipes flat-key)
            flat-key-world seed-flat-key-recipes!
            ;; from (playnet planner knowledge recipes currency)
            *currency-fiat-specs* *currency-store-of-value-specs*
            seed-currency-specs
            ;; from (playnet planner knowledge recipes container)
            seed-container-specs
                        
            seed-farm-commune! seed-holds! seed-farm-holds!
            ;; from (playnet planner knowledge recipes bread-commune-seed)
            seed-bread-recipes! seed-bread-commune!
            ;; from (playnet planner knowledge recipes federation-demo)
            seed-fed-commune!
            ;; from (playnet planner knowledge recipes food-chain-seed)
            food-stage seed-food-chain!
            ;; from (playnet planner knowledge recipes food-surplus)
            food-surplus-collected-spec food-surplus-produce-spec
            food-surplus-reefer-van-spec food-surplus-sorted-produce-spec
            food-surplus-volunteer-spec seed-food-surplus-3step-recipe
            seed-food-surplus-donor-specs seed-food-surplus-recipe
            seed-food-surplus-recipient-specs
            ;; from (playnet planner knowledge recipes cold-chain)
            cold-chain-food-specs cold-chain-process-specs cold-chain-storage-specs
            cold-chain-vehicle-specs cold-chain-skill-specs pa-dairy pa-frozen
            pa-pantry pa-perishable
            pspec-deliver pspec-pack pspec-pre-cool pspec-receive pspec-sort-inspect
            seed-cold-chain-recipe seed-cold-chain-specs spec-ambient-shelf
            spec-cargo-van spec-chilled-bay spec-cc-handling spec-dairy
            spec-dry-pantry spec-frozen-bay
            spec-frozen-meals-nut spec-frozen-meals-soy spec-leafy-greens
            spec-reefer-van
            ;; from (playnet planner knowledge recipes meeting)
            meeting-whole-acts seed-meeting-recipe
            ;; from (playnet planner knowledge recipes mimir)
            mimir-whole-acts seed-mimir-specs seed-mimir-recipes
            ;; from (playnet planner knowledge recipes grow)
            seed-grow-recipe seed-grow-specs
            ;; from (playnet planner knowledge recipes humisoil)
            seed-humisoil-recipe seed-humisoil-specs
            ;; from (playnet planner scope process-registry)
            ^process-registry list->process* process->list process-registry-env
            ;; from (playnet planner scope agents)
            ^agent-store agent->list agent-relationship->list
            agent-relationship-role->list agent-store-env list->agent
            list->agent-relationship list->agent-relationship-role
            ;; from (playnet planner plan recurrence)
            date-matches-window epoch->iso-date get-occurrence-status
            group-events-by-occurrence materialize-occurrence-dates
            occurrence-date-key unfulfilled-occurrences



            ;; from (playnet planner ddmrp buffer-snapshots)
            ^snapshot-store buffer-snapshot->list list->buffer-snapshot
            snapshot-store-env
            ;; from (playnet planner scope spatial-things)
            ^spatial-thing-store circle-boundary is-descendant-or-equal-hm
            list->spatial-thing resolve-chain-hm resolve-coordinates-hm
            spatial-thing->list spatial-thing-store-env
            ;; from (playnet planner ddmrp capacity-buffers)
            ^capacity-buffer-store capacity-buffer->list capacity-buffer-store-env
            list->capacity-buffer
            ;; from (playnet planner ddmrp buffer-zones)
            ^buffer-zone-store buffer-zone->list buffer-zone-store-env
            list->buffer-zone portrait->zones-hashmap zones-hashmap->portrait
            ;; from (playnet planner observation demand-policy)
            derive-communal-demand derive-dependent-demand
            ;; from (playnet planner observation transition)
            compute-claim-capacities compute-collective-metrics
            compute-communal-satisfaction-ratio compute-dollar-balance
            compute-dollar-wage-phase-out-factor compute-dollar-wages-per-worker
            compute-effective-net-market-wage compute-flow-fractions
            compute-real-wages compute-scope-transition-report
            compute-substitution-ratio compute-total-social-value
            compute-validated-hours compute-wage-rate-normalized extract-worker-hours
            ;; from (playnet planner observation live-resource)
            ^live-resource live-resource-env
            ;; from (playnet planner observation host-facts)
            parse-meminfo parse-loadavg parse-herd-running parse-running-value
            parse-ps-table process-tree-usage
            placement-ledger read-host-facts sync-host-facts!
            ;; from (playnet planner execution alerts)
            ^alert-store alert-kind alert-spec-id alert-store-env alert-timestamp
            ;; from (playnet planner execution capacity-execute)
            dispatch-async execute-with-event now-iso with-capacity
            with-enforced-capacity with-resources
            ;; from (playnet planner federation store-registry)
            ^store-registry parse-ref qualify store-registry-env
            ;; from (playnet planner federation remote-transport)
            hydrate-store snapshot-store
            ;; from (playnet planner plan schedule-book)
            can-commit-work? can-use-resource? committed-effort-on has-use-conflict
            schedule-blocks-for
            ;; from (playnet planner observation observer)
            <fold-ctx> <observer-state> ^observer append-index
            apply-container-location apply-direction-effects apply-quantity-effect
            apply-resource-effects capture-container-location check-process-completion
            create-batch-for-produce ctx-affected ctx-state
            ctx-update-state deserialize-observer-state economic-event->list
            economic-resource->list economic-resource-set-custodian-scope economic-resource-set-onhand-quantity
            economic-resource-set-location economic-resource-set-tracking-identifier economic-resource-set-lot
            empty-observer-state event-qty fold-ctx? get-action-def list->economic-event
            list->economic-resource make-fold-ctx make-observer-state measure-qty
            observer-env observer-record-event observer-state? os-agreements
            os-batches os-claim-targets os-events os-events-by-id os-commitment-targets
            os-idx-by-action os-idx-by-agent os-idx-by-process os-idx-by-resource
            os-idx-by-spec os-rebuild os-resource-batches os-resources
            os-intent-targets os-satisfiers 
            override-action-def phase-append-event
            phase-apply-effects phase-breadcrumb-chain phase-implied-transfer
            phase-index-event serialize-observer-state split-custody?
            ;; from (playnet planner algorithms correlation)
            <covariance-view> compute-correlation correlate-pairs
            covariance-view-bucket-seconds covariance-view-id covariance-view-method
            covariance-view? make-covariance-view pearson-rho series-stddev


            ;; from (playnet planner knowledge recipes bay-area-commune-seed)
            seed-bay-area-commune!
            ;; from (playnet planner algorithms value-equations)
            distribute-income distribute-multiple-income effort-equation effort-scorer
            equal-equation equal-scorer make-depreciation-scorer make-hybrid-equation
            resource-scorer score-event
            ;; from (playnet planner knowledge recipes transport)
            car-ride consume-flow* dropoff-flow mode-recipe pickup-flow pspec-transport
            recipe-carry recipe-hold relocation-recipe seed-recipe-entry!
            seed-baseline-modes! baseline-modes seed-transport-recipe seed-transport-specs spec-car spec-petrol spec-rider
            transport-specs use-flow work-flow*
            ;; from (playnet planner knowledge recipes beenius-wax)
            seed-beenius-build-recipe seed-beenius-journey seed-beenius-remelt-recipe
            seed-beenius-specs seed-beenius-sticks-recipe seed-beenius-wax-recipe
            ;; from (playnet planner knowledge recipes stone-paper)
            seed-stone-paper-bio-recipe seed-stone-paper-compost-recipe
            seed-stone-paper-recipe seed-stone-paper-reclaim-recipe
            seed-stone-paper-specs
                        
            network-resource pass-resource seed-relocation-recipe!
            transit-manners vehicle-resource
            ;; from (playnet planner plan store)
            <plan-store-state> ^plan-store append-to-index
            deserialize-plan-store-state empty-plan-store-state fold-promotions
            index-commitment-spec index-intent-spec index-intent-tags
            make-plan-store-state plan-store-env plan-store-state? pss-add-agreement
            pss-add-commitment pss-add-plan pss-agreement-bundles pss-agreements
            pss-claims pss-commitments pss-commitments-by-plan
            pss-commitments-by-process pss-commitments-by-spec pss-intents
            pss-intents-by-plan pss-intents-by-spec pss-meta pss-plans
            pss-promote-intent pss-proposal-lists pss-proposals
            pss-scenario-definitions pss-scenarios pss-tag-index pss-with-commitments
            pss-with-intents remove-from-index serialize-plan-store-state
            ;; from (playnet planner algorithms rollup common)
            recipe-gross-effort recipe-net-outputs rollup-recipes-producing
            standalone-snlt-for-spec
            ;; from (playnet planner knowledge recipes household)
            *household-bin-runs* *household-kit* *household-specs*
            *household-waste-streams* household-flows household-living-defs
            household-living-flows household-processes household-recipe-defs
            household-waste-flows household-waste-processes
            household-waste-recipe-defs seed-household-kit! seed-household-recipes
            seed-household-specs seed-household-waste-recipes
            household-care-flows household-care-processes household-care-recipe-defs
            seed-household-care-recipes
            ;; from (playnet planner knowledge recipes foodsharing-kit)
            *foodsaver-skill-args* *foodsharing-kit* declare-foodsaver-skill!
            enrol-foodsaver-trainee! foodsaver-skill foodsaver-skill-args
            foodsharing-cold-uses foodsharing-hand-uses foodsharing-kit-uses
            kit-per-pickup kit-spec-id kit-spec-name kit-unit seed-foodsharing-kit!
            seed-foodsharing-kit-specs!
            ;; from (playnet planner algorithms rollup relative-snlt)
            rollup-relative-snlt rollup-relative-snlt-for
            ;; from (playnet planner algorithms rollup)
            cost-variance crystallized-snlt-for-spec recipe-unit-snlt
            rollup-actual-cost rollup-producers-of rollup-standard-cost

            ;; from (playnet planner observation account)
            ^account-store account->list account-store-env
            consumer-voice current-social-free-time global-citizen-claimed
            global-citizen-count global-citizen-gross global-citizen-unmet
            global-citizenship-share set-person-substrate! person-aid? global-contribution-claim
            global-citizen-ability global-ability-norm
            global-effective-balance global-elastic-context
            global-embodied-labor-in-pool global-social-free-time
            global-sum-met-capacity
            global-sum-unmet-capacity global-total-claim-capacity
            global-total-social-svc list->account
            set-social-free-time! universal-credit-balance voice-share
            claimable-specs spec-claimable? spec-rail
            ;; from (playnet planner observation live-registry)
            ^live-registry live-registry-env live-availability
            ;; from (playnet planner ddmrp buffers)
            *consuming-actions* *epsilon* *ltf-ranges* *seconds-per-day*
            *standard-ltf* *standard-vf* *vf-ranges* adjust-vf-for-capacity
            adu-drift-alert aggregate-adjustment-factors analyze-recipe-topology
            assq-put average-on-hand-target blend-adu bootstrap-adu
            buffer-eligibility buffer-health-history buffer-status
            build-buffer-health-report build-profile-code capacity-buffer-status
            capacity-in-time cascade-component-daf check-item-type-consistency
            classify-analytics-zone classify-flow-speed compute-adu-differential
            compute-adu/events compute-buffer-zone-levels compute-decoupled-lead-time
            compute-execution-priority compute-forward-adu compute-lead-time-alerts
            compute-material-sync-alerts compute-min-max-buffer compute-nfp
            compute-otif-ddmrp compute-signal-integrity compute-time-buffer
            derive-variability-factor detect-adu-alerts flow-index
            generate-replenishment-signal leg-lead-time location-matches-ddmrp
            ltm-alert-zone ltm-alert-zone-full material-release-date
            material-sync-shortfall on-hand-alert orchestrate-buffer-recalibration
            order-activity-summary parse-profile-code prioritized-share
            project-buffer-zones project-on-hand qualify-demand
            recalibrate-buffer-zone recipe-lead-time recommend-buffer-type
            resolve-adjustment-factor run-recalibration-cycle
            score-positioning-analysis signal-compliance-history
            signal-integrity-report sort-by-priority-and-sequence standard-profile
            sum-onhand-at-location time-buffer-state time-in-zone
            validate-buffer-profile zone-distribution zone-transitions
            ;; from (playnet planner ddmrp monitors)
            buffer-status-monitor create-adu-shift-monitor create-recalibration-sink
            create-snapshot-sink material-sync-monitor standard-monitors
            standard-sinks
            ;; from (playnet planner scope root)
            ^scope-root scope-root-env spawn-scope-root
            ;; from (playnet planner scope earth)
            ^earth earth-env spawn-earth
            ;; from (playnet planner execution scope-execution)
            make-execution-context record-and-monitor
            ;; from (playnet planner formulas capacity)
            holding-capacity
            ;; from (playnet planner facts validity)
            apply-recert-schedule cred-claim-of cred-with-valid-until cred-live? custody-cred-live?
            ;; from (playnet planner formulas cadence)
            conformance-recert-schedule edge-reliance inspection-intensity
            recert-interval-discrete reliance->valid-until
            ;; from (playnet planner formulas skill-law)
            effective-skills
            ;; from (playnet planner formulas capacity)
            held-svc-caps svc-cap-key svc-eco-caps
            ;; from (playnet planner knowledge worlds feel-the-food)
            *batch-homogeneity* *feel-the-food-profiles* *feel-the-food-senses*
            chargenvermutung-asserts-rho chargenvermutung-condemns?
            chargenvermutung-sample feel-the-food-profile feel-the-food-rate
            feel-the-food-sample feel-the-food-saturates? feel-the-food-verdict
            homogeneity sample->implied-rho seed-feel-the-food! sense-criteria
            sense-destructive? spec-perishability unpresumed-units
            ;; from (playnet planner knowledge recipes berlin-transit)
            *berlin-mode-recipes*
            berlin-network-resources berlin-transit-manners berlin-transit-resources
            berlin-transit-svc-caps bt-cargo-bike-resource bt-network-resource
            bt-transit-pass-resource seed-berlin-cargo-bike-recipe
            seed-berlin-transit! seed-berlin-transit-haul-recipe
            seed-berlin-transit-specs
            ;; from (playnet planner knowledge recipes berlin-food-seed)
            *berlin-food-batch* *berlin-food-chain-stages* berlin-food-chain-stages
            seed-berlin-food-recipe! seed-berlin-food-scope!
            ;; from (playnet planner knowledge recipes berlin-commune-seed)
            seed-berlin-commune! seed-berlin-transit-arm!
            ;; from (playnet planner knowledge recipes berlin-festival-seed)
            seed-berlin-festival-arm! attach-festival-futures!
            ;; from (playnet planner knowledge catalogues conformance)
            *conformance-catalogue* conformance-frag-weight
            ;; from (playnet planner knowledge recipes berlin-flotte)
            *flotte-kommunal-bikes* *flotte-max-loan-days* *flotte-stations*
            *flotte-total-bikes* flotte-berlin-resources flotte-kommunal-lender
            flotte-loan-window flotte-spread-resources



              ;; from (playnet planner solve recipe-response)
              observed-capture recipe-response-report
              ;; from (playnet planner knowledge catalogues eco)
              *climate-tipping-points* *limit-reversibility* *planetary-boundaries*
              *planetary-catalogue* catalogue->policy catalogue->wire
              limit-attenuation-rate limit-monitoring-cadence limit-roster migrate-limit
              migrated->caps migrated->flows migrated->procs migrated->resources
              migrated->stock-frag migrated->storables migrated-limits migrated-place
              migrated-rate migrated-spec migrated-stock monitored-alpha
              reversibility-character reversibility-years roster-of-verdict
              witnessed-tipping-characters
              ;; from (playnet planner legal crossings)
              crossing-gloss crossing-kind recipe-channel rail-channel recipe-crossings
              register-crossing!
              ;; from (playnet planner solve compile)
              clear-use-unit-gaps! compile-process compile-recipe use-unit-gaps
              batch-unit-gaps clear-batch-unit-gaps!)
  #:export (; §5 — a RecipeProcess + its flows → a template
            ; the compile-time lint register
            ;; FEEL THE FOOD — the sensory check as a costed, destructive sample
            ;; joint production (rollup/common.scm, rollup/relative-snlt.scm)
            ;; convex-shared pure helpers (formulas/capacity.scm, formulas/skill-law.scm)
            ;; close the credential loop: reliance → recert cadence (formulas/cadence.scm, facts/validity.scm)
            ;; the legal crossings a recipe trips (legal/crossings.scm) — an OPEN catalogue,
            ;; so a jurisdiction's stewards register their own
            ;; the federation's fragility catalogue (eco-catalogue.scm): planetary
            ;; boundaries + climate tipping points as profiles, and the limits they
            ;; migrate into — read by the tension-registry, service.scm and live.scm
            )
  #:use-module (playnet planner vf serdes-bindings))
;; Three groups that used to be listed here are modules now, and reach the
;; umbrella's interface through #:re-export above rather than this list:
;; conformance-catalogue (governed barrier steepness), the former conformance-helpers
;; (service-capacity facts → Svc|spec eco-caps, now formulas/capacity) and recipe-response (the
;; comparator — a recipe's character, computed from its runs).

;; §5, the VF compiler. It lived only in the monolith (planner/planner.scm), so
;; `compile-process` and `compile-recipe` were unbound here and a test's choice
;; of loader decided whether the compile stage existed for it. Same text, both
;; loaders. Must follow schemas.scm, which defines *action-definitions*.
;; stocks.scm before eco-catalogue: the umbrella included the catalogue but not
;; the regenerating-stock records it builds, so make-regenerating-stock,
;; regenerating-stock->resource and stock-restore-flow were unbound on that
;; path. The monolith primitive-loads stocks.scm (planner.scm:3649), which is
;; why the same code works when loaded through the engine and not here.
;; rollup/common.scm (recipe-alternatives, the store read once) and rollup/fixpoint.scm
;; (`crystallize`, the one value rollup) precede rollup.scm and sne.scm — both price
;; through that kernel, as does the engine's good-labour-content
;; vf-relations was retired with the relational planner; it now lives at
;; (playnet deprecated planner vf-relations) and uses (playnet lang kanren).
