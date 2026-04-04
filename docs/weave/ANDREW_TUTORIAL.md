# Weave: A Walk Through playnet

## What Does This Repo Offer, and What Does It Make Possible?

playnet is a commons operating system written entirely in Guile Scheme. Its core slogan is "less work, more play" — minimize socially necessary labor, maximize free time.

What makes it unusual is that everything is the same material — S-expressions all the way down:

- **The OS configuration** is a Scheme expression (`deploy/guix/machines.scm`). Pushing to `main` atomically reconfigures the server via `guix deploy`. Rollback is one command.
- **The economic planning engine** uses ValueFlows records (47 record types) to track resources, processes, and commitments — all as Scheme data.
- **The governance layer** — organizations, roles, voting, delegation — is actors holding S-expressions with immutable history.
- **The browser interface** compiles Scheme to WASM via Hoot, so users interact with the same language the system is built in.
- **The networking** uses Goblins actors over OCapN (Object Capability Network), meaning any actor is reachable over TCP, LoRa, I2P, or packet radio via Reticulum mesh.

A community can pool donated resources (API keys, GPUs, storage, bandwidth), plan their allocation transparently using economic planning algorithms (DDMRP, dependent demand), and govern that process democratically — all without a central scheduler. Think "Kubernetes but the commune decides" instead of a bin-packing algorithm.

The key insight is that capability security comes from the language itself — closures are unforgeable references, Goblins actors extend that to distributed systems, and OCapN extends it across networks. So the security model, the governance model, and the economic model are all the same thing.

---

## ValueFlows Agent/Relationship Roles

### The Three Agent Types

ValueFlows defines three kinds of agents:

- **Person** — an individual human
- **Organization** — a collective (commune, coop, federation)
- **Ecological agent** — a non-human entity (a watershed, a forest, a species)

That last one means the planning system can represent "the river needs 50,000 gallons/day minimum flow" as a genuine economic demand, not an externality someone bolts on later.

### Relationship Roles

An **agent-relationship-role** defines a type of relationship between agents:

- **label** — how the subject relates to the object (e.g., "member-of")
- **inverse-label** — how the object relates to the subject (e.g., "has-member")
- **in-scope-of** — which organization governs this relationship

An **agent-relationship** is an actual instance: "Alice (subject) -> member-of (role) -> Bread Commune (object)."

These are all queryable through miniKanren, so you can ask relational questions like "who are all the members of the bread commune?" or "what organizations is Alice part of?" and get answers by search rather than by writing lookup code.

### Connection to Goblins Capabilities

In Goblins, a capability is just a reference to an actor. If you have a reference, you can call its methods. If you don't, you can't. There's no access control list — possession of the reference *is* the permission.

When Alice has the `member-of` relationship with the Bread Commune, what that concretely means is: she holds actor references that let her do member-level things. The VF relationship is the *legible record* of what capability she was granted. The Goblins reference is the *enforcement*.

The three-seal governance pattern makes this concrete. An org has three seals:

- **gov-seal** — can change the org's rules (the validator)
- **infra-seal** — can modify infrastructure bindings
- **member-seal** — can modify member bindings

Each seal is a Goblins capability (an actor ref with a sealer/unsealer pair). Holding the `member-seal` means you can write to names prefixed with `member-*`. The seal *is* the role.

### The Provider/Recipient Connection

Every VF economic event has a **provider** and a **receiver**. These aren't fixed roles — they come from the action. When Alice bakes bread:

- She's the **provider** of labor (action: `work`)
- She's the **provider** of bread (action: `produce`)
- When she hands it to Bob, she's the **provider** in a `transfer`, Bob is the **receiver**

The observer indexes all of this, so you can query "what has Alice provided?" or "what has the commune received?"

The agent-relationship-roles give you the *structural* picture (who's a member, who's a delegate); the provider/receiver flow gives you the *dynamic* picture (who's actually doing what).

### Connection to the Observer

The **observer** is the system's memory — a left-fold over economic events that builds up the state of the world. When Alice does 4 hours of baking (a VF `work` event), the observer processes it through five phases:

1. **Append** — store the event immutably
2. **Index** — update inverted indexes (by agent, by resource spec, by action, etc.)
3. **Apply effects** — update resource quantities based on the action's semantics (`work` doesn't change on-hand quantity, but `produce` does)
4. **Implied transfer** — deduce custody/rights changes (e.g., `transfer` implies the recipient now has custody)
5. **Track** — update the indexed inventories (accounts)

