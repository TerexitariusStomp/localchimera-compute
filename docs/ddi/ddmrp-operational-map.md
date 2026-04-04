# DDMRP Operational Map

**Reference**: Ptak & Smith, *Demand Driven Material Requirements Planning* (DDI Press, 3rd ed.), Chapters 7–12
**Companion document**: `docs/mrp-drp-ddmrp-modules.md` (broader MRP/DRP/DDMRP module reference)
**Schema**: `docs/ddi/schema.jpg`

---

## 1. Introduction

The **Demand Driven Operating Model (DDOM)** consists of three operational systems:

1. **DDMRP — Supply Order Generation** (Demand Driven Planning, Component 4)
2. **Demand Driven Scheduling** (Decoupled + Control Point Scheduling, Ch 11)
3. **Demand Driven Execution** (Buffer Management, Ch 10)

All three are governed by **DDS&OP** (Demand Driven Sales & Operations Planning), which provides master settings: buffer profiles, ADU data, and planned adjustment factors. DDS&OP replaces the conventional Master Production Schedule (MPS) as the strategic input.

### VF Implementation Substrate

The codebase is organized into four layers:

```
Knowledge → Plan → Observation → Algorithm
```

| Layer | Primary Concern | Key File(s) |
|---|---|---|
| Knowledge | BOM, routing, resource specs | `src/lib/knowledge/recipes.ts` |
| Plan | Supply orders, demand signals, scheduling | `src/lib/planning/` |
| Observation | Actual events, on-hand inventory | `src/lib/observation/observer.ts` |
| Algorithm | Computations: DLT, NFP, cost, trace | `src/lib/algorithms/` |

The canonical VF temporal ladder (`src/lib/schemas.ts`, file header):

```
Intent  →  Commitment  →  EconomicEvent
  ↑ satisfies    ↑ fulfills
```

- **Intent**: unilateral desire/offer/request; provider OR receiver, never both
- **Commitment**: bilateral promise; both provider AND receiver; satisfies an Intent
- **EconomicEvent**: immutable observed fact; fulfills a Commitment OR satisfies an Intent (never both)

All quantities carry a unit via `Measure = { hasNumericalValue: number; hasUnit: string }`.

### Key Quantity Distinction (affects every buffer calculation)

`EconomicResource` carries two quantity fields with different semantics:

| Field | Meaning | Updated by |
|---|---|---|
| `accountingQuantity` | Rights-based balance (who "owns" it) | `produce`, `consume`, `transfer`, `transferAllRights`, `raise`, `lower` |
| `onhandQuantity` | Custody-based balance (who physically has it) | `produce`, `consume`, `pickup`, `dropoff`, `transferCustody`, `transfer` |

**DDMRP buffer status monitoring must use `onhandQuantity`** (physical stock on the shop floor). In-transit stock (shipped but not received) is accounted in `accountingQuantity` but not yet in `onhandQuantity`. PlanNetter uses `accountingQuantity` for netting — see §2.5.

---

## 2. DDMRP — Supply Order Generation

### 2.1 Five Components Overview

| # | Component | Operational role |
|---|---|---|
| C1 | Strategic Inventory Positioning | Decoupling point placement |
| C2 | Buffer Profiles & Levels | Zone sizing (Red/Yellow/Green) |
| C3 | Dynamic Adjustments | ADU/DLT/MOQ-driven recalc + planned factors |
| C4 | Demand Driven Planning / Supply Order Generation | **Primary focus of this section** |
| C5 | Visible & Collaborative Execution | Covered in Section 4 |

### 2.2 Master Settings Feed (DDS&OP → DDMRP)

DDS&OP provides three structured inputs to DDMRP, replacing a conventional MPS:

1. **Buffer Profiles**: groupings by item type (Purchased / Manufactured / Intermediate) × lead time category (Short / Medium / Long → Lead Time Factor, LTF) × variability category (Low / Medium / High → Variability Factor, VF)
2. **Part Demand Data**: planned adjustment factors (DAF etc.) + ADU (past-period / forward-looking / blended)
3. **Part Profile Assignment**: assignment of each replenished part to a buffer profile

**VF mapping:**

| DDS&OP concept | VF schema / code |
|---|---|
| Buffer profile (item type) | `ResourceSpecification.resourceClassifiedAs[]` (taxonomy tag) |
| Buffer profile (LT category) | `RecipeProcess.hasDuration` (`Duration = { hasNumericalValue, hasUnit }`) |
| Buffer profile (variability) | metadata on `ResourceSpecification.note` or `classifiedAs` tag (no dedicated field) |
| Part profile assignment | `RecipeFlow.recipeInputOf` / `recipeOutputOf` linking spec to recipe |
| Independent demand item | `Commitment.independentDemandOf` → Plan ID; `Plan.hasIndependentDemand[]` |
| ADU (past) | `groupEventsByOccurrence()` + `getOccurrenceStatus()` → fulfilled_quantity per day (`src/lib/utils/recurrence.ts`) |
| ADU (recurring demand gaps) | `unfulfilledOccurrences(window, from, to, eventsByOccurrence)` → unfulfilled date gaps |
| ADU (forward) | `materializeOccurrenceDates(window, from, to)` → expected demand dates from `AvailabilityWindow` on Intent/Commitment |

**Gap**: No buffer profile entity; no ADU rolling-average calculator; no planned adjustment factor engine; no `tag:plan:buffer-profile` assignment mechanism.

### 2.3 Buffer Zone Calculation (Component 2)

Four part attributes feed zone sizing:

- **ADU** (Average Daily Usage): rolling calc, past/forward/blended; update frequency affects buffer health
- **DLT** (Decoupled Lead Time): longest cumulative coupled lead time chain between decoupling points
- **MOQ** (Minimum Order Quantity): minimum lot size per supply order
- **Location** (distributed networks): determines transfer buffer needs

**Zone formulas (canonical, Ch 7):**

