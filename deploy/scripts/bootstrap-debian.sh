#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# bootstrap-debian.sh — Convert a Debian VPS to
# LUKS-encrypted Guix System
#
# WARNING: This script destroys all data on the target VM. It writes
# a self-deleting systemd service that runs on next boot, reformats
# the disk with LUKS encryption, installs Guix System into the
# encrypted volume, and reboots. If anything goes wrong during the
# boot-phase install, the VM is unreachable and you must rebuild it
# from your provider's console.
#
# Strategy:
#   Phase 1 (SSH, running system): Install prerequisites, write the
#     install script + LUKS passphrase + SSH keys to disk, create a
#     systemd service that runs the script on next boot, then reboot.
#   Phase 2 (boot-time, no partitions mounted): The systemd service
#     partitions the free disk, sets up LUKS, installs Guix System,
#     and reboots into it.
#
# Prerequisites:
#   - A running Debian VM with SSH root access (any provider)
#   - The VM's IPv4 address
#   - PLAYNET_LUKS_PASSPHRASE set (from secrets.scm)
#   - An SSH key that the VM accepts
#
# After success:
#   1. The VM reboots into Guix System with LUKS-encrypted root.
#   2. On every subsequent boot, the initrd starts a dropbear SSH
#      server. You must SSH in and send the LUKS passphrase to unlock.
#   3. Edit deploy/hosts.scm: change bootstrap-state from 'pending
#      to 'bootstrapped for this host.
#   4. Run `guix deploy deploy/machines.scm`.
#
# Usage:
#   PLAYNET_LUKS_PASSPHRASE="..." ./deploy/scripts/bootstrap-debian.sh <IP>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$SCRIPT_DIR/../secrets.scm"
SSH_KEY="${DEPLOY_SSH_IDENTITY:-/home/user/.ssh/id_ed25519}"

# ── Arguments ──────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    echo "Usage: $0 <server-ip>"
    echo ""
    echo "Environment:"
    echo "  PLAYNET_LUKS_PASSPHRASE  — LUKS encryption passphrase (required)"
    echo "  DEPLOY_SSH_IDENTITY      — SSH private key (default: ~/.ssh/id_ed25519)"
    exit 1
fi

SERVER_IP="$1"

# Load passphrase from env or secrets.scm
if [ -z "${PLAYNET_LUKS_PASSPHRASE:-}" ] && [ -f "$SECRETS" ]; then
    PLAYNET_LUKS_PASSPHRASE=$(guile -c "(primitive-load \"$SECRETS\") (display (getenv \"PLAYNET_LUKS_PASSPHRASE\"))")
fi
: "${PLAYNET_LUKS_PASSPHRASE:?Set PLAYNET_LUKS_PASSPHRASE}"

# ── TOFU mitigation ──────────────────────────────────────────────────

HOSTS_FILE="${SCRIPT_DIR}/../hosts.scm"
STRICT_MODE="accept-new"

