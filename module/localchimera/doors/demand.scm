;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/doors/demand.scm — the paid-intake API translators
;;;
;;; Traditional buyers pay for standard wire shapes, not door calls: an
;;; OpenAI-shaped completion, a Bright Data-shaped fetch, a Judge0-shaped
;;; run, an S3-shaped put. This module is the boundary that speaks them —
;;; it authenticates the customer by the demand key the operator minted
;;; (machine-demand-credit; the key IS the credential, no device
;;; signature), resolves which commune's book holds it, translates the
;;; request into a price-free job envelope plus the desk's debit, and
;;; hands the pair to machine-demand-intake. The reply is always honest:
;;; work is asynchronous — 202 with the job id and a poll path, never a
;;; fabricated synchronous result.
;;;
;;;   POST /api/demand/v1/chat/completions       api-openai   exec
;;;   POST /api/demand/v1/audio/transcriptions   api-openai   exec
;;;   POST /api/demand/fetch                     api-fetch    relay egress
;;;   POST /api/demand/check                     api-monitor  relay egress
;;;   POST /api/demand/loadtest                  api-loadtest N relay egress
;;;   POST /api/demand/judge                     api-judge    exec
;;;   POST /api/demand/pin                       api-pin      store
;;;   POST /api/demand/ocr                       api-ocr      exec
;;;   POST /api/demand/render                    api-render   exec
;;;   POST /api/demand/prove                     api-prove    exec
;;;   PUT  /api/demand/s3/<key>                  api-store    store
;;;   GET  /api/demand/balance                   the book
;;;   GET  /api/demand/ledger                    the customer's ledger rows
;;;   GET  /api/demand/jobs/<id>                 one job's status
;;;
;;; Rate card: *demand-rates* debits the book a flat amount per call per
;;; endpoint — the desk keeps the book, the operator sets the card, the
;;; treasury edge settles what the statement shows.

(define-module (localchimera doors demand)
  #:use-module ((localchimera doors http)
                #:select (parse-json-object value->json))
  #:use-module ((localchimera keri crypto-primitives)
                #:select (keri-crypto-blake3-256))
  #:use-module ((localchimera utils hex) #:select (bv->hex))
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (%demand-prefix handle-demand-request))

(define %demand-prefix "/api/demand/")

;; endpoint → (payer . debit) — the operator's card, flat per call
(define *demand-rates*
  '(("v1/chat/completions"     . ("api-openai"   . 5))
    ("v1/audio/transcriptions" . ("api-openai"   . 5))
    ("fetch"                   . ("api-fetch"    . 1))
    ("check"                   . ("api-monitor"  . 1))
    ("loadtest"                . ("api-loadtest" . 10))
    ("judge"                   . ("api-judge"    . 1))
    ("pin"                     . ("api-pin"      . 1))
    ("ocr"                     . ("api-ocr"      . 2))
    ("render"                  . ("api-render"   . 3))
    ("prove"                   . ("api-prove"    . 5))))