```
Yellow   = ADU × DLT
Red Base = ADU × DLT × LTF
Red Safety = Red Base × VF
Red      = Red Base + Red Safety

Green    = max(order_cycle × ADU,  DLT × ADU × LTF,  MOQ)

TOR (Top of Red)    = Red
TOY (Top of Yellow) = Red + Yellow
TOG (Top of Green)  = Red + Yellow + Green

Average on-hand target = Red + Green/2   (working capital basis)
```

Min-max variant: only Green + Red zones (no Yellow); same trigger/sizing logic.

**VF mapping:**

| DDMRP concept | VF schema field / function |
|---|---|
| MOQ | `RecipeProcess.minimumBatchQuantity` (`Measure`) |
| DLT source data | `RecipeProcess.hasDuration` (`Duration`) per routing step |
| DLT computation | `criticalPath(planId, planStore, processReg)` (`src/lib/algorithms/critical-path.ts`) — **operates on instantiated Plan Processes**, not RecipeProcess templates; returns `CriticalPathResult.projectDuration` in ms |
| Decoupling point on resource | `EconomicResource.stage` → ProcessSpecification ID (set by `stageEffect: 'update'` on produce/modify/dropoff) |
| Decoupling point filter on BOM flow | `RecipeFlow.stage` → ProcessSpecification ID (filters which inventory stage satisfies this input) |
| Containment guard (netting) | `EconomicResource.containedIn` → resource ID; `netDemand()` skips `containedIn !== undefined` (physically unavailable until `separate` action) |
| Location-aware buffers | `Intent.atLocation` / `Commitment.atLocation` → SpatialThing ID; `netDemand/netSupply/netAvailableQty` accept `atLocation` filter |
| Working capital basis | `rollupStandardCost()` × average on-hand target (`src/lib/algorithms/rollup.ts`) |

**Gap**: No buffer zone calculator; no LTF/VF factor tables; no TOR/TOY/TOG data structure; no ADU module.

### 2.4 Dynamic Adjustments (Component 3)

Two adjustment types:

**1. Recalculated Adjustments**: automatic recomputation whenever ADU, DLT, or MOQ changes.

**2. Planned Adjustment Factors** (set by DDS&OP):
- **DAF** (Demand Adjustment Factor): multiplier on ADU for known demand patterns
- **Zone Adjustment Factor**: direct multiplier on zone size
- **Lead Time Adjustment Factor**: multiplier on DLT for supply risk
- **Supply Offset**: timing offset for DAF application (prevents premature buffer inflation)

DAF use cases: seasonality (recurring), product introduction (ramp-up), product deletion (ramp-down), product transition (simultaneous ramp-up/down).

**VF mapping:**

| DAF use case | VF support |
|---|---|
| Seasonal/recurring demand | `AvailabilityWindow` on `Intent`/`Commitment` (`month_schedules`, `week_schedules`, `day_schedules`) — `dateMatchesWindow()` (`src/lib/utils/recurrence.ts`) |
| Ramp-up / ramp-down | `Intent.hasBeginning` / `Intent.hasEnd` + `Intent.availableQuantity` decremented by `promoteToCommitment()` |
| Forward demand window | `TemporalExpression` (`src/lib/utils/time.ts`) on Intent/Commitment/EconomicResource |

**Gap**: No DAF engine; no zone/lead-time adjustment factor module; no recalculated adjustment trigger; no supply offset logic.

### 2.5 Net Flow Position & Supply Order Generation (Component 4)

**Core planning equation:**

```
NFP (Net Flow Position) = On-Hand + On-Order − Qualified Demand

Qualified Demand = orders due today
                 + demand spikes within OST horizon (OST = DLT + 1 day)
  where spike threshold = configurable % of red zone (TOR)
```

**Supply order logic:**

```
if NFP ≤ TOY:
    order_qty = TOG − NFP          (replenish to top of green)
    due_date  = today + DLT
    if order_qty < MOQ: order_qty = MOQ
    if using multiples: round up to nearest multiple (OTOG%)
```

**Planning Priority** = NFP / TOG expressed as %:
- Red zone: priority% < TOR/TOG
- Yellow zone: TOR/TOG ≤ priority% < TOY/TOG
- Green zone: priority% ≥ TOY/TOG

**Planning screen columns**: Part#, Priority%, On-Hand, On-Order, Qualified Demand, NFP, Order Recommendation, Request Date, TOR, TOY, TOG, Lead Time.

**Prioritized Share** (scarce supply across locations):
1. Fill all locations to TOR first
2. Then fill all to TOY
3. Distribute remainder proportionally within green zone

**VF mapping — NFP decomposition:**

| NFP term | VF source | Field / method |
|---|---|---|
| On-Hand (physical) | `EconomicResource.onhandQuantity` | `Observer.conformingResources(specId)` filtered by stage/state/location |
| On-Hand (rights) | `EconomicResource.accountingQuantity` | Used by `PlanNetter.netAvailableQty()` — note: rights-based, not physical |
| On-Order (MO output) | `Commitment.outputOf` → Process ID, `action: 'produce'` | `PlanStore.allCommitments()` where `outputOf` is set |
| On-Order (PO receipt) | `Commitment.outputOf`, `action: 'transferAllRights'` or `'transfer'` | Same query; `transferAllRights` = accounting receipt; `transfer` = full receipt |
| On-Order (TO receipt) | `Commitment.outputOf`, `action: 'transferCustody'` or `'transfer'` | `transferCustody` = custody receipt; `transfer` = full receipt |
| Qualified Demand | `Intent.inputOf` / `Commitment.inputOf` → Process ID, consuming actions | `PlanNetter.netSupply()` deducts these; skips `NON_CONSUMING_ACTIONS = {use, work, cite, deliverService}` |
| NFP approximation | `PlanNetter.netAvailableQty(specId, opts?)` | Returns `Math.max(0, accountingQty + unallocated_outputs − unallocated_consumptions)` — **clamps at 0; cannot go negative unlike true NFP** |
| Independent demand (C4 input) | `Commitment.independentDemandOf` → Plan ID | `Plan.hasIndependentDemand[]` = Commitment/Intent IDs that are top-level deliverables |
| ATP check (order approval) | `PlanStore.promoteToCommitment(intentId, counterparty)` | Validates `Intent.minimumQuantity`; decrements `Intent.availableQuantity` — this is the ATP mechanism |

