# Free Association — Guile Scheme Architecture

A ValueFlows economic planning system built on Goblins actors, organized into
four layers. 25 modules, ~8,500 lines of Scheme, 105 test checks.

## System diagram

```
                    ┌─────────────────────────────────────┐
                    │        Layer 4: Federation           │
                    │                                      │
                    │  plan-federation    store-registry    │
                    │  (hierarchy fold)   (qualified refs)  │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────┴──────────────────────┐
                    │      Layer 2: Planning Algorithms     │
                    │                                       │
                    │  plan-for-unit ── plan-for-scope      │
                    │       │      └── plan-for-region      │
                    │       │                                │
                    │  dependent-demand   dependent-supply   │
                    │  (BFS unfold)       (BFS unfold)       │
                    │       │                  │             │
                    │    netting (state monad)               │
                    │       │                                │
                    │  propagation  sne  ddmrp  signals      │
                    └──────────────┬─────────────────────────┘
                                   │
                    ┌──────────────┴──────────────────────┐
                    │     Layer 1: Store Actors (Goblins)   │
                    │                                       │
                    │  scope-root (coordinator)              │
                    │    ├── recipe-store     (7 hashmaps)   │
                    │    ├── agent-store      (3 hashmaps)   │
                    │    ├── observer         (fold kernel)  │
                    │    ├── plan-store       (10 hashmaps)  │
                    │    ├── buffer-zone-store               │
                    │    ├── account-store    (commune)      │
                    │    ├── capacity-buffer-store            │
                    │    ├── spatial-thing-store              │
                    │    ├── snapshot-store   (append-only)  │
                    │    └── alert-store      (append-only)  │
                    └──────────────┬─────────────────────────┘
                                   │
                    ┌──────────────┴──────────────────────┐
                    │     Layer 0: VF Record Types          │
                    │                                       │
                    │  schemas.scm — 47 immutable records   │
                    │  store-utils.scm — hashmap helpers    │
                    └───────────────────────────────────────┘
```

## Layer 0 — Record types (`schemas.scm`, 2160 lines)

The ValueFlows ontology as Guile `make-record-type` definitions. All fields
immutable. Optional fields hold `#f`. Enums are symbols with validation predicates.

**47 record types** organized by VF layer:

| Category | Records |
|----------|---------|
| **Temporal** | `<time-range>`, `<day-schedule>`, `<week-schedule>`, `<month-schedule>`, `<availability-window>`, `<specific-date-window>` |
| **Primitives** | `<measure>`, `<duration>`, `<unit>`, `<spatial-thing>`, `<batch-lot-record>` |
| **Actions** | `<action-definition>` + `*action-definitions*` alist (19 VF actions) |
| **Agents** | `<agent>`, `<agent-relationship-role>`, `<agent-relationship>` |
| **Knowledge** | `<resource-specification>`, `<process-specification>`, `<positioning-analysis>`, `<decoupling-test-entry>`, `<decoupling-test-result>`, `<capacity-buffer>`, `<recipe-flow>`, `<recipe-process>`, `<recipe-exchange>`, `<recipe>`, `<recipe-group>` |
| **Observation** | `<economic-resource>`, `<economic-event>`, `<process>` |
| **Planning** | `<intent>`, `<commitment>`, `<claim>`, `<plan>`, `<scenario-definition>`, `<scenario>`, `<agreement>`, `<agreement-bundle>`, `<proposal>`, `<proposal-list>` |
| **DDMRP** | `<buffer-profile>`, `<buffer-zone>`, `<replenishment-signal>`, `<demand-adjustment-factor>` |
| **Tracking** | `<fulfillment-state>`, `<satisfaction-state>`, `<claim-state>`, `<buffer-snapshot>`, `<account>` |

**`store-utils.scm`** provides `hashmap-values`, `hashmap-filter`, `hashmap-find`,
`serialize-hashmap`/`deserialize-hashmap` (for persistence), `generate-id`,
`iso-datetime->epoch`.

## Layer 1 — Store actors (10 actors + coordinator)

