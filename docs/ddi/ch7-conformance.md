# DDMRP Chapter 7 — Rigorous Conformance Tracker

**Reference**: Ptak & Smith, *Demand Driven Material Requirements Planning* (DDI Press, 3rd ed.) — Chapter 7
**Schema source**: `src/lib/schemas.ts`
**Algorithm source**: `src/lib/algorithms/ddmrp.ts`
**Seed**: `src/lib/vf-seed.ts`
**Last reviewed**: 2026-03-22

---

## Legend

| Code | Meaning |
|---|---|
| **A** | Aligned — implemented correctly, matches book definition |
| **P** | Partial — concept exists but something is missing or incomplete |
| **G** | Gap — concept has no implementation |
| **M** | Misaligned — implementation exists but differs materially from book definition |

---

## §1 Strategic Inventory Positioning — 6 Positioning Factors

Chapter 7 defines six factors that govern where decoupling points should be placed in the product structure or distribution network. Every buffered item should have a documented rationale across all six.

### 1.1 Factor Map

| # | Ch 7 Factor | Schema Field | Implementation | Status | Notes |
|---|---|---|---|---|---|
| 1 | **Customer Tolerance Time (CTT)** | `PositioningAnalysis.customerToleranceTimeDays` | Stored in days as a non-negative number | **A** | Correctly typed as numeric days |
| 2 | **Market Potential Lead Time (MPLT)** | `PositioningAnalysis.marketPotentialLeadTimeDays` | Stored in days | **A** | Used as competitive benchmark |
| 3 | **Sales Order Visibility Horizon (SOVH)** | `PositioningAnalysis.salesOrderVisibilityHorizonDays` | Stored in days | **A** | Represents confirmed-order horizon |
| 4 | **External Variability — Demand (VRD)** | `PositioningAnalysis.vrd` | `z.enum(['low','medium','high'])` | **A** | Feeds `deriveVariabilityFactor()` |
| 4 | **External Variability — Supply (VRS)** | `PositioningAnalysis.vrs` | `z.enum(['low','medium','high'])` | **A** | Feeds `deriveVariabilityFactor()` |
| 5 | **Inventory Leverage & Flexibility (ILF)** | `PositioningAnalysis.inventoryLeverageFlexibility` | `z.enum(['low','medium','high'])` | **A** | Correct semantic: high = many downstream options |
| 6 | **Critical Operation Protection (COP)** | `PositioningAnalysis.criticalOperationProtection` | `z.boolean().optional()` | **A** | Feeds `scorePositioningAnalysis()` |

### 1.2 Derived / Supporting Fields

| Ch 7 Concept | Schema Field | Status | Notes |
|---|---|---|---|
| Decoupling-point recommendation | `PositioningAnalysis.decouplingRecommended` | **A** | Boolean flag derived from the 6-factor analysis |
| Rationale note | `PositioningAnalysis.note` | **A** | Free-text justification |
| Link positioning analysis to item | `ResourceSpecification.positioningAnalysis` | **A** | Inline embedding; rationale travels with the spec |
| Link item to buffer profile | `ResourceSpecification.bufferProfileId` | **A** | String reference to `BufferProfile.id` |
| Decoupling point detection | BufferZone existence for specId | **A** | Decoupling derived from `bufferZoneStore` (not spec-level tag; `replenishmentRequired` field removed) |
| Decoupling point marker (process) | `ProcessSpecification.isDecouplingPoint` | **A** | Design-time boolean |
| Control point marker (process) | `ProcessSpecification.isControlPoint` | **A** | Design-time boolean |

### 1.3 Positioning Decision Function

| Ch 7 Concept | Function | Status | Notes |
|---|---|---|---|
| Scoring / ranking items by positioning factors | `scorePositioningAnalysis()` in `ddmrp.ts` | **A** | 0–100 score across 6 factors; returns recommendation |
| 6 Tests for Decoupling Point Success | `DecouplingTestResultSchema` in `schemas.ts` | **A** | Audit-trail schema; evaluation remains manual |
| Buffer eligibility check (should this item be buffered?) | `bufferEligibility()` in `ddmrp.ts` | **A** | ADU threshold, MTO flag, CTT ≥ DLT checks |

---

## §2 Item Type Classification

Ch 7 defines four item types that drive profile selection. Each type has different typical LTF and VF ranges.

| Ch 7 Item Type | Schema Value | Status | Notes |
|---|---|---|---|
| **M** — Manufactured in-house | `'Manufactured'` on `BufferProfile.itemType` | **A** | Correct |
| **P** — Purchased externally | `'Purchased'` | **A** | Correct |
| **I** — Intermediate (dual-source: made AND purchased) | `'Intermediate'` | **A** | Correct |
| **D** — Distributed (replenished through distribution network) | `'Distributed'` | **A** | Correct |

### 2.1 Item Type → ResourceSpecification Linkage