**VF mapping — planning orchestration:**

| DDMRP function | VF code |
|---|---|
| Planning orchestrator | `planForRegion()` (`src/lib/planning/plan-for-region.ts`) — H3-cell based, 2-pass, with backtracking and conflict detection |
| Demand classification | `DemandSlotClass`: `locally-satisfiable` / `transport-candidate` / `producible-with-imports` / `external-dependency` |
| Pass 2 trigger | `tag:plan:replenishment-required` on `ResourceSpecification` triggers replenishment explosion |
| Deficit / surplus signals | `DeficitSignal.source: 'unmet_demand' | 'metabolic_debt'`; `SurplusSignal` |
| Unresolvable replenishment | `MetabolicDebt` = no recipe exists for the spec (orphan demand) |
| Backtracking | `PlanNetter.retract(result)` = `releaseClaimsForPlan()` + `removeRecordsForPlan()` + `pruneStale()` |
| Conflict detection | `detectConflicts()` in `planForRegion()` — inventory-overclaim + capacity-contention |
| BOM explosion (backward) | `dependentDemand(specId, qty, neededBy, ...)` (`src/lib/algorithms/dependent-demand.ts`) — BFS backward; creates `purchaseIntents` when no recipe found |
| Supply explosion (forward) | `dependentSupply()` (`src/lib/algorithms/dependent-supply.ts`) |
| External sourcing | `DependentDemandResult.purchaseIntents[]` — Intents with no recipe; published via `Proposal` for supplier matching |
| Supplier matching | `Proposal.publishes[]` → Intent IDs; `purpose: 'offer'|'request'`; `proposedTo[]` → Agent IDs |
| Supply agreement | `Agreement.stipulates[]` → primary Commitment IDs; `stipulatesReciprocal[]` → reciprocal Commitment IDs; `Commitment.clauseOf` → Agreement ID |
| Prioritized share | `ScenarioIndex` / `paretoFront()` / `mergeFrontier()` (`src/lib/utils/space-time-scenario.ts`) — content-addressed scenarios by H3 cell × ProcessSpec |
| Plan merge | `PlanStore.merge(sub)` — imports sub-PlanStore records (merge planner path in `planForRegion`) |

**Gaps**: No spike qualification engine (OST horizon + spike threshold); no continuous NFP calculator (with negative values); no planning screen/dashboard; no OTOG% rounding; no min-max variant; `netAvailableQty()` uses `accountingQuantity` not `onhandQuantity` so physical buffer status requires direct Observer query.

### 2.6 Signal Integrity Tracking (Ch 12)

Monitor whether DDMRP supply order signals are conveyed on time and in correct quantity:

- **Recommendation column**: quantity to restore NFP to TOG (shown when NFP ≤ TOY)
- **Actual column**: approved supply order quantity on that date
- Discrepancies indicate planning compliance failures

**VF mapping:**

| Signal integrity concept | VF schema / observer |
|---|---|
| Recommendation | `Intent.resourceQuantity` (before approval) / `Commitment.resourceQuantity` (after approval) |
| Actual receipt | `EconomicEvent.resourceQuantity` where `event.fulfills` → CommitmentID |
| Fulfillment tracking | `Observer.FulfillmentState`: `totalCommitted`, `totalFulfilled`, `fulfillingEvents[]`, `finished`, `overFulfilled` |
| Over-delivery detection | `Observer` emits `over_fulfilled` event when event quantity exceeds committed quantity |
| Satisfaction tracking | `Observer.SatisfactionState`: `totalDesired`, `totalSatisfied`, `satisfyingEvents[]`, `satisfyingCommitments[]` |
| Plan vs. actual cost | `costVariance()` (`src/lib/algorithms/rollup.ts`) |
| Correction events | `EconomicEvent.corrects` → EconomicEvent ID (immutable record amendment) |

`FulfillmentState` and `SatisfactionState` are the raw data for a signal integrity report — they exist but are not yet surfaced as a DDMRP recommendation-vs-actual dashboard.

**Gap**: No signal integrity report; no recommendation-vs-actual tracking dashboard; no timing compliance alert.

---

## 3. Demand Driven Scheduling

### 3.1 Decoupled Schedules (Impact 1)

Decoupling at the product structure level also decouples at the routing level:

- One large scheduling puzzle → multiple smaller, independent scheduling "legs"
- Each leg = sub-sequence of `RecipeProcess` steps between two decoupling points
- Changes in one leg are isolated from other legs (no nervousness propagation)
- Shared resources between legs are deconflicted by NFP-based priority (see 3.2)

**VF mapping:**

| Scheduling concept | VF code |
|---|---|
| Routing chain | `RecipeStore.getProcessChain()` (`src/lib/knowledge/recipes.ts`) — ordered RecipeProcess sequence |
| Decoupling point on resource | `EconomicResource.stage` → ProcessSpecification ID |
| Decoupling point filter on flow | `RecipeFlow.stage` → ProcessSpecification ID (filters which inventory stage this input consumes) |
| DLT per leg (instantiated plan) | `criticalPath(planId, planStore, processReg)` (`src/lib/algorithms/critical-path.ts`) — forward/backward pass on Plan Processes; duration from `Process.hasBeginning`/`hasEnd`; falls back to `defaultDurationMs` |
| DLT per leg (template) | Sum of `RecipeProcess.hasDuration.hasNumericalValue` along routing leg (no function; must be computed manually) |
| Work center load | `ScheduleBook.committedEffortOn(agentId, dt)` (`src/lib/planning/schedule-book.ts`) — **sums only work Commitments (not Intents)** on that date; Intents are unconfirmed offers, not bookings |
| Agent working hours | `Agent.availability_window` (`TemporalExpression`) — checked by `isWithinTemporalExpression()` |

