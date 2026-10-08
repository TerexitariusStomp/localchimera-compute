;;; module/playnet/fleet/vpsbg.scm — VPSBG API client + provider
;;;
;;; VPSBG (vpsbg.eu) is a no-KYC VPS provider offering AMD SEV-SNP
;;; confidential VMs with Bitcoin/Lightning payment and a REST API.
;;;
;;; Key differences from SporeStack:
;;;   • Auth: Bearer token in Authorization header (not URL path)
;;;   • Payment: per-order; orders auto-pay from balance, top up via BTC deposit
;;;   • Deployment: custom ISO / custom-server-image / stock image_id
;;;   • Security: AMD SEV / SEV-ES / SEV-SNP via amd_sev_level (0–3)
;;;
;;; API documentation: https://dev.vpsbg.eu/doc-338631
;;; API base:          https://api.vpsbg.eu/v1
;;;
;;; Usage:
;;;   (define creds (make-vpsbg-creds vpsbg-default-endpoint "ID|KEY"))
;;;   (define provider (make-vpsbg-provider creds))
;;;   ;; provider implements the 6-operation fleet protocol

(define-module (playnet fleet vpsbg)
  #:use-module (web client)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (ice-9 threads)              ; cancel-thread, join-thread/timeout
  #:use-module (json)
  #:use-module (playnet utils http-auth)
  #:use-module (playnet fleet records)
  #:export (make-vpsbg-creds
            vpsbg-creds?
            vpsbg-creds-endpoint
            vpsbg-creds-api-key
            vpsbg-default-endpoint

            ;; API client — servers
            vpsbg-http-call
            vpsbg-create-server
            vpsbg-get-server
            vpsbg-list-servers
            vpsbg-cancel-server
            vpsbg-undo-cancel-server

            ;; ISOs
            vpsbg-upload-iso
            vpsbg-get-iso
            vpsbg-wait-for-iso
            vpsbg-list-isos
            vpsbg-modify-server-isos

            ;; Custom images
            vpsbg-list-custom-images
            vpsbg-add-custom-image

            ;; SSH keys
            vpsbg-add-ssh-key
            vpsbg-list-ssh-keys

            ;; Billing
            vpsbg-get-balance
            vpsbg-deposit-bitcoin
            vpsbg-list-orders
            vpsbg-pay-orders

            ;; Plans
            vpsbg-list-plans
            vpsbg-find-plan

            ;; Helpers
            vpsbg-server-primary-ip
            vpsbg-paginated-data

            ;; Bitcoin URI
            parse-bitcoin-uri
            bitcoin-uri?
            bitcoin-uri-address
            bitcoin-uri-amount-btc
            bitcoin-uri-label
            build-bitcoin-uri
            btc->satoshis

            ;; Provider protocol
            make-vpsbg-provider))

;;; ── Credentials ──────────────────────────────────────────────────────────

(define vpsbg-default-endpoint "https://api.vpsbg.eu/v1")

(define-record-type <vpsbg-creds>
  (make-vpsbg-creds endpoint api-key)
  vpsbg-creds?
  (endpoint vpsbg-creds-endpoint)   ; "https://api.vpsbg.eu/v1"
  (api-key  vpsbg-creds-api-key))   ; Bearer token, format "ID|KEY"

;;; ── Low-level HTTP ──────────────────────────────────────────────────────

