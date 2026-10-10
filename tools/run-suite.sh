#!/usr/bin/env bash
# run-suite.sh — the planner+governance suite, in parallel, with a stable report.
#
#   tools/run-suite.sh                    # tests/planner + tests/governance
#   tools/run-suite.sh tests/planner/*.scm # an explicit set
#   JOBS=4 tools/run-suite.sh              # override the degree of parallelism
#
# Sequentially this is ~15 minutes, which makes the edit/verify loop the slowest
# part of a lift. Across cores it is a few minutes.
#
# Why parallel is safe here, checked rather than assumed:
#   - --no-auto-compile, so no test process writes the compiled-file cache.
#   - Of the nine suites that touch disk, seven build their paths with getpid;
#     the two fixed ones (/tmp/legal-registry-portrait.scm and
#     /tmp/playnet-fp-portability-test) are each used by exactly one suite.
#   Re-check with: grep -l 'output-file\|delete-file\|mkdir' tests/*/*.scm
#
# THE CACHE THE SUITE READS IS A CACHE THE SUITE FILLED. Two facts decide this:
#
#   - --no-auto-compile does not write .go files, and Guile ignores a .go that
#     is stale against its source — so an edited hot module runs INTERPRETED.
#     Editing solver.scm (2498 lines of hot numerical code) made
#     test-berlin-kleingaerten go from 2m27s to over 400s and blow the cap,
#     reported as a regression it was not. Unlike tools/run-scm-tests.sh, which
#     leaves auto-compile ON and re-runs reds serially before believing them,
#     this runner has no confirm pass — a timeout here is a verdict.
#   - Guile keys its cache by version+ABI, and two BUILDS of one version share
#     the key: a solver.scm.go compiled by the dev manifest's 3.0.11 snapshot
#     is loaded by the host 3.0.11 and dies in vec->i32 ("expecting mutable
#     bytevector") — 117 red, zero regressions. tools/own-ccache.sh.
#
# So the runner runs under its own guile's cache (own-ccache.sh) and WARMS it
# first: one process, auto-compile on, over the hot module roots. Warm, that is
# a second; after an engine edit it is the engine's compile, paid once instead
# of once per test and instead of as a timeout nobody can explain.
#
# The report is SORTED, so the failure set is comparable run to run no matter
# what order things finish in. Compare the NAMES against your baseline, never
# the counts — a concurrent session adding a test file shifts the totals while a
# regression hides inside an unchanged-looking number.

set -uo pipefail
cd "$(dirname "$0")/.."

# THE SUITE RUNS IN THE ENVIRONMENT make test USES. The host guile has no
# libosqp, so every suite whose solve reaches the OSQP backend died at
# solve-osqp — five "reds" per run that were the runner's environment, not the
# tree (restoration-recipe, transit-seat-capacity, optimal-face,
# doctor-rider-located, transport-work-vs-service all pass inside the
# manifest). A baseline polluted with phantom reds hides one real one. So the
# runner re-execs itself inside the dev-test manifest — the same guile, the
# same libraries, the same LC_ALL as `make test` — and own-ccache then keys the
# compile cache to THAT guile.
if [ -z "${RUN_SUITE_ENV:-}" ]; then
  exec guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm --     env RUN_SUITE_ENV=1 LC_ALL=C.UTF-8 HOME="$HOME" bash "$0" "$@"
fi

export XDG_CACHE_HOME
XDG_CACHE_HOME=$(bash tools/own-ccache.sh)

# the hot roots: everything the planner+governance suites load through
guile -L module -c '(use-modules (playnet solve solver) (playnet solve engine)
                                 (playnet scope live) (playnet doors service)
                                 (playnet boot prelude))' 2>&1 \
  | grep -v "^;;; \|^$" | grep -v "failed to install locale" || true

JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) - 2 ))}"
[ "$JOBS" -lt 1 ] && JOBS=1

