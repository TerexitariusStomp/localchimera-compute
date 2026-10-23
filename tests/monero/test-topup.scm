;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/monero/test-topup.scm — the wallet keeps the AI accounts funded
;;;
;;; The keys live in the key-pool's vat and the policy in the wallet's
;;; process, so the top-up asks with sends and works as the answers arrive.
;;; What has to hold — the properties money depends on:
;;;
;;;   - an account above the floor is left alone; one under it gets exactly
;;;     one deposit, for the provider's own amount, at the address the
;;;     provider answers with at that moment
;;;   - the deposit is on record before any XMR moves, and the payment goes
;;;     authorize → transfer → revoke, the entry named for this deposit
;;;   - a deposit in flight is never paid a second time, however many ticks
;;;     pass, and a transfer whose ANSWER is lost is found in the wallet's
;;;     outgoing transfers
;;;   - a refused transfer is retried only once the wallet has been asked
;;;     and the wait is over; a wallet too short for the top-up sends nothing
;;;   - the provider's Completed clears the record; Expired after payment
;;;     leaves it stuck, and nothing more is sent for that key
;;;
;;; Run:  guile -L module tests/monero/test-topup.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (playnet test harness)
             (playnet monero wallet)
             (playnet monero topup)
             (srfi srfi-1)
             (ice-9 ftw)
             (ice-9 format))

