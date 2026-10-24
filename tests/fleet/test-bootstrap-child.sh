#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tests/fleet/test-bootstrap-child.sh — the installer's remote conversation, as a transcript
#
# bootstrap-child.sh talks to its target only through ssh and scp. Here both
# (and the Tor prefix in front of them) are stubs that record each call and
# answer from canned values, so no disk is ever touched and what the script
# does, and in which order, is read off the transcript.
#
# What has to hold:
#
#   - every ssh and scp rides the prefix the keeper names
#   - nothing destructive runs before the target's tools have been checked
#     and a dry render has passed
#   - the initrd door's key reaches the target before `guix system init`,
#     at the path the rendered config names
#   - the passphrase travels on stdin only, never in an argument
#   - the target is synced, unmounted and closed before it reboots, and
#     the reboot is the last call
#   - a failed step stops the script before the next destructive one
#   - a firmware probe that could not reach the target is not read as BIOS
#
# Run:  bash tests/fleet/test-bootstrap-child.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${BOOTSTRAP_SCRIPT:-$REPO/deploy/scripts/bootstrap-child.sh}"
ROOT="$(mktemp -d)"
trap '[[ -n ${KEEP:-} ]] || rm -rf "$ROOT"' EXIT

pass=0; fail=0
check() {                       # check "label" command...
  local label="$1"; shift
  if "$@"; then pass=$((pass + 1)); printf '  ok: %s\n' "$label"
  else fail=$((fail + 1)); printf '  FAIL: %s\n' "$label"; fi
}

# ── fixtures ─────────────────────────────────────────────────────────────

PASSPHRASE="correct-horse-battery-staple-TESTONLY"
mkdir -p "$ROOT/bin" "$ROOT/child" "$ROOT/data"
printf '%s\n' "$PASSPHRASE" > "$ROOT/child/luks-passphrase"
ssh-keygen -q -t ed25519 -N '' -C initrd-test -f "$ROOT/child/initrd-host-key"
ssh-keygen -q -t ed25519 -N '' -C parent-test -f "$ROOT/identity"

cat > "$ROOT/bin/torsocks" <<'EOF'
#!/usr/bin/env bash
export TOR_STUB=1
exec "$@"
EOF

cat > "$ROOT/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Records the remote command; answers the questions the script asks.
cmd=(); seen=0
for a in "$@"; do
  if [[ $seen -eq 1 ]]; then cmd+=("$a"); elif [[ $a == root@* ]]; then seen=1; fi
done
line="${cmd[*]}"; line="${line//$'\n'/ }"
printf '%s\t%s\n' "${TOR_STUB:-direct}" "ssh $line" >> "$LOG/calls"
if [[ -n ${FAIL_ON:-} && $line == *"$FAIL_ON"* ]]; then exit 1; fi
if [[ ${FAIL_SAFETY:-} == 1 && ($line == *"lsblk"* || $line == *"findmnt"*) ]]; then exit 255; fi
case "$line" in
  "lsblk "*"-no MOUNTPOINTS"*)  printf '%b' "${MOUNTED_PARTITIONS:-}" ;;
  "lsblk "*"-no PKNAME"*)
    if [[ -n ${PKNAME_FIRST:-} ]]; then
      COUNTER_FILE="$LOG/lsblk-pkname-count"
      N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
      echo $((N + 1)) > "$COUNTER_FILE"
      if [[ $N -eq 0 ]]; then printf '%b' "${PKNAME_FIRST}\n"
      else printf '%b' "${PKNAME_SECOND:-}\n"; fi
    else
      dev="${line##*PKNAME }"; dev="${dev##*/}"
      parent="${dev%%[0-9]*}"
      if [[ -n "$parent" && "$parent" != "$dev" ]]; then printf '%b' "$parent\n"
      else printf '\n'; fi
    fi ;;
  lsblk*)            printf '%b' "${DISKS:-vda disk\nsr0 rom\n}" ;;
  "findmnt "*"-no SOURCE /")     printf '%b' "${ROOT_SOURCE:-/dev/sdb1}\n" ;;
  "[ -f /etc/localchimera-installer ]") exit "${MARKER:-0}" ;;
  "[ -d /sys/firmware/efi ]") exit "${EFI_RC:-0}" ;;
  "cryptsetup luksUUID"*)     echo "11111111-1111-1111-1111-111111111111" ;;
  "blkid"*"3")       echo "33333333-3333-3333-3333-333333333333" ;;
  "blkid"*"2")       echo "1234-ABCD" ;;
  sfdisk*)           cat > "$LOG/sfdisk-stdin" ;;
  *luksFormat*)      cat > "$LOG/luks-stdin" ;;
  *"cryptsetup open"*) cat > /dev/null ;;
