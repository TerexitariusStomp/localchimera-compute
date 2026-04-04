# Metaprogramming in/with Relations

How relational programming blurs the line between programs and data,
and what that looks like concretely in the playnet planning engine.

## The core insight

In ordinary programming, metaprogramming means "code that writes or
manipulates code." In relational programming, the equivalent is
**goals that construct, compose, or reason about other goals**.

But there's a twist: in miniKanren, goals are already just lambda
functions. So the boundary between "programming" and
"metaprogramming" is thinner than you'd expect.

---

## Level 0: Relations are already functions

Every relation in the codebase is an ordinary Scheme function that
returns a **goal** — a lambda that takes a state and returns a stream
of states:

```scheme
;; This is not a "declaration" — it's a function that returns a goal (lambda)
(define (error-o facts loop-id sp pv err)
  (fresh (sensor-id actuator-id law-kind)
    (control-loop-o facts loop-id sensor-id actuator-id law-kind)
    (setpoint-o facts loop-id sp)
    (-fd sp pv err)))
```

When you call `(error-o facts 'loop1 sp pv err)`, you don't get an
answer — you get a *goal*. The goal only runs when the search engine
applies it to a state.

This is already a kind of metaprogramming: you're building up a
computation (a goal tree) that will be executed later by the search.

---

## Level 1: Goal combinators (composition)

`fresh`, `conde`, `conj+`, `disj+` — these are **goal combinators**.
They take goals and produce new goals:

```scheme
(conde
  ((== law-kind 'proportional) (proportional-law-o ...))
  ((== law-kind 'bang-bang)    (bang-bang-law-o ...))
  ((== law-kind 'deadband)    (deadband-law-o ...)))
```

`conde` takes a list of goal-lists and returns one goal that tries all
branches. This is metaprogramming in the same sense that `map` over
functions is metaprogramming — you're operating at the level of
*goals as values*.

---

## Level 2: Higher-order relations

This is where it gets interesting. `claim-from-o` in
`planner/lib/relational/allocation.scm` doesn't just return a goal —
it **modifies the search state itself**:

```scheme
(define (claim-from-o rid inv-qty floor take)
  (lambda (st)                          ;; <-- raw goal, hand-built
    (let* ((S (cstate-S st))
           (take-v (walk take S)))
      (if (var? take-v)
          ;; Modify the constraint store (N), then chain goals
          (let* ((new-N (claims-add (cstate-N st) rid inv-qty take-v))
                 (st* (cstate-with st 'N new-N)))
            (bind ((rangeo take 0 available) st*)
                  (sum-leq-check rid)))
          ...))))
```

This is **meta-relational**: the goal inspects the current
substitution (`walk`), modifies the constraint store (`cstate-N`),
then constructs and chains new goals (`rangeo`, `sum-leq-check`). The
goal is *about* the search, not just *in* the search.

---

## Level 3: Three axes of relational metaprogramming

### Axis 1: Data as relations (reification)

The fact-lifting pattern turns ground Scheme data into relational facts:

```scheme
(define (recipe-o facts rid name output)
  (in-list-o `(recipe ,rid ,name ,output) facts))
```

A Scheme list becomes a searchable relation. The "program" (the list)
becomes "data" that the relation operates on. This is the simplest
form — going from Scheme-world to logic-world.

### Axis 2: Relations as data (reflection)

`instrumented-plan` in `planner/lib/relational/instrumentation.scm`
wraps a goal, treats it as a black box, and measures it:

```scheme
(define* (instrumented-plan n ctx log ...)
  (let* ((t0 (current-time-ms))
         (results (run-plan n #f (plan)
           (plan-o ctx plan ...)))     ;; <-- goal treated as data to be timed
         (t1 (current-time-ms)))
    ...))
```

The goal `plan-o` is being *observed from outside*. You could imagine
going further: serializing a goal, sending it across a network,
running it in a different vat.

### Axis 3: Relations that build relations (generation)

`demand-o` is recursive — it generates sub-goals dynamically based on
what the search discovers:

```scheme
(define (demand-o ctx spec-id qty due plan-term ...)
  (fresh (remaining allocated)
    (allocate-o ...)               ;; step 1: try to allocate
    (if (ground? remaining)        ;; step 2: based on result...
        (if (> remaining 0)
            (fresh (rid recipe-plan)
              (fact-recipe-o ctx ...)  ;; ...search for a recipe
              (demand-o ctx ...))      ;; ...recurse with new sub-goals
            succeed)
        fail)))
