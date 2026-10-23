;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/doors/test-mcp-door.scm — the doors as an MCP server at POST /api/mcp
;;;
;;; What this pins:
;;;   • initialize answers the protocol revision, the tools capability and the
;;;     server info; notifications/initialized is a 202 with no body; ping is {};
;;;   • tools/list is exactly the committed manifest's tool list — one tool per
;;;     HTTP-form door, each with an input schema and a topic;
;;;   • tools/call on an anonymous door needs no signature and returns the
;;;     door's reply as text content and structuredContent;
;;;   • tools/call on a device door carries the same RFC 9421 signature the
;;;     HTTP door takes, over /api/mcp and the JSON-RPC body: a good one reaches
;;;     the session, a tampered body is a JSON-RPC error carrying HTTP 401,
;;;     an allowlisted device outside its doors is 403;
;;;   • a door's own (error …) reply is a tool result with isError, never a
;;;     transport error; an unknown tool, a missing argument and an unknown
;;;     method are the JSON-RPC codes the protocol names.
;;;
;;; Run: guile -L module -L tests tests/doors/test-mcp-door.scm

(use-modules (playnet test harness)
             (playnet doors mcp)
             (playnet doors http)
             (playnet identity devices)
             (playnet doors protocol) (playnet protocol shapes) (playnet protocol mcp)
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair bran->rotation-keypair public-key->aid-prefix
                        build-icp next-key-digest seed->ed25519-keypair))
             ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes ed25519-keypair-public))
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             
             ((playnet keri first-person credentials) #:select (make-device-authorization-credential))
             (web request) (web response) (web uri)
             (rnrs bytevectors)
             (json) (ice-9 textual-ports)
             (srfi srfi-1))

;; ── a person, a device, an enrollment ─────────────────────────────────────
(define tmp (let ((d (string-append "/tmp/playnet-mcp-door-" (number->string (getpid)))))
              (mkdir d) d))
(device-registry-dir tmp)

