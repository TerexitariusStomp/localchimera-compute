#!/usr/bin/env bash
# tools/check-rid-mentions.sh — every tracked file naming this project's or a
# satellite's RID, as a transition checklist.
#
# Why this exists: a Radicle RID change (a new core project, or a satellite
# re-published under a new id) cannot be made fully env-variable. deploy/os.scm
# and most deploy/ scripts already read PLAYNET_RID[_BARE] from the
# environment with today's value as a fallback default — that part of the
# system needs no edit. But a Guix channel url or package home-page
# (guix.scm, deploy/channels.scm, deploy/guix/*.scm) is read by Guix itself at
# `guix pull`/`guix install` time, before any deploy-time environment exists;
# it has to be a literal in the source. A license, a README clone command, a
# shipped attribution string are the same kind of thing — true today, and
# only true tomorrow if someone edits them. This script does not try to make
# any of that automatic; it finds every place that would need a human's eyes,
# so a transition has a concrete list instead of a fresh grep each time.
#
# Usage: tools/check-rid-mentions.sh [RID_BARE ...]
#   No argument: the core RID from `rad inspect` in this checkout, plus every
#   satellite's rid field in deploy/satellites.scm — i.e. "what's live now".
#   One or more arguments: check exactly those bare ids instead (useful to
#   confirm a NEW rid appears nowhere yet, before it's announced).
#
# Prints RID, then count and path for each file; nothing is read as
# load-bearing vs. cosmetic here — tools/RID-MENTIONS.md in the project's own
# opsec/planning notes carries that classification, read by a human once and
# not worth re-deriving by grep on every run.

set -euo pipefail
cd "$(dirname "$0")/.."

bare_of() { case "$1" in rad:*) echo "${1#rad:}" ;; *) echo "$1" ;; esac; }

RIDS=()
if [ "$#" -gt 0 ]; then
    for r in "$@"; do RIDS+=("$(bare_of "$r")"); done
else
    core=$(rad inspect 2>/dev/null || true)
    [ -n "$core" ] && RIDS+=("$(bare_of "$core")")
    if [ -f deploy/satellites.scm ]; then
        while IFS= read -r rid; do
            [ -n "$rid" ] && RIDS+=("$(bare_of "$rid")")
        done < <(GUILE_AUTO_COMPILE=0 guile -c '
            (let loop ((f (read)) (last #f))
              (if (eof-object? f)
                  (for-each (lambda (p)
                              (let ((r (assq-ref p (quote rid))))
                                (when r (display r) (newline))))
                            (eval last (interaction-environment)))
                  (loop (read) f)))' < deploy/satellites.scm 2>/dev/null || true)
    fi
fi

[ "${#RIDS[@]}" -gt 0 ] || { echo "check-rid-mentions: no RID found (no rad identity here, no deploy/satellites.scm)"; exit 1; }

total=0
for rid in "${RIDS[@]}"; do
    echo "=== $rid ==="
    n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "  $line"
        n=$((n + 1))
    done < <(git grep -n --fixed-strings "$rid" -- . ':!*.local.md' 2>/dev/null || true)
    echo "  ($n mention(s))"
    total=$((total + n))
done
echo "--- $total mention(s) across ${#RIDS[@]} RID(s) ---"
