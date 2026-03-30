---
description: Relational thinking — translating between natural-language questions and miniKanren relations, bidirectionally
---

You are working with the relational paradigm that underlies playnet's planning and knowledge layers. This skill teaches how to think relationally — translating questions to relations and relations back to questions.

## The core idea

A relation is a question with blanks.

When you write `(recipe-o facts ___ ___ "spec-bread")`, you're asking: "fill in the blanks for any recipe that produces bread." The system finds every combination of values that makes the statement true.

The same relation answers different questions depending on which positions are blanks and which are filled in:

| You ask | You write | Blanks filled |
|---|---|---|
| What recipe produces bread? | `(recipe-o facts rid name "spec-bread")` | rid, name |
| What does recipe-bread produce? | `(recipe-o facts "recipe-bread" name output)` | name, output |
| Does a recipe called "Bread Production" exist? | `(recipe-o facts rid "Bread Production" output)` | rid, output |
| List all recipes | `(recipe-o facts rid name output)` | rid, name, output |

One relation, four questions. No separate functions needed.

## Translating a question to a relation

1. **What domain?** Recipe, flow, demand, allocation, plan
2. **Pick the relation:**

| Domain | Relation | Positions |
|---|---|---|
| Recipe | `recipe-o` | facts, recipe-id, name, output-spec |
| Process chain | `chain-o` | facts, recipe-id, process-id-list |
| Process | `process-o` | facts, process-id, name, duration-ms |
| Flow | `flow-o` | facts, process-id, direction, spec-id, qty, unit, action |
| Allocation | `net-demand-o` | ctx, spec-id, qty, remaining, allocated |
| Demand | `demand-o` | ctx, spec-id, qty, due-date, plan-term |
| Full plan | `plan-o` | ctx, plan |

3. **What do you know?** Fill those positions with concrete values
4. **What are you asking?** Leave those as `fresh` variables (blanks)
5. **Wrap in `run-plan`:**

```scheme
(run-plan* ns (answer)
  (fresh (rid name)
    (recipe-o facts rid name "spec-bread")
    (== answer (list rid name))))
;; => (("recipe-bread" "Bread Production"))
```

## Translating a relation back to a question

Read the relation call. Ground values are "given that..." Fresh variables are "what..."

```scheme
(flow-o facts "rp-mill" 'input spec qty unit action)
```

→ "Given process rp-mill and direction input, what spec, quantity, unit, and action does it have?"

→ Plain English: "What goes into the milling process?"

## Combining questions

Two relations in the same `fresh` block = "and" (both must hold):

```scheme
;; "What recipe produces bread, and what wheat does milling need?"
(fresh (rid rname qty unit action)
  (recipe-o facts rid rname "spec-bread")
  (flow-o facts "rp-mill" 'input "spec-wheat" qty unit action))
```

`conde` = "or" (alternative answers):

```scheme
;; "What can we make — bread or flour?"
(conde
  ((recipe-o facts rid name "spec-bread"))
  ((recipe-o facts rid name "spec-flour")))
```

## How many answers?

- `(run-plan 1 ns (q) ...)` — first valid answer
- `(run-plan 5 ns (q) ...)` — up to five
- `(run-plan* ns (q) ...)` — all of them

For planning: `run-plan 1` finds one feasible plan. `run-plan*` finds every feasible plan. The greedy planner only ever found one.

## The demand question

The most important question the planner answers:

"Given that we need 20 bread by tomorrow, what's a plan to get it?"

```scheme
(run-plan 1 ns (plan)
  (demand-o ctx "spec-bread" 20 tomorrow plan))
```

The answer is a plan term — a nested structure showing what to do:

```scheme
(produce "spec-bread" "recipe-bread" 1
  (("spec-flour" (produce "spec-flour" ...
    (("spec-wheat" (satisfied "spec-wheat" 10 ...)))))
  ))
```

Or if we can't produce it:
```scheme
(purchase "spec-bread" 20)
```

Or if inventory covers it:
```scheme
(satisfied "spec-bread" 20 (("r-bread" "spec-bread" 20)))
```

The search finds all three possibilities. You choose.

## The allocation question

"If I need 80kg flour and only have 50kg, how much is left?"

```scheme
(run-plan 1 ns (q)
  (fresh (remaining allocated)
    (net-demand-o ctx "spec-flour" 80 remaining allocated)
    (== q remaining)))
;; => (30)
```

The netter tracks who claimed what. Each search branch gets its own allocation state — if a branch fails, its claims vanish. No undo logic needed.

## The full planning question

"Solve all open demands simultaneously":

```scheme
(run-plan 1 ns (plan)
  (plan-o ctx plan))
```

This is the entire planner. One relation call. It extracts demands from the plan store, tries every recipe and allocation ordering, and returns a plan that satisfies all demands — or proves none exists.

## Arithmetic: the one escape hatch

Pattern matching handles structure. But "10kg wheat times scale 2 = 20kg" needs arithmetic. The `project` syntax walks variables to their concrete values so you can compute:

```scheme
(project (qty scale)
  (let ((total (* qty scale)))
    (== result total)))
```

`project` appears at exactly two points in the planner: computing recipe scale factors, and back-scheduling process durations. Everything else is pure pattern matching.

## Fact shapes

Facts are plain tagged lists. No objects, no records, no classes.

```
(recipe  RID NAME PRIMARY-OUTPUT)
(chain   RID (PID1 PID2 ...))
(process PID NAME DURATION-MS)
(flow    PID DIRECTION SPEC-ID QTY UNIT ACTION)
```

They're lifted from VF records once at session start (`lift-planning-facts`), then queried relationally. The lift is the bridge between the Goblins actor world (recipe-store, observer) and the relational world (plain lists, pattern matching).

## Key files

| File | What it provides |
|---|---|
| `module/playnet/kanren-planning.scm` | ==, fresh, conde, project, in-list-o, run-plan, plan-ctx |
| `planner/lib/relational/planning-facts.scm` | lift-planning-facts, recipe-o, chain-o, process-o, flow-o |
| `planner/lib/relational/netter-goals.scm` | net-demand-o, net-supply-o, reserve-o |
| `planner/lib/relational/demand-relation.scm` | demand-o, produce-branch, solve-inputs-o |
| `planner/lib/relational/plan-relation.scm` | plan-o, all-demands-o, relational-plan |
| `RELATIONS.md` | The philosophy — why unification unifies social and material planning |

## The user's request

$ARGUMENTS
