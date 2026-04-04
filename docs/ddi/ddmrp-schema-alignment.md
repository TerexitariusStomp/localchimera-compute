# DDMRP Schema Alignment Analysis

**Reference**: Ptak & Smith, *Demand Driven Material Requirements Planning* (DDI Press, 3rd ed.)
**Schema source**: `src/lib/schemas.ts` (all VF types)
**Companion**: `docs/ddi/ddmrp-operational-map.md` (module-level map)
**Date**: 2026-03-05

---

## §1 Scope

This document performs a field-by-field alignment analysis between DDMRP operational concepts and
the VF type system in `src/lib/schemas.ts`. Every atomic DDMRP concept is classified as:

| Code | Meaning |
|---|---|
| **A** | **Aligned** — VF schema field or function covers the concept exactly |
| **M** | **Misaligned** — VF field exists but semantics differ in a meaningful way |
| **G** | **Gap** — No VF equivalent; new schema type or field extension needed |

Three-column alignment frame:
```
DDMRP concept  |  VF field / function  |  A / M / G
```

---

## §2 Master Translation Table

### C1 — Strategic Inventory Positioning

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| Decoupling point (design intent) | `ProcessSpecification` + proposed `isDecouplingPoint?` | `ProcessSpecification` | **G** | No typed marker field; must infer from `RecipeFlow.stage` patterns |
| Decoupling point marker (runtime) | `EconomicResource.stage` | `EconomicResource` | **A** | Stage = ProcessSpecification ID; set by `produce`/`modify`/`dropoff` events |
| Decoupling point filter on BOM flow | `RecipeFlow.stage` | `RecipeFlow` | **A** | Filters BOM flows requiring a specific process stage |
| Item type P / M / I | `ResourceSpecification.resourceClassifiedAs[]` | `ResourceSpecification` | **M** | Unstructured string array; no typed `'Purchased' \| 'Manufactured' \| 'Intermediate'` enum — see M4 |

### C2 — Buffer Profiles & Levels

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| Buffer profile entity | `BufferProfile` | `BufferProfileSchema` | **A** | Schema implemented; `leadTimeFactor`, `variabilityFactor`, `orderCycleDays` all present |
| Lead Time Factor (LTF) | `BufferProfile.leadTimeFactor` | `BufferProfileSchema` | **A** | Numeric multiplier on ADU × DLT for red zone base |
| Variability Factor (VF) | `BufferProfile.variabilityFactor` | `BufferProfileSchema` | **A** | Red safety = red base × VF; derivable from `vrd`/`vrs` via `deriveVariabilityFactor()` |
| Order cycle days | `BufferProfile.orderCycleDays` | `BufferProfileSchema` | **A** | Drives green zone: `max(ADU × orderCycleDays, redBase, MOQ)` |
| Lead time band (S/M/L) | `BufferProfile.leadTimeCategory` | `BufferProfileSchema` | **A** | Constrained enum `'short'\|'medium'\|'long'` per Ch 7 convention |
| Variability band (L/M/H) | `BufferProfile.variabilityCategory` | `BufferProfileSchema` | **A** | Constrained enum `'low'\|'medium'\|'high'` per Ch 7 convention |
| Profile code (e.g. "MML") | `BufferProfile.code` | `BufferProfileSchema` | **A** | 3-letter code: ItemType + LTCategory + VariabilityCategory |
| Buffer type classification | `BufferZone.bufferClassification` | `BufferZoneSchema` | **A** | `'replenished'\|'replenished_override'\|'min_max'` per Ch 7 |
| Min-max buffer (2-zone) | `computeMinMaxBuffer()` | `algorithms/ddmrp.ts` | **A** | TOY = TOR (no yellow zone); `recalibrateBufferZone()` dispatches correctly |
| Override zone guard | `recalibrateBufferZone()` | `algorithms/ddmrp.ts` | **A** | Returns zone unchanged when `bufferClassification === 'replenished_override'` |
| ADU — past (data source) | `groupEventsByOccurrence()` + `getOccurrenceStatus()` | `recurrence.ts` | **A** | Raw daily consumption data is available; no rolling calculator yet |
| ADU — forward (data source) | `materializeOccurrenceDates(window, from, to)` | `recurrence.ts` | **A** | Forward demand occurrences materializable from recurring Intents |
| ADU — blended calculator | *(none)* | — | **G** | No `computeBlendedADU()` function combining past + forward ADU |
| DLT from instantiated Plan | `criticalPath(planId, …).projectDuration` | `algorithms/critical-path.ts` | **A** | Correct for plan-level DLT; requires instantiated Processes with `hasBeginning/hasEnd` |
| DLT from Recipe template | Sum of `RecipeProcess.hasDuration` | `RecipeProcess` | **M** | Data exists; no `recipeLeadTime()` function; `criticalPath()` requires instantiated Processes — see M3 |
| MOQ | `RecipeProcess.minimumBatchQuantity` | `RecipeProcess` | **A** | `Measure` shape; enforced at recipe level |
| TOR / TOY / TOG | *(none)* | — | **G** | `BufferZone` schema needed — see G2 |
| Buffer zone entity | *(none)* | — | **G** | `BufferZone` schema needed — see G2 |
| Location-aware buffer | `Intent/Commitment.atLocation` | `Intent`, `Commitment` | **A** | `SpatialThing ID`; both demand and supply flows carry location |