(define bran "mcp-door-passcode-21charsX")
(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (next-key-digest (ed25519-keypair-public kp1)))))
(define person (assoc-ref icp-alist "i"))
(define (device-keypair) (seed->ed25519-keypair (keri-crypto-random-bytes 32)))
(define (device-aid kp) (cesr-bytes->qb64 "B" (ed25519-keypair-public kp)))
(define phone (device-keypair))
(define %now 1760000000)
(define cred (make-device-authorization-credential #:person-aid person
                                                   #:device-aid (device-aid phone)
                                                   #:label "phone"
                                                   #:tier "software"
                                                   #:enrolled-at %now
                                                   #:signing-keypair kp0))
(device-enroll! person cred %now)
(define narrow (device-keypair))
(device-enroll! person (make-device-authorization-credential #:person-aid person
                                                             #:device-aid (device-aid narrow)
                                                             #:label "bot"
                                                             #:tier "software"
                                                             #:enrolled-at %now
                                                             #:doors '("whoami")
                                                             #:signing-keypair kp0)
                %now)

;; ── stand-in objects and a synchronous call ───────────────────────────────
(define asked '())
(define (target object person-aid) (list 'ref object person-aid))
(define (call ref name args)
  (set! asked (cons (list ref name args) asked))
  (case name
    ((whoami) (caddr ref))
    ((who) '("ana" "bo"))
    ((my-skills) '("spec:carpentry"))
    ((declare-need) '(error "no such scope"))
    (else 'answered)))

(define (req body-string headers)
  (build-request (string->uri "http://localhost/api/mcp")
                 #:method 'POST
                 #:headers (cons '(content-type . (application/json)) headers)
                 #:port (open-input-string "")
                 #:validate-headers? #f))

(define (mcp body-string headers)
  "→ (code . parsed-json-or-#f)"
  (call-with-values
      (lambda () (handle-mcp-request (req body-string headers) (string->utf8 body-string)
                                     #:target target #:call call #:now %now))
    (lambda (response text)
      (cons (response-code response)
            (and (not (string-null? text)) (json-string->scm text))))))

(define counter 0)
(define (signed kp body-string)
  (set! counter (+ counter 1))
  (sign-door-request kp (device-aid kp) 'POST "/api/mcp" (string->utf8 body-string) #:now (+ %now counter)))

(define (aref a . ks)
  (let loop ((a a) (ks ks))
    (if (null? ks) a
        (let ((p (and (list? a) (assoc (car ks) a))))
          (and p (loop (cdr p) (cdr ks)))))))
(define (rpc method . params)
  (scm->json-string `((jsonrpc . "2.0") (id . 1) (method . ,method)
                      ,@(if (null? params) '() `((params . ,(car params)))))))

(display "\n── 1. the handshake ──\n")
(define init (mcp (rpc "initialize" '((protocolVersion . "2025-06-18") (capabilities . ()) (clientInfo . ((name . "t"))))) '()))
(check "initialize is 200" (= 200 (car init)))
(check "…with the protocol revision" (equal? %mcp-protocol-version (aref (cdr init) "result" "protocolVersion")))
(check-pred "…and the tools capability" (aref (cdr init) "result" "capabilities" "tools"))
(check "…and the server's name" (equal? "playnet gateway" (aref (cdr init) "result" "serverInfo" "name")))
(define inited (mcp "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" '()))
(check "notifications/initialized is 202 with no body" (and (= 202 (car inited)) (not (cdr inited))))
(check "ping answers an empty result" (equal? '() (aref (cdr (mcp (rpc "ping") '())) "result")))

(display "\n── 2. tools/list is the manifest ──\n")
(define listed (mcp (rpc "tools/list") '()))
(define tools (aref (cdr listed) "result" "tools"))
(check "one tool per HTTP-form door"
       (= (vector-length tools) (count door-http? %doors)))
(check "the tool names are object.name, in declaration order"
       (equal? (map tool-name (filter door-http? %doors))
               (map (lambda (t) (aref t "name")) (vector->list tools))))
(define who-tool (find (lambda (t) (equal? "lobby.who" (aref t "name"))) (vector->list tools)))
(check-pred "a tool carries an input schema" (aref who-tool "inputSchema" "type"))
(check-pred "…and its topic" (aref who-tool "x-playnet-topic"))
(check "the live list and the committed manifest agree"
       (equal? (json-string->scm (scm->json-string (mcp-tools)))
               (aref (json-string->scm (call-with-input-file "browser/api/mcp-tools.json"
                                         (lambda (p) (get-string-all p))))
                     "tools")))

(display "\n── 3. tools/call ──\n")
(define who (mcp (rpc "tools/call" '((name . "lobby.who") (arguments . ()))) '()))
(check "an anonymous door needs no signature" (= 200 (car who)))
(check "the reply is text content" (equal? "[\"ana\",\"bo\"]" (aref (vector-ref (aref (cdr who) "result" "content") 0) "text")))
(check "…and structuredContent" (equal? (vector "ana" "bo") (aref (cdr who) "result" "structuredContent" "reply")))
(check "…and no error" (eq? #f (aref (cdr who) "result" "isError")))

(define b1 (rpc "tools/call" '((name . "session.whoami") (arguments . ()))))
(define r1 (mcp b1 (signed phone b1)))
(check "a signed call reaches the person's session" (and (= 200 (car r1)) (equal? person (aref (cdr r1) "result" "structuredContent" "reply"))))
(check "the target was the session" (equal? (list 'ref 'session person) (car (car asked))))
(define b2 (rpc "tools/call" '((name . "session.whoami") (arguments . ()))))
(define r2 (mcp (string-append b2 " ") (signed phone b2)))
(check "a tampered body is refused with HTTP 401" (= 401 (car r2)))
(check "…as a JSON-RPC error naming the status" (equal? 401 (aref (cdr r2) "error" "data" "http")))
(check "an unsigned call to a device door is 401" (= 401 (car (mcp b1 '()))))
(define b3 (rpc "tools/call" '((name . "session.my-skills") (arguments . ((scope-id . "uc"))))))
(check "an allowlisted device outside its doors is 403" (= 403 (car (mcp b3 (signed narrow b3)))))
(define b4 (rpc "tools/call" '((name . "session.declare-need")
                               (arguments . ((scope-id . "uc") (spec . "spec:x") (qty . 1) (unit . "kg") (location . "h")
                                             (arcs-json . "[]") (note . "") (emoji . "") (from . "d") (until . "d"))))))
(define r4 (mcp b4 (signed phone b4)))
(check "a door's own (error …) is a tool result with isError"
       (and (= 200 (car r4)) (eq? #t (aref (cdr r4) "result" "isError"))))
(define b5 (rpc "tools/call" '((name . "session.declare-need") (arguments . ((spec . "x"))))))
(define r5 (mcp b5 (signed phone b5)))
(check "a missing required argument is 400 with the JSON-RPC error" (and (= 400 (car r5)) (aref (cdr r5) "error" "message")))

(display "\n── 4. the protocol's own refusals ──\n")
(check "an unknown tool is invalid params"
       (equal? -32602 (aref (cdr (mcp (rpc "tools/call" '((name . "lobby.no-such") (arguments . ()))) '())) "error" "code")))
(check "a root door is not a tool"
       (equal? -32602 (aref (cdr (mcp (rpc "tools/call" '((name . "session.rotate-aid") (arguments . ()))) '())) "error" "code")))
(check "an unknown method is method-not-found"
       (equal? -32601 (aref (cdr (mcp (rpc "resources/list") '())) "error" "code")))
(check "a body that is not JSON is a parse error"
       (equal? -32700 (aref (cdr (mcp "nope" '())) "error" "code")))
(check "a wrong jsonrpc version is an invalid request"
       (equal? -32600 (aref (cdr (mcp "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}" '())) "error" "code")))

(test-summary!)
