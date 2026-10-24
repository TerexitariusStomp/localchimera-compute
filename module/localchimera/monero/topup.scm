;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/monero/topup.scm — the wallet keeps the box's metered
;;; accounts funded.
;;;
;;; The AI the box runs on is bought per call from an account the key-pool
;;; holds a key to (nano-gpt today: (localchimera ai key-pool) `nano-gpt-provider`).
;;; That account is funded in XMR, and the commons' wallet holds XMR, so the
;;; two meet here: every tick, each key's account is asked what it holds,
;;; and one under the floor is topped up from the wallet through the same
;;; bracket every payment leaves by — `authorize-invoice` → transfer →
;;; `revoke-invoice`, the policy's budget and per-tx cap governing.
;;;
;;; No address is ever kept. A deposit is asked of the provider at the
;;; moment it is paid — `POST /transaction/create/xmr` answers a fresh
;;; address and the amount it expects — and that address is authorized for
;;; exactly that one transfer. The provider's answer is written down (one
;;; file per key, under JOURNAL-DIR) BEFORE any XMR moves, so a deposit
;;; whose payment's answer is lost — a restart, a broken promise — is found
;;; again and never paid twice: the wallet's own outgoing transfers are the
;;; verdict (`outgoing-match`, the rule payouts and the fleet reconciler
;;; stand on), and an unseen one is waited on for a grace period before the
;;; deposit is let go.
;;;
;;; One key's journal, an alist, moves through:
;;;
;;;   created  — the provider has the deposit; (asked . EPOCH) once the
;;;              transfer has been asked for, absent when the gateway
;;;              stopped between writing it down and paying it
;;;   paid     — the transfer left; the provider's status is followed
;;;   stuck    — paid, and the provider reports Expired/Failed: money has
;;;              left toward a deposit the provider will not credit, which
;;;              is the operator's and the provider's to settle. The file
;;;              stays; nothing more is sent for this key until it is
;;;              removed by hand.
;;;
;;; Everything is promise-pipelined: the policy is an OCapN cap in another
;;; process and the keys live in the key-pool's vat. `start-topup!` runs one
;;; `topup-tick!` every INTERVAL seconds from a plain thread, each inside one
;;; gateway-vat turn, and never two at once.

(define-module (localchimera monero topup)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (goblins actor-lib on)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera monero wallet)
  #:use-module (localchimera monero payout)
  #:use-module (localchimera utils clock)
  #:use-module (localchimera utils files)
  #:export (topup-tick!
            start-topup!
            deposit-amount-xmr
            topup-journal-read
            topup-journal-write!
            topup-journal-delete!
            %topup-floor-usd
            %topup-usd
            set-topup-amounts!
            set-topup-grace-seconds!
            set-topup-uncredited-seconds!))

;;; ── What "funded" means ───────────────────────────────────────────────────
;;;
;;; An account under the floor is topped up by %topup-usd worth of XMR, at
;;; the provider's own rate (its limits endpoint states a minimum in XMR
;;; and the same minimum in USD), clamped to the provider's limits.

(define %topup-floor-usd 5)
(define %topup-usd 20)

(define (set-topup-amounts! floor-usd usd)
  "The floor an account is kept above, and what one top-up is worth."
  (set! %topup-floor-usd floor-usd)
  (set! %topup-usd usd))

;;; A transfer that comes back broken was refused — or its answer was lost
;;; and the money left all the same. Before a deposit is given up on, the
;;; wallet's outgoing transfers are asked, and an unseen one is waited on
;;; for this long from when the payment was asked for.
(define %topup-grace-seconds 1800)

(define (set-topup-grace-seconds! seconds)
  (set! %topup-grace-seconds seconds))

;;; A deposit paid and still not credited after this long is reported.
(define %topup-uncredited-seconds 7200)

(define (set-topup-uncredited-seconds! seconds)
  (set! %topup-uncredited-seconds seconds))