(define %vpsbg-timeout-key 'vpsbg-request-timed-out)

(define (call-with-http-timeout seconds thunk)
  "Run THUNK in a worker thread with a wall-clock deadline. Captures
multi-value returns. If the deadline fires before THUNK returns, the
worker is `cancel-thread`'d (which interrupts even a TLS read) and we
raise `%vpsbg-timeout-key`. Any exception THUNK raises is re-thrown in
the caller's continuation. No background thread is left running on
either path — empirically `cancel-thread` unwinds a TLS-blocked thread
within ~1 s, after which its socket port is reclaimed by GC."
  ;; The cell is a single set! target. We rely on the fact that join-thread
  ;; with a timeoutval returns the sentinel ONLY if the thread didn't
  ;; complete; so we can distinguish "completed" from "timed out" by
  ;; comparing against the sentinel rather than by reading the cell flag
  ;; (which would race).
  (let* ((sentinel  (list 'timeout))
         (cell      sentinel)
         (worker
          (make-thread
           (lambda ()
             (set! cell
                   (catch #t
                     (lambda ()
                       ;; call-with-values + list captures multi-value
                       ;; returns like (values response body-bv).
                       (cons 'ok (call-with-values thunk list)))
                     (lambda args (cons 'err args))))))))
    ;; Guile's join-thread takes an ABSOLUTE deadline (seconds since
    ;; epoch), not a duration — verified empirically.
    (join-thread worker (+ (instant->unix (clock-now)) seconds) sentinel)
    (cond
     ((eq? cell sentinel)
      ;; Best-effort cleanup. cancel-thread is async; we don't block on
      ;; the worker finishing, but the next syscall in the worker (read
      ;; on the socket) will see the cancellation and unwind. GC closes
      ;; the socket port shortly after.
      (catch #t
        (lambda () (cancel-thread worker))
        (lambda _ #f))
      (throw %vpsbg-timeout-key seconds))
     ((eq? (car cell) 'ok)
      (apply values (cdr cell)))
     (else
      (apply throw (cdr cell))))))

(define* (vpsbg-http-call creds
                          #:key
                          method
                          path
                          body
                          (query '())
                          (max-rate-limit-retries 5)
                          (request-timeout-seconds 60))
  "Issue an HTTP call against the VPSBG API. Auth via Bearer token.
Returns parsed JSON, or #t for 204 No Content. Raises on >=400.

Recoverability:
  • Per-request deadline of `request-timeout-seconds` (default 60 s).
    A wedged TLS handshake or stalled read is interrupted via
    `cancel-thread`; the underlying socket port is reclaimed by GC.
    The wedged attempt counts toward the retry budget so callers can
    keep going.
  • HTTP 429 (rate limit; VPSBG enforces 200 req/min per user): reads
    the `Retry-After` header (delta-seconds, RFC 7231) and sleeps
    that long before retrying. Up to `max-rate-limit-retries` (default 5).
  • Timeouts are also retried up to the same budget — but with a 1 s
    cool-off rather than the absent Retry-After's default, because the
    failure mode is local rather than server-side.

Once the retry budget is exhausted the underlying error (HTTP code or
timeout) is surfaced."
  (let* ((qs (if (null? query)
                 ""
                 (string-append "?" (format-query query))))
         ;; Tolerate a trailing slash on the endpoint: VPSBG endpoints
         ;; in this module are written with a leading slash on `path`
         ;; (e.g. "/servers"), so an endpoint like "https://…/v1/" would
         ;; concatenate to "…/v1//servers" and 404 on a strict path
         ;; matcher. Strip the slash exactly once.
         (endpoint (let ((e (vpsbg-creds-endpoint creds)))
                     (if (and (string? e)
                              (positive? (string-length e))
                              (eqv? #\/ (string-ref e (- (string-length e) 1))))
                         (substring e 0 (- (string-length e) 1))
                         e)))
         (url (string-append endpoint path qs))
         (body-bytes (and body
                          (string->utf8 (scm->json-string body))))
         (headers (append (bearer-auth-header (vpsbg-creds-api-key creds))
                          '((accept . "application/json"))
                          (if body
                              '((content-type . "application/json"))
                              '()))))
    (let* ((http-thunk
            (lambda ()
              (case method
                ((GET)
                 (http-get url
                           #:headers headers
                           #:streaming? #f
                           #:decode-body? #f
                           #:verify-certificate? #t))
                ((POST)
                 (http-post url
                            #:body (or body-bytes #vu8())
                            #:headers headers
                            #:streaming? #f
                            #:decode-body? #f
                            #:verify-certificate? #t))
                ((PUT)
                 (http-put url
                           #:body (or body-bytes #vu8())
                           #:headers headers
                           #:streaming? #f
                           #:decode-body? #f
                           #:verify-certificate? #t))
                ((PATCH)
                 ;; Guile's (web client) lacks http-patch; use http-request.
                 ((@ (web client) http-request) url
                                                #:method 'PATCH
                                                #:body (or body-bytes #vu8())
                                                #:headers headers
                                                #:streaming? #f
                                                #:decode-body? #f
                                                #:verify-certificate? #t))
                ((DELETE)
                 ;; Some VPSBG DELETE endpoints (e.g. undo cancel) take a
                 ;; body. Guile's http-delete signature does not accept
                 ;; #:body in all versions, so route through http-request.
                 ((@ (web client) http-request) url
                                                #:method 'DELETE
                                                #:body (or body-bytes #vu8())
                                                #:headers headers
                                                #:streaming? #f
                                                #:decode-body? #f
                                                #:verify-certificate? #t))
                (else (error "vpsbg-http-call: unsupported method" method))))))
      (let retry ((attempt 0))
        (catch %vpsbg-timeout-key
          (lambda ()
            (call-with-values
                (lambda ()
                  (call-with-http-timeout request-timeout-seconds http-thunk))
              (lambda (response body-bv)
                (let* ((code (response-code response))
                       (body-str (if (bytevector? body-bv)
                                     (utf8->string body-bv)
                                     (or body-bv ""))))
                  (cond
                   ((= code 204) #t)
                   ((and (>= code 200) (< code 300))
                    (if (string-null? body-str)
                        #t
                        (json-string->scm body-str)))
                   ;; Rate limited: respect Retry-After, then retry.
                   ((and (= code 429) (< attempt max-rate-limit-retries))
                    (let ((wait (extract-retry-after-seconds response)))
                      (format (current-error-port)
                              "vpsbg ~a ~a: 429 rate-limited, sleeping \
~as (retry ~a/~a)~%"
                              method path wait
                              (+ attempt 1) max-rate-limit-retries)
                      (sleep wait)
                      (retry (+ attempt 1))))
                   (else
                    (error (format #f "vpsbg ~a ~a: HTTP ~a ~a"
                                   method path code body-str))))))))
          (lambda (_key seconds)
            ;; Per-request deadline tripped. Retry with a 1 s cool-off
            ;; (the failure is local, no point waiting longer).
            (cond
             ((< attempt max-rate-limit-retries)
              (format (current-error-port)
                      "vpsbg ~a ~a: request exceeded ~as, retrying \
(~a/~a)~%"
                      method path seconds
                      (+ attempt 1) max-rate-limit-retries)
              (sleep 1)
              (retry (+ attempt 1)))
             (else
              (error
               (format #f
                       "vpsbg ~a ~a: request exceeded ~as timeout \
after ~a retries"
                       method path seconds max-rate-limit-retries))))))))))

(define (extract-retry-after-seconds response)
  "Read the `Retry-After` header off a Guile response. Guile parses the
delta-seconds form as an integer; the HTTP-date form as a date. We
support the integer form (what VPSBG sends) and fall back to a small
constant so a missing/malformed header doesn't turn 429 into a hang."
  (let ((v (assq-ref (response-headers response) 'retry-after)))
    (cond
     ((and (integer? v) (positive? v)) v)
     ((and (string? v) (string->number v)) (string->number v))
     (else 5))))

(define (format-query alist)
  (string-join
   (map (lambda (kv)
          (string-append (uri-encode (format #f "~a" (car kv)))
                         "="
                         (uri-encode (format #f "~a" (cdr kv)))))
        alist)
   "&"))

(define (vpsbg-paginated-data resp)
  "Extract the data[] array from a paginated VPSBG response. Returns '() if
the shape is unexpected."
  (let ((d (and (list? resp) (assoc-ref resp "data"))))
    (cond
     ((vector? d) (vector->list d))
     ((list? d) d)
     (else '()))))

;;; ── Servers ──────────────────────────────────────────────────────────────

(define* (vpsbg-create-server creds
                              #:key
                              name              ; string or list of strings
                              plan              ; "cloud-vps-2gb" etc
                              billing-cycle     ; integer 1–24 (months)
                              image-id          ; integer (GET /server-images)
                              custom-image-id   ; integer
                              backup-id
                              snapshot-id
                              primary-iso-id
                              secondary-iso-id
                              password          ; required if no ssh-keys
                              (ssh-keys '())    ; list of integer key IDs
                              (backups #f)
                              extra-ipv6
                              cpanel
                              bandwidth
                              promo-code
                              (amd-sev-level 0) ; 0|1|2|3
                              user-data         ; cloud-init script
                              environment-variables
                              (vpcs '())
                              payment-method    ; "card" or omit
                              quantity)
  "Deploy a new server. Returns the created server object (or array of
objects if `name` is a list / `quantity` > 1). Server is initially in
`processing`; an order is created which must be paid (auto-pays from
balance when funded)."
  (unless name (error "vpsbg-create-server: #:name required"))
  (unless plan (error "vpsbg-create-server: #:plan required"))
  (unless billing-cycle
    (error "vpsbg-create-server: #:billing-cycle required (months, 1–24)"))
  (unless (and (integer? billing-cycle)
               (>= billing-cycle 1) (<= billing-cycle 24))
    (error "vpsbg-create-server: #:billing-cycle must be an integer in [1, 24]"
           billing-cycle))
  (when (and amd-sev-level
             (not (and (integer? amd-sev-level)
                       (>= amd-sev-level 0) (<= amd-sev-level 3))))
    (error "vpsbg-create-server: #:amd-sev-level must be in {0,1,2,3}"
           amd-sev-level))
  (when (and user-data
             (string? user-data)
             (> (string-length user-data) 65536))
    (error "vpsbg-create-server: #:user-data exceeds 65536-char limit"
           (string-length user-data)))
  (when (and (not password) (null? ssh-keys))
    (error "vpsbg-create-server: must supply #:password or #:ssh-keys (key IDs)"))
  (let* ((maybe (lambda (k v) (if v `((,k . ,v)) '())))
         (body
          (append
           `(("name" . ,(if (list? name) (list->vector name) name))
             ("plan" . ,plan)
             ("billing_cycle" . ,billing-cycle))
           (maybe "image_id" image-id)
           (maybe "custom_server_image_id" custom-image-id)
           (maybe "backup_id" backup-id)
           (maybe "snapshot_id" snapshot-id)
           (maybe "primary_iso_id" primary-iso-id)
           (maybe "secondary_iso_id" secondary-iso-id)
           (maybe "password" password)
           (if (pair? ssh-keys)
               `(("ssh_keys" . ,(list->vector ssh-keys)))
               '())
           (if backups '(("backups" . #t)) '())
           (maybe "extra_ipv6" extra-ipv6)
           (maybe "cpanel" cpanel)
           (maybe "bandwidth" bandwidth)
           (maybe "promo_code" promo-code)
           (if (and (number? amd-sev-level) (> amd-sev-level 0))
               `(("amd_sev_level" . ,amd-sev-level))
               '())
           (maybe "user_data" user-data)
           (maybe "environment_variables" environment-variables)
           (if (pair? vpcs)
               `(("vpcs" . ,(list->vector vpcs)))
               '())
           (maybe "payment_method" payment-method)
           (maybe "quantity" quantity))))
    (vpsbg-http-call creds #:method 'POST #:path "/servers" #:body body)))

(define (vpsbg-get-server creds server-id)
  "Get a single server's details."
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path (string-append "/servers/" (number->string-id server-id))))

(define* (vpsbg-list-servers creds #:key (page 1) (per-page 50) status search)
  "List servers. Returns the full paginated response; use
`vpsbg-paginated-data` to extract the data[] array."
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path "/servers"
   #:query (append `((page . ,page) (per_page . ,per-page))
                   (if status `((filter[status] . ,status)) '())
                   (if search `((filter[search] . ,search)) '()))))

(define* (vpsbg-cancel-server creds server-id-or-ids
                               #:key (now #f) reason)
  "Schedule one or more servers for cancellation. VPSBG does not expose a
hard-delete: cancellation runs at the billing-period boundary unless
`#:now` is #t, in which case the server is suspended immediately.
`server-id-or-ids` may be a single id or a list of ids.

Endpoint: POST /servers/cancel (collection-level batch); returns 204."
  (let* ((ids (cond ((list? server-id-or-ids)
                     (map normalize-id server-id-or-ids))
                    (else (list (normalize-id server-id-or-ids)))))
         (body (append
                `(("server_ids" . ,(list->vector ids))
                  ("now" . ,(and now #t)))
                (if reason `(("reason" . ,reason)) '()))))
    (vpsbg-http-call creds #:method 'POST #:path "/servers/cancel"
                     #:body body)))

(define (vpsbg-undo-cancel-server creds server-id-or-ids)
  "Undo a pending cancel request. Endpoint: DELETE /servers/cancel with
{server_ids:[...]} body; returns 204."
  (let ((ids (cond ((list? server-id-or-ids)
                    (map normalize-id server-id-or-ids))
                   (else (list (normalize-id server-id-or-ids))))))
    (vpsbg-http-call creds #:method 'DELETE #:path "/servers/cancel"
                     #:body `(("server_ids" . ,(list->vector ids))))))

(define (normalize-id id)
  "Coerce an id to an integer, since VPSBG expects integer IDs in JSON bodies."
  (cond ((number? id) id)
        ((string? id)
         (or (string->number id)
             (error "vpsbg: id must be an integer or numeric string" id)))
        (else (error "vpsbg: bad id" id))))

(define (number->string-id id)
  (cond ((number? id) (number->string id))
        ((string? id) id)
        (else (error "vpsbg: bad server id" id))))

;;; ── ISOs ────────────────────────────────────────────────────────────────

(define* (vpsbg-upload-iso creds #:key url)
  "Upload an ISO by URL. VPSBG downloads it asynchronously and auto-deletes
the file 48 h after creation. URL must be 3–100 characters per the schema.
Returns the ISO object with `id`, `status` (downloading|downloaded|deleted),
`name`, `size`, `url`, `downloaded`, `created_at`, `deletion_at`. 201."
  (unless url (error "vpsbg-upload-iso: #:url required"))
  (unless (string? url)
    (error "vpsbg-upload-iso: #:url must be a string" url))
  (let ((len (string-length url)))
    (when (< len 3)
      (error "vpsbg-upload-iso: #:url too short (minLength: 3)" url))
    (when (> len 100)
      (error "vpsbg-upload-iso: #:url exceeds 100-char limit" url)))
  (vpsbg-http-call
   creds
   #:method 'POST
   #:path "/isos"
   #:body `(("url" . ,url))))

(define* (vpsbg-list-isos creds #:key (page 1) (per-page 50))
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path "/isos"
   #:query `((page . ,page) (per_page . ,per-page))))

(define (vpsbg-get-iso creds iso-id)
  "Fetch a single ISO record (id, status, name, size, url, downloaded,
created_at, deletion_at)."
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path (string-append "/isos/" (number->string-id iso-id))))

(define* (vpsbg-wait-for-iso creds iso-id
                             #:key
                             (timeout-seconds 900)   ; 15 min
                             (poll-interval 5)
                             (on-progress #f))
  "Block until the ISO finishes downloading. Returns the final ISO
record on success.

Statuses observed:
  • \"downloading\" — keep polling.
  • \"downloaded\"  — return record.
  • \"deleted\"     — VPSBG dropped the ISO (e.g. 48 h TTL hit during a
                      retry, or upstream URL went 404 mid-download).
                      Raises an error.

`on-progress`, if provided, is called with each polled record so callers
can log progress (`downloaded` / `size`). Times out after
`timeout-seconds`, raising an error — the bare upload is unaffected and
can be retried; the ISO record persists until its 48 h TTL."
  (let* ((start (clock-now))
         (deadline (+ start timeout-seconds)))
    (let loop ()
      (let* ((iso (vpsbg-get-iso creds iso-id))
             (status (or (assoc-ref iso "status") "")))
        (when on-progress (on-progress iso))
        (cond
         ((equal? status "downloaded") iso)
         ((equal? status "deleted")
          (error (format #f "vpsbg-wait-for-iso: ISO ~a was deleted before \
download completed" iso-id)))
         ((> (clock-now) deadline)
          (error (format #f "vpsbg-wait-for-iso: timed out after ~a s \
waiting for ISO ~a (last status: ~a)"
                         timeout-seconds iso-id status)))
         (else
          (sleep poll-interval)
          (loop)))))))

(define* (vpsbg-modify-server-isos creds server-id
                                   #:key
                                   (primary-iso-id 'unset)
                                   (secondary-iso-id 'unset)
                                   (boot-from-iso #t)
                                   (restart #f)
                                   password            ; required w/o 2FA
                                   otp)                ; required w/ 2FA
  "Attach/detach ISO(s) to a server.

Per the API schema, BOTH `primary_iso_id` and `secondary_iso_id` are
required fields in the request body; their value drives the action:
  • integer  → attach that ISO to the slot.
  • #f       → send explicit JSON null; detach whatever is in that slot.

To make accidental detach impossible, both keyword args are required
here (default sentinel 'unset raises). State the value for each slot
explicitly, even if you only want to change one.

The API also requires either #:password (account password) or #:otp
(2FA code) for this destructive op; calls without one will 422."
  (when (eq? primary-iso-id 'unset)
    (error "vpsbg-modify-server-isos: #:primary-iso-id required \
(integer to attach, #f to detach — API requires the field present)"))
  (when (eq? secondary-iso-id 'unset)
    (error "vpsbg-modify-server-isos: #:secondary-iso-id required \
(integer to attach, #f to detach — API requires the field present)"))
  (unless (or password otp)
    (error "vpsbg-modify-server-isos: must supply #:password (account \
password) or #:otp (2FA code); the API requires one for destructive ops"))
  (let* ((iso-cell (lambda (key v)
                     (cond ((not v) `((,key . null)))
                           ((integer? v) `((,key . ,v)))
                           (else (error
                                  "vpsbg-modify-server-isos: ISO id must be \
integer or #f" key v)))))
         (maybe (lambda (k v) (if v `((,k . ,v)) '())))
         (body
          (append (iso-cell "primary_iso_id"   primary-iso-id)
                  (iso-cell "secondary_iso_id" secondary-iso-id)
                  `(("boot_from_iso" . ,boot-from-iso)
                    ("restart" . ,restart))
                  (maybe "password" password)
                  (maybe "otp" otp))))
    (vpsbg-http-call
     creds
     #:method 'POST
     #:path (string-append "/servers/" (number->string-id server-id) "/isos")
     #:body body)))

;;; ── Custom server images ────────────────────────────────────────────────

(define* (vpsbg-add-custom-image creds #:key url name)
  "Register a custom server image. VPSBG downloads it asynchronously from
`url`. Constraints (validated client-side to fail fast):
  • `name` required, max 20 characters.
  • `url`  required, must match the API's pattern
    `^https?://.+\\.(raw|qcow2|vmdk|img)(\\?.*)?$` (case-insensitive).
    The extension must precede any query string; a trailing `?token=…` is
    fine, but `.../foo.qcow2.tmp` is not.

Returns 201 with the image object: `id`, `status` (e.g. \"downloading\"),
`name`, `url`, `size`, `downloaded`, `created_at`, `deletion_at`.
Account-level caps: max 2 in-flight downloads, ≤100 GB each, auto-deleted
48 h after creation."
  (unless url  (error "vpsbg-add-custom-image: #:url required"))
  (unless name (error "vpsbg-add-custom-image: #:name required (≤20 chars)"))
  (unless (and (string? name) (string? url))
    (error "vpsbg-add-custom-image: #:name and #:url must be strings"))
  (when (> (string-length name) 20)
    (error "vpsbg-add-custom-image: #:name exceeds 20-char limit" name))
  (unless (custom-image-url-valid? url)
    (error "vpsbg-add-custom-image: #:url does not match required pattern \
^https?://.+\\.(raw|qcow2|vmdk|img)(\\?.*)?$" url))
  (vpsbg-http-call
   creds
   #:method 'POST
   #:path "/custom-server-images"
   #:body `(("name" . ,name) ("url" . ,url))))

(define (custom-image-url-valid? url)
  "Match the VPSBG custom-image URL regex without pulling in (ice-9
regex): require http(s)://, an extension in {raw,qcow2,vmdk,img}
(case-insensitive), and allow a trailing ?query."
  (and (string? url)
       (let* ((lower (string-downcase url))
              (has-scheme? (or (string-prefix? "http://"  lower)
                               (string-prefix? "https://" lower)))
              ;; Strip an optional ?query before checking the extension.
              (path (let ((q (string-index lower #\?)))
                      (if q (substring lower 0 q) lower))))
         (and has-scheme?
              (or (string-suffix? ".raw"   path)
                  (string-suffix? ".qcow2" path)
                  (string-suffix? ".vmdk"  path)
                  (string-suffix? ".img"   path))))))

(define* (vpsbg-list-custom-images creds #:key (page 1) (per-page 50))
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path "/custom-server-images"
   #:query `((page . ,page) (per_page . ,per-page))))

;;; ── SSH keys ────────────────────────────────────────────────────────────

(define* (vpsbg-add-ssh-key creds #:key name key)
  "Register an SSH public key. Returns object with integer `id` for use in
`vpsbg-create-server #:ssh-keys`."
  (unless (and name key)
    (error "vpsbg-add-ssh-key: #:name and #:key required"))
  (vpsbg-http-call
   creds
   #:method 'POST
   #:path "/ssh-keys"
   #:body `(("name" . ,name) ("key" . ,key))))

(define* (vpsbg-list-ssh-keys creds #:key (page 1) (per-page 50))
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path "/ssh-keys"
   #:query `((page . ,page) (per_page . ,per-page))))

;;; ── Billing ─────────────────────────────────────────────────────────────

(define (vpsbg-get-balance creds)
  (vpsbg-http-call creds #:method 'GET #:path "/balance"))

(define* (vpsbg-deposit-bitcoin creds amount #:key (lightning? #f))
  "Start a BTC (or Lightning) top-up of `amount` EUR. Returns the deposit
record; for `bitcoin` the payable address is at
payment_information.address with payment_information.bitcoin_amount BTC."
  (vpsbg-http-call
   creds
   #:method 'POST
   #:path "/balance"
   #:body `(("amount" . ,amount)
            ("payment_method" . ,(if lightning? "bitcoin-ln" "bitcoin")))))

(define* (vpsbg-list-orders creds
                            #:key
                            ;; The order.status enum is documented as
                            ;;   processing | cancelled | paid | awaiting_payment
                            ;; but the *default* filter on this endpoint is
                            ;; documented as `pending_payment,paid` — likely
                            ;; a legacy alias where `pending_payment` ≡
                            ;; `awaiting_payment`. We default to the
                            ;; enum-confirmed forms; if a deployment ever
                            ;; needs `pending_payment` to match a server-side
                            ;; quirk, pass it explicitly.
                            (status "awaiting_payment,processing")
                            (page 1)
                            (per-page 50))
  (vpsbg-http-call
   creds
   #:method 'GET
   #:path "/orders"
   #:query `((page . ,page) (per_page . ,per-page)
             (filter[status] . ,status))))

;;; ── Plans ───────────────────────────────────────────────────────────────

(define (vpsbg-list-plans creds)
  "GET /servers/plans. Returns paginated response; use
`vpsbg-paginated-data` to extract the data[] array."
  (vpsbg-http-call creds #:method 'GET #:path "/servers/plans"))

(define (vpsbg-find-plan creds plan-key)
  "Look up a plan by its `key` field (e.g. \"cloud-vps-2gb\"). Returns
the plan object or #f."
  (let ((plans (vpsbg-paginated-data (vpsbg-list-plans creds))))
    (find (lambda (p) (equal? (assoc-ref p "key") plan-key))
          plans)))

(define (vpsbg-pay-orders creds order-ids)
  "Pay one or more orders (drawn from balance). Returns #t on 204.

`order-ids` must be a non-empty list of integers; the API doesn't define
a min-length but {ids: []} is meaningless and will 422 server-side."
  (when (null? order-ids)
    (error "vpsbg-pay-orders: order-ids must be a non-empty list"))
  (vpsbg-http-call
   creds
   #:method 'POST
   #:path "/orders/pay"
   #:body `(("ids" . ,(list->vector order-ids)))))

;;; ── Server response helpers ─────────────────────────────────────────────

(define (vpsbg-server-primary-ip server)
  "Extract the primary IPv4 address from a server object. The API's
`ip_addresses[]` items have fields `ip_address` (string), `version`
(integer, 4 or 6), `main` (boolean, true = primary), and `type`
(\"public\" etc). We prefer the entry with main=true; otherwise first v4."
  (let* ((raw (assoc-ref server "ip_addresses"))
         (ips (cond ((vector? raw) (vector->list raw))
                    ((list? raw) raw)
                    (else '())))
         (v4 (filter (lambda (ip) (equal? (assoc-ref ip "version") 4)) ips))
         (main (find (lambda (ip) (equal? (assoc-ref ip "main") #t)) v4)))
    (let ((chosen (or main (and (pair? v4) (car v4)))))
      (and chosen (assoc-ref chosen "ip_address")))))

;;; ── Bitcoin URI ─────────────────────────────────────────────────────────
;;;
;;; Format: bitcoin:<address>?amount=<btc>&label=<text>   (BIP-21)

(define-record-type <bitcoin-uri>
  (make-bitcoin-uri address amount-btc label)
  bitcoin-uri?
  (address    bitcoin-uri-address)
  (amount-btc bitcoin-uri-amount-btc)
  (label      bitcoin-uri-label))

(define (parse-bitcoin-uri uri-str)
  "Parse a BIP-21 bitcoin: URI. Returns a <bitcoin-uri> record or #f."
  (and (string? uri-str)
       (>= (string-length uri-str) 8)
       (string=? "bitcoin:" (substring uri-str 0 8))
       (let* ((rest (substring uri-str 8))
              (q-pos (string-index rest #\?))
              (address (if q-pos (substring rest 0 q-pos) rest))
              (query (if q-pos (substring rest (+ q-pos 1)) "")))
         (let ((params (parse-query-string query)))
           (make-bitcoin-uri
            address
            (let ((amt (assoc-ref params "amount")))
              (and amt (string->number amt)))
            (assoc-ref params "label"))))))

(define* (build-bitcoin-uri address #:key amount-btc label)
  "Build a BIP-21 bitcoin: URI."
  (let* ((params
          (append (if amount-btc
                      `(("amount" . ,(format #f "~a" amount-btc)))
                      '())
                  (if label `(("label" . ,label)) '()))))
    (string-append
     "bitcoin:" address
     (if (null? params)
         ""
         (string-append "?" (format-query params))))))

(define (normalize-billing-cycle v)
  "Translate a generic desired-host billing-cycle (any of: integer 1–24,
the symbol/string \"monthly\"/\"yearly\", or #f) into the integer months
VPSBG's `billing_cycle` field requires."
  (cond
   ((number? v) (inexact->exact (round v)))
   ((or (not v) (eq? v 'monthly) (equal? v "monthly")) 1)
   ((or (eq? v 'yearly) (equal? v "yearly")) 12)
   ((string? v) (or (string->number v) 1))
   (else 1)))

(define (btc->satoshis btc)
  "Convert BTC (decimal) to satoshis (integer, 10^-8 BTC per sat).
Mirrors `xmr->atomic` from the SporeStack adapter so create-invoice
return values are in atomic units consistently across providers."
  (inexact->exact (round (* (or btc 0) 100000000))))

(define (parse-query-string s)
  (if (string-null? s)
      '()
      (map (lambda (pair)
             (let ((eq (string-index pair #\=)))
               (if eq
                   (cons (uri-decode (substring pair 0 eq))
                         (uri-decode (substring pair (+ eq 1))))
                   (cons (uri-decode pair) ""))))
           (string-split s #\&))))

;;; ── Provider protocol ───────────────────────────────────────────────────
;;;
;;; The fleet protocol expects: create-invoice, poll-payment, launch,
;;; poll-server, delete-server, list-servers.
;;;
;;; VPSBG's payment model is "fund balance up front, then orders auto-pay
;;; from balance." So we deliberately do NOT create a server in
;;; create-invoice. Instead we:
;;;
;;;   1. create-invoice: look up plan price × billing_cycle, compare with
;;;      GET /balance. If balance already covers it, return an empty URI
;;;      and a synthetic placeholder id; poll-payment will see 'funded
;;;      immediately. Otherwise POST /balance to start a BTC deposit for
;;;      the shortfall, return its BIP-21 URI. No server exists yet.
;;;   2. poll-payment: re-check GET /balance vs the same cost target.
;;;      'funded when balance covers it. The user pays the BIP-21 URI
;;;      from their own wallet; we just watch for the deposit to settle.
;;;   3. launch: NOW upload the Guix ISO (if any), wait for it to finish
;;;      downloading on VPSBG's side, then POST /servers with
;;;      primary_iso_id set so the new VM boots straight off the ISO.
;;;      Order auto-pays from the funded balance during the same call.
;;;   4. poll-server: GET /servers/{id} → (running? ipv4).
;;;   5. delete-server: POST /servers/cancel (now=true).
;;;
;;; This means no failed POST /servers, no orphan orders, no after-the-
;;; fact ISO modify-and-restart dance, no need for the account password
;;; or 2FA OTP. The cost of being right: one extra GET /servers/plans
;;; per deploy (cheap; rate limit is 200/min).

(define (make-vpsbg-provider creds)
  "Build a provider alist from VPSBG credentials."

  ;;; ── Internal helpers ───────────────────────────────────────────────

  (define (host-billing-cycle host)
    (normalize-billing-cycle (desired-host-billing-cycle host)))

  (define (host-plan-key host)
    (desired-host-flavor host))

  (define (host-cost-eur host)
    "Look up plan.price_with_vat × billing_cycle in EUR. Errors if the
plan key doesn't resolve."
    (let* ((key (host-plan-key host))
           (plan (vpsbg-find-plan creds key)))
      (unless plan
        (error (format #f "vpsbg: plan key ~s not found in /servers/plans"
                       key)))
      (let ((unit (or (assoc-ref plan "price_with_vat")
                      (assoc-ref plan "price")
                      0)))
        (* unit (host-billing-cycle host)))))

  (define (current-balance-eur)
    (or (assoc-ref (vpsbg-get-balance creds) "balance") 0))

  (define (current-min-deposit-eur)
    (or (assoc-ref (vpsbg-get-balance creds) "minimum_deposit") 10))

  (define (synthetic-invoice-id host)
    "Placeholder id used during the funding phase. Replaced by the real
server id once launch creates the VM. Includes the host name so logs
remain greppable."
    (string-append "vpsbg-pending-"
                   (or (desired-host-name host) "host")
                   "-"
                   (number->string (clock-now))))

  (define (server-from-create-resp resp)
    ;; POST /servers returns {data: [server, ...]}. Normalize to the
    ;; first server object.
    (let* ((d (or (and (list? resp) (assoc-ref resp "data")) resp)))
      (cond ((vector? d) (and (> (vector-length d) 0) (vector-ref d 0)))
            ((and (list? d) (assoc-ref d "id")) d)
            ((and (list? d) (pair? d) (list? (car d))) (car d))
            (else d))))

  (define (upload-and-wait-iso host iso-url)
    "Upload ISO to VPSBG, poll until status=downloaded. Returns iso-id."
    (let* ((params (desired-host-provider-params host))
           (iso-timeout (or (assoc-ref params "iso-download-timeout") 900))
           (iso-poll-interval (or (assoc-ref params "iso-poll-interval") 5))
           (log-progress
            (lambda (rec)
              (let ((s (assoc-ref rec "status"))
                    (d (or (assoc-ref rec "downloaded") 0))
                    (t (or (assoc-ref rec "size") 0))
                    (id (assoc-ref rec "id")))
                (format (current-error-port)
                        "vpsbg launch: ISO ~a ~a ~a/~a bytes~%"
                        id s d t))))
           (iso (vpsbg-upload-iso creds #:url iso-url))
           (iso-id (assoc-ref iso "id")))
      (unless iso-id
        (error "vpsbg launch: ISO upload returned no id" iso))
      (vpsbg-wait-for-iso creds iso-id
                          #:timeout-seconds iso-timeout
                          #:poll-interval iso-poll-interval
                          #:on-progress log-progress)
      iso-id))

  ;;; ── Protocol ops ───────────────────────────────────────────────────

  `((create-invoice
     . ,(lambda (host)
          ;; Decide whether a deposit is needed BEFORE touching /servers.
          (let* ((cost     (host-cost-eur host))
                 (balance  (current-balance-eur))
                 (deficit  (max 0 (- cost balance))))
            (format (current-error-port)
                    "vpsbg create-invoice: plan ~s × ~a mo = €~a, \
balance €~a, deficit €~a~%"
                    (host-plan-key host) (host-billing-cycle host)
                    cost balance deficit)
            (cond
             ;; Balance already covers the cost: no payment step at all.
             ((<= deficit 0)
              (values (synthetic-invoice-id host) "" 'btc 0))
             ;; Need a top-up. Round up to the API's minimum_deposit so
             ;; POST /balance doesn't 422. Surplus stays as credit.
             (else
              (let* ((min-dep (current-min-deposit-eur))
                     (deposit-eur (max deficit min-dep))
                     (resp (vpsbg-deposit-bitcoin creds deposit-eur))
                     (pi   (assoc-ref resp "payment_information"))
                     (addr (and pi (assoc-ref pi "address")))
                     (btc  (and pi (assoc-ref pi "bitcoin_amount")))
                     (uri  (if addr
                               (build-bitcoin-uri
                                addr
                                #:amount-btc btc
                                #:label (desired-host-name host))
                               "")))
                (format (current-error-port)
                        "vpsbg create-invoice: deposit URI for €~a (~a BTC) → ~a~%"
                        deposit-eur btc addr)
                (values (synthetic-invoice-id host)
                        uri
                        'btc
                        (btc->satoshis btc))))))))

    (poll-payment
     . ,(lambda (host entry)
          ;; Just compare live balance vs cost target. Idempotent and
          ;; cheap. Recomputes cost so we don't rely on threading state
          ;; through `entry`.
          (let* ((cost    (host-cost-eur host))
                 (balance (current-balance-eur)))
            (if (>= balance cost) 'funded 'pending))))

    (launch
     . ,(lambda (host entry)
          ;; At this point balance covers the cost. Do the deploy now:
          ;;   1. Optionally upload ISO and wait for `downloaded`.
          ;;   2. POST /servers with primary_iso_id (if any). Order
          ;;      auto-pays from balance off-session in the same call.
          ;;   3. Return the real server id; the orchestrator uses this
          ;;      as machine-id from here on.
          (let* ((params   (desired-host-provider-params host))
                 (iso-url  (assoc-ref params "iso-url"))
                 (iso-id   (and iso-url (upload-and-wait-iso host iso-url)))
                 (hostname (let ((h (desired-host-hostname host)))
                             (if (or (not h) (string-null? h))
                                 (desired-host-name host)
                                 h)))
                 (cycle    (host-billing-cycle host))
                 (udata    (or (desired-host-user-data host)
                               (assoc-ref params "user-data")))
                 (sev      (or (assoc-ref params "amd-sev-level") 0))
                 (img      (assoc-ref params "image-id"))
                 (cimg     (assoc-ref params "custom-image-id"))
                 (sshks    (or (assoc-ref params "ssh-key-ids") '()))
                 (pwd      (assoc-ref params "password"))
                 (resp     (vpsbg-create-server
                            creds
                            #:name hostname
                            #:plan (host-plan-key host)
                            #:billing-cycle cycle
                            #:primary-iso-id iso-id
                            #:image-id img
                            #:custom-image-id cimg
                            #:ssh-keys sshks
                            #:password pwd
                            #:amd-sev-level sev
                            #:user-data udata))
                 (server   (server-from-create-resp resp))
                 (server-id (and server (assoc-ref server "id"))))
            (unless server-id
              (error "vpsbg launch: POST /servers returned no id" resp))
            (format (current-error-port)
                    "vpsbg launch: server ~a created (booting off ~a)~%"
                    server-id
                    (cond (iso-id  (format #f "ISO ~a" iso-id))
                          (cimg    (format #f "custom image ~a" cimg))
                          (img     (format #f "stock image ~a" img))
                          (else    "default")))
            (number->string-id server-id))))

    (poll-server
     . ,(lambda (machine-id)
          ;; A synthetic placeholder id reaching this op is a bug — guard
          ;; against it instead of 404ing on `/servers/vpsbg-pending-…`.
          (if (and (string? machine-id)
                   (string-prefix? "vpsbg-pending-" machine-id))
              (values #f "")
              (let* ((srv (vpsbg-get-server creds machine-id))
                     (status (or (assoc-ref srv "status") ""))
                     (ip (or (vpsbg-server-primary-ip srv) "")))
                (values (equal? status "active") ip)))))

    (delete-server
     . ,(lambda (machine-id)
          ;; Same guard: only call /servers/cancel for real numeric ids.
          (if (and (string? machine-id)
                   (string-prefix? "vpsbg-pending-" machine-id))
              #t
              ;; Cancel `now` so the slot frees up immediately rather
              ;; than at the billing-period boundary (the API default).
              (vpsbg-cancel-server creds machine-id #:now #t))))

    (list-servers
     . ,(lambda ()
          (vpsbg-paginated-data (vpsbg-list-servers creds))))))
