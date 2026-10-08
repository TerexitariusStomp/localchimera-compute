;;; module/playnet/fleet/sporestack.scm — SporeStack API client
;;;
;;; SporeStack (https://sporestack.com) is a Monero-native VPS reseller
;;; with a clean JSON REST API, no email required, path-based token
;;; authentication. It's the closest thing to "infrastructure-as-a-service
;;; designed for programmable Monero-funded automation" that exists.
;;;
;;; This module wraps the subset of the API that the fleet reconciler
;;; needs:
;;;
;;;   • top-up balance  → POST   /token/{token}/add
;;;   • balance / info  → GET    /token/{token}/balance , /info
;;;   • launch server   → POST   /token/{token}/servers
;;;   • get server      → GET    /token/{token}/servers/{machine_id}
;;;   • list servers    → GET    /token/{token}/servers
;;;   • delete server   → DELETE /token/{token}/servers/{machine_id}
;;;   • rebuild         → POST   /token/{token}/servers/{machine_id}/rebuild
;;;   • list flavors    → GET    /slugs/flavors
;;;   • list OSes       → GET    /slugs/os
;;;
;;; Authentication: the token is a long opaque string (32–64 chars,
;;; e.g. "ss_t_1deadbeefcafedeadbeef1_b092"). It is NEVER sent in an
;;; Authorization header — instead it's embedded directly in the URL
;;; path. Keep it out of query strings and logs.
;;;
;;; Token lifecycle: the token is created out-of-band by the operator
;;; using `sporestack token create --dollars 20 --currency xmr` on a
;;; trusted machine (the CLI does the top-up roundtrip). The resulting
;;; token string goes into secrets.scm as SPORESTACK_TOKEN and is read
;;; by the fleet reconciler at gateway startup time. The token itself
;;; is the long-term credential; the balance is topped up on demand
;;; by the reconciler whenever a new host is being provisioned.
;;;
;;; Monero URI parsing: when the reconciler calls `sporestack-add-funds`
;;; the response includes a `payment_uri` in BIP-21-style format:
;;;
;;;   monero:4AAA...BBB?tx_amount=0.0421
;;;
;;; This module exposes `parse-monero-uri` which extracts the raw
;;; address and the amount (in XMR) so the reconciler can hand them
;;; to the wallet-policy's `transfer` method.

(define-module (playnet fleet sporestack)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module ((srfi srfi-13) #:select (string-prefix?))
  #:use-module (json)
  ;; vpsbg.scm (a sibling fleet provider, always loaded alongside this one via
  ;; reconciler.scm) already redeclares Content-Type globally to accept a bare
  ;; string; that redeclaration is process-wide once ANY module imports it, so
  ;; this module must use the SAME convention rather than Guile's stock
  ;; structured form — importing here makes it correct standalone too.
  #:use-module (playnet utils http-auth)
  #:export (make-sporestack-creds
            sporestack-creds?
            sporestack-creds-endpoint
            sporestack-creds-token
            sporestack-default-endpoint

            generate-sporestack-token
            wait-for-token-funded

            ;; Invoice / payment
            sporestack-add-funds
            invoice-payment-uri
            invoice-amount-usd-cents
            invoice-expires
            invoice-paid?
            invoice-id

            parse-monero-uri
            monero-uri-address
            monero-uri-amount-xmr
            monero-uri-description
            monero-uri?

            ;; Token info
            sporestack-balance
            sporestack-info

            ;; Servers
            sporestack-launch-server
            sporestack-get-server
            sporestack-list-servers
            sporestack-delete-server
            sporestack-rebuild-server
            server-machine-id
            server-ipv4
            server-ipv6
            server-running?
            server-hostname
            server-flavor-slug
            server-operating-system

            ;; Slugs
            sporestack-list-flavors
            sporestack-list-operating-systems

            ;; Low-level (for tests / custom transports):
            sporestack-http-call))

;;; ── Credentials ──────────────────────────────────────────────────────────

(define sporestack-default-endpoint
  "https://api.sporestack.com")

;;; The token's location on disk is deployment layout, not this vendor's
;;; API: see (playnet fleet paths) `provider-token-file'.

(define (generate-sporestack-token)
  "Generate a 64-char hex token from /dev/urandom, prefixed with ss_t_
to match SporeStack's convention. The token IS the credential — there is
no account, no email, no signup."
  (let* ((bv (call-with-input-file "/dev/urandom"
               (lambda (port) (get-bytevector-n port 32))))
         (hex (string-concatenate
               (map (lambda (i)
                      (format #f "~2,'0x" (bytevector-u8-ref bv i)))
                    (iota (bytevector-length bv))))))
    (string-append "ss_t_" hex)))

(define* (wait-for-token-funded creds
                                #:key
                                (poll-interval 15)
                                (max-ticks 120)  ; 30 min at 15 s
                                (on-tick (lambda (tick) #f)))
  "Poll sporestack-balance until cents > 0 or MAX-TICKS reached. Calls
ON-TICK each iteration with the tick number. Returns the final balance
alist on success, or #f on timeout. Catches transport errors silently
(network blips during the wait are normal). Defaults match the
reconciler's automated path (30 min cap); the CLI script can pass a
larger MAX-TICKS for a more patient interactive wait."
  (let loop ((tick 0))
    (let* ((info (catch #t
                   (lambda () (sporestack-balance creds))
                   (lambda _ '())))
           (cents (or (assoc-ref info "cents") 0)))
      (cond
       ((> cents 0) info)
       ((> tick max-ticks) #f)
       (else
        (on-tick tick)
        (sleep poll-interval)
        (loop (+ tick 1)))))))

(define-record-type <sporestack-creds>
  (make-sporestack-creds endpoint token)
  sporestack-creds?
  (endpoint sporestack-creds-endpoint)  ; base URL, no trailing slash
  (token    sporestack-creds-token))    ; long opaque token string

;;; ── Low-level HTTP call ──────────────────────────────────────────────────
;;;
;;; All SporeStack endpoints return JSON except DELETE/rebuild which
;;; return 204 no-content. We normalize so callers always get either a
;;; parsed alist or #t for empty success; errors raise with status +
;;; body for debugging.

(define* (sporestack-http-call creds
                               #:key
                               method
                               path
                               body
                               (query '()))
  "Issue an HTTP call against the SporeStack API. METHOD is one of
'GET, 'POST, 'DELETE. PATH is the URL path (without the endpoint
base). BODY, if set, is a Scheme alist serialized to JSON. QUERY is
an alist of query string params. Returns either the parsed JSON
response or #t for 204 responses."
  (let* ((qs (if (null? query)
                 ""
                 (string-append "?" (format-query query))))
         (url (string-append (sporestack-creds-endpoint creds) path qs))
         (body-bytes (and body
                          (string->utf8 (scm->json-string body))))
         (headers (if body
                      '((content-type . "application/json"))
                      '())))
    (call-with-values
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
            ((DELETE)
             (http-delete url
                          #:headers headers
                          #:streaming? #f
                          #:decode-body? #f
                          #:verify-certificate? #t))
            (else (error "sporestack-http-call: unsupported method" method))))
      (lambda (response body-bv)
        (let* ((code (response-code response))
               (body-str (if (bytevector? body-bv)
                             (utf8->string body-bv)
                             (or body-bv ""))))
          (cond
           ;; 204 no-content success.
           ((= code 204) #t)
           ;; 2xx with JSON body.
           ((and (>= code 200) (< code 300))
            (if (string-null? body-str)
                #t
                (json-string->scm body-str)))
           ;; Anything else: error with body for diagnosis.
           (else
            (error (format #f "sporestack ~a ~a: HTTP ~a ~a"
                           method path code body-str)))))))))

(define (format-query alist)
  (string-join
   (map (lambda (kv)
          (string-append (uri-encode (format #f "~a" (car kv)))
                         "="
                         (uri-encode (format #f "~a" (cdr kv)))))
        alist)
   "&"))

(define (token-path creds suffix)
  (string-append "/token/" (sporestack-creds-token creds) suffix))

;;; ── Invoices / top-up ────────────────────────────────────────────────────

(define* (sporestack-add-funds creds
                               #:key
                               (currency "xmr")
                               dollars
                               (affiliate-token #f))
  "Request a top-up invoice for DOLLARS of credit in CURRENCY. Returns
an alist representing the parsed InvoiceRead record. The
`payment_uri` field holds the BIP-21 style URI (e.g. monero:...),
from which the reconciler extracts the target address + amount to
pay via the wallet-policy."
  (sporestack-http-call
   creds
   #:method 'POST
   #:path (token-path creds "/add")
   #:body `(("currency" . ,currency)
            ("dollars" . ,dollars)
            ,@(if affiliate-token
                  `(("affiliate_token" . ,affiliate-token))
                  '()))))

(define (invoice-payment-uri invoice)
  (assoc-ref invoice "payment_uri"))
(define (invoice-amount-usd-cents invoice)
  (assoc-ref invoice "amount"))
(define (invoice-expires invoice)
  (assoc-ref invoice "expires"))
(define (invoice-paid? invoice)
  (let ((p (assoc-ref invoice "paid")))
    (and p (not (zero? p)))))
(define (invoice-id invoice)
  (assoc-ref invoice "id"))

;;; ── Monero URI parser ────────────────────────────────────────────────────
;;;
;;; Format: `monero:<address>?tx_amount=<x>&tx_description=<y>&...`
;;; The colon-scheme is `monero`; the authority is the raw Monero
;;; address; the query string carries the amount in XMR (not atomic
;;; units) per BIP-21 convention.

(define-record-type <monero-uri>
  (make-monero-uri address amount-xmr description)
  monero-uri?
  (address     monero-uri-address)
  (amount-xmr  monero-uri-amount-xmr)   ; number (XMR) or #f
  (description monero-uri-description)) ; string or #f

(define (parse-monero-uri uri-str)
  "Parse a BIP-21-style monero: URI. Returns a <monero-uri> record
or #f if the string doesn't look like one."
  (and (string? uri-str)
       (string-prefix? "monero:" uri-str)
       (let* ((rest (substring uri-str 7))  ; strip "monero:"
              (q-pos (string-index rest #\?))
              (address (if q-pos (substring rest 0 q-pos) rest))
              (query (if q-pos (substring rest (+ q-pos 1)) "")))
         (let ((params (parse-query-string query)))
           (make-monero-uri
            address
            (let ((amt (assoc-ref params "tx_amount")))
              (and amt (string->number amt)))
            (assoc-ref params "tx_description"))))))

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

;; string-prefix? imported from (srfi srfi-13)

;;; ── Token info ───────────────────────────────────────────────────────────

(define (sporestack-balance creds)
  "Returns the token's current balance alist with 'cents' and 'usd' keys."
  (sporestack-http-call creds
                        #:method 'GET
                        #:path (token-path creds "/balance")))

(define (sporestack-info creds)
  "Returns fuller TokenInfo alist (balance, burn rate, server counts)."
  (sporestack-http-call creds
                        #:method 'GET
                        #:path (token-path creds "/info")))

;;; ── Servers ──────────────────────────────────────────────────────────────

(define* (sporestack-launch-server creds
                                   #:key
                                   flavor
                                   ssh-key
                                   operating-system
                                   provider
                                   (region #f)
                                   (hostname "")
                                   (days 1)
                                   (autorenew #f)
                                   (billing-cycle "daily")
                                   (user-data #f))
  "Launch a server. Returns an alist with at least 'machine_id'."
  (sporestack-http-call
   creds
   #:method 'POST
   #:path (token-path creds "/servers")
   #:body
   (append
    `(("flavor" . ,flavor)
      ("ssh_key" . ,ssh-key)
      ("operating_system" . ,operating-system)
      ("provider" . ,provider)
      ("hostname" . ,hostname)
      ("autorenew" . ,autorenew)
      ("billing_cycle" . ,billing-cycle))
    (if region `(("region" . ,region)) '())
    (if days `(("days" . ,days)) '())
    (if user-data `(("user_data" . ,user-data)) '()))))

(define (sporestack-get-server creds machine-id)
  "Get a single server's details. Returns the TokenServerRead alist."
  (sporestack-http-call
   creds
   #:method 'GET
   #:path (token-path creds (string-append "/servers/" machine-id))))

(define* (sporestack-list-servers creds
                                  #:key
                                  (include-deleted #t)
                                  (include-forgotten #t)
                                  (hostname #f))
  "List servers on the token. Returns an alist with a 'servers' key
whose value is a vector of TokenServerRead alists."
  (sporestack-http-call
   creds
   #:method 'GET
   #:path (token-path creds "/servers")
   #:query
   (append
    `((include_deleted . ,include-deleted)
      (include_forgotten . ,include-forgotten))
    (if hostname `((hostname . ,hostname)) '()))))

(define (sporestack-delete-server creds machine-id)
  "Destroy a server. Returns #t on success. Refunds remaining balance
to the token."
  (sporestack-http-call
   creds
   #:method 'DELETE
   #:path (token-path creds (string-append "/servers/" machine-id))))

(define (sporestack-rebuild-server creds machine-id)
  "Rebuild a server with the original OS + SSH key. Destroys all data
and takes ~2 minutes to complete. Returns #t on success."
  (sporestack-http-call
   creds
   #:method 'POST
   #:path (token-path creds
                      (string-append "/servers/" machine-id "/rebuild"))
   #:body '()))

;;; Server accessors — thin wrappers around assoc-ref so callers don't
;;; have to remember the exact JSON field names.

(define (server-machine-id server)        (assoc-ref server "machine_id"))
(define (server-ipv4 server)              (assoc-ref server "ipv4"))
(define (server-ipv6 server)              (assoc-ref server "ipv6"))
(define (server-running? server)
  (let ((r (assoc-ref server "running")))
    (and r (not (eq? r 'false)) (not (eq? r #f)))))
(define (server-hostname server)          (assoc-ref server "hostname"))
(define (server-flavor-slug server)       (assoc-ref server "flavor_slug"))
(define (server-operating-system server)  (assoc-ref server "operating_system"))

;;; ── Slugs (static catalog queries) ───────────────────────────────────────

(define* (sporestack-list-flavors creds #:key (provider #f))
  (sporestack-http-call
   creds
   #:method 'GET
   #:path "/slugs/flavors"
   #:query (if provider `((provider . ,provider)) '())))

(define* (sporestack-list-operating-systems creds #:key (provider #f))
  (sporestack-http-call
   creds
   #:method 'GET
   #:path "/slugs/os"
   #:query (if provider `((provider . ,provider)) '())))
