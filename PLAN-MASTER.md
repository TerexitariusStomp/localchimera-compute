# xorg Master Plan — Complete Elegant Architecture

_Written 2026-03-26. This is the canonical roadmap. All other PLAN-\*.md files feed into this._

---

## What we're building

An org expressed as a Guile/Goblins interpreter. The org IS the evaluator. Rules, state,
history: S-expressions. Metacircular, homoiconic, self-transforming, capability-secure,
cryptographically auditable, persistent, and composable across machines via OCapN.

Every layer of the stack is Scheme. The capability graph covers organizational decisions
and computational substrate. The org can eventually govern its own infrastructure.

---

## Current state (as of 2026-03-26)

### Done ✓

- `^org` actor — Goblins, Hoot-compatible, version 5
- `make-open-org` / `make-governed-org` — canonical constructors
- Capability layer: `^http-client`, `^config-provider`, `^output-port`
- Services: `^service-cap`, `attenuate-service-cap`, `^deploy-cap` (content-hashed)
- ACL → Cap transition complete: `endorsement.scm`, `^name-predicate`, `^faceted-validator`
- `make-endorsement-authority` returns raw sealer actor refs (persistence-correct)
- `call-validator` handles plain-lambda and actor validators uniformly
- `output-cap` stored as `^org` field, IO delegated in lookup (not io-bindings closures)
- Cryptographic signatures on history entries (Ed25519 via Goblins crypto)
- `verify-history-entry` exported
- Guix+Hetzner deployment: `deploy/guix/` with `hetzner-environment-type`
- `xorg-service-type` — Shepherd service type for xorg processes
- Tests: 225+ passing across all modules

### In progress (uncommitted)

- Persistence fixes: `endorsement.scm` + `gplay.scm` + `org.scm` (keen-gulf output)
- Needs commit and persistence tests

---

## The complete remaining work — in priority order

---

### LAYER 1: Persistence (commit and test what's done)

**Status:** Changes made, not committed, not tested with actual persist/restore cycles.

**Actions:**

1. Commit current `endorsement.scm` + `gplay.scm` + `org.scm` changes
2. Write `tests/test-persistence.scm` — actual Bloblin persist/restore cycle:
   - `make-open-org` survives round-trip (bindings, history)
   - `make-governed-org` survives round-trip (validator, sealers, facets all restored)
   - After restore, governance still enforced (infra-seal still works, wrong domain blocked)
   - Capability actor binding (deploy-cap) in org bindings survives
   - Signatures verify on restored history entries
