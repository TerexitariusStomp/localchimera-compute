#!/usr/bin/env bash
# freshen-ccache.sh — drop .go files that Guile cannot tell are stale.
#
# Guile checks .go freshness per module, by comparing the module's own source
# mtime. Loading (a) triggers loading (b), and (b) re-checks itself; what (a)'s
# compiled file took from (b) is the second check at the end. It is BLIND to `include-from-path`, because the fragment's
# text is baked into the includer's .go and the includer's own mtime never
# moved. Edit a planner fragment and every later run happily loads the stale
# engine — the trap this repo already knows to clear by hand.
#
# Auto-compile does not help; it only re-checks the file whose mtime changed.
# GUILE_AUTO_COMPILE=fresh does close it, but measured at 0.05s -> 29.4s on one
# mid-weight planner test (~600x, per test process, against a 300s cap), so it
# is not an option for the suite.
#
# So: for every module that includes fragments, compare its .go against the
# fragments it actually includes, and delete the .go when any is newer. Guile
# then recompiles that one module on next load and everything downstream is
# correct. Precise on purpose — invalidating the engine's .go on every ordinary
# import edit would cost that 30-second recompile for nothing.
#
# Run before a test suite, or any time after editing a fragment.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# The whole tree, not one build's ccache/: ~/.cache/guile also holds
# by-build/<guile>/guile/ccache/… for every guile tools/test/own-ccache.sh has run,
# and a stale .go is stale in each of them.
CCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/guile"
[ -d "$CCACHE" ] || { echo "freshen-ccache: no ccache at $CCACHE — nothing to do"; exit 0; }

dropped=0
checked=0

# Every source that textually includes something.
includers=$(grep -rlE '\(include(-from-path)? "' --include='*.scm' module/ || true)

for src in $includers; do
    # The .go for this source, under whichever <version>-<abi> dir(s) exist.
    mapfile -t gos < <(find "$CCACHE" -path "*${ROOT}/${src}.go" 2>/dev/null || true)
    [ ${#gos[@]} -gt 0 ] || continue

    fragments=$(guile --no-auto-compile tools/lint/wasm-deps.scm --includes-only "$src" 2>/dev/null || true)
    [ -n "$fragments" ] || continue

    checked=$((checked + 1))

    for go in "${gos[@]}"; do
        stale=""
        for frag in $fragments; do
            if [ "$frag" -nt "$go" ]; then stale="$frag"; break; fi
        done
        if [ -n "$stale" ]; then
            rm -f "$go"
            dropped=$((dropped + 1))
            echo "  stale: $src (fragment $stale is newer) — dropped $(basename "$go")"
        fi
    done
done

if [ "$dropped" -eq 0 ]; then
    echo "freshen-ccache: $checked includer(s) checked, all .go current"
else
    echo "freshen-ccache: $checked includer(s) checked, $dropped stale .go dropped"
fi

# The same blindness one step out: a compiled file holds what it inlined from its
# imports, a record's layout and the module each name came from, and Guile checks
# none of that. tools/edit/freshen-imports.py drops a .go older than a source it reaches.
python3 tools/edit/freshen-imports.py
