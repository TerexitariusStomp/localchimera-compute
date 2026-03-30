---
description: ValueFlows economic planning engine — relational planning over lifted facts, allocation via netter goals
---

You are editing the ValueFlows economic planning engine — a relational planner built on miniKanren search over plain fact tuples, with allocation via a netter state monad threaded through the search.

## Architecture

```
schemas.scm        — 47 VF record types (source of truth)
     ↓ lift once at session start
planning-facts.scm — plain tuples: (recipe ...), (flow ...), (chain ...), (process ...)
     ↓ queried via in-list-o + unification
demand-relation.scm — demand-o explores all recipes via conde, recurses on inputs
plan-relation.scm   — plan-o solves all open demands simultaneously
netter-goals.scm    — net-demand-o threads allocation state through search
```

The planner is relational: facts are plain lists, queries are pattern matching with blanks, and the search explores all valid plans. `project` is used only for arithmetic (scale, scheduling). Everything else is pure unification.

## The six core relations

| Relation | Question it answers |
|---|---|
| `(recipe-o facts rid name output)` | What recipe produces this spec? |
| `(chain-o facts rid pids)` | What's the process chain for this recipe? |
| `(flow-o facts pid dir spec qty unit action)` | What flows in/out of this process? |
| `(net-demand-o ctx spec qty remaining allocated)` | How much is left after inventory allocation? |
| `(demand-o ctx spec qty due plan-term)` | What plan satisfies this demand? |
| `(plan-o ctx plan)` | What plan satisfies ALL open demands? |

## Key files

| File | Purpose |
|---|---|
| `module/playnet/kanren-planning.scm` | Extended miniKanren: state = (subst counter . netter), project, in-list-o, plan-ctx |
| `planner/lib/relational/planning-facts.scm` | Lift VF records → tuples. Fact relations + arithmetic helpers |
| `planner/lib/relational/netter-goals.scm` | Allocation goals: net-demand-o, net-supply-o, reserve-o |
| `planner/lib/relational/demand-relation.scm` | Core: demand-o, produce-branch, solve-inputs-o |
| `planner/lib/relational/plan-relation.scm` | Orchestrator: plan-o, all-demands-o, relational-plan |
| `planner/lib/relational/load-relational.scm` | Module loader |
| `planner/lib/schemas.scm` | 47 VF record types (unchanged) |
| `planner/lib/scope-root.scm` | Coordinator wiring stores into a vat (unchanged) |
| `planner/lib/planning/plan-federation.scm` | Multi-scope federation fold (unchanged) |
| `planner/load-all.scm` | Dependency-order loader |

## Common editing patterns

**Add a fact type:** Add to the `lift-planning-facts` function in `planning-facts.scm`. Define a new relation (one line: `in-list-o` over the facts list).

**Add a planning relation:** Define in `demand-relation.scm` or a new file. Use `fresh`, `==`, `conde` from `(playnet kanren-planning)`. Access facts via the `ctx-facts` field of the planning context.

**Bridge to arithmetic:** Use `project` to walk logic variables to ground values, then do Scheme computation:
```scheme
(project (qty scale)
  (let ((total (* qty scale)))
    (== result total)))
```

**Add a store method:** Modify the relevant store actor in `planner/lib/`. The lift function in `planning-facts.scm` will need updating to extract the new data.

## Planning context

```scheme
(make-plan-ctx facts plan-store observer location-store plan-id)
```

`facts` = lifted tuples for relational queries. `plan-store` + `observer` = Goblins actors for netter allocation (imperative). Goals receive a single `ctx` argument instead of 5+ store references.

## Testing

```bash
cd planner && guile --no-auto-compile -q -L ../module -l load-all.scm -l tests/relational-planner.scm
```

## The user's request

$ARGUMENTS
