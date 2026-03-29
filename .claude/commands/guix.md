---
description: GNU Guix — declarative package management, system configuration, deployment, and reproducibility
---

Guix is the substrate beneath everything. The server OS, the development environment, the deployment pipeline, and the package definitions are all Guix. When you touch Guix, you touch the foundation.

## What Guix does in this project

- **Operating system.** `deploy/guix/machines.scm` declares the entire server as a Scheme expression. `guix deploy` reconfigures it over SSH.
- **Package management.** `manifest.scm` and `deploy/guix/dev-manifest.scm` define reproducible development environments.
- **Reproducibility.** `deploy/guix/channels.scm` pins the exact Guix commit. `guix time-machine -C channels.scm` ensures CI and local builds use the same Guix.
- **Custom packages.** `deploy/guix/python-rns.scm` defines a Guix package for Reticulum from source.
- **Service management.** Shepherd (Guix's init system) manages xorg processes via `deploy/guix/xorg-service.scm`.

## Essential commands

```bash
# Development environment
guix shell -m manifest.scm              # transient shell with all deps
guix shell guile guile-goblins          # quick shell with specific packages

# Package management
guix package -m manifest.scm            # install into profile
guix package -u                         # upgrade installed packages
guix gc                                 # garbage collect unused store items

# System deployment (see /deploy skill for full details)
guix deploy -L deploy/guix deploy/guix/machines.scm         # reconfigure server
guix deploy -L deploy/guix --roll-back deploy/guix/machines.scm  # rollback
guix system build -L deploy/guix deploy/guix/machines.scm   # dry-run build

# Reproducibility
guix time-machine -C deploy/guix/channels.scm -- <command>  # run with pinned Guix
guix describe --format=channels                              # get current channel commit
guix pull                                                    # update Guix itself

# Inspecting
guix show guile-goblins                 # package info
guix graph guile-goblins | dot -Tpng   # dependency graph
guix size guile-goblins                 # closure size
```

## Guix System concepts relevant here

| Concept | What it means |
|---------|--------------|
| `operating-system` | Top-level record declaring the entire OS |
| `service-type` | Extensible service definition (openssh, nginx, shepherd, etc.) |
| `shepherd-service` | Process managed by Shepherd (Guix's init system) |
| `simple-service` | Quick way to add a service extension without defining a new type |
| `activation-service-type` | Code that runs on every system activation (deploy) |
| `plain-file` / `local-file` | File objects for the store (SSH keys, configs, scripts) |
| `file-append` | Referencing a binary from a package (`(file-append guile-3.0 "/bin/guile")`) |
| `#~(...)` / `#$(...)` | G-expressions: code that runs on the target machine, with store references |
| `modify-services` | Alter existing services (e.g., change substitute URLs) |
| `(cons* ... %base-services)` | Extend the default service set |

## G-expressions

G-expressions (`#~`) are the key abstraction for deployment code. Code inside `#~(...)` runs on the target machine, not locally. `#$(...)` splices a store reference into the g-expression.

```scheme
;; This runs on the SERVER during activation:
(simple-service 'my-setup activation-service-type
  #~(begin
      (use-modules (guix build utils))
      (mkdir-p "/home/myuser")
      ;; #$ splices the local guile-3.0 package reference into server code:
      (system* #$(file-append guile-3.0 "/bin/guile") "--version")))
```

## Writing a Guix package

See `deploy/guix/python-rns.scm` for a working example. Key pattern:

```scheme
(define-public python-rns
  (package
    (name "python-rns")
    (version "0.9.4")
    (source (origin
              (method git-fetch)
              (uri (git-reference (url "...") (commit "...")))
              (sha256 (base32 "..."))))
    (build-system pyproject-build-system)
    (propagated-inputs (list python-cryptography python-pyserial))
    (home-page "...")
    (synopsis "...")
    (description "...")
    (license license:expat)))
```

Get the hash: `guix hash -x -S nar <directory>` or `guix download <url>`.

## Gotchas

- **`ftpmirror.gnu.org` is unreliable.** Bordeaux is configured as primary substitute server.
- **GRUB theme disabled.** `(theme #f)` because librsvg has no substitute on Bordeaux.
- **EFI boot, not BIOS.** Hetzner cpx22 uses UEFI. Must use `grub-efi-bootloader`.
- **`local-file` resolves relative to source file.** If `(current-filename)` returns `#f` (e.g., in CI), paths break. The codebase uses a `canonicalize-path` fallback.
- **CI needs `sudo` for `guix deploy`.** And `sudo` strips PATH — use `sudo -E "$(which guix)"`.
- **`guix pull` is slow** (15-30 min). `guix time-machine` with a pinned channel avoids this when you already know which commit you want.

## Reference

- [Guix manual](https://guix.gnu.org/manual/)
- [Guix cookbook](https://guix.gnu.org/cookbook/)
- [System services reference](https://guix.gnu.org/manual/en/html_node/Services.html)
- [G-expressions](https://guix.gnu.org/manual/en/html_node/G_002dExpressions.html)

## The user's request

$ARGUMENTS