| Ch 7 Concept | Implementation | Status | Notes |
|---|---|---|---|
| Item type classification on the item | `BufferProfile.itemType` (on the profile, linked via `bufferProfileId`) | **P** | The item type is on the *profile*, not directly on the `ResourceSpecification`. This is correct per the book (profile-first), but there is no validation that an item's profile `itemType` is consistent with how the item is actually sourced. |
| Item sourcing type on `ResourceSpecification` | `checkItemTypeConsistency()` in `ddmrp.ts` | **A** | Infers P/M/I from recipe flows and compares against profile; warns on mismatch |

---

## §3 Buffer Profile System

### 3.1 Lead Time Category and LTF Ranges

Ch 7 specifies numeric LTF ranges per lead time band. The bands apply uniformly across all four item types.

| Ch 7 LT Band | LTF Range (book) | Schema Enum Value | LTF Enforcement | Status | Notes |
|---|---|---|---|---|---|
| **Short** | 0.61 – 1.00 | `'short'` on `BufferProfile.leadTimeCategory` | `validateBufferProfile()` in `ddmrp.ts` | **A** | Returns warning when LTF outside `LTF_RANGES.short` |
| **Medium** | 0.41 – 0.60 | `'medium'` | `validateBufferProfile()` | **A** | Same function covers all bands |
| **Long** | 0.20 – 0.40 | `'long'` | `validateBufferProfile()` | **A** | Same function covers all bands |

### 3.2 Variability Category and VF Ranges

| Ch 7 Variability Band | VF Range (book) | Schema Enum Value | VF Enforcement | Status | Notes |
|---|---|---|---|---|---|
| **Low** | 0.00 – 0.40 | `'low'` on `BufferProfile.variabilityCategory` | `validateBufferProfile()` in `ddmrp.ts` | **A** | Returns warning when VF outside `VF_RANGES.low` |
| **Medium** | 0.41 – 0.60 | `'medium'` | `validateBufferProfile()` | **A** | Same function covers all bands |
| **High** | 0.61 – 1.00+ | `'high'` | `validateBufferProfile()` | **A** | Same function covers all bands |

### 3.3 VRD × VRS → VF Lookup Table

| Ch 7 Concept | Implementation | Status | Notes |
|---|---|---|---|
| 3×3 VRD × VRS matrix → numeric VF | `deriveVariabilityFactor(vrd, vrs)` in `ddmrp.ts:1902` | **A** | Exact Ch 6/7 lookup table: low/low=0.10, medium/medium=0.50, high/high=1.00, etc. |

### 3.4 Standard 36-Profile Matrix

Ch 7 defines 4 item types × 3 LT categories × 3 variability categories = **36 standard profiles**, each with a 3-letter code.

| Ch 7 Concept | Implementation | Status | Notes |
|---|---|---|---|
| 36 standard profiles enumeration | `STANDARD_LTF`, `STANDARD_VF`, `standardProfile()` in `ddmrp.ts` | **A** | Returns template profile for any of the 36 combinations |
| 3-letter profile code (e.g. "MML") | `BufferProfile.code: z.string().optional()` | **A** | Field exists; `buildProfileCode()` ensures correct format |
| Profile code construction rule | `buildProfileCode(itemType, ltCategory, varCategory)` in `ddmrp.ts` | **A** | Returns correct 3-letter code |
| Profile code → standard LTF / VF lookup | `parseProfileCode(code)` + `STANDARD_LTF` / `STANDARD_VF` in `ddmrp.ts` | **A** | Parse returns `{itemType, ltCategory, varCategory}`; lookups use the constants |
| `leadTimeCategory` ↔ `leadTimeFactor` consistency check | `validateBufferProfile()` using `LTF_RANGES` in `ddmrp.ts` | **A** | Returns warning strings; non-throwing |
| `variabilityCategory` ↔ `variabilityFactor` consistency check | `validateBufferProfile()` using `VF_RANGES` in `ddmrp.ts` | **A** | Same function |

---

## §4 Buffer Type Classification

### 4.1 Buffer Types

| Ch 7 Buffer Type | Schema Enum | `toy` Semantics | Auto-recalculate | Status | Notes |
|---|---|---|---|---|---|
| **Replenished** | `'replenished'` | `toy = tor + ADU × DLT` (full 3-zone) | Yes | **A** | `computeBufferZone()`, `recalibrateBufferZone()` |
| **Replenished Override** | `'replenished_override'` | User-set; must not be modified | No — `recalibrateBufferZone()` returns early | **A** | Guard implemented at `ddmrp.ts:746` |
| **Min-Max** | `'min_max'` | `toy = tor` (no yellow zone — "Not Applicable") | Yes — dispatches to `computeMinMaxBuffer()` | **A** | Implemented; `recalibrateBufferZone()` dispatches at `ddmrp.ts:754` |

### 4.2 Buffer Type Semantics

