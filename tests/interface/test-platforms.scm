;;; test-platforms.scm — X / Bluesky / Threads as config rows over the substrate.
;;;
;;; Proves the three new platforms work through their real API shapes (against
;;; mocks): X's nested `.data.id`, Bluesky's nested record + `.uri`, and Threads'
;;; two-step text publish. Each is a one-line config over the generic strategies —
;;; no bespoke module.
;;;
;;; Run: guile -L module tests/interface/test-platforms.scm

(use-modules (playnet test harness)
             (playnet interface adapters platforms)
             (goblins) (goblins vat)
             (web server) (web response) (web request) (web uri)
             (json) (rnrs bytevectors) (ice-9 format))

(define %path #f) (define %body #f) (define %steps '())
(define (handle-request request body)
  (let ((path (uri-path (request-uri request)))
        (s (if (bytevector? body) (utf8->string body) (or body ""))))
    (set! %path path) (set! %body s) (set! %steps (cons path %steps))
    (values (build-response #:code 200)
      (cond
       ((string-suffix? "/tweets" path)          (scm->json-string '(("data" . (("id" . "tweet-1"))))))
       ((string-suffix? "createRecord" path)    (scm->json-string '(("uri" . "at://did/app.bsky.feed.post/xyz") ("cid" . "bafy"))))
       ((string-suffix? "/threads_publish" path) (scm->json-string '(("id" . "th-99"))))
       ((string-suffix? "/threads" path)         (scm->json-string '(("id" . "th-container"))))
       (else "{}")))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(define vat (spawn-vat))

;;; ─── X v2 : single POST /2/tweets {text}; id nested at .data.id ────────────
(display "\n── X v2: single call, nested id (.data.id) ──\n")
(with-vat vat
  (let ((x (spawn-x "user-bearer" #:base %base)))
    (check "X returns the NESTED id (.data.id)" (assq-ref ($ x 'post "hi from the commons") 'id) "tweet-1")
    (check "X sent {text: …}" (assoc-ref (json-string->scm %body) "text") "hi from the commons")
    (check "X hit /tweets" (and (string-suffix? "/tweets" %path) #t) #t)))

;;; ─── Bluesky : nested record {repo, collection, record{text, createdAt}}; id=.uri
(display "\n── Bluesky: nested record + createdAt, id at .uri ──\n")
(with-vat vat
  (let ((bsky (spawn-bluesky %base "session-jwt" "did:plc:abc")))
    (check "Bluesky returns the .uri as id"
           (assq-ref ($ bsky 'post "hello atproto") 'id) "at://did/app.bsky.feed.post/xyz")
    (let ((sent (json-string->scm %body)))
      (check "Bluesky carried the repo DID" (assoc-ref sent "repo") "did:plc:abc")
      (check "Bluesky nested the text at .record.text"
             (assoc-ref (assoc-ref sent "record") "text") "hello atproto")
      (check "Bluesky stamped a required createdAt"
             (and (assoc-ref (assoc-ref sent "record") "createdAt") #t) #t))))

;;; ─── Threads : two-step, text allowed (media_type=TEXT) ────────────────────
(display "\n── Threads: two-step (text), like Instagram ──\n")
(set! %steps '())
(with-vat vat
  (let ((th (spawn-threads %base "1789" "threads-token")))
    (check "Threads two-step returns the published id" (assq-ref ($ th 'post "hello threads") 'id) "th-99")
    (check "Threads hit /threads then /threads_publish"
           (reverse %steps) (list "/1789/threads" "/1789/threads_publish"))))

(display "\n")
(test-summary!)
