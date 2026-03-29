---
description: Guix System deployment — machines.scm, users, services, OS reconfiguration via guix deploy
---

You are editing the operating system. Changes to `deploy/guix/machines.scm` that reach `main` will trigger GitHub Actions to run `guix deploy`, which reconfigures the ENTIRE server — bootloader, kernel, users, packages, services, SSH keys. This is not a container restart. It is a full declarative OS generation switch.

## How changes propagate

```
Edit deploy/guix/*.scm → git push main → GitHub Actions (deploy.yml)
  → guix time-machine -C channels.scm -- deploy -L deploy/guix machines.scm
  → SSH to SERVER_IP as deploy user
  → build derivations, send store closures
  → switch system profile → restart affected services
```

Rollback: `guix deploy -L deploy/guix --roll-back deploy/guix/machines.scm`

## Key files

| File                                | What it controls                                                                                     |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `deploy/guix/machines.scm`          | The OS declaration: users, packages, services, bootloader, filesystems, SSH keys, activation scripts |
| `deploy/guix/playnet-service.scm`   | `playnet-service-type` Shepherd service for org actor processes                                      |
| `deploy/guix/users.scm`             | Dynamic user accounts (managed by `provision-user.scm`, not hand-edited)                             |
| `deploy/guix/provision-user.scm`    | Enrollment script: validates inputs, appends to users.scm, sends welcome email                       |
| `deploy/guix/channels.scm`          | Pinned Guix commit for reproducibility                                                               |
| `deploy/guix/deploy.sh`             | Local wrapper: loads secrets, runs `guix deploy -L deploy/guix`                                      |
| `deploy/guix/python-rns.scm`        | Guix package definition for Reticulum (python-rns)                                                   |
| `deploy/guix/reticulum-service.scm` | Shepherd services for rnsd and reticulum-bridge                                                      |
| `deploy/guix/bootstrap-hetzner.sh`  | One-shot server provisioning from Hetzner rescue mode                                                |
| `deploy/guix/DEPLOY-GUIDE.md`       | Full guide with pitfalls                                                                             |
| `.github/workflows/deploy.yml`      | CI pipeline: push to main triggers guix deploy                                                       |

## Server details

- **Host:** SERVER_IP (Hetzner cpx22, nbg1)
- **Boot:** EFI (`grub-efi-bootloader`, targets `/boot/efi`)
- **Users:** deploy (sudo), playnet (live hacking), playnet (system), + dynamic users from users.scm
- **Substitutes:** Bordeaux primary (`bordeaux.guix.gnu.org`)
- **GRUB theme:** disabled (`(theme #f)`) — librsvg has no substitute

## Common editing patterns

**Add a user:**

1. Run `provision-user.scm --user NAME --key "ssh-ed25519 ..." --email user@example.com`
2. Or use the browser signup flow: `(signup! "name" "email")`
3. Then `guix deploy` (or push to main) to activate

**Add a system package:**

```scheme
;; In machines.scm, append to the (packages ...) list:
(packages (append (list guile-goblins my-new-package ...) %base-packages))
```

**Add a Shepherd service:**

```scheme
;; In machines.scm, add to (services (cons* ...)):
(simple-service 'my-service
                shepherd-root-service-type
                (list (shepherd-service
                       (provision '(my-service))
                       (start #~(make-forkexec-constructor (list ...)))
                       (stop #~(make-kill-destructor)))))
```

**Add an SSH authorized key:**

```scheme
;; In the openssh-configuration authorized-keys:
("username" ,(plain-file "key-name" "ssh-ed25519 AAAA..."))
```

## Gotchas

- **EFI, not BIOS.** Hetzner cpx22 uses UEFI. Must use `grub-efi-bootloader` targeting `/boot/efi`.
- **`(theme #f)`.** GRUB theme requires librsvg which has no substitute on Bordeaux. Disable it.
- **`ftpmirror.gnu.org` is unreliable.** Bordeaux is configured as primary substitute server.
- **Do NOT use `hetzner-environment-type`** from the Guix manual. It fails on current Hetzner. Use `managed-host-environment-type` with `bootstrap-hetzner.sh` for initial provisioning.
- **`users.scm` path resolution.** Uses `(current-filename)` with canonicalize-path fallback. Always run `guix deploy` from the project root.
- **CI deploy takes 30-90 minutes.** `guix time-machine` bootstraps a full Guix from the pinned channel commit.
- **Activation scripts run on every deploy.** They git-pull `/home/playnet/playnet-repo/` and `/home/<dynamic-user>/playnet-repo/` — local changes in those directories will be overwritten.

## Testing

- **Local syntax check:** `guix system build -L deploy/guix deploy/guix/machines.scm` (builds without deploying)
- **Post-deploy verification:** `ssh deploy@SERVER_IP 'herd status'`
- **Rollback:** `guix deploy -L deploy/guix --roll-back deploy/guix/machines.scm`
- **Dry-run provisioning:** `guile -s deploy/guix/provision-user.scm --user test --key "ssh-ed25519 AAAA..." --email test@example.com --dry-run`

## The user's request

$ARGUMENTS
