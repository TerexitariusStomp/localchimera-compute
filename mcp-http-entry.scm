#!/usr/bin/env -S guile -L module
!#
;;; mcp-http-entry.scm — Entry point for MCP HTTP transport
;;;
;;; Usage:
;;;   guile -L module mcp-http-entry.scm [port]
;;;
;;; Creates an open org and runs the MCP HTTP server.
;;; Default port: 8080

(use-modules (goblins)
             (xorg org)
             (xorg mcp)
             (xorg mcp-http)
             (ice-9 receive))

;;; ── Configuration ─────────────────────────────────────────────────────────

(define port
  (if (> (length (command-line)) 1)
      (string->number (cadr (command-line)))
      8080))

;;; ── Create the org ────────────────────────────────────────────────────────

(define org (make-open-org "mcp-http-session"))
(define vat (org-vat org))

;;; ── Build MCP server ──────────────────────────────────────────────────────

(define mcp-server
  (make-xorg-mcp-server vat org
                         #:allow-eval? #t
                         #:allow-modify? #t
                         #:allow-history? #t
                         #:allow-bindings? #t))

;;; ── Optionally set up nonce registry for multi-server ─────────────────────

(receive (registry locator)
  (make-mcp-registry vat)
  ;; Register the default server so it's also addressable by swiss-num
  (let ((swiss-num (with-vat vat ($ registry 'register mcp-server))))
    (format (current-error-port)
            "MCP server registered at /mcp/~a\n" swiss-num)

    ;; ── Start HTTP server ────────────────────────────────────────────────
    (run-mcp-http-server mcp-server vat
                          #:port port
                          #:locator locator)))
