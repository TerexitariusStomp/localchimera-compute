#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# bootstrap-child.sh — automated installer for fleet child hosts.
#
# Partitions the target disk, opens LUKS, renders the child OS config,
# runs guix system init, and reboots into the initrd unlock door.
#
# Called once per host by the fleet keeper (server/fleet-keeper.scm).
# Exit 0 means the encrypted system is installed and the target is
# rebooting toward its initrd.  Nonzero means failed; the keeper marks
# the host install-failed and leaves it for a person.
#
# Usage:
#   bootstrap-child.sh NAME ADDRESS CHILD_DIR IDENTITY [STOCK_HOST_KEY]
#
# Network params (prefix, gateway) are resolved by render-child-os.scm
# from desired-fleet.scm (per-host provider-params), environment
# variables, or deploy/fleet-network.scm.

set -euo pipefail

# ── arguments ────────────────────────────────────────────────────────

NAME="${1:?usage: bootstrap-child.sh NAME ADDRESS CHILD_DIR IDENTITY [STOCK_HOST_KEY]}"
ADDRESS="${2:?usage: bootstrap-child.sh NAME ADDRESS CHILD_DIR IDENTITY [STOCK_HOST_KEY]}"
CHILD_DIR="${3:?usage: bootstrap-child.sh NAME ADDRESS CHILD_DIR IDENTITY [STOCK_HOST_KEY]}"
IDENTITY="${4:?usage: bootstrap-child.sh NAME ADDRESS CHILD_DIR IDENTITY [STOCK_HOST_KEY]}"
STOCK_HOST_KEY="${5:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="$REPO/deploy"
DATA_DIR="${PLAYNET_DATA_DIR:-/var/lib/playnet}"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ── SSH options (shared by ssh and scp) ──────────────────────────────
# The keeper runs on a Tor-only box; every ssh and scp must go through
# the same prefix the keeper process uses.  The prefix goes BEFORE the
# ssh/scp binary, not inside its option list.

SSH_PREFIX=()
if [[ -n "${PLAYNET_KEEPER_SSH_PREFIX:-}" ]]; then
  read -ra SSH_PREFIX <<< "$PLAYNET_KEEPER_SSH_PREFIX"
fi

SSH_OPTS=(
  -i "$IDENTITY"
  -o ConnectTimeout=15
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o LogLevel=ERROR
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
)
if [[ -n "$STOCK_HOST_KEY" ]]; then
  KH_FILE="$WORK_DIR/known_hosts"
  printf '%s %s\n' "$ADDRESS" "$STOCK_HOST_KEY" > "$KH_FILE"
  SSH_OPTS+=(-o "UserKnownHostsFile=$KH_FILE")
  SSH_OPTS+=(-o StrictHostKeyChecking=yes)
else
  SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

# ── helpers ──────────────────────────────────────────────────────────

