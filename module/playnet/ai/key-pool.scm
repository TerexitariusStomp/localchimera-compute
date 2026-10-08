;;; module/playnet/ai/key-pool.scm — Goblins actor for capability-secure API key pooling
;;;
;;; Self-contained module. No dependency on planner or playnet.
;;; Works with any HTTP API that uses key-based auth — provider profiles
;;; define the base URL, auth headers, error classification, cost
;;; extraction, and optional credit checking.  Ships with profiles for
;;; OpenRouter, OpenAI, and a generic constructor for arbitrary APIs.
;;;
;;; Architecture:
;;;   ^api-key  — seals one raw key string + private HTTP client.
;;;               Key material never leaves the actor boundary.
;;;   ^key-pool — round-robin coordinator over a list of ^api-key refs.
;;;               Callers get this capability; it proxies all requests.
;;;
;;; Usage:
;;;   (use-modules (playnet ai key-pool))
;;;   (define pool (make-key-pool vat "sk-aaa,sk-bbb,sk-ccc"))
;;;   (with-vat vat ($ pool 'request "/chat/completions" body-json))
;;;   (with-vat vat ($ pool 'pool-status))
;;;
;;; Built-in providers:
;;;   (make-key-pool vat keys #:provider (nano-gpt-provider))            ;; default
;;;   (make-key-pool vat keys #:provider (openrouter-provider))
;;;   (make-key-pool vat keys #:provider (openai-provider))
;;;   (make-key-pool vat keys #:provider (generic-provider "http://localhost:11434/v1"))
;;;
;;; Custom provider (any HTTP API):
;;;   (make-key-pool vat keys
;;;     #:provider `((name . "stripe")
;;;                  (base-url . "https://api.stripe.com/v1")
;;;                  (auth-header-fn . ,bearer-auth-header)
;;;                  (credit-check . #f)
;;;                  (cost-extractor . ,(lambda (json) #f))
;;;                  (error-classifier . ,default-error-classifier)))

(define-module (playnet ai key-pool)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)   ; fold, filter, etc.
  #:use-module (srfi srfi-9)   ; define-record-type
  #:use-module (srfi srfi-19)  ; time
  #:use-module (ice-9 hash-table)
  #:use-module (ice-9 threads)  ; call-with-new-thread (used in health-poll loop)
  #:use-module (playnet utils time)
  #:use-module (playnet utils http-auth)
  #:export (^api-key
            ^key-pool
            make-key-pool
            spawn-key-pool
            pool-health
            start-key-pool-monitor
            ;; Provider profiles
            openrouter-provider
            openai-provider
            nano-gpt-provider
            generic-provider
            ;; Building blocks for custom providers
            default-error-classifier)
  ;; bearer-auth-header lives in (playnet utils http-auth) — re-export
  ;; so existing callers continue to find it via this module.
  #:re-export (bearer-auth-header))

;;; ── Helpers ────────────────────────────────────────────────────────────────

;; current-epoch-seconds imported from (playnet utils time)

(define (key-string->id key-str)
  "Derive a stable short ID from a key string (first 12 chars of hex digest).
   Uses a simple hash — not cryptographic, just for identity/logging."
  ;; Use the built-in string-hash and format as hex
  (let ((h (string-hash key-str 4294967296)))  ; 2^32
    (string-append "key-" (number->string h 16))))

(define (string-downcase-contains? haystack needle)
  "Case-insensitive substring search."
  (string-contains (string-downcase haystack) needle))

;;; ── multipart/form-data builder ──────────────────────────────────────────
;;
;; PARTS is a list. Each part is one of:
;;   (name value)                          ;; text field; value is string or bytevector
;;   (name value filename content-type)    ;; file field; value is bytevector
;;
;; Returns (values BOUNDARY BODY-BYTEVECTOR). Header construction is
;; left to the caller — pair BOUNDARY with the content-type header
;; '(multipart/form-data (boundary . ,boundary)).

(define %boundary-alphabet
  "0123456789abcdefghijklmnopqrstuvwxyz")

(define %boundary-random-state
  (random-state-from-platform))

(define (%random-boundary)
  (let* ((n (string-length %boundary-alphabet))
         (suffix (list->string
                  (map (lambda (_)
                         (string-ref %boundary-alphabet
                                     (random n %boundary-random-state)))
                       (iota 24)))))
    (string-append "----playnet-boundary-" suffix)))

(define (%write-bytes port v)
  (cond
   ((bytevector? v) (put-bytevector port v))
   ((string? v)     (put-bytevector port (string->utf8 v)))
   (else (error "multipart: value must be string or bytevector" v))))

(define (build-multipart-body parts)
  (let ((boundary (%random-boundary))
        (crlf "\r\n"))
    (call-with-values open-bytevector-output-port
      (lambda (port get-bv)
        (for-each
         (lambda (part)
           (let ((name (car part))
                 (value (cadr part)))
             (%write-bytes port (string-append "--" boundary crlf))
             (cond
              ((= (length part) 4)
               (let ((filename (caddr part))
                     (ct       (cadddr part)))
                 (%write-bytes
                  port
                  (string-append
                   "Content-Disposition: form-data; name=\"" name
                   "\"; filename=\"" filename "\"" crlf
                   "Content-Type: " ct crlf crlf))))
              (else
               (%write-bytes
                port
                (string-append
                 "Content-Disposition: form-data; name=\"" name "\"" crlf crlf))))
             (%write-bytes port value)
             (%write-bytes port crlf)))
         parts)
        (%write-bytes port (string-append "--" boundary "--" crlf))
        (values boundary (get-bv))))))

;;; ── Provider profiles ──────────────────────────────────────────────────────
;;;
;;; A provider profile is an alist with these keys:
;;;   base-url         — string, e.g. "https://openrouter.ai/api/v1"
;;;   auth-header-fn   — (lambda (key-string) headers-alist)
;;;   credit-check     — #f or alist: ((endpoint . path) (parser . (lambda (json) number|#f)))
;;;   cost-extractor   — (lambda (response-json) cost-number-or-#f)
;;;   error-classifier — (lambda (http-code error-json error-message) health-symbol)
;;;   name             — string, for logging and VF bridge

;; bearer-auth-header and the permissive Authorization-writer fix come
;; from (playnet utils http-auth) — see that module's commentary for
;; the rationale (Guile's stock typed parser doesn't model OAuth Bearer).

(define (default-error-classifier code _err-json msg)
  "Classify errors by HTTP status code. 429 → rate-limited, else degraded."
  (cond
   ((eqv? code 429) 'rate-limited)
   (else 'degraded)))

(define (openrouter-provider)
  "Provider profile for OpenRouter (https://openrouter.ai)."
  `((name             . "openrouter")
    (base-url         . "https://openrouter.ai/api/v1")
    (auth-header-fn   . ,bearer-auth-header)
    (credit-check     . ((endpoint . "/auth/key")
                         (parser   . ,(lambda (json)
                                        (let ((data (assoc-ref json "data")))
                                          (and data (assoc-ref data "limit_remaining")))))))
    (cost-extractor   . ,(lambda (json)
                           (let ((usage (assoc-ref json "usage")))
                             (and usage (assoc-ref usage "total_cost")))))
    (error-classifier . ,(lambda (code _err-json msg)
                           (cond
                            ((and msg (string? msg)
                                  (string-downcase-contains? msg "insufficient credits"))
                             'depleted)
                            ((eqv? code 429) 'rate-limited)
                            (else 'degraded))))))

(define (openai-provider)
  "Provider profile for OpenAI (https://api.openai.com)."
  `((name             . "openai")
    (base-url         . "https://api.openai.com/v1")
    (auth-header-fn   . ,bearer-auth-header)
    (credit-check     . #f)
    (cost-extractor   . ,(lambda (json)
                           (let ((usage (assoc-ref json "usage")))
                             (and usage (assoc-ref usage "total_tokens")))))
    (error-classifier . ,default-error-classifier)))

(define (nano-gpt-provider)
  "Provider profile for nano-gpt (https://nano-gpt.com).
   OpenAI-compatible chat completions under base-url; the account itself —
   balance, crypto deposits — is under account-url, and a key's usd_balance
   is its credit (monero/topup.scm keeps it above the floor from the
   commons' wallet)."
  `((name             . "nano-gpt")
    (base-url         . "https://nano-gpt.com/api/v1")
    (account-url      . "https://nano-gpt.com/api")
    (auth-header-fn   . ,bearer-auth-header)
    (credit-check     . ((endpoint . "/check-balance")
                         (method   . post)
                         (account  . #t)
                         (parser   . ,(lambda (json)
                                        (let ((b (assoc-ref json "usd_balance")))
                                          (cond ((number? b) b)
                                                ((string? b) (string->number b))
                                                (else #f)))))))
    (cost-extractor   . ,(lambda (json)
                           (let ((usage (assoc-ref json "usage")))
                             (and usage (or (assoc-ref usage "total_cost")
                                            (assoc-ref usage "total_tokens"))))))
    (error-classifier . ,default-error-classifier)))

(define (generic-provider base-url)
  "Provider profile for any HTTP API at BASE-URL.
   Uses Bearer auth, no credit checking, tries total_cost then total_tokens
   for cost extraction, and classifies 429 as rate-limited."
  `((name             . "generic")
    (base-url         . ,base-url)
    (auth-header-fn   . ,bearer-auth-header)
    (credit-check     . #f)
    (cost-extractor   . ,(lambda (json)
                           (let ((usage (assoc-ref json "usage")))
                             (and usage (or (assoc-ref usage "total_cost")
                                            (assoc-ref usage "total_tokens"))))))
    (error-classifier . ,default-error-classifier)))

;;; ── <key-state> record ─────────────────────────────────────────────────────

(define-record-type <key-state>
  (make-key-state id health last-used
                  success-count failure-count
                  cost-today credits-remaining
                  donor-id donor-name)
  key-state?
  (id                 key-state-id)
  (health             key-state-health)             ; symbol: healthy | degraded | failed | rate-limited | depleted
  (last-used          key-state-last-used)           ; integer epoch seconds
  (success-count      key-state-success-count)       ; integer
  (failure-count      key-state-failure-count)       ; integer
  (cost-today         key-state-cost-today)          ; number
  (credits-remaining  key-state-credits-remaining)   ; number or #f
  (donor-id           key-state-donor-id)            ; string or #f
  (donor-name         key-state-donor-name))         ; string or #f

(define (fresh-key-state id donor-id donor-name)
  (make-key-state id 'healthy 0 0 0 0 #f donor-id donor-name))

(define (key-state-with-health st new-health)
  (make-key-state (key-state-id st)
                  new-health
                  (key-state-last-used st)
                  (key-state-success-count st)
                  (key-state-failure-count st)
                  (key-state-cost-today st)
                  (key-state-credits-remaining st)
                  (key-state-donor-id st)
                  (key-state-donor-name st)))

(define (key-state-with-credits st credits)
  ;; A depleted key with credit again — funded — is back in rotation.
  (make-key-state (key-state-id st)
                  (cond ((not credits) (key-state-health st))
                        ((<= credits 0) 'depleted)
                        ((eq? (key-state-health st) 'depleted) 'healthy)
                        (else (key-state-health st)))
                  (key-state-last-used st)
                  (key-state-success-count st)
                  (key-state-failure-count st)
                  (key-state-cost-today st)
                  credits
                  (key-state-donor-id st)
                  (key-state-donor-name st)))

(define (key-state-record-success st cost now)
  (make-key-state (key-state-id st)
                  'healthy
                  now
                  (+ 1 (key-state-success-count st))
                  (key-state-failure-count st)
                  (+ (key-state-cost-today st) (or cost 0))
                  (key-state-credits-remaining st)
                  (key-state-donor-id st)
                  (key-state-donor-name st)))

(define (key-state-record-failure st new-health now)
  (make-key-state (key-state-id st)
                  new-health
                  now
                  (key-state-success-count st)
                  (+ 1 (key-state-failure-count st))
                  (key-state-cost-today st)
                  (key-state-credits-remaining st)
                  (key-state-donor-id st)
                  (key-state-donor-name st)))

;;; ── ^api-key — sealed key actor ────────────────────────────────────────────
;;;
;;; The raw key-string and http-client are captured in closure.
;;; No method exposes them. Callers interact only through
;;; typed messages that never return the secret.

(define (^api-key bcom key-string state provider)
  ;; Create the HTTP client inline — it lives in the same vat,
  ;; captured by this closure, never returned to callers.
  (define http-base-url (assoc-ref provider 'base-url))
  (define http-headers ((assoc-ref provider 'auth-header-fn) key-string))

  ;; Generic byte-body POST. CONTENT-TYPE-HEADER is a typed header value
  ;; (alist or symbol) suitable for Guile's web client — e.g. the symbol
  ;; 'application/json or '(multipart/form-data (boundary . "xxx")).
  (define (http-post-bytes-raw path content-type-header body-bv)
    (let ((url (string-append http-base-url path)))
      (call-with-values
          (lambda ()
            (http-post url
                       #:body body-bv
                       #:headers
                       (cons `(content-type . ,content-type-header)
                             http-headers)
                       #:streaming? #f
                       #:decode-body? #f
                       #:verify-certificate? #t))
        (lambda (response body-bv)
          (values response
                  (if (bytevector? body-bv)
                      (utf8->string body-bv)
                      body-bv))))))

  (define (http-post-raw path body-string)
    (http-post-bytes-raw path '(application/json)
                         (string->utf8 body-string)))

  (define (http-post-multipart-raw path parts)
    (call-with-values (lambda () (build-multipart-body parts))
      (lambda (boundary body-bv)
        (http-post-bytes-raw
         path
         `(multipart/form-data (boundary . ,boundary))
         body-bv))))

  (define* (http-get-raw path #:optional (base http-base-url))
    (let ((url (string-append base path)))
      (call-with-values
          (lambda ()
            (http-get url
                      #:headers http-headers
                      #:streaming? #f
                      #:decode-body? #f
                      #:verify-certificate? #t))
        (lambda (response body-bv)
          (values response
                  (if (bytevector? body-bv)
                      (utf8->string body-bv)
                      body-bv))))))

  ;; The provider's account surface — balance, deposits — lives beside its
  ;; completions API, not under it, so it has its own base; a provider
  ;; without one has no account to speak of.
  (define (account-url)
    (or (assoc-ref provider 'account-url)
        (error "key-pool: this provider has no account endpoints"
               (assoc-ref provider 'name))))

  (define (account-post-raw path body-string)
    (let ((url (string-append (account-url) path)))
      (call-with-values
          (lambda ()
            (http-post url
                       #:body (string->utf8 body-string)
                       #:headers (cons '(content-type . (application/json))
                                       http-headers)
                       #:streaming? #f
                       #:decode-body? #f
                       #:verify-certificate? #t))
        (lambda (response body-bv)
          (values response
                  (if (bytevector? body-bv)
                      (utf8->string body-bv)
                      body-bv))))))

  (methods
   ;; ── Queries (no state change) ──

   [(id)     (key-state-id state)]
   [(health) (key-state-health state)]
   [(state)  state]

   ;; ── HTTP proxying ──

   [(post path body-string)
    (call-with-values
        (lambda () (http-post-raw path body-string))
      (lambda (response body-str)
        body-str))]

   ;; PARTS: list of part specs. Each part is either:
   ;;   (name value)                          — text field
   ;;   (name value filename content-type)    — file field (value = bytes)
   ;; Returns the response body as a string.
   [(post-multipart path parts)
    (call-with-values
        (lambda () (http-post-multipart-raw path parts))
      (lambda (response body-str)
        body-str))]

   [(get path)
    (call-with-values
        (lambda () (http-get-raw path))
      (lambda (response body-str)
        body-str))]

   ;; ── The key's account: what it holds, how it is funded ──
   ;; Answers (status-code body-string) as one list, so it crosses a vat
   ;; boundary whole; the caller reads the provider's JSON. The key itself
   ;; never leaves this closure.

   [(account-get path)
    (call-with-values
        (lambda () (http-get-raw path (account-url)))
      (lambda (response body-str)
        (list (response-code response) body-str)))]

   [(account-post path body-string)
    (call-with-values
        (lambda () (account-post-raw path body-string))
      (lambda (response body-str)
        (list (response-code response) body-str)))]

   ;; ── Credit check ──

   [(check-credits)
    (let ((cc (assoc-ref provider 'credit-check)))
      (if (not cc)
          #f  ;; provider has no credit-check endpoint
          (catch #t
            (lambda ()
              (call-with-values
                  (lambda ()
                    (let ((path (assoc-ref cc 'endpoint))
                          (base (if (assoc-ref cc 'account)
                                    (account-url)
                                    http-base-url)))
                      (if (eq? (assoc-ref cc 'method) 'post)
                          (if (assoc-ref cc 'account)
                              (account-post-raw path "{}")
                              (http-post-raw path "{}"))
                          (http-get-raw path base))))
                (lambda (response body-str)
                  (let* ((json (json-string->scm body-str))
                         (credits ((assoc-ref cc 'parser) json)))
                    (when credits
                      (bcom (^api-key bcom key-string
                                      (key-state-with-credits state credits)
                                      provider)))
                    credits))))
            (lambda (key . args)
              #f))))]

   ;; ── Health reporting (called by pool after request) ──

   [(report-success cost)
    (let ((now (current-epoch-seconds)))
      (bcom (^api-key bcom key-string
                      (key-state-record-success state cost now)
                      provider)))]

   [(report-failure error-status error-message)
    (let* ((now (current-epoch-seconds))
           (classifier (assoc-ref provider 'error-classifier))
           (new-health (classifier error-status #f error-message)))
      (bcom (^api-key bcom key-string
                      (key-state-record-failure state new-health now)
                      provider)))]

   ;; ── Auto-recovery (called by monitor) ──

   [(try-recover now)
    (let ((age (- now (key-state-last-used state)))
          (h   (key-state-health state)))
      (cond
       ;; Degraded → healthy after 5 minutes
       ((and (eq? h 'degraded) (>= age 300))
        (bcom (^api-key bcom key-string
                        (key-state-with-health state 'healthy)
                        provider)))
       ;; Rate-limited → healthy after 15 minutes
       ((and (eq? h 'rate-limited) (>= age 900))
        (bcom (^api-key bcom key-string
                        (key-state-with-health state 'healthy)
                        provider)))
       ;; No recovery yet — actor stays as-is. Return a single value so
       ;; the syscaller's single-valued continuation doesn't blow up.
       (else #f)))]))

;;; ── ^key-pool — round-robin coordinator ────────────────────────────────────

(define (^key-pool bcom keys current-index provider)
  ;; keys: vector of ^api-key actor references
  ;; current-index: integer (round-robin position)

  (define key-count (vector-length keys))

  ;; Inline round-robin: find next healthy key, advance index.
  ;; Returns (values key-ref new-index) or (values #f current-index).
  (define (pick-healthy)
    (let loop ((i 0)
               (idx current-index))
      (if (>= i key-count)
          (values #f idx)
          (let* ((key-ref (vector-ref keys idx))
                 (next-idx (modulo (+ idx 1) key-count)))
            (if (eq? ($ key-ref 'health) 'healthy)
                (values key-ref next-idx)
                (loop (+ i 1) next-idx))))))

  ;; Run a request through the next healthy key. SEND is a
  ;; (lambda (key-ref) -> response-string) that performs the actual
  ;; HTTP call. We wrap it with response parsing, health reporting,
  ;; and the round-robin bcom in one place so JSON and multipart
  ;; entrypoints share the same accounting.
  (define (run-request send)
    (call-with-values pick-healthy
      (lambda (key-ref new-idx)
        (unless key-ref
          (error "key-pool: no healthy keys available"))
        (let* ((response-str (send key-ref))
               (result
                (catch #t
                  (lambda ()
                    (let* ((json (json-string->scm response-str))
                           (err  (assoc-ref json "error")))
                      (if err
                          (let* ((msg (or (and (pair? err)
                                               (assoc-ref err "message"))
                                          (if (string? err) err "")))
                                 (code (and (pair? err)
                                            (assoc-ref err "code")))
                                 (classifier (assoc-ref provider 'error-classifier))
                                 (health (classifier code err msg)))
                            ($ key-ref 'report-failure health msg)
                            (error "key-pool: upstream error" msg))
                          (let* ((cost-fn (assoc-ref provider 'cost-extractor))
                                 (cost (cost-fn json)))
                            ($ key-ref 'report-success cost)
                            response-str))))
                  (lambda (key . args)
                    ;; JSON parse failed — treat as success
                    ($ key-ref 'report-success #f)
                    response-str))))
          (bcom (^key-pool bcom keys new-idx provider) result)))))

  (methods

   ;; ── Core: proxy a request through a healthy key ──

   [(request path body-string)
    (run-request (lambda (key-ref)
                   ($ key-ref 'post path body-string)))]

   ;; PARTS shape documented on ^api-key 'post-multipart.
   [(request-multipart path parts)
    (run-request (lambda (key-ref)
                   ($ key-ref 'post-multipart path parts)))]

   ;; GET proxied through a healthy key (carries the provider auth header) —
   ;; e.g. nano-gpt's TEE attestation/signature endpoints. Same rotation/health
   ;; path as 'request; returns the response body string.
   [(request-get path)
    (run-request (lambda (key-ref)
                   ($ key-ref 'get path)))]

   ;; ── Key management ──

   [(add-key key-string . donor-args)
    (let* ((donor-id   (if (pair? donor-args) (car donor-args) #f))
           (donor-name (if (and (pair? donor-args) (pair? (cdr donor-args)))
                           (cadr donor-args) #f))
           (id (key-string->id key-string))
           (st (fresh-key-state id donor-id donor-name))
           (key-ref (spawn ^api-key key-string st provider))
           (new-keys (let ((v (make-vector (+ key-count 1))))
                       (let copy ((i 0))
                         (when (< i key-count)
                           (vector-set! v i (vector-ref keys i))
                           (copy (+ i 1))))
                       (vector-set! v key-count key-ref)
                       v)))
      (bcom (^key-pool bcom new-keys current-index provider)
            id))]

   [(remove-key target-id)
    (let* ((new-keys (list->vector
                      (filter (lambda (k) (not (equal? ($ k 'id) target-id)))
                              (vector->list keys))))
           (new-count (vector-length new-keys))
           (new-idx   (if (and (> new-count 0) (>= current-index new-count))
                          0 current-index)))
      (bcom (^key-pool bcom new-keys new-idx provider)
            (not (= new-count key-count))))]

   ;; ── Health monitor hooks ──

   [(tick-recovery)
    (let ((now (current-epoch-seconds)))
      (let loop ((i 0))
        (when (< i key-count)
          ($ (vector-ref keys i) 'try-recover now)
          (loop (+ i 1)))))]

   [(check-all-credits)
    (let ((now (current-epoch-seconds)))
      (let loop ((i 0))
        (when (< i key-count)
          (let* ((k  (vector-ref keys i))
                 (st ($ k 'state))
                 (age (- now (key-state-last-used st))))
            ;; Only check idle keys (>5 min since last use)
            (when (>= age 300)
              ($ k 'check-credits)))
          (loop (+ i 1)))))]

   ;; The keys themselves, for whoever tends their accounts (the top-up in
   ;; monero/topup.scm). Each is a sealed ^api-key: a holder can ask it and
   ;; fund it, never read it.
   [(key-refs) (vector->list keys)]

   ;; ── Status ──

   [(pool-status)
    (let loop ((i 0)
               (healthy 0) (degraded 0) (failed 0)
               (rate-limited 0) (depleted 0)
               (total-success 0) (total-failure 0) (total-cost 0))
      (if (>= i key-count)
          `((total-keys      . ,key-count)
            (healthy-keys    . ,healthy)
            (health          . ((healthy      . ,healthy)
                                (degraded     . ,degraded)
                                (failed       . ,failed)
                                (rate-limited . ,rate-limited)
                                (depleted     . ,depleted)))
            (current-index   . ,current-index)
            (total-requests  . ,(+ total-success total-failure))
            (success-rate    . ,(if (> (+ total-success total-failure) 0)
                                    (exact->inexact
                                     (/ (* total-success 100)
                                        (+ total-success total-failure)))
                                    0))
            (total-cost-today . ,total-cost))
          (let* ((st ($ (vector-ref keys i) 'state))
                 (h  (key-state-health st)))
            (loop (+ i 1)
                  (+ healthy      (if (eq? h 'healthy) 1 0))
                  (+ degraded     (if (eq? h 'degraded) 1 0))
                  (+ failed       (if (eq? h 'failed) 1 0))
                  (+ rate-limited (if (eq? h 'rate-limited) 1 0))
                  (+ depleted     (if (eq? h 'depleted) 1 0))
                  (+ total-success (key-state-success-count st))
                  (+ total-failure (key-state-failure-count st))
                  (+ total-cost    (key-state-cost-today st))))))]

   [(pool-health)
    (let loop ((i 0) (healthy 0))
      (if (>= i key-count)
          (let* ((pct (if (> key-count 0)
                          (* (/ healthy key-count) 100)
                          0))
                 (s (cond
                     ((= healthy 0) 'down)
                     ((< pct 50) 'degraded)
                     (else 'ok))))
            `((status . ,s)
              (total-keys . ,key-count)
              (healthy-keys . ,healthy)))
          (loop (+ i 1)
                (+ healthy
                   (if (eq? ($ (vector-ref keys i) 'health) 'healthy)
                       1 0)))))]))

;;; ── pool-health — pure function on status alist ────────────────────────────

(define (pool-health pool-status)
  "Compute overall health from a pool-status alist.
   Returns (status . ok|degraded|down)."
  (let* ((total   (assq-ref pool-status 'total-keys))
         (healthy (assq-ref pool-status 'healthy-keys))
         (pct     (if (> total 0) (* (/ healthy total) 100) 0)))
    (cond
     ((= healthy 0) 'down)
     ((< pct 50)    'degraded)
     (else          'ok))))

;;; ── make-key-pool — convenience constructor ────────────────────────────────

(define* (spawn-key-pool keys-string
                         #:key (donors '())
                               (provider (nano-gpt-provider)))
  "Spawn a ^key-pool in the CALLER'S current vat.
   Caller must already be inside a (with-vat ...) block. Use this when
   you want the pool to share a vat with your other actors so all calls
   are synchronous (no cross-vat promises). Returns the pool actor ref."
  (let* ((key-strings (filter (lambda (s) (> (string-length s) 0))
                              (map string-trim-both
                                   (string-split keys-string #\,))))
         (key-actors (map (lambda (ks)
                            (let* ((donor-alist (or (assoc-ref donors ks) '()))
                                   (did (assoc-ref donor-alist "donor-id"))
                                   (dn  (assoc-ref donor-alist "donor-name"))
                                   (id  (key-string->id ks))
                                   (st  (fresh-key-state id did dn)))
                              (spawn ^api-key ks st provider)))
                          key-strings)))
    (spawn ^key-pool (list->vector key-actors) 0 provider)))

(define* (make-key-pool vat keys-string
                        #:key (donors '())
                              (provider (nano-gpt-provider)))
  "Spawn a ^key-pool in VAT from a comma-separated string of API keys.
   Optional DONORS: alist of ((key-string . ((donor-id . \"x\") (donor-name . \"y\"))) ...)
   Optional PROVIDER: a provider profile alist (default: nano-gpt).
   Returns the pool actor reference. For use OUTSIDE any vat — if you're
   already inside a vat, use spawn-key-pool instead."
  (with-vat vat (spawn-key-pool keys-string #:donors donors #:provider provider)))

;;; ── start-key-pool-monitor — background fiber ─────────────────────────────

(define* (start-key-pool-monitor vat pool-ref
                                  #:key (interval-seconds 30)
                                        (credit-check-every 10))
  "Start a background thread that ticks recovery every INTERVAL-SECONDS and
   asks the provider for each idle key's credit every CREDIT-CHECK-EVERY
   ticks — a call to the provider per key, so it is the rarer of the two.
   Returns the thread."
  (call-with-new-thread
   (lambda ()
     (let loop ((tick 1))
       (sleep interval-seconds)
       (catch #t
         (lambda ()
           (with-vat vat
             ($ pool-ref 'tick-recovery)
             (when (zero? (modulo tick credit-check-every))
               ($ pool-ref 'check-all-credits))))
         (lambda (key . args)
           (format (current-error-port)
                   "key-pool monitor error: ~a ~a~%" key args)))
       (loop (+ tick 1))))))