### C3 — Dynamic Adjustments

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| Recalculated adjustment trigger | *(none)* | — | **G** | No zone-recalculation trigger or event type |
| DAF (Demand Adjustment Factor) | *(none)* | — | **G** | `DemandAdjustmentFactor` schema needed — see G4 |
| Zone Adjustment Factor | *(none)* | — | **G** | Field on `DemandAdjustmentFactor`; see G4 |
| Lead Time Adjustment Factor | *(none)* | — | **G** | Field on `DemandAdjustmentFactor`; see G4 |
| Supply Offset (timing) | *(none)* | — | **G** | Field on `DemandAdjustmentFactor`; see G4 |
| Seasonal / recurring demand | `Intent/Commitment.availability_window` | `Intent`, `Commitment` | **A** | `AvailabilityWindow` temporal expression covers recurring patterns |
| Ramp-up / ramp-down | `Intent.hasBeginning/hasEnd` + `Intent.availableQuantity` | `Intent` | **A** | Quantity ramps modeled by sequencing Intents with different `availableQuantity` values |

### C4 — Supply Order Generation

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| On-Hand (physical / custody) | `EconomicResource.onhandQuantity` | `EconomicResource` | **A** | Custody-based; updated by `transferCustody`, `pickup/dropoff`, `produce/consume` |
| On-Hand (rights / accounting) | `EconomicResource.accountingQuantity` | `EconomicResource` | **A** | Rights-based; updated by `transferAllRights`, `produce/consume`; includes in-transit |
| On-Order MO | `Commitment{action:'produce', outputOf}` | `Commitment` | **A** | Manufacturing order = produce Commitment attached to an output Process |
| On-Order PO | `Commitment{action:'transferAllRights'\|'transfer', outputOf}` | `Commitment` | **A** | Purchase order = transfer Commitment with future output date |
| On-Order TO | `Commitment{action:'transferCustody'\|'transfer', outputOf}` | `Commitment` | **A** | Transfer order = custody-transfer Commitment |
| Qualified Demand (due today) | `Commitment/Intent{inputOf, due ≤ today, !NON_CONSUMING}` | `Commitment`, `Intent` | **A** | Filter exists in `netting.ts`; no dedicated `qualifyDemand()` function — see M7 |
| Qualified Demand spike filter (OST) | *(none)* | — | **G** | No OST horizon or spike-threshold filter; all demand included |
| NFP (signed, allows negative) | *(none)* | — | **G** | `netAvailableQty()` clamps to 0; true signed NFP needs `computeNFP()` — see M1 |
| NFP (approximate, non-negative) | `PlanNetter.netAvailableQty()` | `netting.ts` | **M** | Clamps at `Math.max(0, total)`; uses `accountingQuantity` not `onhandQuantity` — see M1, M2 |
| TOY trigger comparison | *(none)* | — | **G** | No zone-comparison function (`NFP ≤ TOY → fire`) |
| Replenishment recommendation | *(none)* | — | **G** | `ReplenishmentSignal` schema needed — see G3 |
| TOG − NFP order quantity | *(none)* | — | **G** | No calculation; requires `BufferZone.tog` |
| MOQ enforcement on order | `RecipeProcess.minimumBatchQuantity` | `RecipeProcess` | **G** | Template data exists; no trigger logic on order generation |
| OTOG% rounding | *(none)* | — | **G** | No function to round order qty to MOQ/multiple-of-MOQ |
| Independent demand | `Commitment.independentDemandOf` | `Commitment` | **A** | Plan ID link marks terminal deliverables |
| Independent demand list | `Plan.hasIndependentDemand[]` | `Plan` | **A** | Array of Commitment/Intent IDs |
| Planning priority % (NFP/TOG) | *(none)* | — | **G** | No `priority = NFP/TOG` ratio computation |
| Prioritized share (zone-fill) | `ScenarioIndex.paretoFront()` | `space-time-scenario.ts` | **M** | Pareto multi-dimensional geographic search ≠ DDMRP sequential zone-fill (TOR→TOY→proportional green) — see M9 |
| Supply order approval (ATP) | `promoteToCommitment()` | `plan-for-region.ts` | **A** | ATP validation: checks `minimumQuantity`, decrements `availableQuantity` |
| ATP: minimumQuantity check | `Intent.minimumQuantity` + `promoteToCommitment()` | `Intent` | **A** | Validation built into `promoteToCommitment()` |
| ATP: availableQuantity decrement | `Intent.availableQuantity` decremented by `promoteToCommitment()` | `Intent` | **A** | Automatic decrement on commitment creation |
| Purchase Intent (external sourcing) | `DependentDemandResult.purchaseIntents[]` | `planning/dependent-demand.ts` | **A** | Separate array for unresolvable internal demand (externally sourced) |
| Supplier matching | `Proposal.publishes[]` + `purpose:'offer'\|'request'` | `Proposal` | **A** | Proposals represent offers/requests; Intents within match supply to demand |
| Supply agreement | `Agreement.stipulates / stipulatesReciprocal` | `Agreement` | **A** | Primary and reciprocal Commitments bound to Agreement |
| Blanket PO grouping | `Commitment.clauseOf` → Agreement ID | `Commitment` | **A** | Commitments reference their parent Agreement via `clauseOf` |

