# Planner

A ValueFlows economic planning system built on Goblins actors in Guile Scheme.

See [architecture.md](architecture.md) for the full system design.
See [../docs/ARCHITECTURE-EXPLAINED.md](../docs/ARCHITECTURE-EXPLAINED.md) for
how Goblins scopes, the relational solver, and infrastructure resources fit together.

## Requirements

- [GNU Guile](https://www.gnu.org/software/guile/) 3.0+
- [Goblins](https://spritely.institute/goblins/) (Spritely Institute)

## Running tests

```sh
./run-tests.sh
```

Or individually:

```sh
cd planner
guile --no-auto-compile -q -L ../module -l load-all.scm -l tests/<test-file>.scm
```

## Structure

```
planner/
├── lib/                        Source modules (~16k lines)
│   ├── schemas.scm             Layer 0: 47 VF record types
│   ├── store-utils.scm         Layer 0: hashmap helpers
│   ├── scope-root.scm          Layer 1: vat coordinator
│   ├── agents.scm              Layer 1: agent store
│   ├── process-registry.scm    Layer 1: process registry
│   ├── knowledge/              Layer 1: knowledge stores
│   │   ├── recipes.scm         Recipe store (specs, processes, flows)
│   │   ├── buffer-zones.scm    DDMRP buffer zones
│   │   ├── capacity-buffers.scm
│   │   ├── spatial-things.scm
│   │   ├── buffer-snapshots.scm
│   │   └── federation-recipes.scm
│   ├── observation/            Layer 1: observer + accounts + infrastructure
│   │   ├── observer.scm        5-phase event fold kernel
│   │   ├── account.scm         Commune labor-credit accounting
│   │   ├── live-resource.scm   Infrastructure as live actors
│   │   └── live-registry.scm   Resource-id → live-resource registry
│   ├── execution/              Execution engine
│   │   ├── alerts.scm          Alert store (append-only)
│   │   ├── monitors.scm        Reactive monitors (buffer status, ADU)
│   │   ├── scope-execution.scm Record-and-monitor dispatch
│   │   └── capacity-execute.scm  Capacity-managed execution primitives
│   ├── planning/               Layer 1+2+4: planning + federation
│   │   ├── planning.scm        Plan store (intents, commitments, plans)
│   │   ├── plan-for-unit.scm   Multi-pass orchestrator
│   │   ├── store-registry.scm  Cross-scope qualified refs
│   │   └── ...
│   ├── algorithms/             Layer 2: pure planning algorithms
│   │   ├── propagation.scm     Duration, SNLT
│   │   ├── sne.scm             Socially Necessary Effort
│   │   ├── ddmrp.scm           Buffer zone formulas
│   │   ├── signals.scm         Signal ↔ intent conversion
│   │   ├── netting.scm         State monad netter
│   │   ├── dependent-demand.scm  BFS demand unfold
│   │   ├── dependent-supply.scm  BFS supply unfold
│   │   └── ...
│   └── relational/             Relational planner (miniKanren + CLP(FD))
│       ├── planning-facts.scm  Lift VF records to tuples, indexes
│       ├── allocation.scm      Buffer-aware CLP(FD) allocation
│       ├── demand-relation.scm Core demand → plan-term relation
│       ├── plan-relation.scm   Orchestrate all demands
│       ├── federation.scm      Lazy-stream federated search
│       └── ...
├── tests/                      39 test files
├── architecture.md             Full system design
├── load-all.scm                Load all modules in dependency order
└── run-tests.sh                Run all test suites
```

## Infrastructure as economic resources

Infrastructure resources (compute, memory, storage, bandwidth) are economic
resources that are also Goblins actors. The observer tracks total capacity via
VF events. The `^live-resource` actor tracks available capacity via
reserve/release. The planner sees available capacity in inventory facts.

### Live-resource actors (`lib/observation/live-resource.scm`)

```scheme
;; Spawn a compute resource in the scope's vat
(let ((live (spawn ^live-resource "cpu-1" "spec:compute" 16 16 "cpu-hours" "dc-1" '())))
  ($ ($ scope 'live-registry) 'register "cpu-1" live))

;; The planner now sees (inventory "cpu-1" "spec:compute" 16 "dc-1")
;; When 4 hours are reserved, it sees 12 instead of 16
```

### Capacity-managed execution (`lib/execution/capacity-execute.scm`)

Three composable procedures for doing real work with infrastructure:

```scheme
;; Simple: reserve, do work, release (guaranteed cleanup via dynamic-wind)
(with-capacity compute-ref 4
  (lambda () (http-post transcription-url audio-data)))

;; Multi-resource: reserve compute + memory, do work, release all
(with-resources `((,compute-ref . 4) (,memory-ref . 8))
  (lambda () (run-inference model input)))

;; With VF event recording (atomic within one vat turn)
(execute-with-event observer
  `((,compute-ref "cpu-1" "spec:compute" 4 "cpu-hours")
    (,memory-ref "mem-1" "spec:memory" 8 "GB"))
  (lambda () (transcribe audio-file))
  #:process-id "proc-transcribe-1"
  #:provider "agent:cluster")
```

### Current limitations

The capacity reservation is an **economic accounting tool**, not a physical
enforcement mechanism. `with-capacity` reserves hours/GB in the planning layer
and guarantees cleanup, but does not enforce cgroup limits, memory quotas, or
CPU pinning on the underlying hardware. The planning layer coordinates
allocation; the social layer (governance) enforces compliance; the observer
records what actually happened.

What remains to be built:

- **Physical enforcement**: bridge to cgroups, WASM memory limits, or
  container resource constraints so reservations map to real OS-level quotas
- **Async work dispatch**: currently all execution is synchronous within a vat
  turn. Long-running tasks need `<-` (async) dispatch to worker actors with
  completion callbacks that release capacity and record events
- **Cross-scope orchestration**: federation plans identify surplus/deficit
  across scopes, but the execution of cross-scope resource transfers (browser
  requesting server compute) needs OCapN integration with the capacity
  primitives