### 3.2 Visible and Priority-Based Scheduling Sequencing (Impact 2)

Planning priority (NFP/TOG %) drives scheduling sequence across shared resources:

- **Lowest priority %** → scheduled first (most urgent buffer, deepest in red)
- All supply orders for manufactured items carry their planning priority
- Shared resources scheduled by ordering MOs by priority %
- Allergen/regulatory sequence constraints layer on top: sort by constraint group first, then priority % within group

**VF mapping:**

| Scheduling concept | VF code |
|---|---|
| Time-slot conflict detection | `ScheduleBook.hasUseConflict(resourceId, from, to)` — checks half-open [from, to) window against existing `use` Commitments/Intents |
| Resource availability | `ScheduleBook.isResourceAvailable(resourceId, dt)` — checks `EconomicResource.availability_window` via `isWithinTemporalExpression()` |
| Use-slot booking (within session) | `PlanNetter.netUse(resourceId, from, to, planId?)` — within-session reservation + pre-existing PlanStore conflict check |
| Planning priority source | NFP/TOG% derived from `PlanNetter.netAvailableQty()` (supply side) + `Observer.conformingResources(specId).onhandQuantity` (physical buffer) |
| Schedule block view | `ScheduleBook.blocksFor(entityId, opts?)` — unified `ScheduleBlock` over Intents + Commitments for an agent or resource |

**Gap**: No scheduling queue / priority-sorted dispatch module; no composite priority sort (sequence group + NFP%).

### 3.3 WIP Priority Management (Dispatch List)

After schedule release, on-hand buffer status governs WIP sequencing at the work center level:

- **Dispatch list** = released MOs ordered by current on-hand buffer status %
- On-hand buffer status (%) = `onhandQuantity` / TOG × 100
- Sequence can be altered in real time based on live buffer status changes
- Visual: MO# | Item# | Buffer Status (color + %)

**VF mapping:**

| Concept | VF code |
|---|---|
| Live on-hand | `Observer.conformingResources(specId)` → `EconomicResource.onhandQuantity` (custody-based, physical) |
| MO completion event | `EconomicEvent.fulfills` → CommitmentID; `EconomicEvent.outputOf` → ProcessID |
| Process completion signal | `Observer` emits `process_completed` event when all expected output events are recorded for a Process |
| Released MO schedule | Open Commitments with `action: 'produce'` in PlanStore; `Commitment.plannedWithin` → Plan ID |
| Lot tracking per MO | `EconomicResource.lot` (`BatchLotRecord`) + `EconomicResource.trackingIdentifier` |

**Gap**: No dispatch list / WIP priority dashboard; no buffer status % display per MO; no real-time buffer resequencing.

### 3.4 Finite Scheduling / Drum Scheduling

Manufactured item buffers = strategic storage tanks of capacity and materials:

- Buffer quantities translate to capacity time (pieces × minutes/piece per work center)
- DDMRP buffers function as "drums" (Goldratt): set system pace, replenish to TOG not beyond
- For most environments with manufactured item buffers: DDMRP is sufficient as a finite scheduling substitute
- TOG × minutes/piece = finite capacity ceiling per work center per replenishment cycle

See also: `docs/ddi/drum-scheduling.jpg`, `docs/ddi/capacity-buffers.jpg`, `docs/ddi/capacity-buffer-requirements.jpg`

**VF mapping:**

| Concept | VF code |
|---|---|
| Cycle time per step | `RecipeProcess.hasDuration` (`Duration = { hasNumericalValue, hasUnit }`) |
| Work center load (actual) | `ScheduleBook.committedEffortOn(agentId, dt)` — `effortQuantity` sum of work Commitments |
| Work Commitment | `Commitment.action: 'work'`; `Commitment.effortQuantity` (`Measure`) |
| TOG → minutes translation | (TOG quantity) × `RecipeProcess.hasDuration` = total capacity consumed (no function; must be computed) |
| Agent capacity ceiling | `Agent.availability_window` → working hours; `ScheduleBook.isResourceAvailable()` |

**Gap**: No capacity-in-time dashboard; no drum capacity ceiling enforcement; no TOG-to-minutes translation function.

### 3.5 Control Point Scheduling (When More Is Needed)

Three circumstances requiring detailed control point scheduling (Ch 11):

1. More detailed scheduling improves LT/variability control feeding into a stock position
2. No ability to decouple before finished level (configure-to-order environments)
3. Shared resources between make-to-stock and make-to-order items (mixed-mode)

**Control point definition (APICS)**: "Strategic locations in the logical product structure for a product or family that simplify planning, scheduling, and control. Includes gating operations, convergent points, divergent points, constraints, and shipping points."

Control points do **not** decouple; they transfer and amplify control within an area. Placed between decoupling points or between decoupling points and customers.

See also: `docs/ddi/control-points.jpg`, `docs/ddi/control-point-placement-criteria.jpg`

Full control point scheduling: *Demand Driven Performance: Using Smart Metrics* (Debra Smith, Chad Smith).

**VF mapping:**

| Concept | VF code |
|---|---|
| Control point type | `ProcessSpecification` — can serve as a control point marker via `classifiedAs` tag |
| Scheduling substrate | `ScheduleBook` — conflict detection, availability windows, effort booking |
| Routing between control points | `RecipeStore.getProcessChain()` — ordered RecipeProcess chain between two ProcessSpecifications |
| Gating / convergent point | `Process.basedOn` → ProcessSpecification ID — can be tagged as control point type |
| CTO / MTO order identity | `Commitment.independentDemandOf` → Plan ID distinguishes customer-order-specific demand |

**Gap**: No control point determination module; no finite control point scheduling engine; no mixed-mode (MTS/MTO) scheduler.

### 3.6 Additional Sequence Constraints

External sequence constraints (allergen order, regulatory compliance, setup sequence) layer on top of planning priority:

- Assign sequence number to each item (e.g., allergen group 1 before group 2)
- Sort planning queue by sequence number first, then planning priority % within group

