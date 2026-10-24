#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-wasm-deps.sh — the wasm prerequisite lists still cover their imports.
#
# Usage: check-wasm-deps.sh ENTRY.scm "declared prereqs ..."
#
# A hand-written prerequisite list fails asymmetrically. An EXTRA entry costs
# a needless rebuild. A MISSING entry means make believes a stale artifact is
# fresh, so an edit that breaks the build produces no rebuild and no error —
# the breakage surfaces later, blamed on whoever next touches a listed file.
# (localchimera crypto shamir) went missing from browser/repl.wasm exactly this way.
#
# So: missing is an error, extra is a note. Extras are never demanded away,
# because tools/lint/wasm-deps.scm reads static import forms only and a prerequisite
# may be there for a reason it cannot see.

set -euo pipefail

ENTRY="${1:?usage: check-wasm-deps.sh ENTRY.scm \"declared ...\"}"
DECLARED="${2:-}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

guile --no-auto-compile tools/lint/wasm-deps.scm "$ENTRY" | LC_ALL=C sort -u > "$tmp/computed"
printf '%s\n' $DECLARED | grep -v '^$' | LC_ALL=C sort -u > "$tmp/declared"

missing=$(LC_ALL=C comm -13 "$tmp/declared" "$tmp/computed")
extra=$(LC_ALL=C comm -23 "$tmp/declared" "$tmp/computed")

if [ -n "$extra" ]; then
    echo "note: $ENTRY declares prerequisites not reachable by static import:"
    printf '        %s\n' $extra
fi

if [ -n "$missing" ]; then
    echo "" >&2
    echo "error: $ENTRY imports modules missing from its prerequisite list:" >&2
    printf '         %s\n' $missing >&2
    echo "" >&2
    echo "       make will treat a stale artifact as up to date. Add them to" >&2
    echo "       the *_WASM_DEPS variable in the Makefile." >&2
    exit 1
fi

echo "ok: $ENTRY — $(wc -l < "$tmp/computed") imported modules, all declared"
