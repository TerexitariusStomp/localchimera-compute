---
description: Knowledge layer — miniKanren logic, hyperarc metagraphs, relational queries, Hoot-compatible
---

You are editing the knowledge layer — three standalone, Hoot-compatible modules providing logic programming, metagraph data structures, and relational queries. No Goblins dependency. No external libraries.

## Key files

| File | Purpose |
|------|---------|
| `module/xorg/kanren.scm` (~219 lines) | miniKanren from scratch: microKanren + Zzz + reification + occurs check |
| `module/xorg/hyperarc.scm` (~143 lines) | Hyperarc/metagraph data structures: nodes, hyperarcs, metagraphs, knowledge bases |
| `module/xorg/knowledge.scm` (~157 lines) | Relational query layer over hyperarc KBs using miniKanren |

## miniKanren exports (kanren.scm)

`var`, `var?`, `==`, `fresh`, `conde`, `run`, `run*`, `appendo`, `membero`, `Zzz`, `conj`, `disj`

Interleaving search with depth suspension via `Zzz`. Full occurs check.

## Hyperarc data model (hyperarc.scm)

Everything is tagged alists — no records, no keywords. This is deliberate: miniKanren can unify against the structure directly. Records would require custom unification.

```scheme
(make-node 'name "Alice" 'role "contributor")
;; => ((type . node) (name . "Alice") (role . "contributor"))

(make-hyperarc 'label "contributes" 'nodes (list alice-node repo-node))
;; => ((type . hyperarc) (label . "contributes") (nodes . (...)))
```

Operations: `kb-add`, `kb-merge`, `kb-query` (by type), `metagraph-nodes`, `metagraph-hyperarcs`.

## Relational queries (knowledge.scm)

Built on kanren.scm, queries over hyperarc KBs:

```scheme
(run* (q) (node-o my-kb q))           ;; all nodes
(run* (q) (hyperarc-o my-kb q))       ;; all hyperarcs
(run* (path) (transitive-o my-kb      ;; transitive closure with proof trace
              start-node end-node path))
```

`transitive-o` is depth-bounded (default 10) and returns proof traces — the chain of hyperarcs traversed.

`directed-arc-o` respects the head=first/tail=rest convention for hyperarc node ordering.

## Common editing patterns

**Add a miniKanren relation:** Define in `knowledge.scm` using `fresh`, `==`, `conde`:
```scheme
(define (my-relation-o kb x y)
  (fresh (arc)
    (hyperarc-o kb arc)
    (== (assq-ref arc 'source) x)
    (== (assq-ref arc 'target) y)))
```

**Add a data structure:** Extend `hyperarc.scm` with a new tagged-list constructor + accessors. Use plain symbols for alist keys (not keywords).

**Hoot compatibility:** Uses only lambdas, pairs, alists, `syntax-rules`. No vectors, no GOOPS, no keywords.

## Testing

```bash
make test-knowledge  # runs tests/test-knowledge.scm — 55 tests
```

## The user's request

$ARGUMENTS