(define (json-response code value)
  (values (build-response #:code code
                          #:headers '((content-type . (application/json))))
          (string-append (scm->json-string (value->json value)) "\n")))

(define (aref alist key)
  (let ((p (assoc key alist))) (and p (cdr p))))

(define (header headers name)
  (let ((p (assoc name headers)))
    (and p (let ((v (cdr p))) (if (string? v) v (format #f "~a" v))))))

;; the demand key: "Authorization: Bearer <key>" — the book's keyHash
;; string itself is the API credential; X-LocalChimera-Key answers for
;; clients that can't shape Authorization
(define (bearer-key headers)
  (let ((a (header headers 'authorization))
        (x (header headers 'x-localchimera-key)))
    (cond (x x)
          ((and a (string-prefix? "Bearer " a)) (substring a 7))
          (else #f))))

(define (content-hash body-bv)
  (string-append "b3:" (bv->hex (keri-crypto-blake3-256 body-bv))))

;; ── the translators — wire shape → price-free envelope ────────────────────

(define (exec-env ref ih params)
  `((kind . "exec") (bridgeJobId . ,ref)
    (image . "js:demand") (entrypoint . "demand")
    (inputHash . ,ih) (caps . ()) (network . #f)
    (params . ,params)))

(define (egress-env ref ih url extra-params)
  ;; the egress profile — destination + network:true + the fetch cap is
  ;; what makes a relay an honest outbound fetch, and the envelope's own
  ;; validation refuses anything else
  `((kind . "relay") (bridgeJobId . ,ref)
    (inputHash . ,ih) (caps . ("fetch")) (network . #t)
    (params . ((destination . ,url) ,@extra-params))))

(define (store-env ref ih params)
  `((kind . "store") (bridgeJobId . ,ref)
    (inputHash . ,ih) (caps . ()) (network . #f)
    (params . ,params)))

;; a request body's "model" as a params.model descriptor — only when the
;; customer supplies the full verified commit (uri + sha256 + format); a
;; bare name is not a descriptor and stays params.input.model instead
(define (model-object body)
  (let ((m (aref body "modelObject")))
    (and (list? m)
         (string? (aref m "uri"))
         (string? (aref m "sha256"))
         `((uri . ,(aref m "uri"))
           (sha256 . ,(aref m "sha256"))
           (format . ,(or (aref m "format") "gguf-wasm"))
           ,@(let ((c (aref m "context"))) (if c `((context . ,c)) '()))
           ,@(let ((s (aref m "seed"))) (if s `((seed . ,s)) '()))))))

;; endpoint+body → ((ref . envelope) …) | (error . message); check and
;; loadtest mint one job per vantage — every job is its own claim and
;; its own ledger row
(define (translate endpoint body ref ih)
  "→ ((ref . envelope) …) | (error . message)"
  (cond
   ((equal? endpoint "v1/chat/completions")
    (let ((model (aref body "model")) (messages (aref body "messages")))
      (if (not (and (string? model) (vector? messages)))
          '(error . "chat/completions needs model and messages")
          ;; a {uri,sha256,format} model object is a verified commit and
          ;; lands in params.model; a bare OpenAI-style name stays a name —
          ;; it rides params.input.model, never a descriptor the node
          ;; can't verify
          (list (cons ref
                      (exec-env ref ih
                                `(,@(let ((d (model-object body)))
                                      (if d `((model . ,d)) '()))
                                  (input . ((model . ,model)
                                            (messages . ,(vector->list messages))
                                            ,@(let ((t (aref body "temperature")))
                                                (if t `((temperature . ,t)) '()))
                                            ,@(let ((t (aref body "max_tokens")))
                                                (if t `((maxTokens . ,t)) '())))))))))))
   ((equal? endpoint "v1/audio/transcriptions")
    (let ((model (aref body "model")) (file (aref body "file")))
      (if (not (and (string? model) (string? file)))
          '(error . "transcriptions needs model and a base64 file")
          (list (cons ref
                      (exec-env ref ih
                                `(,@(let ((d (model-object body)))
                                      (if d `((model . ,d)) '()))
                                  (input . ((model . ,model) (audio . ,file))))))))))
   ((equal? endpoint "fetch")
    (let ((url (aref body "url")))
      (if (not (and (string? url) (string-prefix? "http" url)))
          '(error . "fetch needs an http(s) url")
          (list (cons ref
                      (egress-env ref ih url
                                  `(,@(let ((m (aref body "method")))
                                        (if m `((method . ,m)) '()))
                                    ,@(let ((h (aref body "headers")))
                                        (if h `((headers . ,h)) '())))))))))
   ((equal? endpoint "check")
    (let ((url (aref body "url"))
          (v (or (aref body "vantages") 1)))
      (if (not (and (string? url) (string-prefix? "http" url)))
          '(error . "check needs an http(s) url")
          (map (lambda (i)
                 (cons (string-append ref ":" (number->string i))
                       (egress-env (string-append ref ":" (number->string i))
                                   ih url `((check . #t)))))
               (iota (max 1 (min v 32)))))))
   ((equal? endpoint "loadtest")
    (let ((url (aref body "url"))
          (n (or (aref body "concurrency") 10)))
      (if (not (and (string? url) (string-prefix? "http" url)))
          '(error . "loadtest needs an http(s) url")
          (map (lambda (i)
                 (cons (string-append ref ":" (number->string i))
                       (egress-env (string-append ref ":" (number->string i))
                                   ih url `((burst . #t)))))
               (iota (max 1 (min n 50)))))))
   ((equal? endpoint "judge")
    (let ((src (aref body "source_code")) (lang (aref body "language_id")))
      (if (not (and (string? src) (or (string? lang) (number? lang))))
          '(error . "judge needs source_code and language_id")
          (list (cons ref
                      (exec-env ref ih
                                `((input . ((source . ,src) (language . ,lang))))))))))
   ((equal? endpoint "pin")
    (let ((cid (aref body "cid")))
      (if (not (string? cid))
          '(error . "pin needs a cid")
          (list (cons ref
                      (store-env ref ih `((cid . ,cid))))))))
   ((equal? endpoint "ocr")
    (let ((img (aref body "image")) (lang (or (aref body "language") "eng")))
      (if (not (string? img))
          '(error . "ocr needs a base64 image")
          (list (cons ref
                      (exec-env ref ih
                                `((input . ((image . ,img) (language . ,lang))))))))))
   ((equal? endpoint "render")
    (let ((html (aref body "html")) (url (aref body "url")))
      (if (not (or (string? html) (string? url)))
          '(error . "render needs html or a url")
          (list (cons ref
                      (exec-env ref ih
                                `((input . ,(if html `((html . ,html)) `((url . ,url)))))))))))
   ((equal? endpoint "prove")
    (let ((circuit (aref body "circuit")) (witness (aref body "witness")))
      (if (not (and (string? circuit) (string? witness)))
          '(error . "prove needs circuit and witness")
          (list (cons ref
                      (exec-env ref ih
                                `((input . ((circuit . ,circuit) (witness . ,witness))))))))))
   (else #f)))

;; ── the intake call ───────────────────────────────────────────────────────

(define (resolve-customer call session key)
  "the desk's (commune owner keyHash) for KEY, or 'error"
  (call session 'machine-demand-resolve (list key)))

(define (intake-one call session commune key payer ref debit ih env)
  (call session 'machine-demand-intake
        (list commune key payer ref debit
              "swarm-infer" "member" "deterministic" ih
              'envelope env)))

(define (door-error? r) (and (pair? r) (eq? (car r) 'error)))

;; a door's refusal is (error "msg" …): its message is the second
;; element, whatever the pair shape
(define (err-msg r)
  (let ((e (cdr r))) (if (pair? e) (car e) e)))

(define (intake-error->http r)
  (let ((m (format #f "~a" r)))
    (cond
     ((string-contains m "insufficient") (cons 402 r))
     ((string-contains m "no such customer") (cons 401 r))
     (else (cons 400 r)))))

(define (job-poll job-id) (string-append "/api/demand/jobs/" job-id))

;; ── the handler ───────────────────────────────────────────────────────────

(define* (handle-demand-request request body-bv #:key target call (now #f))
  "Answer one /api/demand/ request. TARGET and CALL are the HTTP door's —
the customer's session is spawned under its key (the key is a principal
for demand doors), and every intake resolves its commune through the
desk before the book is touched."
  (let* ((method (request-method request))
         (path (uri-path (request-uri request)))
         (headers (request-headers request))
         (body-bv (or body-bv (make-bytevector 0)))
         (endpoint (and (string-prefix? %demand-prefix path)
                        (substring path (string-length %demand-prefix))))
         (key (bearer-key headers)))
    (cond
     ((not endpoint)
      (json-response 404 '((error . "no such demand endpoint"))))
     ((not key)
      (json-response 401 '((error . "a demand key rides Authorization: Bearer or X-LocalChimera-Key"))))
     (else
      (let* ((session (target 'session key))
             (res (resolve-customer call session key)))
        (cond
         ((door-error? res)
          (json-response 401 `((error . "unknown demand key"))))
         (else
          (let ((commune (aref (cdr res) "commune")))
            (cond
         ;; ── the reads ──────────────────────────────────────────────
         ((and (eq? method 'GET) (equal? endpoint "balance"))
          (let ((r (call session 'machine-demand-balance (list commune key))))
            (if (door-error? r)
                (json-response 400 `((error . ,(err-msg r))))
                (json-response 200 (cdr r)))))
         ((and (eq? method 'GET) (equal? endpoint "ledger"))
          (let ((r (call session 'machine-payer-events (list commune))))
            (if (door-error? r)
                (json-response 400 `((error . ,(err-msg r))))
                (json-response 200 `((rows . ,(list->vector (cdr r))))))))
         ((and (eq? method 'GET) (string-prefix? "jobs/" endpoint))
          (let* ((job-id (substring endpoint 5))
                 (r (call session 'machine-demand-job (list commune job-id))))
            (if (door-error? r)
                (json-response 404 `((error . ,(err-msg r))))
                (json-response 200 (cdr r)))))
         ;; ── the paid intakes ───────────────────────────────────────
         ((eq? method 'POST)
          (let* ((rate (assoc endpoint *demand-rates*))
                 (body (parse-json-object body-bv)))
            (cond
             ((not rate)
              (json-response 404 '((error . "no such demand endpoint"))))
             ((eq? body 'bad)
              (json-response 400 '((error . "body is not a JSON object"))))
             (else
              (let* ((pair (cdr rate))
                     (payer (car pair)) (debit (cdr pair))
                     (ih (content-hash body-bv))
                     (ref (or (header headers 'idempotency-key)
                              (string-append "dreq:" ih)))
                     (translated (translate endpoint body ref ih)))
                (cond
                 ((not translated)
                  (json-response 404 '((error . "no such demand endpoint"))))
                 ((door-error? translated)
                  (json-response 400 `((error . ,(err-msg translated)))))
                 (else
                  (let ((jobs
                         (map (lambda (re)
                                (let ((r (intake-one call session commune key
                                                     payer (car re) debit ih
                                                     (cdr re))))
                                  (if (door-error? r) r (cdr r))))
                              translated)))
                    (let ((bad (find door-error? jobs)))
                      (if bad
                          (let ((h (intake-error->http bad)))
                            (json-response (car h) `((error . ,(err-msg bad)))))
                          (json-response
                           202 `((status . "queued")
                                 (payer . ,payer)
                                 (jobs . ,(list->vector
                                           (map (lambda (j)
                                                  `(("jobId" . ,(aref j "jobId"))
                                                    ("rowId" . ,(aref j "rowId"))
                                                    ("poll" . ,(job-poll (aref j "jobId")))))
                                                jobs)))))))))))))))
         ;; s3 puts ride PUT — body is the content, not JSON
         ((and (eq? method 'PUT) (string-prefix? "s3/" endpoint))
          (let* ((s3key (substring endpoint 3))
                 (ih (content-hash body-bv))
                 (ref (or (header headers 'idempotency-key)
                          (string-append "dreq:" ih)))
                 (env (store-env ref ih
                                 `((key . ,s3key)
                                   (contentB64 . ,(base64-encode body-bv)))))
                 (r (intake-one call session commune key "api-s3" ref 1 ih env)))
            (if (door-error? r)
                (let ((h (intake-error->http r)))
                  (json-response (car h) `((error . ,(err-msg r)))))
                (json-response
                 202 `((status . "queued") (payer . "api-s3")
                       (jobs . ,(vector `(("jobId" . ,(aref (cdr r) "jobId"))
                                          ("rowId" . ,(aref (cdr r) "rowId"))
                                          ("poll" . ,(job-poll (aref (cdr r) "jobId")))))))))))
         ((eq? method 'GET)
          (json-response 404 '((error . "no such demand read"))))
         (else
          (json-response 405 '((error . "demand endpoints answer GET, POST, PUT")))))))))))))

;; minimal base64 for s3 content bodies (the http door's copy is local)
(define (base64-encode bv)
  (let* ((alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
         (n (bytevector-length bv))
         (out (open-output-string)))
    (let loop ((i 0))
      (when (< i n)
        (let* ((b0 (bytevector-u8-ref bv i))
               (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
               (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
               (triple (+ (* b0 65536) (* b1 256) b2)))
          (display (string-ref alphabet (logand (ash triple -18) 63)) out)
          (display (string-ref alphabet (logand (ash triple -12) 63)) out)
          (display (if (< (+ i 1) n) (string-ref alphabet (logand (ash triple -6) 63)) #\=) out)
          (display (if (< (+ i 2) n) (string-ref alphabet (logand triple 63)) #\=) out)
          (loop (+ i 3)))))
    (get-output-string out)))
