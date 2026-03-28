# Planner

A ValueFlows economic planning system built on Goblins actors in Guile Scheme.

See [architecture.md](architecture.md) for the full system design.

## Requirements

- [GNU Guile](https://www.gnu.org/software/guile/) 3.0+
- [Goblins](https://spritely.institute/goblins/) (Spritely Institute)

## Running tests

```sh
./run-tests.sh
```

Or individually:

```sh
guile --no-auto-compile -q \
  -l lib/schemas.scm -l lib/store-utils.scm \
  -l lib/knowledge/buffer-zones.scm -l lib/knowledge/capacity-buffers.scm \
  -l lib/knowledge/spatial-things.scm -l lib/knowledge/recipes.scm \
  -l lib/knowledge/buffer-snapshots.scm -l lib/agents.scm \
  -l lib/execution/alerts.scm -l lib/observation/observer.scm \
  -l lib/observation/account.scm -l lib/planning/planning.scm \
  -l lib/scope-root.scm \
  -l tests/scope-integration.scm
```

## Structure

```
planner/
├── lib/                    Source modules
│   ├── schemas.scm         Layer 0: 47 VF record types
│   ├── store-utils.scm     Layer 0: hashmap helpers
│   ├── scope-root.scm      Layer 1: vat coordinator
│   ├── agents.scm          Layer 1: agent store
│   ├── knowledge/          Layer 1: knowledge stores
│   ├── observation/        Layer 1: observer + accounts
│   ├── execution/          Layer 1: alert store
│   ├── planning/           Layer 1+2+4: plan store + orchestration + federation
│   └── algorithms/         Layer 2: pure planning algorithms
├── tests/                  Test suites (105 checks)
├── architecture.md         Full system design
├── load-all.scm            Load all modules in dependency order
└── run-tests.sh            Run all test suites
```
