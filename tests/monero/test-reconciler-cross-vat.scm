;;; tests/monero/test-reconciler-cross-vat.scm — the reconciler where it really runs
;;;
;;; On the box the fleet reconciler has its own vat, the swapper and the
;;; ^wallet-policy-client sit in the gateway's vat, and the policy itself is
;;; in the wallet's process behind a ^wallet-policy-wire. A synchronous call
;;; across any of those lines is refused, so the reconciler asks with sends
;;; and acts on the answers a tick later. Three vats stand in for the three
;;; places; the properties checked are the ones money depends on:
;;;
;;;   - a payment reaches the wallet exactly once, however many ticks pass
;;;   - authorize → transfer → revoke arrive in that order, and the
;;;     allowlist entry is gone afterwards whatever the transfer's fate
;;;   - a transfer whose ANSWER is lost, the money having left, is found in
;;;     the wallet's outgoing transfers and is never paid a second time
;;;   - a refused transfer is retried only once the wallet has been asked and
;;;     the wait is over
;;;   - a BTC invoice starts exactly one swap, waits for its answer, and
;;;     follows the swap's status to 'paying
;;;   - a swap whose ANSWER is lost — a restart, a broken promise — is recalled
;;;     from the swapper's record and never made a second time
;;;
;;; Run:  guile -L module tests/monero/test-reconciler-cross-vat.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (playnet test harness)
             (playnet monero wallet)
             (playnet monero policy)
             (playnet monero policy-wire)
             (playnet fleet provider)
             (playnet fleet records)
             (playnet fleet reconciler)
             (playnet fleet swap)
             (srfi srfi-1)
             (ice-9 ftw)
             (ice-9 format))

;;; ── The three places ──────────────────────────────────────────────────────

