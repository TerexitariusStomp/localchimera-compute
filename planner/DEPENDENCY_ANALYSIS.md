# SCHEME CODEBASE DEPENDENCY ANALYSIS REPORT

## EXECUTIVE SUMMARY

**STATUS: ALL DEPENDENCIES PROPERLY RESOLVED**

The Scheme codebase follows a well-structured layered dependency model with clear separation of concerns. All symbol references are properly defined before use, and the load order in `load-all.scm` correctly respects these dependencies.

---

## 1. LOAD ORDER AND LAYERS

### Layer 0: Schemas & Utilities (FOUNDATION)
```
(load "lib/schemas.scm")              Line 7
(load "lib/store-utils.scm")          Line 8
```
**No dependencies** - These are loaded first.

**Key exports:**
- `schemas.scm`: All economic entity record types (economic-event, economic-resource, 
  commitment, intent, process, etc.) plus helper functions
- `store-utils.scm`: 
  - Hashmap helpers: hashmap-values, hashmap-keys, hashmap-filter, hashmap-filter-pairs, 
    hashmap-map-values, hashmap-count, hashmap-find, hashmap-any?
  - ID generation: generate-id
  - ISO datetime parsing: iso-datetime->epoch

---

### Layer 1: Store Actors (PERSISTENT STATE)
```
Lines 11-25: Process registry, knowledge stores (buffer-zones, capacity-buffers, 
spatial-things, recipes, federation-recipes, etc.)
Lines 19-25: Observation stores (observer, account, transition, demand-policy)
Line 24: Planning store
Line 25: Scope root
```
**Depends on:** Layer 0 (uses schemas + hashmap utilities)

---

### Layer 2: Core Algorithms
```
(load "lib/algorithms/propagation.scm")      Line 28  ← FOUNDATION FOR OTHERS
(load "lib/algorithms/sne.scm")              Line 29
(load "lib/algorithms/ddmrp.scm")            Line 30
(load "lib/algorithms/signals.scm")          Line 31
(load "lib/algorithms/netting.scm")          Line 32
(load "lib/algorithms/dependent-demand.scm") Line 33  ← USES propagation + netting
(load "lib/algorithms/dependent-supply.scm") Line 34  ← USES propagation + netting
```

**Depend on:** Layer 0 + Layer 1 schemas

**Key exports and dependencies:**

#### propagation.scm (Line 28)
- **Defines:**
  - rp-duration-ms / rp-duration-days (recipe process duration conversion)
  - compute-snlt (Socially Necessary Labour Time)
  - create-flow-record (scales recipe flows into intents/commitments)
- **Uses:** schemas.scm, store-utils.scm

#### netting.scm (Line 32)
- **Defines:**
  - netter-net-demand (net demand against inventory)
  - netter-net-supply (deduct claimed consumptions)
  - netter-reserve (pre-claim capacity)
  - netter-net-available (query available qty without claiming) ← **Used in plan-for-unit.scm:144**
  - netter-fork (fork state - identity for immutable)
  - netter-retract (restore state)
  - <netter-state> record type
- **Uses:** propagation.scm (implicitly via signals), signals.scm, schemas.scm
- **Key:** Implements pure state monad for soft allocation tracking

#### signals.scm (Line 31)
- **Defines:**
  - signal->intent (converts typed signal alists to Intent + metadata) ← **Used in plan-for-unit.scm:351**
  - intent->signal
- **Uses:** schemas.scm

#### dependent-demand.scm (Line 33)
- **Depends on:** propagation.scm (creates flow records), netting.scm, signals.scm, schemas.scm
- **Defines:** dependent-demand function
- **Key:** BFS demand explosion through bill of materials
- **Used in:** plan-for-unit.scm:147, plan-for-unit.scm:190, plan-for-unit.scm:217

#### dependent-supply.scm (Line 34)
- **Depends on:** propagation.scm (create-flow-record, rp-duration-ms), 
  netting.scm (netter-net-supply), schemas.scm
- **Defines:** dependent-supply function ← **Used in plan-for-unit.scm:225**
- **Key:** BFS supply absorption through recipes

---

### Layer 2 Extended: Additional Algorithms
```
(load "lib/algorithms/critical-path.scm")    Line 37
(load "lib/algorithms/shortest-path.scm")    Line 38
(load "lib/algorithms/network-flow.scm")     Line 39
(load "lib/algorithms/flow-graph.scm")       Line 40  ← scope-of-agent IS A PARAMETER
(load "lib/algorithms/custody.scm")          Line 41
(load "lib/algorithms/otif.scm")             Line 42
(load "lib/algorithms/metabolism.scm")       Line 43
(load "lib/algorithms/positioning.scm")      Line 44
(load "lib/algorithms/track-trace.scm")      Line 45
(load "lib/algorithms/value-equations.scm")  Line 46
(load "lib/algorithms/rollup.scm")           Line 47
(load "lib/algorithms/resource-flows.scm")   Line 48
```

