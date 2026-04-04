# DDI Image Extractions

> All text and structural insights extracted from the images in `docs/ddi/`.
> Source: Demand Driven Institute (DDI) — _Demand Driven Operating Model_ slide deck (© 2017 DDI)
> Companion: Ptak & Smith, _Demand Driven Material Requirements Planning_ (3rd ed.)

---

## `schema.jpg` — The Demand Driven Operating Model (DDOM) System Schema

**Title:** _(partial — "...ing" visible, likely "Demand Driven Operating Model")_

### System Diagram (flow of signals between three operational systems)

```
                     ┌─────────────────────────────────────────────────────┐
                     │         Demand Driven MRP                           │
Actual Demand ──────►│       (Supply Order Generation)                     │◄── Model Configuration
                     │                                                     │
                     │  Outputs:                                           │◄── Variance Analysis
                     │    POs & STOs ──────────────────────────►           │    Return Loop
                     │    MOs w/ Request Dates ────────────►              │    (supply order
                     │    MO w/ Promise Dates ◄────────────────           │    generation &
                     └───────────┬─────────────────┬───────────┘          │    stock management)
                                 │ On-Hand &        │ MOs                  │
                                 │ Synchronization  │ Released             │
                                 │ Alerts           │                      │
                     ┌───────────▼─────┐  ┌─────────▼──────────────────┐  │
                     │ Demand Driven   │  │ Demand Driven Scheduling   │  │
                     │ Execution       │◄─│ (Finite Control Point      │  │
                     │ (Buffer         │  │  Scheduling)               │  │
                     │  Management)   ─┤  └────────────────────────────┘  │
                     └─────────────────┘   MO Progression ───────────────►│
                                                                          │
                                           ┌──────────────────────────┐  │◄── Model Configuration
                                           │  Demand Driven S&OP      │──┘    Variance Analysis
                                           └──────────────────────────┘       Return Loop
                                                                               (scheduling,
                                                                                resources &
                                                                                execution)
```

**Legend:**

- `MO` = Manufacturing Order
- `PO` = Purchase Order
- `STO` = Stock Transfer Order

**Key flows:**

- `Actual Demand` enters **DDMRP** (supply order generation)
- DDMRP outputs POs & STOs (purchase and stock-transfer orders) and MOs with request dates
- MOs with promise dates flow into **DD Scheduling** (finite control point scheduling)
- DD Scheduling releases MOs to **DD Execution** (buffer management)
- DD Execution feeds MO progression back to DD Scheduling
- **DDS&OP** provides model configuration to all three systems and receives variance analysis return loops from both supply-order generation and scheduling/resources/execution

---

## `DDOM-Dashboard.jpg` — Demand Driven Operational Model Dashboard

**Title:** Demand Driven Operational Model Dashboard

Three dashboard columns, each owned by specific roles:

### Column 1: Reliability

**Owners:** Planner, Buyer, Scheduler

**KPIs:**

- Net Flow & On Hand Stock Status
- Order Acceptance & Launch Timeliness
- Control Point Schedule Maintenance

**Visuals shown:**

- Planning screen with columns: Part#, Open Supply, On-Hand, Demand, Net Flow (zone-colored), Recommended Supply Qty, Action
  - Example rows show parts with red/yellow zone NFP, recommended "Create Work Order" or "Create purchase order" actions
- Signal integrity grid (days × parts) with green/yellow/red/empty cells showing replenishment compliance history
- Control Point Schedule Status table: Work | MO# | Part# | Customer | Expedite Status | Start | Full Duration | Start Qty | End Qty | Complete

### Column 2: Stability

**Owners:** Buffer Manager, Resource Manager

**KPIs:**

- Stock Buffer Status
- Time Buffer Status
- Capacity Buffer Status

**Visuals shown:**

- "Yet to Be Received" horizontal bar: Early | Green | Yellow | Red | Late (with dark-red Late zone for overdue)
- "Received" horizontal bar: Early | Green | Yellow | Red | Late
- Two pairs of bar charts showing Resource Order Quantity vs Resource Order Accuracy across periods

### Column 3: Velocity

**Owners:** Buffer Manager, Resource Manager, Scheduler

**KPIs:**

- Flow Exception Reporting:
  - Release Schedules
  - Progress to Next Critical Scheduled Activity
  - Critical Scheduled Activity (Control Points)

