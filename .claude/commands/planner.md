---
description: ValueFlows economic planning engine — algorithms, stores, federation, DDMRP, recipes
---

You are editing the ValueFlows economic planning engine — a complete supply-chain planning system built on Goblins actors. 20+ algorithm modules, ~14,000 lines, 105+ test checks. Independent of the playnet governance kernel.

## Architecture

```
Layer 0: schemas.scm (47 VF record types) + store-utils.scm
Layer 1: scope-root.scm (coordinator), agents.scm, knowledge/, observation/, execution/
Layer 2: algorithms/ (20+ modules: netting, DDMRP, critical-path, propagation, etc.)
Layer 3: planning/ (plan store, orchestration, scheduling)
Layer 4: planning/plan-federation.scm (multi-scope hierarchy fold)
Bridge:  bridge/mqtt-bridge.scm (event bridge to Mosquitto)
```

## Key files

| File                                          | Purpose                                                                            |
| --------------------------------------------- | ---------------------------------------------------------------------------------- |
| `planner/lib/schemas.scm`                     | 47 immutable VF record types (EconomicEvent, Process, ResourceSpecification, etc.) |
| `planner/lib/scope-root.scm`                  | `^scope-root` — coordinator wiring 10 stores into a vat                            |
| `planner/lib/algorithms/netting.scm`          | Demand/supply netting with location awareness                                      |
| `planner/lib/algorithms/ddmrp.scm`            | Demand-driven MRP buffer positioning                                               |
| `planner/lib/algorithms/critical-path.scm`    | Critical path analysis                                                             |
| `planner/lib/algorithms/propagation.scm`      | Constraint propagation                                                             |
| `planner/lib/algorithms/flow-graph.scm`       | Network flow analysis                                                              |
| `planner/lib/algorithms/dependent-demand.scm` | BOM explosion / dependent demand                                                   |
| `planner/lib/algorithms/dependent-supply.scm` | Supply chain upstream analysis                                                     |
| `planner/lib/algorithms/signals.scm`          | Signal generation for planning events                                              |
| `planner/lib/algorithms/sne.scm`              | Synchronized netting engine                                                        |
| `planner/lib/algorithms/track-trace.scm`      | Custody chain tracking                                                             |
| `planner/lib/algorithms/value-equations.scm`  | Value flow equations                                                               |
| `planner/lib/planning/planning.scm`           | Plan store + orchestration                                                         |
| `planner/lib/planning/plan-federation.scm`    | Multi-scope federation (hierarchy fold)                                            |
| `planner/lib/planning/schedule-book.scm`      | Schedule management                                                                |
| `planner/lib/bridge/mqtt-bridge.scm`          | MQTT event bridge to Mosquitto                                                     |
| `planner/load-all.scm`                        | Module dependency order loader                                                     |

## Common editing patterns

**Add a record type:** Add to `schemas.scm` — define constructor, accessors, and serialization. Follow existing `define-record-type` patterns.

**Add an algorithm:** New file in `planner/lib/algorithms/`. Pure functions operating on VF records. Add to `load-all.scm` dependency order.

**Add a store method:** Modify the relevant store actor in `planner/lib/`. Update `^scope-root` if the new method needs cross-store coordination.

**Load order is critical.** `load-all.scm` and `run-tests.sh` define the module dependency order. Adding a file in the wrong position causes load failures.

## Relationship to playnet

The planner is independent of the playnet governance kernel. A planning scope IS a Goblins vat. Scopes communicate via OCapN. The planner could be injected into an playnet org as a capability ref — the org governs access, the planner does computation.

## Testing

```bash
cd planner && ./run-tests.sh  # 105+ checks
```

## The user's request

$ARGUMENTS