**Notable:**
- critical-path.scm uses iso-datetime->epoch
- track-trace.scm **defines trace function** ← used in value-equations.scm:89
- value-equations.scm uses trace, iso-datetime->epoch

---

### Layer 2 Orchestration: Planning Algorithms
```
(load "lib/planning/plan-for-unit.scm")      Line 51  ← MAIN ORCHESTRATOR
(load "lib/planning/plan-for-scope.scm")     Line 52
(load "lib/planning/plan-for-region.scm")    Line 53
```

#### plan-for-unit.scm (Line 51)
- **Depends on:** ALL previous layers
  - Uses dependent-demand, dependent-supply
  - Uses signal->intent (from signals.scm)
  - Uses netter-reserve, netter-net-available (from netting.scm)
  - Uses buffer-status (from ddmrp.scm - Line 30 ✓ loads first)
  - Uses measure-qty (from observer.scm - Line 20 ✓ loads first)
  - Uses iso-datetime->epoch (from store-utils.scm)

---

## 2. CRITICAL QUESTIONS ANSWERED

### Q1: Does dependent-demand.scm use `create-flow-record`? Where is it defined?
**ANSWER:** YES
- Defined in: **propagation.scm (Line 28)**
- Used in: dependent-demand.scm (multiple locations)
- Load order: propagation.scm (Line 28) → dependent-demand.scm (Line 33) ✓

### Q2: Does plan-for-unit.scm use `signal->intent`? Where is it defined?
**ANSWER:** YES
- Defined in: **signals.scm (Line 31)**
- Used in: plan-for-unit.scm:351
- Load order: signals.scm (Line 31) → plan-for-unit.scm (Line 51) ✓

### Q3: Does plan-for-unit.scm use `dependent-supply`? Where is it defined?
**ANSWER:** YES
- Defined in: **dependent-supply.scm (Line 34)**
- Used in: plan-for-unit.scm:225
- Load order: dependent-supply.scm (Line 34) → plan-for-unit.scm (Line 51) ✓

### Q4: Does plan-for-unit.scm use `netter-reserve`, `netter-net-available`? Are they in netting.scm?
**ANSWER:** YES for all
- Defined in: **netting.scm (Lines 214 and 228)**
- Used in: plan-for-unit.scm:118 (netter-reserve), plan-for-unit.scm:144 (netter-net-available)
- Load order: netting.scm (Line 32) → plan-for-unit.scm (Line 51) ✓

### Q5: Does ddmrp.scm use `rp-duration-days`, `rp-duration-ms`? Where defined?
**ANSWER:** YES
- Defined in: **propagation.scm (Lines 22, 36)**
- Used in: ddmrp.scm:152
- Load order: propagation.scm (Line 28) → ddmrp.scm (Line 30) ✓

### Q6: Does flow-graph.scm use `scope-of-agent`? Is it a parameter or a dependency?
**ANSWER:** PARAMETER, NOT A DEPENDENCY
- `scope-of-agent` is a **procedure parameter** to build-flow-graph (Line 8):
  ```scheme
  (define (build-flow-graph events scope-of-agent . rest)
    "scope-of-agent: procedure (agent-id) -> scope-id."
  ```
- Caller provides the implementation
- No external dependency to load

### Q7: Does value-equations.scm call `trace`? Is it from track-trace.scm?
**ANSWER:** YES
- Defined in: **track-trace.scm (Line 45)**
- Used in: value-equations.scm:89
- Load order: track-trace.scm (Line 45) → value-equations.scm (Line 46) ✓

### Q8: Does critical-path.scm use `iso-datetime->epoch`? Where defined?
**ANSWER:** YES
- Defined in: **store-utils.scm (Line 8)**
- Used in: critical-path.scm:31
- Load order: store-utils.scm (Line 8) → critical-path.scm (Line 37) ✓

### Q9: Do files use `hashmap-filter` or `hashmap-values`? Are these defined in store-utils.scm or goblins?
**ANSWER:** Both
- **Defined in store-utils.scm:**
  - hashmap-filter (Line 21)
  - hashmap-values (Line 13)
  - Other helpers: hashmap-keys, hashmap-filter-pairs, hashmap-map-values, etc.