**Visual:** Flow Exception Report table (order#, date, domain, duration/time, data columns, date in alpha)

---

## `DDOM-design-example.jpg` — Example of a Demand Driven Operating Model Design

**Title:** Example of a Demand Driven Operating Model Design

### Legend

| Symbol                              | Meaning                         |
| ----------------------------------- | ------------------------------- |
| © (circle C)                        | Control Point                   |
| Funnel (green/yellow/red trapezoid) | Decoupling Point — Stock Buffer |
| Semi-circle (green/yellow/red)      | Control Point — Time Buffer     |
| Rectangle (green/red)               | Capacity Buffer                 |

### Network Map

Two lead-time segments visible (separated by a decoupling stock buffer at assembly):

- **Leg 1 (Lead time = 3 weeks):**
  - Raw stocks → (C) shear → weld → (C) assembly [Decoupling point, time buffer]
  - Raw stocks → (C) saw → machining → assembly
  - Raw stocks → (C) laser → weld → assembly

- **Leg 2 (Lead time = 1 week):**
  - assembly → paint [stock buffer] → configure [stock buffer] → (C) → Customer

- **Purchased component stocks** feed into assembly area (stock buffer)

**Key insight:** The single decoupling point at assembly breaks the 4-week total lead time into two independently managed legs (3 weeks + 1 week). Control points at each gating resource (shear, saw, laser, configure) enforce scheduling visibility.

---

## `buffering.jpg` — Buffering in the DDOM

**Title:** Buffering in the DDOM

> "These are interchangeable and interdependent regarding sizing & flow"

Three buffer types (all use the shock-absorber metaphor = absorb variability):

| Buffer Type  | Visual                                                                       | Function                                                                                          |
| ------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Stock**    | Funnel (green top = order size, yellow = primary coverage, red = safety)     | Absorbs variability in demand and supply quantity; classic safety stock                           |
| **Time**     | Horizontal bar (Early / Green / Yellow / Red) with circular time-buffer icon | Absorbs variability in process timing; measured in time units (hours/days) before a control point |
| **Capacity** | Vertical bar (green base = normal, red/dark-red over-capacity line)          | Sprint capacity headroom; absorbs demand rate variability without becoming a bottleneck           |

**Design principle:** The three buffer types are not independent. Capacity buffer sizing affects how large stock and time buffers need to be. A company with strong sprint capacity can use smaller stock and time buffers.

---

## `capacity-buffer-requirements.jpg` — Capacity Buffer Requirements

**Title:** Capacity Buffer Requirements

- **Commitment to invest in flexible labor and/or sprint capacity** to prevent floating bottlenecks
- Diagram shows two manufacturing legs:
  - Leg 1: A1 → B1 → C1 (capacity block shown growing) → [Time buffer with G/Y/R zones] → signal tower
  - Leg 2: E1 → F1 → [Time buffer] → signal tower
- **"As variability grows in dependent systems, capacity should be structured and/or aligned to deal with it."**

**Key insight:** Floating bottlenecks move unpredictably through the routing when capacity is unevenly allocated. Capacity buffers (identified sprint resources) prevent this by ensuring the designated control point always has headroom.

---

## `capacity-buffers.jpg` — Capacity Buffers

**Title:** Capacity Buffers

- **Capacity buffers protect control and decoupling points**
- **Sprint capacity and recovery ability** will influence the sizing of both time and stock buffers

### The "Unit Cost Myth"

Misusing spare capacity (i.e. running machines at 100% utilisation to minimise unit cost) produces:

| Metric           | Direction   |
| ---------------- | ----------- |
| Responsiveness   | ↓ Decreases |
| Lead times       | ↑ Increases |
| Inventory levels | ↑ Increases |
| ROI              | ↓ Decreases |

**Visual:** Capacity bar chart (days 1–11) showing daily load relative to a capacity ceiling. Buffer zones (G/Y/R) sit at the top of total capacity. When load peaks into red/over-capacity, the system loses its shock-absorber ability.

**Contrast with flow-centric view** (see `flow-centric.jpg`): In the flow-centric model, the buffer (G/Y/R) is at the top, so variability spikes into the buffer not into the critical path. In the cost-centric model (G/Y/R inverted at bottom), red zone is at capacity floor, meaning any variation becomes a bottleneck.

---

## `control-point-placement-criteria.jpg` — Control Point Placement Criteria

**Title:** Control Point Placement Criteria

Four criteria for identifying where to place control points:

1. **Pacing Resources** — determine the total system output potential. The slowest resource — the most loaded resource — limits or defines the system total capacity for scheduling. These are commonly called a "Drum".

2. **Exit and Entry Points** — are the boundaries of your effective control. Carefully controlling that entry and exit determines whether delays and gains are generated inside or outside your system.

3. **Common Points** — are points where product structures or manufacturing routings either come together (converge) or deviate (diverge). One place controls many things.

4. **Points that Have Notorious Process Instability** — are good candidates because being a control point provides focus and visibility to the resource and forces the organization to bring it under control or plan for, manage, and block the effect of its variability from being passed forward.

---

## `control-points.jpg` — Control Points

**Title:** Control Points

- Places to transfer, impose, and amplify control through a system.
- _"Strategic locations in the logical product structure for a product or family that simplify the planning, scheduling, and control functions. Control points include gating operations, convergent points, divergent points, constraints, and shipping points. Detailed scheduling instructions are planned, implemented, and monitored at these locations."_ — **APICS Dictionary**

---

## `decoupling-considerations.jpg` — Decoupling Point Placement Considerations

**Title:** Decoupling Point Placement Considerations _(table)_

| Factor                                 | Definition                                                                                                                                                                                                                                                |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Customer Tolerance Time**            | The time the typical customer is willing to wait before seeking an alternative source.                                                                                                                                                                    |
| **Market Potential Lead Time**         | This lead time will allow an increase of price or the capture of additional business either through existing or new customer channels.                                                                                                                    |
| **Sales Order Visibility Horizon**     | The time frame in which we typically become aware of sales orders or actual dependent demand.                                                                                                                                                             |
| **External Variability**               | **Demand Variability:** The potential for swings and spikes in demand that could overwhelm resources (capacity, stock, cash, etc.). **Supply Variability:** The potential for and severity of disruptions in sources of supply and/or specific suppliers. |
| **Inventory Leverage and Flexibility** | The places in the integrated bill of material (BOM) structure (matrix bill of material) or the distribution network that enables a company with the most available options as well as the best lead time compression to meet the business needs.          |
| **Critical Operation Protection**      | These types of operations include areas that have limited capacity or where quality can be compromised by disruptions or where variability tends to be accumulated and/or amplified.                                                                      |

---

## `decoupling-points.jpg` — Decoupling Points

**Title:** Decoupling Points

- Decoupling points are placed at the **product structure level**
- The placement of Decoupling Points establishes **independently managed planning horizons**
- The length of these horizons is called the **"Decoupled Lead Time"** for the parent item at the decoupling point

_(Diagram shows a wall separating two figures — visualising the independence created between supply and demand sides of a decoupling point.)_

---

## `decoupling.jpg` — Decoupling (APICS Definitions)

**Title:** _(slide 10)_

**Decoupling (APICS Dictionary):**
_"Creating independence between supply and use of material. Commonly denotes providing inventory between operations so that fluctuations in the production rate of the supplying operation do not constrain production or use rates of the next operation."_

**Decoupling Point (APICS Dictionary):**
_"The locations in the product structure or distribution network where inventory is placed to create independence between processes or entities. Selection of decoupling points is a strategic decision that determines customer lead times and inventory investment."_

**Diagram:** Shows two operations connected by a buffer (blue rectangle). Wavy lines illustrate demand/supply variability being blocked:

- **Distortions to relevant information** (upstream) → absorbed by buffer → smoothed output
- **Distortions to relevant materials** (downstream) ← absorbed by buffer ← smoothed input

---

## `decoupling-tests.jpg` — Six Tests for Decoupling Point Success

**Title:** Six Tests for Decoupling Point Success

1. Decoupling Test
2. Bi-Directional Benefit Test
3. Order Independence Test
4. Primary Planning Mechanism Test
5. Relative Priority Test
6. Dynamic Adjustment Test

_(Each test must be passed for a proposed decoupling point placement to be viable. No further detail shown in this image — refer to Ptak & Smith Ch. 5 for full criteria.)_

---

## `drum-scheduling.jpg` — Scheduling a Drum

**Title:** Scheduling a Drum

- **"The drum is finitely scheduled with both MTS and MTO orders"**
- Loading is important to see for lead time quotation

### Drum Network Diagram

Two supply legs converge at a central Drum (D) resource:

```
Supplier → [Stock Buffer] → (C) → 10 → 5 → 10 → 5 ─────────────────────────────►
                                                        │
                                                       (D) Drum → 10 → 20 → (C) → Customer
                                                        │         (↑ replenishment orders)
Supplier → [Stock Buffer] → (C) → 5 → 10 → 15 → 10 ─►│
                                                       (C)
                                                        │
                                               Purchased Components
                                                        │
                                                   Suppliers
```

_(Numbers on arcs = routing step durations in time units)_

**Bar chart (top right):** Shows Sales Order Demand vs Capacity ceiling per period (periods 1–12). The drum is loaded over multiple periods; when near capacity, lead time quotation must reflect the queue.

**Key insight:** The drum (most loaded resource/constraint) is finitely scheduled first. Both MTS replenishment orders and MTO sales orders are loaded on the same drum to produce a realistic, achievable schedule.

---

## `flow-centric.jpg` — Two Different Views on Capacity

**Title:** Two Different Views on Capacity

Two capacity management philosophies shown side-by-side as bar charts (daily load, periods 1–11, with Total Capacity line):

### Flow-Centric (DDOM approach)

- **Buffer (G/Y/R) at the TOP of the capacity range**
- Normal operating load fills into the Green zone
- Variability spikes absorb into Yellow → Red zones (the buffer)
- Over-capacity zone is above Red (rare/emergency)
- Spare capacity is intentionally preserved — this IS the capacity buffer

### Cost-Centric (traditional approach)

- **G/Y/R inverted — Green at top of the normal range, Red near the floor**
- Machine utilisation is maximised; very little headroom
- Any variability spike immediately causes over-capacity (floating bottleneck)
- Unit cost appears lower but system responsiveness collapses

**Key insight:** Traditional manufacturing tries to eliminate spare capacity to reduce unit cost. DDOM deliberately preserves that spare capacity as a capacity buffer, which reduces lead times, WIP, and inventory — improving ROI even though unit cost per hour is higher on paper.

---

## `stock-buffers.jpg` — Stock Buffers

**Title:** Stock Buffers

### Zone Semantics

```
┌───────────────┐
│     GREEN     │ ← Order frequency and size (replenishment trigger zone)
│───────────────│
│    YELLOW     │ ← Primary coverage (typical on-hand operating range)
│───────────────│
│      RED      │ ← Safety (emergency reserve; penetration triggers alert)
└───────────────┘
```

### Buffer Sizing Formula

**Group Settings (Buffer Profiles)** × **Individual Part Properties** = **Zone and Buffer Levels for Each Part**

**Buffer Profile inputs:**

- Item Type (Purchased / Manufactured / Intermediate)
- Lead Time Category (Short / Medium / Long → Lead Time Factor, LTF)
- Variability Category (Low / Medium / High → Variability Factor, VF)

**Individual Part Properties:**

- Lead Time (DLT)
- Minimum Order Quantity (MOQ)
- Location (Distributed parts only)
- Average Daily Usage (ADU)

---

## `sync-material-release.jpg` — Synchronizing Material Release

**Title:** Synchronizing Material Release

**Rules:**

- **Schedule material release to the control point schedule**
- **Late release** will jeopardize the control point schedule
- **Early release** raises WIP levels unnecessarily

### Network Diagram

Same two-leg convergence at Drum (D) as in `drum-scheduling.jpg`, with **dashed orange circles** highlighting the material release gate at every control point feeding into the drum:

```
Supplier → [Stock] → (C gate) → 10 → 5 → 10 → 5 ─────►
                                                         (D) → 10 → 20 → (C) → Customer
Supplier → [Stock] → (C gate) → 5 → 10 → 15 → 10 ────►
                                                         (C)
                                                 Purchased Components
                                                         │
                                                    Suppliers
```

**Key insight:** Work orders are gated at control points and released only when the control point schedule calls for them — not when upstream capacity is available. This decouples upstream push scheduling from downstream pull scheduling, preventing WIP accumulation.

---

## `time-buffers.jpg` — Time Buffers (with Work Order Example)

**Title:** Time Buffers

### Time Buffer Zone Diagram

```
Variability
  (upstream)
      │
      ▼
[Upstream Processes]
      │
      │  WO 1595  ────────────────────────────────────► |
      │  WO 1781  ──────────────────────────────► |
      │  WO 1626  ────────────────────────────► |
      │  WO 1601  ────────────────────────► |
      │  WO 3279  ─────────────────► |
      │  WO 2001  ──────────────────────────────────────► |
      │
      ├── "Scheduled Entry to Buffer"             ├── "Scheduled Start at Control Point"
      ▼
◄──────────────Early───────────────►│Green│Yellow│Red│◄──Late──►
                                                              ↑
                                               Control Point (signal tower)
```

**Example:** 9 hour buffer (G+Y+R combined)

**Zone interpretations:**

- **Early** (blue): arrived well before scheduled entry — no action needed
- **Green**: on track
- **Yellow**: investigate (WO may be at risk)
- **Red**: ACT — risk of missing the control point scheduled start
- **Late** (dark red): already past scheduled control point start — expedite

---

## `time-buffers-2.jpg` — The 10-Zone Time Buffer Board

**Title:** The 10 Zone Time Buffer Board

### Two-Row Board: "Yet to Be Received" and "Received"

```
"Scheduled Entry to Buffer"         "Scheduled Start at Control Point"
         ▼                                        ▼

Yet to be Received:
[─── WO 1626 ──────────────────────────────────► | ]
                                     (currently in Yellow zone,
                                      projected to arrive at boundary
                                      between Yellow and Green)

◄──────────Early──────────────►│Green│Yellow│Red│◄──Late──►

Received:
[─── WO 1626 ──────────────────────────────────────────► | ]

◄──────────Early──────────────►│Green│Yellow│Red│◄──Late──►

Example: 9 hour buffer
```

**Zone action codes:**
| Zone | Action |
|---|---|
| Green | OK |
| Yellow | Investigate |
| Red | ACT |

**Key insight:** A work order is tracked on **two rows** — "Yet to Be Received" (before physical arrival at the buffer entry) and "Received" (after arrival, tracking progress through to the control point). The dashed arrow shows a WO moving from the upper row to the lower row after receipt, allowing the scheduler to see whether in-process WOs are likely to make the control point on time.

---

## `yet-to-be-recieved.jpg` — Yet to Be Received (LTM Alert Detail)

_(Filename is misspelled in original: "recieved")_

**Title:** _(shown as part of the DDOM Dashboard — Stability column)_

### "Yet to Be Received" and "Received" Status Bars

This is the **Lead Time Managed (LTM) alert** display:

```
Yet to Be Received:
Early │ Green │ Yellow │ Red │ Late

Received:
Early │ Green │ Yellow │ Red │ Late
```

**Color key (same as time buffers):**

- **Early/Blue**: arrived/progressed well ahead of schedule
- **Green**: on track
- **Yellow**: at risk — investigate
- **Red**: critical — take action
- **Late/Dark Red**: past due — escalate immediately

**Usage:** Each open supply order (PO/MO/TO) appears as a horizontal bar spanning from its creation date to its due date. The bar's position relative to the G/Y/R zones (which represent the last third of the lead time) determines urgency. The "Yet to Be Received" row tracks expected arrival; the "Received" row tracks what has already arrived and is in process.

---

## Summary: Visual Vocabulary Cross-Reference

| Symbol                   | Used in            | Meaning                                                                                                 |
| ------------------------ | ------------------ | ------------------------------------------------------------------------------------------------------- |
| Funnel (G/Y/R trapezoid) | Stock buffers      | Stock decoupling point: Green = replenishment trigger, Yellow = primary coverage, Red = safety          |
| Semi-circle (G/Y/R)      | Time buffers       | Control point time buffer: G/Y/R zones measure time-distance before scheduled control point start       |
| Vertical bar (G/Y/R)     | Capacity buffers   | Capacity buffer: load vs. sprint capacity ceiling; Red = sprint mode                                    |
| © symbol (circle C)      | Control points     | Control point: gating resource, convergence/divergence point, or notorious instability resource         |
| D symbol (circle D)      | Drum               | The drum: most loaded/constraining resource for finite scheduling                                       |
| Signal tower (antenna)   | Control/scheduling | Represents a control point emitting scheduling instructions (analogous to an air traffic control tower) |
| Red/over zone above bars | Capacity           | Over-capacity — danger zone; system cannot recover without variability-absorbing capacity               |