### C5 — Visible & Collaborative Execution / Execution Alerts

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| Buffer status % (OH / TOG) | `EconomicResource.onhandQuantity` (partial) | `EconomicResource` | **M** | `onhandQuantity` exists; TOG missing (requires `BufferZone`); ratio uncomputable — see G2 |
| Current on-hand alert threshold | *(none)* | — | **G** | No alert engine for OH dropping below TOR |
| Projected on-hand (day-by-day) | *(none)* | — | **G** | No time-phased inventory projection |
| Material synchronization shortfall | `PlanNetter.netDemand()` | `netting.ts` | **A** | Net demand data available; no alert engine (G) |
| LTM alert horizon | `Commitment.due` | `Commitment` | **A** | Due date exists; no horizon engine to fire LTM alerts (G) |
| FulfillmentState | `Observer.FulfillmentState{totalCommitted, totalFulfilled, finished}` | `observer.ts` | **A** | Complete commitment fulfillment tracking |
| Over-fulfillment detection | `Observer emits 'over_fulfilled'` | `observer.ts` | **A** | Emitted when event quantity exceeds `totalCommitted` |
| Process completion | `Observer emits 'process_completed'` | `observer.ts` | **A** | Emitted when all Commitments for a Process are finished |
| Track/trace provenance | `track-trace.ts` + `EconomicEvent.previousEvent` | `track-trace.ts` | **A** | Full backward trace via `previousEvent` breadcrumbs |
| Lot/batch tracking | `EconomicResource.lot` (`BatchLotRecord`) + `trackingIdentifier` | `EconomicResource` | **A** | `BatchLotRecord{id, batchLotCode, expirationDate}` |
| Correction events | `EconomicEvent.corrects` | `EconomicEvent` | **A** | Immutable correction chain; original events preserved |
| Claim (receipt obligation) | `Claim.triggeredBy` (EconomicEvent ID) | `Claim` | **A** | Claim created from receipt event; provider obligated |
| Signal integrity raw data | `Observer.FulfillmentState` | `observer.ts` | **A** | Raw fulfillment state available; dashboard = G |
| Order activity dashboard | *(none)* | — | **G** | No aggregation / dashboard layer |
| Buffer health analytics | *(none)* | — | **G** | No time-series buffer health (OH vs. TOR/TOY/TOG) — see M10 |