| Ch 7 Concept | Implementation | Status | Notes |
|---|---|---|---|
| Min-Max: "Min" = TOR, "Max" = TOG | `toy = tor` in `computeMinMaxBuffer()` | **A** | Yellow zone size is zero; red→green boundary is correct |
| Override: zones are contractual (e.g. supplier agreement) | `bufferClassification: 'replenished_override'` | **A** | Semantic is documented in JSDoc and schema comment |
| Override: TOR/TOY/TOG must be user-set, not computed | `recalibrateBufferZone()` returns `existing` unchanged | **A** | Guard at `ddmrp.ts:746` |
| Override: still recalibrates ADU/DLT for monitoring | `recalibrateBufferZone()` early-return branch in `ddmrp.ts` | **A** | Returns `{ ...existing, adu: newADU, dltDays: newDLTDays, lastComputedAt }` — zones unchanged |
| Buffer type auto-selection criteria | `recommendBufferType()` in `ddmrp.ts` | **A** | Contractual → override; low VF + stable ADU → min_max; else replenished |
| `bufferClassification` default | `z.enum([...]).default('replenished')` | **A** | New zones default to replenished |
| `bufferClassification` preserved on recalibration | `...existing` spread in `recalibrateBufferZone()` | **A** | The field is never overwritten |

---

## §5 Zone Calculation Formulas

### 5.1 Red Zone

| Ch 7 Formula Component | Implementation | Status | Notes |
|---|---|---|---|
| Red Base = ADU × DLT × LTF | `redBase = effectiveADU * effectiveDLT * profile.leadTimeFactor` | **A** | `ddmrp.ts:667` |
| Red Safety = Red Base × VF | `redSafety = redBase * profile.variabilityFactor` | **A** | `ddmrp.ts:668` |
| TOR = Red Base + Red Safety | `tor = (redBase + redSafety) * zoneAdjFactor` | **A** | ZAF = 1.0 when no active adjustments |
| ADU and DLT modified by DAF / LTAF before red zone calc | `effectiveADU = adu * demandAdjFactor`, `effectiveDLT = dlt * leadTimeAdjFactor` | **A** | `ddmrp.ts:664–665` |
| ZAF (Zone Adj Factor) applied to TOR | `* (opts?.zoneAdjFactor ?? 1)` | **A** | `ddmrp.ts:669` |

### 5.2 Yellow Zone (Replenished only)

| Ch 7 Formula Component | Implementation | Status | Notes |
|---|---|---|---|
| Yellow = ADU × DLT | `toy = tor + effectiveADU * effectiveDLT` | **A** | `ddmrp.ts:670` |
| Yellow = "Not Applicable" for Min-Max (TOY = TOR) | `toy: result.tor` in `computeMinMaxBuffer()` | **A** | `ddmrp.ts:713` |

### 5.3 Green Zone

| Ch 7 Formula Component | Implementation | Status | Notes |
|---|---|---|---|
| Green candidate 1: ADU × DOC (order cycle days) | `effectiveADU * profile.orderCycleDays` | **A** | `ddmrp.ts:677` |
| Green candidate 2: DLT × ADU × LTF (= Red Base) | `redBase` used as floor | **A** | `ddmrp.ts:678` |
| Green candidate 3: MOQ | `moq` | **A** | `ddmrp.ts:679` |
| Green = max of all three | `Math.max(...)` | **A** | `ddmrp.ts:676–680` |
| TOG = TOY + Green | `tog = toy + greenBase` | **A** | `ddmrp.ts:681` |
| Min-Max green zone uses same three-way max | `computeMinMaxBuffer()` delegates to `computeBufferZone()` first | **A** | Only `toy` is replaced; `tog` formula unchanged |

### 5.4 Adjustment Factors

| Ch 7 Factor | Schema Field | Function | Status | Notes |
|---|---|---|---|---|
| DAF — Demand Adjustment Factor | `DemandAdjustmentFactor.type: 'demand'` | `aggregateAdjustmentFactors()` | **A** | Compounds active factors |
| ZAF — Zone Adjustment Factor | `DemandAdjustmentFactor.type: 'zone'` | Same | **A** | Applied multiplicatively to TOR |
| LTAF — Lead Time Adjustment Factor | `DemandAdjustmentFactor.type: 'leadTime'` | Same | **A** | Applied to DLT before all zone calcs |
| Supply Offset (timing shift) | `DemandAdjustmentFactor.supplyOffsetDays` | `aggregateAdjustmentFactors()` accumulates; `generateReplenishmentSignal()` applies to due date | **A** | Summed into `AggregatedFactors.supplyOffsetDays`; propagated via `recalibrateBufferZone()` |
| Factor date range validation (validFrom/validTo) | `DemandAdjustmentFactor.validFrom/validTo` | `aggregateAdjustmentFactors()` | **A** | ISO date string comparison |
| Location-scoped factors | `DemandAdjustmentFactor.atLocation` | `aggregateAdjustmentFactors()` | **A** | Global factors also apply to all locations |
| Compounding multiple factors of same type | Multiplication loop | `aggregateAdjustmentFactors()` | **A** | Correct; all active same-type factors multiply |

---

## §6 Average Daily Usage (ADU)

