# Observation and Relations

How the observer derives world state, how that state becomes relational
facts, and why these layers are connected but not unified.

---

## Three layers, one bridge

```
Layer 3: Relational queries (miniKanren)
         plan-o, demand-o, fact-recipe-o, fact-inventory-o ...
         unify against flat fact tuples
              ↑
              │  in-list-o over lifted facts
              │
Layer 2: The lift (planning-facts.scm)
         observer.all-resources → (inventory rid spec qty loc contained-in)
         observer.all-events   → (event eid action spec qty timestamp)
         recipe-store          → (recipe ...), (chain ...), (process ...), (flow ...)
         plan-store            → (intent ...), (commitment ...)
         buffer-zone-store     → (buffer-zone ...)
              ↑
              │  synchronous $ calls into Goblins actors
              │
Layer 1: Observer fold (observer.scm)
         event stream → 5-phase pure pipeline → bcom commits state
         maintains resources, events, 6 indexes
```

## The observer: a fold over economic events

The observer is a left fold. Each incoming `economic-event` is threaded
through five pure phases:

```
phase-append-event → phase-index-event → phase-apply-effects
                                         → phase-implied-transfer
                                             → phase-track
```

No `set!`. The `<fold-ctx>` record carries state + affected-resources
through phases 3-4. The actor's `bcom` IS the fold's commit step. After
folding, the observer holds:

- **Resources** with current quantities (the "world state")
- **Events** in reverse-chronological order (the history)
- **6 indexes**: by-resource, by-process, by-agent, by-action, by-id, by-spec

This is the imperative, actor-level truth. It knows about records,
hashmaps, quantities. It does not know about logic variables or
unification.

## The lift: records become tuples

`lift-planning-facts` bridges the actor world and the relational world.
It calls into the observer (and other stores) and materializes their
state as plain list tuples:

```scheme
;; observer.all-resources → inventory facts
(filter-map
  (lambda (r)
    (and (> qty 0)
         `(inventory ,rid ,spec ,qty ,location ,contained-in)))
  ($ observer 'all-resources))

;; observer.all-events → event facts
(map (lambda (e)
       `(event ,eid ,action ,spec ,qty ,timestamp))
     ($ observer 'all-events))
```

Facts are plain lists — no records, no accessor functions — because
miniKanren needs to unify over their structure. The lift also builds
hash-table indexes for O(1) key lookup during relational search.

| Store | Fact tuple | Key fields |
|-------|-----------|------------|
| Observer | `(inventory rid spec qty location contained-in)` | Only resources with qty > 0 |
| Observer | `(event eid action spec qty timestamp)` | Full history |
| Recipe store | `(recipe id name output-spec)` | Sorted by SNE |
| Recipe store | `(chain rid (pid ...))` | Process ordering |
| Recipe store | `(process pid name duration min-batch)` | Per-process |
| Recipe store | `(flow pid direction spec qty unit action resolve-from flow-id)` | Inputs and outputs |
| Plan store | `(intent id action spec qty unit due input? output? tags finished?)` | Open planning requests |
| Plan store | `(commitment id action spec qty unit due provider receiver finished?)` | Bilateral agreements |
| Buffer zone store | `(buffer-zone spec tor toy tog adu dlt-days)` | DDMRP profiles |

## Relations: querying the lifted facts

The relational layer uses miniKanren to query over the lifted tuples.
`knowledge.scm` provides generic combinators (`in-list-o`,
`transitive-o`). `planning-facts.scm` provides domain-specific
relations that auto-dispatch between indexed and scan paths:

```scheme
;; fact-inventory-o: indexed O(I) per spec, or full scan O(N)
(define (fact-inventory-o ctx resource-id spec-id qty location)
  (let ((indexes (ctx-indexes ctx)))
    (if indexes
        (let ((matches (idx-ref indexes 'inventory-by-spec spec-id)))
          (fresh (contained-in)
            (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location
                                  ,contained-in)
                       matches)))
        (fresh (contained-in)
          (in-list-o `(inventory ,resource-id ,spec-id ,qty ,location
                                ,contained-in)
                     (ctx-facts ctx))))))
```

The `plan-ctx` record bundles facts, indexes, and actor refs into a
single argument threaded through all relations:

```scheme
(define-record-type <plan-ctx>
  (make-plan-ctx facts plan-store observer location-store plan-id indexes)
  ...)