### Scheduling

| DDMRP Term | VF Schema Field / Function | Schema Type | Status | Notes |
|---|---|---|---|---|
| Decoupled routing legs | `RecipeStore.getProcessChain()` | `knowledge/recipes.ts` | **A** | Returns ordered chain of RecipeProcesses for a Recipe |
| DLT per leg (plan-level) | `criticalPath(planId, …)` | `algorithms/critical-path.ts` | **A** | Instantiated Plan processes with `hasBeginning/hasEnd` |
| DLT per leg (template) | Sum of `RecipeProcess.hasDuration` | `RecipeProcess` | **M** | No `recipeLeadTime()` function; manual sum required — see M3 |
| Work center actual load | `ScheduleBook.committedEffortOn(agentId, dt)` | `planning/schedule-book.ts` | **A** | Sums work Commitments on date; excludes Intents |
| Agent capacity | `AgentCapacity{total_hours, committed_hours, remaining_hours}` | `indexes/agents.ts` | **A** | One record per (agent, space_time_signature) |
| Time-slot conflict | `ScheduleBook.hasUseConflict(resourceId, [from, to))` | `planning/schedule-book.ts` | **A** | Half-open interval conflict detection |
| Resource availability | `ScheduleBook.isResourceAvailable(resourceId, dt)` | `planning/schedule-book.ts` | **A** | Point-in-time availability query |
| Agent working hours | `Agent.availability_window` | `Agent` | **A** | `TemporalExpression` on the Agent record |
| Control point marker | `ProcessSpecification` via `classifiedAs` tag | `ProcessSpecification` | **M** | Unstructured tag; no typed `isControlPoint` field — see M5 |
| Control point scheduler | *(none)* | — | **G** | No dedicated control-point scheduling queue |
| Sequence constraint group | `RecipeProcess.processClassifiedAs[]` tag | `RecipeProcess` | **M** | Unstructured; no typed sequence-group field |
| Priority-sorted scheduling queue | *(none)* | — | **G** | No priority queue for WIP dispatch |
| WIP dispatch list | *(none)* | — | **G** | No execution dispatch view |
| TOG × hasDuration (capacity ceiling) | *(none)* | — | **G** | No function to compute capacity ceiling from buffer sizing |

---

## §3 Confirmed Alignments (A1–A30)

