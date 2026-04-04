# Chapter 8 — Buffer Adjustments: Extraction, Mapping, and Gap Analysis

> **Source**: Ptak & Smith, *Demand Driven Material Requirements Planning (DDMRP)*, 3rd ed., Chapter 8 (PDF pp. 165–197).
> **Last updated**: 2026-03-08

---

## Overview

Chapter 8 defines the **third component** of DDMRP: strategic buffer adjustments. Two categories:

| Category | Trigger | Planner action |
|---|---|---|
| **Recalculated adjustments** | Change to a part attribute (ADU, DLT, MOQ) | Automated — no planner intervention |
| **Planned adjustments** | Known future event (promo, seasonality, supply disruption) | Manual — DAF, ZAF, or LTAF record |

DDMRP without planned adjustments produces "significant over- or under-statement of buffer levels during known events."

---

## 8.1 — Recalculated Adjustments (pp. 165–168)

### Definition

Automated re-computation of all zone boundaries when any of three part-level attributes changes.

### Three Recalculation Drivers

| Driver | Zones affected | Typical change frequency |
|---|---|---|
| **ADU** (Average Daily Usage) | Red base, red safety, yellow, green | Continuous (rolling window) |
| **DLT** (Decoupled Lead Time) | Red base, red safety, yellow | Rare — supplier change events |
| **MOQ** (Minimum Order Quantity) | Green floor only | Rare — negotiated at contract time |

### Equations (Ch 7 formulas, applied here)

```
effectiveADU  = ADU × DAF
effectiveDLT  = DLT × LTAF

redBase   = effectiveADU × effectiveDLT × LTF
redSafety = redBase × VF
TOR       = (redBase + redSafety) × redZAF
TOY       = TOR + (effectiveADU × effectiveDLT × yellowZAF)
green     = max(effectiveADU × DOC × greenZAF, redBase × greenZAF, MOQ)
TOG       = TOY + green
```

### Recalculation Cadence

Can be `daily`, `weekly`, or `monthly` per `BufferProfile.recalculationCadence`. ADU changes are the most frequent trigger; DLT and MOQ changes are typically event-driven.

### Figure 8-1 Example

Part 1234 — ADU grows from 10 → 53 over 6 months; all zones scale proportionally. DLT=10 days, LTF=0.5, VF=0.4 remain constant.

---

## 8.2 — Planned Adjustment Factors (pp. 168–197)

Three distinct factor types address different aspects of the buffer formula:

| Factor | Applied to | Formula element |
|---|---|---|
| **DAF** — Demand Adjustment Factor | ADU | `effectiveADU = ADU × DAF` |
| **ZAF** — Zone Adjustment Factor | A specific zone (green, yellow, or red) | zone-specific multiplier |
| **LTAF** — Lead Time Adjustment Factor | DLT | `effectiveDLT = DLT × LTAF` |

---

### 8.2.1 — Demand Adjustment Factor (DAF)

#### Definition

A multiplier applied to ADU to produce an **Adjusted ADU (AADU)**.

```
AADU = ADU × DAF
```

- **DAF = 1.0**: no change
- **DAF > 1.0**: inflationary (pre-positioning for higher demand)
- **DAF < 1.0**: deflationary (ramp-down ahead of discontinuation)

DAF feeds into **all** buffer zone equations via `effectiveADU`. The green zone selection logic (largest of DOC×ADU, redBase, MOQ) still applies — but using the adjusted ADU.

#### Use Case 1 — Rapid Buffer Adjustment

The ADU alert fires when the short-window ADU diverges significantly from the long-window ADU. The alert does **not** auto-generate a DAF; it raises questions for S&OP review.

**ADU Differential** = `ADU(short_window) / ADU(long_window)` — explicit ratio used to evaluate whether a DAF is warranted.

#### Use Case 2 — Product Introduction (Ramp-Up)

Set projected steady-state ADU as baseline; apply DAF starting near 0 and ramping to 1.0 over the launch window.

**Example** (Fig 8-9): ADU = 2,000 units/day. DAF schedule:

| Week | DAF | Effective ADU |
|---|---|---|
| 1 | 0 | 0 |
| 2 | 0.1 | 200 |
| 3 | 0.2 | 400 |
| … | … | … |
| 11 | 1.0 | 2,000 |

