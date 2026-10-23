#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# check-ui-fresh.sh — the committed JavaScript matches the TypeScript it came from.
#
# ui/ compiles into browser/ and the OUTPUT IS COMMITTED, the way repl.wasm and
# day-boot.wasm already are. That is what lets a fresh clone, `make serve`, the
# CI rsync, the prod static service and the Capacitor stage all see a complete
# served tree with no build having run.
#
# The cost of that choice is drift: edit a .ts, forget to run `make ui`, and the
# tree still works — it just runs the OLD code, and nothing says so. Same failure
# shape as a stale .go or an unlisted wasm prerequisite, and the same answer:
# a gate that recompiles and compares rather than trusting mtimes.
#
# Emits to a scratch tree and diffs each emitted file against its committed
# twin. Says nothing about the hand-written .js in browser/ — a module is EITHER
# hand-written there OR generated from ui/, and only the generated ones are
# checked, so an unconverted file is invisible here rather than reported missing.
#
# TWO MODES, because they answer different questions:
#
#   (default)  is the WORKING TREE consistent? What `make test-fast` wants.
#   --staged   is the COMMIT consistent? What the pre-commit hook wants.
#
# The difference is not academic — it is how browser/app/tabs/location.js went
# stale. This repo is worked in by concurrent sessions sharing one checkout, so
# commits are path-limited to one session's own files. A regenerated .js can sit
# correct on DISK, satisfy a disk-reading gate, and never be staged: the commit
# lands with the .ts moved and its output left behind. --staged materialises the
# index into a scratch tree and checks THAT, so the question asked is the one
# that matters at commit time.
#
# Usage: bash tools/lint/check-ui-fresh.sh [--staged]   (run under $(UI_ENV) — needs tsc)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

STAGED=0
[ "${1:-}" = "--staged" ] && STAGED=1

if [ ! -d ui ]; then
    echo "check-ui-fresh: no ui/ — nothing generated, nothing to drift"
    exit 0
fi

scratch="$(mktemp -d)"
work="$ROOT"
trap 'rm -rf "$scratch" "${index_tree:-}"' EXIT

# --staged: rebuild the index as a tree and run the whole check inside it, so
# both halves of the comparison — the .ts compiled and the .js compared against
# — are the bytes the commit carries. Only what the check reads is materialised.
if [ "$STAGED" -eq 1 ]; then
    index_tree="$(mktemp -d)"
    git ls-files -z -- ui tsconfig.json ':(glob)browser/**/*.js' \
        | git checkout-index -z --stdin --prefix="$index_tree/" -f
    [ -d "$index_tree/ui" ] || { echo "check-ui-fresh: no ui/ in the index"; exit 0; }
    work="$index_tree"
    cd "$work"
fi

# Same project, redirected. --outDir on the command line overrides tsconfig's,
# so the committed tree is never written by the gate itself.
if ! tsc -p tsconfig.json --outDir "$scratch" >"$scratch/.tsc.log" 2>&1; then
    echo "check-ui-fresh: tsc FAILED — the sources do not compile" >&2
    sed 's/^/  /' "$scratch/.tsc.log" >&2
    exit 1
fi

noun="tree"
[ "$STAGED" -eq 1 ] && noun="commit"
rc=0
count=0
while IFS= read -r fresh; do
    rel="${fresh#$scratch/}"
    committed="$work/browser/$rel"
    count=$((count + 1))
    if [ ! -f "$committed" ]; then
        echo "  MISSING  browser/$rel — ui/ emits it, the $noun does not carry it" >&2
        rc=1
    elif ! diff -q "$committed" "$fresh" >/dev/null; then
        echo "  STALE    browser/$rel — differs from a fresh compile of its .ts" >&2
        rc=1
    fi
done < <(find "$scratch" -type f -name '*.js' | sort)

if [ "$rc" -ne 0 ]; then
    if [ "$STAGED" -eq 1 ]; then
        echo "check-ui-fresh: the COMMIT is inconsistent — a generated .js is unstaged or behind." >&2
        echo "check-ui-fresh: run \`make ui\` and \`git add\` the emitted file alongside its .ts." >&2
    else
        echo "check-ui-fresh: committed output is behind ui/ — run \`make ui\` and commit the result" >&2
    fi
    exit 1
fi

label=""; [ "$STAGED" -eq 1 ] && label=" (staged)"
echo "check-ui-fresh: $count generated file(s) match their TypeScript$label"