| Ch 7 ADU Concept | Function | Status | Notes |
|---|---|---|---|
| Past ADU — rolling window of historical consumption | `computeADU(events, specId, windowDays, asOf)` | **A** | Correctly uses `onhandEffect: 'decrement'` filter |
| Past ADU — days-with-no-consumption counted in denominator | `adu = totalConsumed / windowDays` | **A** | Ch 7 explicitly requires this to avoid inflated ADU |
| Forward ADU — from recurring Intents and scheduled demand | `computeForwardADU(intents, specId, windowDays, asOf)` | **A** | Handles `AvailabilityWindow`, `SpecificDateWindow`, and point-in-time `due` |
| Blended ADU — weighted mix of past and forward | `blendADU(past, forward, blendRatio)` | **A** | `blendRatio = 1` → pure past; `0` → pure forward |
| ADU blend ratio stored on zone | `BufferZone.aduBlendRatio` | **A** | 0–1 range enforced |
| ADU window length stored on zone | `BufferZone.aduWindowDays` | **A** | Positive number |
| ADU computation start date recorded | `BufferZone.aduComputedFrom` | **A** | ISO date of earliest qualifying event |
| Recalculation cadence on profile | `BufferProfile.recalculationCadence` | **A** | `'daily' | 'weekly' | 'monthly'` |
| DAF applied to ADU before zone calc | `effectiveADU = adu * demandAdjFactor` | **A** | Correct |
| Seasonal / ramp patterns in forward ADU | `AvailabilityWindow` (rrule-based) materialized by `materializeOccurrenceDates()` | **A** | Recurring Intents naturally model seasonal patterns |

---

## §7 Decoupled Lead Time (DLT)

| Ch 7 DLT Concept | Function | Status | Notes |
|---|---|---|---|
| DLT from recipe template (before instantiation) | `recipeLeadTime(recipeId, recipeStore)` | **A** | Longest-path through `RecipeProcess.hasDuration` DAG |
| DLT for a single routing leg between two decoupling points | `legLeadTime(recipeId, upstreamStage, downstreamStage, recipeStore)` | **A** | Sub-DAG intersection of forward and backward reachability |
| DLT from instantiated Plan (actual dates) | `criticalPath(planId, …)` in `algorithms/critical-path.ts` | **A** | Uses `Process.hasBeginning/hasEnd` |
| LTAF applied to DLT before zone calc | `effectiveDLT = dltDays * leadTimeAdjFactor` | **A** | `ddmrp.ts:665` |
| DLT stored on zone | `BufferZone.dltDays` | **A** | Updated by `recalibrateBufferZone()` |

---

## §8 Net Flow Position (NFP) and Replenishment

| Ch 7 / Ch 9 Concept | Function | Status | Notes |
|---|---|---|---|
| NFP = on-hand + on-order − qualified demand (signed) | `computeNFP()` | **A** | Returns signed number; negative = stockout |
| On-hand = physical custody (`onhandQuantity`) | `Observer.conformingResources()` summing `onhandQuantity` | **A** | Not `accountingQuantity` |
| On-order = approved Commitments only (not Intents) | Filter: `outputOf !== undefined && !NON_CONSUMING_ACTIONS` | **A** | Intents excluded per Ch 7 |
| Qualified demand with OST spike filter | `qualifyDemand()` | **A** | OST horizon = 50% DLT by default; customizable via `BufferZone.ostHorizonDays` |
| OST multiplier on profile | `BufferProfile.ostMultiplier` | **A** | `spikeThreshold = ADU × ostMultiplier` |
| Zone classification from NFP | `nfp ≤ tor → red`, `≤ toy → yellow`, `≤ tog → green`, else `excess` | **A** | `ddmrp.ts:610–618` |
| Planning priority = NFP / TOG | `priority = nfp / tog` | **A** | Can be negative or > 1.0 |
| Replenishment signal generation | `generateReplenishmentSignal()` | **A** | Includes MOQ rounding: `ceil(raw / moq) * moq` |
| TOG − NFP order quantity | `raw = tog - nfp.nfp` | **A** | `ddmrp.ts:1119` |
| MOQ enforcement on recommended qty | `Math.ceil(raw / moq) * moq` | **A** | `ddmrp.ts:1122` |
| Due date = today + DLT + supplyOffset | `dueDate = today + (dltDays + offsetDays) * 86_400_000` | **A** | `ddmrp.ts`; `offsetDays = bufferZone.supplyOffsetDays ?? 0` |

---

## §9 Buffer Health and Execution Alerts

| Ch 7 / Ch 10 Concept | Function | Status | Notes |
|---|---|---|---|
| Buffer health % = OH / TOG | `bufferStatus()` → `pct = onhand / tog * 100` | **A** | `ddmrp.ts:796` |
| Zone classification by on-hand | `bufferStatus()` → `zone` | **A** | Same 4-zone logic as NFP |
| On-hand alert (customizable threshold in red) | `onHandAlert(onhand, bz, alertThreshold)` | **A** | Default 50% of TOR |
| LTM alert (supply order in last third of DLT) | `ltmAlertZone(commitment, dltDays, today)` | **A** | Three sub-zones in final 1/3 of DLT |
| Projected on-hand (day-by-day DLT horizon) | `projectOnHand()` | **A** | Replays demand/supply Commitments + Intents |
| Buffer health time-series reconstruction | `bufferHealthHistory()` | **A** | Replays events from `fromDate` to `toDate` |
| Signal integrity report | `signalIntegrityReport()` | **A** | Maps signals to approved Commitments + fulfillment |
| Average on-hand target (working capital ref) | `averageOnHandTarget(bz)` = `tor + (tog − toy) / 2` | **A** | `ddmrp.ts:1206` |
| Prioritized zone-fill (scarce supply) | `prioritizedShare()` | **A** | Phase 1→TOR, Phase 2→TOY, Phase 3→proportional green |