**VF mapping:**
- `RecipeProcess.processClassifiedAs[]` or `ResourceSpecification.resourceClassifiedAs[]` could carry sequence group taxonomy tags
- **Gap**: No sequence constraint scheduler; no composite priority engine (sequence group + NFP%).

---

## 4. Demand Driven Execution (Buffer Management)

### 4.1 Planning vs. Execution Distinction

Planning ends when a supply order recommendation is approved → becomes an open PO/MO/TO.
**Execution** = managing open supply orders to protect buffer integrity throughout their lead time.

**VF mapping — supply order type encoding:**

| Order type | VF action | Schema fields |
|---|---|---|
| MO (Manufacturing Order) | `produce` | `Commitment.outputOf` → Process ID; `Commitment.action: 'produce'` |
| PO (Purchase Order) | `transferAllRights` (rights transfer) or `transfer` (full) | `Commitment.clauseOf` → Agreement ID (blanket PO) |
| TO (Transfer Order) | `transferCustody` (custody) or `transfer` (full) or `move` (same-agent) | `Commitment.atLocation` / `toLocation` |
| Exchange agreement | `Agreement.stipulates[]` → primary Commitment IDs; `Agreement.stipulatesReciprocal[]` → reciprocal | Instantiated from `RecipeExchange` via `planForRegion` |
| Claim (buyer-initiated) | `Claim.triggeredBy` → EconomicEvent ID | Auto-created after receipt event; tracks supplier obligation |

**VF mapping — lifecycle fields:**

| Concept | VF schema |
|---|---|
| Independent demand deliverable | `Commitment.independentDemandOf` → Plan ID; `Plan.hasIndependentDemand[]` |
| Order approved (bilateral) | `Commitment` (both `provider` and `receiver` set) |
| Order fulfillment event | `EconomicEvent.fulfills` → CommitmentID |
| Intent fulfillment (no Commitment) | `EconomicEvent.satisfies` → IntentID |
| Plan scope | `Plan.refinementOf` → Scenario ID; `Process.nestedIn` → Scenario ID |

### 4.2 Four DDMRP Execution Alerts (Figure 10-1)

Alerts divide into two categories by point type:

---

#### Buffer Status Alerts (independent / decoupled points)

**(a) Current On-Hand Alert**

- **Trigger**: on-hand inventory penetrates a configurable alert level (e.g., 50% of TOR)
- Shows which buffers are being consumed right now
- Color-coded: alert level penetration → dark yellow; below TOR → red
- Purpose: prompt immediate action to protect physical buffer integrity

**VF mapping:**

| Concept | VF code |
|---|---|
| Physical on-hand | `EconomicResource.onhandQuantity` (custody-based) — **use this, not `accountingQuantity`** |
| On-hand per spec | `Observer.conformingResources(specId)` → `EconomicResource[]` filtered by stage/state/location |
| Stage-filtered on-hand | Filter by `EconomicResource.stage === decouplingPointSpecId` |
| Containment guard | Skip `EconomicResource.containedIn !== undefined` (physically locked until `separate`) |
| Location-specific on-hand | Filter by `EconomicResource.currentLocation === SpatialThingID` |

**Gap**: No continuous on-hand monitoring loop; no configurable threshold alert engine; no TOR/TOY/TOG data structures to compare against.

---

**(b) Projected On-Hand Alert**

Projects on-hand forward one DLT period:

```
OH_projected = OH_current
             − max(ADU, known_demand_allocations_per_day) × DLT
             + expected_supply_receipts_within_DLT
```

- **Dark red** = projected stockout (negative projected on-hand)
- Color-coded by buffer zone: green / yellow / red / dark-red (stockout)
- Day-by-day table: daily OH, expected receipts, daily demand, projected OH

**VF mapping:**

| Concept | VF code |
|---|---|
| Current OH (physical) | `Observer.conformingResources(specId)` → `onhandQuantity` |
| Expected receipts within DLT | `PlanStore.allCommitments()` where `outputOf` set + `due` ≤ (today + DLT); actions: `produce`, `transfer`, `transferCustody` |
| Known demand allocations | `PlanStore.allCommitments()` / `allIntents()` where `inputOf` set + `due` within DLT; skip `NON_CONSUMING_ACTIONS` |
| Net available approximation | `PlanNetter.netAvailableQty(specId, { asOf: today + DLT })` — **uses `accountingQuantity`; clamps at 0** — not suitable for stockout detection |
| DLT projection horizon | `CriticalPathResult.projectDuration` from `criticalPath()` |
| Temporal guard on flows | `PlanNetter.netDemand/netSupply` `neededBy` parameter; `netAvailableQty` `asOf` parameter |

**Gap**: No projected on-hand calculator using `onhandQuantity`; no day-by-day projection engine; no dark-red stockout alert; `netAvailableQty()` cannot detect negative NFP (clamps to 0).

---

#### Synchronization Alerts (dependent / non-decoupled points)

**(c) Material Synchronization Alert**

- For non-decoupled items: detects supply shortfall vs. known demand allocations
- Screen columns: MO#, Part#, Release Date, Qty, Shortage, Parent Buffer Status
- **Parent buffer status** context: conveys urgency relative to parent decoupling point zone
- Purpose: identify synchronization failures before they become buffer violations

See also: `docs/ddi/sync-material-release.jpg`

**VF mapping:**

| Concept | VF code |
|---|---|
| Shortfall calculation | `PlanNetter.netDemand(specId, qty, opts?)` — Step 1: `Observer` inventory (`accountingQuantity`, containment guard, location guard, stage/state guard); Step 2: unallocated output `Intent` (outputOf set, temporal + location guard); Step 3: unallocated output `Commitment` (same guards) |
| Supply netting | `PlanNetter.netSupply(specId, qty, availableFrom?, atLocation?)` — deducts consumption `Intent`/`Commitment` (inputOf set); skips `NON_CONSUMING_ACTIONS` |
| Soft allocation tracking | `PlanNetter.allocated: Set<string>` — shared across calls; prevents double-counting |
| MO tracking | `Commitment.outputOf` → Process ID; `EconomicEvent.fulfills` → CommitmentID |
| Parent buffer status | `Observer.conformingResources(parentSpecId)` → `onhandQuantity` at parent decoupling point |