The observer makes relationship roles *real over time*. It's not enough to say "Alice is a member" — the observer records every economic event she participates in, which feeds into:

- **Contribution accounting** — her labor hours are tracked
- **Expression weight** — her voice in governance is proportional to her observed participation
- **Planning** — the planner sees her capacity and her skills as separate resources

The loop: **roles grant capabilities -> capabilities enable economic actions -> the observer records those actions -> the records inform governance weight -> governance decides who gets what roles.**

---

## Org Transformation: Scopes, Structure, and Roles

### What is a Scope?

A **scope** is one self-contained economic space. Concretely, it's a Goblins **vat** — an isolated actor context where all the actors inside can talk to each other synchronously.

Think of it as: one commune, one coop, one workshop — whatever the organizational boundary is. Everything that org needs to track its economy lives inside its scope.

### What's Inside a Scope?

Ten store actors:

| Store | What it holds |
|---|---|
| **recipe-store** | Knowledge — recipes, processes, flows (how to make things) |
| **agent-store** | Directory — who's here, what roles they have, their relationships |
| **observer** | History — the append-only log of economic events, plus indexed inventories |
| **plan-store** | Plans — intents, commitments, proposals, agreements |
| **buffer-zone-store** | DDMRP buffer definitions per resource |
| **account-store** | Labor-credit accounting — contribution tracking per agent |
| **capacity-buffer-store** | Infrastructure capacity buffers |
| **spatial-thing-store** | Location hierarchy (where things are) |
| **snapshot-store** | Immutable snapshots for replay |
| **alert-store** | Buffer zone warnings and monitoring alerts |

Because they're all in the same vat, any operation that touches multiple stores is **atomic** — one vat turn, all or nothing.

### How is it Organized?

A `^scope-root` actor holds references to all the stores. It's the entry point — if you have a reference to the scope root, you can ask it for any store.

But you don't have to give someone the root. You can give them a reference to just the recipe-store, or just a read-only facet of the observer. Capability security means the org structure *is* the permission structure. What you can see and do depends on which references you hold.

### Does it Have Roles?

Yes, through two mechanisms layered together:

**1. VF agent-relationship-roles** (the legible record) — these live in the agent-store. "Alice is a member of the Bread Commune." "Bob is a delegate." Queryable data.

**2. The three-seal governance pattern** (the enforcement) — gov, infra, and member seals. Each is a Goblins capability. Whoever holds the `member-seal` can write to member-scoped bindings.

**3. Expression weight** (the degree of voice) — not all members have equal say. Your expression weight is derived from your observed economic participation:

```
contribution_claim = (your_contribution / total_contribution) * available_pool
solidarity_supplement = (1 - capacity_factor) * (welfare_fund / unmet_capacity)
```

This isn't configured by an admin. It's computed from the observer's records.

### How Scopes Relate to Each Other

Scopes are isolated, but they can federate. The planner can fold across a hierarchy of scopes — plan children first, then parents, then match surpluses and deficits laterally across peers. Each scope keeps its own governance, its own observer, its own rules. Federation is coordination, not control.

Because scopes communicate via OCapN, one scope could be on your laptop and another on a server across the world.

---

## How Do They Evolve? Metaprogramming, Capabilities, Metabolic Coherence

### Homoiconic State and Rollback

Every org state is a VF record or an S-expression. History is immutable — each change creates a versioned snapshot containing the full state (bindings, validator expression, validator procedure). Walking history using parent pointers gives a chain from current state back to genesis. Any prior state is one `rollback!` away.

### The Metacircular Evaluator

`gplay.scm` contains a full Scheme evaluator that:

- Runs in the browser (Hoot/WASM)
- Evaluates user expressions inside an org's bindings
- Handles control flow, binding forms, higher-order functions, and even embedded miniKanren (`fresh`, `conde`, `run`, `run*`)
- Records history entries: `(version, expressor-id, expression, parent-version, snapshot, signature)`
- Signs history entries with the expressor's keypair

### Validator Evolution via `enact!`

The `enact!` method installs a new validator — the function that governs what changes are allowed. It performs two checks:

1. The **current** validator must approve the new one
2. The **new** validator must accept its own installation (metacircular consistency)

This enables multi-stage governance transitions:

```scheme
;; Start: permissive
(enact! '(lambda (e n v pre post) #t))

;; Transition: require endorsement for validator changes
(enact! '(lambda (e n v pre post)
           (if (eq? n 'validator)
               (sealer-check e)
               #t)))
```

The validator can even be an actor ref, making governance distributed.

### System Self-Knowledge

`system-kb.scm` encodes the system's own structure as relational facts — `(depends browser evaluator)`, `(provides actors accountability)`, `(file actors "module/playnet/actors.scm")` — queryable via miniKanren. You can ask "what changes if I modify the kernel?" and get a transitive dependency chain with proof trace:

```scheme
(run* (proof) (trigger-chain-o 'push-to-main 'kernel proof))
;; => ((push-to-main github-actions guix-deploy guix kernel))
```

### Metabolic Coherence

This is how the system keeps its organizational boundaries aligned with economic reality. Three cycles run at different timescales:

**1. Economic cycle (continuous):** Events recorded in observer, accounts credit labor, expression weights shift.

**2. Planning cycle (periodic):** Lift planning facts from each scope, run relational search at leaves, lateral matching at parents. Plans produce commitments which become new events.

**3. Scope evolution cycle (threshold-triggered):** After planning, recompute metabolic coherence metrics:

- **Coherence** = internal flows / total flows (per scope). Range [0,1]. Low coherence means the scope's boundary doesn't match its economic reality.
- **Interdependence** = bilateral flows / external flows (per pair). High interdependence means two scopes are deeply intertwined.
- **Merge candidates** — pairs where interdependence exceeds a threshold
- **Split candidates** — scopes where coherence falls below a threshold

When thresholds are crossed, proposals are generated, ranked by estimated improvement to the `boundary-objective` (weighted average coherence), and citizens vote via `^plan-expression`. Winning proposals execute scope merges, splits, or resource transfers.

The system self-corrects: organizational boundaries drift toward metabolic reality, not the other way around.

---

## Proportional Governance

Proportional governance connects economic participation to democratic voice. It's about expression weight — not voting power in the one-person-one-vote sense, but how much influence your preferences carry when the commune chooses between plans.

### The Core Formula

Each citizen's expression weight in a scope is derived from two components:

**Contribution claim** — proportional to your labor:

```
contribution_claim = (gross_contribution / total_social_svc) * available_pool
```

**Solidarity supplement** — boosts people with less capacity:

```
solidarity_supplement = (1 - capacity_factor) * (welfare_fund / sum_unmet_capacity)
```

The **welfare allocation rate** self-corrects: when everyone has full capacity (CCF=1), the welfare fund is zero. When many people have reduced capacity, the welfare fund grows automatically.

### Concrete Example

```
Alice: 300 hours contributed, CCF=1.0 (full capacity)
Bob:   150 hours contributed, CCF=0.5 (recovering from illness)
Carol:   0 hours contributed, CCF=0.0 (advanced dementia)

Total: 450 hours, pool = 1000 SVC
welfare_rate = 0.6, available_pool = 400, welfare_fund = 600

Alice: contribution=266.7, solidarity=0,   total=266.7
Bob:   contribution=133.3, solidarity=200, total=333.3
Carol: contribution=0,     solidarity=400, total=400
```

Carol — who contributes nothing due to dementia — has the highest expression weight. The system recognizes that those with the least capacity have the greatest stake in how resources are allocated.

### Delegation

Citizens can delegate fractions of their expression weight to delegates, per-scope:

- Delegation is **fractional** — give 30% to Alice, 20% to Bob, keep 50% direct
- Delegation is **revocable** at any time via `^delegation-map`
- Direct stance **always overrides** delegation — if you vote directly, your full weight counts
- Delegation snapshots are **frozen at ballot open time** — no last-minute manipulation

### Ballots and Plan Expression

**`^ballot`** — for yes/no decisions. Tallies expression-weighted stances, with delegation flowing transitively.

**`^plan-expression`** — for choosing between plans. Citizens distribute their claim capacity across competing plans. Each plan's score is the sum of received weights. Plans are ranked by total expression weight.

### Sybil Resistance

- **Splitting labor across fake IDs** gains nothing — your share of total labor is unchanged
- **Gaming the solidarity supplement** requires a governance decision to set CCF=0 — community verification, not self-declaration
- **Cross-scope identity** is handled by OCapN petnames and introduction chains

---

## Transport Adapters: Hook Up to Any Interface

### The Three-Layer Architecture