esac
exit 0
EOF

cat > "$ROOT/bin/scp" <<'EOF'
#!/usr/bin/env bash
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in -o|-i|-P) shift 2 ;; -*) shift ;; *) files+=("$1"); shift ;; esac
done
src="${files[0]}"; dst="${files[1]}"
printf '%s\t%s\n' "${TOR_STUB:-direct}" "scp $src -> $dst" >> "$LOG/calls"
mkdir -p "$LOG/scp"; cp "$src" "$LOG/scp/$(basename "$dst")-$(basename "$src")"
exit 0
EOF
chmod +x "$ROOT/bin/"*

# A run: prints nothing, leaves $LOG/{calls,stderr,exit}.
run() {
  LOG="$ROOT/log-$1"; shift
  rm -rf "$LOG"; mkdir -p "$LOG"
  ( export LOG PATH="$ROOT/bin:$PATH" \
           LOCALCHIMERA_KEEPER_SSH_PREFIX=torsocks LOCALCHIMERA_DATA_DIR="$ROOT/data" \
           LOCALCHIMERA_PREFIX=24 LOCALCHIMERA_GATEWAY=203.0.113.1 "$@"
    bash "$SCRIPT" web-1 203.0.113.7 "$ROOT/child" "$ROOT/identity" \
      > "$LOG/stdout" 2> "$LOG/stderr"
    echo $? > "$LOG/exit" )
}
calls()   { cut -f2 "$1/calls"; }
lineno()  { calls "$1" | grep -n -m1 -- "$2" | cut -d: -f1; }   # first line matching
has()     { calls "$1" | grep -q -- "$2"; }
before()  { local a b; a=$(lineno "$1" "$2"); b=$(lineno "$1" "$3"); [[ -n $a && -n $b && $a -lt $b ]]; }
exit_of() { cat "$1/exit"; }

# ── a whole run ──────────────────────────────────────────────────────────

echo "a whole run"
run ok
L="$ROOT/log-ok"
check "it exits 0"                                   test "$(exit_of "$L")" = 0
check "every ssh and scp rode the prefix"            test "$(cut -f1 "$L/calls" | sort -u)" = "1"
check "the target's tools were checked before the disk was cut" before "$L" "command -v" "ssh sfdisk"
check "the disk is cut before it is formatted"       before "$L" "ssh sfdisk" "luksFormat"
check "the LUKS volume is formatted before the filesystems" before "$L" "luksFormat" "mkfs.ext4 -F"
check "the store is mounted after the root"          before "$L" "mount /dev/mapper/cryptroot /mnt" "mount /dev/vda3"
check "cow-store starts after the mounts"            before "$L" "mount /dev/vda2" "herd start cow-store"
check "the install runs after cow-store"             before "$L" "herd start cow-store" "guix system init"
check "the target is synced after the install"       before "$L" "guix system init" "sync"
check "cow-store stops before the unmount"           before "$L" "herd stop cow-store" "umount -R /mnt"
check "the unmount comes before the volume closes"   before "$L" "umount -R /mnt" "cryptsetup close cryptroot"
check "the volume closes before the reboot"          before "$L" "cryptsetup close cryptroot" "reboot"
check "the reboot is the last call" test "$(calls "$L" | tail -1)" = "ssh reboot"
check "the passphrase is on stdin, newline stripped remotely" \
      bash -c "grep -q \"tr -d '\\\\\\\\n'\" <(cut -f2 '$L/calls') && [ \"\$(cat '$L/luks-stdin')\" = '$PASSPHRASE' ]"