Each store is a Goblins `define-actor` with:
- Immutable state transitioned via `bcom`
- `methods` macro for message dispatch
- `#:portrait` / `#:restore` / `#:version` for persistence
- Record-to-list converters for serialization (Goblins can't persist raw Guile records)

### `^scope-root` — the coordinator

Wires all stores into a single Goblins vat. A scope (organization, commune,
ecological agent) IS a vat. All stores are near (same vat), so operations
within a scope are synchronous and transactional (single turn = all-or-nothing).

```scheme
(define-values (vat scope)
  (spawn-persistent-vat scope-env
    (lambda () (spawn-scope "Riverside Commune"))
    (make-memory-store)))

(with-vat vat
  ($ ($ scope 'observer) 'record-event some-event)  ;; synchronous, transactional
  ($ ($ scope 'plan-store) 'add-intent some-intent))
```

### `^observer` — the fold kernel

The Observer is architecturally a **left fold**: `(fold event->state events initial-state)`.

Each event is folded through a 5-phase pipeline:

```
phase-append-event  →  phase-index-event  →  phase-apply-effects
                                              →  phase-implied-transfer
                                                  →  phase-track
```

Each phase is a pure function. No `set!`. The `<fold-ctx>` record carries the
observer state + affected-resources accumulator through phases 3-4. The actor's
`bcom` IS the fold's commit step.

```scheme
(define (observer-record-event st event)
  (let* ((def (get-action-def (economic-event-action event)))
         (st  (phase-append-event st event))
         (st  (phase-index-event  st event))
         (ctx (make-fold-ctx st '()))
         (ctx (phase-apply-effects    ctx event def))
         (ctx (phase-implied-transfer ctx event def))
         (st  (phase-track (ctx-state ctx) event)))
    (values st (reverse (ctx-affected ctx)))))
```

### `^plan-store` — planning layer

Holds all planning artifacts: intents, commitments, plans, agreements, claims,
proposals, scenarios. Maintains secondary indexes (tag-index, intents-by-spec,
commitments-by-spec) for O(k) lookups.

Key operation: `promote-to-commitment` — elevates an Intent (unilateral) to a
Commitment (bilateral) when offer meets request.

### `^account-store` — commune labor-credit system

Implements the SNLT-based elastic claim capacity system:
- Pools: named SVC pools (individual-claimable, replenishment, etc.)
- Accounts: per-agent gross-contribution, claimed-capacity, capacity-factor
- Derived: welfare allocation rate, contribution claims, solidarity supplements
- All derived properties computed on the fly from two hashmaps

### Persistence

Every store actor serializes via `#:portrait` (converts records to lists of
Goblins-native types) and deserializes via `#:restore`. Persistence round-trips
verified by spawning a fresh vat from the same memory-store.

```scheme
;; Save
(define-values (vat scope)
  (spawn-persistent-vat scope-env (lambda () (spawn-scope "Test")) store))

;; ... use the scope ...

;; Restore (spawn from same store — state fully recovered)
(define-values (vat2 scope2)
  (spawn-persistent-vat scope-env (lambda () (error "should restore!")) store))
```

## Layer 2 — Planning algorithms (10 modules)

All pure functions. They read from store actors via synchronous `$` calls
within a Goblins turn and return VF records. No actor state changes inside
the algorithms.

### Foundation (no store dependencies)

| Module | Functions | Pattern |
|--------|-----------|---------|
| **propagation.scm** | `rp-duration-ms`, `rp-duration-days`, `compute-snlt`, `create-flow-record` | Duration conversion, SNLT per-output-unit |
| **sne.scm** | `build-sne-index`, `compute-recipe-sne`, `compute-sne-for-recipe` | SNE = direct labor + embodied labor + depreciation |
| **ddmrp.scm** | `compute-adu`, `compute-nfp`, `compute-buffer-zone-levels`, `recalibrate-buffer-zone`, `buffer-status`, `generate-replenishment-signal`, `prioritized-share`, ... | Ptak & Smith Ch 7-9 formulas |
| **signals.scm** | `signal->intent`, `intent->signal`, `*plan-tags*` | Bidirectional isomorphism: typed signal alist ↔ VF Intent |

### Core planning

| Module | Pattern | Description |
|--------|---------|-------------|
| **netting.scm** | **State monad** | Immutable `<netter-state>` record. Each operation returns `(values new-state result)`. Fork = identity (free). Retract = restore saved state. |
| **dependent-demand.scm** | **Unfold** (BFS) | Seed: (spec, qty, due). Unfolds into processes, commitments, intents by back-scheduling recipes. Stops at DDMRP decoupling points. |
| **dependent-supply.scm** | **Unfold** (BFS) | Dual of demand. Forward-schedules supply through consuming recipes. Unabsorbed supply → surplus signals. |

### Orchestration

**`plan-for-unit.scm`** — the multi-pass planner (compiler pipeline):

```
Demands (source)
  → Normalize (deduplicate IDs)
  → Extract (demand/supply slots from stores)
  → Classify (locally-satisfiable / transport / producible / external)
  → Formulate (multi-pass explosion + netting)
      Pass 1: Explode primary demands via dependent-demand
      Supply:  Forward-schedule via dependent-supply
      Deficit/Surplus signal emission
  → Collect (emit signals to plan-store)
```

**`plan-for-scope.scm`** and **`plan-for-region.scm`** are thin wrappers that
configure spatial normalization policies, then delegate to `plan-for-unit`.

## Layer 4 — Federation (2 modules)

### `^store-registry` — cross-scope namespace

A Goblins actor mapping scope IDs to plan-store actor references. Supports:
- **Qualified references**: `"scope-id::record-id"` → parse, lookup, return
- **Cross-scope tag queries**: `intents-for-tag` aggregates across all scopes
- **Near/far transparency**: near stores via `$`, remote via `<-` (OCapN-ready)

### `plan-federation.scm` — hierarchical planning

The federation planner is a **monoidal fold** over the scope hierarchy:

```scheme
(plan-federation scope-ids horizon ctx plan-scope-fn
  #:parent-of parent-of #:registry registry)
```

1. **`build-hierarchy`** — construct children-of + topological sort (post-order DFS)
2. **`fold-scopes`** — plan each scope bottom-up, children before parents
3. **`match-laterally`** — greedy score-based surplus↔deficit matching across peers

## Categorical structure

The architecture embodies several FP patterns that Scheme makes explicit:

| Component | Pattern | Why it matters |
|-----------|---------|----------------|
| Observer | **Left fold** | Replay, branch, checkpoint at any point |
| Dependent demand/supply | **Unfold** | Dual of fold — grows structure from a seed |
| PlanNetter | **State monad** | Fork = identity, retract = restore, no copy overhead |
| Buffer zone formulas | **Catamorphism** | Profile IS the F-algebra; TOR/TOY/TOG are the carrier |
| Signal round-trip | **Isomorphism** | Lossless Intent ↔ typed signal conversion |
| Recipe chain | **Free monad** | Same syntax tree, two interpreters (back/forward schedule) |
| Scope merge | **Monoid** | Associative merge; empty scope = identity |
| VF action table | **Tagless final** | Effects defined by algebra, not syntax; swappable interpreters |
| Whole planner | **Compiler pipeline** | Demands → classify → explode → net → schedule → emit |

The meta-insight: **`bcom` is the fold's commit step**. Each message to an actor
is one fold iteration. The actor framework enforces the fold discipline — you
can't skip states or mutate sideways. This is why Scheme + Goblins is the right
target: the planner IS a metacircular evaluator for economic coordination programs.

## Complexity

All hashmap operations (get, set, remove) are O(log32 n) via HAMT, which is
effectively O(1) for practical sizes.

### Secondary indexes

Store actors maintain secondary index hashmaps alongside primary data.
Indexes are maintained on every add/remove and used for O(log n) queries:

| Store | Index | Enables |
|-------|-------|---------|
| **Observer** | `idx-by-spec` (spec-id -> resource-ids) | `conforming-resources` O(log n) instead of O(R) |
| **Observer** | `idx-by-resource/process/agent/action` (id -> event-ids) | All event queries O(log n) |
| **Recipe Store** | `idx-flows-by-input/output` (process-id -> flow-ids) | `flows-for-process` O(log n) instead of O(F) |
| **Recipe Store** | `idx-recipes-by-output` (spec-id -> recipe-ids) | `recipes-for-output` O(log n) instead of O(R) |
| **Plan Store** | `intents/commitments-by-plan` (plan-id -> ids) | Plan queries O(log n) instead of O(I)/O(C) |
| **Plan Store** | `commitments-by-process` (process-id -> ids) | Process query O(log n) instead of O(C) |
| **Plan Store** | `tag-index`, `*-by-spec` | Tag/spec queries O(log n) |

### Key algorithms

| Algorithm | Complexity | Notes |
|-----------|-----------|-------|
| `record-event` (observer fold) | O(log n) | 5 phases, each O(log n) hashmap ops |
| `get-process-chain` (topo sort) | O(P^2 + E) | Kahn's algorithm with indexed flow lookups |
| `dependent-demand` (BFS unfold) | O(B * P) | B = BFS breadth, P = processes per recipe |
| `compute-nfp` | O(log n + C) | Indexed `conforming-resources` + commitment scan |
| `match-laterally` | O(S^2) | Greedy offer x request matching (S = scopes) |

### Remaining O(n) operations (acceptable)

- `open-intents`, `offers`, `requests` — composite predicates, not indexable
- `inventory` — filters on dynamic quantity values
- `compute-adu` — must scan events in time window

## File inventory

```
src/lib/
├── schemas.scm                          2,160 lines  Layer 0: 47 record types
├── store-utils.scm                        109 lines  Layer 0: shared helpers
├── scope-root.scm                          86 lines  Layer 1: vat coordinator
├── agents.scm                             177 lines  Layer 1: ^agent-store
├── knowledge/
│   ├── buffer-zones.scm                   210 lines  Layer 1: ^buffer-zone-store
│   ├── buffer-snapshots.scm                96 lines  Layer 1: ^snapshot-store
│   ├── capacity-buffers.scm                96 lines  Layer 1: ^capacity-buffer-store
│   ├── recipes.scm                        548 lines  Layer 1: ^recipe-store (+ flow indexes)
│   └── spatial-things.scm                  68 lines  Layer 1: ^spatial-thing-store
├── observation/
│   ├── observer.scm                       684 lines  Layer 1: ^observer (fold + spec index)
│   └── account.scm                        249 lines  Layer 1: ^account-store
├── execution/
│   └── alerts.scm                          84 lines  Layer 1: ^alert-store
├── planning/
│   ├── planning.scm                       552 lines  Layer 1: ^plan-store (+ plan/process indexes)
│   ├── plan-for-unit.scm                  315 lines  Layer 2: orchestrator
│   ├── plan-for-scope.scm                  38 lines  Layer 2: scope wrapper
│   ├── plan-for-region.scm                 34 lines  Layer 2: region wrapper
│   ├── store-registry.scm                  93 lines  Layer 4: ^store-registry
│   └── plan-federation.scm                180 lines  Layer 4: federation planner
└── algorithms/
    ├── propagation.scm                    144 lines  Layer 2: duration, SNLT
    ├── sne.scm                            139 lines  Layer 2: SNE index
    ├── ddmrp.scm                          509 lines  Layer 2: DDMRP algorithms
    ├── signals.scm                        211 lines  Layer 2: signal conversion
    ├── netting.scm                        207 lines  Layer 2: pure state monad netter
    ├── dependent-demand.scm               226 lines  Layer 2: BFS demand unfold
    └── dependent-supply.scm               236 lines  Layer 2: BFS supply unfold

tests/
├── scope-integration.scm                  407 lines  48 checks: full VF lifecycle
├── algorithms-foundation.scm              333 lines  37 checks: DDMRP, SNLT, SNE
└── planning-federation.scm                280 lines  20 checks: 3-scope federation

Total: 25 modules + 3 test files = 8,471 lines, 105 checks
```
