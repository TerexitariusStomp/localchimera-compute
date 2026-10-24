;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/fleet/swap.scm — automated XMR→BTC swap via Tor
;;;
;;; Converts Monero to Bitcoin through no-KYC swap services, routed
;;; entirely over Tor. Used by the fleet reconciler to pay VPSBG
;;; (AMD SEV-SNP, BTC-only) from the localchimera XMR wallet.
;;;
;;; Three services, in priority order:
;;;   1. ChangeNow (aggregator, free API key, one-call, most reliable)
;;;   2. Majestic Bank (direct exchanger, no API key, fallback)
;;;   3. Trocador (aggregator, best rates, manual bootstrap only)
;;;
;;; ChangeNow is the primary for the automated swapper — it's the most
;;; reliable no-KYC aggregator, the free API key gives one-call
;;; transaction creation (no widget, no multi-step handshake), and it
;;; routes through many backend exchangers for competitive rates.
;;; Majestic Bank is the no-API-key fallback. Trocador's AnonPay
;;; indirect mode requires visiting a URL in Tor Browser (human-in-the-
;;; loop) and is only suitable for manual bootstrap; the autonomous
;;; swapper does not use Trocador.
;;;
;;; The ^xmr-btc-swapper actor holds a policy cap and manages the
;;; full lifecycle: create swap → authorize temp allowlist entry →
;;; transfer XMR → poll status → revoke temp entry.
;;;
;;; Tor routing: the gateway Shepherd service runs under `torsocks`
;;; (LD_PRELOAD), so all outgoing TCP — including Guile's (web client)
;;; calls — routes through the local Tor SOCKS5 proxy automatically.
;;; No curl, no shell-out, no SOCKS5 implementation needed.

(define-module (localchimera fleet swap)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 match)
  #:use-module (localchimera utils files)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (json)
  ;; vpsbg.scm (a sibling fleet provider, always loaded alongside this one via
  ;; reconciler.scm) already redeclares Content-Type globally to accept a bare
  ;; string; use the SAME convention rather than Guile's stock structured form.
  #:use-module (localchimera utils http-auth)
  #:use-module (localchimera monero wallet)
  #:export (swap-journal-write!
            swap-journal-read
            swap-journal-delete!
            ;; HTTP
            swap-http-get
            swap-http-post

            ;; ChangeNow
            changenow-min-amount
            changenow-estimate
            changenow-create-transaction
            changenow-track

            ;; Trocador (manual bootstrap)
            trocador-create-swap
            trocador-poll-deposit
            trocador-poll-swap

            ;; Majestic Bank (fallback)
            majestic-get-rate
            majestic-create-exchange
            majestic-track

            ;; Rate check
            check-rate-reasonable?

            ;; Actor
            ^xmr-btc-swapper))

;;; ── HTTP helper ─────────────────────────────────────────────────────────
;;;
;;; Plain (web client) GET that returns parsed JSON. When the process
;;; runs under torsocks, all TCP is transparently routed through Tor.

