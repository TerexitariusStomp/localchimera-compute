#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# run-scm-tests.sh — the generic green baseline.
#
# Discovers EVERY .scm test in the repo (tests/ and module/**/tests/) and runs
# it, so a test can never rot by being forgotten from the Makefile — adding a
# test file is all it takes to enlist it. Green/red is read from the process
# EXIT CODE (the harness's test-summary! already exits 1 on any failure), so no
# fragile summary-string parsing.
#
# Exclusions are EXPLICIT and REASONED, never silent:
#   • attic/ — retired code, not the live suite.
#   • tests/QUARANTINE — one path per line, each with a `# reason` (env-dependent
#     like needs-keria / needs-network / needs-valhalla / needs-wasm, or
#     broken:<note> for tracked debt). Blank lines and #-comments ignored.
#
# Exit status: 0 iff every NON-quarantined discovered test exited 0 WHEN RUN
# ALONE. A red seen during the parallel pass is re-run serially before it counts
# (see the confirm pass below): under contention a red is a question, not a
# verdict, and treating the two as the same thing produced three separate rounds
# of phantom failures. A test that only fails under load is reported as
# LOAD-SENSITIVE — visible, not gating, and still a defect in the test.
#
# Env:
#   GUILE      guile invocation (default "guile"); the Makefile passes the pinned
#              guix-shell wrapper. Auto-compile is left ON on purpose: a baseline
#              must be CORRECT over fast, and --no-auto-compile can read a STALE .go
#              for a source edited since (a false red/green). Fresh checkouts have no
#              cache, so the recompile cost is paid once.
#   TIMEOUT    per-test seconds (default 300). Generous on purpose: the heaviest
#              solver tests take a couple of minutes warm and more once
#              auto-compile rebuilds the engine. MEASURED, since this line
#              previously carried a "~85s" that no measurement supported and that
#              made a test costing 828s look like a regression in whatever ran
#              beside it: reproduction-diet 132s, inspection-in-plan 265s. A real
#              hang is still bounded; genuinely-long benchmarks belong in
#              QUARANTINE. The `slowest:` list printed after every run exists so
#              drift toward this cap is visible while it is still headroom.
#   RUN_QUARANTINED=1  also run the quarantined tests, report them, but NEVER let
#              them fail the baseline (visibility without gating).
#   JOBS       tests run concurrently (default: cores/2). JOBS=1 is the old
#              serial behaviour, for when timings must not contend. Workers pin
#              OMP_NUM_THREADS=1 when JOBS>1 — the C kernel is OpenMP-threaded,
#              so unpinned parallel tests oversubscribe and run SLOWER than
#              serial. Reporting order is independent of JOBS.
#   PROGRESS   1 (default) prints a line per test as it finishes, plus the five
#              slowest at the end; 0 restores the silent run.
set -u
cd "$(dirname "$0")/../.." || exit 2

GUILE=${GUILE:-guile}
TIMEOUT=${TIMEOUT:-300}
QFILE=tests/QUARANTINE