---

## §10 Decoupling Point Validation (6 Tests)

Ch 7 defines six formal tests that a proposed decoupling point must pass before it is approved for implementation.

| Test | Description | Implementation | Status |
|---|---|---|---|
| 1. **Decoupling Test** | Does placing a buffer here genuinely decouple supply from demand? | `DecouplingTestResultSchema.results[].test: 'decoupling'` | **A** | Schema captures pass/fail + note; evaluation remains manual |
| 2. **Bi-Directional Benefit Test** | Does the buffer benefit BOTH upstream and downstream? | `test: 'bi-directional'` | **A** | Same schema |
| 3. **Order Independence Test** | Can each side of the decoupling point operate independently? | `test: 'order-independence'` | **A** | Same schema |
| 4. **Primary Planning Mechanism Test** | Is this buffer the primary planning signal for the item? | `test: 'primary-planning'` | **A** | Same schema |
| 5. **Relative Priority Test** | Can buffer status determine relative urgency vs. other buffers? | `test: 'relative-priority'` | **A** | Same schema |
| 6. **Dynamic Adjustment Test** | Can the buffer self-adjust via DAF/ZAF/LTAF when conditions change? | `test: 'dynamic-adjustment'` | **A** | Same schema |

All 6 tests map to `DecouplingTestResultSchema` (`schemas.ts`). The schema captures `specId`, per-test pass/fail, notes, and optional approval metadata.

---

## §11 Capacity Buffers (DDOM Three-Buffer System)

Ch 7 specifies that stock buffers (§4–9 above) are part of a three-buffer system. The other two buffer types are captured here for completeness.

| Buffer Type | Schema / Implementation | Status | Notes |
|---|---|---|---|
| **Stock Buffer** (TOR/TOY/TOG) | `BufferZone`, `computeBufferZone()` | **A** | Core of this chapter |
| **Capacity Buffer** (sprint headroom) | `CapacityBuffer` schema + `CapacityBufferStore` in `knowledge/capacity-buffers.ts` | **A** | Utilisation zones: `< 70% → green, < 90% → yellow, ≥ 90% → red` |
| **Time Buffer** (schedule protection before control point) | `ltmAlertZone()` + `Commitment.due` | **P** | LTM alert uses last-third-of-DLT; formal time-buffer sizing formula (= variability in routing time) is not implemented |
| Capacity → stock buffer interaction | `adjustVFForCapacity(baseVF, capacityZone)` in `ddmrp.ts` | **A** | Advisory: red×1.25, yellow×1.00, green×0.85; capped at 1.0 |

---

## §12 DDS&OP Governance Layer

| Ch 7 / DDS&OP Concept | Implementation | Status | Notes |
|---|---|---|---|
| Profile settings reviewed in DDS&OP | `BufferProfile` schema | **A** | Data structure exists |
| Zone adjustment via DAF/ZAF/LTAF in DDS&OP | `DemandAdjustmentFactor` schema | **A** | Schema correct; UI for DDS&OP review is separate concern |
| Buffer recalibration scheduling | `BufferProfile.recalculationCadence` | **A** | Cadence stored; no scheduler engine |
| Variance analysis return loop | `signalIntegrityReport()` | **A** | Comparison of recommended vs approved vs fulfilled |
| D2 (Design 2) — working capital analysis | `averageOnHandTarget(bz)` | **A** | Per-zone average target for investment sizing |

---

## Gaps — Detailed Specifications

### G-1: Critical Operation Protection (COP) — 6th Positioning Factor

**What the book says:** The 6th factor asks whether an item is upstream of a critical, costly, or quality-sensitive operation. If yes, stocking the item upstream reduces the risk that the critical operation runs out of inputs (protecting throughput).

**What is missing:** `PositioningAnalysis` has 5 of the 6 factors. `criticalOperationProtection` (boolean or enum) is absent.

**Proposed fix:**
```ts
// In PositioningAnalysisSchema, add:
criticalOperationProtection: z.boolean().optional(),
// true = item feeds a capacity-constrained or quality-critical operation
```

**Scope:** `src/lib/schemas.ts` only — one field addition, zero algorithm changes.

---

### G-2: Positioning Scoring Function

**What the book says:** The 6 factors are used together to score and rank candidate decoupling points. Higher scores on CTT (short), SOVH (short), ILF (high), VRD+VRS (high), and COP (true) → stronger case for decoupling.

**What is missing:** No function computes a positioning score or summary recommendation from the 6 factors.