**Gap**: No material synchronization alert engine; no shortfall report; no parent buffer status context display.

---

**(d) Lead Time Alert (LTM — Lead Time Managed)**

- Tracks open supply orders through an **alert horizon** = last third of their lead time
- Alert horizon subdivided into G/Y/R sub-zones (green: early; yellow: mid; red: near-due)
- Purpose: identify orders at risk of not arriving on time; prompt expediting
- Columns: Order#, Part#, Due Date, Status, days remaining, sub-zone color

See also: `docs/ddi/yet-to-be-recieved.jpg`

**VF mapping:**

| Concept | VF code |
|---|---|
| Open MOs | `PlanStore.allCommitments()` where `action: 'produce'` + `finished: false` |
| Open POs | `PlanStore.allCommitments()` where `action: 'transferAllRights'` or `'transfer'` + `finished: false` |
| Open TOs | `PlanStore.allCommitments()` where `action: 'transferCustody'` or `'transfer'` or `'move'` + `finished: false` |
| Due date | `Commitment.due` (ISO datetime) |
| Days remaining | `(new Date(commitment.due).getTime() − Date.now()) / 86_400_000` |
| Capacity delay detection | `ScheduleBook.isResourceAvailable(resourceId, dt)` — checks `EconomicResource.availability_window` |
| Receipt claim | `Claim.triggeredBy` → EconomicEvent ID — auto-created after partial receipt; tracks remaining supplier obligation |
| Fulfillment state | `Observer.FulfillmentState.finished` — true when `totalFulfilled >= totalCommitted` |

**Gap**: No LTM tracking engine; no alert horizon computation; no G/Y/R sub-zone classification; no expedite alert.

### 4.3 Order Activity Summary Screen

Unified view of all open supply orders (PO + MO + TO) with buffer status context:

- **Columns**: Order#, Part#, Order Type, Status, Release Date, Due Date, Qty, Buffer Status %
- Enables execution management across all order types from single dashboard

**VF mapping:**
- `VfQueries` (`src/lib/query.ts`) — unified query API across Commitments/Intents
- `Observer.conformingResources(specId)` → `onhandQuantity` for buffer status per spec
- `PlanStore.commitmentsForPlan(planId)` — all Commitments in a plan (one plan per operational horizon)
- `Observer.FulfillmentState` — per-commitment fulfillment progress
- **Gap**: No unified execution dashboard; no buffer status % column; no order type classification display.

### 4.4 Track & Trace for Execution Visibility

Fully implemented in `src/lib/algorithms/track-trace.ts`:

- `trace()` — backwards provenance: where did this resource come from?
- `track()` — forwards destination: where is this resource going?

Breadcrumb mechanism (set in `Observer.record()`):
```
when event.resourceInventoriedAs is set:
    event.previousEvent = resource.previousEvent   // chain event
    resource.previousEvent = event.id              // advance resource pointer
```

Both `EconomicResource.previousEvent` and `EconomicEvent.previousEvent` are chained independently. Lot/batch details accessible via `EconomicResource.lot` (`BatchLotRecord.batchLotCode`, `expirationDate`) and `EconomicResource.trackingIdentifier`.

Maps directly to DDMRP C5 (Visible & Collaborative Execution). **Fully implemented.**

### 4.5 Plan vs. Actual Variance

- `rollupActualCost()` / `costVariance()` — standard vs. actual cost variance; `src/lib/algorithms/rollup.ts`
- `EconomicEvent.corrects` → previous event ID — immutable correction mechanism for mis-records
- `EconomicEvent.realizationOf` → Agreement ID — links execution event to supply agreement
- `EconomicEvent.settles` → Claim ID — links payment/receipt event to outstanding claim
- **Gap**: No buffer health analytics; no on-hand distribution vs. TOR/TOY/TOG over time; no flow report.

---

## 5. Cross-Cutting VF Schema Anatomy

Key schema fields for DDMRP implementation, grouped by DDMRP concern:

### 5.1 Buffer Position

| Field | Schema | DDMRP meaning |
|---|---|---|
| `onhandQuantity` | `EconomicResource` | Physical buffer level (custody-based) — use for buffer status % |
| `accountingQuantity` | `EconomicResource` | Rights-based balance — used by `PlanNetter`; includes in-transit |
| `stage` | `EconomicResource` | Decoupling point ID (ProcessSpecification) — identifies which buffer this stock belongs to |
| `containedIn` | `EconomicResource` | Containment guard — stock locked until `separate`; excluded from netting |
| `currentLocation` | `EconomicResource` | Physical location for distributed buffer queries |
| `lot` | `EconomicResource` | `BatchLotRecord` — batch/lot identity for execution visibility |

### 5.2 Supply Orders

| Field | Schema | DDMRP meaning |
|---|---|---|
| `action: 'produce'` | `Commitment` | MO (Manufacturing Order) |
| `action: 'transferAllRights'` | `Commitment` | PO receipt (rights transfer only — in transit) |
| `action: 'transfer'` | `Commitment` | PO or TO receipt (full rights + custody) |
| `action: 'transferCustody'` | `Commitment` | TO receipt (custody transfer only) |
| `outputOf` | `Commitment` / `Intent` | Output of scheduled Process — marks as on-order supply |
| `inputOf` | `Commitment` / `Intent` | Input to scheduled Process — marks as qualified demand |
| `due` | `Commitment` | Required completion date — used for LTM alert |
| `clauseOf` | `Commitment` | Agreement ID — groups into blanket PO |
| `independentDemandOf` | `Commitment` | Plan ID — marks as top-level deliverable (C4 independent demand) |
| `satisfies` | `Commitment` | Intent ID — ATP chain |
| `provider` / `receiver` | `Commitment` | Both required for bilateral supply order |

### 5.3 Demand Signals

