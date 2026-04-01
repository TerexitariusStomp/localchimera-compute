# playnet: How It All Works

An explanation of the distributed relational planning system, how it maps onto
Goblins, and where the generic solver ends and the domain logic begins.

---

## 1. Your Mental Model is Correct

### Scopes are actors (Goblins vats)

A scope — an organization, commune, or ecological agent — is a single Goblins
**vat** containing all its store actors. The `^scope-root` actor holds references
to every store and serves as the scope's unified facade.

```scheme
;; planner/lib/scope-root.scm
(define-actor (^scope-root bcom name
                           recipe-store-ref agent-store-ref observer-ref
                           plan-store-ref buffer-zone-store-ref ...)
  (methods
    ((name) name)
    ((recipe-store) recipe-store-ref)
    ((observer) observer-ref)
    ...))

(define (spawn-scope scope-name)
  (let ((rs  (spawn ^recipe-store ...))
        (obs (spawn ^observer (empty-observer-state)))
        (ps  (spawn ^plan-store (empty-plan-store-state)))
        ...)
    (spawn ^scope-root scope-name rs obs ps ...)))
```

All stores are **near** (same vat). This is what enables synchronous transactions.

**Where to find it:** `planner/lib/scope-root.scm` (90 lines)

### Synchronous transactions within each scope

Within a single vat, the `$` operator invokes actors synchronously. State
transitions happen via `bcom` (become). A `with-vat` block is one **turn** —
everything inside commits atomically or rolls back on error.

```scheme
;; planner/tests/scope-integration.scm (integration test pattern)
(with-vat vat
  ($ ($ scope 'observer) 'record-event some-event)   ;; synchronous
  ($ ($ scope 'plan-store) 'add-intent some-intent))  ;; same turn — atomic
```

Every store actor uses `bcom` for state transitions. The observer demonstrates
this clearly — it's architecturally a **left fold**, where each event is folded
through a 5-phase pipeline and `bcom` is the fold's commit step:

```scheme
;; planner/lib/observation/observer.scm (the fold kernel)
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

Each phase is pure — no `set!`. The `bcom` at the actor level IS the fold's
commit step.

**Where to find it:**
- `$` synchronous calls: any `with-vat` block in test/integration code
- `bcom` transitions: every store actor (`observer.scm`, `planning.scm`, `account.scm`, etc.)
- 5-phase fold: `planner/lib/observation/observer.scm`

### Asynchronous message passing between scopes

Between vats (different scopes, or scopes on different machines), the `<-`
operator sends messages asynchronously, returning a **promise**. The `on` macro
handles the response when it arrives.

```scheme
;; docs/goblin-chat.scm — async patterns
(define subscription-sealer-vow
  (<- user 'get-subscription-sealer))    ;; async send, returns promise

(on subscription-sealer-vow
    (lambda (subscription-sealer)
      (define finalize-sub (spawn ^finalize-subscription user))
      (<- subscription-sealer finalize-sub))
    #:promise? #t)

;; Fire-and-forget (no response needed)
(<-np control-sock 'write-line new-msg)
```

The `^store-registry` actor provides cross-scope reference resolution. It maps
scope IDs to plan-store actor references, supporting qualified references like
`"riverside::intent-42"`:

```scheme
;; planner/lib/planning/store-registry.scm
(define-actor (^store-registry bcom scope-refs)
  (methods
    ((register scope-id plan-store-ref)
     (bcom (^store-registry bcom
             (hashmap-set scope-refs scope-id plan-store-ref))))

    ((resolve qualified-ref)
     (let-values (((scope-id record-id) (parse-ref qualified-ref)))
       (let ((store (hashmap-ref scope-refs scope-id #f)))
         ;; Cross-scope call — near via $, remote via <- (OCapN-ready)
         (let ((intent ($ store 'get-intent record-id))
               (commitment ($ store 'get-commitment record-id)))
           ...))))

    ((intents-for-tag tag)
     ;; Aggregates across ALL registered scopes
     (hashmap-fold
       (lambda (scope-id store acc)
         (append (map (lambda (i) (cons scope-id i))
                      ($ store 'intents-for-tag tag))
                 acc))
       '() scope-refs))))
```

**Where to find it:**
- Async patterns (`<-`, `on`): `docs/goblin-chat.scm`
- Cross-scope refs: `planner/lib/planning/store-registry.scm`
- Federation fold: `planner/lib/planning/plan-federation.scm`

### The event loop is implicit

There is no hand-rolled event loop. Goblins vat turns ARE the event loop.
Within a `with-vat` block, all `$` calls execute synchronously in one turn.
Across vats, `<-` enqueues messages into the target vat's turn queue, and the
Goblins runtime drives the scheduling.

### Networking: OCapN over Reticulum

Goblins actors become reachable over physical networks via OCapN (Object
Capability Network). A custom netlayer bridges Goblins' CapTP to Reticulum's
encrypted mesh networking, supporting TCP, LoRa radio, I2P, serial, and packet
radio — all invisible to the actor code.

```scheme
;; module/goblins/ocapn/netlayer/reticulum.scm
(define (setup-bridge control-path socket-dir)
  (define control-sock
    (spawn ^line-delimited-port (make-client-unix-domain-socket control-path)))
  (<-np control-sock 'write-line new-msg)   ;; async to bridge daemon
  (on (<- control-sock 'read-line)
      (lambda (response)
        (match (string-split response #\:)
          (("destination" hash)
           ($ dest-hash-resolver 'fulfill hash))))))
```

A sturdyref like `ocapn://...reticulum/s/...` works identically regardless of
whether the underlying transport is TCP or LoRa. The actor doesn't know or care.

**Where to find it:**
- Netlayer: `module/goblins/ocapn/netlayer/reticulum.scm`
- Bridge daemon: `reticulum-bridge.py`
- Full networking docs: `docs/RETICULUM-NETLAYER.md`

### Summary: Goblins primitives map

| Organizational Need     | Goblins Primitive          | Scope Level     |
|--------------------------|----------------------------|-----------------|
| Mutable state            | `bcom` (become)            | Within scope    |
| Transactions             | Vat turns (`with-vat`)     | Within scope    |
| Synchronous messaging    | `$` operator               | Within scope    |
| Asynchronous messaging   | `<-` operator + promises   | Between scopes  |
| Capability security      | Actor refs (unforgeable)   | Everywhere      |
| Persistence              | `#:portrait` / `#:restore` | Per scope       |
| Networking               | OCapN + Reticulum          | Between machines|

---

## 2. System Structure (Layered)

```
                ┌─────────────────────────────────────────────────┐
                │        Layer 4: Federation                       │
                │                                                  │
                │  plan-federation    store-registry                │
                │  (hierarchy fold)   (qualified refs)              │
                │                                                  │
                │  relational/federation.scm                        │
                │  (lazy-stream protocol, lateral matching)         │
                └──────────────┬──────────────────────────────────┘
                               │
                ┌──────────────┴──────────────────────────────────┐
                │      Layer 2: Planning Algorithms                 │
                │                                                   │
                │  Imperative path:                                  │
                │    plan-for-unit ─ dependent-demand (BFS unfold)   │
                │    netting (state monad) ─ propagation ─ ddmrp    │
                │                                                   │
                │  Relational path (miniKanren):                     │
                │    plan-o ─ demand-o ─ allocate-o (CLP(FD))       │
                │    recipe-o, flow-o, zone-o, sne-o                │
                └──────────────┬────────────────────────────────────┘
                               │
                ┌──────────────┴──────────────────────────────────┐
                │     Layer 1: Store Actors (Goblins vats)          │
                │                                                   │
                │  scope-root (coordinator)                          │
                │    ├── recipe-store     (7 hashmaps)               │
                │    ├── agent-store      (3 hashmaps)               │
                │    ├── observer         (fold kernel)              │
                │    ├── plan-store       (10 hashmaps)              │
                │    ├── buffer-zone-store                           │
                │    ├── account-store    (commune labor-credits)    │
                │    ├── capacity-buffer-store                       │
                │    ├── spatial-thing-store                         │
                │    ├── snapshot-store   (append-only)              │
                │    └── alert-store      (append-only)              │
                └──────────────┬────────────────────────────────────┘
                               │
                ┌──────────────┴──────────────────────────────────┐
                │     Layer 0: ValueFlows Record Types               │
                │                                                   │
                │  schemas.scm — 47 immutable records                │
                │  store-utils.scm — hashmap helpers                 │
                └────────────────────────────────────────────────────┘
```

Both planning paths (imperative and relational) share the same Layer 0 and
Layer 1 — they read the same store actors and operate on the same VF records.

---

## 3. The Relational Solver: Generic vs Domain-Specific

This is the key architectural question: how tightly coupled is the miniKanren
solver to the ValueFlows planning domain?

**Answer: they are cleanly separated into three layers.**

### Layer A — Generic miniKanren + CLP(FD) (domain-agnostic)

These modules know nothing about ValueFlows, planning, resources, or economics.
They implement a general-purpose relational logic programming system:

**`module/playnet/kanren.scm`** (312 lines) — Core microKanren:
- Logic variables, persistent intmap substitution (O(log16 n))
- Unification with occurs check
- `==`, `fresh`, `conde`, `disj`, `conj`
- Lazy interleaving search via `mplus`/`bind`/`Zzz`
- Reification, `appendo`, `membero`

**`module/playnet/kanren-constraints.scm`** (964 lines) — Extended solver:
- Extended state: `#(S C N CS FD P)` — substitution, counter, context,
  constraint store, finite domain store, propagator queue
- Symbolic constraints: `=/=` (disequality), `numbero`, `symbolo`, `absento`
- CLP(FD): `infd`/`rangeo`, `+fd`/`-fd`/`*fd`, `<fd`/`<=fd`, `distinctfd`
- `labelfd` for domain enumeration (binary-split for large domains)
- Constraint propagation: arc consistency, targeted re-evaluation via
  propagator queue

These are completely reusable. You could use them for Sudoku, type inference,
circuit synthesis — anything expressible as relational constraints. They are
also Hoot-compatible (run in the browser via WebAssembly).

**Where to find it:**
- `module/playnet/kanren.scm`
- `module/playnet/kanren-constraints.scm`

### Layer B — Bridge (kanren-planning.scm)

This thin module (217 lines) adapts the generic solver for planning use:

```scheme
;; module/playnet/kanren-planning.scm

;; State = (substitution counter . netter-state)
;; The netter-state threads allocation sums through the search.

(define-record-type <plan-ctx>
  (make-plan-ctx facts plan-store observer location-store plan-id indexes)
  plan-ctx?
  (facts          ctx-facts)       ;; plain S-expr tuples (relationally queried)
  (plan-store     ctx-ps)          ;; Goblins actor (intents/commitments)
  (observer       ctx-obs)         ;; Goblins actor (events/resources)
  (location-store ctx-ls)          ;; Goblins actor (spatial hierarchy)
  (plan-id        ctx-plan-id)
  (indexes        ctx-indexes))    ;; hash-table indexes for O(1) lookups

;; run-plan: execute a relational query with planning state
(define-syntax run-plan
  (syntax-rules ()
    ((_ n ns (q) g0 g ...)
     (map reify-1st
          (take n
                ((fresh (q) g0 g ...)
                 (empty-planning-state ns)))))))
```

This layer adds:
- The `<plan-ctx>` record bundling facts + actor references
- `run-plan` / `run-plan*` for executing planning queries
- `project` for extracting ground values mid-search
- `in-list-o` for membership over concrete Scheme lists

It does NOT define any planning relations — just the machinery to run them.

**Where to find it:** `module/playnet/kanren-planning.scm`

### Layer C — Domain relations (ValueFlows-specific)

These modules define the planning domain as relational goals layered on top of
the generic solver. They live in `planner/lib/relational/` (~2,400 lines
across 11 modules):

#### Fact lifting

VF records from the store actors are "lifted" into plain S-expression tuples
at session start:

```scheme
;; planner/lib/relational/planning-facts.scm
;;
;; Store records become plain tuples:
(inventory     "resource-id" "spec-id" qty location)
(recipe        "recipe-id" "Recipe Name" "output-spec")
(chain         "recipe-id" ("process-id-1" "process-id-2" ...))
(process       "process-id" "Process Name" duration-ms)
(flow          "process-id" direction spec-id qty unit action)
(buffer-zone   "spec-id" tor)
(intent        "intent-id" action spec-id qty unit due ...)
```

These tuples are **plain lists**. The relational solver queries them via pattern
matching — no database, no ORM, just `conde` branches over list structure.

Indexes are built at session start for O(1) lookups:

```scheme
;; recipes-by-output: spec-id → [recipe tuples]
;; flows-by-process:  process-id → [flow tuples]
;; inventory-by-spec: spec-id → [resource tuples with qty > 0]
```

#### Core relations

**`allocate-o`** (allocation.scm) — Buffer-aware CLP(FD) allocation:

```scheme
(define* (allocate-o facts spec-id qty remaining allocated sums-in sums-out
                      #:key (indexes #f))
  (let ((resources ...)
        (floor (conservation-floor facts spec-id)))  ;; TOR or 0
    (conde
      ;; Branch 1: respect conservation floor (buffer-safe)
      ((allocate-from-o qty resources remaining allocated sums-in sums-out floor))
      ;; Branch 2: ignore floor (sacrifice — fallback via interleaving)
      ((allocate-from-o qty resources remaining allocated sums-in sums-out 0)))))
```

The five-pass imperative allocation (reserve, guard, defer, retry, sacrifice)
collapses into a single constraint: `sum-of-takes <= inventory - floor`. The
search naturally explores buffer-safe plans first; sacrifice plans are only
reached via interleaving if no safe plan exists.

**`demand-o`** (demand-relation.scm) — Core demand relation:

```scheme
(define* (demand-o ctx spec-id qty due plan-term sums-in sums-out
                   #:key (depth *default-depth*) (visited '()))
  (fresh (remaining allocated sums-mid)
    (allocate-o (ctx-facts ctx) spec-id qty remaining allocated sums-in sums-mid)
    (after-allocation ctx spec-id qty due remaining allocated
                      plan-term sums-mid sums-out depth visited)))
```

Branches via `conde`:
1. If inventory covers the demand entirely → `(satisfied spec-id qty allocation)`
2. If remaining > 0 → try `produce-branch` (find recipes, scale via CLP(FD),
   recurse on inputs) or give up → `(unmet spec-id remaining)`

**`plan-o`** (plan-relation.scm) — Orchestrator:

Collects all open demands (intents from the plan-store) and threads them
through `demand-o`. The result is a complete plan term.

```scheme
(define* (plan-o ctx plan #:key (max-depth 10) (demand-order #f))
  (let* ((demands (if demand-order (sort raw demand-order) raw)))
    (fresh (sums-final)
      (all-demands-o ctx demands plan initial-sums sums-final
                     #:max-depth max-depth))))
```

The demand ordering is **not hardcoded** — it's an optional parameter. The
algorithm is neutral; the social layer (governance) provides priorities.

#### Additional domain relations

| Relation | File | Purpose |
|----------|------|---------|
| `zone-o`, `nfp-o` | `ddmrp.scm` | DDMRP zone classification via CLP(FD) |
| `sne-o` | `sne.scm` | Socially Necessary Effort (labor cost) |
| `signal-tag-o` | `signals.scm` | Signal ↔ intent conversion |
| `provenance-o`, `destination-o` | `trace.scm` | Transitive flow tracing |

**Where to find it:** `planner/lib/relational/` (all files)

### The separation in practice

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer A: Generic Solver (domain-agnostic)                           │
│                                                                      │
│  kanren.scm — unification, search, streams                           │
│  kanren-constraints.scm — CLP(FD), disequality, propagation          │
│                                                                      │
│  Could solve Sudoku, type inference, circuit design — anything.      │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────┴──────────────────────────────────────┐
│  Layer B: Bridge (thin adapter)                                       │
│                                                                       │
│  kanren-planning.scm — <plan-ctx>, run-plan, project, in-list-o       │
│                                                                       │
│  Adds planning state threading. No domain knowledge.                  │
└───────────────────────────────┬───────────────────────────────────────┘
                                │
┌───────────────────────────────┴───────────────────────────────────────┐
│  Layer C: Domain Relations (ValueFlows-specific)                       │
│                                                                        │
│  allocate-o — buffer-aware CLP(FD) allocation                          │
│  demand-o — demand → plan-term (recipes, scaling, recursion)           │
│  plan-o — orchestrate all demands into complete plan                   │
│  zone-o, sne-o, signal-tag-o, provenance-o — domain algebras          │
│                                                                        │
│  These define WHAT to search for. The solver defines HOW to search.    │
└────────────────────────────────────────────────────────────────────────┘
```

If you wanted to use the solver for a different domain — say, scheduling
classroom timetables — you'd keep Layers A and B, replace Layer C with
timetable relations, and everything would work. The solver doesn't know it's
planning economic flows.

---

## 4. How Federation Works

Federation coordinates planning across scope boundaries. There are two
federation implementations — imperative and relational — sharing the same
`^store-registry` for cross-scope references.

### Imperative federation (plan-federation.scm)

A **monoidal fold** over the scope hierarchy:

1. `build-hierarchy` — construct children-of map + topological sort (post-order DFS)
2. `fold-scopes` — plan each scope bottom-up, children before parents
3. `match-laterally` — greedy surplus-deficit matching across sibling scopes

```scheme
;; planner/lib/planning/plan-federation.scm
(plan-federation scope-ids horizon ctx plan-scope-fn
  #:parent-of parent-of #:registry registry)
```

### Relational federation (relational/federation.scm)

A **hierarchical lazy-stream protocol**. Every node (leaf or parent) produces
the same interface:

```scheme
;; planner/lib/relational/federation.scm

;; federation-result = ((scope . id)
;;                      (plan . ...)
;;                      (deficits . ...)
;;                      (surpluses . ...)
;;                      (residual . number))

(define (scope-stream facts scope-id ctx-map children-of)
  (let ((children (or (assoc-ref children-of scope-id) '())))
    (if (null? children)
        (leaf-stream scope-id ctx-map)           ;; miniKanren search
        (parent-stream facts scope-id children ctx-map children-of))))
```

**Leaf scopes** run `plan-o` via miniKanren directly, extracting
deficits/surpluses from the plan term.

**Parent scopes** interleave their children's streams, then laterally match
surpluses against deficits across siblings. The `advance-worst` strategy
finds the child with the largest unmatched deficit and pulls its next result.
Search is bounded by `*max-steps*` (50).

**Key property:** Consumers of `scope-stream` don't know or care whether
they're pulling from a leaf (miniKanren search) or a parent (interleaved
children + matching). The protocol is uniform at every level.

**Immutable state makes this work:** Facts are plain S-expressions. The
substitution is a persistent intmap. Constraint stores use functional updates.
When `conde` branches, each branch gets its own copy of the allocation state
for free — no explicit forking needed.

**Where to find it:**
- Imperative: `planner/lib/planning/plan-federation.scm`
- Relational: `planner/lib/relational/federation.scm`
- Cross-scope refs: `planner/lib/planning/store-registry.scm`

---

## 5. File Reference Index

### Goblins integration / scope architecture
| File | What it does |
|------|-------------|
| `planner/lib/scope-root.scm` | Scope = vat coordinator (90 lines) |
| `planner/lib/observation/observer.scm` | 5-phase fold kernel, `bcom` transactions |
| `planner/lib/planning/planning.scm` | `^plan-store` — intents, commitments, plans |
| `planner/lib/observation/account.scm` | `^account-store` — commune labor-credits |
| `planner/lib/knowledge/recipes.scm` | `^recipe-store` — recipes, processes, flows |
| `planner/lib/planning/store-registry.scm` | Cross-scope qualified refs |
| `planner/lib/planning/plan-federation.scm` | Imperative federation (hierarchy fold) |

### Generic relational solver
| File | What it does |
|------|-------------|
| `module/playnet/kanren.scm` | Core microKanren (312 lines) |
| `module/playnet/kanren-constraints.scm` | CLP(FD) + symbolic constraints (964 lines) |
| `module/playnet/kanren-planning.scm` | Bridge: `<plan-ctx>`, `run-plan`, `project` (217 lines) |

### Domain relations (ValueFlows planning)
| File | What it does |
|------|-------------|
| `planner/lib/relational/planning-facts.scm` | Lift VF records to tuples, build indexes |
| `planner/lib/relational/allocation.scm` | Buffer-aware CLP(FD) allocation |
| `planner/lib/relational/demand-relation.scm` | Core demand → plan-term relation |
| `planner/lib/relational/plan-relation.scm` | Orchestrate all demands |
| `planner/lib/relational/federation.scm` | Lazy-stream federated search |
| `planner/lib/relational/ddmrp.scm` | DDMRP zone classification via CLP(FD) |
| `planner/lib/relational/sne.scm` | Socially Necessary Effort |
| `planner/lib/relational/signals.scm` | Signal ↔ intent conversion |
| `planner/lib/relational/trace.scm` | Transitive provenance/destination |
| `planner/lib/relational/compute.scm` | Ground computations (ADU, DLT, scheduling) |

### Networking
| File | What it does |
|------|-------------|
| `module/goblins/ocapn/netlayer/reticulum.scm` | OCapN over Reticulum mesh |
| `docs/RETICULUM-NETLAYER.md` | Full networking documentation |

### Tests
| File | What it does |
|------|-------------|
| `planner/tests/scope-integration.scm` | Full VF lifecycle (48 checks) |
| `planner/tests/relational-planner.scm` | Relational solver tests (47 checks) |
| `planner/tests/algorithms-foundation.scm` | DDMRP, SNLT, SNE (37 checks) |
| `planner/tests/planning-federation.scm` | 3-scope federation (20 checks) |

### Other architecture docs
| File | What it does |
|------|-------------|
| `ARCHITECTURE.md` | System overview, Goblins primitives, Hoot/WASM |
| `planner/architecture.md` | Layer 0-4 diagram, categorical structure |
| `docs/goblin-chat.scm` | Async messaging patterns (`<-`, `on`, promises) |