**Proposed fix:**
```ts
export function scorePositioningAnalysis(pa: PositioningAnalysis): {
    score: number;        // 0–100
    recommendation: 'buffer' | 'consider' | 'skip';
    factors: Record<string, number>;  // per-factor contributions
}
```

**Scope:** New function in `algorithms/ddmrp.ts` (or a new `algorithms/positioning.ts`).

---

### G-3: 6 Tests for Decoupling Point Success

**What the book says:** Before approving a proposed decoupling point, six formal tests must pass (see §10 above). These are analytical checks, not automated computations.

**What is missing:** No schema for the test results; no function to evaluate them.

**Proposed fix (minimal):**
```ts
// Schema
export const DecouplingTestResultSchema = z.object({
    specId: z.string(),
    results: z.array(z.object({
        test: z.enum(['decoupling','bi-directional','order-independence',
                      'primary-planning','relative-priority','dynamic-adjustment']),
        passed: z.boolean(),
        note: z.string().optional(),
    })),
    approvedAt: z.string().datetime().optional(),
    approvedBy: z.string().optional(),
});
```

**Scope:** `src/lib/schemas.ts` (new type) — audit trail only; evaluation remains manual.

---

### G-4: Buffer Eligibility Check

**What the book says:** Not every item should be buffered. The book gives explicit criteria for when NOT to buffer an item: very low ADU (near-zero demand), CTT ≥ total supply lead time (no benefit to stocking), or single-customer MTO items.

**What is missing:** No `isBufferEligible(spec, pa, profile)` function that applies these exclusion criteria.

**Proposed fix:**
```ts
export function bufferEligibility(
    pa: PositioningAnalysis,
    adu: number,
    totalLeadTimeDays: number,
    isMTO: boolean,
): { eligible: boolean; reasons: string[] }
```

**Scope:** New function in `algorithms/ddmrp.ts`.

---

### G-5: Item Type Consistency Check

**What the book says:** An item's DDMRP type (P/M/I/D) must match how it is actually sourced. A manufactured item on a purchased profile will have wrong LTF/VF assumptions.

**What is missing:** No validation that `ResourceSpecification`'s actual sourcing (via recipe flows: `produce` outputs = M, external `transfer` inputs = P, both = I) is consistent with the `BufferProfile.itemType` linked via `bufferProfileId`.

**Proposed fix:** A check function (or schema extension) that infers item type from recipe graph and warns when it contradicts the profile's `itemType`.

**Scope:** New utility function, no schema change needed.

---

### G-6: LTF Range Validation per Lead Time Category

**What the book says:**
- Short LT → LTF in range [0.61, 1.00]
- Medium LT → LTF in range [0.41, 0.60]
- Long LT → LTF in range [0.20, 0.40]

**What is missing:** `BufferProfile.leadTimeFactor` is `z.number().positive()` — any value passes. A profile with `leadTimeCategory: 'short'` and `leadTimeFactor: 0.2` is internally contradictory but valid by schema.

**Proposed fix:**
```ts
// Option A: Zod refine (breaks down on optional category)
const LTF_RANGES = { short: [0.61, 1.0], medium: [0.41, 0.60], long: [0.20, 0.40] };
// Option B: Runtime validation function
export function validateBufferProfile(profile: BufferProfile): string[]  // returns warning messages
```

**Scope:** Either a Zod `.superRefine()` on `BufferProfileSchema`, or a standalone `validateBufferProfile()` function.

---

### G-7: VF Range Validation per Variability Category

**Parallel to G-6** for variability:
- Low variability → VF in [0.00, 0.40]
- Medium → VF in [0.41, 0.60]
- High → VF in [0.61, 1.00+]

**Proposed fix:** Same as G-6 — extend `validateBufferProfile()` to include VF range checks.

---

### G-8: Standard 36-Profile Registry

**What the book says:** Ch 7 presents a complete 36-profile matrix as a reference. Companies customize LTF/VF within band ranges, but the matrix provides starting points.

**What is missing:** No function or constant enumerates the 36 standard profile codes or provides default LTF/VF starting values.

**Proposed fix:**
```ts
// In a new src/lib/knowledge/buffer-profiles.ts or inline in ddmrp.ts:
export const STANDARD_LTF: Record<'short'|'medium'|'long', number> = {
    short: 0.80, medium: 0.50, long: 0.30,
};
export const STANDARD_VF_BY_CATEGORY: Record<'low'|'medium'|'high', number> = {
    low: 0.10, medium: 0.50, high: 1.00,
};
export function standardProfile(
    itemType: BufferProfile['itemType'],
    ltCategory: 'short'|'medium'|'long',
    varCategory: 'low'|'medium'|'high',
): Omit<BufferProfile, 'id'|'name'>;  // returns a ready-to-use profile template
```

**Scope:** New function in `algorithms/ddmrp.ts` or a new `knowledge/buffer-profiles.ts`.

---

### G-9: Profile Code Validation and Lookup