(define gateway-vat (spawn-vat #:name "gateway"))
(define pool-vat    (spawn-vat #:name "key-pool"))

(define (settle) (usleep 300000))

;;; ── The provider, as a key answers for it ─────────────────────────────────

(define %usd-balance "2.50")
(define %limits '(("minimum" . 0.05) ("maximum" . 50)
                  ("fiatEquivalentMinimum" . 10) ("fiatEquivalentMaximum" . 10000)))
(define %deposits-made 0)
(define %deposit-status "New")
(define %credits-checked 0)

(define (deposit-address n)
  (format #f "4Deposit~a~a" n (make-string 86 #\A)))

(define (json . pairs)
  (with-output-to-string
    (lambda ()
      (display "{")
      (let loop ((ps pairs) (first #t))
        (unless (null? ps)
          (unless first (display ","))
          (format #t "~s:~a" (car ps)
                  (let ((v (cadr ps)))
                    (if (string? v) (format #f "~s" v) v)))
          (loop (cddr ps) #f)))
      (display "}"))))

(define (^fake-key bcom)
  (methods
   ((id) "key-a")
   ((account-post path body)
    (cond
     ((string=? path "/check-balance")
      (list 200 (json "usd_balance" %usd-balance "nano_balance" "0")))
     ((string=? path "/transaction/create/xmr")
      (set! %deposits-made (+ 1 %deposits-made))
      (list 200 (json "txId" (format #f "dep-~a" %deposits-made)
                      "address" (deposit-address %deposits-made)
                      "amount" 0.1
                      "status" "New"
                      "expiresAt" "2099-01-01T00:00:00.000Z")))
     (else (list 404 "{}"))))
   ((account-get path)
    (cond
     ((string=? path "/transaction/limits/xmr")
      (list 200 (with-output-to-string
                  (lambda ()
                    (display "{\"minimum\":0.05,\"maximum\":50,\"fiatEquivalentMinimum\":10,\"fiatEquivalentMaximum\":10000}")))))
     ((string-prefix? "/transaction/status/xmr/" path)
      (list 200 (json "status" %deposit-status)))
     (else (list 404 "{}"))))
   ((check-credits) (set! %credits-checked (+ 1 %credits-checked)) #f)))

(define-values (pool key)
  (with-vat pool-vat
    (let ((k (spawn ^fake-key)))
      (values (spawn (lambda (bcom) (methods ((key-refs) (list k)))))
              k))))

;;; ── The wallet's policy, recording ────────────────────────────────────────

(define %policy-calls '())                        ; newest first
(define %unlocked 1000000000000)                  ; 1 XMR
(define %refuse-transfers? #f)
(define %lose-answers? #f)
(define %outgoing '())                            ; rows the wallet shows

(define (^fake-policy bcom)
  (methods
   ((get-balance) (make-balance-info %unlocked %unlocked 0))
   ((authorize-invoice name address max)
    (set! %policy-calls (cons `(authorize ,name ,address ,max) %policy-calls))
    name)
   ((revoke-invoice name)
    (set! %policy-calls (cons `(revoke ,name) %policy-calls)))
   ((transfer destinations)
    (set! %policy-calls (cons `(transfer ,destinations) %policy-calls))
    (when %refuse-transfers? (error "the policy refused: over budget"))
    (let ((d (car destinations)))
      (set! %outgoing
            (cons `(("txid" . "abc") ("timestamp" . 1)
                    ("destinations" . ,(list (list (cons "address" (assoc-ref d "address"))
                                                   (cons "amount" (assoc-ref d "amount"))))))
                  %outgoing)))
    (when %lose-answers? (error "the answer was lost on the way"))
    '(("tx_hash" . "abc")))
   ((get-outgoing min-height)
    `(("out" . ,(list->vector %outgoing))))))

(define policy (with-vat gateway-vat (spawn ^fake-policy)))

(define (calls-of kind)
  (filter (lambda (c) (eq? (car c) kind)) %policy-calls))

;;; ── The journal, in a directory of this run's ─────────────────────────────

(define %dir (format #f "/tmp/playnet-test-topup-~a" (getpid)))
(define (clear-dir!)
  (when (file-exists? %dir)
    (for-each (lambda (f) (delete-file (string-append %dir "/" f)))
              (filter (lambda (f) (not (member f '("." ".."))))
                      (scandir %dir)))
    (rmdir %dir)))
(clear-dir!)

(define %now 1000000)
(define (tick!)
  (with-vat gateway-vat
    (topup-tick! pool policy %dir #:now %now))
  (settle))

(define (journal) (topup-journal-read %dir "key-a"))

;;; ── Above the floor, nothing moves ────────────────────────────────────────

(set! %usd-balance "12.00")
(tick!)
(check "an account above the floor is left alone"
       (and (zero? %deposits-made) (null? %policy-calls) (not (journal))))

;;; ── Under the floor: one deposit, paid once ──────────────────────────────

(set! %usd-balance "2.50")
(tick!)
(check "an account under the floor gets one deposit" (= 1 %deposits-made))
(check "the deposit is on record, paid"
       (let ((j (journal)))
         (and j (eq? 'paid (assq-ref j 'state))
              (equal? "dep-1" (assq-ref j 'tx-id)))))
(check "the payment went authorize → transfer → revoke, named for this deposit"
       (let ((seq (reverse %policy-calls)))
         (and (= 3 (length seq))
              (eq? 'authorize (car (first seq)))
              (eq? 'transfer  (car (second seq)))
              (eq? 'revoke    (car (third seq)))
              (equal? "topup:key-a:dep-1" (cadr (first seq)))
              (equal? "topup:key-a:dep-1" (cadr (third seq))))))
(check "the transfer is to the provider's address of the moment, for its amount"
       (let ((dest (car (cadr (car (calls-of 'transfer))))))
         (and (equal? (deposit-address 1) (assoc-ref dest "address"))
              (= (xmr->atomic 0.1) (assoc-ref dest "amount")))))
(check "the authorized entry caps the transfer at the deposit's amount"
       (let ((a (car (calls-of 'authorize))))
         (and (equal? (deposit-address 1) (third a))
              (= 0.1 (fourth a)))))

(tick!)
(tick!)
(check "later ticks make no second deposit and pay nothing more"
       (and (= 1 %deposits-made) (= 1 (length (calls-of 'transfer)))))

;;; ── The provider credits it ──────────────────────────────────────────────

(set! %deposit-status "Completed")
(tick!)
(check "Completed clears the record" (not (journal)))
(check "and the key's credit is read again" (= 1 %credits-checked))

(set! %usd-balance "25.00")
(tick!)
(check "funded, the account is left alone" (= 1 %deposits-made))

;;; ── A wallet too short sends nothing ─────────────────────────────────────

(set! %usd-balance "1.00")
(set! %unlocked 10000000000)                      ; 0.01 XMR
(tick!)
(check "a wallet short of the top-up makes no deposit and pays nothing"
       (and (= 1 %deposits-made) (= 1 (length (calls-of 'transfer)))))
(set! %unlocked 1000000000000)

;;; ── The deposit's amount is the provider's rate, clamped ─────────────────

(check "$20 at the provider's rate of $200/XMR is 0.1 XMR"
       (= 0.1 (deposit-amount-xmr %limits 20)))
(check "under the provider's minimum, the minimum"
       (= 0.05 (deposit-amount-xmr %limits 1)))
(check "over the provider's maximum, the maximum"
       (= 50 (deposit-amount-xmr %limits 1000000)))
(check "no rate, no amount"
       (not (deposit-amount-xmr '(("minimum" . 0)) 20)))

;;; ── A refused transfer ───────────────────────────────────────────────────

(set! %policy-calls '())
(set! %outgoing '())
(set! %deposit-status "New")
(set! %refuse-transfers? #t)
(set-topup-grace-seconds! 100)
(tick!)
(check "the deposit is made and the transfer asked" (= 2 %deposits-made))
(check "refused, the record stays created with the asking noted"
       (let ((j (journal)))
         (and j (eq? 'created (assq-ref j 'state)) (= %now (assq-ref j 'asked)))))
(set! %refuse-transfers? #f)
(tick!)
(check "within the grace, the wallet is asked and nothing is paid again"
       (and (= 2 %deposits-made) (= 1 (length (calls-of 'transfer))) (journal)))
(set! %now (+ %now 200))
(tick!)
(check "past the grace with nothing seen, the deposit is let go"
       (not (journal)))
(tick!)
(check "and a fresh deposit is made — at a fresh address"
       (and (= 3 %deposits-made)
            (let ((j (journal)))
              (and j (eq? 'paid (assq-ref j 'state))
                   (equal? (deposit-address 3) (assq-ref j 'address))))))

;;; ── A transfer whose answer is lost ──────────────────────────────────────

(set! %deposit-status "Completed")
(tick!)                                           ; clears dep-3
(set! %deposit-status "New")
(set! %policy-calls '())
(set! %lose-answers? #t)
(tick!)
(check "the money left, the answer did not: the record stays created"
       (and (= 4 %deposits-made)
            (eq? 'created (assq-ref (journal) 'state))))
(set! %lose-answers? #f)
(tick!)
(check "the wallet shows the payment on its way — paid, and not paid again"
       (and (eq? 'paid (assq-ref (journal) 'state))
            (= 1 (length (calls-of 'transfer)))))

;;; ── Expired after payment is the operator's ───────────────────────────────

(set! %deposit-status "Expired")
(tick!)
(check "Expired after payment leaves the record stuck"
       (eq? 'stuck (assq-ref (journal) 'state)))
(set! %usd-balance "0.10")
(tick!)
(tick!)
(check "a stuck key is sent nothing more, whatever it holds"
       (and (= 4 %deposits-made) (= 1 (length (calls-of 'transfer)))))

;;; ── A record written, the gateway stopped before paying ─────────────────

(topup-journal-delete! %dir "key-a")
(set! %policy-calls '())
(set! %outgoing '())
(topup-journal-write! %dir "key-a"
                      `((tx-id . "dep-late") (address . ,(deposit-address 9))
                        (xmr . 0.1) (atomic . ,(xmr->atomic 0.1))
                        (expires . ,(+ %now 3600)) (state . created)))
(tick!)
(check "an unpaid record is paid on the next tick, no new deposit made"
       (and (= 4 %deposits-made)
            (= 1 (length (calls-of 'transfer)))
            (eq? 'paid (assq-ref (journal) 'state))
            (equal? (deposit-address 9)
                    (assoc-ref (car (cadr (car (calls-of 'transfer)))) "address"))))

(topup-journal-delete! %dir "key-a")
(set! %policy-calls '())
(topup-journal-write! %dir "key-a"
                      `((tx-id . "dep-old") (address . ,(deposit-address 8))
                        (xmr . 0.1) (atomic . ,(xmr->atomic 0.1))
                        (expires . ,(- %now 10)) (state . created)))
(tick!)
(check "an unpaid record the provider no longer expects is let go, unpaid"
       (and (null? (calls-of 'transfer)) (not (journal))))

;;; ── A status the provider has its own word for ───────────────────────────

(define (write-paid! tx paid-at)
  (topup-journal-write! %dir "key-a"
                        `((tx-id . ,tx) (address . ,(deposit-address 7))
                          (xmr . 0.1) (atomic . ,(xmr->atomic 0.1))
                          (asked . ,paid-at) (txid . "abc") (state . paid))))

(set! %usd-balance "1.00")
(set! %deposit-status "Confirming")
(write-paid! "dep-word" %now)
(tick!)
(check "an unfamiliar status is noted on the record, which stays"
       (equal? "Confirming" (assq-ref (journal) 'status)))
(check "nothing is warned or paid while the deposit is young"
       (and (not (assq-ref (journal) 'warned))
            (null? (calls-of 'transfer))))

(set-topup-uncredited-seconds! 100)
(set! %now (+ %now 200))
(tick!)
(check "paid for too long and still under the floor, the record says it warned"
       (assq-ref (journal) 'warned))
(check "and the record stays, nothing more sent"
       (and (journal) (null? (calls-of 'transfer))))

(set! %credits-checked 0)
(set! %usd-balance "21.00")
(tick!)
(check "the account back above the floor clears the record, whatever the word"
       (not (journal)))
(check "and the key's credit is read again" (= 1 %credits-checked))

(clear-dir!)
(test-summary!)