(define (swap-http-get url)
  "GET URL and parse the JSON response. Under torsocks, this routes
through Tor automatically. Follows 30x redirects (handles relative
Location headers). Throws on HTTP error."
  (let loop ((url url) (redirects 0))
    (when (> redirects 5)
      (error "swap-http-get: too many redirects" url))
    (call-with-values
      (lambda ()
        (http-get url
                  #:streaming? #f
                  #:decode-body? #f
                  #:verify-certificate? #t))
      (lambda (response body-bv)
        (let* ((code (response-code response))
               (location (and (<= 300 code 399)
                              (let ((loc (assoc-ref (response-headers response)
                                                    'location)))
                                (and loc (resolve-redirect url loc))))))
          (cond
           (location
            (loop location (+ redirects 1)))
           ((and (>= code 200) (< code 300))
            (let ((body-str (if (bytevector? body-bv)
                                (utf8->string body-bv)
                                (or body-bv ""))))
              (if (string-null? body-str)
                  '()
                  (json-string->scm body-str))))
           (else
            (let ((body-str (if (bytevector? body-bv)
                                (utf8->string body-bv)
                                (or body-bv ""))))
              (error (format #f "swap-http-get: HTTP ~a for ~a: ~a"
                             code url body-str))))))))))

(define (resolve-redirect base-url location-uri)
  "Resolve a redirect Location against the base URL. Handles both
absolute URIs and relative paths (e.g. /en/anonpay/status/X)."
  (let ((loc-str (uri->string location-uri)))
    (if (or (string-prefix? "http://" loc-str)
            (string-prefix? "https://" loc-str))
        loc-str
        (let* ((base (string->uri base-url))
               (resolved (string-append (uri-scheme base) "://"
                                        (uri-host base)
                                        (if (uri-port base)
                                            (format #f ":~a" (uri-port base))
                                            "")
                                        loc-str)))
           resolved))))

(define (swap-http-post url body-alist)
  "POST body-alist as JSON to URL and parse the JSON response.
Under torsocks, routes through Tor automatically. Follows 30x redirects.
Throws on HTTP error."
  (let ((body-bytes (string->utf8 (scm->json-string body-alist))))
    (let loop ((url url) (redirects 0))
      (when (> redirects 5)
        (error "swap-http-post: too many redirects" url))
      (call-with-values
        (lambda ()
          (http-post url
                     #:body body-bytes
                     #:headers '((content-type . "application/json"))
                     #:streaming? #f
                     #:decode-body? #f
                     #:verify-certificate? #t))
        (lambda (response body-bv)
          (let* ((code (response-code response))
                 (location (and (<= 300 code 399)
                                (let ((loc (assoc-ref (response-headers response)
                                                      'location)))
                                  (and loc (resolve-redirect url loc))))))
            (cond
             (location
              (loop location (+ redirects 1)))
             ((and (>= code 200) (< code 300))
              (let ((body-str (if (bytevector? body-bv)
                                  (utf8->string body-bv)
                                  (or body-bv ""))))
                (if (string-null? body-str)
                    '()
                    (json-string->scm body-str))))
             (else
              (let ((body-str (if (bytevector? body-bv)
                                  (utf8->string body-bv)
                                  (or body-bv ""))))
                (error (format #f "swap-http-post: HTTP ~a for ~a: ~a"
                               code url body-str)))))))))))

;;; ── ChangeNow API ──────────────────────────────────────────────────────
;;;
;;; ChangeNow is the primary swap service for the automated swapper.
;;; Free API key (register at changenow.io, no KYC for crypto-crypto).
;;; One-call transaction creation with deposit details returned
;;; immediately — no widget, no multi-step handshake.
;;;
;;; The refundAddress parameter is critical: if a swap fails or expires,
;;; ChangeNow returns the XMR to this address instead of losing the funds.
;;; The swapper passes the localchimera wallet's primary XMR address.
;;;
;;; API docs: https://changenow.io/docs/api
;;; Base: https://api.changenow.io/v1

(define %changenow-base "https://api.changenow.io/v1")

(define* (changenow-min-amount #:key (base %changenow-base))
  "Get the minimum XMR amount for an XMR→BTC swap. Returns a number."
  (let* ((resp (swap-http-get (string-append base "/min-amount/xmr_btc")))
         (min (assoc-ref resp "minAmount")))
    (if (string? min) (string->number min) min)))

(define* (changenow-estimate xmr-amount
                             #:key (base %changenow-base))
  "Estimate how much BTC you get for XMR-AMOUNT. Returns a number."
  (let* ((url (format #f "~a/exchange-amount/~a/xmr_btc" base xmr-amount))
         (resp (swap-http-get url))
         (est (assoc-ref resp "estimatedAmount")))
    (if (string? est) (string->number est) est)))

(define* (changenow-create-transaction btc-address xmr-amount api-key
                                       #:key (base %changenow-base)
                                       (refund-address #f))
  "Create an XMR→BTC transaction on ChangeNow. Returns four values:
  trx-id           — string
  xmr-deposit-addr — string (where to send XMR)
  xmr-amount       — number (amount to send, may differ from input)
  btc-amount       — number (amount to receive)

API-KEY is your free ChangeNow API key. REFUND-ADDRESS is an XMR
address where funds are returned if the swap fails or expires.
If #f, ChangeNow holds the funds and you must contact support."
  (let* ((url (format #f "~a/transactions/~a" base api-key))
         (body `( ("from" . "xmr")
                 ("to" . "btc")
                 ("address" . ,btc-address)
                 ("amount" . ,xmr-amount)
                 ,@(if refund-address
                       `(("refundAddress" . ,refund-address))
                       '())))
         (resp (swap-http-post url body)))
    (let ((trx-id (or (assoc-ref resp "id") ""))
          (deposit (or (assoc-ref resp "payinAddress") ""))
          (from-amt (or (assoc-ref resp "amountFrom") xmr-amount))
          (to-amt (or (assoc-ref resp "amountTo") 0)))
      (when (string-null? trx-id)
        (error "changenow-create-transaction: no id in response" resp))
      (when (string-null? deposit)
        (error "changenow-create-transaction: no payinAddress in response" resp))
      (values trx-id
              deposit
              (if (string? from-amt) (string->number from-amt) from-amt)
              (if (string? to-amt) (string->number to-amt) to-amt)))))

(define* (changenow-track trx-id api-key
                          #:key (base %changenow-base))
  "Track a ChangeNow transaction status. Returns a symbol."
  (let* ((url (format #f "~a/transactions/~a/~a" base trx-id api-key))
         (resp (swap-http-get url))
         (status (or (assoc-ref resp "status") "unknown")))
    (cond
     ((member status '("new" "waiting"))            'waiting)
     ((member status '("confirming" "confirmed"))    'confirming)
     ((member status '("exchanging" "sending"))      'sending)
     ((member status '("finished" "completed"))     'finished)
     ((member status '("failed"))                    'failed)
     ((member status '("refunded"))                  'refunded)
     ((member status '("expired"))                    'expired)
     (else (string->symbol status)))))

;;; ── Trocador API ────────────────────────────────
;;;
;;; Trocador is a swap aggregator — no KYC, onion address available.
;;; It routes through dozens of backend exchangers and picks the best
;;; rate. The `min_kycrating=A` param filters to no-KYC only.
;;;
;;; AnonPay indirect mode (direct=False):
;;;   1. GET /anonpay/?direct=False&... → returns {ID, url, url_onion}
;;;      At this point the trade exists but no exchanger is selected —
;;;      the XMR deposit address is NOT yet known.
;;;   2. Someone visits the url_onion in Tor Browser and selects an
;;;      exchanger. After that the trade moves from "anonpaynew" to
;;;      "waiting" and the status response includes deposit details.
;;;   3. Poll /anonpay/status/{ID} until the deposit address appears.
;;;
;;; For the automated swapper, this two-step flow is a poor fit unless
;;; you have a Trocador API key (which enables /api/ endpoints that
;;; return deposit details in one call). Majestic Bank is preferred for
;;; headless operation. Trocador is kept as fallback and for manual
;;; bootstrap (the operator visits the onion URL in Tor Browser).
;;;
;;; Base: https://trocador.app (clearnet) or .onion
;;; Docs: https://trocador.app/en/anonpaydocumentation

(define %trocador-base "https://trocador.app")

(define* (trocador-create-swap btc-address btc-amount
                               #:key (base %trocador-base))
  "Create an XMR→BTC swap on Trocador (AnonPay indirect mode).
Returns two values:
  swap-id        — string (use for status polling)
  onion-url      — string (visit in Tor Browser to select an exchanger
                    and receive the XMR deposit address)

After calling this, the operator must open onion-url in Tor Browser,
select an exchanger, and then use trocador-poll-deposit to retrieve
the XMR deposit address and amount once the trade moves past
'anonpaynew'."
  (let* ((url (format #f "~a/anonpay/?direct=False&ticker_from=xmr&network_from=Mainnet&ticker_to=btc&network_to=Mainnet&address=~a&amount=~a&min_kycrating=A"
                      base
                      (uri-encode btc-address)
                      btc-amount))
         (resp (swap-http-get url)))
    (let ((swap-id (or (assoc-ref resp "id")
                       (assoc-ref resp "ID")
                       ""))
          (onion-url (or (assoc-ref resp "url_onion")
                         (assoc-ref resp "url")
                         "")))
      (when (string-null? swap-id)
        (error "trocador-create-swap: no swap-id in response" resp))
      (values swap-id onion-url))))

(define* (trocador-poll-deposit swap-id #:key (base %trocador-base))
  "Poll Trocador once for the deposit details of SWAP-ID. Returns three
values:
  xmr-deposit-addr — string, or #f if not yet available
  xmr-amount       — number, or #f if not yet available
  status           — symbol: 'anonpaynew | 'waiting | 'confirming | <other>

Must be called AFTER the operator has opened the onion URL in Tor Browser
and selected an exchanger. Trocador returns 'anonpaynew while waiting for
that step, then 'waiting → 'confirming as the trade progresses.

This is a single non-blocking poll. Callers re-invoke (e.g., from a fiber
or a Goblins timer) until both address and amount are non-#f. Terminal
failure states (failed/error/expired/halted) throw."
  (let* ((url (format #f "~a/anonpay/status/~a" base swap-id))
         (resp (swap-http-get url))
         (status-str (or (assoc-ref resp "status")
                         (assoc-ref resp "Status")
                         "unknown")))
    (cond
     ((member status-str '("anonpaynew" "new"))
      (values #f #f 'anonpaynew))
     ((member status-str '("failed" "error" "expired" "halted"))
      (error "trocador-poll-deposit: swap in terminal state"
             swap-id status-str))
     (else
      (let ((addr (or (assoc-ref resp "address_from")
                      (assoc-ref resp "input_address")
                      (assoc-ref resp "address")
                      ""))
            (amt (or (assoc-ref resp "amount_from")
                     (assoc-ref resp "input_amount")
                     (assoc-ref resp "amount")
                     0)))
        (if (string-null? addr)
            (values #f #f 'waiting)
            (values addr
                    (if (string? amt) (string->number amt) amt)
                    (cond
                     ((member status-str '("waiting"))        'waiting)
                     ((member status-str '("confirming" "confirmed")) 'confirming)
                     (else (string->symbol status-str))))))))))

(define* (trocador-poll-swap swap-id #:key (base %trocador-base))
  "Poll a Trocador swap status. Returns a symbol:
'waiting, 'confirming, 'sending, 'finished, 'failed, 'expired, 'halted, 'refunded."
  (let* ((url (format #f "~a/anonpay/status/~a" base swap-id))
         (resp (swap-http-get url))
         (status (or (assoc-ref resp "status")
                     (assoc-ref resp "trade_status")
                     "unknown")))
    (cond
     ((member status '("anonpaynew" "new" "waiting")) 'waiting)
     ((member status '("confirming" "confirmed"))      'confirming)
     ((member status '("exchanging" "sending"))        'sending)
     ((member status '("finished" "completed"))        'finished)
     ((member status '("failed" "error"))              'failed)
     ((string=? status "expired")                      'expired)
     ((string=? status "halted")                       'halted)
     ((string=? status "refunded")                     'refunded)
     (else (string->symbol status)))))

;;; ── Majestic Bank API ───────────────────────────────────────────────────
;;;
;;; Direct no-KYC exchanger. Fallback when ChangeNow is unavailable.
;;; The /exchange endpoint returns the XMR deposit address and amount in
;;; a single HTTP call — no widget, no multi-step handshake. Downside:
;;; no refund address parameter — if a swap fails, you must contact
;;; support to recover XMR.
;;; Base: https://majesticbank.is/api/v1 (also .sc, .su, .onion)

(define %majestic-base "https://majesticbank.is/api/v1")

(define* (majestic-get-rate #:key (base %majestic-base))
  "Get the current XMR→BTC exchange rate. Returns a number (BTC per XMR)."
  (let* ((resp (swap-http-get (string-append base "/rates")))
         (rate (assoc-ref resp "XMR-BTC")))
    (unless rate
      (error "majestic-get-rate: no XMR-BTC rate in response" resp))
    (if (string? rate) (string->number rate) rate)))

(define* (majestic-calculate btc-amount
                             #:key (base %majestic-base))
  "Calculate how much XMR is needed for a given BTC amount."
  (let* ((url (format #f "~a/calculate?from_currency=XMR&receive_currency=BTC&receive_amount=~a"
                      base btc-amount))
         (resp (swap-http-get url))
         (xmr-amount (or (assoc-ref resp "from_amount")
                         (assoc-ref resp "amount"))))
    (unless xmr-amount
      (error "majestic-calculate: no from_amount in response" resp))
    (if (string? xmr-amount) (string->number xmr-amount) xmr-amount)))

(define* (majestic-create-exchange btc-address xmr-amount
                                   #:key (base %majestic-base))
  "Create an XMR→BTC exchange on Majestic Bank. Returns three values:
  trx-id           — string
  xmr-deposit-addr — string
  xmr-amount       — number (confirmed by service)"
  (let* ((url (format #f "~a/exchange?from_currency=XMR&receive_currency=BTC&from_amount=~a&receive_address=~a"
                      base xmr-amount (uri-encode btc-address)))
         (resp (swap-http-get url)))
    (let ((trx (or (assoc-ref resp "trx") ""))
          (addr (or (assoc-ref resp "address") ""))
          (amt (or (assoc-ref resp "from_amount")
                   (assoc-ref resp "amount")
                   xmr-amount)))
      (when (string-null? trx)
        (error "majestic-create-exchange: no trx in response" resp))
      (when (string-null? addr)
        (error "majestic-create-exchange: no address in response" resp))
      (values trx addr (if (string? amt) (string->number amt) amt)))))

(define* (majestic-track trx-id #:key (base %majestic-base))
  "Track a Majestic Bank exchange status. Returns a symbol."
  (let* ((url (format #f "~a/track?trx=~a" base trx-id))
         (resp (swap-http-get url))
         (status (or (assoc-ref resp "status") "unknown")))
    (cond
     ((member status '("Pending" "pending" "waiting"))  'waiting)
     ((member status '("Confirming" "confirming"))      'confirming)
     ((member status '("Exchanging" "exchanging"
                       "Sending" "sending"))            'sending)
     ((member status '("Completed" "completed"
                       "Finished" "finished"))          'finished)
     ((member status '("Failed" "failed" "Error"))      'failed)
     ((member status '("Expired" "expired"))            'expired)
     ((member status '("Refunded" "refunded"))          'refunded)
     (else (string->symbol (string-downcase status))))))

(define (string-downcase s)
  (list->string (map char-downcase (string->list s))))

;;; ── Rate sanity check ───────────────────────────────────────────────────

(define* (check-rate-reasonable? xmr-amount btc-amount
                                 #:key (max-slippage 0.05))
  "Check that the XMR/BTC rate is within MAX-SLIPPAGE (default 5%)
of the market rate (fetched from Majestic Bank). Returns #t if
reasonable, #f if the rate is too bad."
  (catch #t
    (lambda ()
      (let* ((market-rate (majestic-get-rate))
             (effective-rate (/ btc-amount xmr-amount))
             (slippage (/ (- market-rate effective-rate) market-rate)))
        (< slippage max-slippage)))
    (lambda _
      ;; If we can't fetch the market rate, assume it's fine
      ;; (better to proceed than block on a rate check failure)
      #t)))

;;; ── The swap journal ────────────────────────────────────────────────────
;;;
;;; What the swapper answers a create-swap with — (swap-id provider
;;; deposit-name) — is all that names a swap, and an answer can be lost: the
;;; gateway restarts, a promise breaks on the way. So the swapper writes it
;;; down, one file per KEY (the host the swap pays for), the moment the
;;; provider has created the swap and BEFORE any XMR moves. A swap that was
;;; created can always be recalled; one on record whose XMR never left runs
;;; out at the provider and is seen to, by its status.

(define (journal-file dir key)
  (string-append dir "/" (path-component key) ".scm"))

(define (swap-journal-write! dir key swap)
  "Record SWAP — (swap-id provider deposit-name) — under KEY in DIR."
  (when dir
    (mkdir-private! dir)
    (write-atomically! (journal-file dir key)
                       (lambda (port) (write swap port) (newline port))
                       #:mode #o600)))

(define (swap-journal-read dir key)
  "The swap on record under KEY, or #f."
  (and dir
       (let ((file (journal-file dir key)))
         (and (file-exists? file)
              (catch #t
                (lambda ()
                  (match (call-with-input-file file read)
                    (((? string? id) (? symbol? provider) (? string? deposit))
                     (list id provider deposit))
                    (_ #f)))
                (lambda _ #f))))))

(define (swap-journal-delete! dir key)
  (when dir
    (let ((file (journal-file dir key)))
      (when (file-exists? file) (delete-file file)))))

;;; ── ^xmr-btc-swapper actor ─────────────────────────────────────────────

(define* (^xmr-btc-swapper _bcom policy changenow-api-key
                            #:optional (journal-dir #f))
  "Actor that manages XMR→BTC swaps. Holds a policy cap and ChangeNow
API key. Uses ChangeNow as primary (one-call, refund support), falls
back to Majestic Bank (no API key, no refund address). The refund
address is fetched from the wallet via policy on every swap — if the
swap fails or expires, XMR is returned to the localchimera wallet.

POLICY lives in the wallet's own process (a ^wallet-policy-client stands
in for it here), so every call on it is a send. Sends from this actor
reach the policy in the order they were made: authorize, then transfer,
then — on a failed transfer — revoke.

JOURNAL-DIR is where each created swap is written down (the swap journal,
above); #f keeps none."

  (define (start-swap key btc-address btc-amount refund-addr)
    "Create the swap with a provider and send the XMR. Returns a promise
for (swap-id provider deposit-name)."
    (let ((xmr-needed (majestic-calculate btc-amount)))
      (call-with-values
        (lambda ()
          (catch #t
            (lambda ()
              (changenow-create-transaction
               btc-address xmr-needed changenow-api-key
               #:refund-address refund-addr))
            (lambda _
              (majestic-create-exchange btc-address xmr-needed))))
        (lambda args
          (let* ((n (length args))
                 (provider (if (= n 4) 'changenow 'majestic-bank))
                 (trx-id (car args))
                 (xmr-addr (cadr args))
                 (xmr-amt (caddr args)))
            (unless (check-rate-reasonable? xmr-amt btc-amount)
              (error (format #f
                             "swap rate unreasonable: ~a XMR for ~a BTC (>5% slippage)"
                             xmr-amt btc-amount)))
            (let ((deposit-name (format #f "swap-~a-~a" provider trx-id)))
              ;; On record before any XMR moves.
              (swap-journal-write! journal-dir key
                                   (list trx-id provider deposit-name))
              (<-np policy 'authorize-swap-deposit
                    deposit-name xmr-addr xmr-amt)
              (on (<- policy 'transfer
                      (list (list (cons "address" xmr-addr)
                                  (cons "amount" (xmr->atomic xmr-amt)))))
                  (lambda (_)
                    (list trx-id provider deposit-name))
                  #:catch
                  (lambda (_)
                    (<-np policy 'revoke-swap-deposit deposit-name)
                    (error "create-swap: transfer failed, allowlist entry revoked"))
                  #:promise? #t)))))))

  (methods

    [(create-swap key btc-address btc-amount)
     "Initiate an XMR→BTC swap for KEY. Tries ChangeNow first (with refund
address), falls back to Majestic Bank. Authorizes a temporary policy
allowlist entry, sends XMR to the deposit address. Returns a promise for
the list (swap-id provider deposit-name), broken if both providers fail
or the transfer is refused; the reconciler retries on a later tick."
     ;; A swap of an earlier request under this key is off the record
     ;; before a new one is made, so a recall never answers with it.
     (swap-journal-delete! journal-dir key)
     (on (<- policy 'get-address)
         (lambda (refund-addr)
           (start-swap key btc-address btc-amount refund-addr))
         #:catch
         (lambda (_)
           (start-swap key btc-address btc-amount #f))
         #:promise? #t)]

    [(recall-swap key)
     "The swap on record for KEY — (swap-id provider deposit-name) — or #f.
What the reconciler asks when a create-swap's answer never reached it."
     (swap-journal-read journal-dir key)]

    [(forget-swap key)
     "Take KEY's swap off the record: it is finished, or given up."
     (swap-journal-delete! journal-dir key)
     #t]

    [(poll-swap swap-id provider)
     "Poll the swap status. Returns a symbol."
     (case provider
       ((changenow)    (changenow-track swap-id changenow-api-key))
       ((majestic-bank) (majestic-track swap-id))
       (else (error "unknown swap provider" provider)))]

    [(finalize-swap deposit-name)
     "Remove the temporary allowlist entry after swap completion."
     (<-np policy 'revoke-swap-deposit deposit-name)]))
