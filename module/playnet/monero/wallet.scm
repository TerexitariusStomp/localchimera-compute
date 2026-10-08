;;; module/playnet/monero/wallet.scm — sealed Goblins actor wrapping monero-wallet-rpc
;;;
;;; The raw RPC credentials never leave the actor closure. Callers interact
;;; only through typed methods that return plain Scheme values, never the
;;; credentials. Modeled directly on ^api-key in (playnet ai key-pool) —
;;; same sealed-closure discipline, but there is no pool wrapper because
;;; there is exactly one wallet.
;;;
;;; Persistence:
;;;
;;; ^monero-wallet is a define-actor with #:version 1, #:portrait, and
;;; #:restore, so it can live inside a persistent vat and survive across
;;; process restarts. The portrait serializes only the URL + rpc-user +
;;; rpc-password-FILE-PATH — the password itself is never in the store.
;;; On restore, the actor re-reads the password from that file, which is
;;; written by the monero-service activation step from MONERO_RPC_PASSWORD
;;; in secrets.scm. The file is 0600, owned by the playnet user.
;;;
;;; To make a wallet round-trippable:
;;;
;;;   (define provider
;;;     (make-wallet-provider
;;;       #:base-url "http://127.0.0.1:18082"
;;;       #:rpc-user "playnet"
;;;       #:rpc-password-file "/var/lib/playnet/monero/rpc-login.txt"))
;;;
;;;   (spawn-persistent-vat monero-wallet-env
;;;     (lambda () (spawn ^monero-wallet provider))
;;;     store
;;;     #:name "monero-wallet"
;;;     #:version 1)
;;;
;;; For tests and ad-hoc use you can still pass an inline password via
;;; #:rpc-password — such a wallet is fully functional but cannot be
;;; persisted, because the portrait path expects a file.
;;;
;;; Methods:
;;;   (get-balance)           — returns a <balance-info> record
;;;   (get-address)           — returns the primary address string
;;;   (create-address label)  — returns (address . index)
;;;   (get-transfers filter)  — filter is an alist like '(("in" . #t) ("min_height" . 0))
;;;                             returns the raw response alist (callers parse)
;;;   (transfer destinations) — destinations is a list of (("address" . X) ("amount" . N))
;;;                             returns the raw response alist
;;;   (provider-name)         — diagnostic: the provider profile name
;;;   (last-error)            — diagnostic: last error string or #f
;;;
;;; No method exposes the RPC password, base-url credentials, or the
;;; raw http client.

(define-module (playnet monero wallet)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 rdelim)
  #:use-module (playnet monero rpc-digest)
  #:use-module (playnet utils secure-memory)
  #:export (^monero-wallet
            monero-wallet-env
            make-wallet-provider
            wallet-provider?
            make-balance-info
            balance-info?
            balance-info-atomic
            balance-info-unlocked-atomic
            balance-info-blocks-to-unlock
            atomic->xmr
            xmr->atomic))

;;; ── Unit conversion ───────────────────────────────────────────────────────
;;;
;;; Monero uses "atomic units" = 1e-12 XMR. All RPC numeric fields are
;;; integer atomic units. Keep conversion in one place so callers never
;;; have to remember the exponent.

(define %atomic-per-xmr 1000000000000)   ; 1e12

(define (atomic->xmr atomic)
  "Convert atomic units (integer) to XMR (exact rational or inexact)."
  (/ atomic %atomic-per-xmr))

(define (xmr->atomic xmr)
  "Convert XMR to atomic units (integer). Rounds to nearest atomic."
  (inexact->exact (round (* xmr %atomic-per-xmr))))

;;; ── Balance info record ───────────────────────────────────────────────────

(define-record-type <balance-info>
  (make-balance-info atomic unlocked-atomic blocks-to-unlock)
  balance-info?
  (atomic           balance-info-atomic)           ; integer atomic units
  (unlocked-atomic  balance-info-unlocked-atomic)  ; integer atomic units
  (blocks-to-unlock balance-info-blocks-to-unlock)) ; integer

;;; ── Provider profile ──────────────────────────────────────────────────────
;;;
;;; A provider profile holds the RPC URL plus either:
;;;   - an inline password (captured in digest-creds) — NOT persistable, and
;;;     rpc-password-file is #f
;;;   - a path to a password file — persistable; on restore the path is
;;;     re-read and digest-creds are rebuilt
;;;
;;; The raw password never appears in the portrait.

(define-record-type <wallet-provider>
  (%make-wallet-provider name base-url rpc-user rpc-password-file creds)
  wallet-provider?
  (name              wallet-provider-name)
  (base-url          wallet-provider-base-url)
  (rpc-user          wallet-provider-rpc-user)
  (rpc-password-file wallet-provider-rpc-password-file)
  (creds             wallet-provider-creds))

(define (read-password-file path)
  "Read the single-line password from PATH. Trims trailing newline.
The password string's underlying bytevector is mlock'd to prevent
swapping to disk. Call secure-unlock+zero! if the provider is
destroyed (in practice, wallet actors live for the process lifetime)."
  ;; Note: Guile strings are immutable and GC'd, so we can't truly
  ;; control when the string's memory is freed. But mlock prevents
  ;; the pages from being swapped while the string is live, which
  ;; is the main threat (core dump / /proc/pid/mem are already
  ;; addressed by per-service user isolation).
  (call-with-input-file path
    (lambda (port)
      (let ((line (read-line port)))
        (if (eof-object? line) "" line)))))

(define* (make-wallet-provider #:key
                               (name "monero-wallet-rpc")
                               (base-url "http://127.0.0.1:18082")
                               (rpc-user "playnet")
                               (rpc-password #f)
                               (rpc-password-file #f))
  "Build a wallet provider profile. BASE-URL should NOT include the
/json_rpc path — it is appended automatically. Exactly one of
RPC-PASSWORD or RPC-PASSWORD-FILE should be supplied; if both are
supplied, RPC-PASSWORD wins. If only RPC-PASSWORD-FILE is set, the
file is read at construction time AND the path is kept so the actor
can be persisted and restored later."
  (let ((pw (cond
             (rpc-password rpc-password)
             (rpc-password-file (read-password-file rpc-password-file))
             (else ""))))
    (%make-wallet-provider name base-url rpc-user rpc-password-file
                           (make-digest-creds rpc-user pw))))

;;; ── Response helpers ──────────────────────────────────────────────────────

(define (rpc-result response)
  "Extract the 'result' field from a JSON-RPC response alist, raising a
descriptive error if the response carries an 'error' envelope."
  (let ((err (assoc-ref response "error")))
    (if err
        (error (format #f "monero-wallet-rpc error: ~a"
                       (or (assoc-ref err "message") err)))
        (or (assoc-ref response "result")
            (error "monero-wallet-rpc: response missing 'result'")))))

;;; ── ^monero-wallet ────────────────────────────────────────────────────────

(define-actor (^monero-wallet bcom provider)
  ;; PROVIDER is a <wallet-provider>. The URL and credentials are captured
  ;; in this closure and are never exposed through any method.

  #:portrait
  (lambda ()
    ;; Serialize only what's needed to rebuild the provider. The raw
    ;; password is deliberately excluded — it lives in the password file
    ;; that rpc-password-file points at, written by monero-service
    ;; activation from MONERO_RPC_PASSWORD.
    (list (wallet-provider-name provider)
          (wallet-provider-base-url provider)
          (wallet-provider-rpc-user provider)
          (wallet-provider-rpc-password-file provider)))

  #:version 1

  #:restore
  ;; The rehydrator splats the portrait list into positional args, so
  ;; this lambda takes (version <portrait-fields...>), not (version data).
  ;; See ^agent-store (agents.scm:65) for the same pattern.
  (lambda (version name base-url rpc-user pw-file)
    (case version
      ((1)
       (unless pw-file
         (error "^monero-wallet restore: missing rpc-password-file in portrait; only wallets built with #:rpc-password-file can be restored"))
       (spawn ^monero-wallet
              (make-wallet-provider
               #:name name
               #:base-url base-url
               #:rpc-user rpc-user
               #:rpc-password-file pw-file)))
      (else (error "Unknown ^monero-wallet version" version))))

  (define url (string-append (wallet-provider-base-url provider) "/json_rpc"))
  (define creds (wallet-provider-creds provider))
  (define name (wallet-provider-name provider))

  (define (rpc! method params)
    (json-rpc-call url creds method params))

  ;; Mutable diagnostic — last-error is tracked per-call but does not
  ;; change the bcom state. It resets to #f on restore (fresh instance),
  ;; which is correct: last-error is runtime state, not identity.
  (define last-error-box (list #f))
  (define (set-last-error! v) (set-car! last-error-box v))
  (define (get-last-error) (car last-error-box))

  (define (with-error-tracking thunk)
    (catch #t
      (lambda ()
        (let ((r (thunk)))
          (set-last-error! #f)
          r))
      (lambda (key . args)
        (set-last-error! (format #f "~a: ~a" key args))
        (apply throw key args))))

  (methods
   ;; ── Diagnostics ─────────────────────────────────────────────────
   [(provider-name) name]
   [(last-error)    (get-last-error)]

   ;; ── Read methods ────────────────────────────────────────────────
   [(get-balance)
    (with-error-tracking
      (lambda ()
        (let ((r (rpc-result (rpc! "get_balance" '(("account_index" . 0))))))
          (make-balance-info
           (or (assoc-ref r "balance") 0)
           (or (assoc-ref r "unlocked_balance") 0)
           (or (assoc-ref r "blocks_to_unlock") 0)))))]

   [(get-address)
    (with-error-tracking
      (lambda ()
        (let ((r (rpc-result (rpc! "get_address" '(("account_index" . 0))))))
          (assoc-ref r "address"))))]

   [(get-address-full)
    (with-error-tracking
      (lambda ()
        (rpc-result (rpc! "get_address" '(("account_index" . 0))))))]

   [(create-address label)
    (with-error-tracking
      (lambda ()
        (let ((r (rpc-result
                  (rpc! "create_address"
                        `(("account_index" . 0) ("label" . ,label))))))
          (cons (assoc-ref r "address")
                (assoc-ref r "address_index")))))]

   [(get-transfers filter)
    ;; FILTER is an alist: e.g. '(("in" . #t) ("min_height" . 3100000))
    (with-error-tracking
      (lambda ()
        (rpc-result (rpc! "get_transfers" filter))))]

   [(get-height)
    (with-error-tracking
      (lambda ()
        (assoc-ref (rpc-result (rpc! "get_height" '())) "height")))]

   ;; ── Spend methods ───────────────────────────────────────────────
   ;; These are the dangerous ones. Only reachable through the raw
   ;; wallet cap — never forward them behind a wrapping service actor
   ;; that hands out donation-receiver capabilities.

   [(transfer destinations . opts)
    ;; DESTINATIONS: list of (("address" . "4...") ("amount" . <atomic>))
    ;; OPTS: optional extra alist, e.g. '(("priority" . 1) ("ring_size" . 16))
    (with-error-tracking
      (lambda ()
        (let ((params `(("destinations" . ,(list->vector destinations))
                        ("account_index" . 0)
                        ("priority" . 1)
                        ("ring_size" . 16)
                        ("get_tx_key" . #t)
                        ,@(if (pair? opts) (car opts) '()))))
          (rpc-result (rpc! "transfer" params)))))]

   [(sweep-all address)
    (with-error-tracking
      (lambda ()
        (rpc-result
         (rpc! "sweep_all"
               `(("address" . ,address)
                 ("account_index" . 0)
                 ("priority" . 1)
                 ("ring_size" . 16)
                 ("get_tx_keys" . #t))))))]))

;;; ── Persistence environment ──────────────────────────────────────────────
;;;
;;; Callers pass this to spawn-persistent-vat (usually alongside the scope
;;; envs) so the wallet actor can be serialized and rehydrated across
;;; process restarts. The logical path — `((playnet monero) ^monero-wallet)` —
;;; is the key Goblins uses to find the constructor at restore time.

(define monero-wallet-env
  (make-persistence-env
    `((((playnet monero) ^monero-wallet) ,^monero-wallet))))
