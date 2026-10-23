#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/lint/check-emit-fresh.sh — a generated, committed file matches what its emitter writes today.
#
#   EMIT_CMD="<guile invocation>" tools/lint/check-emit-fresh.sh <check-target> <out-file> <emit-target> <emit-tool> [ARG …]
#
# Regenerates the file into a temporary path — `<emit-tool> ARG … <tmp>`, the
# output path last, as every emitter takes it — and diffs it against the
# committed copy. Every `check-*-fresh` target in the Makefile is this one
# check, so they cannot drift in how they regenerate or how they say "stale".

set -uo pipefail
cd "$(dirname "$0")/../.."

check="$1" out="$2" emit="$3" tool="$4"; shift 4
tmp=$(mktemp); log=$(mktemp); trap 'rm -f "$tmp" "$log"' EXIT

# EMIT_CMD is a command line (guix shell … guile), so it splits on purpose
# shellcheck disable=SC2086
$EMIT_CMD -L module "$tool" "$@" "$tmp" >"$log" 2>&1 || { echo "$check: $tool failed"; tail -12 "$log"; exit 1; }

if diff -q "$tmp" "$out" >/dev/null; then
    echo "$check: $out matches its source"
else
    echo "$check: $out is stale — run: make $emit"
    diff "$tmp" "$out" | head -12
    exit 1
fi