```
Backend (any actor: handle / available-commands / wire-output)
    |
Channel (^channel: backend-agnostic coordinator)
    |
Transport Adapter (send-message / send-formatted / parse-command)
    |
Output Sink (^output-sink: queues and routes messages)
```

### The Transport Protocol

A transport adapter implements three methods:

1. **`parse-command`** — turn raw text into a command name and arguments. A REPL adapter parses `,command args`. A Telegram adapter parses `/command args`.
2. **`send-message`** — deliver plain text to the channel context (a chat ID, room ID, etc.)
3. **`send-formatted`** — deliver rich/structured content (optional)

### The Channel

`^channel` binds a transport adapter to a backend and an output sink. When input arrives:

1. The transport parses it into a command
2. The channel dispatches to the backend via `<-` (async)
3. The backend returns `('response text)` or `('error reason)`
4. The channel sends the result back through the transport

### The Backend

`^scope-backend` implements the backend protocol for a VF planning scope. It delegates commands to a dispatch table and records economic events through the observer. Alerts from DDMRP buffer monitoring auto-forward to the output sink via a `^tee-alert-store` proxy.

### Remote Transparency

The backend is just an actor ref. Via OCapN, the scope can be on this machine or any other — `<-` works identically for local and remote refs. A Telegram group chat becomes a living economic scope. Members type `/inventory wheat` to check stock, `/alerts` to see buffer zone warnings.

To add a new interface (Matrix, IRC, a web dashboard), implement `parse-command` and `send-message`, wire it to a channel, and you're done. The backend doesn't change.

---