| ID | DDMRP Concept | VF Type | Function / Field |
|---|---|---|---|
| A1 | Decoupling point marker (runtime) | `EconomicResource` | `.stage` (ProcessSpecification ID) |
| A2 | Decoupling point filter on BOM | `RecipeFlow` | `.stage` (ProcessSpecification ID) |
| A3 | ADU — past data source | `recurrence.ts` | `groupEventsByOccurrence()`, `getOccurrenceStatus()` |
| A4 | ADU — forward data source | `recurrence.ts` | `materializeOccurrenceDates(window, from, to)` |
| A5 | DLT from instantiated Plan | `algorithms/critical-path.ts` | `criticalPath(planId, …).projectDuration` |
| A6 | MOQ | `RecipeProcess` | `.minimumBatchQuantity` (`Measure`) |
| A7 | Location-aware buffer | `Intent`, `Commitment` | `.atLocation` (SpatialThing ID) |
| A8 | Seasonal / recurring demand | `Intent`, `Commitment` | `.availability_window` (`TemporalExpression`) |
| A9 | Ramp-up / ramp-down | `Intent` | `.hasBeginning`, `.hasEnd`, `.availableQuantity` |
| A10 | On-Hand (physical) | `EconomicResource` | `.onhandQuantity` |
| A11 | On-Hand (rights / accounting) | `EconomicResource` | `.accountingQuantity` |
| A12 | On-Order MO | `Commitment` | `action:'produce'`, `outputOf` set |
| A13 | On-Order PO | `Commitment` | `action:'transferAllRights'\|'transfer'`, `outputOf` set |
| A14 | On-Order TO | `Commitment` | `action:'transferCustody'\|'transfer'`, `outputOf` set |
| A15 | Qualified Demand (due today, filter) | `netting.ts` | `inputOf` set + `!NON_CONSUMING_ACTIONS` filter |
| A16 | Independent demand | `Commitment` | `.independentDemandOf` (Plan ID) |
| A17 | Independent demand list | `Plan` | `.hasIndependentDemand[]` |
| A18 | Supply order approval (ATP) | `plan-for-region.ts` | `promoteToCommitment()` |
| A19 | ATP: minimumQuantity check | `Intent` | `.minimumQuantity` + `promoteToCommitment()` validation |
| A20 | ATP: availableQuantity decrement | `Intent` | `.availableQuantity` decremented by `promoteToCommitment()` |
| A21 | Purchase Intent (external sourcing) | `planning/dependent-demand.ts` | `DependentDemandResult.purchaseIntents[]` |
| A22 | Supplier matching | `Proposal` | `.publishes[]` + `purpose:'offer'\|'request'` |
| A23 | Supply agreement | `Agreement` | `.stipulates`, `.stipulatesReciprocal` |
| A24 | Blanket PO grouping | `Commitment` | `.clauseOf` (Agreement ID) |
| A25 | FulfillmentState | `observer.ts` | `FulfillmentState{totalCommitted, totalFulfilled, finished}` |
| A26 | Over-fulfillment detection | `observer.ts` | `ObserverEvent{type:'over_fulfilled'}` |
| A27 | Process completion | `observer.ts` | `ObserverEvent{type:'process_completed'}` |
| A28 | Track/trace provenance | `track-trace.ts` | `EconomicEvent.previousEvent` breadcrumbs |
| A29 | Lot/batch tracking | `EconomicResource` | `.lot` (`BatchLotRecord`), `.trackingIdentifier` |
| A30 | Correction events | `EconomicEvent` | `.corrects` (EconomicEvent ID) |

---

## §4 Misalignments (M1–M10)

### M1 — NFP sign: `netAvailableQty()` clamps at zero

| | Detail |
|---|---|
| **VF provides** | `PlanNetter.netAvailableQty()` returning `Math.max(0, total)` (`netting.ts:428`) |
| **DDMRP requires** | Signed NFP = `onhand + onorder − qualifiedDemand`; **negative values are valid** (stockout = NFP < 0; below TOR zone) |
| **Semantic delta** | A clamped-to-zero result cannot distinguish "just at zero" from "−50 units in stockout". Zone logic (`NFP ≤ TOY`) breaks entirely when NFP is forced non-negative |
| **Proposed fix** | New `computeNFP(specId, bufferZoneId, opts): number` function in an algorithm file that returns the raw signed total without clamping |

### M2 — Buffer status uses accounting not physical quantity

| | Detail |
|---|---|
| **VF provides** | `PlanNetter.netAvailableQty()` sums `accountingQuantity` (rights-based, includes in-transit) |
| **DDMRP requires** | Buffer status = physical on-hand (`onhandQuantity`, custody-based) |
| **Semantic delta** | In-transit goods inflate the accountingQuantity; buffer status would appear healthier than reality until goods arrive |
| **Proposed fix** | Buffer status queries must bypass `PlanNetter` and use `Observer.conformingResources(specId)` directly, summing `onhandQuantity` |

### M3 — Template DLT: no `recipeLeadTime()` function

