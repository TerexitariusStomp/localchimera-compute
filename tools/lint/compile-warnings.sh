#!/usr/bin/env bash
# compile-warnings.sh — compile every live module with the warnings that find calls
# which can never run, and report them.
#
#   tools/lint/compile-warnings.sh [--check] [OUT-DIR]   default OUT-DIR=/tmp/compile-warnings
#
# --check makes the report a gate (`make lint-compile`, run by `make test`): it exits 1
# when any arity error or any unbound name in a module is found, and works in a
# directory of its own so two runs never share one.
#
# For each module/**/*.scm outside deprecated/, `guild compile` runs with
# -Wunbound-variable -Warity-mismatch -Wformat, writing its object to OUT-DIR/go
# (guild writes atomically, so -o /dev/null fails) and its warnings to OUT-DIR/out.
# The summary lists
#   arity     a call with the wrong number of arguments (the DEFINITE ones)
#   unbound   a name no import supplies, in a file that is a module
# A file with no define-module is an include-fragment read inside another module's
# namespace (solve/robust.scm, comms/*.scm …): its names are bound there, so its
# "possibly unbound" warnings are listed apart and are no finding.
# Files that do not compile at all (a missing shared library, a Hoot-only import) are
# listed last, since their warnings were never reached.
#
# Run it inside the dev manifest, e.g.
#   guix shell --pure -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \
#     bash tools/test/own-ccache.sh env LC_ALL=C.UTF-8 tools/lint/compile-warnings.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
CHECK=0; if [ "${1:-}" = --check ]; then CHECK=1; shift; fi
if [ "$CHECK" = 1 ] && [ -z "${1:-}" ]; then OUT=$(mktemp -d); else OUT=${1:-/tmp/compile-warnings}; fi
rm -rf "$OUT"; mkdir -p "$OUT/out" "$OUT/go"
find module -name '*.scm' -not -path '*/deprecated/*' | sort > "$OUT/files.txt"
one() {
  f=$1; OUT=$2; name=$(echo "$f" | tr / _)
  guild compile -L module -Wunbound-variable -Warity-mismatch -Wformat \
        -o "$OUT/go/$name.go" "$f" > "$OUT/out/$name.log" 2>&1
}
export -f one
xargs -P "${JOBS:-4}" -I{} bash -c 'one "$1" "$2"' _ {} "$OUT" < "$OUT/files.txt"

ARITY=$(grep -h "wrong number of arguments" "$OUT"/out/*.log | sort -u)
UNBOUND=$(for f in $(cat "$OUT/files.txt"); do
  grep -q '^(define-module' "$f" || continue
  log="$OUT/out/$(echo "$f" | tr / _).log"
  grep -h "possibly unbound variable" "$log" 2>/dev/null | sed -E "s/^/$(echo "$f" | sed 's#/#\\/#g'): /" | sed -E 's/^[^:]*: //' | sort -u | sed "s#^#${f#module/}: #"
done | sort -u)
echo "── arity (definite and possible) ──"; [ -n "$ARITY" ] && echo "$ARITY"
echo
echo "── unbound, in files that are modules ──"; [ -n "$UNBOUND" ] && echo "$UNBOUND"
echo
echo "── fragments (no define-module): possibly-unbound counts, not findings ──"
for f in $(cat "$OUT/files.txt"); do
  grep -q '^(define-module' "$f" && continue
  n=$(grep -c "possibly unbound variable" "$OUT/out/$(echo "$f" | tr / _).log" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && echo "  $n  ${f#module/}"
done
echo
echo "── did not compile ──"
grep -l "^ERROR\|^Backtrace" "$OUT"/out/*.log 2>/dev/null | sed 's#.*/out/module_##; s#\.scm\.log##; s#_#/#g' | sed 's#^#  #'
if [ "$CHECK" = 1 ]; then
  rm -rf "$OUT"
  if [ -n "$ARITY$UNBOUND" ]; then echo "lint-compile: a call that cannot run (above)" >&2; exit 1; fi
  echo "lint-compile: no arity errors, no unbound names in a module"
fi
