# xorg Architecture

*An overview of the xorg system layout, transport layers, and governance patterns.*

---

## Core Concept

xorg is not a heavy, standalone framework; it is a **pattern** for building organizational systems securely using [Spritely Goblins](https://spritely.institute/goblins/) and the capability architectures described in the [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) paper.

On native Guile with Goblins, every piece of "governance" maps directly to existing primitives:

| Organizational Need | Goblins Primitive | 
|---|---|
| Mutable state | `bcom` (become) | 
| Accountability | `^logger` + proxy (Heart of Spritely §3.3.4) |
| Attenuation | `^facet` (actor-lib) | 
| Revocation | `^cell` flip (Heart of Spritely §3.3.4) | 
| Identity | Actor refs (unforgeable) | 
| Transactions | Vat turns (automatic rollback on error) | 
| Persistence | `define-actor` + persistence environments | 
| Eval | `(eval expr module)` with custom modules | 
| REPL | `,enter-vat` in Guile's built-in REPL | 
| IO | Capabilities passed in (ports, `^io`) | 
| Networking | OCapN — actors across machines | 

Because xorg relies heavily on these standard Goblins primitives, the server-side environment requires very little custom infrastructure code.

---

## Networking: Goblins over Reticulum

Goblins actors are reachable over [Reticulum](https://reticulum.network/) mesh networks. A custom OCapN netlayer bridges Goblins' CapTP (Capability Transport Protocol) to Reticulum's encrypted Link/Channel system. This ensures any Goblins actor — whether on a server, in a browser, or on an embedded device — can securely communicate over:

- **TCP/UDP** — standard internet
- **LoRa radio** — 1-20km range without internet
- **Serial** — direct wire to embedded devices
- **I2P** — global anonymous networking
- **Packet radio** — emergency or off-grid communications

The transport layer is entirely invisible to the actor. The sturdyref `ocapn://...reticulum/s/...` functions identically regardless of the underlying medium. Reticulum handles routing and encryption (Curve25519 + ephemeral keys), while OCapN manages capability security and object references.

The bridge architecture follows the same pattern as Goblins' libp2p netlayer: a Python daemon (`reticulum-bridge.py`) manages the Reticulum links, connecting to the Guile netlayer via Unix domain sockets.

See `docs/RETICULUM-NETLAYER.md` for full networking details.

---

## Client-Side: Hoot and WebAssembly

Running xorg within a web browser via Guile Hoot requires bridging several native Guile features that aren't available in typical WASM environments natively:

| Native Guile Feature | xorg Hoot Implementation |
|---|---|
| `eval` | Metacircular evaluator (~180 lines) |
| Full module system | `default-base-bindings` — curated primitives |
| `,enter-vat` | Inner REPL (`enter!`) |

For the browser, xorg provides **a Hoot-compatible subset of Goblins patterns**, bundled alongside a metacircular evaluator. 

Key files for the client-side environment:
- `module/xorg/gplay.scm` — Evaluator and Goblins actors (Hoot-compatible)
- `module/xorg/kanren.scm` — miniKanren (standalone, Hoot-compatible)
- `module/xorg/hyperarc.scm` — Metagraph data structures
- `module/xorg/knowledge.scm` — Relational queries

By utilizing the evaluator, browser-based REPLs continue to share the exact same architectural semantics as native environments.

---

## Server-Side: Native Guile Environments

On a server (or any native Guile environment), xorg leverages Goblins directly without needing the Hoot compatibility layers. Governance architectures are composed naturally from generic Spritely patterns rather than opaque abstractions:

```scheme
(use-modules (goblins)
             (goblins actor-lib cell)
             (goblins actor-lib facet)
             (goblins actor-lib methods))

;; State management using standard actors
(define-actor (^org bcom bindings)
  (methods
   [(lookup name) (assq-ref bindings name)]
   [(bindings) bindings]
   [(modify! name value)
    (bcom (^org bcom (cons (cons name value) bindings)))]
   [(snapshot) bindings]
   [(restore! snapshot) (bcom (^org bcom snapshot))]))

;; Accountability — Heart of Spritely §3.3.4
(define (^logger bcom)
  (define log (spawn ^cell '()))
  (methods
   ((append-to-log username object args)
    ($ log (cons `(*entry* user ,username args ,args) ($ log))))
   ((get-log) ($ log))))

(define (spawn-logged-revocable-proxy-pair username object log)
  (define revoked? (spawn ^cell #f))
  (define (^proxy bcom)
    (lambda args
      (when ($ revoked?) (error "Access revoked for" username))
      ($ log 'append-to-log username object args)
      (apply $ object args)))
  (values (spawn ^proxy) revoked?))

;; Wire it up inside a vat
(define vat (spawn-vat))
(with-vat vat
  (define org (spawn ^org '()))
  (define log (spawn ^logger))

  ;; Governed refs — the proxy acts as the identity
  (define-values (gov-ref gov-revoked?)
    (spawn-logged-revocable-proxy-pair 'governance org log))
  (define-values (infra-ref infra-revoked?)
    (spawn-logged-revocable-proxy-pair 'infrastructure org log))

  ;; Read-only — ^facet blocks mutation
  (define read-ref (facet org 'lookup 'bindings 'snapshot))

  ;; Interact via proxy
  ($ infra-ref 'modify! 'deploy "my-deploy-cap")
  ($ gov-ref 'modify! 'policy "consensus")

  ;; Check the logger
  ($ log 'get-log)
  ;; => ((*entry* user governance args (modify! policy "consensus"))
  ;;     (*entry* user infrastructure args (modify! deploy "my-deploy-cap")))

  ;; Revoke infrastructure access with a single flip
  ($ infra-revoked? #t)
  ;; ($ infra-ref 'modify! 'x 1) → ERROR: Access revoked
  )
```

### Live Server Interaction

The native server setup (Guile REPL server + Emacs/Geiser) provides direct access to the Goblins vat:

```
Developer
  → SSH / emacsclient
  → Guile REPL on /var/run/playnet/repl.sock
  → Goblins vat with live actors
  → Test governance patterns interactively
  → Hot-reload modules
```

Rather than using a rigid deployment cycle, expressions can be evaluated live within the vat, persisting across calls as dictated by standard capability security and Heart of Spritely design patterns.

---

## Summary

```text
Browser (Hoot/WASM)              Server (Native Guile)
─────────────────────            ────────────────────
xorg evaluator                   Guile's native eval
xorg base-bindings               Guile's native module system
xorg REPL                        Guile's REPL + ,enter-vat
xorg actors                      Standard Goblins actors
     ↕                                ↕
     └──── OCapN ──── same actors, same patterns ────┘
```
