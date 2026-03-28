# The xorg Stack

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
│  xorg  (Guile Scheme + Spritely Goblins)                            │
│  the org IS the evaluator — rules, state, history: S-expressions    │
│  capability-secure, cryptographically auditable, persistent         │
├─────────────────────────────────────────────────────────────────────┤
│  Shepherd  (being ported to Goblins)                                │
│  service manager — each xorg process is a Shepherd service          │
│  TODO: becomes a Goblins actor system → direct actor refs           │
├─────────────────────────────────────────────────────────────────────┤
│  Guix System  (OS declaration in Scheme)                            │
│  packages, services, users, bootloader — all records                │
├─────────────────────────────────────────────────────────────────────┤
│  Hetzner Cloud  (bootstrapped, then managed by guix deploy)          │
│  guix deploy deploy/guix/machines.scm                               │
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
- `deploy/guix/xorg-service.scm` — Shepherd service type for xorg processes
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

## Layer 2: Shepherd services

Shepherd is Guix's init system and service manager (PID 1). Each xorg org instance
runs as a named Shepherd service.

```bash
herd start xorg-my-org      # start an org
herd stop xorg-my-org       # stop it
herd status                 # see all services
herd log xorg-my-org        # view logs
```

### Shepherd×Goblins (coming soon)
Spritely is porting Shepherd to Goblins (Sep 2025 — nearly done). When it lands:
- Shepherd services become Goblins actors
- An xorg can hold a direct Goblins actor reference to a Shepherd service
- `^service-capability` subprocess backing swaps to direct actor message
- All `TODO Shepherd×Goblins` markers in `services.scm` are the migration points

---

## Layer 3: xorg — the org as interpreter

### What it is
A Guile Scheme interpreter where the org IS the evaluator. Rules, state, and history
are all S-expressions. Metacircular, homoiconic, self-transforming.

### Core architecture
```
^org (Goblins actor)
  ├── bindings: alist of (name . value) — the org's current namespace
  ├── validator-proc: ^faceted-validator actor — governs what's allowed
  ├── validator-expr: S-expression — re-evaluated on restore
  ├── history: list of (version expressor-id expression parent sig snapshot)
  ├── expressor-store: registered expressors with public keys + sealers
  ├── output-cap: ^output-port actor — where (display ...) goes
  └── org-public-key: Ed25519 public key of the org itself
```

### Creating orgs
```scheme
;; Experimentation — no governance
(define org (make-open-org "my-org"))

;; Production — capability-governed
(define-values (org gov-seal infra-seal member-seal)
  (make-governed-org "my-org"))
```

### Expressing inside an org
```scheme
;; Basic evaluation
(enter! org)                          ;; enter the REPL
play[genesis]> (modify! 'x 42)        ;; set a binding (history entry created)
play[genesis]> (define (square n) (* n n))  ;; define functions
play[genesis]> (square 7)             ;; => 49

;; Identity
play[genesis]> (defexpressor 'alice (generate-key-pair))  ;; returns alice-sealer
play[genesis]> (as alice-sealer (modify! 'proposal "fund the commons"))

;; Metaprogramming — governed
play[genesis]> (enact! new-validator gov-seal)  ;; constitutional amendment
play[genesis]> (rollback! 5 gov-seal)           ;; restore version 5
```

### Capability security
The validator checks **possession**, not identity:

```scheme
;; Governed names require endorsement
(modify! 'infra-deploy (endorse deploy-cap infra-seal))
;;                      ↑ sealing value with infra-seal proves you hold it

;; Ungoverned names: freely modifiable
(modify! 'proposal "fund the commons")  ;; no endorsement needed
```

The three governance domains in a governed org:
- **governance** (`gov-seal`): controls `validator` and `rollback`
- **infrastructure** (`infra-seal`): controls `infra-*` names (deploy, services)
- **membership** (`member-seal`): controls `member-*` names (expressors, roles)

### History and signatures
Every state-changing expression creates a history entry:
```scheme
(version expressor-id expression parent-version snapshot signature)
;;        ↑ who          ↑ what     ↑ links to prior     ↑ Ed25519
```

Verify any entry:
```scheme
(verify-history-entry entry expressor-public-key)  ;; => #t or #f
```

History is the audit trail. Rollback restores any prior state. The capability
authorized the change; the signature proves who made it.

### Persistence
Orgs persist via Goblins' Bloblin store. The entire actor graph serializes:
- Bindings (capability actors, plain values)
- Validator (as actor refs — `^faceted-validator` → `^facet` → sealers)
- History with signatures
- Expressor store (public keys, sealer actors)
- Output capability

```scheme
(make-governed-org-persistent "my-org"
  (make-bloblin-store "./my-org.db"))
```

On restart, everything comes back including governance and capabilities.

---

## Layer 4: Geiser + Emacs (development tooling)