```

The structure of the goal tree isn't known ahead of time — it unfolds
as search proceeds. Each `demand-o` call creates new `fresh` variables
and new goals that didn't exist before. This is metaprogramming: the
relation is writing new pieces of itself at runtime.

---

## Level 4: State as meta-level

The most profound metaprogramming in the system is the **cstate** itself:

```
cstate = (S, C, FD, P, N)
         |  |   |   |  +-- claims registry (allocation metadata)
         |  |   |   +----- proof/trace data
         |  |   +--------- finite domain store
         |  +------------- disequality constraints
         +---------------- substitution (variable bindings)
```

Each field is a different "language" that the search engine
interprets. When `claim-from-o` writes to `N`, it's not just solving a
logic puzzle — it's **extending the language** that later goals operate
in. The `sum-leq-check` goal reads from `N` to enforce a global
invariant that no single goal could express alone.

This is the relational equivalent of a macro system: individual goals
modify the interpretation context for future goals.

---

## Level 5: Relational interpreters (the deep end)

The codebase doesn't use `eval` or `quote/unquote` on goals — that's
the right call for production code. But the *concept* exists in
miniKanren literature and is worth understanding.

A relational interpreter takes a "goal expression" as data and
executes it relationally:

```scheme
;; A relation that interprets a "goal expression" as data
(define (eval-goal-o expr state result)
  (conde
    ;; An == expression
    ((fresh (a b)
       (== expr `(== ,a ,b))
       (== a b)
       (== result state)))
    ;; A fresh expression
    ((fresh (var body)
       (== expr `(fresh (,var) ,body))
       (fresh (x)
         (eval-goal-o body (extend state var x) result))))
    ;; A conde expression
    ((fresh (branches)
       (== expr `(conde . ,branches))
       (eval-branches-o branches state result)))))
```

This is a **relational interpreter for miniKanren itself** — a
relation that takes a goal-as-data and executes it relationally. You
can run it "backwards" to *synthesize* goals that produce a desired
result.

This is program synthesis via relational metaprogramming, and it's the
core idea behind William Byrd's work on relational interpreters.

### Why this matters for planning

A relational interpreter over planning goals could:

- **Synthesize strategies**: given a desired plan shape, generate the
  `demand-o` call sequence that produces it.
- **Explain plans**: given a result, trace backwards through the
  interpreter to recover which goals fired and why.
- **Compose planners**: treat an entire planning context as a
  first-class value that can be combined with others (this is what
  `federation.scm` begins to do with lazy streams).

---

## Summary

Metaprogramming in the relational world happens at three levels:

| Level | Mechanism | Example | Analogy |
|-------|-----------|---------|---------|
| **Structural** | `fresh`/`conde` compose goals | `control-law-o` branching on law-kind | Function composition |
| **Stateful** | Goals modify cstate | `claim-from-o` writing to N | Macros changing the compilation environment |
| **Recursive** | Goals generate goal trees at runtime | `demand-o` unfolding sub-demands | Runtime code generation |

The key difference from traditional metaprogramming: in relations,
"running backwards" is always on the table. A relation that
*generates* plans can also *verify* them. A relation that *computes*
error can also *infer* what setpoint would produce a given error. The
meta-level and the object-level are the same language, run in any
direction.

---

## Appendix: Implemented refactorings

These refactorings apply the metaprogramming patterns described above
to make the codebase more elegant. All 39 test suites pass.

### A. `transitive-closure-o` — higher-order edge traversal

**File:** `planner/lib/relational/trace.scm`
**Level:** 2 (higher-order relations)

`provenance-o` and `destination-o` were structurally identical,
differing only in the edge relation (`produces-o` vs `consumed-by-o`).
Extracted a generic `transitive-closure-o` that takes an edge relation
as a first-class argument:

```scheme
(define* (transitive-closure-o edge-o from to trace
                               #:optional (depth *default-trace-depth*))
  (if (= depth 0) fail
      (conde
        ((edge-o from to)
         (== trace (list from to)))
        ((fresh (mid rest)
           (edge-o from mid)
           (transitive-closure-o edge-o mid to rest (- depth 1))
           (== trace (cons from rest)))))))

;; Now provenance and destination are one-liners:
(define* (provenance-o facts spec-id ancestor trace ...)
  (transitive-closure-o (lambda (a b) (produces-o facts a b))
                        spec-id ancestor trace depth))
```

Reusable for any future transitive query (part-of, labor-chain, etc.).

### B. Unified `fact-*-o` relations — ctx-aware auto-dispatch

**File:** `planner/lib/relational/planning-facts.scm`
**Level:** 1 (goal combinators) + Axis 1 (data as relations)

Previously, every call site had `if indexes` dispatch:

```scheme
;; Before: 4 branches in produce-branch alone
(if indexes (recipe-indexed-o indexes spec-id rid rname)
            (recipe-o facts rid rname spec-id))
(if indexes (chain-indexed-o indexes rid pids)
            (chain-o facts rid pids))
```

Now: unified `fact-recipe-o`, `fact-chain-o`, `fact-flow-o`,
`fact-inventory-o`, `fact-buffer-zone-o` accept a `ctx` and
auto-dispatch:

```scheme
;; After: clean call sites
(fact-recipe-o ctx rid rname spec-id)
(fact-chain-o ctx rid pids)
(fact-flow-o ctx last-pid 'output spec-id out-qty out-unit out-action)
```

Raw-facts variants (`recipe-o`, `flow-o`, etc.) remain for code
without a ctx. Legacy `*-indexed-o` aliases remain for test
compatibility.

### C. `map-goal-o` — higher-order relational fold

**File:** `planner/lib/relational/demand-relation.scm`
**Level:** 2 (higher-order relations)

Three input solvers (`solve-inputs-o`, `solve-use-inputs-o`,
`solve-cite-inputs-o`) shared a recursive null?/cons/fresh pattern.
Extracted `map-goal-o`:

```scheme
(define (map-goal-o items item->goal-o results)
  "Relational map: apply item->goal-o to each item, collect results."
  (if (null? items)
      (== results '())
      (fresh (result rest)
        (item->goal-o (car items) result)
        (map-goal-o (cdr items) item->goal-o rest)
        (== results (cons result rest)))))
```

Each solver is now a one-call wrapper around `map-goal-o` with its
domain-specific goal:

```scheme
(define (solve-cite-inputs-o facts cited-specs cite-plans)
  (map-goal-o cited-specs
    (lambda (spec result)
      (fresh (rid qty loc)
        (inventory-o facts rid spec qty loc)
        (<fd 0 qty)
        (== result `(cited ,spec ,rid))))
    cite-plans))
