# xorg

_Express and Experiment with Organization._

---

**xorg** is a way of thinking about organization — expressing it, experimenting with it, and transforming it. It is not any particular organizational form. It is the practice of making organization _expressible_.

This repository explores xorg in the domain of computable interpreters: an org expressed as a Lisp environment, built on [Spritely Goblins](https://spritely.institute) and [Guile Scheme](https://www.gnu.org/software/guile/). Here, the question becomes: what if an organization were an interpreter — and the people in it were expressions that could rewrite it?

The system is **homoiconic**: the organization's rules, state, and history are all S-expressions — the same representation the evaluator consumes. There is no gap between the org and its description. History entries are the original S-expressions that produced each state transition. This is what makes the org **self-reflective**: it can inspect its own evolution and rollback to restore a prior state, using the same language it was built in.

## Architecture

On native Guile + Goblins, xorg is not a library — it's a **pattern**. Every piece of governance maps 1:1 to existing Goblins primitives:

| Need | Goblins provides |
|---|---|
| Mutable state | `bcom` (become) |
| Accountability | `^logger` + revocable proxy ([Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) §3.3.4) |
| Attenuation | `^facet` (actor-lib) |
| Revocation | `^cell` flip |
| Identity | Actor refs are unforgeable |
| Persistence | `define-actor` + persistence env |
| Networking | OCapN — actors across machines |
| Mesh networking | [Reticulum](https://reticulum.network/) — LoRa, serial, I2P, TCP, packet radio |

Goblins actors are reachable over **any transport Reticulum supports**: TCP, LoRa radio, serial links, I2P, packet radio. The same sturdyref works whether the message crosses the internet or travels over radio waves.

On the server, you just use Goblins directly. xorg code is needed only for **Hoot/WASM** (browser), where Guile's `eval` and module system aren't available.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full explanation.

### Code structure

```
module/xorg/
  actors.scm       — ^org, ^logger, proxy pair (works everywhere)
  evaluator.scm    — metacircular eval (Hoot/WASM only)
  repl.scm         — factories + inner REPL (Hoot convenience)
  kanren.scm       — miniKanren (standalone)
  hyperarc.scm     — metagraphs (standalone)
  knowledge.scm    — relational queries (standalone)
```

## Core Concepts

### State

An org is a Goblins actor with bindings — an alist of `(name . value)` pairs. Mutation happens via `bcom`: the actor becomes a new version of itself with updated bindings. The previous state is not destroyed — Goblins' transactional model preserves it within the turn.

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

A `^logger` accumulates log entries. A `spawn-logged-revocable-proxy-pair` wraps any object in a proxy that logs every call and can be revoked. The proxy IS the identity.

```scheme
(define log (spawn ^logger))
(define-values (infra-ref infra-revoked?)
  (spawn-logged-revocable-proxy-pair 'infrastructure org log))

;; infra-ref logs every call — accountability is automatic
($ infra-ref 'modify! 'deploy "my-cap")

;; Check the log
($ log 'get-log)
;; => ((*entry* user infrastructure args (modify! deploy "my-cap") snapshot ...))

;; Revoke access — one cell flip
($ infra-revoked? #t)
;; infra-ref is now dead
```

### Attenuation

Goblins' `^facet` creates a read-only view by exposing only certain methods:

```scheme
(define read-ref (facet org 'lookup 'bindings 'snapshot))
;; read-ref can read but not modify — structurally enforced
```

### Governed Orgs

`make-governed-org` wires these patterns together:

```scheme
(define-values (vat read log gov gov-r infra infra-r member member-r)
  (make-governed-org "commune"))

;; gov, infra, member: logged revocable proxies (each with their own identity)
;; gov-r, infra-r, member-r: revocation cells (flip to #t to cut access)
;; read: ^facet — can only lookup, no mutation
;; log: ^logger — the accountability record
```

### Rollback

Rollback restores bindings from a snapshot stored in the log. Each log entry captures the org's state at that point. To rollback: find the entry, extract the snapshot, call `restore!`.

## The Evaluator (Hoot/WASM)

In the browser, Guile's `eval` isn't available. xorg provides a metacircular evaluator — a Scheme interpreter written in Scheme. On native Guile, use `(eval expr module)` instead.

`evaluate` understands:

| Form | Effect |
|---|---|
| `#t`, `#f`, numbers, strings | Self-evaluating literals |
| `(quote x)` | Returns `x` unevaluated |
| `(if test then else)` | Conditional |
| `(begin body ...)` | Sequence |
| `(let ...)`, `(let* ...)`, `(letrec ...)` | Bindings |
| `(let name (...) body)` | Named let — loop |
| `(lambda (args) body)` | Closure |
| `(define name value)` | Bind in the org |
| `(modify! name value)` | Explicit binding mutation |
| `(rollback! index)` | Restore snapshot from log |
| `(cond ...)`, `(case ...)` | Multi-branch |
| `(and ...)`, `(or ...)` | Short-circuit boolean |
| `(when ...)`, `(unless ...)` | Conditional execution |
| `(do ...)` | Iteration |
| `(f args ...)` | Application |

## Networking

Goblins actors communicate via OCapN (Object Capability Network) over multiple transports:

- **Tor Onion Services** — anonymous, peer-to-peer
- **TCP + TLS** — direct encrypted connections
- **WebSocket** — browser-to-server (Hoot/WASM)
- **Reticulum** — mesh networking over LoRa, serial, I2P, packet radio, TCP

The Reticulum netlayer means Goblins actors are reachable over **radio, serial wire, anonymous networks, and the open internet** — all through the same OCapN sturdyref. An actor on a LoRa node in a field can hold a capability ref to an actor on a Hetzner server. The call looks the same:

```scheme
(on (<- remote-greeter "Bob")
    (lambda (reply) (display reply)))
;; => "Hello Bob, welcome to the Reticulum mesh!"
```

The transport is invisible. The capability security is preserved end-to-end. Reticulum handles routing and encryption (Curve25519). OCapN handles object references and garbage collection.

## How to Run

### Requirements

GNU Guile 3.0+, Guile Goblins 0.17.0+. For browser: Guile Hoot 0.7.0+ and a recent browser (Chrome 119+ or Firefox 121+).

### Setup with Guix

```bash
guix shell -m manifest.scm
```

### Native Guile REPL

```bash
make repl         # full REPL with Goblins actors
```

### Browser REPL (Hoot/WASM)

```bash
make          # compiles browser/repl.scm to WebAssembly
make serve    # starts web server at http://localhost:8088
```

### Deploy to Hetzner Cloud

```bash
./deploy/guix/bootstrap-hetzner.sh    # first time: provision server
guix deploy deploy/guix/machines.scm  # reconfigure
```

See `deploy/guix/DEPLOY-GUIDE.md` for details.

### Run tests

```bash
make test-all     # all tests
```

## REPL Tutorial (Browser)

Visit `http://localhost:8088` after `make serve`.

```
xorg> (make-org "alpha")
Created org: alpha

xorg> (enter! "alpha")
Entering org.

play> (define greeting "hello world")
play> greeting
=> "hello world"

play> (define (square x) (* x x))
play> (square 7)
=> 49

play> (modify! 'proposal "fund the commons")

play> ,log
  [genesis] (modify! proposal "fund the commons")
  [genesis] (modify! greeting "hello world")

play> (rollback! 0)
play> greeting
=> "hello world"
play> proposal
error: Variable unbound: proposal
```

## What This Is Not

This is not a governance framework. It does not encode voting, consensus, hierarchy, or any particular organizational form. It is the layer _beneath_ those — a substrate in which any such form could be expressed and later replaced by something else entirely.

The only invariants are: every action has an identity (the proxy ref), every change is logged (the `^logger`), and access can be revoked (the `^cell` flip).

What emerges from that is up to the expressors.

## Built With

- [Spritely Goblins](https://spritely.institute/goblins/) — distributed object-capability actor system
- [GNU Guile](https://www.gnu.org/software/guile/) — Scheme implementation
- [GNU Guix](https://guix.gnu.org/) — declarative system configuration and deployment
- [Guile Hoot](https://spritely.institute/hoot/) — Scheme-to-WebAssembly compiler
- [Reticulum](https://reticulum.network/) — mesh networking (LoRa, serial, I2P, TCP, packet radio)
- [Eclipse Mosquitto](https://mosquitto.org/) — MQTT broker for event bridging
- [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) — the capability patterns this follows
- [Claude Code](https://claude.ai/claude-code) — AI pair programming (infrastructure, MQTT bridge, planner)

## License

[AGPL-3.0](LICENSE)

![alt text](image.png)