log()  { printf '[bootstrap-child] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# Detect the single disk on the target.  Pure bash — no awk/grep.
detect_disk() {
  local raw disks=""
  raw=$(ssh_target lsblk -dno NAME,TYPE 2>/dev/null) || die "lsblk failed on $NAME"
  while IFS= read -r line; do
    local name="${line%% *}"
    local rest="${line#* }"
    local type="${rest## }"
    if [[ "$type" == "disk" ]]; then
      disks="${disks:+$disks }$name"
    fi
  done <<< "$raw"
  local count=0
  for _ in $disks; do count=$((count + 1)); done
  if [[ $count -eq 0 ]]; then
    die "no block device found on $NAME"
  elif [[ $count -gt 1 ]]; then
    die "multiple disks on $NAME — cannot auto-detect: $disks"
  fi
  echo "/dev/$disks"
}

# Construct partition device names from the base device.
# NVMe /dev/nvme0n1 → /dev/nvme0n1p1, SATA/virtio /dev/vda → /dev/vda1
partn() {
  local base="$1" n="$2"
  if [[ "$base" =~ [0-9]$ ]]; then
    echo "${base}p${n}"
  else
    echo "${base}${n}"
  fi
}

# SSH to the target as root.  Returns the SSH exit code (caller checks).
ssh_target() {
  "${SSH_PREFIX[@]}" ssh "${SSH_OPTS[@]}" "root@$ADDRESS" "$@"
}

# Run a command on the target over SSH.  Dies on nonzero exit.
on_target() {
  local rc=0
  ssh_target "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "SSH command failed (exit $rc): $*"
  fi
  return 0
}

# scp to the target.  Returns the scp exit code.
scp_target() {
  "${SSH_PREFIX[@]}" scp "${SSH_OPTS[@]}" -q "$@"
}

# Render the child OS config.  Args: UUID firm_flag key_path output_file
render() {
  local luks_uuid="$1" store_uuid="$2" esp_uuid="$3"
  local firmware_flag="$4" key_path="$5" output="$6"

  guile -L "$REPO/module" "$DEPLOY_DIR/scripts/render-child-os.scm" "$NAME" \
    --address "$ADDRESS" \
    --luks-uuid "$luks_uuid" \
    --store-uuid "$store_uuid" \
    --esp-uuid "$esp_uuid" \
    $firmware_flag \
    --identity-pub "$IDENTITY.pub" \
    --initrd-host-key-file "$key_path" \
    --data-dir "$DATA_DIR" \
    --deploy-dir "$DEPLOY_DIR" \
    > "$output" \
    || die "render-child-os.scm failed"
}

# ── pre-flight: local files ──────────────────────────────────────────

log "$NAME: starting install at $ADDRESS"

[[ -r "$CHILD_DIR/luks-passphrase" ]] || die "$CHILD_DIR/luks-passphrase not readable"
[[ -r "$IDENTITY" ]] || die "$IDENTITY not readable"
[[ -r "$CHILD_DIR/initrd-host-key" ]] || die "$CHILD_DIR/initrd-host-key not readable"

# ── SSH reachability ─────────────────────────────────────────────────

log "$NAME: checking SSH reachability"
ssh_target true || die "cannot reach $ADDRESS"

# ── pre-flight: target tools and marker ──────────────────────────────

log "$NAME: pre-flight checks on target"

on_target 'for cmd in guix cryptsetup sfdisk mkfs.vfat mkfs.ext4 blkid herd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done'

log "$NAME: detecting disk"
DEVICE=$(detect_disk)
log "$NAME: target disk is $DEVICE"

# ── pre-flight: target disk must not be in use ────────────────────────
# A running system's root or any mounted partition on the target disk
# means this is not the installer ISO — abort before any wipe.
# A failed query (connection error, old lsblk without MOUNTPOINTS)
# is treated as "in use" — the script must not proceed blind.

rc=0
MOUNTS=$(ssh_target lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null) || rc=$?
if [[ $rc -ne 0 ]]; then
  die "lsblk query failed (exit $rc) — refusing to proceed without confirming the disk is unused"
fi
if [[ -n "$MOUNTS" ]]; then
  die "$DEVICE has mounted partitions — refusing to wipe a live disk"
fi

rc=0
ROOT_SRC=$(ssh_target findmnt -no SOURCE / 2>/dev/null) || rc=$?
if [[ $rc -ne 0 ]]; then
  die "findmnt query failed (exit $rc) — refusing to proceed without confirming root is elsewhere"
fi
if [[ -n "$ROOT_SRC" ]]; then
  # Walk up the device hierarchy: LUKS roots report /dev/mapper/cryptroot
  # whose PKNAME is the partition (vda4), not the disk (vda).
  DISK_NAME=$(basename "$DEVICE")
  PARENT="$ROOT_SRC"
  while true; do
    PARENT=$(ssh_target lsblk -no PKNAME "$PARENT" 2>/dev/null) || break
    [[ -z "$PARENT" ]] && break
    if [[ "$PARENT" == "$DISK_NAME" ]]; then
      die "root is on $DEVICE — refusing to wipe the running system's disk"
    fi
  done
fi

if ! ssh_target "[ -f /etc/playnet-installer ]" 2>/dev/null; then
  die "/etc/playnet-installer not found on target — not the installer ISO"
fi

P1=$(partn "$DEVICE" 1)
P2=$(partn "$DEVICE" 2)
P3=$(partn "$DEVICE" 3)
P4=$(partn "$DEVICE" 4)

# Firmware detection: exit 1 means BIOS, exit 0 means UEFI, anything
# else (e.g. SSH failure = 255) is fatal — a wrong bootloader is unrecoverable.
fw_rc=0
ssh_target "[ -d /sys/firmware/efi ]" || fw_rc=$?
if [[ $fw_rc -eq 0 ]]; then
  FIRMWARE_FLAG="--uefi"
elif [[ $fw_rc -eq 1 ]]; then
  FIRMWARE_FLAG="--bios $DEVICE"
else
  die "firmware probe failed (exit $fw_rc) — cannot determine UEFI vs BIOS"
fi

# ── copy initrd host key to target ───────────────────────────────────
# The renderer bakes this path into the OS config.  It must exist on
# the target at guix-system-init time.

TARGET_KEY="/root/initrd-host-key"

scp_target "$CHILD_DIR/initrd-host-key" "root@$ADDRESS:$TARGET_KEY"
on_target chmod 0600 "$TARGET_KEY"
on_target "[ -f $TARGET_KEY ]" || die "initrd host key missing on target at $TARGET_KEY"

# ── dry render (catches config errors before the wipe) ───────────────

log "$NAME: dry render with dummy UUIDs"
render 00000000-0000-0000-0000-000000000000 \
       00000000-0000-0000-0000-000000000000 \
       0000-0000 \
       "$FIRMWARE_FLAG" \
       "$TARGET_KEY" \
       /dev/null

# ── partition ────────────────────────────────────────────────────────

log "$NAME: partitioning $DEVICE"

ssh_target sfdisk --quiet -W always "$DEVICE" <<SFDSK
label: gpt
unit: sectors

${P1} : size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name=bios
${P2} : size=512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=esp
${P3} : size=15GiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=store
${P4} : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=cryptroot
SFDSK

on_target udevadm settle

# ── format ───────────────────────────────────────────────────────────

log "$NAME: formatting $DEVICE"

on_target "tr -d '\n' < /dev/stdin | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- ${P4}" \
  < "$CHILD_DIR/luks-passphrase"

on_target "tr -d '\n' < /dev/stdin | cryptsetup open --type luks --key-file=- ${P4} cryptroot" \
  < "$CHILD_DIR/luks-passphrase"

on_target mkfs.ext4 -F -q /dev/mapper/cryptroot
on_target mkfs.ext4 -F -q "$P3"
on_target mkfs.vfat  -F32 "$P2"

# ── read UUIDs ───────────────────────────────────────────────────────

log "$NAME: reading partition UUIDs"

LUKS_UUID=$(on_target cryptsetup luksUUID "$P4")
STORE_UUID=$(on_target blkid -s UUID -o value "$P3")
ESP_UUID=$(on_target blkid -s UUID -o value "$P2")

log "$NAME: luks=$LUKS_UUID store=$STORE_UUID esp=$ESP_UUID"

# ── render child-os.scm (real UUIDs) ────────────────────────────────

log "$NAME: rendering child OS config"

render "$LUKS_UUID" "$STORE_UUID" "$ESP_UUID" "$FIRMWARE_FLAG" "$TARGET_KEY" "$WORK_DIR/child-os.scm"

# ── mount, cow-store, install ────────────────────────────────────────

log "$NAME: mounting target filesystems"

on_target mount /dev/mapper/cryptroot /mnt
on_target mkdir -p /mnt/gnu/store /mnt/boot
on_target mount "$P3" /mnt/gnu/store
on_target mount "$P2" /mnt/boot

log "$NAME: starting cow-store"
on_target herd start cow-store /mnt

log "$NAME: copying config and modules to target"

on_target mkdir -p /tmp/unlock-modules
scp_target "$WORK_DIR/child-os.scm" "root@$ADDRESS:/tmp/child-os.scm"
scp_target "$REPO/deploy/guix/remote-unlock.scm" "root@$ADDRESS:/tmp/unlock-modules/"

log "$NAME: running guix system init (this may take a while)"

on_target "guix system init -L /tmp/unlock-modules /tmp/child-os.scm /mnt --no-grafts"

# ── teardown and reboot ──────────────────────────────────────────────

log "$NAME: cleaning up and rebooting"

on_target rm -rf /tmp/child-os.scm /tmp/unlock-modules
on_target sync
on_target herd stop cow-store
on_target "umount -R /mnt"
on_target "cryptsetup close cryptroot"
ssh_target reboot || true

log "$NAME: install complete — target is rebooting toward its initrd"
exit 0
