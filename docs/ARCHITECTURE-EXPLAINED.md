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

**The message interface is self-introspection.** The `federation-result` a
scope emits is not an external description imposed by its parent — it's the
scope's own self-assessment, discovered through its own relational search.
When a leaf runs `plan-o` and produces `(deficits . ((spec-flour 20)))`,
that is simultaneously:

1. **Self-knowledge:** "I can't satisfy 20 flour from my own inventory/recipes"
2. **A message to my parent:** "I have a deficit of 20 flour for lateral matching"

The parent doesn't inspect the child's stores or tell it what its deficits are.
It only sees the `federation-result` the child chose to emit. Then the parent
composes its children's results via `evaluate-state` and emits *its own*
`federation-result` — which is now the parent's self-description, legible to
the grandparent. Self-knowledge and inter-scope communication are the same act
at every level of the hierarchy.

**Uniform protocol:** Consumers of `scope-stream` don't know or care whether
they're pulling from a leaf (miniKanren search) or a parent (interleaved
children + matching). The protocol is the same at every level.

**Immutable state makes this work:** Facts are plain S-expressions. The
substitution is a persistent intmap. Constraint stores use functional updates.
When `conde` branches, each branch gets its own copy of the allocation state
for free — no explicit forking needed.

**Where to find it:**
- Imperative: `planner/lib/planning/plan-federation.scm`
- Relational: `planner/lib/relational/federation.scm`
- Cross-scope refs: `planner/lib/planning/store-registry.scm`

---

## 5. Infrastructure as Live-Resource Actors

Economic resources can also be actors. A compute resource, a memory pool, or a
storage volume IS a Goblins actor in the scope's vat — with live state tracking
available capacity via `reserve`/`release`.

### The two numbers

The observer and the live-resource actor track different things:

- **Observer:** total capacity (what exists). Changed by `'raise`/`'lower` events.
- **Live-resource actor:** available capacity (what's free right now). Changed by
  `reserve`/`release` calls.

The VF `'use` action has `no-effect` on accounting quantities — correct, because
using a machine doesn't destroy it. The machine still exists with full capacity.
What changes is its availability, which is operational state, not stock accounting.

### How the planner sees it

When `lift-planning-facts` builds inventory tuples, it checks the scope's
`^live-registry`. If a resource-id has a live-resource actor, the planner sees
`available` instead of `accounting-quantity`:

```scheme
;; planner/lib/relational/planning-facts.scm (inventory lifting)
(let* ((rid (economic-resource-id r))
       (live (and live-registry ($ live-registry 'get rid)))
       (qty (if live
                ($ live 'available)              ;; live: available capacity
                (measure-qty (economic-resource-accounting-quantity r)))))
  ;; → (inventory "cpu-1" "spec:compute" 12 "dc-1")
```

The relational planner, `allocate-o`, `demand-o`, federation — none of them
know the difference. They see an inventory tuple with a number. Whether it's
12 kg of wheat or 12 available cpu-hours is the same to the solver.

### Execution: atomic within a vat turn

Reserve capacity and record the economic event in the same `with-vat` turn.
Both succeed or both roll back:

```scheme
(with-vat vat
  (let ((rsv-id ($ live-resource 'reserve 4)))        ;; bcom: available 16→12
    ($ observer 'record-event use-compute-event)))     ;; fold logs the event
  ;; Atomic. If reserve fails → turn aborted, event not recorded.
```

### Cross-scope distribution

A live-resource actor is just an actor. Within the scope: `$` (synchronous).
Across scopes: `<-` over OCapN (async). A browser scope's planner sees a
deficit in compute; federation matches it against the server scope's surplus.
The actual reservation crosses the vat boundary asynchronously — no extra code.

**Where to find it:**
- `planner/lib/observation/live-resource.scm` — `^live-resource` actor
- `planner/lib/observation/live-registry.scm` — `^live-registry` (resource-id → actor ref)
- `planner/lib/scope-root.scm` — scope-root holds the live-registry
- `planner/lib/relational/planning-facts.scm` — inventory lifting checks live-registry

---

## 6. Generic Interface Layer

Scopes are accessible through a generic interface layer that decouples **what
you're interacting with** (the backend) from **how you're interacting** (the
transport). A Telegram groupchat, a Matrix room, a terminal REPL, or any
messaging platform can bind to a scope and let users issue commands against
the observer and receive alert output.

### Backend protocol

The channel actor (`^channel`) is backend-agnostic. It talks to a backend via
`<-` (async), so the backend can be local or on any remote machine via OCapN.
A backend implements three methods:

```
(handle user-id command-name args-string) → ('response text) | ('error reason)
(available-commands)                      → list of strings
(wire-output sink-ref)                    → void
```

A VF planning scope is one backend (`^scope-backend`). A chat room, a kanban
board, or any other actor system could be another — the channel doesn't care.

### Transport adapters

A transport adapter implements three methods:

```
(send-message channel-context text)       → void
(send-formatted channel-context blocks)   → void (optional)
(parse-command raw-text)                  → (values cmd args) | (values #f #f)
```

Adding a new messaging platform means implementing these three methods. The
Telegram adapter uses `^key-pool` with a `telegram-provider` profile for the
bot token — same sealed credential pattern as API keys, same round-robin,
same health tracking.

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     ^channel-manager                          │
│  (lifecycle: create, attach remote, destroy)                  │
│  Takes a backend-factory fn; also accepts remote OCapN refs   │
└────────┬─────────────────────────────────────────────────────┘
         │ spawns
         ▼
┌──────────────────────────────────────────────────────────────┐
│                    ^channel (generic)                          │
│                                                               │
│  backend  ← any actor implementing backend protocol           │
│  sink     ← ^output-sink (the print side of the channel)      │
│  transport ← ^transport-adapter (Telegram, REPL, Matrix, ...) │
│  members  ← hashmap: user-id → capabilities                   │
│                                                               │
│  Uses <- (async) to talk to backend — works over OCapN        │
│  so the backend can be local or on any remote machine.        │
└────────┬─────────────────────────────────────────────────────┘
         │ <- (async, works remote)
         ▼
┌──────────────────────────────────────────────────────────────┐
│             Backend Protocol (3 methods)                       │
│                                                               │
│  Implementations:                                             │
│    ^scope-backend  — VF scope + org + command dispatch         │
│    (future)        — chat, kanban, any actor system            │
│    any OCapN ref   — remote scope on another machine           │
└───────────────────────────────────────────────────────────────┘
```

### Output routing

The `^output-sink` is the print side of a channel — analogous to `^output-port`
in `gplay.scm` but routed through a transport instead of a local port. When the
transport is attached, output is delivered immediately. When offline, it queues
(same pattern as `^mailbox`) and flushes on reconnect.

A `^tee-alert-store` proxy interposes on the scope's alert pipeline. When
`record-and-monitor` pushes alerts to the alert-store, the tee forwards them
to the output sink automatically — no changes to existing execution code.

### Scope-per-groupchat lifecycle

1. First message (e.g. `/start`) → `^channel-manager` creates a channel + scope
2. Mapping `"tg-<chat_id>" → ^channel ref` persists via Goblins snapshot/restore
3. Across restarts: channel-manager restores, transport adapters `rewire`
   (same pattern as `^topic-observer`)
4. Multiple channels can share one scope (different teams, different permissions)
5. A channel can bind to a remote scope via `attach-channel` with an OCapN ref

**Where to find it:**
- `module/playnet/interface/channel.scm` — `^channel` (backend-agnostic)
- `module/playnet/interface/scope-backend.scm` — `^scope-backend` + convenience constructor
- `module/playnet/interface/command-dispatch.scm` — `^command-dispatch` + standard command table
- `module/playnet/interface/notification-sink.scm` — `^output-sink` + `^tee-alert-store`
- `module/playnet/interface/transport.scm` — transport protocol helpers
- `module/playnet/interface/adapters/telegram.scm` — Telegram adapter + `telegram-provider`
- `module/playnet/interface/adapters/repl.scm` — terminal adapter

---

## 7. Social Planning Replaces Container Orchestration

Kubernetes schedules containers onto nodes by matching resource requests against
available capacity. playnet's planner does the same thing — but for any economic
resource, governed by the people who use it, not by a centralized scheduler.

### The mapping

| Kubernetes | playnet |
|-----------|---------|
| Node (machine with resources) | Scope with `^live-resource` actors for CPU, memory, storage |
| Pod (unit of deployment) | Scope vat (a planning scope running on some machine) |
| Resource requests/limits | ValueFlows intents ("I need 4 CPU-hours by Thursday") |
| Scheduler (bin-packing) | `allocate-o` + `demand-o` (relational search over inventory) |
| Horizontal autoscaler | DDMRP buffer zones — capacity in red zone emits demand signal |
| Service discovery | OCapN sturdyrefs — reachable by capability URI regardless of machine |
| Config management | Guix System — entire OS is a Scheme expression (`machines.scm`) |
| Rolling updates | `guix deploy` — atomic OS reconfiguration, `guix system roll-back` |
| Multi-cluster federation | `^store-registry` + lateral matching across scopes |

### How it works

A scope is a vat running on some machine. The compute and memory it consumes
are `^live-resource` actors in an infrastructure scope:

```scheme
;; Infrastructure scope tracks server capacity
(define cpu-resource (spawn ^live-resource "cpu-1" "spec:compute" 64 60 "cores" "dc-1" '()))
(define mem-resource (spawn ^live-resource "mem-1" "spec:memory" 256 200 "GB" "dc-1" '()))
```

When a new scope vat is created, the planner reserves capacity:

```scheme
(with-vat infra-vat
  (let ((rsv ($ cpu-resource 'reserve 4)))          ;; 4 cores for this scope
    ($ observer 'record-event
       (make-economic-event "use" "spec:compute" 4 "cores"
                            #:provider "dc-1"
                            #:receiver scope-id))))
```

The planner sees this as inventory — `(inventory "cpu-1" "spec:compute" 60 "dc-1")`.
When available capacity drops into the DDMRP yellow or red zone, the system
emits a demand signal: "we need more compute." That signal is a ValueFlows
intent, visible to any agent in the federation. A node operator sees it and
donates capacity — or the system provisions new resources automatically.

### Why this is different from Kubernetes

Kubernetes optimizes a **global objective function** — pack pods onto nodes
to minimize resource waste. The scheduler decides. Humans configure resource
requests and limits; the system does the rest.

playnet makes resource flows **visible**. The planner doesn't decide where
scopes run — it shows the commune what capacity exists, what's being used,
where deficits are forming, and what options are available. The commune
chooses. Buffer zones provide early warning. Federation shares surplus.
Governance actors control who can allocate what.

The other difference is scope. Kubernetes manages containers. playnet
manages anything the planner can see — CPU, memory, storage, API keys,
GPU time, bandwidth, wheat, flour, labor hours. It's all inventory tuples
to `allocate-o`. The same `demand-o` relation that plans bread production
plans compute allocation. The same DDMRP that prevents flour stockouts
prevents capacity exhaustion.

### Scope mobility

Because `^channel` talks to its backend via `<-` (OCapN async), moving a
scope from one machine to another is transparent to every interface bound
to it. The sturdyref follows the scope. The Telegram groupchat, the web
REPL, the CLI — none of them notice. The compute/memory consumed by hosting
that scope shows up as economic events in the planner, which can reason
about placement decisions the same way it reasons about any other allocation.

**Where to find it:**
- `planner/lib/observation/live-resource.scm` — `^live-resource` actor
- `planner/lib/observation/live-registry.scm` — `^live-registry` (resource-id → actor ref)
- `planner/lib/relational/allocation.scm` — `allocate-o` (buffer-aware CLP(FD))
- `planner/lib/relational/demand-relation.scm` — `demand-o` (demand → plan-term)
- `planner/lib/relational/planning-facts.scm` — inventory lifting from `^live-resource`
- `module/playnet/interface/channel.scm` — `^channel` uses `<-` for remote backends
- `module/playnet/interface/scope-backend.scm` — scope as movable backend

---

## 8. File Reference Index

### Goblins integration / scope architecture
| File | What it does |
|------|-------------|
| `planner/lib/scope-root.scm` | Scope = vat coordinator (90 lines) |
| `planner/lib/observation/observer.scm` | 5-phase fold kernel, `bcom` transactions |
| `planner/lib/planning/planning.scm` | `^plan-store` — intents, commitments, plans |
| `planner/lib/observation/account.scm` | `^account-store` — commune labor-credits |
| `planner/lib/knowledge/recipes.scm` | `^recipe-store` — recipes, processes, flows |
| `planner/lib/observation/live-resource.scm` | `^live-resource` — infrastructure as actor |
| `planner/lib/observation/live-registry.scm` | `^live-registry` — resource-id → actor ref |
| `planner/lib/planning/store-registry.scm` | Cross-scope qualified refs |
| `planner/lib/planning/plan-federation.scm` | Imperative federation (hierarchy fold) |

### Interface layer
| File | What it does |
|------|-------------|
| `module/playnet/interface/channel.scm` | `^channel` — backend-agnostic, uses `<-` for remote |
| `module/playnet/interface/scope-backend.scm` | `^scope-backend` — VF scope as channel backend |
| `module/playnet/interface/channel-manager.scm` | `^channel-manager` — lifecycle + remote attach |
| `module/playnet/interface/command-dispatch.scm` | `^command-dispatch` — /command routing |
| `module/playnet/interface/notification-sink.scm` | `^output-sink` + `^tee-alert-store` |
| `module/playnet/interface/transport.scm` | Transport adapter protocol |
| `module/playnet/interface/adapters/telegram.scm` | Telegram adapter + `telegram-provider` |
| `module/playnet/interface/adapters/repl.scm` | Terminal REPL adapter |

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
| `docs/ARCHITECTURE-EXPLAINED.md` | This document — how the system works end-to-end |