| | Detail |
|---|---|
| **VF provides** | `RecipeProcess.hasDuration` (`Duration`) on each recipe step |
| **DDMRP requires** | DLT from the recipe template (before a Plan is instantiated) — used during buffer profiling and `BufferZone` calculation |
| **Semantic delta** | `criticalPath()` requires instantiated `Process` records with `hasBeginning/hasEnd`. Template DLT must be manually summed from `RecipeProcess.hasDuration` — no function exists |
| **Proposed fix** | New `recipeLeadTime(recipeId, recipeStore): number` function that walks `RecipeStore.getProcessChain()` and sums `hasDuration` along the critical path |

### M4 — Item type P/M/I: unstructured classification

| | Detail |
|---|---|
| **VF provides** | `ResourceSpecification.resourceClassifiedAs[]` — free string array (taxonomy URIs or ad hoc strings) |
| **DDMRP requires** | Typed `'Purchased' \| 'Manufactured' \| 'Intermediate'` item type driving buffer profile selection logic |
| **Semantic delta** | No enforcement, no autocomplete, no type-safe filtering. Buffer profile lookup cannot be type-safe |
| **Proposed fix** | New `BufferProfile.itemType: 'Purchased' \| 'Manufactured' \| 'Intermediate'` (on `BufferProfile` schema, not `ResourceSpecification`). `ResourceSpecification.bufferProfileId?` links the spec to its profile |

### M5 — Control/decoupling point: no typed marker

| | Detail |
|---|---|
| **VF provides** | `ProcessSpecification.classifiedAs` (unstructured); `RecipeFlow.stage` (runtime marker) |
| **DDMRP requires** | Explicit design-time flags: `isDecouplingPoint` (strategic buffer placement), `isControlPoint` (scheduling pacemaker) |
| **Semantic delta** | Current code must infer decoupling from `RecipeFlow.stage` patterns — brittle, requires traversal; no single authoritative field |
| **Proposed fix** | Add `isDecouplingPoint?: boolean` and `isControlPoint?: boolean` to `ProcessSpecificationSchema` |

### M6 — On-Order composition: Intents included with Commitments

| | Detail |
|---|---|
| **VF provides** | `IndependentSupplyIndex.SupplySlot` includes both `scheduled_receipt` slots sourced from Commitments AND Intents |
| **DDMRP requires** | On-Order = approved, bilateral Commitments only; Intents are unilateral and unconfirmed |
| **Semantic delta** | Including unconfirmed Intents inflates on-order, making NFP appear more positive than it is |
| **Proposed fix** | `computeNFP()` must filter supply slots: include `slot_type === 'scheduled_receipt'` only when the source is a `Commitment` (not Intent) |

### M7 — Qualified demand: no OST filter or today-gate function

| | Detail |
|---|---|
| **VF provides** | `DemandSlot.remaining_quantity` = all unfulfilled demand with no OST spike filter; temporal filter exists in `PlanNetter.netDemand()` but is not exposed as a standalone function |
| **DDMRP requires** | Qualified demand = demand with `due ≤ today` AND quantity ≤ OST spike threshold (Order Spike Threshold horizon) |
| **Semantic delta** | Spike demand beyond OST is excluded in DDMRP to avoid phantom qualification; without filter, NFP understates inventory position |
| **Proposed fix** | New `qualifyDemand(specId, today, ostHorizon, ostThreshold, planStore): number` function |

### M8 — Forward labor capacity not available via `committedEffortOn()`

| | Detail |
|---|---|
| **VF provides** | `ScheduleBook.committedEffortOn(agentId, dt)` counts only work Commitments (backward-looking); `AgentCapacity.remaining_hours` in `indexes/agents.ts` gives forward view |
| **DDMRP requires** | Forward capacity view from uncommitted Intents (offers) for scheduling |
| **Semantic delta** | Forward planning sessions need `AgentCapacity.remaining_hours` from `AgentIndex`, not `committedEffortOn()` |
| **Proposed fix** | Use `AgentCapacity.remaining_hours` from `AgentIndex` for forward capacity view; document this distinction |

