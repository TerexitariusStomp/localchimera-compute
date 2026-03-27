# Hetzner Deploy Attempts — What We Tried and What Happened

_Written 2026-03-27. Honest record of what worked and what didn't._

---

## Setup (worked)

- Created Hetzner Cloud account, project, API token
- Generated SSH keypair on nozomi-laptop
- Ran `sudo guix archive --generate-key` — created signing keys at `/etc/guix/signing-key.{pub,sec}`
- Ran `guix pull --disable-authentication` to update from Guix 1.4.0 → 894c432 (2026 build)
- Confirmed `guix deploy` command available and `(gnu machine hetzner)` module present

## What `hetzner-environment-type` is supposed to do

1. Create a Hetzner server via API
2. Enable rescue mode (Debian-based minimal system)
3. SSH in and run a bash script that:
   - Partitions and formats `/dev/sda`
   - Bind-mounts `/mnt/tmp/gnu/store` → `/gnu/store`
   - Downloads and runs `guix-install.sh` from guix.gnu.org
   - Writes a minimal `hetzner-os.scm` to the rescue system
   - Calls `guix system init hetzner-os.scm /mnt`
4. Reboots into the new Guix System
5. Delegates to `managed-host-environment-type` for subsequent reconfigures

## Attempts and failures

### Attempt 1 — cx22 server type
- **Error:** `server type 'cx22' not supported`
- **Fix:** switched to `cpx11` (cheapest x86 in nbg1)

### Attempt 2 — `~/.ssh/id_ed25519` not found
- **Error:** `public-key-from-file: The file does not exist`
- **Root cause:** `~` not expanded by Guile's path resolution
- **Fix:** changed to absolute path `/home/nozomi/.ssh/id_ed25519`

### Attempt 3 — cpx11 not available in nbg1
- **Error:** `unsupported location for server type`
- **Root cause:** `cpx11` is not available in `nbg1` datacenter
- **Fix:** switched to `cax11` (ARM, available in nbg1), updated `base-system.scm` to use `%hetzner-os-arm`

### Attempt 4 — `chown: cannot access '/etc/guix'`
- **Error:** `guix-install.sh` tries to chown `/etc/guix` before creating it
- **Root cause:** Bug in guix-install.sh — the directory doesn't exist on a fresh rescue system
- **Workaround attempt:** Raced a background SSH loop to `mkdir -p /etc/guix` before install ran — sometimes worked, sometimes lost the race

### Attempt 5 — ARM graft failures
- **Error:** `bash-minimal-5.2.37.drv failed` — graft failure
- **Root cause:** ARM rescue system + Guix 1.5.0 bootstrap + missing graft substitutes
- **Fix attempt:** `--no-grafts` flag — still failed on module-import-compiled.drv

### Attempt 6 — Out of disk space on rescue overlay
- **Error:** `No space left on device` when trying `guix pull` on rescue server
- **Root cause:** Rescue system uses a 2GB RAM overlay fs; only ~500MB free after Guix install
- **Fix attempt:** Tried bind-mounting /mnt space into /root — broke SSH key auth, locked out

### Attempt 7-10 — Switched to x86 (cpx22 in nbg1)
- **cpx22** is x86, 4GB RAM, available in nbg1 — fixes ARM graft issue and more overlay space
- Updated `base-system.scm` back to `%hetzner-os-x86`
- Patched `hetzner.scm` (the deploy module) to add `mkdir -p /etc/guix` before install
- **Error:** `guix: command not found` — PATH not updated after install
- **Root cause:** `guix-install.sh` says "log out and back in" to get updated PATH; same shell session doesn't have it
- **Fix:** Patched to use glob `$(ls /gnu/store/*-guix-*/bin/guix | head -1)` to find binary

### Attempt 11 — `cannot execute: required file not found`
- **Error:** Found binary at `/mnt/tmp/gnu/store/.../bin/guix` — shebang points to `/gnu/store/...guile`
- **Root cause:** Binary path via `/mnt/tmp/...` doesn't have the bind mount in effect; shebang interpreter at `/gnu/store/...` fails
- **Fix:** Changed to search only `/gnu/store` (the bind-mounted path)

### Attempt 12 — `$GUIX_BIN: unbound variable`
- **Error:** Guile parser error during deploy
- **Root cause:** Our bash snippet had `"$GUIX_BIN"` inside double-quotes — the `"` prematurely closed the Guile format string
- **Fix:** Removed double-quotes from bash conditional (`if [ -z "$VAR" ]` → simplified away)

