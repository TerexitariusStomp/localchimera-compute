#!/usr/bin/env bash
# Vendor the speech runtime the ASR worker (browser/lib/asr-worker.js) loads:
# the transformers.js bundle and the ONNX Runtime Web binaries it runs on.
#
# The files are COMMITTED: the deploy rsync ships them, the service worker
# caches them, and no page asks a CDN for them. This script is how they are
# updated — bump the versions, run it, update the digests it prints, commit.
#
# Two ORT builds ride along, as transformers.js picks between them:
#   ort-wasm-simd-threaded.asyncify.*   every engine but Safari
#   ort-wasm-simd-threaded.*            Safari
# ORT_VERSION is the one transformers.js TX_VERSION depends on (its
# package.json `onnxruntime-web`); the two move together.
#
# Fetched over Tor by default, by the project's networking policy; NO_TOR=1
# overrides. Each file is checked against its pinned sha256, so a changed or
# truncated download is refused before it replaces a file.

set -euo pipefail
cd "$(dirname "$0")"

CURL=("curl" "-sLf")
[[ "${NO_TOR:-0}" == "1" ]] || CURL=("torsocks" "${CURL[@]}")

TX_VERSION="4.2.0"
ORT_VERSION="1.26.0-dev.20260416-b7804b056c"
TX="@huggingface/transformers@${TX_VERSION}/dist"
ORT="onnxruntime-web@${ORT_VERSION}/dist"

# name | path under cdn.jsdelivr.net/npm | sha256
FILES=(
  "transformers.min.js|$TX/transformers.min.js|e74bd32ed4453369ebb0edcaa27f6bc6204004a949a0233cdb87b62dda8d6978"
  "ort-wasm-simd-threaded.asyncify.mjs|$ORT/ort-wasm-simd-threaded.asyncify.mjs|5959c6733039619c9af710d8e1bae8d6e84402787990637be987c2b1bd6c5fa9"
  "ort-wasm-simd-threaded.asyncify.wasm|$ORT/ort-wasm-simd-threaded.asyncify.wasm|e0c0c6d3e73d43b8a249972f8358f845b08cc16fec3c80efafdf8bed40366786"
  "ort-wasm-simd-threaded.mjs|$ORT/ort-wasm-simd-threaded.mjs|5f2cd914554830762579c372d0211614c1e3f40ab3f6c0cfcf0900343229071d"
  "ort-wasm-simd-threaded.wasm|$ORT/ort-wasm-simd-threaded.wasm|f4f290847a4df02d0b93cdbf39b4b0e71acefbe80573e7e6b9342a7abd7b290a"
)

for entry in "${FILES[@]}"; do
  IFS='|' read -r name path want <<<"$entry"
  echo "  -> $name"
  "${CURL[@]}" "https://cdn.jsdelivr.net/npm/$path" -o "$name.new"
  got=$(sha256sum "$name.new" | cut -d' ' -f1)
  if [[ "$got" != "$want" ]]; then
    echo "     sha256 $got is not the pinned $want — left as $name.new" >&2
    exit 1
  fi
  mv -f "$name.new" "$name"
done

echo "Done. Files vendored:"
ls -lh *.js *.mjs *.wasm