3. Update `gplay-env` to include `^name-predicate`, `^faceted-validator`, `^output-port`
4. Verify `filter-serializable-bindings` is doing the right thing — actor refs should pass through (they're not procedures), only plain lambdas should be stripped

**The test:**

```scheme
(use-modules (goblins persistence-store bloblin))
(define store (make-bloblin-store "/tmp/test-org-store"))
(define-values (org gov infra member) (make-governed-org-persistent "test" store))
;; use it...
;; shut down vat...
;; restore:
(define-values (org2 ...) (restore-governed-org store))
;; verify validator still works
```

---

### LAYER 2: AI as a proper expressor with its own sealer

**Current:** `(ai-eval ...)` runs as the calling expressor, inheriting all their capabilities.
**Problem:** AI can amplify caller's authority. No attribution separate from the caller.
**Fix:** AI is a `defexpressor` with its own keypair and its own scoped bindings.

```scheme
;; Setup:
(define-values (ai-seal ai-unseal ai-sealed?) (make-endorsement-authority))
(define ai-kp (generate-key-pair))

;; Inside org — create the AI expressor:
(evaluate '(defexpressor 'ai-agent ai-kp) ref '() genesis-id)
;; Now ai-seal is the AI's authorization sealer
;; Give the AI specific capabilities:
(as ai-seal
  (modify! 'ai-http (endorse http-cap ai-seal)))
;; The AI can only use what it was given
```

`(ai-eval ...)` then evaluates as `(as ai-sealer expr)` — the AI's expression runs
under the AI expressor's authority, not the caller's. The history entry is attributed
to the AI expressor with its keypair's signature.

**New file:** `module/xorg/ai-expressor.scm` — `make-ai-expressor`, `install-ai-expressor!`

---

### LAYER 3: MCP as a capability actor

**Insight:** Model Context Protocol tools are just capabilities with a defined interface.
An `^mcp-server` actor wraps a set of tools and exposes them via `$`.

```scheme
(define-actor (^mcp-server bcom tools)
  ;; tools: alist of (name . ^tool-cap) actor refs
  (methods
   [(list-tools)
    (map car tools)]
   [(call name args)
    (let ((tool (assoc name tools)))
      (if tool
          ($ (cdr tool) 'call args)
          (error "Unknown tool" name)))]
   [(get name)
    (assoc-ref tools name)]))
```

Each tool is itself an actor. The AI expressor holds an `^mcp-server` reference.
The server can be attenuated: give the AI a version without dangerous tools.
The org's validator governs who can install/modify the MCP server binding.

This is cleaner than external MCP because:

- The server IS a capability — unforgeable, attenuatable
- Every tool call is through the Goblins actor system — traceable
- The org history shows exactly which tools the AI was given access to

**New file:** `module/xorg/mcp.scm` — `^mcp-server`, `^tool-cap`, `make-mcp-server`

---

### LAYER 4: Multi-org on one machine (OCapN via Unix sockets)

**Current:** Multiple orgs can run in separate Shepherd-managed processes.
**Missing:** They can't communicate directly — the relay routes by public key but
there's no org-to-org capability passing.

Goblins 0.16.0 has Unix Domain Socket netlayer — machine-local OCapN. Two orgs
on the same machine can hold direct Goblins actor references to each other via UDS.

**Design:**

```
Host org (privileged)
  ├── holds ^service-registry (all machine services)
  ├── holds ^system-deployer capability
  ├── spawns tenant orgs as Shepherd services
  └── passes attenuated capabilities to tenant orgs via OCapN/UDS
      e.g. tenant-A gets nginx-start-only, deploy-machine-A-only
           tenant-B gets relay-full, deploy-machine-B-only
```

**New file:** `module/xorg/host.scm` — host org setup, tenant spawning, capability grants
**New file:** `deploy/guix/host-org.scm` — Guix service for the host org process

**Shepherd×Goblins migration point:** When Shepherd ports to Goblins, the host org
actor IS a Shepherd actor — no separate process boundary needed. The service registry
IS the capability. All `TODO Shepherd×Goblins` markers in services.scm swap here.

---

### LAYER 5: Guix deploy as an org action (full provenance)

**Current:** `^deploy-cap` exists. It's not wired into any org.
**Full version:** A governed org can `(modify! 'infra-deploy (endorse deploy-cap infra-seal))`.
An expressor with infra-seal can then `($ (lookup 'infra-deploy) 'deploy)`.
The history records: who authorized the deploy, which validator approved it, what config was used.

Combined with signatures: the history entry for the deploy is signed by the authorizing
expressor's keypair. The entry is verifiable by anyone with the public key.

**This is `guix deploy` with org-level provenance** — every infrastructure change
is attributed, validated, signed, and rollbackable via `rollback!` (which would
re-deploy the previous generation).

---

### LAYER 6: `^output-port` per org → per-expressor (optional)

Current output-cap is org-level — all expressors share it. A more granular model:
each expressor has their own output capability, allowing per-expressor routing.

```scheme
;; Alice's output → Alice's terminal
;; AI expressor output → log file
;; Governance expressor output → audit stream
```

This becomes important when orgs are multi-tenant with multiple active expressors.
Lower priority — org-level output is sufficient for now.

---

## The sequencing

```
NOW:
  └── Commit persistence fixes
  └── Write test-persistence.scm

NEXT (this week):
  └── AI as its own expressor (LAYER 2)
  └── MCP server capability (LAYER 3)
└── Guix deploy as org action end-to-end

WHEN SHEPHERD×GOBLINS LANDS:
  └── Replace all ^service-capability subprocess backings with direct actor refs
  └── Host org IS Shepherd actor — one unified actor graph
  └── Per-expressor output routing (LAYER 8)
  └── Full OCapN across machines — orgs communicate by holding actor refs
```

---

## The invariants to maintain

Throughout all of this, these properties must hold at every commit:

1. **Possession = authorization.** No ACL patterns. No identity checks in validators.
2. **All history entries attributed.** Expressor-id + optional signature.
3. **Persistence-correct.** No plain lambdas in persisted actor state. Only data and actor refs.
4. **Backward-compatible restore.** `^org` version upgrades handled.
5. **Hoot-compatible core.** `gplay.scm` cond-expand stubs for WASM.
6. **Tests green throughout.** Every commit passes all existing tests.

---

## What "done" looks like

```scheme
;; Create a governed org backed by globlin persistence
(define-values (org gov infra member)
  (make-governed-org "my-commune" #:store (make-bloblin-store "./commune.db")))

;; Set up an AI expressor with limited capabilities
(define ai-seal (make-ai-expressor! org ai-keypair
                  #:tools (make-mcp-server vat
                            `(("query-kb" . kb-query-cap)
                              ("propose"   . proposal-cap)))))

;; Set up deployment capability (governed by infra-seal)
(with-vat (org-vat org)
  (evaluate '(modify! 'infra-deploy
                      (endorse (lookup 'deploy-machine-1) infra-seal))
            (org-ref org) '() genesis-id))

;; An expressor can now deploy, with full provenance:
(as alice-seal
  ($ (lookup 'infra-deploy) 'deploy))
;; → history entry signed by alice, authorized by infra-seal, config content-hashed
;; → verifiable by anyone with alice's public key
;; → rollback-able: (rollback! prev-version gov-seal) re-deploys previous generation

;; Persist and restore — everything survives:
;; validator, sealers, capabilities, history, signatures — complete graph
```

This is the org that governs its own infrastructure.
