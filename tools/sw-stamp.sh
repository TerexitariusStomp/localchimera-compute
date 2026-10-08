#!/usr/bin/env bash
# sw-stamp.sh — stamp a served browser tree's service worker.
#
#   tools/sw-stamp.sh <tree> [<source-sw.js>]
#
# Writes <tree>/sw.js from the source (default: <tree>/sw.js itself) with four
# lines filled in from the tree as it stands:
#
#   const CACHE = 'playnet-<hash>';  a fingerprint of the dial's served bytes
#   const CORE  = [ … ];             what app.html's own tags load
#   const SHELL = [ … ];             the dial's module graph, path by path
#   const ROOTS = [ … ];             the tree's top-level directories and files
#
# The fingerprint is a walk of the tree, less three things: sw.js (it embeds
# the result), dot-files (the server refuses them), and the sub-apps the
# worker passes through — read from the source's own `const PASS` line, so the
# worker and this walk agree on what is the dial's. A change under boards/ or
# docs/ therefore leaves the stamp, and every installed dial, as it was.
#
# CORE is every same-origin src/href of a <script>, <link> or <img> in
# app.html. SHELL is app/ and lib/ modules, the root scripts and the
# stylesheets, less what CORE already names. ROOTS is where a static file can
# live; a server route is no directory of the tree, so the worker's
# "keep what is under a root" rule cannot keep one.
#
# The write is a temp file and a rename, so a browser fetching mid-deploy sees
# the previous stamp or this one. Prints the hash. Callers: the deploy hook
# (deploy/scripts/radicle-ci-hook.sh) and the APK stage (playnet-app).
set -euo pipefail

tree=${1:?usage: sw-stamp.sh <tree> [<source-sw.js>]}
src=${2:-$tree/sw.js}
[ -d "$tree" ] || { echo "sw-stamp: no such tree: $tree" >&2; exit 1; }
[ -f "$src" ]  || { echo "sw-stamp: no such source: $src" >&2; exit 1; }
for name in CACHE PASS CORE SHELL ROOTS; do
  grep -q "^const $name = " "$src" || { echo "sw-stamp: $src has no $name line" >&2; exit 1; }
done

# the pass-through subroots, as directory names: '/boards/' → boards
mapfile -t pass < <(grep '^const PASS = ' "$src" | grep -oE "'/[^']+/'" | tr -d "'/")
prune=()
for p in "${pass[@]}"; do prune+=(-o -path "./$p"); done

# every file the dial serves: no dot-files, no pass-through subroot, no sw.js
dial_files() {
  (cd "$tree" && find . \( -name '.*' ! -name '.' "${prune[@]}" \) -prune -o \
       -type f ! -name 'sw.js' ! -name 'sw.js.tmp' -print | sed 's|^\./||' | LC_ALL=C sort)
}

hash=$(cd "$tree" && dial_files | tr '\n' '\0' | xargs -0 sha256sum | sha256sum | cut -c1-12)
[ -n "$hash" ] || { echo "sw-stamp: empty fingerprint" >&2; exit 1; }

js_list() { sed -e "s|^|'/|" -e "s|\$|'|" | paste -sd, -; }

core=$( { [ -f "$tree/app.html" ] && grep -oE '<(script|link|img)[^>]*[[:space:]](src|href)="[^"#?]+"' "$tree/app.html" \
            | sed -E 's/.*(src|href)="([^"]+)"$/\2/' \
            | grep -vE '^([a-z]+:)?//|^data:' | sed 's|^\./||; s|^/||' || true; } | LC_ALL=C sort -u)

shell=$(dial_files | grep -E '^(app|lib)/.*\.js$|^[^/]+\.js$|^assets/css/[^/]+\.css$' \
          | grep -vxE 'repl\.js' | grep -vxF -f <(printf '%s\n' "$core") || true)

roots=$(cd "$tree" && dial_files | awk -F/ 'NF>1 {print $1"/"} NF==1 {print $1}' | LC_ALL=C sort -u)

sed -E -e "s|^const CACHE = .*|const CACHE = 'playnet-${hash}';|" \
       -e "s|^const CORE = .*|const CORE = [$(printf '%s\n' "$core" | sed '/^$/d' | js_list)];|" \
       -e "s|^const SHELL = .*|const SHELL = [$(printf '%s\n' "$shell" | sed '/^$/d' | js_list)];|" \
       -e "s|^const ROOTS = .*|const ROOTS = [$(printf '%s\n' "$roots" | sed '/^$/d' | js_list)];|" \
    "$src" > "$tree/sw.js.tmp"
mv -f "$tree/sw.js.tmp" "$tree/sw.js"
echo "$hash"
