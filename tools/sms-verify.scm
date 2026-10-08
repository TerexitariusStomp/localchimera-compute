#!/usr/bin/env -S guile -L module
!#
(use-modules (playnet sms walls-rip)
             (playnet monero rpc-digest)
             (ice-9 format)
             (ice-9 getopt-long)
             (ice-9 rdelim))

(define %atomic-per-xmr 1000000000000)
(define (xmr->atomic xmr)
  (inexact->exact (round (* xmr %atomic-per-xmr))))

;; ── CLI ──────────────────────────────────────────────────────────────────

(define option-spec
  '((service    (single-char #\s) (value #t))
    (country    (single-char #\c) (value #t))
    (amount     (single-char #\a) (value #t))
    (manual     (single-char #\m) (value #f))
    (wallet-rpc-url          (value #t))
    (wallet-rpc-user         (value #t))
    (wallet-rpc-password-file (value #t))
    (poll-interval (value #t))
    (max-retries  (value #t))
    (api-key     (value #t))
    (help        (single-char #\h) (value #f))))

(define (usage)
  (format #t "\
Usage: sms-verify.scm [OPTIONS]

Required:
  -s, --service SERVICE  Target service (telegram, signal, whatsapp)
  -c, --country ID       Country numeric ID (e.g. 12 = USA)
  -a, --amount USD       Amount in USD to pay

Payment mode (choose one):
  -m, --manual           Print address, wait for manual XMR send
  --wallet-rpc-password-file PATH  Auto-pay via monero-wallet-rpc

Optional:
  --wallet-rpc-url URL   Default: http://127.0.0.1:18082/json_rpc
  --wallet-rpc-user USER Default: playnet
  --poll-interval SEC    Seconds between polls (default: 5)
  --max-retries N        Max poll retries (default: 60)
  --api-key KEY          WALLS.RIP API key (if required)
  -h, --help             Show this help
")
  (exit 0))

(define (read-password-file path)
  (call-with-input-file path
    (lambda (port)
      (let ((line (read-line port)))
        (if (eof-object? line) "" line)))))

(define (send-monero-payment! rpc-url creds address amount-atomic)
  (let* ((params `(("destinations" . ,(vector `(("address" . ,address)
                                                 ("amount" . ,amount-atomic))))
                    ("account_index" . 0) ("priority" . 1)
                    ("ring_size" . 16) ("get_tx_key" . #t)))
         (result (json-rpc-call rpc-url creds "transfer" params))
         (tx     (assoc-ref result "result")))
    (unless tx
      (error "wallet-rpc transfer failed" (assoc-ref result "error")))
    (assoc-ref tx "tx_hash")))

;; ── Main ─────────────────────────────────────────────────────────────────

(define (main args)
  (let* ((opts      (getopt-long args option-spec))
         (help?     (option-ref opts 'help #f))
         (service   (option-ref opts 'service #f))
         (country   (option-ref opts 'country #f))
         (amount    (and (option-ref opts 'amount #f)
                         (string->number (option-ref opts 'amount #f))))
         (manual?   (option-ref opts 'manual #f))
         (wallet-url (or (option-ref opts 'wallet-rpc-url #f)
                         "http://127.0.0.1:18082/json_rpc"))
         (wallet-user (or (option-ref opts 'wallet-rpc-user #f) "playnet"))
         (pw-file    (option-ref opts 'wallet-rpc-password-file #f))
         (interval  (string->number (or (option-ref opts 'poll-interval #f) "5")))
         (max-tick  (string->number (or (option-ref opts 'max-retries #f) "60")))
         (api-key   (option-ref opts 'api-key #f)))

    (when help? (usage))
    (unless (and service country amount) (usage))
    (unless (or manual? pw-file)
      (format (current-error-port)
              "error: specify --manual or --wallet-rpc-password-file~%")
      (usage))

    (let* ((cfg     (make-walls-rip-config #:api-key api-key))
           (payment (create-payment amount "XMR" cfg))
           (pay-id  (assoc-ref payment "paymentId"))
           (addr    (assoc-ref payment "address"))
           (xmr-amt (assoc-ref payment "amount"))
           (currency (or (assoc-ref payment "currency") "USD")))

      (format #t "\n=== SMS Verification ===\n  service: ~a\n  country: ~a\n  cost:    ~a ~a\n  payment: ~a\n  address: ~a\n"
              service country xmr-amt currency pay-id addr)

      ;; Step 2 — pay
      (cond
       (pw-file
        (let* ((pw    (read-password-file pw-file))
               (creds (make-digest-creds wallet-user pw))
               (tx    (send-monero-payment! wallet-url creds addr
                                            (xmr->atomic xmr-amt))))
          (format #t "  tx:      ~a\n" tx)))
       (manual?
        (format #t "\nSend ~a XMR to the address above, then wait.\n" xmr-amt)))

      ;; Step 3 — wait for payment
      (format #t "\nWaiting for payment...\n")
      (let ((payment-info (poll-until
                           (lambda () (check-payment pay-id cfg))
                           (lambda (r)
                             (and (string=? (assoc-ref r "status") "COMPLETED")
                                  r))
                           #:interval interval #:max-ticks max-tick
                           #:log (lambda (t)
                                   (format #t "  still unpaid (~a/~a)~%" t max-tick)))))
        (format #t "Payment confirmed!\n"))

      ;; Step 4 — purchase number
      (let* ((payment-info (check-payment pay-id cfg))
             (token   (assoc-ref payment-info "walletToken"))
             (purchase (purchase-number country service token cfg))
             (order   (assoc-ref purchase "order_id"))
             (phone   (assoc-ref purchase "phone")))
        (format #t "\nNumber: ~a (order: ~a)\n" phone order)

        ;; Step 5 — wait for SMS
        (format #t "Waiting for SMS...\n")
        (let ((sms (poll-until
                    (lambda () (check-sms order token cfg))
                    (lambda (r)
                      (and (string=? (assoc-ref r "status") "COMPLETED")
                           (assoc-ref r "code")))
                    #:interval interval #:max-ticks max-tick
                    #:log (lambda (t)
                            (format #t "  no SMS yet (~a/~a)~%" t max-tick)))))
          (format #t "\n=== Code ===\n  phone: ~a\n  code:  ~a\n\nDone.\n"
                  phone sms))))))

(main (command-line))
