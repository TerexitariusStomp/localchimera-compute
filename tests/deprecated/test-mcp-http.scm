;;; test-mcp-http.scm — Tests for MCP HTTP transport
;;; Run with: guile -L module tests/test-mcp-http.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib nonce-registry)
             (xorg mcp)
             (xorg mcp-http)
             (xorg mcp-stdio)
             (xorg org)
             (xorg gplay)
             (json)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 receive)
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

(display "\n══ MCP HTTP Transport Tests ════════════════════════════════════\n")

;;; ── Setup ───────────────────────────────────────────────────────────────────

(define org (make-open-org "test-http"))
(define vat (org-vat org))

(define mcp-server
  (make-xorg-mcp-server vat org
                         #:allow-eval? #t
                         #:allow-modify? #t
                         #:allow-history? #t
                         #:allow-bindings? #t))

;;; ── Helper: build mock HTTP requests ────────────────────────────────────────
;;; Guile's build-request for POST needs an I/O #:port or content-length.
;;; We disable header validation for test simplicity.

(define (make-post-request path body-string)
  "Build a mock HTTP POST request + body for testing the handler."
  (let ((body-bv (string->utf8 body-string)))
    (values (build-request (build-uri 'http
                                       #:host "localhost"
                                       #:port 8080
                                       #:path path)
                            #:method 'POST
                            #:headers `((content-type . (application/json)))
                            #:port (open-input-string "")
                            #:validate-headers? #f)
            body-bv)))

(define (make-get-request path)
  "Build a mock HTTP GET request."
  (values (build-request (build-uri 'http
                                     #:host "localhost"
                                     #:port 8080
                                     #:path path)
                          #:method 'GET
                          #:validate-headers? #f)
          #f))

(define (make-options-request path)
  "Build a mock HTTP OPTIONS request."
  (values (build-request (build-uri 'http
                                     #:host "localhost"
                                     #:port 8080
                                     #:path path)
                          #:method 'OPTIONS
                          #:validate-headers? #f)
          #f))

;;; ── Create handler ──────────────────────────────────────────────────────────

(define handler (make-mcp-http-handler mcp-server vat))

(define (call-handler method-fn path . body-args)
  "Call the handler with a mock request, return (values response body-string)."
  (receive (request body)
    (apply method-fn path body-args)
    (receive (response response-body)
      (handler request body)
      (values response
              (if (string? response-body)
                  response-body
                  (utf8->string response-body))))))

;;; ── Test 1: Health check ────────────────────────────────────────────────────

(display "\n── 1. Health check ──\n")

(receive (response body)
  (call-handler make-get-request "/health")
  (check "health returns 200"
         (response-code response) 200)
  (check "health body is ok"
         body "ok"))

;;; ── Test 2: CORS preflight ─────────────────────────────────────────────────

(display "\n── 2. CORS preflight ──\n")

(receive (response body)
  (call-handler make-options-request "/mcp")
  (check "OPTIONS returns 204"
         (response-code response) 204))

;;; ── Test 3: POST /mcp — initialize ─────────────────────────────────────────

(display "\n── 3. POST /mcp — initialize ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "initialize")
                         ("id" . 1))))
  (check "initialize returns 200"
         (response-code response) 200)
  (let* ((json (json-string->scm body))
         (result (assoc-ref json "result")))
    (check "protocol version"
           (assoc-ref result "protocolVersion") "2025-03-26")
    (check "server name"
           (assoc-ref (assoc-ref result "serverInfo") "name") "xorg-mcp")))

;;; ── Test 4: POST /mcp — tools/list ─────────────────────────────────────────

(display "\n── 4. POST /mcp — tools/list ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "tools/list")
                         ("id" . 2))))
  (check "tools/list returns 200"
         (response-code response) 200)
  (let* ((json (json-string->scm body))
         (result (assoc-ref json "result"))
         (tools (vector->list (assoc-ref result "tools")))
         (names (map (lambda (t) (assoc-ref t "name")) tools)))
    (check "has 4 tools"
           (length tools) 4)
    (check "has xorg-eval"
           (member "xorg-eval" names) (member "xorg-eval" names))))

;;; ── Test 5: POST /mcp — tools/call eval ────────────────────────────────────

(display "\n── 5. POST /mcp — tools/call eval ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "tools/call")
                         ("id" . 3)
                         ("params" . (("name" . "xorg-eval")
                                      ("arguments" . (("expression" . "(* 6 7)"))))))))
  (check "eval returns 200"
         (response-code response) 200)
  (let* ((json (json-string->scm body))
         (result (assoc-ref json "result"))
         (content (vector->list (assoc-ref result "content")))
         (text (assoc-ref (car content) "text")))
    (check "eval (* 6 7) returns 42"
           text "42")))

;;; ── Test 6: POST /mcp — notification (no response body) ────────────────────

(display "\n── 6. POST /mcp — notification ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "notifications/initialized"))))
  (check "notification returns 204"
         (response-code response) 204))

;;; ── Test 7: POST /mcp — error (unknown tool) ───────────────────────────────

(display "\n── 7. POST /mcp — error ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "tools/call")
                         ("id" . 4)
                         ("params" . (("name" . "bad-tool")
                                      ("arguments" . ()))))))
  (check "error returns 200 (JSON-RPC error inside body)"
         (response-code response) 200)
  (let* ((json (json-string->scm body))
         (result (assoc-ref json "result")))
    (check "error has isError flag"
           (assoc-ref result "isError") #t)))

;;; ── Test 8: POST /mcp — malformed JSON ─────────────────────────────────────

(display "\n── 8. POST /mcp — malformed JSON ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp" "not json at all {{{")
  (check "malformed returns 200 (JSON-RPC parse error)"
         (response-code response) 200)
  (let* ((json (json-string->scm body))
         (err (assoc-ref json "error")))
    (check "error code is -32700"
           (assoc-ref err "code") -32700)))

;;; ── Test 9: 404 for unknown paths ──────────────────────────────────────────

(display "\n── 9. 404 for unknown paths ──\n")

(receive (response body)
  (call-handler make-get-request "/nonexistent")
  (check "unknown path returns 404"
         (response-code response) 404))

;;; ── Test 10: Nonce registry — register and fetch via /mcp/<swiss-num> ──────

(display "\n── 10. Nonce registry addressing ──\n")

(receive (registry locator)
  (make-mcp-registry vat)
  ;; Register the MCP server — swiss-num is a bytevector
  (let* ((swiss-num (with-vat vat ($ registry 'register mcp-server)))
         (hex-id (bv->hex-string swiss-num)))
    (check "swiss-num is a bytevector"
           (bytevector? swiss-num) #t)
    (check "hex-id is a string"
           (string? hex-id) #t)

    ;; Create a handler with locator
    (let ((registry-handler (make-mcp-http-handler mcp-server vat
                                                    #:locator locator)))
      ;; Request to /mcp/<hex-encoded-swiss-num>
      (receive (request body)
        (make-post-request (string-append "/mcp/" hex-id)
          (scm->json-string '(("jsonrpc" . "2.0")
                               ("method" . "ping")
                               ("id" . 10))))
        (receive (response response-body)
          (registry-handler request body)
          (let* ((body-str (if (string? response-body)
                               response-body
                               (utf8->string response-body)))
                 (json (json-string->scm body-str)))
            (check "registry ping returns id 10"
                   (assoc-ref json "id") 10))))

      ;; Request to /mcp/<bad-hex> should 404
      (receive (request body)
        (make-post-request "/mcp/deadbeef"
          (scm->json-string '(("jsonrpc" . "2.0")
                               ("method" . "ping")
                               ("id" . 11))))
        (receive (response response-body)
          (registry-handler request body)
          (check "bad swiss-num returns 404"
                 (response-code response) 404))))))

;;; ── Test 11: Modify via HTTP then read back ─────────────────────────────────

(display "\n── 11. Modify via HTTP then read back ──\n")

;; Modify
(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "tools/call")
                         ("id" . 12)
                         ("params" . (("name" . "xorg-modify")
                                      ("arguments" . (("name" . "http-test")
                                                      ("value" . "42"))))))))
  (check "modify returns 200"
         (response-code response) 200))

;; Read back via eval
(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "tools/call")
                         ("id" . 13)
                         ("params" . (("name" . "xorg-eval")
                                      ("arguments" . (("expression" . "http-test"))))))))
  (let* ((json (json-string->scm body))
         (result (assoc-ref json "result"))
         (content (vector->list (assoc-ref result "content")))
         (text (assoc-ref (car content) "text")))
    (check "eval reads back modified value"
           text "42")))

;;; ── Test 12: CORS headers on JSON response ──────────────────────────────────

(display "\n── 12. CORS headers ──\n")

(receive (response body)
  (call-handler make-post-request "/mcp"
    (scm->json-string '(("jsonrpc" . "2.0")
                         ("method" . "ping")
                         ("id" . 14))))
  (let ((headers (response-headers response)))
    (check "has access-control-allow-origin"
           (assoc-ref headers 'access-control-allow-origin) "*")))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(newline)
(display "══════════════════════════════════════════════════════════════════\n")
(format #t "  ~a passed, ~a failed\n" pass-count fail-count)
(display "══════════════════════════════════════════════════════════════════\n")

(when (> fail-count 0)
  (exit 1))