(define wallet-vat     (spawn-vat #:name "wallet-process"))
(define gateway-vat    (spawn-vat #:name "gateway"))
(define reconciler-vat (spawn-vat #:name "fleet-reconciler"))

(define (settle)
  "Let the sends in flight across the three vats land."
  (usleep 300000))

;;; ── Wallet side: a wallet that records, a real policy, the wire facet ─────

(define %xmr-address
  "4CrossVatTestAddress0000000000000000000000000000000000000000000000000000000000000000000000000000AA")

(define %wallet-calls '())          ; newest first
(define %sent '())                  ; what really left: outgoing rows
(define %refuse-transfers? #f)      ; refused outright — nothing leaves
(define %lose-answers? #f)          ; the money leaves, the answer does not arrive

(define (^recording-wallet bcom)
  (methods
   ((transfer destinations)
    (set! %wallet-calls (cons `(transfer ,destinations) %wallet-calls))
    (when %refuse-transfers?
      (error "stub wallet: not enough unlocked balance"))
    (set! %sent
          (cons `(("txid" . "feedface")
                  ("timestamp" . 1)
                  ("destinations" . ,(list->vector destinations)))
                %sent))
    (when %lose-answers?
      (error "stub wallet: the connection dropped after the send"))
    '(("tx_hash" . "feedface") ("fee" . 1000)))
   ((get-transfers filter)
    `(("out" . ,(list->vector %sent))))
   ((get-balance) (make-balance-info 9000000000000 9000000000000 0))
   ((get-address) "4Refund")))

;; The policy's own audit trail shows the order its methods ran in.
(define %policy-audit '())

(define-values (policy wire)
  (with-vat wallet-vat
    (let* ((wallet (spawn ^recording-wallet))
           (policy (spawn ^wallet-policy wallet
                          (make-monero-spend-policy 10 2 '() "cross-vat test")
                          0 0
                          (lambda (evt)
                            (set! %policy-audit (cons evt %policy-audit)))
                          (lambda (_) #t))))
      (values policy (spawn ^wallet-policy-wire policy)))))

(define (allowlist-names)
  (map allowed-payee-name
       (monero-spend-policy-allowlist
        (with-vat wallet-vat ($ policy 'policy)))))

;;; ── Gateway side: the policy client, and a swapper that records ───────────

(define client
  (with-vat gateway-vat
    (spawn ^wallet-policy-client (lambda () wire))))

(define %swaps-created 0)
(define %swap-status 'waiting)
(define %finalized '())
(define %swap-record '())           ; key → swap: the stub's journal
(define %lose-swap-answers? #f)     ; the swap is made, the answer does not arrive
(define %refuse-swaps? #f)          ; no provider will make one

(define (^recording-swapper bcom)
  (methods
   ((create-swap key btc-address btc-amount)
    (set! %swap-record (filter (lambda (kv) (not (equal? (car kv) key)))
                               %swap-record))
    (when %refuse-swaps?
      (error "stub swapper: both providers are down"))
    (set! %swaps-created (+ 1 %swaps-created))
    (let ((swap (list (format #f "swap-~a" %swaps-created) 'changenow
                      (format #f "swap-changenow-swap-~a" %swaps-created))))
      (set! %swap-record (acons key swap %swap-record))
      (when %lose-swap-answers?
        (error "stub swapper: the answer was lost on the way"))
      swap))
   ((recall-swap key) (assoc-ref %swap-record key))
   ((forget-swap key)
    (set! %swap-record (filter (lambda (kv) (not (equal? (car kv) key)))
                               %swap-record))
    #t)
   ((poll-swap swap-id provider) %swap-status)
   ((finalize-swap deposit-name)
    (set! %finalized (cons deposit-name %finalized))
    #t)))

(define swapper (with-vat gateway-vat (spawn ^recording-swapper)))

;;; ── A provider that invoices in whatever currency the test says ───────────

(define %invoice-currency 'xmr)

(define %provider
  `((create-invoice
     . ,(lambda (host)
          (case %invoice-currency
            ((xmr) (values "inv-xmr"
                           (format #f "monero:~a?tx_amount=0.5" %xmr-address)
                           'xmr 0.5))
            (else  (values "inv-btc"
                           "bitcoin:bc1qcrossvattest?amount=0.001"
                           'btc 0.001)))))
    (poll-payment . ,(lambda (host entry) 'pending))))

(define %tmpdir (format #f "/tmp/playnet-test-cross-vat-~a" (getpid)))
(system* "mkdir" "-p" %tmpdir)

(define (write-desired! path name)
  (call-with-output-file path
    (lambda (port)
      (format port "(use-modules (playnet fleet records))~%(list (sporestack-host #:name ~s #:flavor \"vps-1vcpu-1gb\" #:operating-system \"debian-12\" #:provider \"digitalocean\" #:region \"nyc1\" #:days 30 #:hostname ~s #:estimated-monthly-usd 5))~%"
              name name))))

(define (spawn-reconciler name)
  (let ((desired (format #f "~a/desired-~a.scm" %tmpdir name))
        (hosts   (format #f "~a/hosts-~a.scm" %tmpdir name)))
    (write-desired! desired name)
    (with-vat reconciler-vat
      (spawn ^fleet-reconciler
             client
             (make-provider-registry `(("sporestack" . ,%provider)))
             swapper
             "ssh-ed25519 AAAATest cross-vat"
             desired hosts
             (hashmap) 0 0 #f))))

(define (tick! reconciler)
  (with-vat reconciler-vat ($ reconciler 'reconcile))
  (settle))

(define (state-of reconciler name)
  (assoc-ref (assq-ref (with-vat reconciler-vat ($ reconciler 'status))
                       'in-flight-states)
             name))

(define (transfers)
  (filter (lambda (c) (eq? (car c) 'transfer)) %wallet-calls))

;;; ── An XMR invoice: paid once, in order, the allowlist left clean ─────────

(format #t "~%=== XMR invoice across three vats ===~%")

(define r1 (spawn-reconciler "host-xmr"))

(tick! r1)
(check "the entry is 'paying as soon as the payment is asked for"
       (eq? 'paying (state-of r1 "host-xmr")))
(check "the wallet saw exactly one transfer"
       (= 1 (length (transfers))))
(check "the transfer is the invoice: its address and 0.5 XMR"
       (let ((dest (car (cadr (car (transfers))))))
         (and (equal? %xmr-address (assoc-ref dest "address"))
              (= (xmr->atomic 0.5) (assoc-ref dest "amount")))))
(check "the policy recorded the transfer (it ran under an allowlist entry)"
       (any (lambda (evt) (eq? 'transfer (assq-ref evt 'action))) %policy-audit))
(check "the one-payment allowlist entry is gone afterwards"
       (null? (allowlist-names)))

(tick! r1)
(tick! r1)
(check "two more ticks ask for no second payment"
       (= 1 (length (transfers))))
(check "and the entry keeps polling its provider in 'paying"
       (eq? 'paying (state-of r1 "host-xmr")))

;;; ── The answer is lost, the money left: never paid twice ──────────────────

(format #t "~%=== A transfer whose answer is lost ===~%")

(set! %wallet-calls '())
(set! %sent '())
(set! %lose-answers? #t)
(set-payment-grace-seconds! 0)      ; even with NO wait at all, below

(define r-lost (spawn-reconciler "host-lost-answer"))

(tick! r-lost)
(check "the payment was asked for once, and its answer came back broken"
       (= 1 (length (transfers))))

(set! %lose-answers? #f)
(tick! r-lost)
(check "a broken answer is not a refusal: the entry asks the wallet what left"
       (eq? 'payment-unconfirmed (state-of r-lost "host-lost-answer")))

(tick! r-lost)
(check "the wallet shows the transfer, so the entry is 'paying"
       (eq? 'paying (state-of r-lost "host-lost-answer")))
(tick! r-lost)
(tick! r-lost)
(check "and the invoice was paid exactly once, with the wait set to zero"
       (= 1 (length (transfers))))
(check "the allowlist is clean" (null? (allowlist-names)))

;;; ── A refused transfer: asked about, waited on, then retried ──────────────

(format #t "~%=== A refused transfer ===~%")

(set! %wallet-calls '())
(set! %sent '())
(set! %refuse-transfers? #t)
(set-payment-grace-seconds! 1800)

(define r2 (spawn-reconciler "host-refused"))

(tick! r2)
(check "the allowlist entry is revoked though the transfer was refused"
       (null? (allowlist-names)))

(set! %refuse-transfers? #f)
(tick! r2)   ; the refusal arrives → asks the wallet
(tick! r2)   ; the wallet shows nothing for this invoice
(tick! r2)
(check "unseen is not 'did not happen': inside the wait, no second payment"
       (= 1 (length (transfers))))
(check "and the entry stands 'payment-unconfirmed"
       (eq? 'payment-unconfirmed (state-of r2 "host-refused")))

(set-payment-grace-seconds! 0)
(tick! r2)   ; asks once more
(tick! r2)   ; unseen and the wait is over → invoice-pending → paid
(check "once the wait is over, the retry reaches the wallet"
       (= 2 (length (transfers))))
(check "and the entry is 'paying on the payment that went through"
       (eq? 'paying (state-of r2 "host-refused")))
(check "the allowlist is clean after the retry too"
       (null? (allowlist-names)))

(set-payment-grace-seconds! 1800)

;;; ── A BTC invoice: one swap, awaited, then followed ───────────────────────

(format #t "~%=== BTC invoice: the swapper across the vat line ===~%")

(set! %invoice-currency 'btc)
(define r3 (spawn-reconciler "host-btc"))

(tick! r3)
(check "one swap was asked for" (= 1 %swaps-created))

(tick! r3)
(check "the swapper's answer moved the entry to 'swapping"
       (eq? 'swapping (state-of r3 "host-btc")))
(check "no second swap was started while waiting"
       (= 1 %swaps-created))

(tick! r3)   ; asks for the status: 'waiting
(tick! r3)   ; applies it: still in progress
(check "a swap still in progress keeps the entry 'swapping"
       (eq? 'swapping (state-of r3 "host-btc")))

(set! %swap-status 'finished)
(tick! r3)   ; asks: 'finished
(tick! r3)   ; applies it
(check "a finished swap moves the entry to 'paying"
       (eq? 'paying (state-of r3 "host-btc")))
(settle)
(check "and the swap's allowlist entry was finalized, once"
       (equal? '("swap-changenow-swap-1") %finalized))
(check "through all of it, exactly one swap was ever created"
       (= 1 %swaps-created))
(check "a finished swap is off the swapper's record"
       (not (assoc-ref %swap-record "host-btc")))

;;; ── The swap is made, its answer is lost: recalled, never made twice ───────

(format #t "~%=== A swap whose answer is lost ===~%")

(set! %swaps-created 0)
(set! %swap-status 'waiting)
(set! %lose-swap-answers? #t)
(set-payment-grace-seconds! 0)      ; even with NO wait at all

(define r-swap-lost (spawn-reconciler "host-swap-lost"))

(tick! r-swap-lost)
(check "the swap was made once, and its answer came back broken"
       (= 1 %swaps-created))

(set! %lose-swap-answers? #f)
(tick! r-swap-lost)
(check "a broken answer is not 'no swap': the entry keeps waiting, and asks"
       (eq? 'swap-requested (state-of r-swap-lost "host-swap-lost")))

(tick! r-swap-lost)
(check "the swapper's record names the swap, so the entry is 'swapping"
       (eq? 'swapping (state-of r-swap-lost "host-swap-lost")))
(tick! r-swap-lost)
(tick! r-swap-lost)
(check "and exactly one swap was ever made, with the wait set to zero"
       (= 1 %swaps-created))

;;; ── No swap was ever made: retried once the wait is over ──────────────────

(format #t "~%=== A swap no provider would make ===~%")

(set! %swaps-created 0)
(set! %refuse-swaps? #t)
(set-payment-grace-seconds! 1800)

(define r-swap-refused (spawn-reconciler "host-swap-refused"))

(tick! r-swap-refused)
(set! %refuse-swaps? #f)
(tick! r-swap-refused)
(tick! r-swap-refused)
(check "inside the wait, a swap that was refused is not asked for again"
       (and (= 0 %swaps-created)
            (eq? 'swap-requested (state-of r-swap-refused "host-swap-refused"))))

(set-payment-grace-seconds! 0)
(tick! r-swap-refused)   ; asks the record once more
(tick! r-swap-refused)   ; nothing on record, the wait is over → asks for a swap
(check "once the wait is over and nothing is on record, one swap is made"
       (= 1 %swaps-created))

(set-payment-grace-seconds! 1800)

;;; ── The swapper's own journal: what `recall-swap` stands on ───────────────

(format #t "~%=== The swap journal on disk ===~%")

(define %journal-dir (string-append %tmpdir "/swaps"))
(define %a-swap (list "trx-9" 'majestic-bank "swap-majestic-bank-trx-9"))

(check "nothing on record reads as #f"
       (not (swap-journal-read %journal-dir "host-a")))
(swap-journal-write! %journal-dir "host-a" %a-swap)
(check "a written swap reads back as it was"
       (equal? %a-swap (swap-journal-read %journal-dir "host-a")))
(check "the journal is the operator's alone (0700 dir, 0600 file)"
       (and (= #o700 (logand #o777 (stat:perms (stat %journal-dir))))
            (every (lambda (f)
                     (= #o600 (logand #o777
                                      (stat:perms (stat (string-append %journal-dir "/" f))))))
                   (filter (lambda (f) (string-suffix? ".scm" f))
                           (or (scandir %journal-dir) '())))))
(swap-journal-write! %journal-dir "../../etc/host b" %a-swap)
(check "a key cannot name a file outside the journal"
       (and (equal? %a-swap (swap-journal-read %journal-dir "../../etc/host b"))
            (every (lambda (f) (not (string-index f #\/)))
                   (or (scandir %journal-dir) '()))
            (not (file-exists? (string-append %tmpdir "/etc")))))
(call-with-output-file (string-append %journal-dir "/host-c.scm")
  (lambda (port) (write '(not a swap) port)))
(check "a file that is not a swap reads as #f"
       (not (swap-journal-read %journal-dir "host-c")))
(swap-journal-delete! %journal-dir "host-a")
(check "a deleted swap is off the record"
       (not (swap-journal-read %journal-dir "host-a")))
(check "with no journal directory, nothing is kept and nothing fails"
       (begin (swap-journal-write! #f "host-a" %a-swap)
              (not (swap-journal-read #f "host-a"))))

(system* "rm" "-rf" %tmpdir)
(test-summary!)