### What it is
Geiser is an Emacs interface to live Scheme REPLs. With Geiser connected to a running
Goblins vat, you can evaluate expressions directly in the live org from your editor.

### Setup (on the Guix server)
```bash
herd start xorg-dev-repl     # starts guile --listen=/var/run/xorg-dev.sock
emacs                        # Emacs config pre-loaded (geiser, smartparens, rainbow-delimiters)
```

Then in Emacs:
```
M-x geiser-connect-local RET guile RET /var/run/xorg-dev.sock RET
```

**IMPORTANT:** In the `*Geiser Guile REPL*` buffer, run this FIRST:
```scheme
(use-modules (goblins))
```
This prevents vat hanging due to Geiser's port-redirection (known Goblins issue, will be fixed).

### Live hacking workflow
```
Buffer (xorg-module.scm)              *Geiser Guile REPL*
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

**Layer 5A: xorg-internal AI expressor** (Goblins layer — governance)
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
;; → history entry attributed to AI, signed with ai-pk, validated by ^faceted-validator
```

**Layer 5B: Emacs/Geiser MCP bridge** (custom — org-aware tooling)
`emacs-mcp.el` makes Emacs an MCP server. An external LLM (Claude, etc.)
connects via stdio and calls tools that evaluate in the live Geiser/Goblins session.

```elisp
;; Register Geiser-backed tools as MCP tools
(mcp-server-lib-register-tool #'xorg-evaluate
  :id "xorg-eval"
  :description "Evaluate a Scheme expression in the running xorg")

(defun xorg-evaluate (expression)
  "Evaluate EXPRESSION in live xorg via Geiser.
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
| | 5A: AI expressor | 5B: Geiser MCP bridge | 5C: Claude Code IDE |
|---|---|---|---|
| Purpose | Governance, production | Org-aware tooling | Code editing, IDE |
| Attribution | History + signature | Emacs buffer output | Diff view, ediff |
| Validation | ^faceted-validator | None | Flycheck/Flymake |
| Persistence | Survives restarts | Session only | Session only |
| Authority | Exactly what given | Full Geiser access | Full editor access |
| Talks to | Goblins actors | Live REPL via socket | LSP, tree-sitter, Emacs |

---

## Local development

### Spin up a dev environment locally
```bash
# Using the manifest:
guix shell -m deploy/guix/dev-manifest.scm

# Or: if you have guile-goblins installed:
cd ~/Programs/meta-org
./live-guile.sh   # if it exists, or: guile --listen=/tmp/xorg-dev.sock
```

### Run tests
```bash
guile -L module tests/test-gplay.scm
guile -L module tests/test-endorsement.scm
guile -L module tests/test-governed-org.scm
guile -L module tests/test-persistence.scm
```

### Key modules
| Module | What it does |
|---|---|
| `(xorg gplay)` | Core `^org` actor, `evaluate`, `make-initial-org` |
| `(xorg org)` | `make-open-org`, `make-governed-org`, `enter!` |
| `(xorg endorsement)` | `make-endorsement-authority`, `make-faceted-validator`, `^name-predicate` |
| `(xorg capabilities)` | `^http-client`, `^config-provider`, `^output-port` |
| `(xorg services)` | `^service-cap`, `attenuate-service-cap`, `^deploy-cap` |
| `(xorg ai)` | `^ai-capability`, `install-ai-capability!`, `openrouter-chat` |
| `(xorg ai-expressor)` | `make-ai-expressor!`, `ai-eval-as` |
| `(xorg knowledge)` | Relational queries over hyperarc metagraphs |
| `(xorg kanren)` | miniKanren — unification-based logic queries |
| `(xorg hyperarc)` | Hyperarc/metagraph data structures |

---

## Roadmap snapshot

| Layer | Status | What's next |
|---|---|---|
| Hetzner+Guix deploy | ✓ Done | Server live at SERVER_IP |
| Shepherd service type | ✓ Done | Wait for Shepherd×Goblins |
| xorg core (`^org` v5) | ✓ Done | — |
| Cap security (endorsement) | ✓ Done | — |
| History signatures | ✓ Done | — |
| Persistence (actors) | ✓ Done | Persistence tests |
| Geiser dev environment | ✓ Done | Wire mcp-server-lib.el |
| AI as expressor | 🔄 In progress | `sharp-bloom` agent |
| MCP capability actor | ⬜ Next | `module/xorg/mcp.scm` |
| Multi-org via OCapN/UDS | ⬜ Next | `module/xorg/host.scm` |
| Quorum governance | ⬜ Next | `module/xorg/quorum.scm` |
| Knowledge base in orgs | ⬜ Next | Wire into base-bindings |
| Guix deploy as org action | ⬜ Next | End-to-end wiring |
| Shepherd×Goblins | ⏳ Waiting | Spritely release |