check "the passphrase is in no argument" bash -c "! grep -q '$PASSPHRASE' '$L/calls' '$L/stderr'"
check "partitions are named by device: /dev/vda4 holds the LUKS volume" has "$L" "cryptsetup luksFormat --type luks2 --batch-mode --key-file=- /dev/vda4"
check "the partition table names three sizes and leaves the last open" \
      bash -c "grep -q 'size=1MiB' '$L/sfdisk-stdin' && grep -q 'size=512MiB' '$L/sfdisk-stdin' && grep -q 'size=15GiB' '$L/sfdisk-stdin' && grep 'cryptroot' '$L/sfdisk-stdin' | grep -vq 'size='"

# ── the initrd door's key ────────────────────────────────────────────────

echo "the initrd door's key"
KEYDEST=$(grep -a "initrd-host-key" "$L/calls" | grep '^.*scp .*initrd-host-key.* -> root@' | sed 's/.* -> root@[^:]*://' | head -1)
CFG=$(ls "$L"/scp/*child-os.scm 2>/dev/null | head -1)
CFGPATH=$( [ -n "$CFG" ] && sed -n 's/.*(local-file "\([^"]*\)".*/\1/p' "$CFG" | head -1 )
check "the key is copied to the target"              test -n "$KEYDEST"
check "the key is copied before guix system init"    before "$L" "initrd-host-key" "guix system init"
check "the rendered config names the path the key was copied to" \
      test -n "$KEYDEST" -a "$KEYDEST" = "$CFGPATH"

# ── a target missing a tool ──────────────────────────────────────────────

echo "a target that lacks a tool"
run tool FAIL_ON="command -v"
L="$ROOT/log-tool"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

# ── a failing partition step ─────────────────────────────────────────────

echo "a partitioning that fails"
run cut FAIL_ON="sfdisk"
L="$ROOT/log-cut"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "no format follows" bash -c "! grep -Eq 'luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

echo "an install that fails"
run init FAIL_ON="guix system init"
L="$ROOT/log-init"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "the target is not rebooted" bash -c "! grep -q 'reboot' '$L/calls'"

# ── two disks ────────────────────────────────────────────────────────────

echo "two disks"
run two DISKS='vda disk\nvdb disk\n'
L="$ROOT/log-two"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

# ── safety: target disk is in use ────────────────────────────────────────

echo "root is on the target disk"
run rooted ROOT_SOURCE=/dev/vda2
L="$ROOT/log-rooted"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

echo "a LUKS root lives on the target disk"
run luks ROOT_SOURCE=/dev/mapper/cryptroot PKNAME_FIRST=vda4 PKNAME_SECOND=vda
L="$ROOT/log-luks"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

echo "a partition on the target disk is mounted"
run mounted MOUNTED_PARTITIONS='/boot/efi\n'
L="$ROOT/log-mounted"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

echo "the installer marker is missing"
run no-marker MARKER=1
L="$ROOT/log-no-marker"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

echo "a safety query that cannot reach the target"
run blind FAIL_SAFETY=1
L="$ROOT/log-blind"
check "the run fails"                                test "$(exit_of "$L")" != 0
check "nothing destructive ran" bash -c "! grep -Eq 'ssh sfdisk|luksFormat|mkfs.ext4 -F|mkfs.vfat -F32' '$L/calls'"

# ── firmware ─────────────────────────────────────────────────────────────

echo "firmware"
run bios EFI_RC=1
check "a target without /sys/firmware/efi gets the BIOS bootloader" \
      bash -c "grep -q 'grub-bootloader' '$ROOT'/log-bios/scp/*child-os.scm*"
run dark EFI_RC=255
check "a probe that could not reach the target is not read as BIOS" \
      bash -c "! ls '$ROOT'/log-dark/scp/*child-os.scm* >/dev/null 2>&1 || ! grep -q 'grub-bootloader' '$ROOT'/log-dark/scp/*child-os.scm*"

echo
echo "=== Results: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
