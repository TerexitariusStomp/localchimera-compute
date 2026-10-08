#!/usr/bin/env bash
# install-to-disk.sh — one-shot installer for the playnet ISO (Path B).
#
# Runs inside the live system booted from deploy/playnet-iso.scm.
# Partitions the target disk, mounts /mnt, runs `guix system init` with
# deploy/guix/playnet-iso-post-install.scm, and reboots. After reboot the
# VM comes up off disk with a minimal Guix System (sshd + deploy user)
# that is a `guix deploy` target. From an operator workstation:
#
#   PLAYNET_PROVIDER=deploy/providers/<host>.scm \
#     guix time-machine -C deploy/channels.scm -- \
#     deploy deploy/machines.scm
#
# Modelled on the Guix Cookbook §3.9 (Running Guix on a Kimsufi Server).
#
# Usage: playnet-install /dev/DEVICE
#
# Refuses to autodetect — caller MUST verify the target disk with `lsblk`
# first. Wipes everything on DEVICE.

set -euo pipefail

DEVICE="${1:-}"
# Minimal on-disk OS config baked into the ISO at build time (sshd +
# deploy user + the operator pubkey from playnet-keys.scm). That's all
# `guix deploy` needs as a target. Override only for custom installs.
POST_INSTALL_CONFIG="${POST_INSTALL_CONFIG:-/etc/playnet/post-install.scm}"

if [[ -z "$DEVICE" ]]; then
  cat >&2 <<EOF
usage: playnet-install /dev/DEVICE

Wipes DEVICE, partitions it (EFI + ext4 root labeled playnet-root),
installs the playnet post-install OS, and reboots.

