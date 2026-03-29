;;; key-pool/key-pool.scm — Goblins actor for OpenRouter API key pooling
;;;
;;; Self-contained module. No dependency on planner or xorg.
;;;
;;; Architecture:
;;;   ^api-key  — seals one raw key string + private HTTP client.
;;;               Key material never leaves the actor boundary.
;;;   ^key-pool — round-robin coordinator over a list of ^api-key refs.
;;;               Callers get this capability; it proxies all requests.
;;;
;;; Usage:
;;;   (use-modules (key-pool))
;;;   (define pool (make-key-pool vat "sk-aaa,sk-bbb,sk-ccc"))
;;;   (with-vat vat ($ pool 'request "/chat/completions" body-json))
;;;   (with-vat vat ($ pool 'pool-status))

(define-module (key-pool)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (srfi srfi-1)   ; fold, filter, etc.
  #:use-module (srfi srfi-9)   ; define-record-type
  #:use-module (srfi srfi-19)  ; time
  #:use-module (ice-9 hash-table)
  #:export (^api-key
            ^key-pool
            make-key-pool
            pool-health
            start-key-pool-monitor))

;;; ── Helpers ────────────────────────────────────────────────────────────────

(define (current-epoch-seconds)
  "Current wall-clock time as integer seconds."
  (let ((t (current-time time-utc)))
    (time-second t)))

(define (key-string->id key-str)
  "Derive a stable short ID from a key string (first 12 chars of hex digest).
   Uses a simple hash — not cryptographic, just for identity/logging."
  ;; Use the built-in string-hash and format as hex
  (let ((h (string-hash key-str 4294967296)))  ; 2^32
    (string-append "key-" (number->string h 16))))

(define (string-downcase-contains? haystack needle)
  "Case-insensitive substring search."
  (string-contains (string-downcase haystack) needle))

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
  (make-key-state (key-state-id st)
                  (if (and credits (<= credits 0)) 'depleted (key-state-health st))
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

(define (^api-key bcom key-string state)
  ;; Create the HTTP client inline — it lives in the same vat,
  ;; captured by this closure, never returned to callers.
  (define http-base-url "https://openrouter.ai/api/v1")
  (define http-headers `((authorization bearer ,key-string)))

  (define (http-post-raw path body-string)
    (let ((url (string-append http-base-url path)))
      (call-with-values
          (lambda ()
            (http-post url
                       #:body (string->utf8 body-string)
                       #:headers
                       (cons '(content-type . (application/json))
                             http-headers)
                       #:streaming? #f
                       #:decode-body? #f
                       #:verify-certificate? #f))
        (lambda (response body-bv)
          (values response
                  (if (bytevector? body-bv)
                      (utf8->string body-bv)
                      body-bv))))))

  (define (http-get-raw path)
    (let ((url (string-append http-base-url path)))
      (call-with-values
          (lambda ()
            (http-get url
                      #:headers http-headers
                      #:streaming? #f
                      #:decode-body? #f
                      #:verify-certificate? #f))
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

   [(get path)
    (call-with-values
        (lambda () (http-get-raw path))
      (lambda (response body-str)
        body-str))]

   ;; ── Credit check ──

   [(check-credits)
    (catch #t
      (lambda ()
        (call-with-values
            (lambda () (http-get-raw "/auth/key"))
          (lambda (response body-str)
            (let* ((json (json-string->scm body-str))
                   (data (assoc-ref json "data"))
                   (credits (and data (assoc-ref data "limit_remaining"))))
              (when credits
                (bcom (^api-key bcom key-string
                                (key-state-with-credits state credits))))
              credits))))
      (lambda (key . args)
        #f))]

   ;; ── Health reporting (called by pool after request) ──

   [(report-success cost)
    (let ((now (current-epoch-seconds)))
      (bcom (^api-key bcom key-string
                      (key-state-record-success state cost now))))]

   [(report-failure error-status error-message)
    (let* ((now (current-epoch-seconds))
           (new-health
            (cond
             ((and error-message
                   (string? error-message)
                   (string-downcase-contains? error-message "insufficient credits"))
              'depleted)
             (else error-status))))
      (bcom (^api-key bcom key-string
                      (key-state-record-failure state new-health now))))]

   ;; ── Auto-recovery (called by monitor) ──

   [(try-recover now)
    (let ((age (- now (key-state-last-used state)))
          (h   (key-state-health state)))
      (cond
       ;; Degraded → healthy after 5 minutes
       ((and (eq? h 'degraded) (>= age 300))
        (bcom (^api-key bcom key-string
                        (key-state-with-health state 'healthy))))
       ;; Rate-limited → healthy after 15 minutes
       ((and (eq? h 'rate-limited) (>= age 900))
        (bcom (^api-key bcom key-string
                        (key-state-with-health state 'healthy))))
       (else (values))))]))

;;; ── ^key-pool — round-robin coordinator ────────────────────────────────────

(define (^key-pool bcom keys current-index)
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

  (methods

   ;; ── Core: proxy a request through a healthy key ──

   [(request path body-string)
    (call-with-values pick-healthy
      (lambda (key-ref new-idx)
        (unless key-ref
          (error "key-pool: no healthy keys available"))
        ;; Make the request through the sealed key
        (let ((response-str ($ key-ref 'post path body-string)))
          ;; Parse response, report health to the key actor, then
          ;; advance round-robin index via bcom as the final expression.
          (let ((result
                 (catch #t
                   (lambda ()
                     (let* ((json (json-string->scm response-str))
                            (err  (assoc-ref json "error")))
                       (if err
                           (let ((msg (or (and (pair? err)
                                               (assoc-ref err "message"))
                                          (if (string? err) err "")))
                                 (code (and (pair? err)
                                            (assoc-ref err "code"))))
                             (cond
                              ((and code (equal? code 429))
                               ($ key-ref 'report-failure 'rate-limited msg))
                              ((and (string? msg)
                                    (string-downcase-contains?
                                     msg "insufficient credits"))
                               ($ key-ref 'report-failure 'depleted msg))
                              (else
                               ($ key-ref 'report-failure 'degraded msg)))
                             (error "key-pool: upstream error" msg))
                           ;; Success — extract cost if present
                           (let* ((usage (assoc-ref json "usage"))
                                  (cost  (and usage
                                              (assoc-ref usage "total_cost"))))
                             ($ key-ref 'report-success cost)
                             response-str))))
                   (lambda (key . args)
                     ;; JSON parse failed — treat as success
                     ($ key-ref 'report-success #f)
                     response-str))))
            ;; Advance round-robin and return the result
            (bcom (^key-pool bcom keys new-idx)
                  result)))))]

   ;; ── Key management ──

   [(add-key key-string . donor-args)
    (let* ((donor-id   (if (pair? donor-args) (car donor-args) #f))
           (donor-name (if (and (pair? donor-args) (pair? (cdr donor-args)))
                           (cadr donor-args) #f))
           (id (key-string->id key-string))
           (st (fresh-key-state id donor-id donor-name))
           (key-ref (spawn ^api-key key-string st))
           (new-keys (let ((v (make-vector (+ key-count 1))))
                       (let copy ((i 0))
                         (when (< i key-count)
                           (vector-set! v i (vector-ref keys i))
                           (copy (+ i 1))))
                       (vector-set! v key-count key-ref)
                       v)))
      (bcom (^key-pool bcom new-keys current-index)
            id))]

   [(remove-key target-id)
    (let* ((new-keys (list->vector
                      (filter (lambda (k) (not (equal? ($ k 'id) target-id)))
                              (vector->list keys))))
           (new-count (vector-length new-keys))
           (new-idx   (if (and (> new-count 0) (>= current-index new-count))
                          0 current-index)))
      (bcom (^key-pool bcom new-keys new-idx)
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

(define* (make-key-pool vat keys-string #:key (donors '()))
  "Spawn a ^key-pool in VAT from a comma-separated string of API keys.
   Optional DONORS: alist of ((key-string . ((donor-id . \"x\") (donor-name . \"y\"))) ...)
   Returns the pool actor reference."
  (let* ((key-strings (filter (lambda (s) (> (string-length s) 0))
                              (map string-trim-both
                                   (string-split keys-string #\,))))
         (key-actors
          (with-vat vat
            (map (lambda (ks)
                   (let* ((donor-alist (or (assoc-ref donors ks) '()))
                          (did (assoc-ref donor-alist "donor-id"))
                          (dn  (assoc-ref donor-alist "donor-name"))
                          (id  (key-string->id ks))
                          (st  (fresh-key-state id did dn)))
                     (spawn ^api-key ks st)))
                 key-strings))))
    (with-vat vat
      (spawn ^key-pool (list->vector key-actors) 0))))

;;; ── start-key-pool-monitor — background fiber ─────────────────────────────

(define* (start-key-pool-monitor vat pool-ref
                                  #:key (interval-seconds 30))
  "Start a background fiber that periodically ticks recovery and credit checks.
   Must be called within a (run-fibers ...) context.
   Returns the fiber."
  ;; Use Guile fibers if available, otherwise fall back to a thread.
  (let ((sleep-fn (lambda (secs)
                    ;; Try fibers sleep, fall back to regular sleep
                    (sleep secs))))
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (sleep-fn interval-seconds)
         (catch #t
           (lambda ()
             (with-vat vat
               ($ pool-ref 'tick-recovery)
               ($ pool-ref 'check-all-credits)))
           (lambda (key . args)
             (format (current-error-port)
                     "key-pool monitor error: ~a ~a~%" key args)))
         (loop))))))
