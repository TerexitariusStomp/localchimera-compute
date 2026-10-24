#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# deploy/scripts/backup-state.sh — snapshot the at-risk persistent state
# into a single age-encrypted tarball, write it to the local rolling
# window, and (optionally) push to a sister Radicle peer.
#
# Run by the localchimera-backup mcron job (daily at 03:00) or manually:
#   sudo herd start localchimera-backup
#   sudo /run/current-system/profile/bin/localchimera-backup [--dry-run]
#
# Closes the three audit gaps with one mechanism:
#   - KERIA witness keystores  (HIGH)
#   - Tor onion private key    (MEDIUM)
#   - SporeStack token         (LOW)
#
# Plus everything else under /var/lib/localchimera/ that survives reboot
# (vat snapshots, sturdyrefs, designator key) so a single restore puts
# the box back exactly where it was.

set -euo pipefail

# The mcron/shepherd service that runs this daily has a MINIMAL PATH — it
# lacks coreutils (date, tar, gzip) and age, so every run died at line 1 with
# "date: command not found" and never produced a backup (root-caused
# 2026-07-28: /var/lib/localchimera/backups did not even exist — the box had NO
# off-box copy of anything). Pin the system profile so the tools resolve
# regardless of the caller's environment.
export PATH="/run/current-system/profile/bin:/run/current-system/profile/sbin:${PATH:-}"

: "${LOCALCHIMERA_DATA_DIR:=/var/lib/localchimera}"
: "${LOCALCHIMERA_BACKUP_DIR:=$LOCALCHIMERA_DATA_DIR/backups}"
: "${LOCALCHIMERA_BACKUP_KEEP:=30}"
: "${LOCALCHIMERA_BACKUP_REPO_DIR:=$LOCALCHIMERA_DATA_DIR/backup-repo}"
: "${LOCALCHIMERA_REPO_DIR:=/home/localchimera/localchimera-repo}"

# age recipient discovery — same precedence as secrets-encrypt.sh:
#   1. YubiKey identity (preferred): public file, safe to commit
#   2. File-key fallback: software age key (gitignored; back up alongside
#      the Monero seed). For setups without a YubiKey.
# Override either path with LOCALCHIMERA_RECIPIENT_FILE / LOCALCHIMERA_FILE_KEY env.
YUBIKEY_IDENTITY="${LOCALCHIMERA_RECIPIENT_FILE:-$LOCALCHIMERA_REPO_DIR/deploy/.age-yubikey-identity.txt}"
# The operator keeps the age key in repo/deploy/ on their laptop, but on the
# box that path is gitignored/absent — the deployed key lives at
# $LOCALCHIMERA_DATA_DIR/.age-key.txt. The service set neither LOCALCHIMERA_FILE_KEY nor
# the repo key, so recipient discovery failed with "no age recipient" every
# run. Check both locations so the box key is found with no service-env change.
FILE_KEY="${LOCALCHIMERA_FILE_KEY:-}"
if [ -z "$FILE_KEY" ]; then
    for _cand in "$LOCALCHIMERA_REPO_DIR/deploy/.age-key.txt" \
                 "$LOCALCHIMERA_DATA_DIR/.age-key.txt"; do
        [ -f "$_cand" ] && { FILE_KEY="$_cand"; break; }
    done
fi

DRY_RUN=0
case "${1:-}" in
    --dry-run|-n) DRY_RUN=1 ;;
    --help|-h)
        sed -n '2,18p' "$0" | sed 's|^# \{0,1\}||'
        exit 0
        ;;
esac

LOG_PREFIX="[localchimera-backup]"
log() { echo "$LOG_PREFIX $(date -Iseconds) $*"; }
die() { log "FATAL: $*"; exit 1; }

# --- Paths to snapshot --------------------------------------------------