| Field | Schema | DDMRP meaning |
|---|---|---|
| `action: 'consume'` | `Intent` / `Commitment` (inputOf set) | Material consumption demand |
| `resourceConformsTo` | `Intent` / `Commitment` | ResourceSpecification ID — what is demanded |
| `resourceQuantity` | `Intent` / `Commitment` | Quantity demanded (with unit) |
| `availableQuantity` | `Intent` | Remaining ATP capacity; decremented by `promoteToCommitment()` |
| `minimumQuantity` | `Intent` | MOQ enforcement on the demand side |
| `availability_window` | `Intent` / `Commitment` | Recurring demand pattern (`AvailabilityWindow` or `SpecificDateWindow`) |
| `provider` only | `Intent` | Offer (supply intent) |
| `receiver` only | `Intent` | Request (demand intent, replenishment signal) |

### 5.4 Execution Tracking

| Field | Schema | DDMRP meaning |
|---|---|---|
| `fulfills` | `EconomicEvent` | CommitmentID — execution record for a supply order |
| `satisfies` | `EconomicEvent` | IntentID — direct fulfillment (no Commitment) |
| `corrects` | `EconomicEvent` | Previous event ID — correction/adjustment |
| `realizationOf` | `EconomicEvent` | Agreement ID — links receipt to purchase agreement |
| `settles` | `EconomicEvent` | Claim ID — links payment to outstanding claim |
| `triggeredBy` | `Claim` | EconomicEvent ID — auto-created claim after triggering event |
| `previousEvent` | `EconomicResource` / `EconomicEvent` | Track/trace breadcrumb chain |

---

## 6. Cross-Cutting VF Modules

| Module | File | DDMRP Role |
|---|---|---|
| Observer (stockbook) | `src/lib/observation/observer.ts` | On-hand buffer status; FulfillmentState; SatisfactionState; ClaimState; process_completed events |
| PlanNetter | `src/lib/planning/netting.ts` | netDemand/netSupply/netAvailableQty (accountingQty); netUse (time slots); fork/retract (backtracking) |
| PlanStore | `src/lib/planning/planning.ts` | Commitments (supply orders); Intents (demand signals); promoteToCommitment (ATP); merge/retract |
| VfQueries | `src/lib/query.ts` | Unified query API for all VF entities |
| Critical Path | `src/lib/algorithms/critical-path.ts` | DLT (instantiated Plan Processes); float/slack per process |
| planForRegion | `src/lib/planning/plan-for-region.ts` | H3-cell DDMRP planning cycle; 2-pass; DemandSlotClass; backtracking; conflict detection |
| ScenarioIndex | `src/lib/utils/space-time-scenario.ts` | Content-addressed scenarios (H3 × ProcessSpec); paretoFront; mergeFrontier; prioritized share |
| ScheduleBook | `src/lib/planning/schedule-book.ts` | blocksFor; committedEffortOn (work Commitments only); hasUseConflict [from,to); isResourceAvailable |
| dependentDemand | `src/lib/algorithms/dependent-demand.ts` | BFS backward BOM explosion; purchaseIntents; SNLT ranking |
| dependentSupply | `src/lib/algorithms/dependent-supply.ts` | Forward supply explosion (Mode C) |
| RecipeStore | `src/lib/knowledge/recipes.ts` | BOM/routing (Knowledge layer); getProcessChain |
| Recurrence Utils | `src/lib/utils/recurrence.ts` | OccurrenceStatus; groupEventsByOccurrence; unfulfilledOccurrences; materializeOccurrenceDates; dateMatchesWindow |
| Track & Trace | `src/lib/algorithms/track-trace.ts` | trace() / track() — previousEvent breadcrumb chain |
| Cost Rollup | `src/lib/algorithms/rollup.ts` | rollupStandardCost; rollupActualCost; costVariance |
| Resource Flows | `src/lib/algorithms/resource-flows.ts` | Inventory / cash flow timeline |
| Temporal Utils | `src/lib/utils/time.ts` | TemporalExpression; AvailabilityWindow; isWithinTemporalExpression |
| Space-Time Keys | `src/lib/utils/space-time-keys.ts` | spaceTimeSig; calendarComponents; VF space-time bridges |
| Indexes | `src/lib/indexes/` | Fast lookups: agents, intents, commitments, events, resources, independent-demand |

---

## 7. Gap Summary

| Gap Module | System | Description |
|---|---|---|
| ADU Tracker | Planning | Rolling avg daily usage from `groupEventsByOccurrence` + `getOccurrenceStatus`; past/forward/blended; frequency update |
| Buffer Zone Calculator | Planning | Green/Yellow/Red from ADU × DLT × LTF/VF (using `RecipeProcess.hasDuration`); TOR/TOY/TOG data structure |
| Buffer Profile Registry | Planning | `ResourceSpecification` type × LTF × VF factor tables; part-to-profile assignment |
| Dynamic Adjustment Engine | Planning | Recalculated adjustments + DAF/Zone AF/Lead Time AF; supply offset logic |
| Spike Qualification Engine | Planning | OST horizon (DLT + 1 day), spike threshold (% of TOR), qualified demand filter from `inputOf` Commitments |
| NFP Calculator | Planning | True NFP = `onhandQuantity` + on-order `outputOf` Commitments − qualified `inputOf` Commitments; **allows negative values** (unlike `netAvailableQty`) |
| Planning Screen / Dashboard | Planning | Priority-sorted queue with zone-colored NFP%; columns: Part#, Priority%, OH, OO, QD, NFP, Recommendation, TOR, TOY, TOG |
| Signal Integrity Report | Planning | DDMRP recommendation vs. actual from `FulfillmentState`; timing + quantity compliance; `over_fulfilled` tracking |
| Scheduling Queue / Dispatch | Scheduling | Priority-sorted MO list by NFP%; sequence constraint layering by `processClassifiedAs` group |
| WIP Priority Dashboard | Scheduling | Released MO dispatch list by live `onhandQuantity`/TOG%; `process_completed` event-driven refresh |
| Capacity-Time Translation | Scheduling | (TOG qty) × `RecipeProcess.hasDuration` → work center minutes; drum ceiling enforcement |
| Control Point Scheduler | Scheduling | Control point determination via `ProcessSpecification.classifiedAs`; finite capacity scheduling; MTS/MTO mixed-mode |
| Current On-Hand Alert | Execution | `onhandQuantity` vs. (TOR × alert_threshold); color-coded; containment guard applied |
| Projected On-Hand Monitor | Execution | Day-by-day OH projection over DLT using `onhandQuantity` + `outputOf` receipts − `inputOf` demand |
| Material Synchronization Alert | Execution | `netDemand()` shortfall for non-decoupled items; parent `onhandQuantity` vs. TOR/TOY |
| Lead Time Alert (LTM) | Execution | `Commitment.due` vs. today; alert horizon = last-third of DLT; G/Y/R sub-zones; `Claim` for partial receipts |
| Order Activity Dashboard | Execution | Unified PO/MO/TO view from `PlanStore` with `FulfillmentState` per line and `onhandQuantity`/TOG% |
| Buffer Health Analytics | All | `onhandQuantity` distribution vs. TOR/TOY/TOG over time; flow report via `resource-flows.ts` |