# quarantined paths (strip inline reasons + comments + blanks)
declare -A QUAR=()
if [[ -f "$QFILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line// /}"
    [[ -n "$line" ]] && QUAR["$line"]=1
  done < "$QFILE"
fi

mapfile -t ALL < <(find tests module -name '*.scm' \
  \( -path 'tests/*' -o -path '*/tests/*' \) \
  ! -path '*/attic/*' | sort)

# DISCOVERING NOTHING IS A FAILURE, NOT A PASS. This runner counted what it ran
# and reported the count, so when `find` itself was missing from the environment
# it discovered zero files, ran zero tests, printed `0 passed, 0 failed` and
# exited 0. A green that means "the suite never started" is worse than a red:
# it is the one result nobody double-checks. The repo has hundreds of suites and
# the floor is deliberately loose — this asks whether a suite exists at all, not
# whether the count is right.
if (( ${#ALL[@]} < 50 )); then
  echo "run-scm-tests: discovered only ${#ALL[@]} test files — expected hundreds." >&2
  echo "  The suite did not run. Check that \`find\` is present and that this is" >&2
  echo "  the repo root (cwd: $PWD)." >&2
  exit 2
fi

# split into gating and quarantined, preserving discovery order
RUN=(); QLIST=()
for f in "${ALL[@]}"; do
  if [[ -n "${QUAR[$f]:-}" ]]; then QLIST+=("$f"); else RUN+=("$f"); fi
done
quar=${#QLIST[@]}

# ── one line per test, as it finishes ────────────────────────────────────────
# The runner used to send every test's output to /dev/null and print only a
# final summary, so a half-hour run was completely opaque while it ran: no way
# to tell a slow test from a hung one, a third of the way through from nearly
# done. Progress was reconstructed from counting .go files and reading ps, which
# is how an afternoon went into diagnosing contention that a per-test line would
# have shown immediately. PROGRESS=0 restores the quiet behaviour.
progress() {
  [[ "${PROGRESS:-1}" == 1 ]] || return 0
  local code=$1 secs=$2 file=$3
  if [[ $code -eq 0 ]]; then printf '  ok   %5ss  %s\n' "$secs" "$file"
  elif [[ $code -eq 124 ]]; then printf '  TIME %5ss  %s  (timeout %ss)\n' "$secs" "$file" "$TIMEOUT"
  else printf '  FAIL %5ss  %s  (exit %s)\n' "$secs" "$file" "$code"; fi
}

# ── parallelism ──────────────────────────────────────────────────────────────
# Serial on a 12-core machine meant 30+ minutes. JOBS=1 reproduces that exactly
# when a run needs to be deterministic in timing (benchmarks, contention
# studies). NOTE the OpenMP interaction: the C kernel is built with -fopenmp, so
# a single heavy solver test already spreads over cores — one was measured at
# 3m48s of CPU in 3m00s of wall. Running J tests each free to use every core
# oversubscribes and makes everything slower than serial. Workers therefore pin
# OMP_NUM_THREADS=1 whenever JOBS>1, so total concurrency is exactly JOBS.
JOBS=${JOBS:-$(( $(nproc 2>/dev/null || echo 2) / 2 ))}
[[ "$JOBS" -lt 1 ]] && JOBS=1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── the run's CONDITIONS, on the record before a single test runs ────────────
# The per-test timeout has no headroom for a cold cache: the heaviest test is
# ~250s warm against a 300s cap, and auto-compile is deliberately ON (a stale
# .go is worse than a slow run). So the FIRST run after the ccache is cleared
# pays the engine's whole compile cost spread across whichever tests start
# first, and they blow the cap for reasons that have nothing to do with them.
# That is invisible unless someone thinks to look, so the script looks.

# Auto-compile being ON is what keeps a stale .go from deciding a result — but
# it only re-checks files whose own mtime moved, and an edited INCLUDE moves no
# such file. The includer's .go carries the fragment's old text and Guile sees
# nothing to redo. Drop exactly those before the run; everything else stays warm.
# (GUILE_AUTO_COMPILE=fresh also closes it, and costs 35.4s against 0.081s warm
# per process, times 344 test files. Measured, and rejected on that.)
if [[ -x "$(dirname "$0")/stale-go-sweep.sh" ]]; then
  "$(dirname "$0")/stale-go-sweep.sh" || true
fi

GOCOUNT=$(find "${XDG_CACHE_HOME:-$HOME/.cache}/guile/ccache" -path '*playnet*' -name '*.go' 2>/dev/null | wc -l)
LOAD1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo '?')
CORES=$(nproc 2>/dev/null || echo '?')
if [[ "${PROGRESS:-1}" == 1 ]]; then
  printf 'conditions: jobs=%s cores=%s load=%s cache=%s .go%s\n' \
    "$JOBS" "$CORES" "$LOAD1" "$GOCOUNT" \
    "$( [[ "$GOCOUNT" -lt 20 ]] && printf ' — COLD: first tests pay the compile cost; timings are not comparable' )"
  # A machine already busy before the suite starts will contend with it, and the
  # confirm pass below is what keeps that from being read as breakage.
  if [[ "$CORES" != '?' && "$LOAD1" != '?' ]] && awk "BEGIN{exit !($LOAD1 > $CORES/2)}" 2>/dev/null; then
    printf '            NOTE: load %s on %s cores before starting — expect contention\n' "$LOAD1" "$CORES"
  fi
fi

# ── keep the output of anything that fails ──────────────────────────────────
# Every invocation here used to send stdout and stderr to /dev/null, so a test
# that failed left an exit code and nothing else. That is survivable for a test
# that fails every time — run it again and look. It is NOT survivable for a
# flake: the only run that could explain it is the parallel one, and the
# confirm pass below re-runs the test ALONE, where it passes. So the single
# most informative artefact was discarded by construction, every time, and a
# load-sensitive test could be reported for weeks with no evidence of why.
#
# Failures now land in $FAILDIR, named after the test. Passing runs are still
# discarded — this is about keeping what is rare, not everything.
FAILDIR=${TEST_FAILURE_DIR:-.test-failures}
mkdir -p "$FAILDIR" 2>/dev/null || FAILDIR=$(mktemp -d)
faillog() { printf '%s/%s.log' "$FAILDIR" "$(echo "$1" | tr '/' '_')"; }

run_one() {
  local f=$1 s e code out
  out=$(faillog "$f")
  s=$(date +%s)
  timeout "$TIMEOUT" $GUILE -L module -L . -L tests "$f" > "$out" 2>&1
  code=$?
  e=$(date +%s)
  # a pass leaves nothing behind; a failure keeps the run that produced it,
  # UNDER LOAD, which is the run the serial confirm can never reproduce
  if [[ $code -eq 0 ]]; then rm -f "$out"; fi
  printf '%s\t%s\t%s\n' "$code" "$((e-s))" "$f" >> "$TMP/results"
  progress "$code" "$((e-s))" "$f"
}
# faillog and FAILDIR must travel WITH the workers. The parallel pass runs each
# test in a `bash -c` subshell, so a function or variable merely defined here
# does not exist there — `out` came back empty, the redirect had no target, and
# every test in the parallel pass died instantly. The serial confirm still
# redirected to /dev/null, passed all of them, and the run printed "470 passed,
# 0 failed" over a parallel pass in which nothing had actually run. Exactly the
# shape this script exists to make impossible, introduced by the change meant to
# catch it. The confirm pass is what kept it from being a false GREEN; it could
# not keep it from being a meaningless one.
export -f run_one progress faillog
export GUILE TIMEOUT TMP PROGRESS FAILDIR

if [[ "$JOBS" -gt 1 ]]; then
  export OMP_NUM_THREADS=1
  printf '%s\n' "${RUN[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}
else
  for f in "${RUN[@]}"; do run_one "$f"; done
fi

# ── the confirm pass: a red under load is a QUESTION, not a verdict ──────────
# A test that fails or times out while J others compete for the machine has not
# been shown to be broken — it has been shown to be red under contention, which
# is a different claim. Three separate rounds of phantom failures came from
# reading one as the other: a cold .go cache made early tests pay the whole
# compile cost and blow a 300s cap that a warm run clears in 49s, and heavy
# work running BESIDE the suite pushed 23 tests over the same cap, including
# two that passed standalone minutes later.
#
# So every non-zero result is re-run ONCE, serially, with nothing else from
# this script running. That result is the trustworthy one and it is what gates.
# The discrepancy is never swallowed: a test that fails under load and passes
# alone is reported as LOAD-SENSITIVE, loudly, because it is a real defect in
# the test (the mock-server port race was exactly this) — just not a reason to
# call the baseline red.
pass=0; fail=0; failed=(); flaky=()
if [[ -s "$TMP/results" ]]; then
  suspect=()
  while IFS=$'\t' read -r code secs f; do
    if [[ $code -eq 0 ]]; then pass=$((pass+1)); else suspect+=("$code|$secs|$f"); fi
  done < <(sort -t$'\t' -k3,3 "$TMP/results")   # deterministic order regardless of JOBS

  # A HANDFUL of reds under load is contention. MOST OF THE SUITE going red under
  # load and green alone is not a fact about the tests — it is the parallel pass
  # itself being broken, and it reads as a normal run because the confirm pass
  # rescues every one of them and the baseline prints in black. That happened
  # here: an unexported variable left the workers redirecting to an empty path,
  # every test died instantly, and the run reported 470 passed / 0 failed over a
  # parallel pass in which nothing had executed. The number was true and
  # worthless. So a mass load-failure is now an infrastructure verdict.
  if (( ${#suspect[@]} * 4 > ${#RUN[@]} )); then
    echo "──────────────────────────────────────────────" >&2
    echo "  ${#suspect[@]} of ${#RUN[@]} tests failed in the PARALLEL pass." >&2
    echo "  That is not contention and not a test defect: at this scale the" >&2
    echo "  parallel pass itself did not work. The serial confirm below would" >&2
    echo "  rescue them one by one and print a baseline that means nothing." >&2
    echo "  Check the worker invocation (exported vars/functions) before" >&2
    echo "  believing any number from this run." >&2
    exit 2
  fi

  if [[ ${#suspect[@]} -gt 0 ]]; then
    echo "──────────────────────────────────────────────"
    echo "  ${#suspect[@]} red under load — confirming serially before calling it"
    unset OMP_NUM_THREADS
    for entry in "${suspect[@]}"; do
      IFS='|' read -r code secs f <<< "$entry"
      s2=$(date +%s)
      timeout "$TIMEOUT" $GUILE -L module -L . -L tests "$f" >/dev/null 2>&1
      code2=$?
      e2=$(date +%s)
      if [[ $code2 -eq 0 ]]; then
        pass=$((pass+1))
        flaky+=("$f  (parallel: exit $code after ${secs}s · alone: passed in $((e2-s2))s)")
        printf '  LOAD %5ss  %s  (exit %s under load, PASSES alone — output: %s)\n' \
               "$((e2-s2))" "$f" "$code" "$(faillog "$f")"
      else
        fail=$((fail+1)); failed+=("$code2 $f")
        printf '  RED  %5ss  %s  (exit %s, confirmed)\n' "$((e2-s2))" "$f" "$code2"
      fi
    done
  fi
fi

qran=()
if [[ "${RUN_QUARANTINED:-0}" == 1 ]]; then
  for f in "${QLIST[@]}"; do
    timeout "$TIMEOUT" $GUILE -L module -L . -L tests "$f" >/dev/null 2>&1
    qran+=("$? $f")
  done
fi

echo "──────────────────────────────────────────────"
echo "  baseline: $pass passed, $fail failed, $quar quarantined  (jobs=$JOBS)"
echo "──────────────────────────────────────────────"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "RED (exit code · file)   [124 = timed out at ${TIMEOUT}s]   — confirmed serially:"
  printf '  %s\n' "${failed[@]}"
fi
# Not gating, and not swallowed either. A test that only fails when the machine
# is busy is carrying a real defect — a shared port, a wall-clock assumption, a
# fixed sleep standing in for a readiness check — and it will keep costing an
# afternoon each time it resurfaces until someone fixes the test.
if [[ ${#flaky[@]} -gt 0 ]]; then
  echo "LOAD-SENSITIVE (passed alone, failed under load — fix the test, not the cap):"
  printf '  %s\n' "${flaky[@]}"
fi
if [[ ${#qran[@]} -gt 0 ]]; then
  echo "quarantined (ran for visibility, NOT gating):"
  printf '  %s\n' "${qran[@]}"
fi
# the slowest handful, so a test drifting toward its timeout is visible BEFORE
# it starts failing — reproduction-diet sat at ~85s under a 300s cap and its
# drift past that cap read as a regression in whatever ran alongside it.
if [[ -s "$TMP/results" ]] && [[ "${PROGRESS:-1}" == 1 ]]; then
  echo "slowest:"
  sort -t$'\t' -k2,2nr "$TMP/results" | head -5 | while IFS=$'\t' read -r c s f; do
    printf '  %5ss  %s\n' "$s" "$f"
  done
fi
# RED_BASELINE=<file> compares the red list by NAME with the one the file holds, as
# tools/test/run-suite.sh does with BASELINE: totals shift when another session adds or
# removes a test, while a regression hides in a count that looks unchanged. The
# first run writes the file. With it set, the exit code says whether a test is red
# that the baseline does not name.
if [[ -n "${RED_BASELINE:-}" ]]; then
  cur="$TMP/red.txt"
  printf '%s\n' "${failed[@]}" | sed -E 's/^[0-9]+ //' | grep -v '^$' | sort > "$cur"
  if [[ ! -f "$RED_BASELINE" ]]; then
    cp "$cur" "$RED_BASELINE"
    echo "red baseline written: $RED_BASELINE ($fail names)"
  else
    new=$(comm -13 "$RED_BASELINE" "$cur"); gone=$(comm -23 "$RED_BASELINE" "$cur")
    [[ -n "$new" ]]  && { echo "REGRESSIONS (red, and not in $RED_BASELINE):"; echo "$new" | sed 's/^/  + /'; }
    [[ -n "$gone" ]] && { echo "now passing (red in the baseline):"; echo "$gone" | sed 's/^/  - /'; }
    [[ -z "$new" && -z "$gone" ]] && echo "red list identical to the baseline ($fail names)"
    [[ -z "$new" ]]; exit $?
  fi
fi
[[ $fail -eq 0 ]]
