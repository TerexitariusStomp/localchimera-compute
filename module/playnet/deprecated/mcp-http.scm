;;; module/playnet/mcp-http.scm — MCP JSON-RPC over HTTP transport
;;;
;;; Applies the Mandy/ActivityPub-on-Goblins pattern:
;;;   HTTP request → handler fiber → with-vat dispatch → ^mcp-server → response
;;;
;;; Uses Guile's (web server) with fibers for concurrent request handling.
;;; Pattern-matching router on URI path segments (not string DSL).
;;;
;;; Reference: https://modelcontextprotocol.io/specification/2025-03-26

(define-module (playnet mcp-http)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib nonce-registry)
  #:use-module (playnet mcp)
  #:use-module (playnet mcp-stdio)
  #:use-module (json)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (fibers)
  #:export (run-mcp-http-server
            make-mcp-http-handler
            make-mcp-registry
            bv->hex-string
            hex-string->bv))

;;; ── Bytevector ↔ hex string (for URL-safe swiss-nums) ─────────────────────

(define (bv->hex-string bv)
  "Convert a bytevector to a lowercase hex string."
  (let ((len (bytevector-length bv)))
    (let loop ((i 0) (acc '()))
      (if (= i len)
          (apply string-append (reverse acc))
          (loop (+ i 1)
                (cons (let ((b (bytevector-u8-ref bv i)))
                        (string-append
                         (if (< b 16) "0" "")
                         (number->string b 16)))
                      acc))))))

(define (hex-string->bv str)
  "Convert a hex string to a bytevector."
  (let* ((len (string-length str))
         (bv (make-bytevector (/ len 2))))
    (let loop ((i 0))
      (if (>= i len)
          bv
          (begin
            (bytevector-u8-set! bv (/ i 2)
              (string->number (substring str i (+ i 2)) 16))
            (loop (+ i 2)))))))

;;; ── Nonce registry for addressable MCP servers ────────────────────────────
;;; Each ^mcp-server gets a swiss-num. Multiple servers (with different tool
;;; sets) are addressable at /mcp/<swiss-num>. A default server is optional.

(define (make-mcp-registry vat)
  "Create a nonce registry for MCP server addressability.
   Returns (values registry locator) — both are actor refs.
   Register: (with-vat vat ($ registry 'register mcp-server)) → swiss-num
   Fetch:    (with-vat vat ($ locator 'fetch swiss-num)) → mcp-server ref"
  (with-vat vat
    (spawn-nonce-registry-and-locator)))

;;; ── HTTP response builders ────────────────────────────────────────────────

(define (json-response body-alist)
  "Build an HTTP 200 response with JSON content-type."
  (values (build-response
           #:headers `((content-type . (application/json))
                       (access-control-allow-origin . "*")
                       (access-control-allow-headers . "Content-Type")))
          (scm->json-string body-alist)))

(define (json-error-response code message)
  "Build an HTTP error response with JSON body."
  (values (build-response
           #:code code
           #:headers `((content-type . (application/json))
                       (access-control-allow-origin . "*")))
          (scm->json-string
           `(("error" . ,message)))))

(define (text-response text)
  "Build a plain text 200 response."
  (values (build-response
           #:headers `((content-type . (text/plain))))
          text))

(define (options-response)
  "CORS preflight response."
  (values (build-response
           #:code 204
           #:headers `((access-control-allow-origin . "*")
                       (access-control-allow-methods . "POST, GET, OPTIONS")
                       (access-control-allow-headers . "Content-Type")
                       (access-control-max-age . "86400")))
          ""))

;;; ── HTTP handler (Mandy pattern: match on path segments) ──────────────────

(define* (make-mcp-http-handler mcp-server vat
                                 #:key
                                 (locator #f))
  "Build an HTTP request handler that dispatches to MCP-SERVER.

   Routes (pattern-matched, not string DSL):
     POST /mcp           → JSON-RPC dispatch to default server
     POST /mcp/<id>      → JSON-RPC dispatch to registered server (via locator)
     GET  /health        → health check
     OPTIONS *           → CORS preflight

   If LOCATOR is provided, /mcp/<swiss-num> routes are enabled."

  (lambda (request body)
    (let ((method (request-method request))
          (path (uri-path (request-uri request))))
      (match (cons method (string-split path #\/))

        ;; ── CORS preflight
        (('OPTIONS . _)
         (options-response))

        ;; ── Health check
        (('GET "" "health")
         (text-response "ok"))

        ;; ── MCP endpoint (default server)
        (('POST "" "mcp")
         (handle-mcp-post request body mcp-server vat))

        ;; ── MCP endpoint (addressed by hex-encoded swiss-num via nonce registry)
        (('POST "" "mcp" hex-id)
         (if locator
             (catch #t
               (lambda ()
                 (let* ((swiss-num (hex-string->bv hex-id))
                        (server (with-vat vat ($ locator 'fetch swiss-num))))
                   (if server
                       (handle-mcp-post request body server vat)
                       (json-error-response 404 "MCP server not found"))))
               (lambda (key . args)
                 (json-error-response 404 "MCP server not found")))
             (json-error-response 404 "Registry not configured")))

        ;; ── Catch-all
        (_ (json-error-response 404 "Not found"))))))

(define (handle-mcp-post request body mcp-server vat)
  "Parse JSON-RPC from HTTP body, dispatch to MCP server, return response."
  (catch #t
    (lambda ()
      (let* ((body-str (if (bytevector? body)
                           (utf8->string body)
                           (or body "")))
             (msg (json-string->scm body-str))
             (response (mcp-jsonrpc-dispatch msg mcp-server vat)))
        (if response
            (json-response response)
            ;; Notification — no response body, but HTTP needs something
            (values (build-response
                     #:code 204
                     #:headers `((access-control-allow-origin . "*")))
                    ""))))
    (lambda (key . args)
      (json-response
       (make-jsonrpc-error #nil -32700
         (format #f "Parse error: ~a ~a" key args))))))

;;; ── Server startup ────────────────────────────────────────────────────────

(define* (run-mcp-http-server mcp-server vat
                               #:key
                               (port 8080)
                               (host "127.0.0.1")
                               (locator #f))
  "Start the MCP HTTP server.

   Runs inside (run-fibers ...) for concurrent request handling.
   Uses Guile's built-in web server.

   MCP-SERVER: ^mcp-server actor ref
   VAT: the vat containing the MCP server
   PORT: HTTP port (default 8080)
   HOST: bind address (default 127.0.0.1)
   LOCATOR: optional nonce-registry locator for multi-server addressing"

  (let ((handler (make-mcp-http-handler mcp-server vat
                                         #:locator locator)))
    (format (current-error-port)
            "playnet-mcp HTTP server listening on ~a:~a\n" host port)
    (run-server handler 'http
                `(#:host ,host #:port ,port))))
