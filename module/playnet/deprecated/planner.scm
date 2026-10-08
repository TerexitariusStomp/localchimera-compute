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
;;   knowledge/recipes/meeting.scm
;;   knowledge/recipes/cold-chain.scm
;;   knowledge/recipes/food-surplus.scm
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

(define-module (playnet deprecated planner)
  #:use-module (playnet deprecated planner planning plan-federation)
  #:use-module (playnet deprecated planner relational ddmrp-leaf-planner)
  #:use-module (playnet deprecated planner relational strategy)
  #:use-module (playnet deprecated planner relational instrumentation)
  #:use-module (playnet deprecated planner relational federation)
  #:use-module (playnet deprecated planner relational streams)
  #:use-module (playnet deprecated planner relational federation-result)
  #:use-module (playnet deprecated planner relational plan-actor)
  #:use-module (playnet deprecated planner relational harmony)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (playnet deprecated planner relational plan-relation)
  #:use-module (playnet deprecated planner relational sne)
  #:use-module (playnet deprecated planner relational ddmrp)
  #:use-module (playnet deprecated planner relational signals)
  #:use-module (playnet deprecated planner relational grammar)
  #:use-module (playnet deprecated planner relational narrate)
  #:use-module (playnet deprecated planner relational demand-relation)
  #:use-module (playnet deprecated planner relational lexicon)
  #:use-module (playnet deprecated planner relational trace)
  #:use-module (playnet deprecated planner relational allocation)
  #:use-module (playnet deprecated planner relational planning-facts)
  #:use-module (playnet deprecated planner relational compute)
  #:use-module (playnet deprecated planner planning plan-for-region)
  #:use-module (playnet deprecated planner planning plan-for-scope)
  #:use-module (playnet deprecated planner planning plan-for-unit)
  #:use-module (playnet deprecated planner algorithms dependent-supply)
  #:use-module (playnet deprecated planner algorithms dependent-demand)
  #:use-module (playnet deprecated planner algorithms netting)
  #:use-module (playnet deprecated planner utils demand-priority)
  #:use-module (playnet planner execution scope-execution)
  #:use-module (playnet planner scope root)
  #:use-module (playnet planner ddmrp monitors)
  ;; #:select — relational/compute.scm reimplements 26 of ddmrp's names over
  ;; lifted facts. Importing them all would make every one of those dead code.
  #:use-module ((playnet planner ddmrp buffers)
                #:select (analyze-recipe-topology detect-adu-alerts material-release-date
                         time-buffer-state leg-lead-time signal-compliance-history
                         adjust-vf-for-capacity compute-adu/events qualify-demand
                         project-on-hand build-buffer-health-report recalibrate-buffer-zone
                         generate-replenishment-signal compute-lead-time-alerts
                         compute-time-buffer run-recalibration-cycle compute-otif-ddmrp
                         cascade-component-daf ltm-alert-zone *vf-ranges* recipe-lead-time
                         prioritized-share assq-put resolve-adjustment-factor
                         check-item-type-consistency compute-adu-differential *ltf-ranges*
                         compute-material-sync-alerts compute-signal-integrity
                         aggregate-adjustment-factors derive-variability-factor
                         material-sync-shortfall sort-by-priority-and-sequence compute-nfp
                         order-activity-summary location-matches-ddmrp
                         compute-buffer-zone-levels ltm-alert-zone-full
                         orchestrate-buffer-recalibration sum-onhand-at-location
                         standard-profile adu-drift-alert score-positioning-analysis
                         buffer-status recommend-buffer-type buffer-eligibility
                         buffer-health-history compute-execution-priority))
  #:use-module (playnet planner observation live-registry)
  #:use-module (playnet planner observation account)
  #:use-module (playnet planner pools credit-fold)   ; the global-* reads and voice-share, off the fold
  ;; #:select — relational/compute.scm defines the other three over lifted facts.
  #:use-module ((playnet deprecated planner algorithms metabolism)
                #:select (material-metabolism labour-metabolism metabolic-balance-legacy))
  #:use-module (playnet planner algorithms rollup)
  #:use-module (playnet planner plan store)
  ;; #:select — relational/compute.scm defines the other nine over lifted facts.
  #:use-module ((playnet planner algorithms value-equations)
                #:select (distribute-multiple-income))
  #:use-module (playnet deprecated planner indexes independent-supply)
  #:use-module (playnet planner algorithms correlation)
  #:use-module (playnet planner observation observer)
  #:use-module (playnet planner plan schedule-book)
  #:use-module (playnet planner federation remote-transport)
  #:use-module (playnet planner federation store-registry)
  #:use-module (playnet planner execution capacity-execute)
  #:use-module (playnet planner execution alerts)
  #:use-module (playnet planner observation live-resource)
  #:use-module (playnet planner observation transition)
  #:use-module (playnet planner observation demand-policy)
  #:use-module (playnet planner ddmrp buffer-zones)
  #:use-module (playnet planner ddmrp capacity-buffers)
  #:use-module (playnet planner scope spatial-things)
  #:use-module (playnet planner ddmrp buffer-snapshots)
  #:use-module (playnet deprecated planner utils buffer-type)
  #:use-module (playnet planner plan recurrence)
  #:use-module (playnet planner scope agents)
  #:use-module (playnet planner scope process-registry)
  #:use-module (playnet planner knowledge recipes humisoil)
  #:use-module (playnet planner knowledge recipes grow)
  #:use-module (playnet planner knowledge recipes meeting)
  #:use-module (playnet planner knowledge recipes cold-chain)
  #:use-module (playnet planner knowledge recipes food-surplus)
  #:use-module (playnet planner knowledge recipes infrastructure)
  #:use-module (playnet planner dev recipes)
  #:use-module (playnet planner algorithms sne)
  #:use-module (playnet planner algorithms signals)
  #:use-module (playnet planner algorithms skill-matcher)
  #:use-module (playnet planner algorithms critical-path)
  #:use-module (playnet deprecated planner algorithms shortest-path)
  #:use-module (playnet deprecated planner algorithms network-flow)
  #:use-module (playnet deprecated planner algorithms flow-graph)
  ;; #:select — relational/compute.scm (and planning-facts.scm) define these
  ;; names again over lifted facts. An unselected import would make the umbrella
  ;; #:re-export publish the recipe-store version and shadow the override.
  #:use-module ((playnet planner algorithms custody)
                #:select (settle-custody scope-entrustment-capacity ledger-by-agent apply-transfer-custody apply-penalty penalty-svc current-custodian ledger-records build-custody-ledger make-custody-ledger held-by))
  ;; #:select, not a bare import: relational/compute.scm redefines the other two
  ;; names at top level, and an unselected import would make that a redefinition
  ;; of an imported binding rather than a clean local definition.
  #:use-module ((playnet deprecated planner algorithms positioning)
                #:select (rank-control-point-candidates))
  #:use-module (playnet planner algorithms track-trace)
  #:use-module (playnet deprecated planner indexes intents)
  #:use-module (playnet deprecated planner indexes commitments)
  #:use-module (playnet deprecated planner indexes economic-events)
  #:use-module (playnet deprecated planner indexes economic-resources)
  #:use-module (playnet deprecated planner indexes independent-demand)
  #:use-module (playnet planner indexes membership)
  #:use-module (playnet deprecated planner indexes proposals)
  #:use-module (playnet deprecated planner indexes agents)
  #:use-module (playnet deprecated planner indexes index-utils)
  #:use-module (playnet planner knowledge recipes store)
  #:use-module ((playnet planner algorithms propagation)
                #:select (rp-duration-ms rp-duration-days *days-per-ms* min-snlt-for-spec recipe-output-qty *ms-per-minute* *ms-per-second* *ms-per-hour* compute-snlt create-flow-record *ms-per-day*))
  #:use-module (playnet planner vf serdes)
  #:use-module (playnet utils store-utils)
  #:use-module (srfi srfi-1)
  ;; the VF ontology, a module of its own. Imported HERE rather than loaded in
  ;; the body, because #:re-export below is processed at define-module time —
  ;; an import further down the file arrives too late for it.
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner formulas actions)
  #:use-module (playnet planner observation states)
  #:use-module (playnet planner beyond schedules)
  #:use-module (playnet planner beyond scenario)
  #:use-module (playnet planner beyond lot)
  #:use-module (playnet planner ddmrp records)
  #:use-module (playnet utils clock)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 match)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib facet)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (playnet deprecated kanren-constraints)
  #:use-module (playnet governance ballot-store)
  #:use-module (playnet governance demand-registry)
  ;; Tests and external consumers historically got these via the
  ;; load-all.scm top-level pollution; re-export so `(use-modules
  ;; (playnet planner))` feels like the old load chain. The kanren
  ;; primitives come from kanren-constraints, which is the flavour the
  ;; main relational planner uses. vf-relations uses a different
  ;; kanren — it lives in (playnet planner vf-relations).
  ;; the federation recipe seeds are IMPORTED (knowledge recipes federation),
  ;; so they belong here — #:export of an imported name makes a hollow slot that
  ;; every importer resolves fine until the first call. The #:use-module must sit
  ;; in THIS form: #:re-export is settled at define-module time, and the
  ;; top-level (use-modules …) further down arrives far too late.
  #:use-module (playnet planner knowledge recipes federation)
  #:re-export (*spec-names* seed-federation-specs seed-federation-recipes
               seed-federation-inventory
              ;; from (playnet deprecated planner algorithms dependent-demand)
              *epsilon-dd* *non-consuming-dd* dependent-demand unmet-intent?
              ;; from (playnet deprecated planner algorithms dependent-supply)
              *durable-actions* *epsilon-ds* dependent-supply
              ;; from (playnet deprecated planner planning plan-for-unit)
              *class-order* block-a block-b block-c build-retraction-candidates
              classify-demand compute-imperative-coherence ctx-dependent-demand
              debts->deficit-signals extract-demands extract-supply pass-1b
              plan-for-unit sort-classified supply-phase
              ;; from (playnet deprecated planner planning plan-for-scope)
              normalize-scopes plan-for-scope
              ;; from (playnet deprecated planner planning plan-for-region)
              normalize-cells plan-for-region
              ;; from (playnet deprecated planner relational compute)
              *consuming-actions* *epsilon* *input-actions* *non-consuming*
              *output-actions* *seconds-per-day* *standard-ltf* *standard-vf*
              *work-actions* adu-differential adu-drift aggregate-adjustments
              average-on-hand-target blend-adu bootstrap-adu build-profile-code
              build-sne-index capacity-buffer-status capacity-in-time cash-flow-report
              check-ownership-invariant classify-analytics-zone classify-flow-speed
              compute-adu compute-buffer-levels compute-decoupled-lead-time
              compute-due-date compute-forward-adu compute-input-sne
              compute-leg-lead-time compute-min-max-buffer compute-on-hand-projection
              compute-onhand compute-onorder compute-otif compute-prioritized-share
              compute-qualified-demand compute-recipe-lead-time compute-recipe-sne
              compute-replenishment-qty custody-level detect-adu-alert distribute-income
              dlt-recurse effort-equation effort-scorer entrustment-limit equal-equation
              equal-scorer execution-priority find-transport-recipe flow-index
              handle-cite-demand handle-use-demand incentive-compatible ltm-5zone
              ltm-alert make-depreciation-scorer make-hybrid-equation metabolic-balance
              net-available net-supply on-hand-alert parse-profile-code
              project-buffer-zones rank-control-points rank-decoupling-candidates
              resource-scorer routing-geometry score-event signal-integrity-report
              sort-by-priority spec-lifespan time-buffer time-in-zone trace-destination
              trace-provenance tranche-coverage validate-buffer-profile
              zone-distribution zone-transitions
              ;; from (playnet deprecated planner relational planning-facts)
              *non-consuming-actions* buffer-zone-indexed-o build-indexes
              chain-indexed-o chain-o cred-live? custody-cred-live? effective-skills
              fact-buffer-zone-o fact-chain-o fact-custodian-of-o fact-flow-o
              fact-inventory-o fact-recipe-o flow-indexed-o flow-o idx-ref
              idx-ref-single inventory-indexed-o inventory-o lift-claim-facts
              lift-commitment-facts lift-custody-facts lift-intent-facts
              lift-planning-facts lift-skill-facts process-o recipe-indexed-o recipe-o
              skill-cred-live?
              ;; from (playnet deprecated planner relational allocation)
              allocate-from-o allocate-o allocate-with-floors claim-from-o claims-add
              claims-ref conservation-floor narrow-domain-hi sum-leq-check
              ;; from (playnet deprecated planner relational trace)
              *default-trace-depth* consumed-by-o custody-level-o destination-o
              produces-o provenance-o
              ;; from (playnet deprecated planner relational lexicon)
              location-word-o spec-name-o spec-word-o tokenize-phrase
              ;; from (playnet deprecated planner relational demand-relation)
              *default-depth* after-allocation back-schedule-inputs cite-schedule-inputs
              demand-o produce-branch resolve-container-from-use-plans
              schedule-inputs-fold solve-cite-inputs-o solve-inputs-o solve-use-inputs-o
              transport-branch transport-recipe-o use-schedule-inputs
              ;; from (playnet deprecated planner relational narrate)
              narrate-o narrate-plan narrate-plan-tree narrate-produce-o
              narrate-query-result narrate-satisfied-o narrate-sub-plans
              narrate-transport-o narrate-unmet-o
              ;; from (playnet deprecated planner relational grammar)
              ask demand-question-o destination-question-o execute-query
              inventory-question-o parse-query provenance-question-o qty-np-o
              qty-spec-np-o query-o recipe-question-o spec-np-o word-o words-o
              ;; from (playnet deprecated planner relational signals)
              *signal-tags* intent->signal-o signal->intent-o signal-action-o
              signal-category-o signal-o signal-tag-o
              ;; from (playnet deprecated planner relational ddmrp)
              *max-location-depth* *variability-table* adjustment-factor-o
              buffer-zone-fact-o buffered-spec-o ddmrp-evaluate-o event-fact-o
              location-descendant-or-equal-o location-parent-o nfp-o
              replenishment-needed-o variability-factor-o zone-o
              ;; from (playnet deprecated planner relational sne)
              build-sne-index-o sne-o
              ;; from (playnet deprecated planner relational plan-relation)
              *epsilon-plan* all-demands-o by-due-date by-harmony-priority
              by-local-first demand-class extract-open-demands plan-o relational-plan
              ;; from (playnet deprecated planner relational plan-walk)
              *default-leaf-result-count* allocation-total demand-pair-demand
              demand-pair-goal demand-pair-spec demand-pair-term demand-pair?
              extract-deficits extract-retraction-candidates extract-surpluses
              fold-demand-pairs fold-plan-terms force-cands force-or-self plan-coherence
              plan-coherence-counts plan-external-qty plan-internal-qty plan-term-alloc
              plan-term-kind plan-term-qty plan-term-spec plan-term-subplans plan-term?
              produce-term? reify-from-state reify-s satisfied-term? transport-term?
              unmet-term?
              ;; from (playnet deprecated planner relational harmony)
              *default-priority-base* *default-priority-level* *harmony-epsilon*
              compute-harmony compute-weighted-harmony extract-demand-outcomes
              harmony-above-o harmony-at-least-o harmony-diff harmony-diff-o harmony-o
              make-weight-fn plan-harmony plan-harmony-o priority-level->weight
              retraction-harmony-impact retraction-loss-exact retraction-loss-upper
              weighted-harmony-o
              ;; from (playnet deprecated planner relational plan-actor)
              *plan-methods-readable* *plan-methods-summary* ^plan-actor
              federation-result-plan federation-result-plan-ref
              relational-plan->plan-actor-result spawn-plan-facet
              ;; from (playnet deprecated planner relational federation-result)
              *federation-result-methods-readable* *federation-result-methods-summary*
              ^federation-result ^federation-tree ^federation-tree-async
              actor->federation-result federation-result->actor fr-coherence fr-deficits
              fr-harmony fr-plan fr-plan-ref fr-residual fr-retraction-candidates
              fr-scope fr-surpluses spawn-federation-result
              spawn-federation-result-facet spawn-federation-tree
              spawn-federation-tree-async
              ;; from (playnet deprecated planner relational streams)
              pull-one-each stream-map-lazy stream-take-1 stream-take-best
              ;; from (playnet deprecated planner relational federation)
              %make-federation-config <federation-config> add-retraction-record
              advance-child advance-worst advance-worst-by-coherence
              advance-worst-by-harmony build-hierarchy cfg-leaf-planner
              cfg-leaf-planner-or-default cfg-max-steps cfg-plan-actor? cfg-weight-fn
              collect-child-cands collect-child-coherences collect-child-defs
              collect-child-harmonies collect-child-plans collect-child-surps
              default-relational-leaf-planner deficit-spec enrich-retraction-record
              entry-result evaluate-state expected-retraction-loss
              expected-transfer-for-cand federation-config? leaf-stream
              make-federation-config make-state-entry match-at-level parent-stream
              peer-scopes-o plan-federation-o pull-from-all
              relational-plan->federation-result relational-state->federation-result
              relevant-candidate? residual-zero? retract-demand-from-state
              retract-one-stream retraction-harmony-loss retraction-improved?
              retraction-stream scope-parent-o scope-stream search-stream
              sort-retraction-candidates state-entry-id state-entry-result
              state-entry-stream subtract-matched sum-harmony-totals sum-qty
              ;; from (playnet deprecated planner relational instrumentation)
              %make-perf-log <perf-log> count-plan-terms current-time-ms
              instrumented-federation instrumented-plan make-entry make-perf-log
              perf-log-append! perf-log-clear! perf-log-display perf-log-entries
              perf-log-summary perf-log? set-perf-log-entries!
              ;; from (playnet deprecated planner relational strategy)
              best-strategy-o demand-class-o plan-quality-o situation-o strategy-o
              strategy-outcome-o
              ;; from (playnet deprecated planner relational ddmrp-leaf-planner)
              *cascade-depth* *supply-bfs-depth* absorb-excess buffer-zone-fact
              buffered-spec-set build-ddmrp-federation-result
              collect-consumed-from-plans ddmrp-allocate-o ddmrp-demand-o
              ddmrp-leaf-planner ddmrp-plan-o decoupling-stop? earliest-due-from-demands
              extract-demands-from-ctx find-consuming-recipe process-input-qty
              recipe-consumes-amount recipe-outputs-with-amounts replenishment-cascade-o
              replenishment-o sum-onhand-from-facts supply-routing-o tor-floor toy-floor
              ;; from (playnet deprecated planner planning plan-federation)
              aggregate-federation-harmony build-scope-hierarchy
              collect-remaining-deficits endorse-by-tally fold-scopes match-laterally
              plan-federation propagate-confirmations retract-across-scopes)
  #:re-export (== succeed fail
            fresh call/fresh conde disj conj
            ;; kanren-constraints run forms (work with the
            ;; relational planner's CLP(FD) state)
            run-plan run-plan*
            project in-list-o
            var? walk walk*
            ;; SRFI helpers
            let-values let*-values
            fold filter find remove partition append-map delete-duplicates
            iota first second third fourth
            any every count reduce
            match match-lambda match-lambda*
            ;; Governance ballot-store (held by ^scope-root)
            ^ballot-store spawn-ballot-store ballot-store-env
            ;; Governance demand-registry (held by ^scope-root)
            ^demand-registry spawn-demand-registry demand-registry-env
            ;; the VF ontology, imported from (playnet planner vf schemas)
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
            <measure> <month-schedule> <plan> <positioning-analysis>
            <process-specification> <process> <proposal-list> <proposal>
            <recipe-exchange> <recipe-flow> <recipe-group> <recipe-process> <recipe>
            <replenishment-signal> <resource-specification> <satisfaction-state>
            <scenario-definition> <scenario> <spatial-thing> <specific-date-window>
            <time-range> <unit> <week-schedule> account-agent-id
            account-claimed-capacity account-contribution-capacity-factor account?
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
            batch-lot-record-batch-lot-code batch-lot-record-expiration-date
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
            commitment-action commitment-at-location commitment-availability-window
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
            make-economic-event make-economic-resource make-fulfillment-state
            make-intent make-measure make-month-schedule make-plan
            make-positioning-analysis make-process make-process-specification
            make-proposal make-proposal-list make-recipe make-recipe-exchange
            make-recipe-flow make-recipe-group make-recipe-process
            make-replenishment-signal make-resource-specification
            make-satisfaction-state make-scenario make-scenario-definition
            make-spatial-thing make-specific-date-window make-time-range make-unit
            make-week-schedule measure-has-numerical-value measure-has-unit measure?
            month-schedule-day-schedules month-schedule-month
            month-schedule-time-ranges month-schedule-week-schedules month-schedule?
            override-reason? plan-classified-as plan-created plan-due
            plan-has-independent-demand plan-id plan-name plan-note plan-refinement-of
            plan? positioning-analysis-critical-operation-protection
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
            recipe-recipe-processes recipe?
            replenishment-signal-approved-commitment-id
            replenishment-signal-at-location replenishment-signal-buffer-zone-id
            replenishment-signal-created-at replenishment-signal-due-date
            replenishment-signal-id replenishment-signal-nfp
            replenishment-signal-onhand replenishment-signal-onorder
            replenishment-signal-priority replenishment-signal-qualified-demand
            replenishment-signal-recommended-qty replenishment-signal-spec-id
            replenishment-signal-status replenishment-signal-zone
            replenishment-signal? replenishment-status? resource-distribution-mode
            resource-spec-keep-in-place? resource-specification-buffer-profile-id
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
            spatial-thing-contained-in spatial-thing-id spatial-thing-lat
            spatial-thing-long spatial-thing-mappable-address spatial-thing-name
            spatial-thing-note spatial-thing? specific-date-window-specific-dates
            specific-date-window-time-ranges specific-date-window? target-zone?
            temporal-expression? time-range-end-time time-range-start-time time-range?
            unit-classified-as unit-id unit-label unit-symbol unit? vf-action?
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
            compute-snlt create-flow-record min-snlt-for-spec
            rp-duration-days rp-duration-ms
            ;; from (playnet planner knowledge recipes store)
            ^recipe-store action-input-output list->process-specification list->recipe
            list->recipe-exchange list->recipe-flow list->recipe-group
            list->recipe-process list->resource-specification
            process-specification->list recipe->list recipe-exchange->list
            recipe-flow->list recipe-group->list recipe-process->list recipe-store-env
            resource-specification->list
            ;; from (playnet deprecated planner indexes index-utils)
            build-index index-query
            ;; from (playnet deprecated planner indexes agents)
            build-agent-index get-total-agent-hours query-agents-by-spec
            ;; from (playnet deprecated planner indexes proposals)
            build-proposal-index query-proposals-by-purpose query-proposals-by-scope
            ;; from (playnet planner indexes membership)
            build-membership-index citizen-share commune-share
            ;; from (playnet deprecated planner indexes independent-demand)
            build-independent-demand-index get-total-demand-quantity
            query-demand-by-action query-demand-by-scope query-demand-by-spec
            query-open-demands
            ;; from (playnet deprecated planner indexes economic-resources)
            build-economic-resource-index query-resources-by-accountable
            query-resources-by-location query-resources-by-spec
            query-resources-by-stage
            ;; from (playnet deprecated planner indexes economic-events)
            build-economic-event-index query-events-by-action query-events-by-agent
            query-events-by-process query-events-by-resource query-events-by-spec
            ;; from (playnet deprecated planner indexes commitments)
            build-commitment-index query-commitments-by-action
            query-commitments-by-agent query-commitments-by-intent
            query-commitments-by-plan query-commitments-by-process
            query-commitments-by-spec
            ;; from (playnet deprecated planner indexes intents)
            build-intent-index query-intents-by-action query-intents-by-agent
            query-intents-by-plan query-intents-by-spec
            ;; from (playnet planner algorithms resource-flows)
            ;; from (playnet planner algorithms track-trace)
            trace track
            ;; from (playnet deprecated planner algorithms positioning) — only the name the
            ;; relational planner does NOT override. routing-geometry and
            ;; rank-decoupling-candidates are defined again by relational/compute.scm
            ;; over lifted facts, so they stay in #:export below: #:re-export would
            ;; publish positioning's recipe-store version and shadow the override.
            rank-control-point-candidates
            ;; from (playnet planner ddmrp otif)
            ;; from (playnet planner algorithms custody)
            apply-penalty apply-transfer-custody build-custody-ledger
            current-custodian
            held-by ledger-by-agent
            ledger-records make-custody-ledger penalty-svc scope-entrustment-capacity
            settle-custody
            ;; from (playnet deprecated planner algorithms flow-graph)
            bilateral-flow boundary-objective build-flow-graph coherence external-flow
            interdependence internal-flow merge-candidates split-candidates total-flow
            ;; from (playnet deprecated planner algorithms network-flow)
            max-flow min-cut
            ;; from (playnet deprecated planner algorithms shortest-path)
            bellman-ford dijkstra reconstruct-path
            ;; from (playnet planner algorithms critical-path)
            critical-path
            ;; from (playnet planner algorithms skill-matcher)
            match-work-flows
            ;; from (playnet planner algorithms signals)
            *plan-tags* intent->signal plan-tag signal->intent
            ;; from (playnet planner algorithms sne)
            *non-consuming-actions-sne* build-sne-index/actor compute-recipe-sne/actor
            compute-sne-for-recipe
            ;; from (playnet planner dev recipes)
            seed-dev-knowledge!
            ;; from (playnet planner knowledge recipes infrastructure)
            infra-bandwidth-spec infra-compute-spec infra-dataset-spec
            infra-memory-spec infra-storage-spec infra-transcript-spec
            infrastructure-specs seed-infrastructure-recipes
                        
            food-surplus-collected-spec food-surplus-produce-spec
            food-surplus-reefer-van-spec food-surplus-sorted-produce-spec
            food-surplus-volunteer-spec seed-food-surplus-3step-recipe
            seed-food-surplus-donor-specs seed-food-surplus-recipe
            seed-food-surplus-recipient-specs
            ;; from (playnet planner knowledge recipes cold-chain)
            cold-chain-food-specs cold-chain-process-specs cold-chain-storage-specs
            cold-chain-vehicle-specs pa-dairy pa-frozen pa-pantry pa-perishable
            pspec-deliver pspec-pack pspec-pre-cool pspec-receive pspec-sort-inspect
            seed-cold-chain-recipe seed-cold-chain-specs spec-ambient-shelf
            spec-cargo-van spec-chilled-bay spec-dairy spec-dry-pantry spec-frozen-bay
            spec-frozen-meals-nut spec-frozen-meals-soy spec-leafy-greens
            spec-reefer-van
            ;; from (playnet planner knowledge recipes meeting)
            seed-meeting-recipe
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
            ;; from (playnet deprecated planner utils buffer-type)
            *buffer-types* *response-times* *tier-priority* *zone-ord*
            buffer-type-from-tags composite-buffer-priority get-buffer-type
            get-response-time
            ;; from (playnet planner ddmrp buffer-snapshots)
            ^snapshot-store buffer-snapshot->list list->buffer-snapshot
            snapshot-store-env
            ;; from (playnet planner scope spatial-things)
            ^spatial-thing-store is-descendant-or-equal-hm list->spatial-thing
            resolve-chain-hm resolve-coordinates-hm spatial-thing->list
            spatial-thing-store-env
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
            committed-effort-on has-use-conflict schedule-blocks-for
            ;; from (playnet planner observation observer)
            <fold-ctx> <observer-state> ^observer append-index
            apply-container-location apply-direction-effects apply-quantity-effect
            apply-resource-effects capture-container-location check-process-completion
            create-batch-for-produce ctx-affected ctx-state
            ctx-update-state deserialize-observer-state economic-event->list
            economic-resource->list economic-resource-set-custodian-scope
            economic-resource-set-location economic-resource-set-lot
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
            ;; from (playnet deprecated planner indexes independent-supply)
            build-independent-supply-index get-total-supply-quantity
            query-supply-by-spec
            ;; from (playnet planner algorithms value-equations)
            distribute-multiple-income
                        
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
            ;; from (playnet planner algorithms rollup)
            cost-variance rollup-actual-cost rollup-standard-cost
            ;; from (playnet deprecated planner algorithms metabolism)
            ;; from (playnet planner observation account)
            ^account-store account->list account-store-env
            global-citizen-gross global-citizen-unmet
            global-contribution-claim global-effective-balance global-elastic-context
            global-embodied-labor-in-pool
            global-sum-met-capacity global-sum-unmet-capacity
            global-total-claim-capacity global-total-social-svc
            list->account universal-credit-balance
            voice-share
            ;; from (playnet planner observation live-registry)
            ^live-registry live-registry-env
            ;; from (playnet planner ddmrp buffers)
            *ltf-ranges*
            *vf-ranges*
            adjust-vf-for-capacity adu-drift-alert aggregate-adjustment-factors
            analyze-recipe-topology assq-put
            buffer-eligibility buffer-health-history buffer-status
            build-buffer-health-report
            cascade-component-daf check-item-type-consistency
            compute-adu-differential
            compute-adu/events compute-buffer-zone-levels
            compute-execution-priority compute-lead-time-alerts
            compute-material-sync-alerts compute-nfp
            compute-otif-ddmrp compute-signal-integrity compute-time-buffer
            derive-variability-factor detect-adu-alerts
            generate-replenishment-signal leg-lead-time location-matches-ddmrp
            ltm-alert-zone ltm-alert-zone-full material-release-date
            material-sync-shortfall orchestrate-buffer-recalibration
            order-activity-summary prioritized-share
            project-on-hand qualify-demand
            recalibrate-buffer-zone recipe-lead-time recommend-buffer-type
            resolve-adjustment-factor run-recalibration-cycle
            score-positioning-analysis signal-compliance-history
            sort-by-priority-and-sequence standard-profile
            sum-onhand-at-location time-buffer-state
            ;; from (playnet planner ddmrp monitors)
            buffer-status-monitor create-adu-shift-monitor create-recalibration-sink
            create-snapshot-sink material-sync-monitor standard-monitors
            standard-sinks
            ;; from (playnet planner scope root)
            ^scope-root scope-root-env spawn-scope-root
            ;; from (playnet planner execution scope-execution)
            make-execution-context record-and-monitor
            ;; from (playnet deprecated planner utils demand-priority)
            *default-harmony-level* *default-priority* default-priority-fn
            fact-matches? harmony-level-from-facts make-harmony-level-fn
            make-priority-fn
              ;; from (playnet deprecated planner algorithms netting)
              *epsilon-pu* *non-consuming-actions-net* <netter-state> empty-netter-state
              make-netter-state netter-break-on-orphan netter-fork
              netter-migrate-witness netter-net-available netter-net-demand
              netter-net-supply netter-reserve netter-retract netter-state? ns-allocate
              ns-allocate+track ns-allocated ns-allocated? ns-claim-witness
              ns-claimed-by-plan ns-conservation-floors planning-signal?)
  #:export (;; relational/compute.scm's ddmrp reimplementation, over lifted facts
            ;; relational/compute.scm's metabolism trio, defined over facts
            ;; relational/compute.scm's value-equation family, defined over facts
            ;; relational/compute.scm + planning-facts.scm define these over
            ;; lifted facts; the algorithms modules above are #:select'd so
            ;; these local definitions are the ones the umbrella publishes.
            ;; relational/compute.scm's own (facts recipe-id) versions — the
            ;; positioning module's (recipe-id recipe-store) pair is deliberately
            ;; not imported above, so these two names are ours to define.
            ;; cold-chain recipe data
            ;; food-surplus recipe data
            ;; infrastructure recipe data
            ))

(use-modules (playnet planner vf serdes-bindings))
;; vf-relations is its own module: (playnet planner vf-relations).
;; It uses (playnet lang kanren), which has an incompatible state shape
;; with the (playnet kanren-constraints) primitives used above.
