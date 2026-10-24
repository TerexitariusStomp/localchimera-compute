#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# tools/dev/shot.sh — reliable headless screenshot of a local URL, via Playwright +
# the guix `ungoogled-chromium` (UNCONFINED — not the snap Firefox, which hangs
# headless under Wayland/snap confinement from a non-login shell).
#
#   bash tools/dev/shot.sh <url> <out.png> [width] [height] [settleMs]
#   bash tools/dev/shot.sh 'http://127.0.0.1:8080/app.html?face=share' ~/localchimera-dev-shots/share.png
#   SHOT_INIT='localStorage.setItem("onboard", ...)'  runs before the page's scripts;
#   SHOT_EVAL='…'                                     runs after it has settled.
#
# Re-execs itself inside the browser-test guix shell (node + node-playwright-core
# + ungoogled-chromium), links the profile's node_modules so ESM resolves
# playwright-core, points Playwright at chromium via CHROMIUM_PATH, then runs
# tools/dev/shot.mjs. Mirrors tests/ux/ux-run.sh.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Enter the guix env if we're not already in it.
if [ -z "${GUIX_ENVIRONMENT-}" ]; then
  exec guix shell -L deploy/guix -m deploy/manifests/browser-test-manifest.scm -- sh "$0" "$@"
fi

URL="${1:?usage: shot.sh <url> <out.png> [w] [h] [settleMs]}"
OUT="${2:?usage: shot.sh <url> <out.png> [w] [h] [settleMs]}"
W="${3:-1400}"; H="${4:-900}"; SETTLE="${5:-2500}"

CLEAN=""
if [ -d "$GUIX_ENVIRONMENT/lib/node_modules" ] && [ ! -e "$ROOT/node_modules" ]; then
  ln -s "$GUIX_ENVIRONMENT/lib/node_modules" "$ROOT/node_modules"; CLEAN="$ROOT/node_modules"
fi
trap '[ -n "$CLEAN" ] && rm -f "$CLEAN"' EXIT INT TERM

CHROMIUM_BIN="$(command -v chromium || true)"
[ -n "$CHROMIUM_BIN" ] && export CHROMIUM_PATH="$CHROMIUM_BIN"

node "$ROOT/tools/dev/shot.mjs" "$URL" "$OUT" "$W" "$H" "$SETTLE"