- **Used throughout:** planning.scm, observer.scm, knowledge stores, indexes, agents, etc.
- **Also from Goblins:** (goblins utils hashmap) provides hashmap primitives
  - Used via import in all files that need it

---

## 3. SYMBOL DEFINITION INVENTORY

### Defined Symbols by File

#### store-utils.scm
- hashmap-values
- hashmap-keys
- hashmap-filter ← used widely
- hashmap-filter-pairs
- hashmap-map-values
- hashmap-count
- hashmap-find
- hashmap-any?
- serialize-hashmap
- deserialize-hashmap
- generate-id
- iso-datetime->epoch ← used in 10+ files

#### propagation.scm
- rp-duration-ms ← used in dependent-demand, dependent-supply, ddmrp, positioning, sne
- rp-duration-days ← used in ddmrp, dependent-demand, positioning, sne
- compute-snlt ← used in dependent-demand, dependent-supply
- create-flow-record ← used in dependent-demand, dependent-supply, planning

#### netting.scm
- <netter-state> record
- netter-net-demand
- netter-net-supply
- netter-reserve ← used in plan-for-unit.scm:118
- netter-net-available ← used in plan-for-unit.scm:144
- netter-fork
- netter-retract

#### signals.scm
- signal->intent ← used in plan-for-unit.scm:351
- intent->signal

#### ddmrp.scm
- compute-adu
- compute-forward-adu
- buffer-status ← used in plan-for-unit.scm:99
- compute-nfp

#### track-trace.scm
- trace ← used in value-equations.scm:89
- track

#### observer.scm
- measure-qty ← used in plan-for-unit.scm:98

---

## 4. RUNTIME ACTOR METHOD INVOCATIONS

All Goblins `$` calls are used correctly with actor methods available in corresponding stores:

### Observer methods used:
- 'conforming-resources
- 'all-resources
- 'get-resource
- 'get-event
- 'events-for-process
- 'events-for-resource

### Plan Store methods used:
- 'open-intents
- 'intents-for-spec
- 'commitments-for-spec
- 'commitments-for-plan
- 'add-intent
- 'set-meta
- 'add-plan

### Recipe Store methods used:
- 'recipes-for-output
- 'recipes-for-input
- 'get-recipe
- 'processes-for-recipe
- 'flows-for-process
- 'get-process-chain
- 'get-process-spec

### Buffer Zone Store methods used:
- 'all-zones

---

## 5. UNDEFINED SYMBOLS FOUND

**NONE** - All symbols are properly defined before use.

---

## 6. DEPENDENCY GRAPH (CRITICAL PATH)

```
Layer 0 (Foundations)
├─ schemas.scm
└─ store-utils.scm

Layer 1 (Stores)
├─ observer.scm (provides: measure-qty)
├─ planning.scm
├─ knowledge/*.scm

Layer 2a (Core Algorithms - CRITICAL)
├─ propagation.scm (provides: rp-duration-*, create-flow-record)
├─ signals.scm (provides: signal->intent)
├─ netting.scm (provides: netter-*)
├─ ddmrp.scm (provides: buffer-status, compute-adu)

Layer 2b (Algorithm Consumers)
├─ dependent-demand.scm (uses: create-flow-record, netting, signals)
└─ dependent-supply.scm (uses: create-flow-record, netting, rp-duration-*)

Layer 2c (Extended Algorithms)
├─ track-trace.scm (provides: trace)
└─ value-equations.scm (uses: trace)

Layer 3 (Orchestration)
└─ plan-for-unit.scm (uses: everything above)
```

---

## 7. LOAD ORDER VERIFICATION

All dependencies respect the following invariant:
**A symbol is never used before it is defined in the load order.**

Critical dependencies verified:
- ✓ propagation.scm loaded before all its consumers
- ✓ signals.scm loaded before plan-for-unit.scm
- ✓ netting.scm loaded before plan-for-unit.scm
- ✓ dependent-demand.scm, dependent-supply.scm loaded before plan-for-unit.scm
- ✓ ddmrp.scm loaded before plan-for-unit.scm
- ✓ track-trace.scm loaded before value-equations.scm
- ✓ observer.scm loaded before plan-for-unit.scm

---

## CONCLUSION

The codebase has **NO UNDEFINED SYMBOL GAPS**. All dependencies are properly declared via:
1. Load order in load-all.scm
2. Comments documenting assumptions (e.g., "Assumes schemas.scm, store-utils.scm are loaded")
3. Use of Goblins hashmap utilities properly imported

The architecture follows clear layering with no circular dependencies or forward references.
