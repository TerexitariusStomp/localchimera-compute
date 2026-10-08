#!/usr/bin/env bash
# deploy/scripts/backup-restore.sh — restore a state-*.tar.age snapshot.
#
# Idempotent + dry-run-by-default. Two phases:
#
#   1. --dry-run (default): decrypt to a temp dir, list every path that
#      would be replaced and what changed (mtime + size diff). No writes.
#
#   2. --apply: stop affected services, atomically rename current paths
#      to .pre-restore-<date>, untar new state, restart services.
#      On any error, roll forward to .pre-restore (no half-state).
#
# Usage:
#   bash deploy/scripts/backup-restore.sh state-2026-05-08T030000Z.tar.age
#   bash deploy/scripts/backup-restore.sh --apply latest.tar.age
#
# Decryption uses the same age-identity-file conventions as
# secrets-decrypt.sh (YubiKey preferred; file key fallback).

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YUBIKEY_IDENTITY="$DEPLOY_DIR/.age-yubikey-identity.txt"
FILE_KEY="$DEPLOY_DIR/.age-key.txt"

# Services that touch the at-risk paths; stop them before restore.
AFFECTED_SERVICES=(
    keria
    keri-witness-wan keri-witness-wil keri-witness-wes
    keri-witness-wit keri-witness-wub keri-witness-wyz
    fleet-reconciler
    tor
    playnet-gateway
)

LOG_PREFIX="[backup-restore]"
log() { echo "$LOG_PREFIX $*"; }
die() { log "FATAL: $*"; exit 1; }

# --- Args --------------------------------------------------------------

APPLY=0
BLOB=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --dry-run|-n) APPLY=0 ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        *) BLOB="$1" ;;
    esac
    shift
done

[ -n "$BLOB" ] || die "usage: $0 [--apply] <state-*.tar.age>"
[ -f "$BLOB" ] || die "blob not found: $BLOB"

# --- Identity ----------------------------------------------------------

if [ -f "$YUBIKEY_IDENTITY" ]; then
    IDENT="$YUBIKEY_IDENTITY"
    log "Using YubiKey identity (touch when prompted)"
elif [ -f "$FILE_KEY" ]; then
    IDENT="$FILE_KEY"
    log "Using file-key identity"
else
    die "no age identity at $YUBIKEY_IDENTITY or $FILE_KEY"
fi

# --- Stage --------------------------------------------------------------

STAGE="$(mktemp -d -t playnet-restore.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

log "Decrypting $BLOB → $STAGE/"
age -d -i "$IDENT" -o "$STAGE/state.tar.gz" "$BLOB"
mkdir -p "$STAGE/tree"
tar --extract \
    --gzip \
    --xattrs \
    --absolute-names=no \
    --directory "$STAGE/tree" \
    --file "$STAGE/state.tar.gz"

# --- Diff vs current ---------------------------------------------------

# tar with --absolute-names archived under ./var/lib/... so the staged
# tree mirrors the absolute paths. Walk the stage and report.

CHANGED=0
report_diff() {
    local rel="$1"
    local staged="$STAGE/tree/$rel"
    local live="/$rel"
    if [ ! -e "$live" ]; then
        log "  NEW       $live"
        CHANGED=$((CHANGED + 1))
    elif [ -f "$staged" ] && [ -f "$live" ]; then
        if ! cmp -s "$staged" "$live"; then
            local s_size=$(stat -c%s "$staged" 2>/dev/null || echo "?")
            local l_size=$(stat -c%s "$live" 2>/dev/null || echo "?")
            log "  CHANGED   $live  (live=${l_size}B  staged=${s_size}B)"
            CHANGED=$((CHANGED + 1))
        fi
    elif [ -d "$staged" ] && [ -d "$live" ]; then
        # Recurse for directories
        find "$staged" -type f | while read -r f; do
            sub_rel="${f#"$STAGE/tree/"}"
            report_diff "$sub_rel"
        done
        return
    fi
}

log "Diff vs current state:"
find "$STAGE/tree" -mindepth 1 -maxdepth 6 \( -type f -o -type d \) | while read -r f; do
    rel="${f#"$STAGE/tree/"}"
    report_diff "$rel"
done

if [ "$APPLY" -eq 0 ]; then
    log ""
    log "DRY RUN — no changes applied. Re-run with --apply to restore."
    exit 0
fi

# --- Apply --------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "--apply requires root (use sudo)"

STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
log "APPLY mode (rollback marker: .pre-restore-$STAMP)"

# Stop affected services. Continue past services that aren't running.
log "Stopping affected services"
for svc in "${AFFECTED_SERVICES[@]}"; do
    herd stop "$svc" 2>/dev/null || true
done

# Atomically rename live paths → .pre-restore-<stamp>; copy new in place.
log "Snapshotting current state to .pre-restore-$STAMP suffixes"
ROLLBACK_MAP="$(mktemp)"
trap 'rm -f "$ROLLBACK_MAP"; rm -rf "$STAGE"' EXIT

restore_failed() {
    log "FAILURE — rolling forward to .pre-restore-$STAMP"
    while IFS=$'\t' read -r live backup; do
        [ -e "$backup" ] && mv -T "$backup" "$live" || true
    done < "$ROLLBACK_MAP"
    log "Rolled back. Restarting services."
    for svc in "${AFFECTED_SERVICES[@]}"; do
        herd start "$svc" 2>/dev/null || true
    done
    exit 1
}
trap restore_failed ERR

find "$STAGE/tree" -mindepth 1 -maxdepth 1 | while read -r staged_top; do
    rel_top="${staged_top#"$STAGE/tree/"}"
    live_top="/$rel_top"
    # If live exists, snapshot it.
    if [ -e "$live_top" ]; then
        mv -T "$live_top" "$live_top.pre-restore-$STAMP"
        echo -e "$live_top\t$live_top.pre-restore-$STAMP" >> "$ROLLBACK_MAP"
    fi
    # Copy the staged tree in place, preserving ownership/perms.
    cp -a "$staged_top" "$live_top"
done

trap 'rm -f "$ROLLBACK_MAP"; rm -rf "$STAGE"' EXIT

log "Restored. Restarting services"
for svc in "${AFFECTED_SERVICES[@]}"; do
    herd start "$svc" 2>/dev/null || log "  (couldn't start $svc — investigate)"
done

log "Done. Old state preserved at *.pre-restore-$STAMP for inspection."
log "If everything looks right, clean up with:"
log "  sudo find /var -maxdepth 5 -name '*.pre-restore-$STAMP' -exec rm -rf {} +"