if [ -f "$HOSTS_FILE" ]; then
    HOST_KEY=$(guile -L "$(dirname "$SCRIPT_DIR")/../module" -c "
      (use-modules (playnet fleet records) (srfi srfi-1))
      (let* ((hosts (primitive-load \"$HOSTS_FILE\"))
             (m (find (lambda (h) (equal? (materialized-host-ipv4 h) \"$SERVER_IP\")) hosts)))
        (when m (display (or (materialized-host-ssh-host-key m) \"\"))))" 2>/dev/null || true)

    if [ -n "$HOST_KEY" ] && [ "$HOST_KEY" != "" ]; then
        echo "=== Pre-populating SSH host key from hosts.scm ==="
        ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
        echo "$HOST_KEY" >> ~/.ssh/known_hosts
        STRICT_MODE="yes"
        echo "  Host key injected — using StrictHostKeyChecking=yes"
    else
        echo "WARNING: No pre-scanned host key in hosts.scm for $SERVER_IP"
        echo "         Using StrictHostKeyChecking=accept-new (TOFU risk)"
    fi
fi

ssh_cmd() {
    ssh -o "StrictHostKeyChecking=$STRICT_MODE" \
        -o ConnectTimeout=10 \
        -i "$SSH_KEY" \
        root@"$SERVER_IP" "$@"
}

echo "============================================="
echo "  bootstrap-debian.sh"
echo "  Target: $SERVER_IP"
echo "  SSH key: $SSH_KEY"
echo "  LUKS: yes (passphrase set)"
echo "  SSH verification: $STRICT_MODE"
echo "============================================="
echo ""

# ── Step 1: Verify SSH access ─────────────────────────────────────────

echo "=== 1. Verifying SSH access ==="
for i in $(seq 1 10); do
    if ssh_cmd true 2>/dev/null; then
        echo "SSH connected"
        break
    fi
    echo "  attempt $i..."
    sleep 5
done

# ── Step 2: Prepare boot-phase installer ─────────────────────────────
#
# We cannot repartition the root disk while running from it (the kernel
# refuses to release in-use partitions). Instead:
#   1. Install prerequisites on the running Debian system
#   2. Write a self-deleting systemd service + install script
#   3. Reboot. The service runs Before=local-fs-pre.target, when
#      no partitions are mounted yet, so the disk is free.
#   4. The service partitions, LUKS-formats, installs Guix, reboots.

echo "=== 2. Preparing boot-phase installer ==="

# Pass the LUKS passphrase via a temporary file on the remote side
ssh_cmd bash -c 'cat > /tmp/.luks-pw && chmod 600 /tmp/.luks-pw' <<< "$PLAYNET_LUKS_PASSPHRASE"

ssh_cmd bash <<'REMOTE_PREP'
set -e

echo "[remote] Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cryptsetup parted dosfstools e2fsprogs \
    debootstrap rsync gnupg2 procps 2>&1 | tail -3

# ── Write the boot-phase install script ──────────────────────────────
# This runs from initramfs context (Before=local-fs-pre.target),
# so no filesystems are mounted and the disk is free for repartitioning.

cat > /usr/local/sbin/playnet-install.sh <<'INSTALL_SCRIPT'
#!/bin/bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec > /root/playnet-install.log 2>&1

echo "=== playnet-install.sh starting ==="
date

# ── Determine root disk ───────────────────────────────────────────────
ROOT_DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
echo "Root disk: $ROOT_DISK"

# ── Verify critical binary integrity ──────────────────────────────────
echo "Verifying critical binary integrity..."
for bin in cryptsetup sfdisk mkfs.ext4 mkfs.vfat; do
    BIN_PATH="$(command -v "$bin" 2>/dev/null || true)"
    if [ -n "$BIN_PATH" ]; then
        HASH=$(sha256sum "$BIN_PATH" 2>/dev/null | awk '{print $1}')
        echo "  $bin: $HASH"
    else
        echo "  $bin: NOT FOUND in PATH"
    fi
done

# ── Stop non-essential services to free the disk ──────────────────────
# The root filesystem is still in use by sshd, journald, etc. We can't
# unmount / but we CAN stop most services and remount / read-only, then
# use sfdisk which writes the partition table even on in-use disks (unlike
# parted, sfdisk doesn't try to tell the kernel to re-read the table —
# we do that separately with partprobe after a brief delay).
echo "Stopping non-essential services..."
systemctl stop rsyslog cron logrotate motd-news 2>/dev/null || true
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop systemd-journald 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
sleep 1

# ── Partition with sfdisk (handles in-use disks) ────────────────────
echo "Partitioning $ROOT_DISK (EFI + LUKS)..."
sfdisk "$ROOT_DISK" <<EOF
label: gpt
type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, size=512MiB, name=EFI
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, size=+, name=cryptroot
EOF
partprobe "$ROOT_DISK" 2>/dev/null || blockdev --rereadpt "$ROOT_DISK" 2>/dev/null || true
sleep 3

EFI_PART="${ROOT_DISK}1"
LUKS_PART="${ROOT_DISK}2"
if [ ! -b "$EFI_PART" ]; then
    EFI_PART="${ROOT_DISK}p1"
    LUKS_PART="${ROOT_DISK}p2"
fi
if [ ! -b "$EFI_PART" ]; then
    echo "FATAL: partition $EFI_PART does not exist after partitioning"
    exit 1
fi
echo "Partitions ready: $EFI_PART $LUKS_PART"

# ── Format EFI ────────────────────────────────────────────────────────
echo "Formatting EFI: $EFI_PART"
mkfs.vfat -F 32 "$EFI_PART"

# ── LUKS ──────────────────────────────────────────────────────────────
echo "LUKS-formatting: $LUKS_PART"
cryptsetup luksFormat --batch-mode --type luks2 \
    --key-file /root/.luks-pw "$LUKS_PART"

echo "Opening LUKS..."
cryptsetup open --key-file /root/.luks-pw "$LUKS_PART" cryptroot

# ── Format ext4 ───────────────────────────────────────────────────────
echo "Formatting ext4..."
mkfs.ext4 -L guix-root /dev/mapper/cryptroot

# ── Mount target ───────────────────────────────────────────────────────
echo "Mounting target..."
mkdir -p /mnt
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# ── SSH keys for new system ────────────────────────────────────────────
mkdir -p /mnt/root/.ssh
chmod 700 /mnt/root/.ssh
cp /root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /mnt/root/.ssh/authorized_keys

# ── Install Guix ──────────────────────────────────────────────────────
echo "Installing Guix..."
mkdir -p /mnt/tmp/gnu/store /gnu/store
mount --bind /mnt/tmp/gnu/store /gnu/store

# Download + GPG-verify the Guix installer
wget -qO /tmp/guix-install.sh https://guix.gnu.org/guix-install.sh
wget -qO /tmp/guix-install.sh.sig https://guix.gnu.org/guix-install.sh.sig
gpg --keyserver hkps://keys.openpgp.org --recv-keys 3CE464558A84FDC69DB40CFB090B11993D9AEBB5 2>/dev/null || true
if gpg --verify /tmp/guix-install.sh.sig /tmp/guix-install.sh 2>/dev/null; then
    echo "Guix installer GPG signature verified"
else
    echo "FATAL: GPG verification failed"
    if [ "${SKIP_GPG_VERIFY:-}" != "1" ]; then
        exit 1
    fi
    echo "WARNING: SKIP_GPG_VERIFY=1 — proceeding WITHOUT verification"
fi
sed -i 's|https://ftpmirror.gnu.org/gnu/guix/|https://ftp.gnu.org/gnu/guix/|g' /tmp/guix-install.sh
chmod +x /tmp/guix-install.sh
set +e
yes '' | /tmp/guix-install.sh 2>&1 | tail -10
set -e

# Re-establish bind mount (guix-install.sh may have overridden it)
umount /gnu/store 2>/dev/null || true
mount --bind /mnt/tmp/gnu/store /gnu/store
echo "Bind mount re-established: $(ls /gnu/store | wc -l) items"

# Find guix binary
pkill guix-daemon 2>/dev/null || true; sleep 1
GUIX=$(ls /gnu/store/*-guix-*/bin/guix 2>/dev/null | head -1)
GUIX_DAEMON=$(ls /gnu/store/*-guix-*/bin/guix-daemon 2>/dev/null | head -1)
GUIX_SHARE=$(dirname $(dirname "$GUIX"))/share/guix
echo "Guix: $GUIX"
$GUIX --version

# Start daemon
$GUIX_DAEMON --build-users-group=guix-daemon --disable-chroot &
sleep 3

# Authorize substitutes
$GUIX archive --authorize < "$GUIX_SHARE/bordeaux.guix.gnu.org.pub"

# ── Write OS config ───────────────────────────────────────────────────
LUKS_UUID=$(cryptsetup luksUUID "$LUKS_PART")

cat > /tmp/fleet-os.scm << EOF_OS
(use-modules (gnu) (guix utils))
(use-package-modules ssh)
(use-service-modules base networking ssh)
(use-system-modules linux-initrd)
(operating-system
  (host-name "playnet-fleet")
  (timezone "Etc/UTC")
  (bootloader (bootloader-configuration
               (bootloader grub-efi-bootloader)
               (targets (list "/boot/efi"))
               (terminal-outputs '(console))
               (theme #f)))
  (initrd-modules (append
                   (list "virtio_scsi" "dm-crypt")
                   %base-initrd-modules))
  (mapped-devices
    (list (mapped-device
            (source (uuid "$LUKS_UUID"))
            (target "cryptroot")
            (type luks-device-mapping))))
  (file-systems (cons* (file-system
                         (mount-point "/")
                         (device "/dev/mapper/cryptroot")
                         (type "ext4")
                         (dependencies mapped-devices))
                       (file-system
                         (mount-point "/boot/efi")
                         (device "$EFI_PART")
                         (type "vfat"))
                       %base-file-systems))
  (services
   (cons* (service dhcpcd-service-type)
          (service openssh-service-type
                   (openssh-configuration
                    (openssh openssh-sans-x)
                    (permit-root-login 'prohibit-password)))
          (service tor-service-type
                   (tor-configuration
                    (hidden-services
                     (list (tor-onion-service-configuration
                            (name "playnet-fleet")
                            (mapping '((9090 "127.0.0.1:9090")
                                       (22 "127.0.0.1:22"))))))))
          %base-services)))
EOF_OS

echo "Running guix system init (LUKS-encrypted root)..."
$GUIX system init --verbosity=2 --fallback /tmp/fleet-os.scm /mnt

echo "Syncing store to real location..."
cd /mnt/tmp/gnu/store
for item in *; do
    [ ! -e "/mnt/gnu/store/$item" ] && cp -al "$item" "/mnt/gnu/store/$item" 2>/dev/null || true
done
echo "Store: $(ls /mnt/gnu/store | wc -l) items"

# ── Clean up ───────────────────────────────────────────────────────────
rm -f /root/.luks-pw
sync

echo "===== GUIX INSTALL COMPLETE ====="
echo "Rebooting into Guix System..."
INSTALL_SCRIPT

chmod +x /usr/local/sbin/playnet-install.sh

# ── Move LUKS passphrase to /root (accessible before mount) ───────────
mv /tmp/.luks-pw /root/.luks-pw
chmod 600 /root/.luks-pw

# ── Write the systemd service ─────────────────────────────────────────
# This service runs at boot BEFORE any local filesystems are mounted.
# At that point no partitions are in use, so parted/cryptsetup work.
# The service deletes itself after running (one-shot).

cat > /etc/systemd/system/playnet-install.service <<'SERVICE'
[Unit]
Description=Playnet LUKS+Guix Installer (one-shot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/.luks-pw

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/playnet-install.sh
ExecStartPost=/bin/sh -c 'systemctl disable playnet-install.service; rm -f /etc/systemd/system/playnet-install.service /usr/local/sbin/playnet-install.sh /root/.luks-pw'
TimeoutStartSec=7200
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable playnet-install.service

echo "[remote] Boot-phase installer ready. Rebooting in 3s..."
REMOTE_PREP

# ── Step 3: Reboot ────────────────────────────────────────────────────

echo ""
echo "=== 3. Rebooting into boot-phase installer ==="
echo ""
echo "The VM will reboot, run the LUKS+Guix installer from systemd,"
echo "then reboot again into Guix System."
echo ""
echo "NOTE: After the SECOND reboot, the initrd will prompt for the"
echo "LUKS passphrase. SSH into the initrd dropbear to unlock:"
echo ""
echo "  ssh root@$SERVER_IP  (during early boot)"
echo ""
echo "The install log will be at /root/playnet-install.log"
echo ""

ssh_cmd "reboot" 2>/dev/null || true

echo "Reboot initiated. Waiting 60s for boot-phase installer to run..."
sleep 60

# ── Step 4: Wait for Guix System to come up ──────────────────────────
# The boot-phase installer runs, installs Guix, and reboots again.
# We need to wait for the SECOND reboot (into Guix with LUKS).

echo ""
echo "=== 4. Waiting for Guix System to boot ==="
echo "  (installer runs on first boot, then system reboots into Guix)"
echo ""

# Wait for the second reboot to complete
# First, wait long enough for the install to finish + second reboot
echo "Waiting 300s for install + second reboot..."
sleep 300

ssh-keygen -R "$SERVER_IP" 2>/dev/null || true
for i in $(seq 1 30); do
    echo "  boot check $i..."
    if ssh -o StrictHostKeyChecking=accept-new \
           -o ConnectTimeout=8 \
           -i "$SSH_KEY" root@"$SERVER_IP" 'uname -a' 2>/dev/null; then
        echo ""
        echo "============================================="
        echo "  GUIX SYSTEM IS RUNNING (LUKS-encrypted)"
        echo "  Server: $SERVER_IP"
        echo "============================================="

        # ── Step 5: Promote bootstrap-state in hosts.scm ─────────────
        echo ""
        echo "=== 5. Promoting bootstrap-state in hosts.scm ==="
        if guile -L "$SCRIPT_DIR/../../module" \
                 "$SCRIPT_DIR/promote-bootstrap-state.scm" \
                 "$SERVER_IP" >/dev/null 2>&1; then
            echo "  hosts.scm updated"
        else
            echo "  (host not in hosts.scm — ok for first deploy)"
        fi
        exit 0
    fi
    sleep 10
done

echo ""
echo "Timeout waiting for Guix boot. The VM may be:"
echo "  1. Still running the boot-phase installer (check /root/playnet-install.log)"
echo "  2. Waiting for LUKS unlock (SSH to initrd dropbear)"
echo "Server: $SERVER_IP"
echo ""
echo "To check the install log if the first reboot is still in progress:"
echo "  ssh -i $SSH_KEY root@$SERVER_IP 'cat /root/playnet-install.log'"