## Explain metaprogramming
 The Universe Is A Question You Can Run Backwards                   
                                                                     
  Normally when you write a program, you make a one-way machine. You 
  put facts in the top. Answers fall out the bottom. The machine has 
  a direction. It only knows how to go forward.
                                                                     
  But look at what == actually is:                                   
   
  (define (== u v)                                                   
    (lambda (st)  
      (let ((s (unify u v (state-subst st))))
        (if s (list (cons s (state-counter st)))                     
              '()))))                                                
                                                                     
  It's not assignment. It's not comparison. It's a declaration that  
  two things are the same shape. The engine figures out which
  direction to flow. u and v can both be unknown. You're not saying  
  "set u to v." You're saying "u and v are the same thing, universe —
   please reconcile."

  This is the first miracle: you write the relationship, not the     
  procedure.
                                                                     
  ---             
  The Grammar Doesn't Parse — It Is Meaning
                                                                     
  Look at demand-question-o:
                                                                     
  (define (demand-question-o ctx s0 s goal)
    (fresh (qty spec-id s1)                                          
      (conde                                                         
        ((words-o '("how" "do" "we" "make") s0 s1))                  
        ((word-o "make" s0 s1))                                      
        ((word-o "produce" s0 s1)))
      (qty-spec-np-o ctx s1 s qty spec-id)                           
      (== goal `(demand ,spec-id ,qty))))                            
                                                                     
  Ground s0 with words → you get goal. Ground goal with a meaning →  
  you get s0. The same code parses and generates. The grammar is the 
  language, not a description of it. You don't have a parser and a   
  pretty-printer. You have one thing that is both simultaneously,
  depending on which end you squeeze.

  This is the second miracle: direction is not baked in. You choose  
  it at query time.
                                                                     
  ---             
  map-goal-o Is Where It Gets Fractal
                                                                     
  (define (map-goal-o items item->goal-o results)
    (if (null? items)                                                
        (== results '())                                             
        (fresh (result rest)
          (item->goal-o (car items) result)                          
          (map-goal-o (cdr items) item->goal-o rest)                 
          (== results (cons result rest)))))
                                                                     
  Normal map takes a function a → b and gives you [a] → [b].         
                                                                     
  map-goal-o takes a relation (a, b) → goal — and the whole thing is 
  itself a relation between items and results. You can run it
  forward: given items, find results. You can run it backward: given 
  results, find what items produced them. You can run it sideways:
  given partial items and partial results, fill in the gaps.

  The combinator lifts a relation over lists without changing what it
   is. The meta-level and the object-level are made of the same
  stuff.                                                             
                  
  This is the third miracle: abstraction doesn't cost you            
  bidirectionality. You keep the magic at every level.
                                                                     
  ---             
  transitive-closure-o Is A Proof That Knows Itself
                                                                     
  (define (transitive-closure-o edge-o from to trace . rest)
    (let ((depth (if (pair? rest) (car rest) 10)))                   
      (conde                                                         
        ((edge-o from to)                                            
         (== trace (list from to)))                                  
        ((fresh (mid rest-trace)
           (edge-o from mid)                                         
           (transitive-closure-o edge-o mid to rest-trace (- depth
  1))                                                                
           (== trace (cons from rest-trace)))))))
                                                                     
  This is asking: "can you reach to from from?" But trace is unified 
  with the path that proves it. The answer and the justification are
  the same object. You don't compute the result and separately       
  explain it. The explanation is the result.

  Ask the planner "what is needed for bread?" and you get back not   
  just "wheat" but the chain: bread ← flour ← wheat. The trace is the
   proof. The proof is the answer. You can't have one without the    
  other, because they're the same unification.

  ---
  Constraints Are Deferred Enlightenment

  (=/= x 'locked)
  (numbero qty)                                                      
  (rangeo qty 0 1000)
  (+fd consumed available needed)                                    
                  
  You're not computing. You're describing the shape of what's true,  
  before you know what it is. The constraint store CS and domain
  store FD in the state vector are like a cloud of partial knowledge 
  that gradually crystallizes.

  When you write (+fd x y z) and only x and y are known — the system 
  doesn't fail. It waits. It remembers the constraint. Later, when z
  shows up from somewhere else in the search, the propagator fires   
  and narrows everything. Variables talk to each other across time.

  The state isn't a snapshot of what you know. It's a living network 
  of implications that fires incrementally as the universe fills in.
                                                                     
  ---                                                                
  What It All Enables: The Program Becomes The Model
                                                                     
  Put it together.
                                                                     
  You write (ask ctx "how do we make 10 bread").                     
   
  Under the hood:                                                    
  - The grammar (a relation) parses the phrase bidirectionally
  - The lexicon (a relation) resolves words to facts via the live    
  world-state                                                    
  - The planner (a relation) searches backward from the goal through 
  recipes, inventory, transport                                     
  - The narrator (the same grammar relations, run in reverse)        
  explains the plan back in words                            
  - Constraints thread through all of it, narrowing the search       
  without enumerating                                         
                                                                     
  The whole pipeline — language, reasoning, explanation — is one 
  relational machine. There's no separate parser, planner, and       
  explainer. There's no translation between layers. It's turtles all
  the way down, and each turtle is made of the same (lambda (st)     
  ...).           

  The program doesn't process meaning. It is meaning, declared as    
  relationships, from which computation emerges in whatever direction
   you need.                                                         
                  
  That's what the combinators enable. Not better code. A different   
  kind of code — one where the question and the answer are the same
  object, seen from different angles.    

---

## How Does This System Create Infinitely Scalable Self-Organizing Infrastructure Through Social Planning?

### The Core Mechanism: Federation

Each scope is a vat. Scopes coordinate via a recursive, lazy streaming protocol:

**Leaf scopes** run miniKanren search internally — find plans that satisfy demands from inventory and recipes, preferring lowest socially necessary effort.

**Parent scopes** don't solve plans — they orchestrate children's solutions. Pull one result from each child's stream, match children's surpluses to children's deficits laterally, and if residual demand remains, advance the worst child and repeat.

**Lateral matching** is the key move: a surplus in one scope flows to a deficit in another. Same spec, different scope, match the minimum quantity. This happens at every level of the hierarchy.

### Replacing Kubernetes

| Kubernetes | playnet |
|---|---|
| Node | Scope with live-resource actors for CPU, memory, storage |
| Pod | Scope vat (runs on some machine) |
| Resource requests/limits | VF intents ("I need 4 CPU-hours by Thursday") |
| Scheduler (bin-packing) | `allocate-o` + `demand-o` (relational search over inventory) |
| Horizontal autoscaler | DDMRP buffer zones — capacity entering red emits demand signal |
| Service discovery | OCapN sturdyrefs — reachable by capability URI regardless of machine |
| Config management | Guix System — entire OS is a Scheme expression |
| Rolling updates | `guix deploy` — atomic OS reconfiguration with rollback |
| Federation (multi-cluster) | Store registry + lateral matching |

**Critical difference:** Kubernetes has a central scheduler optimizing a global objective. playnet has a planner making resource flows *visible*. The commune sees the demand signals and chooses.

### The Generalization Pattern

Any donatable resource wrapped in a Goblins actor becomes poolable, plannable, and accountable:

- **GPU time** — usage is an EconomicEvent with cost, DDMRP over capacity
- **Storage** — reads/writes are events, buffer zones signal "we need more space"
- **Bandwidth** — a Reticulum mesh node offering relay capacity is an actor
- **CPU cycles** — volunteer compute on any OCapN-speaking machine
- **API keys** — the key-pool wraps keys as economic resources with round-robin allocation, health tracking, and contribution visibility for donors

### Self-Organization Through Metabolic Coherence

The system doesn't need a central authority to decide organizational structure. The scope evolution cycle watches the actual flow of resources:

1. Build a flow graph from observed economic events
2. Compute coherence (internal/total) per scope
3. Identify merge candidates (high bilateral interdependence) and split candidates (low internal coherence)
4. Generate proposals, citizens vote via expression-weighted plan selection
5. Execute merges, splits, or transfers

Scopes that are metabolically connected get matched together — even across continents. Scopes that have drifted apart get split. The structure emerges from economic interdependence, not administrative decree.

### Why It Scales

- **Relational search** at leaves means the planner explores all valid plans — cheapest first — without hand-written optimization logic
- **Lazy streams** mean federation doesn't compute everything upfront — it pulls results as needed
- **Immutable allocation state** means failed branches cost nothing to discard
- **OCapN** means scope placement is transparent — add machines, add scopes, the protocol is the same
- **DDMRP buffers** absorb variability locally, so planning doesn't cascade through the entire federation on every fluctuation
- **Threshold-triggered evolution** means scope boundaries only change when metabolic reality demands it, not on a schedule

The result is infrastructure that grows by people joining and donating resources, organizes itself by tracking where value actually flows, and governs itself through the democratic expression of the people who use it.

---

## Appendix: Key Concepts

### DDMRP (Demand-Driven Material Requirements Planning)

Traditional planning (MRP) takes a forecast and pushes it through the whole supply chain. The problem: forecasts are wrong, and small errors at the top become huge swings at the bottom (the "bullwhip effect").

DDMRP fixes this by placing **buffers** at strategic points. Each buffer has three zones:

- **Red** (bottom) — emergency, replenish immediately
- **Yellow** (middle) — reorder point, start producing/acquiring more
- **Green** (top) — healthy, well-stocked

Key calculations:
- **ADU** (Average Daily Usage) — actual consumption rate
- **NFP** (Net Flow Position) — on-hand + on-order - qualified demand

When NFP drops below the top of yellow, a replenishment signal fires. That signal becomes a VF intent, which the dependent demand algorithm unfolds into a concrete plan.

### Dependent Demand

If the commune needs 100 loaves of bread, that's independent demand. **Dependent demand** is everything that follows: flour, water, yeast, oven-hours. To get flour you need wheat and milling time. The algorithm does a breadth-first search through recipes: start with the top-level demand, look up its recipe, generate demands for all inputs, then look up *their* recipes, and so on until you hit existing inventory or raw inputs.

### miniKanren

A relational programming language. In normal programming, functions go one direction: input to output. In miniKanren, you write **relations** that can run in any direction. Define `parent-of` once, then ask "who are Alice's children?", "who is Dave's parent?", or "give me all parent-child pairs" — same relation, different queries.

The engine uses **unification** (bidirectional pattern matching) and **interleaving** (fair exploration of alternatives). The planner declares relations like `recipe-o`, `demand-o`, `allocate-o`, then asks `(run 1 (plan) (plan-o ctx plan))` to find the cheapest valid plan. miniKanren does the search.

### Capacity vs. Skills

Every agent gets exactly **one capacity resource** — their total available time/energy (e.g., 8 hours/day). **Skills are separate resources** — baking, carpentry, facilitation.

When the planner needs to satisfy a demand, it finds someone with both the right skill and remaining capacity. If Alice has the baking skill but she's committed 8 hours today, the planner can't assign her more work. One body, finite time — the model reflects reality.

### Substitution as Persistent Integer Trie

miniKanren stores variable assignments in a **substitution**. The naive approach (association list) requires O(n) scans. playnet uses an **intmap** — a trie keyed by variable counter with branching factor 16. Lookup is O(log16 n) per hop — 1-2 steps for thousands of variables.

"Persistent" means old versions survive when new ones branch off. When the search explores "try x=5 here, x=10 there," each branch gets its own substitution sharing most of its structure. Failed branches just get discarded — no mutation, no rollback.
