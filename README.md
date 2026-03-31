# playnet

<object data="docs/commons.pdf" type="application/pdf" width="100%" height="800px">
    <p>Your browser does not support viewing PDFs directly. <a href="docs/commons.pdf">Download the PDF</a> to view the full documentation.</p>
</object>

![playnet poster](playnet_poster.png)

_A self-evolving commons computer written entirely in Guile Scheme._

---

**playnet** is a computer environment where pushing to `main` can redeploy the entire operating system. Everything from the browser interface to the kernel configuration is a Scheme expression. Object capability security comes from the lambda calculus itself (as described in [_A Security Kernel Based on the Lambda-Calculus_](https://mumble.net/~jar/pubs/secureos/secureos.html)) — if you hold the reference, you have the authority; if you don't, you don't. The system runs in the browser (Hoot/WASM), on the desktop (native Guile), and on the server (Guix System), connected by mesh networking that works over LoRa radio, serial wire, I2P, TCP, or packet radio.

There is no gap between the system and its description. The organization's rules, state, and history are all S-expressions — the same representation the evaluator consumes. This is what makes the system self-reflective: it can inspect its own evolution, rollback to a prior state, and rewrite its own governance, using the same language it was built in.

## Try it

Visit the [browser REPL](https://interplaynetary.github.io/playnet/) — no install needed.

```
playnet> (make-org "my-org")
Created org: my-org

playnet> (enter! "my-org")
Entering org.

play> (define greeting "hello world")
play> greeting
=> "hello world"

play> (signup! "alice" "alice@example.com")
Sending signup request...
Account registered! ssh alice@SERVER_IP
```

Create an org. Write Scheme. Register an account. Get SSH access to a Guix System machine — all from the browser REPL.

## The stack

```
Browser (Hoot/WASM)          Server (Guix System)
├─ Metacircular evaluator    ├─ Native Guile + Goblins
├─ Virtual DOM REPL          ├─ OCapN gateway + signup
├─ Ed25519 key management    ├─ Shepherd services
├─ WebRTC P2P netlayer       ├─ MQTT event bridge
└─ Compiles to repl.wasm     ├─ Reticulum mesh networking
                             └─ guix deploy = OS reconfiguration
  ←── OCapN (capability transport) ──→
       WebSocket (bootstrap) │ WebRTC (P2P) │ Reticulum (mesh)
```

Every layer is Guile Scheme. Every connection is capability-secured.

## Properties

- **Declarative OS.** `deploy/guix/machines.scm` defines the entire server — bootloader, kernel, users, packages, services. Push to `main` triggers `guix deploy` via GitHub Actions. The operating system is a Scheme expression that evolves with the codebase.
- **Object capability security.** [Spritely Goblins](https://spritely.institute/goblins/) actors with unforgeable references. No ACLs, no permission tables. Possession of a reference IS authorization. Attenuation via `^facet`, revocation via `^cell` flip, accountability via `^logger`.
- **Mesh networking.** [Reticulum](https://reticulum.network/) transport layer — the same OCapN sturdyref works over TCP, LoRa radio (1-20km), serial wire, I2P (anonymous), or packet radio. An actor on a LoRa node in a field can hold a capability ref to an actor on the server.
- **End-to-end encryption.** Curve25519 for Reticulum transport, Ed25519 for actor identity and SSH credentials. Keys are generated in the browser; the private key never leaves the client.
- **Homoiconic governance.** Rules, state, and history are S-expressions. The evaluator consumes the same representation it produces. An org can inspect its own evolution and rollback to any prior state.
- **Self-service signup.** Users register through the browser REPL. The signup flow provisions a Linux account on the Guix machine via the relay → `^signup-agent` → `guix deploy` pipeline.

## Architecture

On native Guile + Goblins, playnet is not a library — it's a **pattern**. Every piece of governance maps 1:1 to existing Goblins primitives:

| Need            | Goblins provides                                                                                                      |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| Mutable state   | `bcom` (become)                                                                                                       |
| Accountability  | `^logger` + revocable proxy ([Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) §3.3.4) |
| Attenuation     | `^facet` (actor-lib)                                                                                                  |
| Revocation      | `^cell` flip                                                                                                          |
| Identity        | Actor refs are unforgeable                                                                                            |
| Persistence     | `define-actor` + persistence env                                                                                      |
| Networking      | OCapN — actors across machines                                                                                        |
| Mesh networking | [Reticulum](https://reticulum.network/) — LoRa, serial, I2P, TCP, packet radio                                        |

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full explanation.

### Code structure

```
module/playnet/
  actors.scm         — ^org, ^logger, proxy pair (governance kernel)
  evaluator.scm      — metacircular eval (Hoot/WASM only)
  repl.scm           — org factories + inner REPL
  kanren.scm         — miniKanren logic programming (219 lines)
  knowledge.scm      — relational queries with proof traces
  system-kb.scm      — the system's self-knowledge as relational facts
  markdown.scm       — bidirectional markdown ↔ S-expression transpilation

browser/
  repl.scm           — browser REPL (compiles to WASM via Hoot)
  index.html          — web shell
  repl.js / repl.css  — JS host + styling

server/
  relay.scm           — WebSocket message relay
  signup-agent.scm    — self-service account registration actor
  reticulum-bridge.py — Reticulum mesh networking bridge

planner/
  lib/schemas.scm     — 47 ValueFlows record types
  lib/relational/     — relational planner (miniKanren search over lifted fact tuples)
  tests/              — 29 relational planner tests

key-pool/
  key-pool.scm        — capability-secure API key management (any HTTP API via provider profiles)
  vf-bridge.scm       — ValueFlows bridge (keys as economic resources)

deploy/guix/
  machines.scm        — the operating system declaration
  playnet-service.scm    — Shepherd service type for org processes
  users.scm           — dynamically provisioned user accounts
  provision-user.scm  — enrollment script
  channels.scm        — pinned Guix commit for reproducibility
```

## Core Concepts

### State

An org is a Goblins actor with bindings — an alist of `(name . value)` pairs. Mutation happens via `bcom`: the actor becomes a new version of itself with updated bindings.

```scheme
(define-actor (^org bcom bindings)
  (methods
   [(lookup name) (assq-ref bindings name)]
   [(modify! name value) (bcom (^org bcom (cons (cons name value) bindings)))]
   [(snapshot) bindings]
   [(restore! snapshot) (bcom (^org bcom snapshot))]))
```

### Accountability

Following the [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) (§3.3.4), accountability is **compositional** — it wraps the org, not built into it.

```scheme
(define log (spawn ^logger))
(define-values (infra-ref infra-revoked?)
  (spawn-logged-revocable-proxy-pair 'infrastructure org log))

($ infra-ref 'modify! 'deploy "my-cap")  ;; logged automatically
($ infra-revoked? #t)                     ;; access revoked — one cell flip
```

### Governed Orgs

`make-governed-org` wires state + accountability + attenuation + revocation together:

```scheme
(define-values (vat read log gov gov-r infra infra-r member member-r)
  (make-governed-org "commune"))
;; gov, infra, member: logged revocable proxies
;; gov-r, infra-r, member-r: revocation cells
;; read: read-only facet
;; log: the accountability record
```

## The lambda calculus, all the way down

Capability security from closures. State from `bcom`. Accountability from logging. Economic reasoning from relations. Each layer is the lambda calculus applied to a different domain:

| Domain         | Lambda calculus provides                                                                                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Security       | Closures are unforgeable references — [A Security Kernel Based on the Lambda-Calculus](https://mumble.net/~jar/pubs/secureos/secureos.html) |
| State          | `bcom` — a function becomes a new function (Goblins actors)                                                                                 |
| Accountability | `^logger` — wrapping a function to record every call                                                                                        |
| Attenuation    | `^facet` — partial application restricts the interface                                                                                      |
| Revocation     | `^cell` — a conditional that can be flipped                                                                                                 |
| Reasoning      | miniKanren — search as lazy evaluation of goal functions                                                                                    |
| Economics      | Facts as tuples, queries as unification — one relation per question, every direction                                                        |

Because they're all the same substrate, they compose without adapters. A relational query over economic data runs inside a governed actor, over a capability-secured network, on a declaratively defined operating system — and every layer is Scheme.

## Economic Planning — Relations, Not Algorithms

The planner is a [ValueFlows](https://valueflo.ws/) economic planning engine built on miniKanren relational search over Goblins actors. Facts are plain S-expression tuples. Queries are pattern matching with blanks. The search explores all valid plans — not just the first greedy one.

```scheme
(recipe-o    facts rid name output)          ;; what can we make?
(flow-o      facts pid dir spec qty unit act) ;; what goes in and out?
(net-demand-o ctx spec qty remaining alloc)  ;; what's available?
(demand-o    ctx spec qty due plan-term)     ;; what's the plan?
(plan-o      ctx plan)                       ;; solve all demands
(run-plan    n ns (plan) (plan-o ctx plan))  ;; find n valid plans
```

Six relations replace 20+ imperative algorithm modules. Each relation works bidirectionally — "what recipe produces bread?" and "what does recipe-bread produce?" are the same `recipe-o` with different blanks filled in. Every plan is traceable: the search tree IS the audit trail.

The allocation state is immutable. When the search branches to explore a different recipe, each branch gets its own copy automatically. A branch that claims 50kg of flour and then fails doesn't affect other branches — its claims vanish with it. The system's branching IS the backtracking.

Each planning scope is a Goblins vat. Scopes coordinate via OCapN — the same protocol that connects browsers to servers to LoRa radios. A planning federation is a hierarchy of scopes folded together, each governed by its own actors.

See [RELATIONS.md](RELATIONS.md) for the full philosophy.

### Social planning over API keys

The key-pool is the first concrete example. The pool works with any HTTP API that uses key-based auth — a provider profile defines the base URL, auth headers, error classification, cost extraction, and optional credit checking. It ships with profiles for OpenRouter and OpenAI, plus a generic constructor for arbitrary APIs. Custom profiles are plain alists with lambdas — no subclassing, no framework.

The VF bridge (`key-pool/vf-bridge.scm`) maps pool operations to ValueFlows records:

| Pool concept | ValueFlows record             | What it enables                                             |
| ------------ | ----------------------------- | ----------------------------------------------------------- |
| Donor        | Agent                         | Track who contributed what, compute contribution claims     |
| API key      | EconomicResource              | State (available/degraded/exhausted), provenance, capacity  |
| API call     | EconomicEvent (action: `use`) | Cost tracking, usage attribution, audit trail               |
| Pool         | Process                       | Container of economic activity the planner can reason about |

Every API call becomes an immutable economic fact. This isn't monitoring — it turns infrastructure into something the planner can _plan over_:

- **Demand/supply**: "We need 100 USD of transcription capacity this month" unfolds via dependent-demand into "which keys can provide it? Do we have enough?"
- **Buffer management (DDMRP)**: Average daily usage computed from the event stream predicts when capacity will exhaust. Buffer zones signal "donate keys now" before the pool runs dry — the same algorithm that prevents stockouts in supply chains.
- **Contribution visibility**: Each donor's events are queryable via the relational layer. Donors see the economic value of their contribution, not just that they provided a key.
- **Capacity forecasting**: The netter reserves capacity without mutation. Combined with usage forecasts, the planner answers "when will we run out?" and emits replenishment signals.
- **Federation**: Multiple key pools (separate scopes/vats) can coordinate via OCapN lateral matching — surplus capacity in one scope flows to deficit in another.

### Socializing computation and memory

The key pool is the proof of concept, but the pattern is general: any computational resource wrapped in a Goblins actor becomes poolable, plannable, and accountable through the same machinery. API keys were first. The same architecture extends to:

- **GPU time** — a donated GPU is an actor, usage is an EconomicEvent with cost, the planner does DDMRP over capacity
- **Storage** — a donated disk is an EconomicResource, reads/writes are events, buffer zones signal "we need more space"
- **Bandwidth** — a Reticulum mesh node offering relay capacity is an actor with a provider profile
- **CPU cycles** — volunteer compute on any machine that speaks OCapN

Three layers make this work:

1. **Capability security** means you can safely share compute without trusting contributors. You hand someone a capability to _use_ the resource, not to _control_ it. Attenuation restricts the interface, revocation pulls it back, logging records everything.

2. **ValueFlows accounting** means every unit of donated compute enters the same economic vocabulary. Alice donates GPU time, Bob donates API keys, Carol donates storage — the planner sees all of it as economic resource flows, does demand/supply across them, and tracks contribution.

3. **OCapN federation** means this isn't one server. Each commons runs its own scope. Surplus compute in one scope is visible to demand signals from another. The Reticulum mesh means even a LoRa node with a sensor contributes to the same economy.

The critical property is the feedback loop. In a traditional system, when API keys run low, someone notices, pings a channel, someone else manually adds a key — human coordination overhead at every step. With DDMRP buffer zones computed over the event stream, the system itself produces a demand signal: "capacity enters red zone in 2 days." That signal is a ValueFlows intent, visible to any agent in the federation. A donor doesn't need to be asked — they can see the signal and respond with a resource.

Because OCapN federates across scopes, signals aren't trapped in one server. A commons with surplus API keys can see that another commons is running low. Lateral matching connects surplus to deficit without central coordination.

The planner doesn't _command_ donors. It makes the flows visible. Coordination emerges from visibility — the same way a biological system upregulates enzyme production when substrate runs low. That's what socializing infrastructure means: not "everyone shares everything," but the economic structure itself creates the conditions for self-organization.

## Networking

Goblins actors communicate via OCapN over multiple transports:

- **WebSocket** — browser-to-server (Hoot/WASM)
- **WebRTC** — browser-to-browser, direct peer-to-peer with DTLS encryption
- **TCP + TLS** — direct encrypted connections
- **Tor Onion Services** — anonymous, peer-to-peer
- **Reticulum** — mesh networking over LoRa, serial, I2P, packet radio, TCP

```scheme
(on (<- remote-greeter "Bob")
    (lambda (reply) (display reply)))
;; => "Hello Bob, welcome to the Reticulum mesh!"
```

The transport is invisible. Capability security is preserved end-to-end.

### Peer discovery and WebRTC

Peers don't discover each other directly — all peers connect to a single **gateway server** which tracks presence and introduces them. This is intentional: the gateway is the trust root in a capability-security model.

```
Browser A ──WebSocket──┐                    ┌── Browser B
                       ├── Gateway ─────────┤
LoRa node ──Reticulum──┘   (^lobby,         └── Browser C
                             ^presence,
                             signaling)
                                 │
                        After signaling:
                     Browser A ←─WebRTC─→ Browser B
                                (direct P2P)
```

1. The gateway publishes a **sturdyref** — a capability URI encoding its identity
2. Browsers enliven the sturdyref over WebSocket to get a live `^lobby` reference
3. Peers call `announce` with a display name and inbox actor
4. The gateway's `^presence` actor broadcasts who's online and introduces peers
5. Once introduced, browsers upgrade to **WebRTC DataChannels** for direct P2P messaging

The gateway relays only signaling (SDP offers/answers, ICE candidates). Application data flows directly between browsers, encrypted by DTLS. The `^webrtc-netlayer` is a proper OCapN netlayer — `spawn-mycapn` routes CapTP messages over DataChannels automatically, using the same Syrup framing as WebSocket.

Glare resolution ensures exactly one connection between any two peers: the lexicographically greater display name is always the offerer.

See [docs/PEER-DISCOVERY.md](docs/PEER-DISCOVERY.md) for the full protocol and [docs/RETICULUM-NETLAYER.md](docs/RETICULUM-NETLAYER.md) for the mesh architecture.

### IoT and sensors with capability security

Any device that speaks Reticulum — a LoRa sensor, a serial-connected microcontroller, an I2P node — can host Goblins actors. The actor IS the sensor's API. Possession of the actor reference IS authorization to read the sensor. No API keys, no tokens, no ACLs.

```scheme
;; A soil moisture sensor on a LoRa node is a Goblins actor
(on (<- soil-sensor 'read)
    (lambda (moisture) (display moisture)))
;; => 42.3

;; Attenuate: give Alice read-only access, revocable
(define alice-sensor (facet soil-sensor 'read))
;; Alice can read but not configure. Revoke anytime via ^cell flip.
```

MQTT bridges the gap for existing IoT infrastructure: Mosquitto handles the physical protocol boundary (topic ACLs, device auth), Goblins handles the logical capability boundary (attenuation, logging, revocation). Each MQTT topic becomes an actor. Each message becomes a vat turn. `bcom` folds over event streams give replayable audit trails for free.

```
Physical sensor → Mosquitto (MQTT) → bridge actor → topic observer → scoped observer
                  protocol normalization    capability attenuation chain
```

Sensor data flows through the same ValueFlows accounting as API keys — each reading is an EconomicEvent, each sensor is an EconomicResource, the data is a resource flow governed by the same actors that govern everything else.

## Relational Reasoning

The system includes a miniKanren relational programming engine — running in the browser (Hoot/WASM) and on the server (native Guile). Knowledge is plain S-expression tuples. miniKanren unifies against them directly. No ORM, no query language, no separate pattern matching engine. The system reasons about itself, relationally, in itself.

Every relation is bidirectional. "What recipe produces bread?" and "what does recipe-bread produce?" are the same relation with different blanks. You write it once and get every direction for free. Transitive closure produces proof traces — the chain of facts traversed to reach the conclusion. This is accountability for inference, the same way `^logger` is accountability for state transitions.

### miniKanren — logic programming from scratch

```scheme
;; Find all values of q where appending (1 2) and q gives (1 2 3 4)
(run* (q) (appendo '(1 2) q '(1 2 3 4)))
;; => ((3 4))
```

219 lines. Interleaving search, occurs check, reification. Hoot-compatible — runs in the browser.

### The system reasons about itself

`system-kb.scm` expresses playnet's own structure as relational facts queryable via miniKanren:

```scheme
(query-depends 'browser)
;; => (evaluator actors kanren knowledge)

(query-what-changes 'push-to-main)
;; => (github-actions guix-deploy guix kernel bootloader services users)

;; Proof-traced inference: HOW does push-to-main affect the kernel?
(run 3 (proof) (trigger-chain-o 'push-to-main 'kernel proof))
;; => ((push-to-main github-actions guix-deploy guix kernel))
```

Every query returns proof traces — the chain of relations traversed to reach the conclusion. This is accountability for inference.

### Bidirectional markdown ↔ S-expressions

`markdown.scm` transpiles between markdown and S-expression ASTs. The miniKanren relation `markdown-element-o` is bidirectional — bind either side and the other is computed:

```scheme
;; S-expression → markdown
(sexp->markdown (list (heading 1 "Deploy") (bullet "EFI boot")))
;; => "# Deploy\n- EFI boot\n"

;; Markdown → S-expression
(markdown->sexp "# Deploy\n- EFI boot\n")
;; => ((heading 1 "Deploy") (bullet "EFI boot"))

;; miniKanren: what element produces this form?
(run* (elem) (markdown-element-o elem '(md-heading 2 "Key files")))
;; => ((heading 2 "Key files"))
```

Skills, documentation, and knowledge bases are views of the same relational program. Edit the markdown and the facts update. Edit the facts and the markdown regenerates. See [docs/SELF-IMPROVING-LOOP.md](docs/SELF-IMPROVING-LOOP.md) for the full architecture.

### Relational queries over ValueFlows

The planner lifts ValueFlows records to plain fact tuples at session start, then queries them relationally. The same `recipe-o` relation that answers "what recipe produces bread?" also answers "what does recipe-bread produce?" — just fill in different blanks.

```scheme
;; "What recipe produces bread?"
(run* (rid name) (recipe-o facts rid name "spec-bread"))
;; => (("recipe-bread" "Bread Production"))

;; "What goes into the milling process?"
(run* (spec qty unit action) (flow-o facts "rp-mill" 'input spec qty unit action))
;; => (("spec-wheat" 10 "kg" consume))

;; "Is there a feasible plan for 20 bread by tomorrow?"
(run-plan 1 ns (plan) (demand-o ctx "spec-bread" 20 tomorrow plan))
;; => ((produce "spec-bread" "recipe-bread" 1 ...))

;; "Give me ALL feasible plans"
(run-plan* ns (plan) (demand-o ctx "spec-bread" 20 tomorrow plan))
;; => ((produce ...) (purchase ...))
```

No separate indexes, no separate functions. One relation, every direction. `project` is used only for arithmetic (scaling, scheduling). Everything else is pure pattern matching.

## How to Run

### Requirements

GNU Guile 3.0+, Guile Goblins 0.17.0+. For browser: Guile Hoot 0.7.0+ and a recent browser (Chrome 119+ or Firefox 121+).

### Setup with Guix

You can consume this repository either directly or as a Guix channel.

**Install directly from source:**

```bash
Sensor data flows through the same ValueFlows accounting as API keys — each reading is an EconomicEvent, each sensor is an EconomicResource, the data is a resource flow governed by the same actors that govern everything else.
guix package -f guix.scm      # install the playnet desktop REPL into your profile
guix shell -m manifest.scm    # transient shell with all development dependencies
```

**Add as a Guix channel:**
To make `playnet` available in your system's package registry, add this to your `~/.config/guix/channels.scm`:

```scheme
(cons (channel
        (name 'playnet)
        (url "https://github.com/interplaynetary/playnet.git")
        (branch "main"))
      %default-channels)
```

After running `guix pull`, you can install it globally via `guix install playnet`.

### Run

```bash
make repl                          # native Guile REPL with Goblins
make serve                         # browser REPL at http://localhost:8088
guile -L module server/relay.scm   # WebSocket relay on port 9090
make test-all                      # all tests
```

### Deploy

```bash
./deploy/guix/bootstrap-hetzner.sh              # first time: provision server
guix deploy -L deploy/guix deploy/guix/machines.scm  # reconfigure OS
```

Or push to `main` — GitHub Actions runs `guix deploy` automatically.

See `deploy/guix/DEPLOY-GUIDE.md` for the full guide.

### Learning Scheme and Goblins

- **Scheme:** If you're new to the language, [A Scheme Primer](https://spritely.institute/static/papers/scheme-primer.html) is the perfect introduction.
- **Goblins:** The best starting point is the [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) paper — it covers the capability patterns that playnet maps onto directly.

## Built With

- [Spritely Goblins](https://spritely.institute/goblins/) — distributed object-capability actor system
- [GNU Guile](https://www.gnu.org/software/guile/) — Scheme implementation
- [GNU Guix](https://guix.gnu.org/) — declarative system configuration and deployment
- [Guile Hoot](https://spritely.institute/hoot/) — Scheme-to-WebAssembly compiler
- [Reticulum](https://reticulum.network/) — mesh networking (LoRa, serial, I2P, TCP, packet radio)
- [Eclipse Mosquitto](https://mosquitto.org/) — MQTT broker for event bridging
- [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) — the capability patterns this follows
- [A Security Kernel Based on the Lambda-Calculus](https://mumble.net/~jar/pubs/secureos/secureos.html) — the foundational theory of capability security in Scheme
- [Claude Code](https://claude.ai/claude-code) — AI pair programming

## License

[AGPL-3.0](LICENSE.md)

![alt text](image.png)
