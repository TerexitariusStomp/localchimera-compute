#!/usr/bin/env bash
# qemu-test-iso.sh — boot the playnet ISO locally in QEMU for smoke testing.
#
# Usage:
#   make qemu                                    # build + boot
#   deploy/scripts/qemu-test-iso.sh [ISO_PATH]   # boot a specific ISO
#
# Boots the ISO with:
#   - 2 GiB RAM, 2 vCPUs, KVM acceleration if /dev/kvm is accessible
#   - UEFI firmware (matches the ISO's grub-efi-bootloader)
#   - A 10 GiB throwaway virtual disk for testing `playnet-install`
#   - SSH port forward: host 2222 → guest 22
#
# In another terminal:
#   ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#     -i ~/.ssh/<your-operator-key> root@localhost
#
# Inside the VM, exercise the full installer:
#   lsblk
#   playnet-install /dev/vda
#
# After reboot off the virtual disk, ssh back in to verify the on-disk
# Guix System came up with sshd + your key (the state `guix deploy`
# expects as a target).
#
# Quit QEMU: Ctrl-A then X (serial console).
#
# Env vars:
#   SSH_PORT=N        forward host port N instead of 2222
#   QEMU_DISK=PATH    use a specific disk image instead of /tmp/...
#   KEEP_DISK=1       preserve the disk between runs (default: wipe each boot)

set -euo pipefail

ISO="${1:-}"
DISK="${QEMU_DISK:-/tmp/playnet-qemu-disk.img}"
SSH_PORT="${SSH_PORT:-2222}"

if [[ -z "$ISO" ]]; then
  echo "qemu-test-iso: building ISO via 'make iso' (slow on first run)..." >&2
  ISO=$(make -s iso | tail -1)
fi

if [[ ! -f "$ISO" ]]; then
  echo "qemu-test-iso: ISO not found: $ISO" >&2
  exit 1
fi

# Fresh disk unless KEEP_DISK=1, so playnet-install can wipe cleanly.
if [[ "${KEEP_DISK:-0}" != "1" ]] || [[ ! -f "$DISK" ]]; then
  rm -f "$DISK"
  qemu-img create -f raw "$DISK" 10G >/dev/null
fi

# KVM if available, plain TCG otherwise.
ACCEL=tcg
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL=kvm
fi

# UEFI firmware. Try Guix's ovmf package first (reproducible); fall back
# to common system locations.
OVMF_CODE=""
if command -v guix >/dev/null 2>&1; then
  OVMF_DIR=$(guix build ovmf 2>/dev/null | tail -1 || true)
  if [[ -n "$OVMF_DIR" && -d "$OVMF_DIR" ]]; then
    for c in "$OVMF_DIR/share/firmware/ovmf_x64.bin" \
             "$OVMF_DIR/share/firmware/ovmf_ia32.bin" \
             "$OVMF_DIR/share/OVMF.fd"; do
      [[ -f "$c" ]] && OVMF_CODE="$c" && break
    done
  fi
fi
if [[ -z "$OVMF_CODE" ]]; then
  for p in /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/edk2/ovmf/OVMF_CODE.fd \
           /usr/share/edk2-ovmf/OVMF_CODE.fd \
           /usr/share/qemu/OVMF.fd; do
    [[ -f "$p" ]] && OVMF_CODE="$p" && break
  done
fi
if [[ -z "$OVMF_CODE" ]]; then
  echo "qemu-test-iso: no OVMF UEFI firmware found." >&2
  echo "  Install via: guix install ovmf  (or apt-get install ovmf)" >&2
  exit 1
fi

cat <<EOF >&2
qemu-test-iso: starting VM
  ISO          $ISO
  Disk         $DISK (10 GiB, $( [[ "${KEEP_DISK:-0}" = "1" ]] && echo preserved || echo fresh ))
  OVMF         $OVMF_CODE
  Acceleration $ACCEL
  SSH port     localhost:$SSH_PORT

In another terminal:
  ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\
      root@localhost

Quit: Ctrl-A then X.
EOF

exec qemu-system-x86_64 \
  -name playnet-iso-test \
  -machine type=q35,accel="$ACCEL" \
  -m 2G -smp 2 \
  -bios "$OVMF_CODE" \
  -cdrom "$ISO" \
  -drive file="$DISK",format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