### M9 — Prioritized share: Pareto ≠ DDMRP zone-fill

| | Detail |
|---|---|
| **VF provides** | `ScenarioIndex.paretoFront()` — multi-dimensional Pareto search across H3 cells, optimizing geographic/spec dimensions simultaneously |
| **DDMRP requires** | Prioritized share = sequential zone-fill: fill all buffers to TOR first → then fill to TOY → then distribute remaining proportionally within green zone |
| **Semantic delta** | Pareto is a different optimization objective. It does not respect the DDMRP sequential zone-fill priority |
| **Proposed fix** | New `prioritizedShare(bufferZones: BufferZone[], supplyQty: number): Map<string, number>` function |

### M10 — Buffer health analytics: cash flow vs. inventory time-series

| | Detail |
|---|---|
| **VF provides** | `cashFlowReport()` in `resource-flows.ts` — tracks monetary inflows/outflows per agent over time |
| **DDMRP requires** | Buffer health = `onhandQuantity` time-series vs. TOR/TOY/TOG thresholds per ResourceSpecification |
| **Semantic delta** | Monetary flows ≠ physical inventory position. Different data, different schema, different analytics |
| **Proposed fix** | New buffer health analytics function using `Observer.conformingResources()` + `BufferZone` as substrate |

---

## §5 Gap Modules (G-series)

Proposed schema shapes for all gaps. Computation functions belong in algorithm files (future work).

### G1 — BufferProfile (DDS&OP master settings)

```typescript
BufferProfile {
  id: string
  name: string
  itemType: 'Purchased' | 'Manufactured' | 'Intermediate'
  leadTimeFactor: number        // LTF: 0.5 (short) / 1.0 (medium) / 1.5 (long)
  variabilityFactor: number     // VF: 0.1 (low) / 0.5 (medium) / 1.0 (high)
  orderCycleDays?: number       // for green zone: order_cycle × ADU
  note?: string
}
```

**Links to**: `ResourceSpecification.bufferProfileId?` (new extension field)

### G2 — BufferZone (per-spec computed zone parameters)

```typescript
BufferZone {
  id: string
  specId: string                // ResourceSpecification ID
  profileId: string             // BufferProfile ID
  atLocation?: string           // SpatialThing ID (null = all locations)
  // ADU inputs
  adu: number
  aduUnit: string
  aduBlendRatio?: number        // 0–1: proportion past vs. forward in blended ADU
  // DLT
  dltDays: number               // Decoupled Lead Time in days
  // MOQ (mirrored from RecipeProcess.minimumBatchQuantity for quick access)
  moq: number
  moqUnit: string
  // Computed zone boundaries
  tor: number                   // Top of Red  = ADU × DLT × LTF × (1 + VF)  [red base + red safety]
  toy: number                   // Top of Yellow = TOR + ADU × DLT
  tog: number                   // Top of Green = TOY + green  = TOY + max(ADU × orderCycle, MOQ)
  // Adjustment factors
  demandAdjFactor?: number      // DAF multiplier on ADU (default 1.0)
  zoneAdjFactor?: number        // direct zone size multiplier (default 1.0)
  leadTimeAdjFactor?: number    // DLT multiplier (default 1.0)
  supplyOffsetDays?: number     // DAF timing offset in days
  // Metadata
  lastComputedAt: string        // ISO datetime of last zone recalculation
}
```

**Resolves**: M1 (NFP requires TOG), M2 (buffer status requires TOG), M9 (zone-fill requires TOR/TOY/TOG)

### G3 — ReplenishmentSignal (NFP-triggered supply order proposal)

```typescript
ReplenishmentSignal {
  id: string
  specId: string
  atLocation?: string
  bufferZoneId: string          // source BufferZone
  onhand: number                // onhandQuantity at signal time
  onorder: number               // sum of open supply Commitments (Commitment-only, not Intents)
  qualifiedDemand: number       // OST-filtered demand due today
  nfp: number                   // = onhand + onorder - qualifiedDemand (CAN BE NEGATIVE)
  priority: number              // = nfp / tog (can exceed 1.0; < 0 = stockout)
  zone: 'red' | 'yellow' | 'green'
  recommendedQty: number        // TOG − NFP, rounded up to MOQ/multiple
  dueDate: string               // ISO date: today + DLT
  status: 'open' | 'approved' | 'rejected'
  approvedCommitmentId?: string // set by promoteToCommitment() on approval
  createdAt: string             // ISO datetime
}
```

