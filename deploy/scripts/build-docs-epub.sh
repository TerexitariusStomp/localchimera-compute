#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# build-docs-epub.sh — compile docs/playnet.typ to PDF + EPUB at deploy.
#
# browser/docs/playnet.pdf and browser/docs/playnet.epub are gitignored build
# products (like rns-wasm's artifacts), so the CI rsync never delivers them on
# its own — without this step the scroll's "the latest spec" links 404. Built
# UNDER browser/ (not top-level docs/) so the scroll's relative links resolve
# the same way under both servers: `make serve`'s local dev server (work-dir
# "browser") and production (work-dir the whole checkout, deploy/os.scm) — a
# top-level docs/ would 404 locally while working in prod, or vice versa.
# Runs BEFORE sync_application_code, so the freshly-built files ride the
# ordinary rsync (browser/*** is already included).
#
# Toolchain: plain in-channel `typst` + `pandoc`
# (deploy/manifests/docs-manifest.scm) via `guix shell` — no external
# binary fetch. That was NOT the first design here: it needs equations in
# the EPUB, and Typst's HTML export only turns an equation into real MathML
# markup as of 0.15 (typst/typst#5721) — this channel's typst reports 0.14.2,
# which drops every equation from HTML export silently (confirmed:
# 755/755 dropped on this doc). The first version of this script fetched a
# pinned 0.15 binary outside the channel to get that MathML.
#
# MathML then turned out to be the wrong target anyway: Kindle's MathML
# support doesn't compute correct block height for "tall" equations
# (underbrace / summation-with-limits / nested sub-sup), so the following
# text overlapped the equation instead of flowing below it — confirmed live
# on-device. The fix isn't a better MathML exporter, it's not using MathML:
# the EPUB_WRAPPER below renders every equation to an inline SVG via
# `html.frame` (a documented pre-0.15 technique — see the Typst forum
# thread "How to render math equations inline … in html export"), which
# works fine on this channel's 0.14.2 and gives every reader (Kindle
# included) an image with explicit width/height instead of a markup tree it
# has to lay out itself. `it.block ? it : box(it)` keeps INLINE equations
# from forcing a paragraph break — without it every `$x$` mid-sentence came
# out as its own top-level element, splitting the paragraph in two.
#
# Skips (exit 0, deploy must not break): no docs/playnet.typ, no guix, or
# sources unchanged since the last successful build (content stamp).
#
# Usage: build-docs-epub.sh <repo-dir>
#   builds <repo-dir>/browser/docs/playnet.pdf and .../playnet.epub.

set -euo pipefail

REPO_DIR="${1:?usage: build-docs-epub.sh <repo-dir>}"
SRC="$REPO_DIR/docs/playnet.typ"
OUT_DIR="$REPO_DIR/browser/docs"
LOG_PREFIX="[build-docs-epub]"
MANIFEST="$REPO_DIR/deploy/manifests/docs-manifest.scm"

log() { echo "$LOG_PREFIX $(date -Iseconds) $*"; }

[ -f "$SRC" ] || { log "no $SRC — skipping"; exit 0; }
if ! command -v guix >/dev/null 2>&1; then
    log "no guix (for typst + pandoc) — skipping"
    exit 0
fi
mkdir -p "$OUT_DIR"

# --- Content stamp: skip when the source is unchanged -----------------------
stamp_file="$OUT_DIR/.docs-epub-stamp"
src_hash=$(sha256sum "$SRC" | cut -c1-16)
if [ -f "$stamp_file" ] && [ "$(cat "$stamp_file")" = "$src_hash" ] \
   && [ -f "$OUT_DIR/playnet.pdf" ] && [ -f "$OUT_DIR/playnet.epub" ]; then
    log "docs/playnet.typ unchanged ($src_hash) — skipping"
    exit 0
fi

GUIX_DOCS_SHELL=(guix shell -m "$MANIFEST" --)

# The spec imports @preview/cetz (and cetz imports @preview/oxifmt). The box
# reaches the network over Tor only, so typst's package download fails DNS
# there; the packages ride in the repo and typst reads them from here.
TYPST_PKGS=(--package-path "$REPO_DIR/deploy/typst-packages")

log "compiling docs/playnet.typ ($src_hash) → PDF"
"${GUIX_DOCS_SHELL[@]}" typst compile "${TYPST_PKGS[@]}" "$SRC" "$OUT_DIR/playnet.pdf"

# The wrapper: same document, plus a show rule that only fires during HTML
# export (PDF above compiles $SRC directly and never sees it). Lives beside
# playnet.typ so its #include resolves without a relative-path dance.
wrapper_tmp="$REPO_DIR/docs/.playnet-epub-wrapper.typ"
cat > "$wrapper_tmp" <<'EOF'
#show math.equation: it => context {
  if target() == "html" {
    show: if it.block { it => it } else { box }
    html.frame(it)
  } else {
    it
  }
}
#include "playnet.typ"
EOF

log "compiling docs/playnet.typ ($src_hash) → HTML (features=html, equations → inline SVG)"
html_tmp="$OUT_DIR/.playnet-epub-src.html"
# HTML export is still marked experimental upstream and warns on every
# ignored-in-HTML construct (page-level `#v`, `#align`, `#pagebreak`, …) —
# expected and harmless for a reflowable EPUB, so only the summary line
# survives to the deploy log rather than several thousand lines of noise.
if ! "${GUIX_DOCS_SHELL[@]}" typst compile "${TYPST_PKGS[@]}" --features html --format html "$wrapper_tmp" "$html_tmp" \
        >"$OUT_DIR/.playnet-epub-warnings.log" 2>&1; then
    log "typst HTML export FAILED — see $OUT_DIR/.playnet-epub-warnings.log"
    rm -f "$wrapper_tmp"
    exit 0
fi
warn_count=$(grep -c '^warning:' "$OUT_DIR/.playnet-epub-warnings.log" || true)
eq_dropped=$(grep -c 'equation was ignored' "$OUT_DIR/.playnet-epub-warnings.log" || true)
svg_count=$(grep -o '<svg' "$html_tmp" | wc -l || true)
log "HTML export: $warn_count warnings, $eq_dropped equations dropped, $svg_count equation SVGs (want 0 dropped)"
rm -f "$OUT_DIR/.playnet-epub-warnings.log" "$wrapper_tmp"

css_tmp="$OUT_DIR/.playnet-epub.css"
cat > "$css_tmp" <<'EOF'
body { font-family: serif; line-height: 1.4; }
svg { max-width: 100%; }
h2, h3, h4 { line-height: 1.2; }
EOF

log "packaging EPUB3 via pandoc"
"${GUIX_DOCS_SHELL[@]}" pandoc "$html_tmp" -f html -t epub3 -o "$OUT_DIR/playnet.epub" \
    --metadata title="Playnet" \
    --metadata author="playnet" \
    --toc --toc-depth=3 \
    --epub-chapter-level=2 \
    --css="$css_tmp"

rm -f "$html_tmp" "$css_tmp"
echo "$src_hash" > "$stamp_file"
log "wrote docs/playnet.pdf + docs/playnet.epub"