#### Use Case 3 — Product Deletion (Ramp-Down)

DAF decreases from 1.0 → 0 over the discontinuation window.

**Example** (Fig 8-11): Over weeks 5–9, DAF = 1.0 → 0.8 → 0.6 → 0.4 → 0.2 → 0.

#### Use Case 4 — Product Transition

Simultaneous ramp-down of outgoing SKU and ramp-up of incoming SKU. Both share the same effectivity date as the culmination point.

**Caution**: avoid "double-buffer" — the two ADUs should not overlap significantly during the transition window.

#### Use Case 5 — Seasonality

Five considerations (C1–C5) govern correct DAF application for seasonal patterns:

| # | Consideration | Implication |
|---|---|---|
| **C1** | Severity — length and magnitude of the seasonal swing | Larger swing → larger DAF |
| **C2** | ADU calculation period — longer window = greater lag during ramp-up | Long window → DAF must start earlier |
| **C3** | Past / forward / blended ADU | Forward-looking ADU may eliminate need for DAF; past-looking ADU requires DAF to pre-position |
| **C4** | Lead times of critical components (supply offset) | DAF must be applied N days early where N = cumulative LT of constraining component |
| **C5** | Resource capacity | If seasonal ramp-up outstrips supplying resource's capacity, DAF must be pulled even further forward |

**Supply offset example**: Seasonal uplift begins at week 17; constraining component lead time = 6 weeks. DAF must begin by **week 11**.

If the parent item has a buffered long-LT component, use the *cumulative* lead time of the parent for the offset unless the component buffer is sufficient to absorb the full seasonal demand increase.

#### Use Case 6 — Promotional Campaigns

Same 5 considerations as seasonality. Large planned promotions that create stockouts are treated as supply chain failures; pre-adjustment via DAF is mandatory.

#### Use Case 7 — DAF Cascade to Components

When a parent SKU has a DAF applied, shared components must receive a proportional DAF adjustment.

**Unique components**: apply the same DAF as the parent.

**Shared components** — weighted blend formula:

```
componentAdjustedADU = Σ(parentAdjustedADU_i × usageQtyPerParent_i)
componentDAF = componentAdjustedADU / componentBaseADU
```

**Example** (Fig 8-24):

| Parent | Base ADU | DAF | Adjusted ADU | Usage of ICB |
|---|---|---|---|---|
| FPA | 100 | 2.0 | 200 | 2 per unit |
| FPB | 200 | 1.0 | 200 | 2 per unit |

```
ICB adjusted ADU = (200 × 2) + (200 × 2) = 800
ICB base ADU = (100 × 2) + (200 × 2) = 600
ICB effective DAF = 800 / 600 = 1.333
```

---

### 8.2.2 — Zone Adjustment Factor (ZAF)

#### Definition

A multiplier applied to a **specific zone** of the buffer. Because each zone serves a distinct purpose, the ZAF targets the zone whose purpose matches the adjustment rationale.

#### Green Zone ZAF

**Purpose**: adjusts order size and order frequency.

| Direction | Rationale |
|---|---|
| **Increase** (ZAF > 1) | Supplying resource has significant setup issues and capacity constraint → fewer, larger orders preserve capacity |
| **Decrease** (ZAF < 1) | Sufficient excess capacity; market responsiveness is primary goal (common in seasonal markets) |

#### Yellow Zone ZAF

**Purpose**: adjusts the demand coverage window (the "on order" protection period).

**Trigger 1 — Short-term promotional event**: Event is too short to warrant a full DAF schema but will spike demand within the lead time window.

*Example*: ADU = 1,000, DLT = 7 days → yellow = 7,000. One-week promo expected to triple demand → yellowZAF = 3 → yellow = 21,000.

**Trigger 2 — Planned supply disruption**: A known interruption prevents the source from responding.

*Example*: Packaging line down for 1 week → yellowZAF = 2 doubles yellow to cover 2 weeks of demand.

#### Red Zone ZAF

**Purpose**: adjusts embedded safety (variability cushion).

**Trigger**: Known/planned but temporary change in volatility that does not warrant changing the buffer profile permanently.

*Example*: New resource or material being brought online causes higher short-term supply disruptions. Once the transition period ends, ZAF is removed and the buffer returns to normal.

