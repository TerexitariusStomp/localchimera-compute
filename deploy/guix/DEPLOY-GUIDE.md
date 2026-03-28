# Deploying Guix System on Hetzner Cloud

_What actually works, as of 2026-03-28._

This guide covers deploying GNU Guix System to a Hetzner Cloud VPS from a
non-Guix host (e.g. Ubuntu with `guix` package manager installed). It
documents every pitfall we hit and the working solutions.

---

## Overview

The Guix manual (section 11.17) documents `hetzner-environment-type` for
one-command provisioning. In practice, this fails due to:

1. `ftpmirror.gnu.org` returning 502 (the install script's only mirror)
2. The Guix docs claiming x86 Hetzner uses BIOS boot, but newer server
   types (cpx22, etc.) actually use UEFI
3. The GRUB default theme pulling in `librsvg` which has no pre-built
   substitute for the 1.5.0 binary

The working approach: **manual bootstrap** using `ftp.gnu.org`, EFI
bootloader, and no GRUB theme, then ongoing management via
`managed-host-environment-type`.

---

## Prerequisites

### On your local machine

1. **Guix package manager** installed (not necessarily Guix System):

   ```sh
   # If not yet installed:
   # https://guix.gnu.org/manual/en/html_node/Binary-Installation.html
   ```

2. **SSH key pair:**

   ```sh
   ssh-keygen -t ed25519
   ```

3. **Guix signing key** (needed for `guix deploy` to send store items):

   ```sh
   sudo guix archive --generate-key
   ```

4. **Hetzner Cloud API token:**
   Project > Security > API Tokens > Generate API Token (read/write)

### Secrets

Store your API token in `deploy/guix/secrets.scm` (gitignored):

```scheme
;;; deploy/guix/secrets.scm — NOT committed
(setenv "GUIX_HETZNER_API_TOKEN" "your-token-here")
```

The deploy script loads this automatically via Guile's `(setenv ...)`.

---

## Step 1: Bootstrap (first time only)

The bootstrap script (`deploy/guix/bootstrap-hetzner.sh`) automates the
entire initial provisioning. It does what `hetzner-environment-type` does,
with fixes for the known issues.

```sh
./deploy/guix/bootstrap-hetzner.sh
```

This takes ~15 minutes and does:

1. Creates a Hetzner server (cpx22/x86, nbg1) via API
2. Enables rescue mode (Debian) and hard-resets into it
3. On the rescue system:
   - Installs `cloud-initramfs-growroot` and `uidmap`
   - Grows `/dev/sda1` to the full disk with `growpart`
   - Formats ext4 and mounts
   - Bind-mounts `/mnt/tmp/gnu/store` to `/gnu/store`
   - Downloads `guix-install.sh` and patches the mirror URL
   - Runs the installer, then re-establishes the bind mount
   - Starts `guix-daemon` manually (systemd fails in rescue)
   - Authorizes the Bordeaux substitute server
   - Runs `guix system init` with the EFI OS config
   - Hardlinks store items from `/mnt/tmp/gnu/store` to `/mnt/gnu/store`
4. Disables rescue mode, power-cycles, and waits for SSH

### What the bootstrap script fixes

| Problem                              | Cause                                  | Fix                                   |
| ------------------------------------ | -------------------------------------- | ------------------------------------- |
| `ftpmirror.gnu.org` 502              | GNU mirror redirector down             | `sed` to use `ftp.gnu.org`            |
| `Missing commands: newgidmap`        | Rescue lacks `uidmap`                  | `apt-get install uidmap`              |
| 3GB partition on 76GB disk           | Hetzner image has small sda1           | `growpart /dev/sda 1`                 |
| `guix-daemon` won't start            | systemd broken in rescue               | Manual start with `--disable-chroot`  |
| GRUB theme needs `librsvg`           | No substitute for 1.5.0 binary         | `(theme #f)` in bootloader config     |
| BIOS GRUB on UEFI firmware           | Docs say x86=BIOS, but cpx22 is UEFI   | `grub-efi-bootloader` + `/boot/efi`   |
| `gnu-store.mount` overrides bind     | `guix-install.sh` creates systemd unit | Re-mount after install                |
| Store items only in `/tmp/gnu/store` | Bind mount separation                  | Hardlink to `/gnu/store` post-install |
| `chown /etc/guix` fails              | Directory doesn't exist yet            | `mkdir -p /etc/guix` before install   |

---

## Step 2: Ongoing management with `guix deploy`

After bootstrap, the server is a running Guix System. Manage it with
`guix deploy` using `managed-host-environment-type` (Guix manual section
11.17):

```sh
guix deploy deploy/guix/machines.scm
```

### `machines.scm`

```scheme
(use-modules (gnu machine)
             (gnu machine ssh)
             (gnu machine hetzner)
             (gnu packages ssh)
             (gnu services networking)
             (gnu services ssh)
             (gnu services base)
             (gnu system linux-initrd)
             (gnu))

(define %guix-x86
  (operating-system
    (host-name "guix-x86")
    (timezone "Etc/UTC")
    (bootloader (bootloader-configuration
                 (bootloader grub-efi-bootloader)
                 (targets (list "/boot/efi"))
                 (terminal-outputs '(console))
                 (theme #f)))
    (initrd-modules (append
                     (list "virtio_scsi")
                     %base-initrd-modules))
    (file-systems (cons* (file-system
                           (mount-point "/")
                           (device "/dev/sda1")
                           (type "ext4"))
                         (file-system
                           (mount-point "/boot/efi")
                           (device "/dev/sda15")
                           (type "vfat"))
                         %base-file-systems))
    (services
     (cons* (service dhcpcd-service-type)
            (service openssh-service-type
                     (openssh-configuration
                      (openssh openssh-sans-x)
                      (permit-root-login 'prohibit-password)))
            %base-services))))

(list (machine
       (operating-system %guix-x86)
       (environment managed-host-environment-type)
       (configuration (machine-ssh-configuration
                       (host-name "SERVER_IP")
                       (system "x86_64-linux")
                       (identity "/home/nozomi/.ssh/id_ed25519")
                       (host-key "ssh-ed25519 AAAAC3NzaC...")))))
```

### Key points

- **`grub-efi-bootloader`** with target `/boot/efi` (NOT `grub-bootloader`)
- **`(theme #f)`** avoids the `librsvg` dependency
- **`virtio_scsi`** in initrd-modules (Hetzner uses virtio disks)
- **`/dev/sda15`** is the EFI System Partition (vfat, 244M)
- **`dhcpcd-service-type`** for networking (not the deprecated
  `dhcp-client-service-type`)
- **`openssh-sans-x`** (no X11 dependency on a server)

### Common operations

```sh
# Reconfigure (apply OS changes)
guix deploy deploy/guix/machines.scm

# Roll back to previous generation
guix deploy --roll-back deploy/guix/machines.scm

# Run a command on all machines
guix deploy deploy/guix/machines.scm -x -- herd status

# SSH in directly
ssh -i ~/.ssh/id_ed25519 root@SERVER_IP
```

---

## Adding services

Edit the `services` list in `%guix-x86`. Example adding nginx:

```scheme
(services
 (cons* (service dhcpcd-service-type)
        (service openssh-service-type
                 (openssh-configuration
                  (openssh openssh-sans-x)
                  (permit-root-login 'prohibit-password)))
        (service nginx-service-type)
        %base-services))
```

Then `guix deploy deploy/guix/machines.scm`.

---

## Hetzner server types

The Guix docs default to `cx42`. The cheapest working types:

| Type  | Arch | vCPU | RAM | Disk  | EUR/mo | Boot |
| ----- | ---- | ---- | --- | ----- | ------ | ---- |
| cpx22 | x86  | 2    | 4GB | 80GB  | ~6     | UEFI |
| cpx32 | x86  | 4    | 8GB | 160GB | ~12    | UEFI |
| cax11 | ARM  | 2    | 4GB | 40GB  | ~4     | UEFI |

**`cpx11` is NOT supported** (rescue system too small to bootstrap).

Available locations: `nbg1` (Nuremberg), `hel1` (Helsinki), `sin`
(Singapore). Note: `fsn1` (Falkenstein) was disabled at time of writing.

---

## When `hetzner-environment-type` will work

The built-in `hetzner-environment-type` would work if:

1. `ftpmirror.gnu.org` comes back online, AND
2. The Guix `(gnu machine hetzner)` module is updated to:
   - Use `grub-efi-bootloader` for newer x86 server types
   - Disable the GRUB theme (or ensure `librsvg` substitutes exist)

When those are fixed, the config simplifies to:

```scheme
(list (machine
       (operating-system %hetzner-os-x86)  ; or a custom OS inheriting it
       (environment hetzner-environment-type)
       (configuration (hetzner-configuration
                       (server-type "cpx22")
                       (ssh-key "/home/you/.ssh/id_ed25519")))))
```

Until then, use `bootstrap-hetzner.sh` + `managed-host-environment-type`.

---

## File inventory

```
deploy/guix/
  bootstrap-hetzner.sh   -- one-shot provisioning script
  machines.scm           -- guix deploy target (managed-host)
  secrets.scm            -- API token (gitignored)
  deploy.sh              -- wrapper: loads secrets, runs guix deploy
  base-system.scm        -- full OS declaration (for future use)
  xorg-service.scm       -- Shepherd service for xorg actors
  channels.scm           -- pinned Guix channel
  DEPLOY-GUIDE.md        -- this file
```
