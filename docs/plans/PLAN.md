# playnet × Guix × Goblins — Integration Plan

_Written 2026-03-26. Goal: make playnet, Guix System, and Goblins a unified stack where every layer speaks the same protocol and the org can eventually govern its own infrastructure._

---

## The Vision

Every layer of this system is or will be Scheme:

- **playnet** — the org is a Goblins actor. Rules, state, history: S-expressions.
- **Shepherd** — being ported to Goblins (Spritely, Sep 2025 — nearly done).
- **Guix System** — OS declaration is Scheme. Packages, services, users: records.
- **The relay** — Guile WebSocket server.
- **Hetzner provisioning** — `machines.scm` is a Scheme program that computes servers.

When Shepherd×Goblins lands: Shepherd services _are_ Goblins actors, addressable over OCapN. At that point an playnet can hold a direct Goblins reference to a service, a service manager, or a deployer — and govern all of them as org actions with full provenance.

**The thread running through everything:** every interface we add is defined as a Goblins actor boundary. The backing implementation can be a subprocess, HTTP call, or file read. When Shepherd×Goblins ships, the interfaces don't change — the backing swaps. That's what it means to be primed.

---

## Current State

| Layer                               | Status                            | Gap                                    |
| ----------------------------------- | --------------------------------- | -------------------------------------- |
| `^org` actor (gplay.scm)            | ✓ Goblins, Hoot-compatible        | —                                      |
| `hyperarc` + `kanren` + `knowledge` | ✓ relational query layer          | not wired into org bindings            |
| `ai.scm`                            | ✗ ambient `getenv`, `http-post`   | not ocap-safe                          |
| `org.scm` REPL                      | ✗ ambient IO                      | not ocap-safe                          |
| Multi-org topology                  | ✗                                 | no isolation between orgs              |
| Guix deployment                     | ✓ `deploy/guix/` (Hetzner native) | no playnet service definition          |
| Service capabilities                | ✗                                 | playnet can't govern Shepherd services |
| Infrastructure as org action        | ✗                                 | `guix deploy` not an org action        |

---

## Track 1: Wrap ambient IO in capability objects

**Problem:** `ai.scm` uses `getenv`, `http-post`, `set-ai-api-key!` as global mutable state. Any expressor in any org can call the AI by knowing the procedure names — this bypasses the ocap model entirely.

**Fix:** Introduce `^http-client` and `^config-provider` capability actors. `ai.scm` becomes a factory that takes capabilities and returns procedures. No globals.

```scheme
;; A capability actor wrapping HTTP to a specific endpoint
(define (^http-client bcom base-url default-headers)
  (lambda (method path body)
    ;; only this actor can make HTTP calls to base-url
    ;; caller gets a response value, not a raw socket
    ...))

;; A capability actor wrapping config/env
(define (^config-provider bcom config-alist)
  (lambda (key) (assoc-ref config-alist key)))

;; ai.scm becomes:
(define (make-ai-query-fn http-client)
  "Returns an ai-query procedure backed by the given http-client capability."
  (lambda (system-prompt user-prompt) ...))
```

Pass these into org bindings explicitly. The org's validator decides which expressors get access to the AI capability. Mock implementations make testing trivial.

**New file:** `module/playnet/capabilities.scm` — defines `^http-client`, `^config-provider`, and the general capability actor patterns.

---

## Track 2: Define the service capability interface

**The key interface that will connect playnet to Shepherd.** Define it now with a subprocess backing; swap to direct Goblins actor reference when Shepherd×Goblins lands.