**Resolves**: G for "Replenishment recommendation", "TOG − NFP order quantity", "Planning priority %"

### G4 — DemandAdjustmentFactor (DDS&OP planned multipliers)

```typescript
DemandAdjustmentFactor {
  id: string
  specId: string                // ResourceSpecification ID
  type: 'demand' | 'zone' | 'leadTime'
  factor: number                // multiplier (e.g. 1.2 = 20% increase)
  validFrom: string             // ISO date (inclusive)
  validTo: string               // ISO date (inclusive)
  supplyOffsetDays?: number     // for 'demand' type only: offset ADU computation window
  note?: string
}
```

**Links to**: `BufferZone.demandAdjFactor`, `BufferZone.zoneAdjFactor`, `BufferZone.leadTimeAdjFactor`

### Field Extensions to Existing Schemas

| Schema | New Field | Type | Rationale |
|---|---|---|---|
| `ResourceSpecification` | `bufferProfileId?` | `string` (BufferProfile ID) | Links spec to its DDMRP buffer profile; drives zone calculation |
| `ResourceSpecification` | `replenishmentRequired?` | `boolean` | `tag:plan:replenishment-required` trigger for Pass 2 in `planForRegion()` (existing runtime convention; now schema-typed) |
| `ProcessSpecification` | `isDecouplingPoint?` | `boolean` | Design-time marker for strategic buffer placement |
| `ProcessSpecification` | `isControlPoint?` | `boolean` | Design-time marker for pacemaker scheduling |

---

## §6 Priority Implementation Order

### Tier 1 — Data structure (unblocks everything else)

1. `BufferProfile` schema + `ResourceSpecification.bufferProfileId` + `ProcessSpecification.isDecouplingPoint/isControlPoint`
2. `BufferZone` schema

**Why first**: Every DDMRP computation (NFP, replenishment signal, zone-fill, buffer status) requires TOR/TOY/TOG values. Without `BufferZone`, nothing downstream can be computed correctly.

### Tier 2 — Planning cycle enablement

3. `ReplenishmentSignal` schema
4. `DemandAdjustmentFactor` schema
5. `computeNFP()` function — signed NFP (resolves M1, M6)
6. `recipeLeadTime()` function — template DLT (resolves M3)

**Why second**: Once buffer zones exist, the planning cycle can fire: compute NFP → compare to TOY → generate ReplenishmentSignal → approve via `promoteToCommitment()`.

### Tier 3 — Execution alerts (deferred)

7. `qualifyDemand()` — OST spike filter (resolves M7)
8. Buffer health analytics time-series (resolves M10)
9. Scheduling queue / WIP dispatch list
10. Alert engines (on-hand alert threshold, projected on-hand, LTM horizon, mat-sync)
11. `prioritizedShare()` — sequential zone-fill (resolves M9)

**Why deferred**: Tier 3 requires Tier 1+2 to be operational in production. Alert engines also require UI/streaming infrastructure beyond the schema layer.

---

## Appendix — Gap Count Summary

| Component | A | M | G |
|---|---|---|---|
| C1 Strategic Positioning | 2 | 1 | 1 |
| C2 Buffer Profiles & Levels | 5 | 1 | 7 |
| C3 Dynamic Adjustments | 2 | 0 | 5 |
| C4 Supply Order Generation | 14 | 2 | 10 |
| C5 Execution / Alerts | 9 | 1 | 4 |
| Scheduling | 7 | 3 | 5 |
| **Total** | **39** | **8** | **32** |

> Note: some concepts map to the same VF field (e.g. On-Hand appears in both C4 and C5);
> they are counted separately because they represent distinct DDMRP use-cases for the same field.