```

## Connected but not unified

The observer and the relational layer are **connected through the lift**
but are **not the same system**. This is deliberate.

### Why they are separate

1. **Purity during search.** Facts are frozen at session start.
   miniKanren search never calls the observer — no side effects, no
   state changes mid-unification. The search is deterministic and
   replayable.

2. **Different representations.** The observer uses Guile records with
   accessor functions and HAMT hashmaps. Relations use plain lists and
   logic variables. Records can't participate in unification; lists can.

3. **Different lifecycles.** The observer updates continuously as events
   arrive (fold). The relational facts are a snapshot — immutable for
   the duration of a planning session.

### What the separation costs

1. **Staleness.** If an event arrives after the lift, the relational
   layer doesn't see it until the next session/re-lift.

2. **No reactive replanning.** Observations don't automatically trigger
   relation updates or new planning runs. The lift is manual.

3. **Disconnected utilities.** `knowledge.scm` (`in-list-o`,
   `transitive-o`) is generic — it doesn't know about the observer or
   VF domain. It works over any fact list. This is good for generality
   but means there's no built-in "query the observer relationally."

### What unification would look like

If the observer's state *were* a set of relations maintained
incrementally, every `record-event` would update the relation set
directly. Queries would always see current state — no snapshot, no
lift step. The rest of this document explores what that means
concretely.

---

## Toward unification

### The core idea

Replace the observer's 14-field record (resources hashmap, 6 index
hashmaps, event log, tracking state) with a **fact store** — a set of
tuples that IS the observer's state. The fold kernel stays, but
instead of hashmap mutations it asserts and retracts tuples:

```
Current:  event → update-hashmap(resources, rid, new-resource-record) → bcom
Unified:  event → retract(inventory rid spec old-qty ...) 
                → assert(inventory rid spec new-qty ...)
                → bcom
```

The relational layer no longer needs a lift step. It queries the
observer's fact store directly.

### What the observer's state becomes

Today the observer holds 14 fields. In a unified model those become
fact tuples grouped by kind:

| Current field | Becomes | Notes |
|---------------|---------|-------|
| `resources` (hashmap) | `(inventory rid spec qty location contained-in accountable custodian state)` | One tuple per resource with qty > 0 |
| `events` (list) | `(event eid action spec qty timestamp provider receiver)` | Append-only — assert, never retract |
| `idx-by-resource` | Implicit — query `(event _ _ _ _ _ _ rid)` | Unification replaces the index |
| `idx-by-process` | Implicit — query `(event _ _ _ _ _ pid _)` | Unification replaces the index |
| `idx-by-agent` | Implicit — query `(event _ _ _ _ _ _ _ agent)` | Unification replaces the index |
| `idx-by-action` | Implicit — query `(event _ action _ _ _)` | Unification replaces the index |
| `events-by-id` | Implicit — query `(event eid _ _ _ _)` | Unification replaces the index |
| `idx-by-spec` | Implicit — query `(inventory _ spec _ _ _)` | Unification replaces the index |
| `fulfillments` | `(fulfillment commitment-id committed-qty fulfilled-qty finished?)` | One tuple per commitment |
| `satisfactions` | `(satisfaction intent-id desired-qty satisfied-qty finished?)` | One tuple per intent |
| `claim-states` | `(settlement claim-id claimed-qty settled-qty finished?)` | One tuple per claim |
| `agreements` | `(agreement agreement-id ...)` | Structural |
| `batches` | `(batch batch-id ...)` | Append-only |
| `resource-batches` | `(resource-batch rid batch-id)` | Link tuples |

The 6 index hashmaps vanish entirely. Indexes are implicit in
unification — you query for the pattern you want. Performance comes
from the fact store's internal indexing (see below), not from
hand-maintained secondary hashmaps.

### The fold kernel: assert/retract

The 5-phase pipeline stays structurally identical. Each phase becomes
a sequence of assert/retract operations on the fact store instead of
hashmap updates:

```
Phase 1: phase-append-event
  Before:  (cons event events-list)
  After:   (assert (event eid action spec qty ts provider receiver))

Phase 2: phase-index-event
  Before:  (hashmap-set idx-by-resource rid (cons eid old-list)) ...
  After:   Nothing. Indexes are implicit.

Phase 3: phase-apply-effects
  Before:  (hashmap-set resources rid (make-economic-resource ...new-qty...))
  After:   (retract (inventory rid spec old-qty old-loc ...))
           (assert  (inventory rid spec new-qty new-loc ...))

Phase 4: phase-implied-transfer
  Before:  (hashmap-set resources rid (make-economic-resource ...new-accountable...))
  After:   (retract (inventory rid spec qty loc old-accountable ...))
           (assert  (inventory rid spec qty loc new-accountable ...))

Phase 5: phase-track
  Before:  (hashmap-set fulfillments cid (make-fulfillment-state ...new-total...))
  After:   (retract (fulfillment cid committed old-fulfilled old-done))
           (assert  (fulfillment cid committed new-fulfilled new-done))