```scheme
;; module/playnet/services.scm

(define (^service-capability bcom service-name control-proc)
  "Wraps a service control interface as a capability.
   NOW: calls herd over a subprocess.
   LATER: replace control-proc with ($ shepherd-actor 'start service-name)"
  (methods
   [(start)  (control-proc 'start  service-name)]
   [(stop)   (control-proc 'stop   service-name)]
   [(status) (control-proc 'status service-name)]
   [(name)   service-name]))

(define (^system-deployer bcom authorized-configs deploy-proc)
  "Capability to deploy one of a set of authorized OS configs.
   The org pre-approves configs; the deployer enforces that list.
   NOW: subprocess guix deploy.
   LATER: direct Guix actor reference."
  (lambda (config)
    (if (member config authorized-configs)
        (deploy-proc config)
        (error "Config not authorized by org"))))
```

When an expressor calls `(deploy-system new-config)`, it's an org action — attributed, validated, in the history, rollbackable — that has real infrastructure effects.

**Shepherd×Goblins migration target (mark in code):**

```scheme
;;; TODO Shepherd×Goblins: replace (subprocess-control-proc ...) with
;;; ($ shepherd-registry-actor 'get-service service-name)
```

---

## Track 3: Multi-org topology on Guix

On a single Guix machine, multiple playnets need isolation and communication. Architecture:

```
Guix System (one machine)
  └── Shepherd
        ├── playnet-host service      ;; the "machine org" — governs services
        │     └── ^org actor       ;; has ^service-capability bindings
        ├── playnet-relay service     ;; the relay (already exists)
        ├── playnet-A service         ;; tenant org A
        │     └── ^org actor       ;; has sub-capabilities granted by host
        └── playnet-B service         ;; tenant org B
              └── ^org actor
```

The **host org** is privileged — it holds service capabilities and passes sub-capabilities to tenant orgs. A tenant org gets only what the host grants. Capability security at the infrastructure level.

**Communication:** Goblins 0.16.0 added Unix Domain Socket netlayer for machine-local OCapN. Each org is a separate Shepherd-managed process; they communicate over UDS sockets using OCapN. No shared memory, no ambient access.

**New files:**

- `module/playnet/host.scm` — the host org definition, service registry, tenant spawning
- `deploy/guix/playnet-service.scm` — Guix Shepherd service type for playnet processes

---

## Track 4: Wire knowledge layer into org bindings

The `hyperarc` + `kanren` + `knowledge` modules exist but aren't wired into the org. An org should be able to hold a knowledge base as a binding and query it relationally.

```scheme
;; Inside an org:
(modify! 'kb (make-kb 'governance governance-metagraph))

;; Query: who has proposed what, transitively related to resource-X
(run 2 (q) (transitive-o (lookup 'kb) 'proposals q resource-x-node))
```

The knowledge base is just an S-expression — serializable, in the history, subject to the validator. An expressor modifying the KB is an org action like any other.

---

## Sequencing

### Now (this sprint)

1. **Track 1A:** `module/playnet/capabilities.scm` — `^http-client`, `^config-provider` actor definitions
2. **Track 1B:** Refactor `ai.scm` to take capabilities, remove globals
3. **Track 2A:** `module/playnet/services.scm` — `^service-capability`, `^system-deployer` interfaces with subprocess backing
4. **Track 3A:** `deploy/guix/playnet-service.scm` — Guix Shepherd service type for playnet processes

### Soon

5. **Track 3B:** OCapN between orgs on same machine (Unix socket netlayer)
6. **Track 4:** Wire `knowledge.scm` into org bindings — expressors can query relational graph
7. **Track 2B:** `^system-deployer` wired to `guix deploy` — infrastructure becomes an org action

### When Shepherd×Goblins lands

8. Replace `^service-capability` subprocess backing with direct Goblins actor references
9. The host org IS the Shepherd actor system — one unified actor graph
10. `guix deploy` becomes a Goblins message, fully in the OCapN protocol chain
11. Full provenance: kernel version → system generation → org action → expressor identity

---

## The Payoff

**From the current state:** playnets that use ambient IO and have no infrastructure awareness.

**To the target state:** an org that governs its own substrate. Who authorized the server change, when, under what validator, in which org version — all in the history. Rollback means rollback at every level.

The org doesn't just run on infrastructure. The org _is_ the infrastructure's governance layer.
