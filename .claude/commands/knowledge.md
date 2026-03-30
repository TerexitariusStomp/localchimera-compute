---
description: Knowledge layer — miniKanren logic, relational queries, transitive closure with proof traces, Hoot-compatible
---

You are editing the knowledge layer — standalone, Hoot-compatible modules providing logic programming, relational queries over plain fact lists, and transitive closure with proof traces. No Goblins dependency. No external libraries.

## Key files

| File | Purpose |
|---|---|
| `module/playnet/kanren.scm` (~219 lines) | miniKanren from scratch: microKanren + Zzz + reification + occurs check |
| `module/playnet/knowledge.scm` (~60 lines) | in-list-o, generic transitive-o with proof traces |
| `module/playnet/system-kb.scm` (~100 lines) | System self-knowledge as plain facts + relations |

## miniKanren exports (kanren.scm)

`var`, `var?`, `==`, `fresh`, `conde`, `run`, `run*`, `appendo`, `membero`, `Zzz`, `conj`, `disj`

Interleaving search with depth suspension via `Zzz`. Full occurs check.

## Knowledge utilities (knowledge.scm)

**in-list-o** — membership in a concrete Scheme list. The fundamental relation for querying plain fact tuples:

```scheme
(in-list-o `(depends ,from ,to) facts)  ;; find matching facts
```

**transitive-o** — generic depth-bounded transitive closure with proof traces. Takes any edge relation as parameter:

```scheme
(transitive-o edge-o start end trace)
;; edge-o: (lambda (from to) goal)
;; trace: (start mid1 ... end)
```

Not tied to any data structure — works over any binary relation.

## System knowledge base (system-kb.scm)

Plain tagged tuples — no constructors, no wrappers:

```scheme
*system-facts*  ;; list of:
  (depends browser evaluator)
  (file actors "module/playnet/actors.scm")
  (provides goblins capability-security)
```

Relations:

```scheme
(depends-on-o 'browser q)          ;; what does browser depend on?
(file-of-o 'planner q)             ;; what files does planner have?
(provides-o 'goblins q)            ;; what does goblins provide?
(trigger-chain-o 'push-to-main 'guix proof)  ;; transitive dependency chain
```

Every relation works bidirectionally. `(depends-on-o q 'goblins)` finds everything that depends on goblins.

## Common editing patterns

**Add a system fact:** Add a tuple to `*system-facts*` in `system-kb.scm`. Tagged: `(depends ...)`, `(file ...)`, `(provides ...)`.

**Add a relation:** Define using `in-list-o` over the fact list:

```scheme
(define (my-relation-o x y)
  (in-list-o `(my-tag ,x ,y) *system-facts*))
```

**Add a transitive query:** Pass an edge relation to `transitive-o`:

```scheme
(define (my-chain-o start end proof)
  (transitive-o my-edge-o start end proof))
```

**Hoot compatibility:** Uses only lambdas, pairs, alists, `syntax-rules`. No vectors, no GOOPS, no keywords.

## Relationship to the relational planner

Both use the same miniKanren core over plain fact tuples:

- **Knowledge layer** (this skill): system self-knowledge — dependencies, files, capabilities. Uses `(playnet kanren)` (Hoot-compatible).
- **Relational planner** (`/planner` skill): economic planning — recipes, flows, demands, allocation. Uses `(playnet kanren-planning)` which extends kanren.scm with netter state.

Same pattern, same fact shape, same `in-list-o`. The planner adds allocation state threading; the knowledge layer stays pure logic.

## Testing

```bash
guile --no-auto-compile -q -L module tests/test-knowledge.scm  # 48 tests
```

## The user's request

$ARGUMENTS