**What the book says:** Profile codes are 3-letter strings: `[M|P|D|I][S|M|L][L|M|H]`. The code encodes itemType (first letter), lead time band (second), and variability band (third).

**What is missing:**
- `BufferProfile.code` is `z.string().optional()` — no format enforcement.
- No `buildProfileCode(itemType, ltCategory, varCategory): string` helper.
- No `parseProfileCode(code): { itemType, ltCategory, varCategory }` helper.

**Proposed fix:**
```ts
export function buildProfileCode(
    itemType: BufferProfile['itemType'],
    ltCategory: 'short'|'medium'|'long',
    varCategory: 'low'|'medium'|'high',
): string {
    const it = { Manufactured:'M', Purchased:'P', Distributed:'D', Intermediate:'I' }[itemType];
    const lt = { short:'S', medium:'M', long:'L' }[ltCategory];
    const vr = { low:'L', medium:'M', high:'H' }[varCategory];
    return `${it}${lt}${vr}`;
}
```

**Scope:** New utility function in `algorithms/ddmrp.ts`. Optionally add Zod `.regex(/^[MPDI][SML][LMH]$/)` to `BufferProfile.code`.

---

### G-10: Override Zone — ADU/DLT Informational Tracking

**What the book says:** Even for `replenished_override` zones, the book recommends continuing to monitor current ADU and DLT data. When the monitored ADU × DLT × profile deviates significantly from the user-set TOR/TOY/TOG, it signals that the contract terms may need renegotiation.

**What is missing:** `recalibrateBufferZone()` returns the entire zone unchanged for overrides. The updated `adu` and `dltDays` values are never written back. There is no "override drift" detection.

**Proposed fix:**
```ts
// In recalibrateBufferZone(), for override zones, update adu/dltDays but not tor/toy/tog:
if (existing.bufferClassification === 'replenished_override') {
    return { ...existing, adu: newADU, dltDays: newDLTDays, lastComputedAt: asOf.toISOString() };
}
// Optionally expose a separate overrideDrift() function that computes
// what the zones WOULD be if replenished, for comparison.
```

**Scope:** `src/lib/algorithms/ddmrp.ts` — small change to the existing guard.

---

### G-11: Buffer Type Auto-Selection

**What the book says:** The book gives guidance on when each buffer type is appropriate:
- Replenished: most items with variable demand and supply
- Min-Max: items with highly stable, predictable demand
- Override: items with contractually fixed quantities, constrained supply, or regulatory restrictions

**What is missing:** No `recommendBufferType(adu, variabilityFactor, isMTO, isContractual): BufferZone['bufferClassification']` function.

**Scope:** New advisory function, no schema changes.

---

### G-12: Supply Offset Application in Zone Calculation

**What the book says:** `supplyOffsetDays` on a `DemandAdjustmentFactor` shifts the timing of when supply is expected to arrive (e.g. a supplier consistently delivers 2 days late). This should affect the effective DLT used in zone calculations.

**What is missing:** `DemandAdjustmentFactor.supplyOffsetDays` is stored in the schema but `aggregateAdjustmentFactors()` does not return it, and `computeBufferZone()` does not consume it. The field has no effect.

**Proposed fix:**
```ts
// In AggregatedFactors, add:
supplyOffsetDays: number;   // sum of all active supply offsets

// In aggregateAdjustmentFactors(), accumulate:
supplyOffset += adj.supplyOffsetDays ?? 0;  // additive, not multiplicative

// In computeBufferZone() opts, add:
supplyOffsetDays?: number;

// In recalibrateBufferZone(), pass through:
factors.supplyOffsetDays
```

**Scope:** `src/lib/schemas.ts` (no change), `src/lib/algorithms/ddmrp.ts` — three small changes.

---

### G-13: Capacity Buffer ↔ Stock Buffer Interaction

**What the book says:** The three buffer types (stock, time, capacity) are interdependent. Higher sprint capacity shrinks the required stock buffer sizes (less variability to absorb). The book suggests a qualitative adjustment: when capacity utilisation is in the red zone, stock buffer VF should increase.

**What is missing:** No function computes a recommended VF adjustment based on capacity buffer utilisation, and no link exists between `CapacityBuffer` and `BufferZone`.

**Scope:** Advisory function only — no schema change strictly required. Low priority.

---

## Summary Scorecard

### Round 1 — Original 13-gap audit

| Ch 7 Section | A | P | G | M | Total Concepts |
|---|---|---|---|---|---|
| §1 Strategic Positioning (6 factors) | 14 | 0 | 0 | 0 | 14 |
| §2 Item Type Classification | 5 | 0 | 0 | 0 | 5 |
| §3 Buffer Profile System | 13 | 0 | 0 | 0 | 13 |
| §4 Buffer Type Classification | 10 | 0 | 0 | 0 | 10 |
| §5 Zone Formulas (Red/Yellow/Green + DAF/ZAF/LTAF) | 15 | 0 | 0 | 0 | 15 |
| §6 ADU Computation | 9 | 0 | 0 | 0 | 9 |
| §7 DLT | 5 | 0 | 0 | 0 | 5 |
| §8 NFP and Replenishment | 12 | 0 | 0 | 0 | 12 |
| §9 Execution Alerts + Buffer Health | 9 | 1 | 0 | 0 | 10 |
| §10 Decoupling Point Tests | 6 | 0 | 0 | 0 | 6 |
| §11 Three-Buffer System (Capacity/Time) | 3 | 1 | 0 | 0 | 4 |
| §12 DDS&OP Governance | 5 | 0 | 0 | 0 | 5 |
| **Total** | **106** | **2** | **0** | **0** | **108** |

