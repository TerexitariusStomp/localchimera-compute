#!/bin/sh
# hoot's `guild compile-wasm --bundle` emits browser/reflect.js with a bare
# WebAssembly.instantiateStreaming(fetch(...)) — which hard-fails when the
# server mis-types .wasm (Capacitor's local scheme is a known offender;
# docs/dev/clock-projection.md, app/README.md). Patch in a bytes fallback.
# Idempotent; pure POSIX sh+awk (runs in the lean CI-hook env too).
# Both Makefile wasm rules call this after every bundle. Drop once hoot
# ships the fallback upstream.
set -eu
f="$(dirname "$0")/../../browser/reflect.js"
# The spine runs in a dedicated Worker (browser/spine-worker.js): reflect.js
# picks its browser I/O and fetch paths by `typeof window`, which a worker
# lacks, and falls to the Node path (`require`). Teach both tests `self`.
# Idempotent: sed matches only the unpatched form.
sed -i "s/typeof fetch !== 'undefined' \&\& typeof window !== 'undefined')/typeof fetch !== 'undefined' \&\& (typeof window !== 'undefined' || typeof self !== 'undefined'))/; s/} else if (typeof window !== 'undefined') { \/\/ web browser/} else if (typeof window !== 'undefined' || typeof self !== 'undefined') { \/\/ web browser or worker/" "$f"
# A 100k-argument String.fromCodePoint spread overflows the CALLER'S stack —
# a worker mid-decode has little left, and a ~500KB snapshot string (Berlin's
# plan wire) crashed the spine on it. 8k spreads are safe everywhere.
# Idempotent: sed matches only the unpatched constant.
sed -i 's/let maxcp = 100000;/let maxcp = 8000;/' "$f"
grep -q 'arrayBuffer' "$f" && exit 0      # already patched
old='        return WebAssembly.instantiateStreaming(fetch(path), imports);'
n=$(grep -cF "$old" "$f" || true)
[ "$n" = 1 ] || { echo "reflect.js shape changed -- update $0" >&2; exit 1; }
awk -v old="$old" '
  $0 == old {
    print "        // some servers (and Capacitor local scheme) serve .wasm without"
    print "        // the application/wasm MIME type, which instantiateStreaming"
    print "        // rejects -- fall back to plain instantiate over the bytes"
    print "        return WebAssembly.instantiateStreaming(fetch(path), imports)"
    print "            .catch(async () => {"
    print "                const resp = await fetch(path);"
    print "                if (!resp.ok) throw new Error(\"fetch \" + path + \": \" + resp.status);"
    print "                return WebAssembly.instantiate(await resp.arrayBuffer(), imports);"
    print "            });"
    next
  }
  { print }
' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
echo "patched $f"