# Globs are expanded here; missing paths are silently skipped (any one
# of these may be absent on a fresh deploy that hasn't booted some
# service yet).
PATHS=(
    "$LOCALCHIMERA_DATA_DIR/keria/witnesses"
    "$LOCALCHIMERA_DATA_DIR/keria/ks"
    "$LOCALCHIMERA_DATA_DIR/keria/config"
    "/var/lib/tor/hidden-services/localchimera"
    "$LOCALCHIMERA_DATA_DIR/sporestack-token.txt"
    "$LOCALCHIMERA_DATA_DIR/wallet-sref.txt"
    "$LOCALCHIMERA_DATA_DIR/reconciler-sref.txt"
    "$LOCALCHIMERA_DATA_DIR/fleet-reconciler.syrup"
    "$LOCALCHIMERA_DATA_DIR/designator-key.scm"
    # Durable-dir credential/entry stores (#:durable-dir write-through):
    #   acdc/      — the governance ACDC graph: personhood (PHCs),
    #                delegations, stances, work/skill attestations, custody.
    #                Survives a gateway RESTART on disk; this puts it off-box
    #                too, so it also survives losing the box.
    #   oobi-host/ — published KELs / OOBIs served at /oobi/{aid}.
    "$LOCALCHIMERA_DATA_DIR/acdc"
    "$LOCALCHIMERA_DATA_DIR/oobi-host"
    # Web-push VAPID signing key — lose it and every push subscription breaks.
    "$LOCALCHIMERA_DATA_DIR/vapid-key.scm"
    # The communes' own durable state (LOCALCHIMERA_SCOPES_DURABLE): each scope's
    # KEL, its ACDC store and its vault, under the gateway's state root. The
    # gateway runs with HOME=$LOCALCHIMERA_DATA_DIR, so the root is the XDG default
    # below it unless LOCALCHIMERA_STATE_DIR names another. A member's seat is a
    # row in a scope; the scope's identity is what a restored box seats them in.
    "${LOCALCHIMERA_STATE_DIR:-$LOCALCHIMERA_DATA_DIR/.local/state/localchimera}"
    # Which AIDs the founding and universal communes are: boot keys the
    # restored roster by them.
    "$LOCALCHIMERA_DATA_DIR/founding-commune-aid.txt"
    "$LOCALCHIMERA_DATA_DIR/universal-commune-aid.txt"
    "$LOCALCHIMERA_DATA_DIR/founders.txt"
    "$LOCALCHIMERA_DATA_DIR/pending-grants.scm"
    "$LOCALCHIMERA_DATA_DIR/recipients.scm"
    "$LOCALCHIMERA_DATA_DIR/federation.scm"
    # Sealed contact cards a person gave another (ciphertext, kept for them).
    "$LOCALCHIMERA_DATA_DIR/cards"
)

