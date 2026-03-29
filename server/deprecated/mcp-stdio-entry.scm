#!/usr/bin/env -S guile -L module
!#
;;; mcp-stdio-entry.scm — Entry point for MCP stdio transport
;;;
;;; Usage:
;;;   guile -L module mcp-stdio-entry.scm
;;;
;;; Creates an open org and runs the MCP stdio server.
;;; Claude Desktop config:
;;;   { "command": "guile", "args": ["-L", "module", "mcp-stdio-entry.scm"] }

(use-modules (goblins)
             (playnet org)
             (playnet mcp)
             (playnet mcp-stdio))

;;; ── Create the org ────────────────────────────────────────────────────────

(define org (make-open-org "mcp-session"))

;;; ── Build MCP server with standard tools ──────────────────────────────────
;;; Start conservative: read-only tools on, eval/modify off.
;;; Pass #:allow-eval? #t to enable evaluation.

(define mcp-server
  (make-playnet-mcp-server (org-vat org) org
                         #:allow-eval? #t
                         #:allow-modify? #t
                         #:allow-history? #t
                         #:allow-bindings? #t))

;;; ── Run the stdio loop ────────────────────────────────────────────────────

(run-mcp-stdio-server mcp-server (org-vat org))
