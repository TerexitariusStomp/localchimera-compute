#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# stale-go-sweep.sh — drop .go files that an edited INCLUDE left stale.
#
# Guile checks compiled-cache freshness per module, by comparing the module's
# own source mtime against its .go. That is correct for imports: editing an
# imported module changes that module's source, so its .go is rebuilt.
#
# It is blind to `include-from-path`. The fragment's TEXT is compiled into the
# includer's .go, and editing the fragment does not touch the includer's mtime
# — so Guile keeps loading a .go built from text that no longer exists. Edit a
# planner fragment, run the suite, and get a green (or red) that describes the
# previous edit. This repo has been bitten and carries a "nuke the ccache"
# habit as folklore; this replaces the folklore with a check.
#
# Auto-compile does NOT close this — it re-checks the file whose mtime moved,
# and no such file exists here. GUILE_AUTO_COMPILE=fresh does close it, by
# recompiling everything unconditionally: measured at 35.4s versus 0.081s warm
# for one planner test, per process, across 344 test files. Not viable.
#
# So: find the includers, compute what each one textually includes, and delete
# only the .go files that are actually out of date with respect to that text.
# One sweep, then the whole suite runs warm.
#
# Usage: tools/test/stale-go-sweep.sh [--dry-run]

set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# The whole tree, not one build's ccache/: ~/.cache/guile also holds
# by-build/<guile>/guile/ccache/… for every guile tools/test/own-ccache.sh has run,
# and a stale .go is stale in each of them.
CCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/guile"
[ -d "$CCACHE" ] || { echo "stale-go-sweep: no compiled cache, nothing to do"; exit 0; }

# Only files that textually include something can go stale this way.
mapfile -t INCLUDERS < <(grep -rlE '\(include(-from-path)? ' --include='*.scm' module/ 2>/dev/null || true)
[ "${#INCLUDERS[@]}" -gt 0 ] || { echo "stale-go-sweep: no include sites"; exit 0; }

dropped=0
checked=0

for src in "${INCLUDERS[@]}"; do
    # Guile caches as <ccache>/<abi>/<absolute source path>.go
    while IFS= read -r go; do
        checked=$((checked + 1))

        # Everything this source pulls in textually, transitively.
        newer=""
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            if [ "$dep" -nt "$go" ]; then newer="$dep"; break; fi
        done < <(guile --no-auto-compile tools/lint/wasm-deps.scm --includes-only "$src" 2>/dev/null || true)

        if [ -n "$newer" ]; then
            echo "stale: ${go#"$CCACHE"/}"
            echo "         newer: $newer"
            if [ "$DRY_RUN" -eq 0 ]; then rm -f "$go"; fi
            dropped=$((dropped + 1))
        fi
    done < <(find "$CCACHE" -path "*${ROOT}/${src}.go" 2>/dev/null || true)
done

if [ "$dropped" -eq 0 ]; then
    echo "stale-go-sweep: $checked cached includer(s) checked, all current"
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "stale-go-sweep: $dropped stale (dry run, nothing deleted)"
else
    echo "stale-go-sweep: dropped $dropped stale .go — they rebuild on next load"
fi
