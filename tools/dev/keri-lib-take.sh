#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# keri-lib-take.sh — carry a contributor's commits from localchimera-keri into the core.
#
# The KERI + OpenVTC library is developed in the core and cut out as
# localchimera-keri (tools/dev/publish-keri-lib.sh). A contributor works in the cut and
# opens a Radicle patch there. This brings that work home: the cut keeps the
# core's paths, so each commit applies as it stands, author and date intact,
# and the next `make keri-lib-publish` carries it back out.
#
#   cd ../localchimera-keri && rad patch checkout <patch-id>      # → branch patch/<id>
#   tools/dev/keri-lib-take.sh main..patch/<id>
#
# What it holds to:
#   - every path the commits touch is the library's own (the published path
#     set, or a new file under its directories); anything else is refused —
#     a patch to localchimera-keri has no say over the rest of the core
#   - the cut's README.md is the core's module/localchimera/keri/README.md, and its
#     guix/gnu/packages/localchimera-keri.scm the core's deploy/guix/gnu/packages/localchimera-keri.scm; the channel
#     files (.guix-channel, .guix-authorizations) belong to the maintainers and
#     are refused like any path outside the library
#   - the commits are proven first in a scratch worktree at the core's HEAD:
#     applied, the import gate run, every shipped suite run in the library's
#     pure Guix shell; the core's own tree is touched only after that passes
#
# Usage:  tools/dev/keri-lib-take.sh <rev-range in the localchimera-keri clone>
# Env:    LOCALCHIMERA_KERI_DIR   the clone (default ../localchimera-keri)
#         KERI_TAKE_SKIP_TESTS=1   gate only (the suites take a few minutes)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KERI="${LOCALCHIMERA_KERI_DIR:-$ROOT/../localchimera-keri}"
RANGE="${1:?usage: keri-lib-take.sh <rev-range in the localchimera-keri clone, e.g. main..patch/abc123>}"

[ -d "$KERI/.git" ] || { echo "[take] no localchimera-keri clone at $KERI"; exit 1; }
N=$(git -C "$KERI" rev-list --count --no-merges "$RANGE")
[ "$N" -gt 0 ] || { echo "[take] $RANGE names no commits"; exit 1; }
echo "[take] $N commit(s) in $RANGE"
git -C "$KERI" log --no-merges --reverse --format='         %h %an — %s' "$RANGE"

# ── the library's own paths ──────────────────────────────────────────────────
mapfile -t OWN < <(cd "$ROOT" && guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm --manifest)
OWN_DIRS=(module/localchimera/keri/ tests/keri/ docs/keri/ docs/first-person/)
OWN_FILES=(README.md guix/gnu/packages/localchimera-keri.scm docs/planning/identity/openvtc-parity.md docs/planning/identity/keri-openvtc-library-split.md
           tools/lint/openvtc-parity-check.sh tools/lint/lint-keri-lib.scm deploy/manifests/keri-lib-manifest.scm)

owned() {
  local f="$1" p
  for p in "${OWN[@]}" "${OWN_FILES[@]}"; do [ "$f" = "$p" ] && return 0; done
  for p in "${OWN_DIRS[@]}"; do case "$f" in "$p"*) return 0;; esac; done
  return 1
}
bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  owned "$f" || { echo "[take] outside the library: $f"; bad=1; }
done < <(git -C "$KERI" log --no-merges --name-only --format= "$RANGE" | sort -u)
[ "$bad" = 0 ] || { echo "[take] refused — the commits reach past the library's paths"; exit 1; }

# ── the commits as a mailbox, README mapped to its path in the core ─────────
WORK="$(mktemp -d)"
cleanup() { git -C "$ROOT" worktree remove --force "$WORK/proof" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$KERI" format-patch --quiet --no-merges --stdout "$RANGE" \
  | sed -E \
      -e 's#^(diff --git) a/README\.md b/README\.md$#\1 a/module/localchimera/keri/README.md b/module/localchimera/keri/README.md#' \
      -e 's#^(---) a/README\.md$#\1 a/module/localchimera/keri/README.md#' \
      -e 's#^(\+\+\+) b/README\.md$#\1 b/module/localchimera/keri/README.md#' \
      -e 's#^(diff --git) a/guix/gnu/packages/localchimera-keri\.scm b/guix/gnu/packages/localchimera-keri\.scm$#\1 a/deploy/guix/gnu/packages/localchimera-keri.scm b/deploy/guix/gnu/packages/localchimera-keri.scm#' \
      -e 's#^(---) a/guix/gnu/packages/localchimera-keri\.scm$#\1 a/deploy/guix/gnu/packages/localchimera-keri.scm#' \
      -e 's#^(\+\+\+) b/guix/gnu/packages/localchimera-keri\.scm$#\1 b/deploy/guix/gnu/packages/localchimera-keri.scm#' \
  > "$WORK/take.mbox"

# ── prove it away from the core's own tree ──────────────────────────────────
echo "[take] proving in a scratch worktree at $(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$ROOT" worktree add --quiet --detach "$WORK/proof" HEAD
if ! git -C "$WORK/proof" -c commit.gpgsign=false am --quiet --3way "$WORK/take.mbox"; then
  git -C "$WORK/proof" am --abort >/dev/null 2>&1 || true
  echo "[take] the commits do not apply to the core's HEAD — the contributor rebases onto the current cut"
  exit 1
fi
( cd "$WORK/proof" && guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm )
if [ -z "${KERI_TAKE_SKIP_TESTS:-}" ]; then
  rc=0; ( cd "$WORK/proof" && make -s test-keri-lib ) > "$WORK/suites.log" 2>&1 || rc=$?
  grep -E '^(ok|FAIL) ' "$WORK/suites.log" | sed 's/^/         /' || true
  [ "$rc" = 0 ] || { echo "[take] a shipped suite fails with these commits"; exit 1; }
fi

# ── and then for real ───────────────────────────────────────────────────────
if ! git -C "$ROOT" diff --cached --quiet; then
  echo "[take] the core's index holds staged changes — commit or unstage them first"; exit 1
fi
git -C "$ROOT" am --quiet --3way "$WORK/take.mbox" || {
  git -C "$ROOT" am --abort >/dev/null 2>&1 || true
  echo "[take] applied in the scratch worktree but the core's tree has local edits in the way"; exit 1; }

echo "[take] landed:"
git -C "$ROOT" log --reverse --format='         %h %an — %s' "HEAD~$N..HEAD"
echo "[take] next: make ship, then make keri-lib-publish (the cut carries these out under their authors),"
echo "       then close the patch in localchimera-keri naming the core commit."