Run \`lsblk\` first to confirm the target disk. Typical KVM VMs use
/dev/vda; some hypervisors use /dev/sda or /dev/nvme0n1.
EOF
  exit 2
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "playnet-install: $DEVICE is not a block device" >&2
  exit 1
fi

if [[ ! -f "$POST_INSTALL_CONFIG" ]]; then
  echo "playnet-install: post-install config not found at $POST_INSTALL_CONFIG" >&2
  echo "Set POST_INSTALL_CONFIG=/path/to/os.scm to override." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "playnet-install: must run as root" >&2
  exit 1
fi

echo "playnet-install: about to WIPE $DEVICE and install Guix System."
lsblk "$DEVICE" || true
# Confirmation gate. Default is interactive (the irreversible step stays
# in front of a human, per the provider-specific guide — kept in the
# private ops vault, not in the public repo). For unattended deploys
# driven by deploy/scripts/provider-deploy.scm or CI, set
# PLAYNET_INSTALL_FORCE=1 to skip the prompt — only do this from a
# context where you have already verified the disk path.
if [[ "${PLAYNET_INSTALL_FORCE:-0}" == "1" ]]; then
  echo "playnet-install: PLAYNET_INSTALL_FORCE=1 set, skipping confirmation."
else
  read -r -p "Type the device path again to confirm: " confirm
  if [[ "$confirm" != "$DEVICE" ]]; then
    echo "playnet-install: confirmation mismatch, aborting" >&2
    exit 1
  fi
fi

# Partition layout: GPT, 512 MiB EFI, rest is ext4 root labeled
# playnet-root (matches the (file-system-label "playnet-root") in the
# post-install OS config).
parted "$DEVICE" --script -- \
  mklabel gpt \
  mkpart EFI fat32 1MiB 513MiB \
  set 1 esp on \
  mkpart root ext4 513MiB 100%

# Partition device naming differs for NVMe (/dev/nvme0n1p1) vs SATA/virtio
# (/dev/vda1). `lsblk -nro NAME` enumerates children in order.
mapfile -t PARTS < <(lsblk -nro NAME "$DEVICE" | tail -n +2)
if [[ "${#PARTS[@]}" -lt 2 ]]; then
  echo "playnet-install: expected at least 2 partitions on $DEVICE, found ${#PARTS[@]}" >&2
  exit 1
fi
EFI_PART="/dev/${PARTS[0]}"
ROOT_PART="/dev/${PARTS[1]}"

# Labels match the (file-system-label ...) declarations in post-install.scm.
mkfs.vfat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -F -L playnet-root "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# Pre-create swap on the target disk before guix system init runs.
# 8 GB plans see ~3.9 GiB tmpfs / on the live ISO; the activation step
# of `guix system init` is graft- and copy-heavy, and even with cow-
# store the daemon's intermediate writes can briefly overflow tmpfs.
# Swap-backed memory lets the kernel offload tmpfs pages to disk.
# Skipped on systems with ≥16 GiB RAM (unnecessary overhead).
INSTALL_SWAP="/mnt/.install-swap.bin"
TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [[ "$TOTAL_KB" -lt 16000000 ]]; then
  echo "playnet-install: provisioning 4 GiB install-time swap at $INSTALL_SWAP"
  fallocate -l 4G "$INSTALL_SWAP"
  chmod 600 "$INSTALL_SWAP"
  mkswap "$INSTALL_SWAP" >/dev/null
  swapon "$INSTALL_SWAP"
fi

# cow-store: redirect /gnu/store writes to /mnt during install so the
# graft step doesn't fill the live ISO's tmpfs. We do this manually
# (matching gnu/build/install.scm's mount-cow-store) rather than via
# `herd start cow-store /mnt` so the ISO doesn't have to ship the
# cow-store shepherd service.
COW_UPPER="/mnt/.cow-store-upper"
COW_WORK="/mnt/.cow-store-work"
mkdir -p "$COW_UPPER" "$COW_WORK" /.rw-store
chown 0:30000 "$COW_UPPER" /.rw-store 2>/dev/null || true
chmod 1775 "$COW_UPPER" /.rw-store 2>/dev/null || true
# The post-install config typically lives at /tmp/post-install*.scm.
# Below we bind-mount /mnt/tmp over /tmp (so daemon build dirs go to
# disk), which would mask any file in the original /tmp. Copy the
# config into /mnt/tmp first so it survives the bind.
mkdir -p /mnt/tmp
if [[ -f "$POST_INSTALL_CONFIG" && "$POST_INSTALL_CONFIG" == /tmp/* ]]; then
  cp "$POST_INSTALL_CONFIG" "/mnt$POST_INSTALL_CONFIG"
fi
# Bind /tmp into /mnt so the daemon's build dirs are also on disk
mount --bind /mnt/tmp /tmp
# Overlay: lower=current /gnu/store, upper=$COW_UPPER (on disk), work=$COW_WORK
mount -t overlay none /.rw-store \
  -o lowerdir=/gnu/store,upperdir="$COW_UPPER",workdir="$COW_WORK"
# Atomically move the new overlay over /gnu/store
mount --move /.rw-store /gnu/store
rmdir /.rw-store

# --no-grafts skips the security-patch grafting step. Grafts produce
# one new store path per patched package, and on a small-RAM VM the
# resulting store explosion has been observed to fill /gnu/store's
# overlay despite cow-store (see deploy/playnet-iso.scm header).
# Without grafts the final on-disk system is fine; subsequent
# `make deploy` invocations from the operator workstation apply
# grafts normally on a system that now has 8+ GiB usable RAM.
guix system init --no-grafts "$POST_INSTALL_CONFIG" /mnt

# Tear down install-time swap so it doesn't leak into the on-disk
# system's swap configuration (post-install OS manages its own swap).
swapoff "$INSTALL_SWAP" 2>/dev/null || true
rm -f /mnt/.install-swap.bin 2>/dev/null || true

sync
umount /mnt/boot/efi
umount /mnt

echo "playnet-install: install complete. Rebooting in 5s — disconnect now if you want to inspect."
sleep 5
reboot