```

### D. Relational signal dispatch — `signal-action-o`, `signal-category-o`

**File:** `planner/lib/relational/signals.scm`
**Level:** 1 (goal combinators) — replacing ground `case`/`memq`

The kind-to-action and kind-to-category mappings were buried inside a
`project` block (ground `case` dispatch). Extracted as pure relational
`conde` tables:

```scheme
(define (signal-action-o kind action)
  "Relational: signal kind ↔ VF action. Any direction."
  (conde
    ((== kind 'deficit) (== action 'transfer))
    ((== kind 'replenishment) (== action 'produce))
    ...))

(define (signal-category-o kind input-of output-of)
  "Relational: signal kind ↔ input/output classification."
  (conde
    ((== kind 'deficit) (== input-of 'input) (== output-of #f))
    ((== kind 'replenishment) (== input-of #f) (== output-of 'output))
    ...))
```

These now work bidirectionally: "what action for deficit?" AND "what
kinds map to transfer?" — previously impossible because `case` is
one-way. `project` remains only for genuine string operations (iid
generation).

---

## References

- William E. Byrd, *miniKanren and Relational Programming* — relational interpreters and program synthesis
- Daniel P. Friedman, William E. Byrd, Oleg Kiselyov, *The Reasoned Schemer* — foundations of miniKanren
- `module/playnet/kanren.scm` — base miniKanren implementation (Hemann & Friedman)
- `module/playnet/kanren-planning.scm` — planning state extensions (cstate)
- `module/playnet/kanren-constraints.scm` — CLP(FD) + symbolic constraints
- `planner/lib/relational/` — all planning domain relations
