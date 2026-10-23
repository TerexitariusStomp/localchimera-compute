;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/manifests/docs-manifest.scm — docs/playnet.typ → PDF + EPUB
;;;
;;; typst + pandoc for deploy/scripts/build-docs-epub.sh. Not built from an
;;; equation-dropping HTML export: the script's show rule renders every
;;; equation to an inline SVG via `html.frame` (works on typst 0.14, the
;;; version this channel provides — no need for 0.15's native MathML export,
;;; which Kindle's MathML support turned out to render wrong for tall/
;;; stacked equations anyway). So a plain in-channel typst is enough; no
;;; pinned external binary fetch.
;;;
;;; Same "why not deploy/channels.scm" trade-off as dev-test-manifest.scm:
;;; not bit-for-bit reproducible across hosts, but this is a doc-rendering
;;; tool, not something that ships in the served closure — fast/simple wins
;;; over that reproducibility here.
;;;
;;; Usage:
;;;   guix shell -m deploy/manifests/docs-manifest.scm -- typst compile ...
;;;   guix shell -m deploy/manifests/docs-manifest.scm -- pandoc ...

(use-modules (guix profiles))

(packages->manifest
 (map specification->package
      '("typst"
        "pandoc")))
