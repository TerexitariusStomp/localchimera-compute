#!/usr/bin/env bash
# deploy/server-1/install.sh — idempotent installer for server-1 services
#
# Modes:
#   --full       (default) seed everything: state dirs, profiles, witness
#                keystores, systemd user unit, daemon-reload, enable+start
#   --pre-start  fast path invoked by shepherd.service ExecStartPre: only
#                ensures dirs and profiles exist; skips systemd plumbing
#
# Always safe to re-run. No destructive operations.

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  --pre-start|--full|"") ;;
  *) echo "usage: $0 [--full|--pre-start]" >&2; exit 1 ;;
esac

REPO="${PLAYNET_REPO:-$HOME/playnet}"
STATE="$HOME/.local/state/playnet"
GUIX="$HOME/.config/guix/current/bin/guix"
[ -x "$GUIX" ] || GUIX="$(command -v guix)"

mkdir -p \
  "$STATE/log" \
  "$STATE/keria/config" \
  "$STATE/keria/ks" \
  "$STATE/witnesses" \
  "$STATE/gateway" \
  "$STATE/profiles"

# Drop KERIA config into place. We copy from the repo's deploy/keria-config.json
# (same file the Guix-System deploy uses).
if [ -f "$REPO/deploy/keria-config.json" ]; then
  cp -u "$REPO/deploy/keria-config.json" "$STATE/keria/config/keria.json"
fi

# ── Warm Guix shell caches ──────────────────────────────────────────────
# We don't materialize merged profiles via `guix package -p`: the keri
# manifest has python-keri + python-keria, which propagate conflicting
# python-marshmallow versions (4.0 vs 3.26). `guix shell` resolves the
# conflict at union time (last-write wins inside the transient profile
# tree) but `guix package` is strict and errors out.
#
# Trade-off: each service start re-invokes `guix shell -m ...`, which on
# a warm machine resolves in well under a second. install.sh just primes
# the substitute cache so the first start isn't slow.

KERI_MANIFEST="$REPO/deploy/manifests/keri-test-manifest.scm"
GATEWAY_MANIFEST="$REPO/deploy/server-1/gateway-manifest.scm"
LOAD_PATH="$REPO/deploy/guix"

warm() {
  local manifest="$1"
  echo "==> Warming: $manifest"
  "$GUIX" shell -L "$LOAD_PATH" -m "$manifest" -- true
}
warm "$KERI_MANIFEST"
warm "$GATEWAY_MANIFEST"

# ── Per-witness keystore + AID inception ────────────────────────────────
# Mirrors the activation step in deploy/guix/keria-service.scm: each
# witness gets its own keystore (kli init) and an AID with alias = name
# (kli incept). Salts persist at $STATE/witnesses/<name>/salt.txt (0600).
# Both steps are gated by file/dir markers so re-runs are no-ops — salts
# never re-roll, AIDs stay stable across restarts.

WITNESSES=(wan wil wes wit wub wyz)

kli_in_shell() {
  HOME="$STATE/keria" "$GUIX" shell -L "$LOAD_PATH" -m "$KERI_MANIFEST" -- kli "$@"
}

for name in "${WITNESSES[@]}"; do
  wdir="$STATE/witnesses/$name"
  salt_file="$wdir/salt.txt"
  ks_marker="$STATE/keria/.keri/ks/$name"
  db_marker="$STATE/keria/.keri/db/$name"   # kli incept creates the AID db
  mkdir -p "$wdir"

  if [ ! -f "$salt_file" ]; then
    kli_in_shell salt > "$salt_file"
    chmod 600 "$salt_file"
  fi

  if [ ! -d "$ks_marker" ]; then
    salt="$(cat "$salt_file")"
    kli_in_shell init \
      --name "$name" \
      --nopasscode \
      --salt "$salt" \
      --config-dir "$STATE/keria" \
      >/dev/null
  fi

  # kli incept creates the witness's AID inside the keystore with
  # alias=name. `kli witness start --alias` looks this up; without
  # incept the start would error "alias not found".
  # Non-transferable, single-sig, no witnesses-of-witness.
  if [ ! -d "$db_marker" ]; then
    kli_in_shell incept \
      --name  "$name" \
      --alias "$name" \
      --icount 1 --isith 1 \
      --ncount 1 --nsith 1 \
      --toad   0 \
      >/dev/null
  fi
done

if [ "$MODE" = "--pre-start" ]; then
  exit 0
fi

# ── systemd user unit ───────────────────────────────────────────────────
SYSTEMD_USER="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER"
ln -sf "$REPO/deploy/server-1/shepherd.service" "$SYSTEMD_USER/shepherd.service"

# Runtime dir for the shepherd socket (XDG_RUNTIME_DIR/shepherd/).
mkdir -p "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/shepherd"

systemctl --user daemon-reload
systemctl --user enable shepherd.service
systemctl --user restart shepherd.service

echo
echo "==> Status:"
systemctl --user status shepherd.service --no-pager -n 5 || true
echo
echo "Logs: journalctl --user -u shepherd -f"
echo "Herd: $HOME/.guix-profile/bin/herd status \\"
echo "        -s \${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/shepherd/socket"
