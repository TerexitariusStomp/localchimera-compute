#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/lint/lint-ids.sh — no module spells an id grammar's prefix by hand.
#
# A grammar written in one place has a constructor, a membership test and (where one is
# read) a reader: vf/facts/located.scm for column keys, good keys and the claim~ and
# cross- process ids; vf/facts/work-ids.scm for the ni|, oi|, mi| and offer: intents;
# federation/plan-bundle.scm for plan:; economy/payouts.scm for sending:. A site that
# builds or tests one of these prefixes itself, or joins a located good (`#` and `@`) from its
# parts, is a second spelling that drifts when the
# grammar does (the claim id once had seven splitters). So: a `string-append`,
# `string-prefix?` or `format` over a literal that begins with one of these prefixes is
# refused outside the owners, and the exceptions are named here with their reason.
#
# Run: bash tools/lint/lint-ids.sh   (make lint-ids)

set -uo pipefail
cd "$(dirname "$0")/../.."

bars='p|m|w|wr|mv|r|T|acq|Svc|Lab|Pres|El|ni|oi|mi|bg|cp'
pattern="\\((string-append|string-prefix\\?|string-suffix\\?|format #f) \"(($bars)\\||claim~|cross-|offer:|plan:|sending:)"

# a located good joined from its parts: spec#place@period, or a place and a period (`lg`, `cell`)
joined="\\((string-append|format #f)[^;]*(~a#~a@|\"#\" [^;]*\"@\"|\"@\" \\(number->string)"

# the files that OWN a grammar, and what is exempt with its reason
owners='module/localchimera/vf/facts/located.scm|module/localchimera/vf/facts/work-ids.scm|module/localchimera/federation/plan-bundle.scm|module/localchimera/economy/payouts.scm'
exempt='module/localchimera/bench/'   # benchmarks read engine keys directly, as a stopwatch

hits="$(grep -rnE "$pattern|$joined" module --include=*.scm \
        | grep -vE "^($owners)" | grep -vE "^$exempt" \
        | grep -vE '^[^:]*:[0-9]+:\s*;' || true)"
if [ -n "$hits" ]; then
    echo "lint-ids: a prefix spelled by hand, where the grammar has a constructor and a test:"
    echo "$hits" | sed 's/^/  /' | cut -c1-170
    echo "lint-ids: use the constructor, the predicate or the reader of the module that owns the grammar (see the header of this script)."
    exit 1
fi
echo "lint-ids: no id prefix is spelled by hand outside its owner."