# Plus any *.syrup at the root (Goblins persistence stores).
shopt -s nullglob
PATHS+=("$LOCALCHIMERA_DATA_DIR"/*.syrup)
# Plus per-AID user files (server-side mirror of contacts / credentials /
# taxonomy — local-first, but the box copy is a user's backup + new-device
# transfer, so it belongs off-box too).
PATHS+=("$LOCALCHIMERA_DATA_DIR"/contacts-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/credentials-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/taxonomy-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/devices-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/log-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/pins-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/allotment-*.scm \
        "$LOCALCHIMERA_DATA_DIR"/venue-*.scm)
shopt -u nullglob

# Filter to existing paths.
EXISTING=()
for p in "${PATHS[@]}"; do
    [ -e "$p" ] && EXISTING+=("$p")
done

if [ "${#EXISTING[@]}" -eq 0 ]; then
    die "no paths to back up under $LOCALCHIMERA_DATA_DIR — wrong host?"
fi

# --- Recipient discovery ------------------------------------------------

RECIPIENT=""
RECIPIENT_SOURCE=""
if [ -f "$YUBIKEY_IDENTITY" ]; then
    RECIPIENT="$(grep -E '^age1' "$YUBIKEY_IDENTITY" | head -1)"
    RECIPIENT_SOURCE="YubiKey identity"
elif [ -f "$FILE_KEY" ]; then
    # Derive the public recipient from the private file key.
    RECIPIENT="$(age-keygen -y "$FILE_KEY" 2>/dev/null | head -1)"
    RECIPIENT_SOURCE="file key (no YubiKey)"
fi

if [ -z "$RECIPIENT" ]; then
    die "no age recipient found.
  Looked at:
    YubiKey:  $YUBIKEY_IDENTITY
    File key: $FILE_KEY
  Set up one of:
    age-plugin-yubikey --generate > $YUBIKEY_IDENTITY  # commit (safe)
    age-keygen -o $FILE_KEY                            # do NOT commit"
fi

# --- Output paths -------------------------------------------------------

DATE="$(date -u +%Y-%m-%dT%H%M%SZ)"
OUT="$LOCALCHIMERA_BACKUP_DIR/state-$DATE.tar.age"
LATEST="$LOCALCHIMERA_BACKUP_DIR/latest.tar.age"

# --- Dry run: just report ----------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN — would write: $OUT"
    log "DRY RUN — recipient:  ${RECIPIENT:0:30}…  ($RECIPIENT_SOURCE)"
    log "DRY RUN — paths:"
    for p in "${EXISTING[@]}"; do
        size=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
        printf '%s   %-50s %s\n' "$LOG_PREFIX" "$p" "$size"
    done
    exit 0
fi

# --- Snapshot ----------------------------------------------------------

mkdir -p "$LOCALCHIMERA_BACKUP_DIR"
chmod 700 "$LOCALCHIMERA_BACKUP_DIR"

log "Tarring ${#EXISTING[@]} paths → $OUT"
# tar with --xattrs --acls preserves owner/perms; --sparse for syrup
# stores. -C / so paths are absolute-relative (./var/lib/...).
tar --create \
    --gzip \
    --xattrs \
    --sparse \
    --absolute-names \
    --warning=no-file-changed \
    --file - \
    -- "${EXISTING[@]}" \
    | age -e -r "$RECIPIENT" -o "$OUT"

chmod 600 "$OUT"
ln -sfn "state-$DATE.tar.age" "$LATEST"

SIZE=$(du -h "$OUT" | awk '{print $1}')
SHA=$(sha256sum "$OUT" | awk '{print substr($1,1,12)}')
log "Wrote $OUT ($SIZE, sha256=$SHA…)"

# --- Prune local rolling window ----------------------------------------

# Newest first, skip the symlink + the most recent N snapshots, delete
# the rest. ARTIFACTS_KEEP defaults to 30 (one-month rolling window).
ls -1t "$LOCALCHIMERA_BACKUP_DIR"/state-*.tar.age 2>/dev/null \
    | tail -n +"$((LOCALCHIMERA_BACKUP_KEEP + 1))" \
    | xargs -r rm -f
log "Pruned to $LOCALCHIMERA_BACKUP_KEEP most recent snapshots"

# --- Sister-peer push (optional) ---------------------------------------

# If LOCALCHIMERA_BACKUP_RID is set, commit the new blob to a sister Radicle
# project and push. The sister peer (running anywhere) gets the blob via
# gossip — defense in depth against host seizure.
#
# Failure here is logged but doesn't fail the job: the local snapshot is
# still recoverable.

if [ -n "${LOCALCHIMERA_BACKUP_RID:-}" ]; then
    log "Sister-peer push enabled (RID=$LOCALCHIMERA_BACKUP_RID)"
    (
        set -e
        if [ ! -d "$LOCALCHIMERA_BACKUP_REPO_DIR/.git" ]; then
            log "Cloning sister Radicle repo to $LOCALCHIMERA_BACKUP_REPO_DIR"
            mkdir -p "$(dirname "$LOCALCHIMERA_BACKUP_REPO_DIR")"
            rad clone "$LOCALCHIMERA_BACKUP_RID" \
                --no-confirm 2>&1 \
                | sed "s|^|$LOG_PREFIX rad: |" || true
            # rad clone names the dir after the project; locate it.
            cloned="$(find "$(dirname "$LOCALCHIMERA_BACKUP_REPO_DIR")" -maxdepth 1 -type d -name '*backup*' | head -1)"
            [ -n "$cloned" ] && [ "$cloned" != "$LOCALCHIMERA_BACKUP_REPO_DIR" ] \
                && mv "$cloned" "$LOCALCHIMERA_BACKUP_REPO_DIR"
        fi

        cd "$LOCALCHIMERA_BACKUP_REPO_DIR"
        cp "$OUT" "./state-$DATE.tar.age"
        # Symlink latest inside the repo too.
        ln -sfn "state-$DATE.tar.age" "./latest.tar.age"

        # Same pruning as local — keep the repo from growing unbounded.
        ls -1t state-*.tar.age 2>/dev/null \
            | tail -n +"$((LOCALCHIMERA_BACKUP_KEEP + 1))" \
            | xargs -r git rm -f -q 2>/dev/null || true
        ls -1t state-*.tar.age 2>/dev/null \
            | tail -n +"$((LOCALCHIMERA_BACKUP_KEEP + 1))" \
            | xargs -r rm -f

        git add "state-$DATE.tar.age" latest.tar.age
        git -c user.name='localchimera-backup' \
            -c user.email='backup@localchimera' \
            commit -q -m "backup: state-$DATE sha=$SHA"
        git push -q rad main 2>&1 \
            | sed "s|^|$LOG_PREFIX rad-push: |"
        log "Sister-peer push OK"
    ) || log "WARNING: sister-peer push failed — local snapshot still good"
else
    log "Sister-peer push skipped (LOCALCHIMERA_BACKUP_RID not set)"
fi

log "Done"
