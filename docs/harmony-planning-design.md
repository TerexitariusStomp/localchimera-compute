# Harmony-Based Planning: Design Document

## Overview

Replace the zone-based DDMRP decision machinery and greedy allocation
strategy with a **weighted harmony function** that guides resource
distribution across the federation. The relational (miniKanren + CLP(FD))
framework stays as the structural feasibility layer. Harmony becomes the
optimization objective expressed as a composable relation, enabling both
proportional allocation under scarcity and relational "why" queries over
plan trade-offs.

## Where Harmony Applies

Harmony operates at **three distinct levels**, each doing a different
job. The critical insight is that harmony is fundamentally an
**output-level measure** — it evaluates how well independent demands
(final consumption, external orders) are satisfied. Intermediate
resource allocation is a *consequence* of output-level harmony, not an
independent objective.

### Level 1: Federation rebalancing (primary)

This is where harmony does its real work. When scopes compete for
shared resources, harmony answers: "if scope A gives up flour so scope
B can make bread, does bread's harmony gain outweigh cake's harmony
loss?"

Harmony is computed over **independent demands** — the final outputs
that people actually want. The federation compares the output-level
harmony of different allocation strategies across scopes and steers
toward the one that maximizes total weighted harmony.

This replaces the current priority-ordered retraction and
advance-worst heuristics in `federation.scm` and
`plan-federation.scm`.

### Level 2: Within-plan allocation (derived)

When multiple production branches within a scope compete for the same
intermediate resource (flour needed for both bread and cake), the
allocation decision is **derived from downstream output harmony**.

The right question is not "what is flour's harmony?" — flour has no
independent demand, so it has no harmony goal. The right question is:
"which downstream output has the lowest harmony, and therefore should
get priority access to flour?"

The labeling heuristic in `allocation.scm` traces intermediate
resources to their downstream independent demands and allocates based
on *those* harmony scores. This replaces greedy max-first labeling
with harmony-guided labeling, but the signal flows backward from
outputs, not from intermediates.

Intermediates that *also* have independent demand (e.g., natural gas
used both industrially and domestically) do get their own harmony
evaluation for the independent-demand portion.

### Level 3: Plan evaluation and explanation (read-only)

After a plan is produced, harmony provides a single legible score for
plan quality and enables relational queries:

- "What is the total harmony of this plan?"
- "Show the trade-offs between plan A and plan B"
- "Why did scope A get less flour than scope B?"

This level does not drive decisions — it answers questions. It
composes Level 1 and Level 2 scores into explanations.

### What this means for intermediates and buffers

Buffers sit mostly at intermediate positions in the BOM. They don't
participate in harmony evaluation (no independent demand, no harmony
goal). But they still need an internal planning signal — the whole
point of a decoupled buffer is *proactive* replenishment before
downstream production is affected.

This is handled by a **buffer gap signal**, separate from harmony:

```
buffer_gap = (safety_stock - inventory) / safety_stock
```

When `buffer_gap > 0`, the buffer is below target and the internal
planner generates a replenishment order proportional to the gap. This
is a continuous replacement for what zones did: instead of "red →
replenish immediately, yellow → plan ahead, green → do nothing," the
signal is a smooth gradient from 0 (fully stocked) to 1 (empty).

The buffer gap signal operates **within a plan** — it's part of the
internal planning engine for a single scope. It does not participate
in harmony evaluation or cross-scope federation decisions.

**Two separate concerns, two separate levels:**

- **Within a plan**: buffer gap signal drives proactive intermediate
  replenishment. "Flour is at 60% of safety stock → generate
  replenishment order for 40%." Mechanical, proportional, continuous.
- **Across plans / across scopes**: harmony over independent demands
  drives federation rebalancing. "Bread harmony in scope B is lower
  than cake harmony in scope A → reallocate resources toward scope B."

These interact but don't collapse: if flour replenishment succeeds,
bread production is protected and bread harmony stays high. If flour
replenishment *fails* (upstream supply constraint), bread's projected
output falls, bread harmony drops, and the federation responds. The
buffer gap provides proactive internal planning; harmony provides
reactive cross-scope rebalancing. Both are needed.

This replaces the current zone-based multi-pass structure
(Pass 0 buffer evaluation → Pass 1 TOY-gated demand → Pass 2
replenishment → Pass 1b retry) with a simpler model: compute buffer
gaps, generate proportional replenishment orders, allocate via BOM
explosion with harmony-guided labeling for competing demands.

