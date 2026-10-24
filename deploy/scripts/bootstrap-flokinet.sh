#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# bootstrap-flokinet.sh — Bootstrap a FlokiNET VPS with Guix System
#
# FlokiNET supports custom ISO upload via their web panel (IPMI).
# This script runs AFTER booting into the Guix installer ISO.
#
# Prerequisites:
#   1. Order a VPS (4GB+ RAM) at flokinet.is
#   2. Upload the Guix System ISO via the control panel
#   3. Boot into the ISO (IPMI console)
#   4. SSH into the installer from your machine
#
# Usage:
#   ssh root@<vps-ip> < deploy/scripts/bootstrap-flokinet.sh
#
# After bootstrap:
#   1. Note the SSH host key (printed at end)
#   2. Create deploy/providers/<location>.scm with the IP and host key
#   3. Deploy:
#      LOCALCHIMERA_PROVIDER=deploy/providers/<location>.scm \
#        bash deploy/scripts/reconfigure.sh

set -euo pipefail

echo "[bootstrap] FlokiNET Guix System bootstrap"
echo "[bootstrap] Checking disk layout..."
lsblk

# Detect disk — FlokiNET KVM uses /dev/vda or /dev/sda
if [ -b /dev/vda ]; then
    DISK=/dev/vda
    ROOT_PART=/dev/vda1
    EFI_PART=/dev/vda15
elif [ -b /dev/sda ]; then
    DISK=/dev/sda
    ROOT_PART=/dev/sda1
    EFI_PART=/dev/sda15
else
    echo "[bootstrap] ERROR: No disk found. Expected /dev/vda or /dev/sda"
    exit 1
fi

echo "[bootstrap] Using disk: $DISK"

# Partition the disk (GPT, EFI)
echo "[bootstrap] Partitioning $DISK..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB 512MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 512MiB 100%

# Wait for partition devices
sleep 2

# Format
echo "[bootstrap] Formatting..."
mkfs.vfat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"

# Mount
echo "[bootstrap] Mounting..."
mount "${DISK}2" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}1" /mnt/boot/efi

# Initialize Guix
echo "[bootstrap] Installing Guix System..."
herd start cow-store /mnt

# Generate base config
mkdir -p /mnt/etc/guix
cat > /mnt/etc/guix/system.scm << 'GUIXEOF'
;; Minimal Guix System for initial boot — reconfigure.sh will
;; deploy the full localchimera config after first SSH connection.
(use-modules (gnu))
(use-service-modules networking ssh)

(operating-system
  (host-name "localchimera")
  (timezone "Etc/UTC")
  (bootloader (bootloader-configuration
                (bootloader grub-efi-bootloader)
                (targets '("/boot/efi"))))
  (file-systems (cons* (file-system
                          (mount-point "/")
                          (device (file-system-label "guix-root"))
                          (type "ext4"))
                       (file-system
                          (mount-point "/boot/efi")
                          (device (file-system-label "EFI"))
                          (type "vfat"))
                       %base-file-systems))
  (users (cons (user-account
                 (name "deploy")
                 (group "users")
                 (supplementary-groups '("wheel"))
                 (home-directory "/home/deploy"))
               %base-user-accounts))
  (sudoers-file (plain-file "sudoers"
                  "root ALL=(ALL) ALL\n%wheel ALL=(ALL) ALL\ndeploy ALL=(ALL) NOPASSWD: ALL\n"))
  (packages %base-packages)
  (services (list (service dhcpcd-service-type)
                  (service openssh-service-type
                           (openssh-configuration
                            (permit-root-login 'prohibit-password)
                            (password-authentication? #f))))))
GUIXEOF

# Label partitions
e2label "${DISK}2" "guix-root"
fatlabel "${DISK}1" "EFI"

# Install
guix system init /mnt/etc/guix/system.scm /mnt

echo ""
echo "[bootstrap] ============================================"
echo "[bootstrap] Guix System installed!"
echo "[bootstrap] Reboot into the installed system."
echo "[bootstrap]"
echo "[bootstrap] After reboot:"
echo "[bootstrap]   1. SSH as root, set deploy user's SSH key"
echo "[bootstrap]   2. Create deploy/providers/<name>.scm"
echo "[bootstrap]   3. LOCALCHIMERA_PROVIDER=... bash deploy/scripts/reconfigure.sh"
echo "[bootstrap] ============================================"