FILES=("$@")
FULL_RUN=0
if [ ${#FILES[@]} -eq 0 ]; then
  # bench-* are BENCHMARKS, not tests — bench-relational's own header says
  # "NOT part of run-tests.sh"; it runs ~10 minutes and exits 0, so under the
  # 600s cap it sat in every baseline as a permanent phantom red. A driver
  # that prints a table answers "how fast", never "still correct".
  FILES=($(ls tests/planner/*.scm tests/governance/*.scm | grep -v '/bench-'))
  FULL_RUN=1     # a BASELINE comparison only means anything over the whole set:
fi                # on a subset every unrun test reads as "now passing"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

run_one() {
  local t="$1" out="$2"
  local b; b=$(basename "$t" .scm)
  # -L module ONLY, exactly as the Makefile invokes these (Makefile:878). Adding
  # `-L tests` looks harmless — the test harness is (playnet test harness), which
  # lives under module/ and never needed it — and it silently broke 34 of the 268
  # suites: once a script's own path resolves through a -L directory, guile's
  # (current-filename) returns #f, and `(dirname (current-filename))` is how these
  # tests find their fixtures. They died with "Wrong type argument … #f" before
  # running an assertion, and sat in the baseline being read as environmental.
  # 600, not 300. test-berlin-kleingaerten takes 4m28s ALONE on a warm .go and
  # more under ten-way contention, so at 300 it lands on either side of the cap
  # depending on what else is running — it reported as a fresh regression on two
  # consecutive runs of an unchanged tree. A cap that flaps makes every baseline
  # comparison a coin toss, which is worse than a slow suite.
  if timeout 600 guile --no-auto-compile -L module "$t" >"$out/$b.log" 2>&1; then
    echo "PASS $b" >>"$out/results"
  else
    echo "FAIL $b" >>"$out/results"
  fi
}
export -f run_one

printf '%s\0' "${FILES[@]}" \
  | xargs -0 -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} "$OUT"

# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` yields "0\n0".
pass=$(grep -c '^PASS ' "$OUT/results" 2>/dev/null); pass=${pass:-0}
fail=$(grep -c '^FAIL ' "$OUT/results" 2>/dev/null); fail=${fail:-0}
echo "planner+governance: $pass passed, $fail failed   (jobs=$JOBS)"
printf 'FAILED:'
grep '^FAIL ' "$OUT/results" 2>/dev/null | cut -d' ' -f2- | sort | tr '\n' ' '
echo

# BASELINE=<file> compares failure SETS and names the difference, which is the
# only comparison that means anything: a concurrent session adding or deleting a
# test shifts the totals while a real regression hides in an unchanged-looking
# count. Both happened in one afternoon. Writes the current set back out when
# the file does not exist yet, so the first run seeds it.
if [ -n "${BASELINE:-}" ] && [ "$FULL_RUN" = 1 ]; then
  cur="$OUT/failed.txt"
  grep '^FAIL ' "$OUT/results" 2>/dev/null | cut -d' ' -f2- | sort > "$cur"
  if [ ! -f "$BASELINE" ]; then
    cp "$cur" "$BASELINE"
    echo "baseline seeded: $BASELINE ($fail names)"
  else
    new=$(comm -13 "$BASELINE" "$cur")
    gone=$(comm -23 "$BASELINE" "$cur")
    [ -n "$new" ]  && { echo "REGRESSIONS (not in baseline):"; echo "$new" | sed 's/^/  + /'; }
    [ -n "$gone" ] && { echo "now passing (were failing):";     echo "$gone" | sed 's/^/  - /'; }
    if [ -z "$new" ] && [ -z "$gone" ]; then echo "exact baseline match"; fi
    [ -n "$new" ] && exit 1
  fi
fi
exit 0

# keep the logs of failures around for inspection
if [ "$fail" -gt 0 ] && [ -n "${KEEP_LOGS:-}" ]; then
  mkdir -p "$KEEP_LOGS"
  grep '^FAIL ' "$OUT/results" | cut -d' ' -f2- | while read -r b; do
    cp "$OUT/$b.log" "$KEEP_LOGS/$b.log" 2>/dev/null
  done
  echo "failure logs in $KEEP_LOGS"
fi
