;;; test-mcp-stdio.scm — Tests for MCP stdio transport
;;; Run with: guile -L module tests/test-mcp-stdio.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (goblins)
             (goblins actor-lib methods)
             (xorg mcp)
             (xorg mcp-stdio)
             (xorg org)
             (xorg gplay)
             (json)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ── Harness ─────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define-syntax check-error
  (syntax-rules ()
    ((_ label body ...)
     (check label
            (catch #t
              (lambda () body ... #f)
              (lambda (key . args) #t))
            #t))))

(display "\n══ MCP stdio Transport Tests ═══════════════════════════════════\n")

;;; ── Setup: create org + MCP server ──────────────────────────────────────────

(define org (make-open-org "test-stdio"))
(define vat (org-vat org))

(define mcp-server
  (make-xorg-mcp-server vat org
                         #:allow-eval? #t
                         #:allow-modify? #t
                         #:allow-history? #t
                         #:allow-bindings? #t))

;;; ── Helper: dispatch a JSON-RPC message and get parsed response ─────────────

(define (dispatch-json method params id)
  "Build a JSON-RPC message, dispatch it, return parsed response."
  (let ((msg `(("jsonrpc" . "2.0")
               ("method" . ,method)
               ,@(if id `(("id" . ,id)) '())
               ,@(if params `(("params" . ,params)) '()))))
    (mcp-jsonrpc-dispatch msg mcp-server vat)))

;;; ── Test 1: Initialize handshake ────────────────────────────────────────────

(display "\n── 1. Initialize handshake ──\n")

(let ((resp (dispatch-json "initialize" '() 1)))
  (check "response has jsonrpc 2.0"
         (assoc-ref resp "jsonrpc") "2.0")
  (check "response has id 1"
         (assoc-ref resp "id") 1)
  (let ((result (assoc-ref resp "result")))
    (check "protocol version is 2025-03-26"
           (assoc-ref result "protocolVersion") "2025-03-26")
    (let ((info (assoc-ref result "serverInfo")))
      (check "server name is xorg-mcp"
             (assoc-ref info "name") "xorg-mcp"))))

;;; ── Test 2: Initialized notification returns #f ─────────────────────────────

(display "\n── 2. Initialized notification ──\n")

(let ((resp (dispatch-json "notifications/initialized" #f #f)))
  (check "notification returns #f (no response)"
         resp #f))

;;; ── Test 3: Ping ────────────────────────────────────────────────────────────

(display "\n── 3. Ping ──\n")

(let ((resp (dispatch-json "ping" #f 2)))
  (check "ping response has id 2"
         (assoc-ref resp "id") 2)
  (check "ping result is empty alist"
         (assoc-ref resp "result") '()))

;;; ── Test 4: tools/list ──────────────────────────────────────────────────────

(display "\n── 4. tools/list ──\n")

(let* ((resp (dispatch-json "tools/list" #f 3))
       (result (assoc-ref resp "result"))
       (tools (vector->list (assoc-ref result "tools")))
       (names (map (lambda (t) (assoc-ref t "name")) tools)))
  (check "response has id 3"
         (assoc-ref resp "id") 3)
  (check "has xorg-bindings tool"
         (member "xorg-bindings" names) (member "xorg-bindings" names))
  (check "has xorg-history tool"
         (member "xorg-history" names) (member "xorg-history" names))
  (check "has xorg-eval tool"
         (member "xorg-eval" names) (member "xorg-eval" names))
  (check "has xorg-modify tool"
         (member "xorg-modify" names) (member "xorg-modify" names))
  ;; Check tool has inputSchema
  (let ((eval-tool (find (lambda (t) (equal? (assoc-ref t "name") "xorg-eval"))
                         tools)))
    (check "xorg-eval has inputSchema"
           (pair? (assoc-ref eval-tool "inputSchema")) #t)
    (check "xorg-eval inputSchema has properties"
           (pair? (assoc-ref (assoc-ref eval-tool "inputSchema") "properties")) #t)))

;;; ── Test 5: tools/call — xorg-eval ─────────────────────────────────────────

(display "\n── 5. tools/call — xorg-eval ──\n")

(let* ((resp (dispatch-json "tools/call"
               `(("name" . "xorg-eval")
                 ("arguments" . (("expression" . "(+ 2 3)"))))
               4))
       (result (assoc-ref resp "result"))
       (content (vector->list (assoc-ref result "content")))
       (text (assoc-ref (car content) "text")))
  (check "eval (+ 2 3) returns 5"
         text "5"))

;;; ── Test 6: tools/call — xorg-modify then xorg-bindings ────────────────────

(display "\n── 6. tools/call — xorg-modify + xorg-bindings ──\n")

;; Modify
(let ((resp (dispatch-json "tools/call"
              `(("name" . "xorg-modify")
                ("arguments" . (("name" . "greeting")
                                ("value" . "\"hello world\""))))
              5)))
  (let* ((result (assoc-ref resp "result"))
         (content (vector->list (assoc-ref result "content")))
         (text (assoc-ref (car content) "text")))
    (check "modify returns ok"
           text "ok")))

;; Read bindings
(let* ((resp (dispatch-json "tools/call"
               `(("name" . "xorg-bindings")
                 ("arguments" . ()))
               6))
       (result (assoc-ref resp "result"))
       (content (vector->list (assoc-ref result "content")))
       (text (assoc-ref (car content) "text")))
  (check "bindings contain greeting"
         (string-contains text "greeting") (string-contains text "greeting")))

;;; ── Test 7: tools/call — xorg-history ───────────────────────────────────────

(display "\n── 7. tools/call — xorg-history ──\n")

(let* ((resp (dispatch-json "tools/call"
               `(("name" . "xorg-history")
                 ("arguments" . (("count" . 5))))
               7))
       (result (assoc-ref resp "result"))
       (content (vector->list (assoc-ref result "content")))
       (text (assoc-ref (car content) "text")))
  (check "history returns non-empty string"
         (> (string-length text) 2) #t))

;;; ── Test 8: tools/call — unknown tool error ─────────────────────────────────

(display "\n── 8. tools/call — unknown tool error ──\n")

(let* ((resp (dispatch-json "tools/call"
               `(("name" . "nonexistent-tool")
                 ("arguments" . ()))
               8))
       (result (assoc-ref resp "result")))
  (check "error response has isError flag"
         (assoc-ref result "isError") #t))

;;; ── Test 9: Unknown method ──────────────────────────────────────────────────

(display "\n── 9. Unknown method ──\n")

(let ((resp (dispatch-json "unknown/method" #f 9)))
  (check "returns error response"
         (pair? (assoc-ref resp "error")) #t)
  (check "error code is -32601"
         (assoc-ref (assoc-ref resp "error") "code") -32601))

;;; ── Test 10: Full stdio round-trip with string ports ────────────────────────

(display "\n── 10. Full stdio round-trip ──\n")

(let* ((request (scm->json-string
                 '(("jsonrpc" . "2.0")
                   ("method" . "tools/list")
                   ("id" . 10))))
       (input-port (open-input-string (string-append request "\n")))
       (output-port (open-output-string)))
  (run-mcp-stdio-server mcp-server vat
                        #:input-port input-port
                        #:output-port output-port)
  (let* ((output (get-output-string output-port))
         (lines (string-split (string-trim-right output) #\newline))
         (response (json-string->scm (car lines))))
    (check "stdio round-trip: response has id 10"
           (assoc-ref response "id") 10)
    (check "stdio round-trip: result has tools"
           (vector? (assoc-ref (assoc-ref response "result") "tools")) #t)))

;;; ── Test 11: Multiple messages in sequence ──────────────────────────────────

(display "\n── 11. Multiple messages in sequence ──\n")

(let* ((msg1 (scm->json-string
              '(("jsonrpc" . "2.0") ("method" . "initialize") ("id" . 11))))
       (msg2 (scm->json-string
              '(("jsonrpc" . "2.0") ("method" . "notifications/initialized"))))
       (msg3 (scm->json-string
              '(("jsonrpc" . "2.0") ("method" . "ping") ("id" . 12))))
       (input-port (open-input-string
                    (string-append msg1 "\n" msg2 "\n" msg3 "\n")))
       (output-port (open-output-string)))
  (run-mcp-stdio-server mcp-server vat
                        #:input-port input-port
                        #:output-port output-port)
  (let* ((output (get-output-string output-port))
         (lines (filter (lambda (s) (not (string-null? s)))
                        (string-split (string-trim-right output) #\newline))))
    ;; Should get 2 responses (initialize + ping), not 3 (notification is silent)
    (check "got 2 response lines (notification is silent)"
           (length lines) 2)
    (let ((r1 (json-string->scm (first lines)))
          (r2 (json-string->scm (second lines))))
      (check "first response is initialize (id 11)"
             (assoc-ref r1 "id") 11)
      (check "second response is ping (id 12)"
             (assoc-ref r2 "id") 12))))

;;; ── Test 12: tool-schema->mcp-json conversion ──────────────────────────────

(display "\n── 12. tool-schema->mcp-json conversion ──\n")

(let ((mcp-json (tool-schema->mcp-json
                 '((name . "xorg-eval")
                   (description . "Evaluate Scheme")
                   (read-only . #f)))))
  (check "has name"
         (assoc-ref mcp-json "name") "xorg-eval")
  (check "has description"
         (assoc-ref mcp-json "description") "Evaluate Scheme")
  (check "has inputSchema"
         (pair? (assoc-ref mcp-json "inputSchema")) #t)
  (check "inputSchema has expression property"
         (pair? (assoc-ref (assoc-ref (assoc-ref mcp-json "inputSchema")
                                       "properties")
                            "expression"))
         #t))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(newline)
(display "══════════════════════════════════════════════════════════════════\n")
(format #t "  ~a passed, ~a failed\n" pass-count fail-count)
(display "══════════════════════════════════════════════════════════════════\n")

(when (> fail-count 0)
  (exit 1))