---

### 8.2.3 — Lead Time Adjustment Factor (LTAF)

#### Definition

A multiplier applied to DLT for a part or group of parts sharing the same supply disruption cause.

```
effectiveDLT = DLT × LTAF
```

**Trigger**: Known or planned expansion of lead time (construction blocking a transport route, facility upgrade, supplier relocation, etc.).

**Example**: Previous LT = 2 days, estimated new LT = 3 days → LTAF = 1.5. Applied for the duration of the construction project.

**Alternative**: If the new LT will persist long-term, update the DLT field on the part master directly rather than using an LTAF.

**Scope**: Can apply to an individual part or a group of parts not necessarily in the same buffer profile.

---

## 8.3 — Summary (p. 197)

- Chapter 8 is the **third component** of DDMRP.
- **Recalculated adjustments**: automated, triggered by attribute changes. ADU is the most dynamic; DLT and MOQ are typically event-driven.
- **Planned adjustments** (DAF, ZAF, LTAF): for known/anticipated events. Correct zone selection requires understanding zone purpose.
- The three factor types address distinct planning scenarios and must not be confused:
  - DAF → demand volume change
  - ZAF → zone-specific behavior (order size, coverage window, or safety level)
  - LTAF → supply lead time change

---

## Implementation Mapping

| Ch 8 Concept | Schema | Algorithm | Status |
|---|---|---|---|
| Recalculated adjustments (ADU-driven) | `BufferProfile.recalculationCadence` | `recalibrateBufferZone()` | ✅ Complete |
| DAF — ADU multiplier | `DemandAdjustmentFactor{type:'demand'}` | `aggregateAdjustmentFactors()`, `computeBufferZone()` | ✅ Complete |
| LTAF — DLT multiplier | `DemandAdjustmentFactor{type:'leadTime'}` | `aggregateAdjustmentFactors()`, `computeBufferZone()` | ✅ Complete |
| Supply offset days (C4) | `DemandAdjustmentFactor.supplyOffsetDays` | `aggregateAdjustmentFactors()`, `generateReplenishmentSignal()` | ✅ Complete |
| ZAF — per zone (green/yellow/red) | `DemandAdjustmentFactor{type:'zone', targetZone}` | `aggregateAdjustmentFactors()`, `computeBufferZone()` | ✅ Implemented (Gap 1) |
| Component DAF cascade (Fig 8-24) | DAFs set per-specId manually | `cascadeComponentDAF()` | ✅ Implemented (Gap 2) |
| ADU Differential metric | `aduAlertHighPct`/`aduAlertLowPct` (threshold) | `computeADUDifferential()` | ✅ Implemented (Gap 3) |
| Product transition (ramp-up + ramp-down) | Two `DemandAdjustmentFactor` records with overlapping windows | Composed via `aggregateAdjustmentFactors()` | ✅ Complete |
| Resource capacity as DAF timing factor (C5) | `CapacityBuffer` (EconomicResource) | `capacityBufferStatus()` | ⚠️ Partial — no DAF timing integration |

---

## ValueFlows Translation Notes

Per project principle: "resource buffers as we have defined them are economic resources" — `CapacityBuffer` entities are `EconomicResource` instances.

| DDMRP Ch 8 Concept | ValueFlows Mapping |
|---|---|
| Buffer (any type) | `EconomicResource` with `conformsTo: ResourceSpecification` |
| DAF applied to buffer | Modifier on the `EconomicResource`'s projected `accountingQuantity` (future-looking) |
| Supply offset (C4) | Advance-scheduling the `EconomicEvent` or `Commitment` by N days before the seasonal peak |
| Resource capacity constraint (C5) | `CapacityBuffer` (an `EconomicResource`) — its `currentLoadHours/totalCapacityHours` ratio determines how far in advance DAF must begin |
| Component DAF cascade | Flows through `RecipeProcess` ingredients — `hasQuantity` on each ingredient is the `usageQty` in the cascade formula |
| Product transition | Two `DemandAdjustmentFactor` records with overlapping `validFrom/validTo` windows (one outgoing, one incoming SKU) |
| Green ZAF for setup optimization | Relates to `CapacityBuffer.setupHours` — capacity saved per setup × fewer setups = more total output |