**Round 1: 106/108 aligned (98%), 2 partial, 0 gaps, 0 misalignments**

### Round 2 — Deep review (N-1 through N-4)

| Gap | Area | Resolution |
|---|---|---|
| N-1 | ADU exception alert system (high/low threshold, rolling window) | **A** — `aduAlertHighPct`, `aduAlertLowPct`, `aduAlertWindowDays` on `BufferZone`; `aduDriftAlert()` in `ddmrp.ts` |
| N-2 | ADU no-history bootstrap (estimated ADU + actualization blend) | **A** — `estimatedADU`, `bootstrapDaysAccumulated` on `BufferZone`; `bootstrapADU()` in `ddmrp.ts` |
| N-3 | Override reason capture (space/cash/contractual) | **A** — `overrideReason`, `overrideNote` on `BufferZone` |
| N-4 | Distributed item DLT breakdown (transport + staging/QA) | **A** — `transportDays`, `stagingDays` on `BufferZone` (informational; `dltDays` remains authoritative) |
| N-5 | Per-part DOC (`orderCycleDays`) — individual part attribute per Fig 7-19 | **A** — `orderCycleDays` on `BufferZone`; `docDays` opt in `computeBufferZone()`; `recalibrateBufferZone` passes it through |
| N-6 | Red base / red safety stored separately (planner worksheet visibility) | **A** — `redBase`, `redSafety` on `BufferZone` (informational; `tor` remains authoritative); persisted by `recalibrateBufferZone` |
| N-7 | ADU anomaly exclusion — individual events flagged as non-representative excluded from ADU average | **A** — `excludeFromADU` on `EconomicEventSchema`; `computeADU()` skips flagged events |

**Round 2: All 7 new gaps resolved. No regressions.**

---

## Ch 10 — Demand Driven Execution

| Concept | Function | Status | Notes |
|---|---|---|---|
| Current on-hand alert | `bufferStatus()` | **A** | Zone from on-hand vs TOR/TOY/TOG |
| Projected on-hand alert | `computeNFP()` | **A** | NFP = onhand + onorder − qualifiedDemand; zone + priority |
| Execution priority display | `computeExecutionPriority()` | **A** | On-hand severity ranking for shop floor sequencing |
| Material synchronization alert | `computeMaterialSyncAlerts()` | **A** | Shortfall detection for non-buffered process inputs |
| Lead time alert | `computeLeadTimeAlerts()` | **A** | Countdown zones (G/Y/R/late) for non-stocked items |

## Ch 12 — Metrics and Analytics

| Concept | Function | Status | Notes |
|---|---|---|---|
| Signal integrity | `computeSignalIntegrity()` | **A** | Timing + qty accuracy of replenishment signals vs approved orders |
| OTIF | `computeOTIF()` | **A** | On-Time In-Full delivery measurement |
| Flow index / velocity | `flowIndex()`, `classifyFlowSpeed()` | **A** | ADU/TOG ratio; fast/slow mover classification |
| ADU alerts | `detectADUAlerts()` | **A** | Surge/drop detection against aduAlertHighPct/LowPct thresholds |
| Decoupling point integrity (historical) | `BufferSnapshotStore` + `zoneDistribution()` + `classifyAnalyticsZone()` | **A** | Snapshots captured reactively via `createSnapshotSink()`; 7-zone Taguchi classification; zone distribution + transition analytics |

## Ch 13 — DDS&OP

| Concept | Function | Status | Notes |
|---|---|---|---|
| Current vs projected buffer zones | `projectBufferZones()` | **A** | Side-by-side comparison of zones at current vs projected ADU |
| Buffer recalibration | `recalibrateBufferZone()` | **A** | ADU-based recalculation on configurable cadence |
| 5-step DDS&OP process | Scope assembly + BufferHealthReport | **A** | Governance process; tools are available, cadence is scope-determined |

## Remaining Partial Items

All algorithmic and infrastructure gaps are resolved:

| Section | Concept | Resolution |
|---|---|---|
| §9 | Time buffer sizing formula | **A** — `computeTimeBuffer()` sizes buffer from routing time × variability × coverage factor |
| §12 | Zone-recalculation scheduler | **A** — `runRecalibrationCycle()` batch + `createRecalibrationSink()` event-driven; no cron needed |
| Ch 12 | Historical on-hand snapshots | **A** — `BufferSnapshotStore` + `createSnapshotSink()` reactive capture + `zoneDistribution()` analytics |

**All DDMRP chapters (6-13) fully implemented.** No remaining gaps.
