;;; test-bearer-endpoint.scm — the generic sealed OAuth2 bearer client.
;;;
;;; Reusable for ANY Graph/REST bearer API (Instagram, Threads, X v2, Bluesky, …).
;;; Proves get / post-json / post-form and — the opsec point — HEADLESS token
;;; refresh: after (refresh!), the rotated token is used with no human involved.
;;;
;;; Run: guile -L module tests/playnet/test-bearer-endpoint.scm

(use-modules (playnet test harness)
             (playnet interface adapters bearer-endpoint)
             (goblins) (goblins vat)
             (web server) (web response) (web request) (web uri)
             (json) (rnrs bytevectors) (ice-9 format))

(define %path #f) (define %body #f) (define %auth #f)
(define (handle-request request body)
  (set! %path (uri-path (request-uri request)))
  (set! %body (if (bytevector? body) (utf8->string body) (or body "")))
  (set! %auth (assq-ref (request-headers request) 'authorization))
  (values (build-response #:code 200)
          (scm->json-string `(("id" . "created") ("echo" . ,%body)))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(define vat (spawn-vat))

(display "\n── the generic client: get / post-json / post-form ──\n")
(with-vat vat
  (let ((ep (spawn ^bearer-endpoint %base "tok-A" #:refresh (lambda (_old) "tok-B"))))
    (let ((r ($ ep 'post-json "/api/x" '(("k" . "v")))))
      (check "post-json parses the JSON response" (assoc-ref r "id") "created")
      (check "post-json sent a JSON body" (assoc-ref (json-string->scm %body) "k") "v"))
    (check "the sealed token A is on the wire" (and (string-contains %auth "tok-A") #t) #t)

    ($ ep 'post-form "/f" '(("a" . "hello world")))
    (check "post-form x-www-form-urlencodes the params" %body "a=hello%20world")

    ($ ep 'get "/me")
    (check "get hits the requested path" %path "/me")

    ;; ── the opsec point: headless token rotation ──
    (display "\n── refresh! rotates the sealed token with no human ──\n")
    (check "refresh! reports ok" (assq-ref ($ ep 'refresh!) 'ok) #t)
    ($ ep 'get "/after")
    (check "after refresh the NEW token B is used automatically"
           (and (string-contains %auth "tok-B") #t) #t)
    (check "a client with no refresh configured declines cleanly"
           (assq-ref ($ (spawn ^bearer-endpoint %base "t") 'refresh!) 'ok) #f)))

(display "\n")
(test-summary!)
