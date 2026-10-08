#!/usr/bin/env bash
# playnet-sync — push this delegate's Radicle repo state to the canonical
# seed(s) over Tor. Generic: reads the seed list from deploy/radicle-seeds.txt,
# so it works for ANY delegate on ANY machine (no hardcoded host, no flashdrive).
#
# Prereqs (one-time): run tools/radicle-delegate-setup.sh, and have Tor's SOCKS
# proxy on 127.0.0.1:9050. Usage: tools/playnet-sync.sh
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The real seed list is gitignored (production onion) — obtained out-of-band.
SEEDS_FILE="$REPO_ROOT/deploy/radicle-seeds.local.txt"
# `rad .` resolves the RID from cwd, not $REPO_ROOT — when this runs from
# systemd (WorkingDirectory defaults to $HOME, not a Radicle repo), `rad .`
# prints its error to stdout rather than stderr, so `2>/dev/null || echo
# fallback` doesn't catch it and $RID ends up holding the error text
# concatenated with the fallback RID. `cd` into the repo first and fall back
# on an EMPTY result instead of trusting the exit code.
RID="$(cd "$REPO_ROOT" && rad . 2>/dev/null)"
[ -n "$RID" ] || RID="rad:z27dFkN28LQAsSsG3DVHcfBqYAArQ"

if [ ! -f "$SEEDS_FILE" ]; then
  echo "Missing $SEEDS_FILE" >&2
  echo "Copy deploy/radicle-seeds.local.txt.example to it and fill in the real seed" >&2
  echo "(obtain it out-of-band — it is intentionally not in this public repo)." >&2
  exit 1
fi

# Connect to every configured seed (idempotent; ignores already-connected).
while read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comments/space
  [ -z "$line" ] && continue
  echo "→ connecting to ${line%@*}…"
  rad node connect "$line" >/dev/null 2>&1 || true
done < "$SEEDS_FILE"

sleep 2
echo "→ announcing $RID…"
rad sync --announce "$RID" --timeout 120sec

echo "→ status:"
rad sync status "$RID" 2>/dev/null | grep -E '\(you\)|✓' | head -20