## Core Concepts

### The Harmony Function

Per-spec evaluation of how well output meets its goal:

```
u = (output - goal) / goal

deficit (u < 0):  harmony = -(u^2)
surplus (u >= 0): harmony = sqrt(u)
```

Deficits are penalized quadratically (shortages hurt more than surpluses
help). Surpluses yield diminishing returns. This shape forces
proportional distribution under scarcity — giving 50/50 to two equal
demands always produces higher total harmony than 80/20.

### Weighted Harmony

Each spec's raw harmony is multiplied by a single **priority weight**:

```
weighted_harmony(spec) = priority(spec) * raw_harmony(spec)
```

**Priority weight** is governance-set, per resource spec, exponentially
scaled. Examples: bread = 1000, clothing = 100, Porsche = 1.

Priority is attached to the **resource specification** by governance,
not to buffers or zones. It is a social decision about how much the
community values this output. Specs without buffers still have
priority. Independent demands always have priority.

There is no separate urgency weight. The harmony function itself
already encodes urgency continuously — a spec that is deeply
underfulfilled (u far below 0) generates a quadratically larger
penalty than one that is slightly underfulfilled. Priority scales
*how much the system cares*, and the curve shape encodes *how urgent
the current situation is*. Two weights would double-count urgency.

Harmony applies only to specs with **independent demand** (see "Where
Harmony Applies" above). Intermediate resources that exist only to
feed production have no harmony goal — their allocation is derived
from downstream output harmony.

### Asymmetric Deficit/Surplus Weighting

The deficit and surplus sides of the curve can be weighted differently
per priority tier:

- Essentials (high priority): steep deficit penalty, moderate surplus
  reward. Fight hard to prevent bread shortages, but don't over-produce
  at the expense of everything else.
- Luxuries (low priority): gentle deficit penalty, gentle surplus reward.
  Don't panic about Porsche shortages, but don't ignore them either.

This produces continuous, humane outcomes: "everyone gets bread, and
there's still some cake" rather than all-or-nothing priority cutoffs.

## Relationship: Resource Specs, Buffers, and Harmony

### Only independent demands have harmony

The harmony function applies to **resource specs with independent
demand** — final outputs that people actually want (bread, housing,
clothing, Porsches). Each independently-demanded spec has:

- A **goal** (target output quantity + safety stock if buffered)
- A **priority** (governance-set social importance)
- A **harmony curve** (the universal shape above, weighted by priority)

Intermediate resources (flour, steel, electricity used in production)
do **not** have their own harmony. Their allocation is derived from
the harmony of downstream outputs they feed. Flour's "importance" is
entirely determined by what it produces — if it feeds bread
(priority 1000), it gets allocated accordingly. No separate harmony
evaluation is needed or desirable.

Exception: some resources have **both** intermediate and independent
demand (e.g., natural gas used industrially and domestically). The
independent-demand portion gets a harmony evaluation; the
intermediate-demand portion is derived from downstream output harmony.

### Buffers contribute safety stock to the harmony goal

A buffer is a **physical protection mechanism** — actual inventory held
to absorb real-world variability (equipment failure, demand spikes,
supply delays). Buffers can exist at any point in the BOM, including
both intermediate and output positions.

For specs with independent demand, the buffer's safety stock is added
to the harmony goal:

```
harmony_goal(spec) = independent_demand(spec) + safety_stock(spec)
```

Where `safety_stock = ADU * DLT * variability_factor` for buffered
specs, and `safety_stock = 0` for unbuffered specs.

For intermediate specs, the buffer is driven by the **buffer gap
signal** (see "Where Harmony Applies" above): a continuous measure of
how far current inventory is from the safety stock target. When the
gap is positive, the internal planner generates proportional
replenishment orders. This is proactive — it fires before downstream
output is affected. If replenishment fails despite the gap signal,
downstream output harmony drops and the federation responds.

The buffer no longer generates zone-based planning signals
(red/yellow/green). For output-level specs, the harmony function
provides the continuous urgency signal. For intermediate specs, the
buffer gap signal drives proactive internal replenishment, and
harmony propagates urgency backward from outputs when needed.

### Independent demands

Independent demands (final consumption, external orders) are the
**primary objects of harmony evaluation**. They have a goal quantity,
a priority, and a harmony function. They are not reframed as buffers.

However, for specs with variable or uncertain independent demand, a
safety stock buffer may be warranted. The decision of whether to
buffer a spec is a strategic positioning question (currently handled
by `positioning.scm`) and remains separate from the harmony
evaluation.

### What buffers become

Buffers reduce to:

- A **safety stock quantity** — computed from variability protection
  + lead-time consumption + batch minimum (if applicable). See
  "Continuous buffers" under Design Decisions for the simplified
  formula. DOC-based order cycle coverage is dropped as a
  capitalist supply chain artifact.
- A **continuous gap signal** — `(safety_stock - inventory) /
  safety_stock`. Any positive gap generates proportional
  replenishment demand within the plan.
- A **decoupling point** in the BOM (DLT computation stops here)
- A **recalibration schedule** (periodically recompute safety stock
  from fresh ADU and DLT)

They no longer have zones, zone-based alerts, or zone-driven
planning behavior.

For output-level buffers, the safety stock feeds the harmony goal.
For intermediate buffers, the gap signal drives proactive internal
replenishment, and harmony propagates urgency backward from outputs
when replenishment fails.

## Architecture

### Layer 1 — Structural Relations + Buffer Gap Signal

miniKanren + CLP(FD) determines what is physically feasible:

- BOM/recipe explosion (`dependent-demand.scm`, `dependent-supply.scm`)
- Skill matching (`skill-matcher.scm`)
- Durable input resolution, container mediation
- Recipe selection by SNE
- Inventory existence and location constraints
- **Buffer gap signal**: for buffered intermediate specs, compute
  `(safety_stock - inventory) / safety_stock` and generate
  proportional replenishment demands. This replaces the zone-based
  Pass 0/Pass 2 replenishment logic with a continuous, proportional
  mechanism internal to the plan.

This layer answers: "what allocations are possible, and what
intermediate replenishment is needed?"

### Layer 2 — Harmony Evaluation (new)

A set of composable relations that evaluate plans over their
**independent demands** (not intermediates):

- `harmony-o goal output h` — raw harmony for one independent demand
- `weighted-harmony-o spec goal output priority h` — priority-weighted
- `plan-harmony-o plan facts total-h` — total harmony across all
  independent demands in the plan
- `harmony-diff-o plan-a plan-b facts explanation` — relational
  trade-off trace: which outputs gained/lost harmony and why

These are expressible in miniKanren (forward-biased via `project` for
the arithmetic, but composable with structural relations for queries).

Key queries this enables:
- "What is the total harmony of this plan?"
- "Which independent demand has the lowest harmony?" (where to focus)
- "If we move N units of X from scope A to scope B, how does total
  harmony change?" (trade-off evaluation)
- "What reallocations would raise total harmony above threshold T?"
- "Show the trade-offs between plan A and plan B" (relational diff)
- "Why did this reallocation improve harmony?" (provenance trace
  from output-level harmony through BOM to intermediate allocation)

### Layer 3 — Harmony-Guided Search (replaces greedy heuristics)

The current search heuristics are replaced with harmony-guided variants.
The key principle: **harmony is computed at the output/independent-demand
level, and propagates backward through the BOM to guide intermediate
allocation.**

#### Federation rebalancing (primary application)

**Current**: `advance-worst` advances the child with the largest raw
deficit quantity. `retract-across-scopes` sacrifices lowest-priority
demands first.

**New**: Advance the child with the lowest weighted output harmony.
Retract the candidate whose removal would produce the largest increase
in total weighted harmony across independent demands. The retraction
structure (netter state restoration, surplus generation, lateral
re-matching) stays unchanged — only the ordering criterion changes.

This is the primary site of harmony optimization. The federation
compares output-level harmony across scopes to decide where resources
should flow.

#### Within-plan allocation (derived application)

**Current**: `(labelfd take #:order 'max)` — greedily take the maximum
from each resource.

**New**: When multiple production branches compete for the same
intermediate resource, trace each branch to its downstream independent
demand(s) and label toward the allocation that best equalizes their
output-level harmonies.

For example: if flour feeds both bread (harmony = -0.8, priority =
1000) and cake (harmony = -0.2, priority = 10), the labeling favors
bread's branch because its weighted harmony deficit is far larger.
The intermediate allocation is a *consequence* of output-level
harmony, not an independent optimization.

This replaces the Cockshott shave-top/fill-bottom with a
BOM-aware variant: rather than equalizing harmony at one level, the
signal propagates backward through the recipe graph.

## Advantages of Continuous Planning in a Socialist System

The planned economy context changes the trade-offs around continuous
vs. discrete signals in ways that favor continuity.

### What continuity gains

**Responsiveness.** Without discrete zones gating replenishment, the
system responds to any deviation from target immediately and
proportionally. A 5% dip generates a 5% replenishment signal. In
zoned systems, that same dip might fall within the green zone and
generate nothing — until it accumulates past a threshold and
triggers a large corrective action. Continuous signals avoid the
sawtooth pattern of "ignore, ignore, ignore, panic."

**No artificial batching pressure.** Zone thresholds create implicit
batch incentives — wait until you cross a boundary, then order a big
chunk. In a planned system where production can be scheduled
flexibly, there is no reason to batch artificially. Steady, even
production flows that match actual consumption patterns reduce peak
demand on production capacity and smooth workloads for workers.

**Richer information for the planner.** A zone tells you "red" or
"yellow" — 1.5 bits of information. A continuous gap tells you "37%
below target." When two intermediates both need replenishment, the
planner knows one is 37% depleted and the other is 12% depleted,
rather than knowing they're both "yellow." This enables finer-grained
allocation decisions.

**Proportionality under scarcity.** If upstream capacity can't fully
replenish all buffers simultaneously, continuous gap signals let the
planner distribute replenishment proportionally — fill each buffer
toward its target at the same rate. Zones can't express this: two
"red" buffers look equally urgent even if one is at 5% and the other
at 25%.

**Coherent system language.** The continuous buffer gap mirrors the
continuous harmony function at the output level. Same mathematical
character at both levels — proportional signals, no discrete jumps.
The whole system speaks one language.

### Why this works in a planned economy but not a market

In a capitalist supply chain, discrete zones exist for good reasons:

- Each replenishment is a **purchase order** with transaction costs
  (communication, negotiation, shipping overhead). Frequent small
  orders are expensive. Batching is economically rational.
- **Information opacity** between firms means you can't coordinate
  production smoothly — you order what you think you'll need and
  buffer against uncertainty about your supplier's behavior.
- **MOQ and pricing incentives** (volume discounts) reward larger,
  less frequent orders.

In a planned economy, none of these apply:

- Replenishment is a **signal within the plan**, not a purchase order.
  No transaction costs, no supplier negotiation overhead.
- **Information transparency** across the planning network means
  production can be coordinated directly.
- No volume discounts or pricing distortions. Production costs are
  computed from labour time and material inputs.

The friction that justified discrete batching disappears. Continuous
signals become not just possible but preferable.

### Constraints and engineering concerns

**Production granularity.** Some processes can't produce in arbitrary
quantities (you can't bake 3.7 loaves, a kiln fires in batches).
But this is a **recipe constraint**, not a buffer constraint. The
continuous signal says "I need 3.7 loaves worth of replenishment"
and the recipe says "minimum batch is 50 loaves." The planner
resolves the tension. The buffer doesn't need to know about it.

**Planning frequency.** Continuous signals assume the planner runs
frequently enough to act on small deviations. If planning runs
once a week, a 5% gap signal on Monday might be irrelevant by
Friday. For playnet, the planner runs within a live system —
planning frequency is high and this is not a practical concern.

**Oscillation / stability.** A potential concern: continuous signals
reacting to tiny fluctuations could create oscillation — constantly
adjusting production up and down in response to noise. Zones provide
natural hysteresis because you don't react until you cross a
threshold.

However, the **variability factor (VF) already provides damping.**
The safety stock target is sized to absorb normal fluctuations —
that's what the variability protection component is for. Under
normal variance, inventory fluctuates *within* the safety stock
range, so `buffer_gap` hovers near zero and generates minimal
signal. The gap signal only fires meaningfully when inventory drops
below what the variability math says is safe. The variability factor
is the damping. No additional hysteresis mechanism is needed.

If in practice the signal proves too noisy for specific specs with
high-variance demand, a rolling average on the gap signal can smooth
it — but this should be the exception, not the default.

## What Changes

### New files

- `planner/lib/relational/harmony.scm` — harmony relations
  (`harmony-o`, `weighted-harmony-o`, `plan-harmony-o`,
  `harmony-diff-o`). ~100 lines.

### Modified files

- `planner/lib/relational/allocation.scm` — replace `#:order 'max`
  labeling with harmony-guided labeling. Constraint structure unchanged.

- `planner/lib/relational/federation.scm` — `advance-worst` sorts by
  weighted harmony instead of deficit quantity. `retraction-stream` and
  `retract-one-stream` order candidates by harmony impact instead of
  raw priority.

- `planner/lib/planning/plan-federation.scm` — `retract-across-scopes`
  ordering changes from priority sort to harmony-impact sort. Lateral
  matching unchanged.

- `planner/lib/planning/plan-for-unit.scm` — remove TOY guard in Pass 1
  (zone-based deferral). Remove zone-based planning pass structure.
  Multi-pass pipeline simplifies: BOM explosion + allocation guided by
  harmony, without zone-gated passes.

- `planner/lib/algorithms/ddmrp.scm` — remove zone computation and
  zone-based alert logic. Keep: ADU computation, DLT computation
  (`compute-decoupled-lead-time`, `recipe-lead-time`, `leg-lead-time`),
  buffer size computation (but outputting a single safety-stock quantity
  rather than zone levels). Keep: recalibration logic (fresh ADU/DLT
  recomputation). Remove: NFP zone classification, zone-based order
  generation, zone alert system.

- `planner/lib/relational/ddmrp.scm` — simplify `buffer-zone-fact-o` to
  emit safety-stock quantity rather than TOR/TOY/TOG levels.

- `planner/lib/relational/compute.scm` — keep DLT and ADU computation.
  Remove `compute-buffer-zone-levels`, zone-based projections, zone
  alert functions. Add safety-stock computation.

- `planner/lib/relational/control.scm` — update signal generation to
  use harmony scores rather than zone states.

- `planner/lib/utils/demand-priority.scm` — simplify to return
  governance-set priority weight per spec. Remove buffer-tier/zone
  composite priority computation.

- `planner/lib/schemas.scm` — simplify `<buffer-zone>` record: remove
  zone-level fields (TOR, TOY, TOG), keep safety-stock, DLT, ADU, MOQ.
  Or rename to `<buffer>` / `<safety-stock>`.

### Removed machinery

- Buffer zone levels (TOR, TOY, TOG) as planning signals
- Zone-based demand deferral (TOY guard in Pass 1 / Pass 1b retry)
- Zone-based alert system (red/yellow/green alerts)
- NFP (Net Flow Position) zone classification
- Buffer-tier priority computation (ecological/metabolic/equilibrium/
  consumption as priority source — priority now comes directly from
  governance)
- `strategy.scm` — subsumed by harmony objective (the "which strategy
  is best" question is answered by "whichever maximizes total harmony")

### Unchanged

- BOM explosion (`dependent-demand.scm`, `dependent-supply.scm`)
- Skill matching (`skill-matcher.scm`)
- Netter state monad (`netting.scm`) — still tracks commitments
- Recipe store and process chains
- Scope hierarchy construction
- DLT and ADU computation
- Buffer sizing math (ADU * DLT * factors → safety stock quantity)
- Buffer positioning (`positioning.scm`)
- Decoupling point logic (DLT stops at buffer boundaries)

## Design Decisions

### Universal harmony curve (not per-spec)

The harmony curve shape is **universal** — the same mathematical form
(quadratic deficit penalty, square-root surplus reward) applies to all
resource specs with independent demand. Differentiation between specs
comes entirely from the **priority weight**, not from the curve shape.

Rationale:

- The curve encodes diminishing marginal utility, which is a general
  economic principle that applies to bread and Porsches alike.
- If per-spec curve shapes were allowed, the curve shape would become
  a hidden priority mechanism — a steeper curve for bread does the
  same thing as a higher priority weight, but it's harder for
  governance to reason about and compare across specs.
- A universal curve keeps harmony scores comparable: -0.3 always means
  "30% underfulfilled, quadratic penalty" regardless of spec. Priority
  weight tells you how much that matters.
- One shape, one meaning, governance controls the weight.

### Independent demands are not buffers

Independent demands and buffers are categorically different:

- **Independent demand** = "people want 100 loaves of bread." A social
  fact (consumption, orders, governance targets). This is the *goal*
  that harmony evaluates against.
- **Buffer** = "keep 20 extra loaves on hand for variability." A
  physical protection mechanism computed from ADU, DLT, and
  variability factors.

They combine additively: `harmony_goal = demand + safety_stock`. But
collapsing them would lose the ability to distinguish "we need more
bread because people are hungry" from "we need more bread because our
safety margin is thin" — different situations requiring different
responses (increase production vs. reduce supply chain variability).

Not every independent demand needs a buffer (a one-time order for 50
ceremonial cakes needs no safety stock). Not every buffer has
independent demand (a flour buffer decouples the BOM, nobody
independently wants flour). They are orthogonal.

### Continuous buffers (no zones)

Buffer zones (red/yellow/green) are removed as decision thresholds.
The planning system operates on continuous signals: harmony for
outputs, buffer gap for intermediates.

#### Safety stock computation

The safety stock formula simplifies for a planned economy. In
capitalist DDMRP, the three zones encode:

```
Red    = ADU * DLT * LTF * (1 + VF)       — variability protection
Yellow = Red + ADU * DLT                   — lead-time consumption
Green  = Yellow + max(ADU*DOC, red, MOQ)   — order cycle coverage
```

The **green zone's order cycle component (DOC) dissolves** in a
planned system. DOC represents "we place orders every N days" — a
transaction-cost concern from purchasing economics. In a planned
economy, replenishment is a signal within the plan, not a purchase
order. There are no transaction costs, no supplier negotiations, no
ordering overhead. Planning can run continuously.

What remains:

```
safety_stock = variability_protection     (ADU * DLT * LTF * VF)
             + lead_time_consumption      (ADU * DLT)
             + batch_minimum              (MOQ, only if production
                                           has genuine batch
                                           constraints — e.g.,
                                           kiln firings, minimum
                                           viable batch sizes)
```

- **Variability protection** — still real. Crops fail, machines break,
  weather disrupts transport regardless of economic system.
- **Lead-time consumption** — still real. Production takes time
  regardless of who coordinates it.
- **Batch minimum (MOQ)** — only applies when production has physical
  batch constraints. Many processes in a planned economy can run at
  any scale, eliminating this component. Where batch constraints
  exist (e.g., a bread oven holds 50 loaves minimum), MOQ stays as
  a production constraint expressed in recipes, not as a buffer
  parameter.

#### Continuous buffer gap signal

Without order cycle economics, the main justification for discrete
replenishment gates disappears. The buffer gap signal is genuinely
continuous:

```
buffer_gap = (safety_stock - inventory) / safety_stock
```

Any positive gap generates a proportional replenishment signal in
the plan. No thresholds, no gates. If production requires batching,
that's handled by batch-size constraints in recipes, not by the
buffer artificially gating replenishment into discrete chunks.

This is cleaner than zones for a planned system: the buffer says
"I need this much" and the planner figures out how and when to
produce it, respecting production constraints.

#### Dashboard presentation

For human communication, the buffer state can be presented as a
continuous fill level or quantized for readability:

```
if buffer_gap > 0.67  → display "critical"
if buffer_gap > 0.33  → display "low"
if buffer_gap > 0     → display "replenishing"
if buffer_gap <= 0    → display "stocked"
```

This is a **UI concern**, not a planning concern. The planning engine
works on continuous signals. Dashboards quantize for humans.

## Migration Path

### Phase 1: Add harmony evaluation alongside existing system

- Implement `harmony.scm` with the core relations
- Wire `plan-harmony-o` into federation results so harmony scores are
  emitted alongside existing deficit/surplus signals
- No behavior change — harmony is computed but does not drive decisions
- Validate that harmony scores correlate with plan quality as expected

### Phase 2: Replace labeling and search heuristics

- Change `allocation.scm` labeling from `#:order 'max` to
  harmony-guided
- Change `advance-worst` to use harmony scores
- Change retraction ordering to use harmony impact
- Compare plan quality (measured by harmony) against Phase 1 baseline
- Zone machinery still present but no longer driving decisions

### Phase 3: Remove zone machinery

- Strip TOY guard and zone-based pass structure from `plan-for-unit.scm`
- Simplify buffer records to safety-stock quantities
- Remove zone alert system
- Remove NFP classification
- Remove buffer-tier priority (replace with governance-set priority)
- Update tests

### Phase 4: Relational trade-off queries

- Implement `harmony-diff-o` for plan comparison
- Enable governance queries: "what would happen if we changed bread
  priority from 1000 to 500?"
- Build explanation traces: "why did scope A get less flour than scope B?"