(define (deposit-amount-xmr limits usd)
  "The XMR to deposit for USD worth, from the provider's LIMITS answer —
   ((\"minimum\" . XMR) (\"maximum\" . XMR) (\"fiatEquivalentMinimum\" . USD) …).
   The minimum in both units is the provider's rate; the amount is clamped
   to its limits and stated to the micro-XMR. #f when the answer carries no
   rate."
  (let ((min  (->number (assoc-ref limits "minimum")))
        (max  (->number (assoc-ref limits "maximum")))
        (fmin (->number (assoc-ref limits "fiatEquivalentMinimum"))))
    (and min fmin (> min 0) (> fmin 0)
         (let* ((price (/ fmin min))
                (raw   (/ usd price))
                (x     (cond ((< raw min) min)
                             ((and max (> raw max)) max)
                             (else raw))))
           (/ (round (* x 1000000)) 1000000.0)))))

(define (->number v)
  (cond ((number? v) v)
        ((string? v) (string->number v))
        (else #f)))

;;; ── The journal ───────────────────────────────────────────────────────────

(define (journal-file dir key-id)
  (string-append dir "/" (path-component key-id) ".scm"))

(define (topup-journal-write! dir key-id entry)
  "Record ENTRY — the deposit alist — for KEY-ID in DIR."
  (mkdir-private! dir)
  (write-atomically! (journal-file dir key-id)
                     (lambda (port) (write entry port) (newline port))
                     #:mode #o600))

(define (topup-journal-read dir key-id)
  "The deposit on record for KEY-ID, or #f."
  (let ((file (journal-file dir key-id)))
    (and (file-exists? file)
         (catch #t
           (lambda ()
             (let ((e (call-with-input-file file read)))
               (and (list? e)
                    (string? (assq-ref e 'tx-id))
                    (string? (assq-ref e 'address))
                    (integer? (assq-ref e 'atomic))
                    (memq (assq-ref e 'state) '(created paid stuck))
                    e)))
           (lambda _ #f)))))

(define (topup-journal-delete! dir key-id)
  (let ((file (journal-file dir key-id)))
    (when (file-exists? file) (delete-file file))))

(define (entry-with entry . kvs)
  "ENTRY with each KEY VALUE of KVS set."
  (let loop ((e entry) (kvs kvs))
    (match kvs
      (() e)
      ((k v . rest)
       (loop (cons (cons k v) (filter (lambda (p) (not (eq? (car p) k))) e))
             rest)))))

;;; ── Reading the provider ──────────────────────────────────────────────────

(define (answer-json answer)
  "The JSON of an account answer (STATUS BODY), or #f when the status is
   not 2xx or the body is not JSON."
  (match answer
    (((? integer? status) (? string? body))
     (and (<= 200 status 299)
          (catch #t (lambda () (json-string->scm body)) (lambda _ #f))))
    (_ #f)))

(define (%unix-now) (instant->unix (now)))

(define (expiry-epoch iso)
  (and (string? iso) (and=> (civil->instant iso) instant->unix)))

;;; ── One key ───────────────────────────────────────────────────────────────

(define* (tend-key! key policy journal-dir
                    #:key (log! (lambda _ #f)) (done (lambda () #t))
                          (now (%unix-now)))
  "One key's account: follow the deposit on record for it, or, with none,
   ask what it holds and top it up when under the floor. DONE is called once
   this key's asking is answered, either way."
  (on (<- key 'id)
      (lambda (key-id)
        (let ((entry (topup-journal-read journal-dir key-id)))
          (cond
           ((not entry)
            (consider-topup! key key-id policy journal-dir log! done now))
           ((eq? (assq-ref entry 'state) 'stuck)
            (done))
           ((eq? (assq-ref entry 'state) 'paid)
            (follow-deposit! key key-id entry journal-dir log! done now))
           ((not (assq-ref entry 'asked))
            ;; Written down, then the gateway stopped before paying: pay it
            ;; now while the provider still expects it.
            (let ((expires (assq-ref entry 'expires)))
              (if (and expires (< expires (+ now 120)))
                  (begin
                    (log! "  [topup] ~a: deposit ~a ran out before it was paid — let go~%"
                          key-id (assq-ref entry 'tx-id))
                    (topup-journal-delete! journal-dir key-id)
                    (done))
                  (pay-deposit! key-id entry policy journal-dir log! done now))))
           (else
            (settle-asked! key-id entry policy journal-dir log! done now)))))
      #:catch
      (lambda (e)
        (log! "  [topup] a key is unreachable: ~a~%" e)
        (done))))

(define (consider-topup! key key-id policy journal-dir log! done now)
  "Ask the account what it holds; under the floor, make a deposit and pay it."
  (on (<- key 'account-post "/check-balance" "{}")
      (lambda (answer)
        (let* ((json (answer-json answer))
               (usd  (and json (->number (assoc-ref json "usd_balance")))))
          (cond
           ((not usd)
            (log! "  [topup] ~a: the account's balance is unreadable: ~s~%" key-id answer)
            (done))
           ((>= usd %topup-floor-usd)
            (done))
           (else
            (log! "  [topup] ~a holds $~,2f, under the $~a floor — topping up $~a~%"
                  key-id usd %topup-floor-usd %topup-usd)
            (make-deposit! key key-id policy journal-dir log! done now)))))
      #:catch
      (lambda (e)
        (log! "  [topup] ~a: balance unavailable: ~a~%" key-id e)
        (done))))

(define (make-deposit! key key-id policy journal-dir log! done now)
  "The provider's rate and limits, then a fresh deposit for the top-up —
   written down before it is paid."
  (on (<- key 'account-get "/transaction/limits/xmr")
      (lambda (answer)
        (let* ((limits (answer-json answer))
               (xmr    (and limits (deposit-amount-xmr limits %topup-usd))))
          (if (not xmr)
              (begin
                (log! "  [topup] ~a: the provider's XMR limits are unreadable: ~s~%"
                      key-id answer)
                (done))
              (on (<- policy 'get-balance)
                  (lambda (bi)
                    (if (< (balance-info-unlocked-atomic bi) (xmr->atomic xmr))
                        (begin
                          (log! "  [topup] ~a: the wallet holds ~a XMR unlocked, short of the ~a XMR top-up~%"
                                key-id
                                (exact->inexact (atomic->xmr (balance-info-unlocked-atomic bi)))
                                xmr)
                          (done))
                        (on (<- key 'account-post "/transaction/create/xmr"
                                (scm->json-string `(("amount" . ,xmr))))
                            (lambda (answer)
                              (let* ((dep     (answer-json answer))
                                     (tx-id   (and dep (assoc-ref dep "txId")))
                                     (address (and dep (assoc-ref dep "address")))
                                     (amount  (and dep (->number (assoc-ref dep "amount")))))
                                (if (not (and (string? tx-id) (string? address) amount (> amount 0)))
                                    (begin
                                      (log! "  [topup] ~a: the provider made no deposit: ~s~%"
                                            key-id answer)
                                      (done))
                                    (let ((entry `((tx-id . ,tx-id)
                                                   (address . ,address)
                                                   (xmr . ,amount)
                                                   (atomic . ,(xmr->atomic amount))
                                                   (expires . ,(expiry-epoch (assoc-ref dep "expiresAt")))
                                                   (state . created))))
                                      (topup-journal-write! journal-dir key-id entry)
                                      (log! "  [topup] ~a: deposit ~a for ~a XMR on record~%"
                                            key-id tx-id amount)
                                      (pay-deposit! key-id entry policy journal-dir log! done now)))))
                            #:catch
                            (lambda (e)
                              (log! "  [topup] ~a: the provider could not make a deposit: ~a~%" key-id e)
                              (done)))))
                  #:catch
                  (lambda (e)
                    (log! "  [topup] ~a: the wallet's balance is unavailable: ~a~%" key-id e)
                    (done))))))
      #:catch
      (lambda (e)
        (log! "  [topup] ~a: the provider's limits are unavailable: ~a~%" key-id e)
        (done))))

(define (pay-deposit! key-id entry policy journal-dir log! done now)
  "Pay the deposit on record under a one-payment allowlist entry. Three
   sends that reach the policy in this order whatever the transfer's fate:
   authorize the address for exactly this payment, transfer, revoke. The
   journal notes the asking first, so a lost answer is looked for."
  (let* ((tx-id   (assq-ref entry 'tx-id))
         (address (assq-ref entry 'address))
         (xmr     (assq-ref entry 'xmr))
         (atomic  (assq-ref entry 'atomic))
         (name    (format #f "topup:~a:~a" key-id tx-id)))
    (topup-journal-write! journal-dir key-id (entry-with entry 'asked now))
    (log! "  [topup] ~a: paying ~a XMR to deposit ~a~%" key-id xmr tx-id)
    (<-np policy 'authorize-invoice name address xmr)
    (let ((paid (<- policy 'transfer
                    (list (list (cons "address" address)
                                (cons "amount" atomic))))))
      (<-np policy 'revoke-invoice name)
      (on paid
          (lambda (result)
            (topup-journal-write! journal-dir key-id
                                  (entry-with entry 'asked now 'state 'paid
                                              'txid (payout-txid result)))
            (log! "  [topup] ~a: ~a XMR left for deposit ~a (tx ~a)~%"
                  key-id xmr tx-id (payout-txid result))
            (done))
          #:catch
          (lambda (e)
            ;; Refused, or the answer lost: the next tick asks the wallet.
            (log! "  [topup] ~a: the transfer came back broken: ~a — the wallet is asked next tick~%"
                  key-id e)
            (done))))))

(define (settle-asked! key-id entry policy journal-dir log! done now)
  "A deposit whose transfer was asked for and not seen to leave: the
   wallet's outgoing transfers are the verdict."
  (let ((address (assq-ref entry 'address))
        (atomic  (assq-ref entry 'atomic))
        (asked   (assq-ref entry 'asked)))
    (on (<- policy 'get-outgoing 0)
        (lambda (reply)
          (let ((row (outgoing-match address atomic #f (outgoing-rows reply))))
            (cond
             ((and row (not (assoc-ref row "failed")))
              (log! "  [topup] ~a: the wallet shows the payment on its way — paid~%" key-id)
              (topup-journal-write! journal-dir key-id
                                    (entry-with entry 'state 'paid
                                                'txid (or (assoc-ref row "txid") "?"))))
             (row
              (log! "  [topup] ~a: the wallet reports the transfer failed — a fresh deposit next tick~%" key-id)
              (topup-journal-delete! journal-dir key-id))
             ((> (- now asked) %topup-grace-seconds)
              (log! "  [topup] ~a: no outgoing transfer for deposit ~a in ~as — a fresh deposit next tick~%"
                    key-id (assq-ref entry 'tx-id) %topup-grace-seconds)
              (topup-journal-delete! journal-dir key-id))
             (else #t)))
          (done))
        #:catch
        (lambda (e)
          (log! "  [topup] ~a: the wallet's outgoing transfers are unavailable: ~a~%" key-id e)
          (done)))))

(define (follow-deposit! key key-id entry journal-dir log! done now)
  "A paid deposit: the provider's status decides whether it is over. A
   status that is neither final word is named in the log when it changes,
   and the account's own balance is the second witness — one back above
   the floor is funded whatever word the provider used for it."
  (let ((tx-id (assq-ref entry 'tx-id)))
    (on (<- key 'account-get (string-append "/transaction/status/xmr/" tx-id))
        (lambda (answer)
          (let* ((json   (answer-json answer))
                 (status (and json (assoc-ref json "status"))))
            (cond
             ((member status '("Completed" "Paid"))
              (funded! key key-id tx-id journal-dir log!
                       (format #f "the provider says ~a" status))
              (done))
             ((member status '("Expired" "Failed"))
              (log! "  [topup] ~a: deposit ~a is ~a AFTER ~a XMR left for it — stuck; the file under ~a names it for the operator~%"
                    key-id tx-id status (assq-ref entry 'xmr) journal-dir)
              (topup-journal-write! journal-dir key-id (entry-with entry 'state 'stuck))
              (done))
             (else
              (let* ((seen  (if (string? status) status "unreadable"))
                     (entry (if (equal? seen (assq-ref entry 'status))
                                entry
                                (begin
                                  (log! "  [topup] ~a: deposit ~a has status ~s (answer ~s)~%"
                                        key-id tx-id seen answer)
                                  (entry-with entry 'status seen)))))
                (check-funded! key key-id entry journal-dir log! done now))))))
        #:catch
        (lambda (e)
          (log! "  [topup] ~a: deposit ~a status unavailable: ~a~%" key-id tx-id e)
          (done)))))

(define (funded! key key-id tx-id journal-dir log! why)
  "The deposit is over: the record goes, and the key's credit is read again,
   a depleted key back in rotation."
  (log! "  [topup] ~a: deposit ~a credited (~a)~%" key-id tx-id why)
  (topup-journal-delete! journal-dir key-id)
  (<-np key 'check-credits))

(define (check-funded! key key-id entry journal-dir log! done now)
  "A paid deposit whose status is not final: ask the account what it holds.
   At or above the floor, the deposit has landed. Under it for longer than
   %TOPUP-UNCREDITED-SECONDS from the payment, say so once, loudly — the
   record stays, and nothing more is sent for this key."
  (let ((tx-id (assq-ref entry 'tx-id))
        (paid-at (or (assq-ref entry 'asked) now)))
    (on (<- key 'account-post "/check-balance" "{}")
        (lambda (answer)
          (let* ((json (answer-json answer))
                 (usd  (and json (->number (assoc-ref json "usd_balance")))))
            (cond
             ((and usd (>= usd %topup-floor-usd))
              (funded! key key-id tx-id journal-dir log!
                       (format #f "the account holds $~,2f" usd)))
             ((and (> (- now paid-at) %topup-uncredited-seconds)
                   (not (assq-ref entry 'warned)))
              (log! "  [topup] ~a: WARNING deposit ~a was paid ~as ago (tx ~a, ~a XMR) and the account is not credited — status ~s, balance ~a. Ask the provider about it; the record under ~a stays~%"
                    key-id tx-id (- now paid-at) (assq-ref entry 'txid)
                    (assq-ref entry 'xmr) (assq-ref entry 'status)
                    (if usd (format #f "$~,2f" usd) "unreadable") journal-dir)
              (topup-journal-write! journal-dir key-id (entry-with entry 'warned #t)))
             (else
              ;; Nothing to say; keep a status note the tick just learned.
              (unless (equal? entry (topup-journal-read journal-dir key-id))
                (topup-journal-write! journal-dir key-id entry)))))
          (done))
        #:catch
        (lambda (e)
          (log! "  [topup] ~a: balance unavailable: ~a~%" key-id e)
          (done)))))

;;; ── One tick, all keys ────────────────────────────────────────────────────

(define* (topup-tick! pool policy journal-dir
                      #:key (log! (lambda _ #f)) (done (lambda () #t))
                            (now (%unix-now)))
  "Tend every key the pool holds. Runs in a vat turn; the work happens as
   the answers arrive. DONE is called once every key's asking is answered."
  (on (<- pool 'key-refs)
      (lambda (keys)
        (let ((left (length keys)))
          (if (zero? left)
              (done)
              (for-each
               (lambda (key)
                 (tend-key! key policy journal-dir
                            #:log! log! #:now now
                            #:done (lambda ()
                                     (set! left (- left 1))
                                     (when (zero? left) (done)))))
               keys))))
      #:catch
      (lambda (e)
        (log! "  [topup] the key-pool is unreachable: ~a~%" e)
        (done))))

(define* (start-topup! vat pool policy journal-dir
                       #:key (interval-seconds 300) (log! (lambda _ #f)))
  "A background thread that runs one topup-tick! every INTERVAL-SECONDS
   inside VAT. Returns a thunk that stops it.

   A tick reads each key's journal and its answers write it, so a tick waits
   for the one before it. An ask unanswered for ten minutes is taken for
   lost."
  (let ((running? #t)
        (asked-at #f))
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (when running?
           (catch #t
             (lambda ()
               (when (or (not asked-at)
                         (> (- (current-time) asked-at) 600))
                 (set! asked-at (current-time))
                 (with-vat vat
                   (topup-tick! pool policy journal-dir
                                #:log! log!
                                #:done (lambda () (set! asked-at #f))))))
             (lambda (key . args)
               (log! "  [topup] tick: ~a ~a~%" key args)))
           (sleep interval-seconds)
           (loop)))))
    (lambda () (set! running? #f))))
