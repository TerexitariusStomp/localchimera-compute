# xorg

_A self-evolving commons computer written entirely in Guile Scheme._

---

**xorg** is a computer environment where pushing to `main` can redeploy the entire operating system. Everything from the browser interface to the kernel configuration is a Scheme expression. Object capability security comes from the lambda calculus itself — if you hold the reference, you have the authority; if you don't, you don't. The system runs in the browser (Hoot/WASM), on the desktop (native Guile), and on the server (Guix System), connected by mesh networking that works over LoRa radio, serial wire, I2P, TCP, or packet radio.

There is no gap between the system and its description. The organization's rules, state, and history are all S-expressions — the same representation the evaluator consumes. This is what makes the system self-reflective: it can inspect its own evolution, rollback to a prior state, and rewrite its own governance, using the same language it was built in.

## Try it

Visit the [browser REPL](https://interplaynetary.github.io/xorg/) — no install needed.

```
xorg> (make-org "my-org")
Created org: my-org

xorg> (enter! "my-org")
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
├─ Virtual DOM REPL          ├─ WebSocket relay + signup
├─ Ed25519 key management    ├─ Shepherd services
└─ Compiles to repl.wasm     ├─ MQTT event bridge
                             ├─ Reticulum mesh networking
  ←── OCapN (capability      └─ guix deploy = OS reconfiguration
       network) ──→
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

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full explanation.

### Code structure

```
module/xorg/
  actors.scm         — ^org, ^logger, proxy pair (governance kernel)
  evaluator.scm      — metacircular eval (Hoot/WASM only)
  repl.scm           — org factories + inner REPL
  kanren.scm         — miniKanren logic programming
  hyperarc.scm       — metagraph data structures
  knowledge.scm      — relational queries over knowledge bases

browser/
  repl.scm           — browser REPL (compiles to WASM via Hoot)
  index.html          — web shell
  repl.js / repl.css  — JS host + styling

server/
  relay.scm           — WebSocket message relay
  signup-agent.scm    — self-service account registration actor
  reticulum-bridge.py — Reticulum mesh networking bridge

planner/
  lib/                — ValueFlows economic planning engine (20+ algorithms)

key-pool/
  key-pool.scm        — capability-secure API key management

deploy/guix/
  machines.scm        — the operating system declaration
  xorg-service.scm    — Shepherd service type for org processes
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

## Networking

Goblins actors communicate via OCapN over multiple transports:

- **WebSocket** — browser-to-server (Hoot/WASM)
- **TCP + TLS** — direct encrypted connections
- **Tor Onion Services** — anonymous, peer-to-peer
- **Reticulum** — mesh networking over LoRa, serial, I2P, packet radio, TCP

```scheme
(on (<- remote-greeter "Bob")
    (lambda (reply) (display reply)))
;; => "Hello Bob, welcome to the Reticulum mesh!"
```

The transport is invisible. Capability security is preserved end-to-end.

## How to Run

### Requirements

GNU Guile 3.0+, Guile Goblins 0.17.0+. For browser: Guile Hoot 0.7.0+ and a recent browser (Chrome 119+ or Firefox 121+).

### Setup with Guix

You can consume this repository either directly or as a Guix channel.

**Install directly from source:**
```bash
guix package -f guix.scm      # install the meta-org desktop REPL into your profile
guix shell -m manifest.scm    # transient shell with all development dependencies
```

**Add as a Guix channel:**
To make `meta-org` available in your system's package registry, add this to your `~/.config/guix/channels.scm`:
```scheme
(cons (channel
        (name 'meta-org)
        (url "https://github.com/interplaynetary/meta-org.git")
        (branch "main"))
      %default-channels)
```
After running `guix pull`, you can install it globally via `guix install meta-org`.

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
- **Goblins:** The best starting point is the [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) paper — it covers the capability patterns that xorg maps onto directly.

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
- [Claude Code](https://claude.ai/claude-code) — AI pair programming

## License

[AGPL-3.0](LICENSE.md)

![alt text](image.png)
