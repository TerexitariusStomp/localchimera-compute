;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/doors/mcp.scm — the doors as an MCP server
;;;
;;; POST /api/mcp speaks the Model Context Protocol over its HTTP transport:
;;; one JSON-RPC 2.0 request per POST, one JSON-RPC response per reply. The
;;; tools are the doors with an HTTP form, exactly the list
;;; browser/api/mcp-tools.json carries ((playnet protocol mcp) builds both), and
;;; `tools/call` admits and makes the call the way POST /api/<object>/<name>
;;; does: the same RFC 9421 device signature over the request (path /api/mcp,
;;; the whole JSON-RPC body under Content-Digest), the same allowlist, the
;;; same argument shaping. An anonymous door needs no signature here either.
;;;
;;; Methods: initialize, notifications/initialized (202, no body), ping,
;;; tools/list, tools/call. A door's refusal (401, 403, 400, 503) is a
;;; JSON-RPC error with that HTTP status; a door that answers `(error …)`
;;; is a tool result with isError, as the protocol asks, so an agent reads
;;; the reason instead of a transport failure.

(define-module (playnet doors mcp)
  #:use-module (playnet doors protocol)
  #:use-module (playnet protocol shapes)
  #:use-module (playnet protocol mcp)
  #:use-module ((playnet doors http)
                #:select (admit-and-call parse-json-object value->json))
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (%mcp-path handle-mcp-request))

(define %mcp-path "/api/mcp")

;; The protocol's own structures are JSON-shaped already (alists for objects,
;; vectors for arrays, '() the empty object), so they go to the encoder as
;; they are; only a door's reply passes through value->json (tool-result).
(define (json-response code value)
  (values (build-response #:code code
                          #:headers '((content-type . (application/json))))
          (string-append (scm->json-string value) "\n")))

(define (rpc-result id result) `((jsonrpc . "2.0") (id . ,id) (result . ,result)))
(define (rpc-error id code message . data)
  `((jsonrpc . "2.0") (id . ,id)
    (error . ((code . ,code) (message . ,message)
              ,@(if (null? data) '() `((data . ,(car data))))))))

;; JSON-RPC's reserved codes, and the door's refusals mapped onto the
;; server-error range so a client can tell them apart
(define %parse-error -32700)
(define %invalid-request -32600)
(define %method-not-found -32601)
(define %invalid-params -32602)
(define (door-error-code http) (- -32000 (quotient http 100)))   ; 401 → -32004, 403 → -32004, 400 → -32004, 503 → -32005

(define (aref alist key) (let ((p (assoc key alist))) (and p (cdr p))))

(define (door-reply-error? reply)
  "A door said (error …) or ((error . …)): the call ran and refused."
  (or (and (pair? reply) (eq? (car reply) 'error))
      (and (pair? reply) (pair? (car reply)) (eq? (caar reply) 'error))))

(define (tool-result door reply)
  (let ((json (value->json reply)))
    `((content . ,(vector `((type . "text") (text . ,(scm->json-string json)))))
      (structuredContent . ((door . ,(tool-name door)) (reply . ,json)))
      (isError . ,(door-reply-error? reply)))))

(define (initialize-result)
  `((protocolVersion . ,%mcp-protocol-version)
    (capabilities . ((tools . ((listChanged . #f)))))
    (serverInfo . ,(mcp-server-info))
    (instructions . "Every tool is a playnet gateway door, named object.name. Tools whose door needs a seat are signed like the HTTP door: RFC 9421 over this request with an enrolled device key (Signify-Resource, Signify-Timestamp, Content-Digest, Signature-Input, Signature). Anonymous doors need nothing. Doors are grouped by topic; the tool description names it.")))

(define* (handle-mcp-request request body-bv #:key target call (now #f))
  "Answer one MCP request. TARGET and CALL are the HTTP door's: (object
person-aid-or-#f) → a Goblins ref, and (ref name args) → the settled reply."
  (let* ((method (request-method request))
         (path (uri-path (request-uri request)))
         (headers (request-headers request))
         (body-bv (or body-bv (make-bytevector 0)))
         (msg (parse-json-object body-bv)))
    (cond
     ((not (eq? method 'POST))
      (json-response 405 (rpc-error 'null %invalid-request "the MCP door answers POST")))
     ((eq? msg 'bad)
      (json-response 400 (rpc-error 'null %parse-error "body is not a JSON-RPC object")))
     ((not (equal? (aref msg "jsonrpc") "2.0"))
      (json-response 400 (rpc-error (or (aref msg "id") 'null) %invalid-request "jsonrpc must be \"2.0\"")))
     (else
      (let ((id (aref msg "id")) (rpc (aref msg "method")) (params (or (aref msg "params") '())))
        (cond
         ((equal? rpc "notifications/initialized")
          (values (build-response #:code 202) ""))
         ((not id)                                   ; any other notification: accepted, nothing to say
          (values (build-response #:code 202) ""))
         ((equal? rpc "initialize") (json-response 200 (rpc-result id (initialize-result))))
         ((equal? rpc "ping") (json-response 200 (rpc-result id '())))
         ((equal? rpc "tools/list") (json-response 200 (rpc-result id `((tools . ,(mcp-tools))))))
         ((equal? rpc "tools/call")
          (let* ((name (aref params "name"))
                 (door (and (string? name) (tool-name->door name)))
                 (arguments (or (aref params "arguments") '())))
            (cond
             ((not door)
              (json-response 200 (rpc-error id %invalid-params (format #f "no such tool: ~a" name))))
             ((not (door-http? door))
              (json-response 200 (rpc-error id %invalid-params
                                            (format #f "~a is not callable over HTTP (auth ~a)" name (door-auth door)))))
             ((not (list? arguments))
              (json-response 200 (rpc-error id %invalid-params "arguments must be an object")))
             (else
              (let ((r (admit-and-call door arguments headers method path body-bv
                                       #:target target #:call call #:now now)))
                (if (= (car r) 200)
                    (json-response 200 (rpc-result id (tool-result door (aref (cdr r) 'reply))))
                    (json-response (car r) (rpc-error id (door-error-code (car r))
                                                      (value->json (aref (cdr r) 'error))
                                                      `((http . ,(car r)))))))))))
         (else (json-response 200 (rpc-error id %method-not-found (format #f "no such method: ~a" rpc))))))))))