### Attempt 13 — `system: command not found`
- **Error:** bash interprets `$GUIX_BIN system init` as just `system init` when var is empty
- **Root cause:** The bind mount `/mnt/tmp/gnu/store` → `/gnu/store` was unmounted between install and our find command (it's set up inside the script's own bash session, but something removed it)
- **Diagnosis:** SSH-ed in manually, confirmed `find /gnu/store` returns nothing; but `ls /mnt/tmp/gnu/store | wc -l` = 84
- **Fix:** Used `ls /gnu/store/*-guix-*/bin/guix | head -1` glob instead of find

### Attempt 14 — `guix system: error: failed to connect to daemon socket`
- **Error:** `guix system init` runs but can't connect to guix-daemon
- **Root cause:** `guix-daemon` systemd unit uses path `/var/guix/profiles/per-user/root/current-guix/bin/guix-daemon` which doesn't exist (it's supposed to be created by guix-install.sh profile linking, but fails because the daemon itself didn't start during install)
- **Diagnosis:** Manually started daemon from store path — worked. Confirmed binary at `/gnu/store/.../bin/guix-daemon`
- **Fix:** Added manual daemon start to patch before `guix system init`

### Attempt 15 — `the group 'guixbuild' does not exist`
- **Error:** `guix system init` fails because guixbuild group isn't in the rescue system
- **Root cause:** `guix-install.sh` creates this group, but the daemon failure during install left the group creation incomplete
- **Fix:** Added `groupadd guixbuild` + 10 `useradd guixbuilder{01-10}` to patch before daemon start

### Attempt 16 — librsvg build failure
- **Error:** `cannot build derivation .../librsvg-2.58.5.drv: 1 dependencies couldn't be built`
- **Root cause:** The minimal bootstrap OS includes `grub-bootloader` which needs `librsvg` for its graphical menu image. Guix 1.5.0 substitutes don't have a pre-built `librsvg` for x86. Building locally on a 2GB rescue server takes hours and may OOM.
- **Fix attempted:** `--fallback` flag to build locally — ran for ~3 hours, SSH session timed out before completion
- **Status:** Unresolved

---

## Current state (as of 2026-03-27 15:00)

Server still running at `178.104.108.19`. Being deleted.

The bootstrap works up to `guix system init` but fails on building `librsvg` (needed by GRUB's graphical theme) without available substitutes.

---

## What would actually work

### Option A: Fix the librsvg substitute issue
The Guix 1.5.0 bootstrap binary is old. If we could run `guix pull` on the rescue server first (to get current substitutes), all packages would be available pre-built. The problem: `guix pull` itself needs ~1GB of overlay space which the rescue system doesn't have.

**Potential fix:** Use a larger Hetzner server type with more RAM (e.g. `cpx32` — 8GB RAM, more overlay space).

### Option B: Remove GRUB graphical image
Add `(theme #f)` or use `grub-efi-bootloader` without a theme. This avoids the librsvg dependency entirely.

The bootstrap OS in `/tmp/guix/deploy/hetzner-os.scm` uses the default grub which includes a theme. The theme is the only thing pulling in librsvg.

**Fix in `hetzner-machine-bootstrap-os-form`:** The generated OS could explicitly disable the GRUB theme. This would be a one-line patch.

### Option C: Manual bootstrap (reliable, documented in Guix cookbook)
1. Create a Hetzner server with any OS (Debian)
2. SSH in, install Guix package manager
3. `guix pull`
4. Write our OS config
5. `guix system init config.scm /` (or partition + mount, then init to /mnt)
6. Reboot
7. From that point on, `guix deploy` works normally for updates

This is how the Guix cookbook documents it for Linode/Kimsufi and it's proven to work.

### Option D: Pre-built disk image
`guix system image --image-type=raw base-system.scm` — build a raw disk image locally, upload to Hetzner via rescue mode (`dd`). Requires a full Guix System locally (not just the package manager).

---

## Lessons learned

1. `hetzner-environment-type` is new (added 2024) and has several bootstrap bugs when using the Guix 1.5.0 binary that gets installed on the rescue system
2. The fundamental issue: the 1.5.0 binary installed on rescue → tries to build packages → no substitutes for newer packages → fails
3. If you're on a full Guix System machine (not just the package manager on Ubuntu), most of these issues go away because `guix deploy` builds locally and ships the closure
4. The right workaround is Option B (disable GRUB theme) or Option C (manual bootstrap)

---

## Patches made to `hetzner.scm` (in `/tmp/guix-patch2/gnu/machine/hetzner.scm`)

1. `mkdir -p /etc/guix` before `guix-install.sh` (fixes chown failure)
2. `groupadd guixbuild` + 10 build users (fixes missing group)
3. Manual daemon start via store binary path (fixes daemon not starting)
4. Use glob `ls /gnu/store/*-guix-*/bin/guix` to find binary (fixes PATH issue)

These patches are not committed — they're in `/tmp` and will be lost on restart.
The right approach is to upstream these fixes or use Option B/C above.