---

## 8. Architecture: DDMRP in the VF Four-Layer Model

```
┌──────────────────────────────────────────────────────────────────┐
│  DDS&OP MASTER SETTINGS (external governance)                    │
│  Buffer Profiles (ResourceSpecification.classifiedAs × LTF × VF)│
│  ADU + Planned Adjustment Factors (DAF, Zone AF, LT AF)          │
│  Part Profile Assignment (Recipe → ResourceSpecification)        │
│  Plan.hasIndependentDemand[] — top-level deliverables            │
└───────────────────────────┬──────────────────────────────────────┘
                            │ configure
┌───────────────────────────▼──────────────────────────────────────┐
│  KNOWLEDGE LAYER                                                 │
│  Recipe, RecipeProcess.hasDuration (Duration), RecipeFlow        │
│  RecipeProcess.minimumBatchQuantity (MOQ — Measure)              │
│  RecipeFlow.stage → ProcessSpecification ID (decoupling filter)  │
│  RecipeExchange → Agreement + reciprocal Commitment template     │
│  ResourceSpecification.resourceClassifiedAs[] (buffer type tags) │
└───────────────────────────┬──────────────────────────────────────┘
                            │ instantiate / explode
┌───────────────────────────▼──────────────────────────────────────┐
│  PLAN LAYER — Supply Order Generation                            │
│  Plan: hasIndependentDemand[], refinementOf → Scenario           │
│  Commitment (MO/PO/TO): outputOf, inputOf, due, clauseOf,        │
│    independentDemandOf, satisfies, action                        │
│  Intent: outputOf, inputOf, availableQuantity, minimumQuantity,  │
│    availability_window, provider XOR receiver                    │
│  PlanNetter: netDemand/netSupply/netAvailableQty (accountingQty) │
│    netUse [from,to), fork(), retract() — soft allocation         │
│  promoteToCommitment() — ATP: minQty + availQty validation       │
│  Agreement: stipulates[] + stipulatesReciprocal[] (exchange)     │
│  Proposal: publishes[] → Intents, purpose: offer|request         │
│  Claim: triggeredBy → EconomicEvent (auto receipt claim)         │
│  ScheduleBook: committedEffortOn (work Commitments only),        │
│    hasUseConflict [from,to), isResourceAvailable                 │
│  planForRegion(): H3-cell, 2-pass, DemandSlotClass, backtrack    │
│  ScenarioIndex / paretoFront() / mergeFrontier()                 │
│  [GAP: buffer zone calc, true NFP engine, planning screen]       │
└───────────────────────────┬──────────────────────────────────────┘
                            │ fulfill / satisfy
┌───────────────────────────▼──────────────────────────────────────┐
│  OBSERVATION LAYER — Execution                                   │
│  EconomicResource: onhandQuantity (custody, physical buffer),    │
│    accountingQuantity (rights), stage (decoupling point),        │
│    containedIn (containment guard), lot, previousEvent           │
│  Observer.conformingResources(specId) — buffer status query      │
│  Observer.FulfillmentState: totalCommitted vs totalFulfilled     │
│  Observer.SatisfactionState: totalDesired vs totalSatisfied      │
│  Observer emits: fulfilled, over_fulfilled, satisfied,           │
│    claim_settled, process_completed                              │
│  EconomicEvent: fulfills → Commitment, satisfies → Intent,       │
│    corrects (correction), realizationOf → Agreement,             │
│    settles → Claim, previousEvent (trace breadcrumb)             │
│  [GAP: on-hand alert, projected OH, LTM, mat-sync alert]         │
└───────────────────────────┬──────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────┐
│  ALGORITHM LAYER                                                 │
│  criticalPath() — DLT on instantiated Plan Processes             │
│  dependentDemand() — BFS backward; purchaseIntents for orphans   │
│  dependentSupply() — forward supply explosion (Mode C)           │
│  rollup() — standardCost, actualCost, costVariance               │
│  track-trace() — previousEvent breadcrumb chain                  │
│  resource-flows() — inventory / cash flow timeline               │
│  recurrence utils — OccurrenceStatus, unfulfilledOccurrences,    │
│    materializeOccurrenceDates (ADU data source)                  │
│  [GAP: ADU tracker, spike qualifier, buffer zone calc,           │
│    true NFP (onhandQty-based, allows negative), LTM engine]      │
└──────────────────────────────────────────────────────────────────┘

Scheduling (Plan + Algorithm layers):
  ScheduleBook.blocksFor / committedEffortOn / hasUseConflict / isResourceAvailable
  PlanNetter.netUse [from,to) — time-slot booking
  RecipeStore.getProcessChain() — routing / decoupled legs
  criticalPath() — DLT per leg, isCritical / float per process
  Agent.availability_window — working hours ceiling
  [GAP: scheduling queue, WIP dispatch list, capacity-time dashboard,
   control point scheduler, composite priority engine]
```
