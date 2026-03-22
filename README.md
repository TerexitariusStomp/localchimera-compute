# xorg

_Express and Experiment with Organization._

---

**xorg** is a way of thinking about organization — expressing it, experimenting with it, and transforming it. It is not any particular organizational form. It is the practice of making organization _expressible_.

This repository explores xorg in the domain of computable interpreters: an org expressed as a Lisp environment, built on [Spritely Goblins](https://spritely.institute) and [Guile Scheme](https://www.gnu.org/software/guile/). Here, the question becomes: what if an organization were an interpreter — and the people in it were expressions that could rewrite it?

In this expression of xorg, the answer inherits everything that makes Lisp powerful. The system is **homoiconic**: the organization's rules, state, and history are all S-expressions — the same representation the evaluator consumes. There is no gap between the org and its description. A validator is not a config file — it is a live Scheme expression sitting in the same expression-space as the data it governs. History entries are not opaque log rows — they are the original S-expressions that produced each state transition, ready to be re-evaluated. This is what makes the org **self-reflective**: it can `show-history` to inspect its own evolution, then `rollback!` to restore a prior state, using the same language it was built in.

Because the evaluator is **metacircular** — a Scheme interpreter written in Scheme — the org is **extensible** and **self-transforming** from within. `enact!` installs a new validator: an arbitrary Scheme function that changes how all future expressions are evaluated. The validator has access to the full environment before and after every change. It must accept its own installation to take effect. You are not configuring an organization — you are metaprogramming the interpreter that _is_ the organization, and the interpreter must consent.

Every expression an expressor evaluates moves the org through **expression-space** — the space of all reachable organizational states. `modify!` traverses it. `enact!` reshapes which regions are reachable. `rollback!` backtracks. The org's evolution is a path through this space, and because every step is recorded as a homoiconic S-expression, the entire path is replayable, inspectable, and forkable.

The system is deliberately minimal. It provides identity, memory, and a mechanism for self-modification. What it _becomes_ is not prescribed. An org could evolve into a democracy, a marketplace, a neural network of agents, a single autocratic expressor, or something with no existing name. The structure doesn't impose direction — it makes direction _expressible_.

## Architecture

This implementation is built on [Spritely Goblins](https://spritely.institute), an object-capability actor system. Each org is a Goblins actor living in a vat (event loop). This gives it:

- **Capability-based security** — identity is proved by holding a cryptographic sealer, not by claiming a name
- **Persistence** — orgs can be saved to disk and restored via Goblins' `define-actor` persistence
- **Networking** — orgs can communicate across machines via OCapN (Object Capability Network)
- **Browser support** — the full system compiles to WebAssembly via [Guile Hoot](https://spritely.institute/hoot/)

## Core Concepts

### Expressors

An expressor is an identity — a _who_ attached to every action. It carries a name, a public key, and a unique symbol. There is no anonymous mutation; every change to the environment names the expressor that caused it.

```scheme
(define alice (defexpressor 'alice "alice-public-key"))
```

`defexpressor` returns a **sealer** — a cryptographic capability object. This sealer is your proof of identity. Holding it is what lets you act as alice. It is never stored in the org's shared state — only the holder possesses it.

An expressor is not necessarily a person. It could be a process, an external system, a role, or another xorg. The system does not distinguish — it only requires that expression has a source.

### Acting as an Expressor

```scheme
(as alice (modify! 'proposal "fund the commons"))
```

The `as` form requires the sealer returned by `defexpressor`. It verifies the sealer against the org's expressor store by sealing a nonce and checking which expressor's `sealed?` predicate recognizes it. Without the sealer, you cannot act as that expressor — the capability IS the authorization.

### Environments

An org is an immutable snapshot managed as a Goblins actor:

| Component     | Role                                              |
| ------------- | ------------------------------------------------- |
| **Bindings**  | The current namespace — what the org _knows_      |
| **Validator** | A function gating every change — how it _decides_ |
| **History**   | A versioned ledger — what it _remembers_          |
| **Expressor** | The identity currently acting — who _speaks_      |

Each operation produces a new actor state via Goblins' `bcom` (become). The previous state is not destroyed — it becomes history.

### Validators

A validator is an ordinary function: `(expressor name value pre-bindings post-bindings) -> bool`. It receives the acting expressor, the binding name, the new value, and the bindings before and after the change. It returns true or false.

The default validator accepts everything. You replace it with `enact!`. The metacircular constraint: **a new validator must accept itself** before it takes effect. This means the mechanism for changing the rules is always subject to the current rules — but _what_ those rules are is entirely open.

### History

Every change produces a history entry: a version number, the expressor, the expression evaluated, and a pointer to its parent. The ledger is append-only. Because entries store the original expressions as data, the organization's past is not merely recorded — it is **replayable**.

### Rollback

```scheme
(rollback! 3)
```

Rollback does not erase — it restores. Each history entry carries a snapshot of the org's full state (bindings, validator expression, validator procedure) at the moment it was created. `rollback!` finds the target version's snapshot and becomes that state directly. History is preserved — only the org's live state rewinds.

## Metacircularity

In the Lisp tradition, a metacircular evaluator is an interpreter for a language written in that same language. xorg extends this to organizations: the org is an interpreter, and its expressors write programs that the org evaluates — including programs that rewrite the interpreter itself.

The metacircular closure is complete:

- **The evaluator evaluates itself.** The language that defines the organization is the language the organization operates in.
- **Validators validate themselves.** `enact!` must pass the current validator to install a new one. The rules for changing the rules are subject to the current rules.
- **Expressors create expressors.** Identities within the system bring new identities into being — the org grows itself.
- **History is its own source code.** Each entry is the S-expression that produced it, paired with a snapshot of the state it produced. The org's past is not a log — it is a program.

## Play and Meta-Play

**Play** is acting within the org — binding values, switching identities, enacting rules. **Meta-play** is stepping outside to inspect, replay, and reason about the act of expression itself. Both use the same language. There is no separate admin interface or audit system — meta-play is Scheme over Scheme.

```scheme
;; Play: alice acts within the org
(as alice (modify! 'budget 50000))

;; Meta-play: inspect how the org arrived here
(show-history)

;; Meta-play: rewind and explore a different path
(rollback! 3)
```

## The Evaluator

`evaluate` is a small Lisp interpreter. It understands:

| Form                            | Effect                                             |
| ------------------------------- | -------------------------------------------------- |
| `#t`, `#f`, numbers, strings    | Self-evaluating literals                           |
| `(quote x)`                     | Returns `x` unevaluated                            |
| `(if test then else)`           | Conditional (two or three branches)                |
| `(begin body ...)`              | Sequence — returns last value                      |
| `(let ((v e) ...) body)`        | Parallel bindings                                  |
| `(let* ((v e) ...) body)`       | Sequential bindings                                |
| `(let name ((v e) ...) body)`   | Named let — loop construct                         |
| `(letrec ((v e) ...) body)`     | Recursive bindings                                 |
| `(lambda (args ...) body)`      | Closure — captures the current expressor           |
| `(define name value)`           | Bind a value in the org                            |
| `(defexpressor name key)`       | Bring a new identity into being, returns sealer    |
| `(as sealer expr)`              | Evaluate under a different identity (requires sealer) |
| `(modify! name value)`          | Validated binding mutation                         |
| `(enact! validator-expr)`       | Replace the validator (must self-accept)           |
| `(rollback! version)`           | Restore snapshot at a prior version                |
| `(show-history)`                | Return the versioned history as a string           |
| `(show-expressors)`             | Return all known identities as a string            |
| `(public-key)`                  | Return this org's Ed25519 public key               |
| `(process-message msg-id)`      | Process a pending inbox message                    |
| `(retract-message msg-id sender)` | Retract a pending inbox message                  |
| `(ai prompt)`                   | Send prompt to AI, return response                 |
| `(ai-eval prompt)`              | Send prompt to AI, evaluate response as code       |
| `(cond clauses ...)`            | Multi-branch conditional                           |
| `(and exprs ...)`, `(or ...)`   | Short-circuit boolean                              |
| `(when test body ...)`          | Conditional execution                              |
| `(unless test body ...)`        | Inverse conditional execution                      |
| `(case key clauses ...)`        | Datum-based dispatch                               |
| `(do ((v i s) ...) (test) cmd)` | Iteration                                          |
| `(f args ...)`                  | Function application                               |

Lambdas capture the environment at creation time (bindings, validator, history), but adopt the identity of their caller at invocation time.

## Multi-Agent Networking

xorg supports multi-agent interaction via Goblins' OCapN (Object Capability Network) protocol. Two or more peers can connect to the same org, each with their own authenticated expressor identity.

### Identity Model

Following the [goblin-chat](https://spritely.institute/news/goblins-in-the-browser.html) pattern from Spritely:

- **Identity** (`^expressor-identity`) — the public face, freely shareable. Carries name, unsealer, sealed? predicate, and a subscription-sealer for the membership handshake.
- **Controller** (`^expressor-controller`) — the private handle. Only the authorized party holds this. Can evaluate expressions as that expressor and seal messages.
- **Sealer** — returned by `defexpressor`, never stored in shared state. Proves you control that identity.

### Membership Handshake

When a peer wants to join an org:

1. **Peer** creates a local identity with a subscription sealer triplet
2. **Peer** submits a membership request to the org's inbox
3. **Host** approves the request via `approve-membership`
4. **Host** creates an expressor pair and seals the controller with the peer's subscription-sealer
5. **Peer** unseals the controller with their subscription-unsealer
6. **Peer** can now evaluate expressions in the org through their controller

The sealer/unsealer pattern ensures only the intended recipient can access the controller — no server needs to verify credentials.

### Inbox System

Each org can have a warded inbox (`^org-inbox`):

- **Public methods**: `submit` (anyone can send a message), `pending`, `all-entries`
- **Protected methods**: `process`, `retract` (only the incanter-holder can use these)
- Messages carry the sender's identity for attribution

### Browser REPL Commands

```scheme
;; Create two orgs
(make-org "alpha")
(make-org "beta")

;; From inside beta, request to join alpha
(enter! "beta")
(join-org "alpha")

;; Switch to alpha and approve
(exit!)
(enter! "alpha")
(approve-member 0 "beta")

;; Now beta can act in alpha through its controller
(exit!)
(enter! "beta")
(act-in "alpha" (define greeting "hello from beta"))
```

For remote orgs across machines, connect to a relay and use public keys:

```scheme
;; Connect browser to relay: http://localhost:8088?relay=ws://localhost:9090
;; Then act-in using a public key instead of a name
(act-in target-public-key (modify! 'status "online"))
```

## How to Run

### Requirements

GNU Guile (built from main branch), Guile Hoot 0.7.0+, Guile Goblins 0.17.0+, and a recent browser (Chrome 119+ or Firefox 121+).

### Setup with Guix

```bash
guix shell -m manifest.scm
```

### Build and serve the browser REPL

```bash
make          # compiles repl.scm to WebAssembly
make serve    # starts web server at http://localhost:8088
```

### Native Guile REPL

```bash
make repl         # full two-tier REPL with Goblins actors
make quick-repl   # single-org functional REPL
```

### Relay and server

```bash
make relay        # WebSocket relay on ws://localhost:9090 — routes messages by public key, queues for offline peers
make server       # native org server with admin REPL (approve members, inspect bindings/history)
```

To connect the browser REPL to a relay, add `?relay=ws://localhost:9090` to the URL. The REPL auto-connects and registers all local org public keys.

### Run tests

```bash
make test-gplay   # tests covering the evaluator, identity, rollback, persistence, inbox
```

## REPL Tutorial (Browser)

Visit `http://localhost:8088` after `make serve`.

```
xorg> (make-org "alpha")
Created org: alpha

xorg> (enter! "alpha")
Entering org 'alpha'.

play[genesis]> (define greeting "hello world")
play[genesis]> greeting
=> "hello world"

play[genesis]> (define alice (defexpressor 'alice "alice-key"))
=> #<local-object sealer>

play[genesis]> (as alice (modify! 'proposal "fund the commons"))

play[genesis]> (show-history)
=> Version 0 [genesis] : (quote initial) (parent: 0)
   Version 1 [genesis] : (define greeting "hello world") (parent: 0)
   Version 2 [genesis] : (defexpressor (quote alice) "alice-key") (parent: 1)
   Version 3 [alice] : (modify! (quote proposal) "fund the commons") (parent: 2)

play[genesis]> (rollback! 1)

play[genesis]> greeting
=> "hello world"

play[genesis]> proposal
error: Variable unbound: proposal
```

The sidebar shows bindings, validator, history, and expressors in real time. The REPL supports tab-completion for special forms, Scheme keywords, and org bindings.

## What This Is Not

This is not a governance framework. It does not encode voting, consensus, hierarchy, or any particular organizational form. It is the layer _beneath_ those — a substrate in which any such form could be expressed, enacted, and later replaced by something else entirely.

The only invariants are: every action has an identity, every change is remembered, and the rules for changing the rules are themselves subject to the rules.

What emerges from that is up to the expressors.

![alt text](image.png)
