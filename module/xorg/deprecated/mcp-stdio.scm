;;; module/xorg/mcp-stdio.scm — MCP JSON-RPC over stdio transport
;;;
;;; Thin translation layer: stdin/stdout ↔ ^mcp-server actor.
;;; No business logic here — the actors in mcp.scm do all real work.
;;;
;;; MCP protocol: JSON-RPC 2.0 over newline-delimited stdio.
;;; Reference: https://modelcontextprotocol.io/specification/2025-03-26

(define-module (xorg mcp-stdio)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (xorg mcp)
  #:use-module (json)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (run-mcp-stdio-server
            mcp-jsonrpc-dispatch
            tool-schema->mcp-json
            make-jsonrpc-response
            make-jsonrpc-error))

;;; ── JSON-RPC helpers ──────────────────────────────────────────────────────

(define (make-jsonrpc-response id result)
  "Build a JSON-RPC 2.0 success response."
  `(("jsonrpc" . "2.0")
    ("id" . ,id)
    ("result" . ,result)))

(define (make-jsonrpc-error id code message)
  "Build a JSON-RPC 2.0 error response."
  `(("jsonrpc" . "2.0")
    ("id" . ,id)
    ("error" . (("code" . ,code)
                ("message" . ,message)))))

;;; ── Tool schema conversion ────────────────────────────────────────────────

(define (tool-schema->mcp-json schema)
  "Convert a ^tool-cap schema alist to MCP tools/list JSON format.
   Input:  ((name . \"xorg-eval\") (description . \"...\") (read-only . #f))
   Output: MCP tool object with inputSchema.
   Note: ^tool-cap schema uses symbol keys."
  (let ((name (assoc-ref schema 'name))
        (desc (assoc-ref schema 'description)))
    `(("name" . ,name)
      ("description" . ,desc)
      ("inputSchema"
       . (("type" . "object")
          ("properties" . ,(tool-input-properties name)))))))

(define (tool-input-properties tool-name)
  "Return the inputSchema properties for a known tool.
   Each tool has its own expected parameters."
  (match tool-name
    ("xorg-eval"
     `(("expression"
        . (("type" . "string")
           ("description" . "Scheme expression to evaluate in the org")))))
    ("xorg-modify"
     `(("name"
        . (("type" . "string")
           ("description" . "Binding name to set")))
       ("value"
        . (("type" . "string")
           ("description" . "Value as a Scheme expression string")))))
    ("xorg-history"
     `(("count"
        . (("type" . "integer")
           ("description" . "Number of recent history entries to return (default 10)")))))
    ("xorg-bindings" `())
    ("xorg-query-kb"
     `(("query"
        . (("type" . "string")
           ("description" . "miniKanren query expression")))))
    ;; Unknown tools get a generic pass-through schema
    (_
     `(("args"
        . (("type" . "object")
           ("description" . "Tool arguments")))))))

;;; ── MCP dispatch ──────────────────────────────────────────────────────────

(define (mcp-jsonrpc-dispatch msg mcp-server vat)
  "Dispatch a parsed JSON-RPC message to the ^mcp-server actor.
   Returns a JSON-RPC response alist, or #f for notifications (no response)."
  (let ((method (assoc-ref msg "method"))
        (id     (assoc-ref msg "id"))
        (params (or (assoc-ref msg "params") '())))
    (match method
      ;; ── Initialize handshake
      ("initialize"
       (make-jsonrpc-response id
         `(("protocolVersion" . "2025-03-26")
           ("capabilities"
            . (("tools" . (("listChanged" . #f)))))
           ("serverInfo"
            . (("name" . "xorg-mcp")
               ("version" . "0.1.0"))))))

      ;; ── Initialized notification (no response)
      ("notifications/initialized" #f)

      ;; ── Ping
      ("ping"
       (make-jsonrpc-response id '()))

      ;; ── List tools
      ("tools/list"
       (let ((schemas (with-vat vat ($ mcp-server 'list-tools))))
         (make-jsonrpc-response id
           `(("tools" . ,(list->vector
                          (map tool-schema->mcp-json schemas)))))))

      ;; ── Call tool
      ;; Note: we extract only "name" and "arguments" from params.
      ;; Extra fields like "_meta" (progressToken etc.) are ignored —
      ;; this is the #:allow-other-keys pattern from Mandy, applied at
      ;; the JSON level. Forward-compatible with future MCP spec fields.
      ("tools/call"
       (let ((tool-name (assoc-ref params "name"))
             (arguments (or (assoc-ref params "arguments") '())))
         (catch #t
           (lambda ()
             (let ((result (with-vat vat
                             ($ mcp-server 'call tool-name arguments))))
               (make-jsonrpc-response id
                 `(("content"
                    . ,(vector
                        `(("type" . "text")
                          ("text" . ,(if (string? result)
                                         result
                                         (format #f "~s" result))))))))))
           (lambda (key . args)
             (make-jsonrpc-response id
               `(("content"
                  . ,(vector
                      `(("type" . "text")
                        ("text" . ,(format #f "Error: ~a ~a" key args)))))
                 ("isError" . #t)))))))

      ;; ── Unknown method
      (_
       (if id
           (make-jsonrpc-error id -32601
             (string-append "Method not found: " (or method "")))
           #f)))))

;;; ── stdio server loop ─────────────────────────────────────────────────────

(define* (run-mcp-stdio-server mcp-server vat
                               #:key
                               (input-port (current-input-port))
                               (output-port (current-output-port)))
  "Run the MCP stdio transport loop.
   Reads newline-delimited JSON-RPC from INPUT-PORT,
   dispatches to MCP-SERVER actor in VAT,
   writes JSON-RPC responses to OUTPUT-PORT.

   Loops until EOF on input."
  ;; Disable buffering on output for immediate delivery
  (setvbuf output-port 'none)
  (let loop ()
    (let ((line (read-line input-port)))
      (unless (eof-object? line)
        (unless (string-null? (string-trim-both line))
          (catch #t
            (lambda ()
              (let* ((msg (json-string->scm line))
                     (response (mcp-jsonrpc-dispatch msg mcp-server vat)))
                ;; Notifications return #f — no response sent
                (when response
                  (put-string output-port (scm->json-string response))
                  (newline output-port)
                  (force-output output-port))))
            (lambda (key . args)
              ;; Parse error — send JSON-RPC error
              (let ((err (make-jsonrpc-error
                          #nil -32700
                          (format #f "Parse error: ~a ~a" key args))))
                (put-string output-port (scm->json-string err))
                (newline output-port)
                (force-output output-port)))))
        (loop)))))