```

Phase 2 disappears completely. The remaining phases become simpler
because there's one representation (tuples) instead of two (records +
accessors).

### What the query interface becomes

The observer currently exposes ~50 actor methods. In a unified model,
these become relational queries:

```scheme
;; Current: ($ observer 'conforming-resources "wheat")
;; Unified:
(run* (rid) (inventory rid "wheat" _ _ _))

;; Current: ($ observer 'inventory-at-location "warehouse-1")
;; Unified:
(run* (rid spec qty)
  (fresh (contained-in accountable)
    (inventory rid spec qty "warehouse-1" contained-in accountable)
    (=/= qty 0)))

;; Current: ($ observer 'events-for-agent "alice")
;; Unified:
(run* (eid action spec qty ts)
  (conde
    ((event eid action spec qty ts "alice" _))
    ((event eid action spec qty ts _ "alice"))))

;; Current: ($ observer 'fulfilled? commitment-id)
;; Unified:
(run 1 (q) (fulfillment commitment-id _ _ #t))
```

No accessor functions. No method dispatch. The query IS the pattern.

### The fact store

The tuples need a container. Three options:

**Option A: Plain list (simplest, slowest)**

The fact store is just a list of tuples, like the current lifted
facts. `in-list-o` queries them. This is what we have today after
lifting — but maintained incrementally instead of snapshot-rebuilt.

Assert = cons. Retract = filter. Query = linear scan.

Good enough for small communes. Doesn't scale.

**Option B: Indexed list with hash tables (current hybrid)**

Keep the hash-table indexes but generate them from tuples instead of
records. This is essentially what `build-indexes` does today, but
maintained incrementally on assert/retract instead of rebuilt per
session.

Assert = cons + update relevant hash tables. Retract = remove + update
hash tables. Query = O(1) via index, O(n) fallback for unindexed
patterns.

Pragmatic middle ground. The observer already does this — just with
records instead of tuples.

**Option C: Trie-indexed fact store (most relational)**

A purpose-built store that indexes tuples by their first element (fact
kind) and key positions. Conceptually a miniature Datalog EDB:

```scheme
(define-record-type <fact-store>
  (make-fact-store by-kind by-key)
  fact-store?
  (by-kind  fs-by-kind)   ;; hashmap: symbol → list of tuples
  (by-key   fs-by-key))   ;; hashmap: (kind . key-position-value) → list of tuples

(define (fs-assert store tuple)
  ;; Add to by-kind index + relevant by-key indexes
  ...)

(define (fs-retract store tuple)
  ;; Remove from all indexes
  ...)

(define (fs-query store kind . pattern)
  ;; Use best available index, fall back to by-kind scan
  ...)
```

This gives the observer O(1) indexed queries without hand-maintaining
per-field hashmaps. New fact kinds automatically get indexed. The
relational layer queries the same store via `in-list-o` over
`fs-query` results.

### Consistency: the snapshot question

The current architecture freezes facts at session start. This is
load-bearing in one specific place: **inventory allocation**.

The relational planner uses CLP(FD) constraints to allocate
quantities:

```scheme
;; allocation.scm — claim-from-o
;; Registers a take-variable against a resource's inventory qty.
;; Constraint: sum(all takes from resource R) <= inventory-qty(R)
```

If inventory quantities could change mid-search (another event
arrives, changes a resource's qty), the constraint solver's
`sum <= qty` invariant breaks. A branch that was feasible when
explored could become infeasible after a concurrent event — but
miniKanren has already committed to it (no invalidation mechanism).

**The solution is not to prevent unification, but to scope it.**

Within a single Goblins turn (a `with-vat` block), the vat is
single-threaded. No events can arrive while a planning query runs.
If the planning query happens inside a turn, the fact store is
naturally consistent — not because we froze it, but because the
actor model already provides isolation.

```scheme
;; Planning inside a turn: fact store is consistent by construction
(with-vat vat
  (let ((facts ($ observer 'fact-store)))  ;; returns the live fact store
    (run* (plan) (plan-o facts plan))))    ;; queries over current state
```

For planning queries that span multiple turns (long-running search),
you'd take an explicit snapshot — but that's a `(fs-snapshot store)`
call, not a full lift-and-rebuild. The snapshot is just a reference
to the current immutable fact store (since assert/retract produce new
stores, old ones are still valid).

### What simplifies

1. **The lift disappears.** `lift-planning-facts` (300 lines) becomes
   unnecessary. The observer's fact store IS the planning facts.

2. **Index maintenance consolidates.** Instead of the observer
   maintaining 6 hashmaps AND `build-indexes` building 6 more hash
   tables, there's one indexing mechanism in the fact store.

3. **Serialization simplifies.** No record-to-list conversion
   boilerplate. Facts are already lists. `(write (fs-all-facts store))`
   serializes the entire observer. Deserialization is
   `(fold fs-assert empty-store saved-facts)`.

4. **Query interface vanishes.** The observer's ~50 methods become
   unnecessary. Any query is expressible as a relational pattern. New
   queries don't require new methods.

5. **The plan-ctx simplifies.** Instead of bundling facts + indexes +
   actor refs, the plan context just carries a reference to the fact
   store. The `ctx-obs` and `ctx-ps` fields (actor refs currently
   stored but never used during search) go away.

6. **Tracking state unifies with observation.** Fulfillments,
   satisfactions, and settlements are just more fact tuples. No
   separate hashmaps, no separate serialization logic. You can query
   "which commitments are fulfilled?" the same way you query "what's
   in inventory?" — same mechanism, same interface.

### What gets harder

1. **Phase ordering.** The current fold applies effects in a specific
   sequence (append → index → effects → transfer → track). With
   assert/retract, you need to be careful that a retract in phase 3
   doesn't invalidate a pattern that phase 5 needs to match. In
   practice this is fine — each phase touches different fact kinds —
   but the dependency must be made explicit.

2. **Split-custody logic.** The observer's most complex transformation
   (pickup/dropoff with 2 resources, 2 agents) currently overrides
   action effects procedurally. In a relational model this becomes a
   set of conditional retract/assert rules. The logic is the same but
   expressed differently.

3. **Performance of unindexed queries.** The current observer can do
   `hashmap-ref` in O(log32 n) for any resource by ID. A fact store
   without per-field indexes would scan all inventory tuples. Option C
   (trie-indexed store) addresses this, but it's more machinery than
   a plain list.

4. **Backward compatibility.** Code outside the planner that calls
   `($ observer 'get-resource rid)` or `($ observer 'inventory)`
   would need to change. The observer's actor interface could wrap
   relational queries to preserve the API, but it's an extra layer.

5. **Breadcrumb chains.** The observer currently sets a
   `previousEvent` field on resource records for trace-back. In the
   fact store model, this becomes a link tuple
   `(event-chain eid previous-eid rid)` or is derived by querying
   events for the same resource in temporal order.

### Incremental path

Unification doesn't have to happen all at once. A natural progression:

**Step 1: Dual-write.** The observer maintains its current state AND
emits fact tuples as a side effect. The lift reads from the fact
tuples instead of calling actor methods. This validates the tuple
schema without changing the observer's internals.

**Step 2: Fact store as primary.** Replace the observer's hashmaps
with a fact store (Option B or C). The fold kernel asserts/retracts
tuples. The actor interface wraps relational queries. External code
doesn't change.

**Step 3: Direct relational access.** The planning layer queries the
fact store directly instead of going through the actor interface.
`lift-planning-facts` reduces to `(fs-all-facts ($ observer 'facts))`
or disappears entirely if the planner holds a direct reference.

**Step 4: Other stores.** Apply the same pattern to recipe-store,
plan-store, buffer-zone-store. Each store's state becomes a fact
store. The plan context becomes a union of fact stores (or one shared
store).

### The deeper question

Unification isn't just an implementation choice. It's a statement
about what the system *is*.

In the current architecture, the observer is an actor that happens to
produce data that can be queried relationally. The relational layer is
a planning tool that happens to consume observer data. They're
connected by convention (the lift) but have different ontologies.

In a unified architecture, **observation IS assertion**. Recording an
economic event IS asserting facts into the shared knowledge base.
Planning IS querying that same knowledge base. The observer and the
planner are not separate systems connected by a bridge — they're
different modes of interaction with the same relational state.

This maps naturally onto the miniKanren worldview: the world is a set
of relations, and computation is the process of finding substitutions
that satisfy constraints over those relations. The observer's fold
becomes a sequence of relation-maintenance operations. The planner's
search becomes a query over the maintained relations. Same relations,
different operations.

It also aligns with the Goblins actor model: each scope's vat holds
the authoritative fact store for that scope. Cross-scope queries
(federation) become distributed relational queries over multiple fact
stores. The OCapN layer provides the transport; the relational layer
provides the query semantics.

## File map

| File | Role |
|------|------|
| `planner/lib/observation/observer.scm` | Fold kernel — 5-phase event pipeline, 6 indexes |
| `planner/lib/relational/planning-facts.scm` | The lift + indexed fact relations |
| `module/playnet/kanren.scm` | miniKanren core — unification, intmap substitutions |
| `module/playnet/knowledge.scm` | Generic relational utilities — `in-list-o`, `transitive-o` |
| `module/playnet/kanren-planning.scm` | Planning-specific goals |
| `module/playnet/kanren-constraints.scm` | CLP(FD) integration |
| `planner/lib/relational/plan-relation.scm` | Orchestrator `plan-o` |
| `planner/lib/relational/demand-relation.scm` | Demand/produce relations |
