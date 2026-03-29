# The playnet Stack

_A complete map of how everything fits together._

---

## Overview

Every layer of this stack is Scheme. The capability graph covers organizational decisions
and computational substrate. An org can eventually govern its own infrastructure — and
an AI can participate in that governance as a proper, attributed, capability-governed expressor.

```
┌─────────────────────────────────────────────────────────────────────┐
│  AI / LLM  (external: Claude, GPT, local model)                     │
│  ↕ MCP (mcp-server-lib.el via stdio)                                │
├─────────────────────────────────────────────────────────────────────┤
│  Emacs + Geiser  (live REPL connection to running Goblins vat)      │
│  editor, structural editing, evaluate-in-org tool bridge            │
├─────────────────────────────────────────────────────────────────────┤
│  playnet  (Guile Scheme + Spritely Goblins)                            │
│  the org IS the evaluator — rules, state, history: S-expressions    │
│  capability-secure, cryptographically auditable, persistent         │
├─────────────────────────────────────────────────────────────────────┤
│  Shepherd  (being ported to Goblins)                                │
│  service manager — each playnet process is a Shepherd service          │
│  TODO: becomes a Goblins actor system → direct actor refs           │
├─────────────────────────────────────────────────────────────────────┤
│  Guix System  (OS declaration in Scheme)                            │
│  packages, services, users, bootloader — all records                │
├─────────────────────────────────────────────────────────────────────┤
│  Hetzner Cloud  (bootstrapped, then managed by guix deploy)          │
│  guix deploy deploy/guix/machines.scm                               │
├─────────────────────────────────────────────────────────────────────┤
│  Reticulum  (mesh networking — LoRa, serial, I2P, TCP, UDP)         │
│  OCapN netlayer: Goblins actors reachable over any Reticulum transport│
└─────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Hetzner + Guix System

### What it is

GNU Guix System running on Hetzner Cloud VPS (cpx22, nbg1, `SERVER_IP`).
No Docker. No Ansible. Just Scheme.

### How it works

**First time:** `bootstrap-hetzner.sh` provisions the server via Hetzner API,
installs Guix in rescue mode, and boots into Guix System (~15 min).

**Ongoing:** `guix deploy` reconfigures in place via `managed-host-environment-type`.

```bash
./deploy/guix/bootstrap-hetzner.sh              # first time only
guix deploy deploy/guix/machines.scm             # reconfigure
guix deploy --roll-back deploy/guix/machines.scm # rollback
guix deploy deploy/guix/machines.scm -x -- herd status  # run command
```

### Why not `hetzner-environment-type`?

The Guix manual's `hetzner-environment-type` automates provisioning but currently
fails due to: `ftpmirror.gnu.org` being down, newer Hetzner x86 types using UEFI
(not BIOS as documented), and the GRUB theme needing `librsvg` without a substitute.
The bootstrap script fixes all of these. See `deploy/guix/DEPLOY-GUIDE.md` for details.

### Key files

- `deploy/guix/bootstrap-hetzner.sh` — one-shot server provisioning
- `deploy/guix/machines.scm` — `managed-host-environment-type` target
- `deploy/guix/secrets.scm` — API token via `(setenv ...)` (gitignored)
- `deploy/guix/deploy.sh` — wrapper: loads secrets, runs `guix deploy`
- `deploy/guix/playnet-service.scm` — Shepherd service type for playnet processes
- `deploy/guix/channels.scm` — pinned Guix commit
- `deploy/guix/dev-manifest.scm` — `guix shell` manifest for local dev
- `deploy/guix/DEPLOY-GUIDE.md` — full deployment guide with pitfalls

### The OS declaration

```scheme
(define %guix-x86
  (operating-system
    (host-name "guix-x86")
    (timezone "Etc/UTC")
    (bootloader (bootloader-configuration
                 (bootloader grub-efi-bootloader)   ;; UEFI, not BIOS
                 (targets (list "/boot/efi"))
                 (terminal-outputs '(console))
                 (theme #f)))                        ;; no librsvg
    (initrd-modules (append (list "virtio_scsi") %base-initrd-modules))
    (file-systems (cons* (file-system
                           (mount-point "/")
                           (device "/dev/sda1") (type "ext4"))
                         (file-system
                           (mount-point "/boot/efi")
                           (device "/dev/sda15") (type "vfat"))
                         %base-file-systems))
    (services
     (cons* (service dhcpcd-service-type)
            (service openssh-service-type
                     (openssh-configuration
                      (openssh openssh-sans-x)
                      (permit-root-login 'prohibit-password)))
            %base-services))))
```

---

## Layer 1.5: Reticulum — mesh networking for Goblins

### What it is

Goblins actors reachable over any network Reticulum supports: TCP, UDP,
LoRa radio, serial links, I2P, packet radio. A custom OCapN netlayer
bridges Goblins' CapTP to Reticulum's encrypted Link/Channel system.

The same `(<- remote-ref "Bob")` call works whether the message travels
over fiber optic or LoRa radio. OCapN abstracts the object references.
Reticulum abstracts the transport. The actor doesn't know or care.

### What this means

An org running on the Hetzner server can be called from a LoRa node in
a field with no internet. A sensor on a serial link can hold a Goblins
actor ref. A device behind NAT, on I2P, on a mesh network — all
addressable via the same OCapN sturdyref:

```
ocapn://33a5995c162b827962ad20748bd2ccbf.reticulum/s/c14LAGX...
```

| Transport    | Range       | Use case                        |
| ------------ | ----------- | ------------------------------- |
| TCP/UDP      | Global      | Standard server-to-server       |
| LoRa radio   | 1-20km      | Field devices, rural, off-grid  |
| Serial       | Direct wire | Embedded systems                |
| I2P          | Global      | Anonymous, censorship-resistant |
| Packet radio | 10-100km    | Emergency, disaster             |

### Architecture

```
Goblins actors ←→ OCapN CapTP
        ↕
^reticulum-netlayer (Guile, uses ^base-port-netlayer)
        ↕  Unix domain sockets
reticulum-bridge.py (Python, byte shuttle)
        ↕  Reticulum Channel (encrypted, reliable)
Reticulum Link ←→ any transport
```

Follows the same pattern as Goblins' libp2p netlayer: external daemon
bridged via Unix sockets, `^base-port-netlayer` handles the common
netlayer interface.

### Key files

- `module/goblins/ocapn/netlayer/reticulum.scm` — Guile netlayer
- `server/reticulum-bridge.py` — Python bridge daemon
- `deploy/guix/reticulum-service.scm` — Guix Shepherd services
- `docs/RETICULUM-NETLAYER.md` — full architecture docs

### Usage

```scheme
(use-modules (goblins) (goblins ocapn captp)
             (goblins ocapn netlayer reticulum))
(define vat (spawn-vat))
(with-vat vat
  (define netlayer (spawn ^reticulum-netlayer))
  (define mycapn (spawn-mycapn netlayer))
  ;; Register any actor — now reachable over mesh
  (define sref ($ mycapn 'register my-actor 'reticulum))
  ;; Share the sturdyref: ocapn://...reticulum/s/...
  )
```

---

## Layer 2: Shepherd services

Shepherd is Guix's init system and service manager (PID 1). Each playnet org instance
runs as a named Shepherd service.

```bash
herd start playnet-my-org      # start an org
herd stop playnet-my-org       # stop it
herd status                 # see all services
herd log playnet-my-org        # view logs
```

### Shepherd×Goblins (coming soon)

Spritely is porting Shepherd to Goblins (Sep 2025 — nearly done). When it lands:

- Shepherd services become Goblins actors
- An playnet can hold a direct Goblins actor reference to a Shepherd service
- `^service-capability` subprocess backing swaps to direct actor message
- All `TODO Shepherd×Goblins` markers in `services.scm` are the migration points

---

## Layer 3: playnet — governed state via Goblins patterns

### What it is

On native Guile, playnet is a **pattern** — Heart of Spritely applied to orgs.
In the browser (Hoot/WASM), playnet provides a metacircular evaluator.
See [ARCHITECTURE.md](ARCHITECTURE.md).

### Core actors (from `actors.scm`, 96 lines)

```
^org              — pure state: bindings + modify! + snapshot + restore!
^logger           — accountability log (Heart of Spritely §3.3.4)
^proxy            — logged revocable proxy (Heart of Spritely §3.3.4)
^facet            — read-only attenuation (Goblins actor-lib)
^cell             — revocation flag (Goblins actor-lib)
```

### Creating orgs

```scheme
;; Open org — everyone gets a logged proxy
(define-values (vat proxy log) (make-open-org "my-org"))

;; Governed org — read-only ref + 3 revocable proxies
(define-values (vat read log gov gov-r infra infra-r member member-r)
  (make-governed-org "my-org"))
```

### Using an org

```scheme
(with-vat vat
  ;; Modify via proxy — logged automatically
  ($ infra 'modify! 'deploy "my-cap")

  ;; Check the log
  ($ log 'get-log)
  ;; => ((*entry* user infrastructure args (modify! deploy "my-cap") ...))

  ;; Revoke access
  ($ infra-r #t)
  ;; infra proxy is now dead

  ;; Read-only ref — ^facet blocks mutation structurally
  ($ read 'lookup 'deploy)  ;; works
  ;; ($ read 'modify! ...) → ERROR: method denied
  )
```

### Governance = composition

- **Identity**: the proxy ref IS the identity — unforgeable by Goblins guarantee
- **Accountability**: `^logger` records who did what — separate from the org
- **Attenuation**: `^facet` restricts which methods are available
- **Revocation**: `^cell` flip cuts access instantly

No validators. No signing. No endorsement. Pure Goblins.

### Persistence

Orgs persist via Goblins' `define-actor` mechanism. The `org-env`
persistence environment includes `^org`, `^facet`, and `^cell`.

---

## Layer 4: Geiser + Emacs (development tooling)

### What it is

Geiser is an Emacs interface to live Scheme REPLs. With Geiser connected to a running
Goblins vat, you can evaluate expressions directly in the live org from your editor.

### Setup (on the Guix server)

```bash
herd start playnet-dev-repl     # starts guile --listen=/var/run/playnet-dev.sock
emacs                        # Emacs config pre-loaded (geiser, smartparens, rainbow-delimiters)
```

Then in Emacs:

```
M-x geiser-connect-local RET guile RET /var/run/playnet-dev.sock RET
```

**IMPORTANT:** In the `*Geiser Guile REPL*` buffer, run this FIRST:

```scheme
(use-modules (goblins))
```

This prevents vat hanging due to Geiser's port-redirection (known Goblins issue, will be fixed).

### Live hacking workflow

```
Buffer (playnet-module.scm)              *Geiser Guile REPL*
─────────────────────────             ──────────────────────────────
C-x C-e → eval expression        →   expression evaluated in running vat
C-x C-b → eval whole buffer      →   module reloaded in live session
C-c C-z → switch to REPL         →   inspect state, test expressions
```

### Emacs packages (installed via Guix)

- `emacs-no-x` — terminal Emacs (no X11 needed on server)
- `emacs-geiser` + `emacs-geiser-guile` — REPL integration
- `emacs-smartparens` — structural editing (slurp, barf, wrap)
- `emacs-rainbow-delimiters` — colored parens by nesting depth
- `emacs-claude-code-ide` — Claude Code inside Emacs (see Layer 5C)

---

## Layer 5: AI integration

### Three layers

**Layer 5A: playnet-internal AI expressor** (Goblins layer — governance)
The AI is a proper expressor inside the org with its own sealer and keypair.
Its expressions are attributed, signed, validated, and in the history.

```scheme
(define-values (ai-seal ai-pk)
  (make-ai-expressor! org http-client "google/gemini-flash-2.0"
    #:tools (make-mcp-server vat
              `(("propose"  . proposal-cap)
                ("query-kb" . kb-query-cap)))))

;; AI acts under its own authority — not the caller's
(as-ai-eval ai-seal "write a proposal for funding the commons")
;; → logged via ^logger, attributed to ai proxy, revocable
```

**Layer 5B: Emacs/Geiser MCP bridge** (custom — org-aware tooling)
`emacs-mcp.el` makes Emacs an MCP server. An external LLM (Claude, etc.)
connects via stdio and calls tools that evaluate in the live Geiser/Goblins session.

```elisp
;; Register Geiser-backed tools as MCP tools
(mcp-server-lib-register-tool #'playnet-evaluate
  :id "playnet-eval"
  :description "Evaluate a Scheme expression in the running playnet")

(defun playnet-evaluate (expression)
  "Evaluate EXPRESSION in live playnet via Geiser.
MCP Parameters:
  expression - Scheme expression to evaluate"
  (mcp-server-lib-with-error-handling
    (geiser-eval-string expression)))
```

Claude Desktop (or any MCP client) connects to this server and can:

- Evaluate Scheme in the live org
- Query org history and bindings
- Propose expressions for human review
- Read the knowledge base

**Layer 5C: Claude Code IDE** (Emacs layer — full IDE integration)
`emacs-claude-code-ide` (packaged in Guix) runs Claude Code natively inside
Emacs with bidirectional MCP communication. Claude gets access to Emacs
features: LSP, tree-sitter, diagnostics, project navigation, imenu.

```elisp
;; Installed via Guix: emacs-claude-code-ide
(use-package claude-code-ide
  :bind ("C-c a" . claude-code-ide-menu))
```

Combined with Layer 5B, Claude can both understand your code (via LSP/tree-sitter)
AND act on the live Goblins vat (via the Geiser MCP bridge). The IDE layer helps
Claude write correct Scheme; the MCP bridge lets it evaluate in the running org.

### How the layers compose

|                | 5A: AI expressor       | 5B: Geiser MCP bridge | 5C: Claude Code IDE     |
| -------------- | ---------------------- | --------------------- | ----------------------- |
| Purpose        | Governance, production | Org-aware tooling     | Code editing, IDE       |
| Attribution    | History + signature    | Emacs buffer output   | Diff view, ediff        |
| Accountability | ^logger + proxy        | None                  | Flycheck/Flymake        |
| Persistence    | Survives restarts      | Session only          | Session only            |
| Authority      | Exactly what given     | Full Geiser access    | Full editor access      |
| Talks to       | Goblins actors         | Live REPL via socket  | LSP, tree-sitter, Emacs |

---

## Local development

### Spin up a dev environment locally

```bash
# Using the manifest:
guix shell -m deploy/guix/dev-manifest.scm

# Or: if you have guile-goblins installed:
cd ~/Programs/playnet
./live-guile.sh   # if it exists, or: guile --listen=/tmp/playnet-dev.sock
```

### Run tests

```bash
make test-all
```

### Key modules

Goblins actors (work everywhere):

| Module             | What it does                                                      |
| ------------------ | ----------------------------------------------------------------- |
| `(playnet actors)` | `^org`, `^logger`, `spawn-logged-revocable-proxy-pair`, `org-env` |

Hoot/WASM (browser only):

| Module                | What it does                                                         |
| --------------------- | -------------------------------------------------------------------- |
| `(playnet evaluator)` | Metacircular `evaluate`, `default-base-bindings`, `make-io-bindings` |
| `(playnet repl)`      | `make-open-org`, `make-governed-org`, `enter!`                       |

Knowledge layer (standalone, Hoot-compatible):

| Module                | What it does                                 |
| --------------------- | -------------------------------------------- |
| `(playnet kanren)`    | miniKanren — unification-based logic queries |
| `(playnet hyperarc)`  | Hyperarc/metagraph data structures           |
| `(playnet knowledge)` | Relational queries over hyperarc metagraphs  |

On the server, `(playnet actors)` is optional — you can write the same
Heart of Spritely patterns inline. See [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Roadmap snapshot

### Done

| What                                                               | Status |
| ------------------------------------------------------------------ | ------ |
| playnet actors (^org, ^logger, proxy — Heart of Spritely patterns) | ✓ Done |
| Governance via composition (^facet, ^cell, proxy)                  | ✓ Done |
| Server/browser split (actors.scm, evaluator.scm, repl.scm)         | ✓ Done |
| Knowledge layer (miniKanren, hyperarc, queries)                    | ✓ Done |
| Hetzner+Guix deploy (SERVER_IP)                               | ✓ Done |
| Kernel extraction (deprecated wrappers moved out)                  | ✓ Done |
| Reticulum OCapN netlayer (LoRa, serial, I2P, TCP)                  | ✓ Done |

### Next

| What                       | Notes                                                     |
| -------------------------- | --------------------------------------------------------- |
| Persistence tests          | Bloblin round-trip: governed org survives persist/restore |
| Hoot compatibility testing | Run kernel in WASM, verify governance works in browser    |
| OCapN capability injection | Server provides caps to browser org via OCapN refs        |
| Browser demo               | Org in WASM + server caps, end-to-end                     |

### Waiting

| What                       | On                                                   |
| -------------------------- | ---------------------------------------------------- |
| Shepherd as Goblins actors | Spritely release — services become direct actor refs |
