#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# own-ccache.sh — run a command with a compile cache that belongs to the Guile
# on PATH, and to no other Guile.
#
#   tools/test/own-ccache.sh guile -L module foo.scm    # run under its own cache
#   tools/test/own-ccache.sh                            # print the cache home only
#
# Guile keys its compiled-file cache by version and ABI —
# ~/.cache/guile/ccache/3.0-LE-8-4.7 — and TWO DIFFERENT BUILDS of one version
# share that key. The host guile 3.0.11 and the dev manifest's 3.0.11-1.b0f6549
# snapshot both write there, and a solver.scm.go compiled by one is loaded by
# the other, which dies in vec->i32 with "expecting mutable bytevector": 117
# suites red at once, none of them a regression. Whichever ran last poisoned
# the well for the other. Two sessions on one working tree did exactly this.
#
# So the cache is keyed by the BINARY: XDG_CACHE_HOME moves to
# ~/.cache/guile/by-build/<name>-<hash>/, where the key is the store item the
# guile resolves to (guile-3.0.11-8vwbdsni), or basename+path-hash off-store.
# Under ~/.cache/guile on purpose, so the one tree still holds every compiled
# file there is, freshen-ccache/stale-go-sweep walk it whole, and `rm -rf
# ~/.cache/guile` is still the nuke-all.
#
# Idempotent: an XDG_CACHE_HOME already inside a by-build dir is kept, so the
# wrapper can nest (Makefile → runner → runner) without stacking keys.
#
# The default ~/.cache/guile/ccache is left to hand-run guile. A cache the
# suite reads is a cache the suite filled — see run-suite.sh's warm step.

set -euo pipefail

case "${XDG_CACHE_HOME:-}" in
  */guile/by-build/*) ;;                       # already keyed — keep it
  *)
    g=$(command -v guile 2>/dev/null || true)
    if [ -z "$g" ]; then
      key="no-guile"
    else
      real=$(realpath "$g")
      case "$real" in
        /gnu/store/*)
          item=${real#/gnu/store/}; item=${item%%/*}       # <hash>-guile-3.0.11
          hash=${item%%-*}; name=${item#*-}
          key="$name-${hash:0:8}"
          ;;
        *)
          h=$(printf '%s' "$real" | sha256sum | cut -c1-8)
          key="$(basename "$real")-$h"
          ;;
      esac
    fi
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/guile/by-build/$key"
    ;;
esac

if [ $# -eq 0 ]; then printf '%s\n' "$XDG_CACHE_HOME"; else exec "$@"; fi
