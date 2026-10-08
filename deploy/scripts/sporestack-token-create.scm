#!/usr/bin/env -S guile -L module
!#
;;; deploy/scripts/sporestack-token-create.scm
;;;
;;; Create a SporeStack token and top it up with Monero — entirely from
;;; Guile, no pip, no Python, no external CLI. Uses the same HTTP client
;;; module that the fleet reconciler uses at runtime.
;;;
;;; Usage:
;;;   guile -L module deploy/scripts/sporestack-token-create.scm \
;;;         --dollars 10 --currency xmr
;;;
;;; The script:
;;;   1. Generates a cryptographically random token (64 hex chars).
;;;   2. Calls POST /token/{token}/add to request an invoice.
;;;   3. Prints the Monero payment URI (address + amount).
;;;   4. Polls the token balance every 15s until SporeStack confirms.
;;;   5. Prints the token string for you to paste into secrets.scm.
;;;
;;; No account, no email, no signup. The token IS the credential.

(use-modules (playnet fleet sporestack)
             (ice-9 format)
             (ice-9 getopt-long)
             (srfi srfi-19))

;;; ── CLI ──────────────────────────────────────────────────────────────────

(define option-spec
  '((dollars  (single-char #\d) (value #t))
    (currency (single-char #\c) (value #t))
    (endpoint (single-char #\e) (value #t))
    (help     (single-char #\h) (value #f))))

(define (usage)
  (format #t "Usage: sporestack-token-create.scm [OPTIONS]

Create a SporeStack token and fund it with Monero.

Options:
  -d, --dollars N      Amount in USD to add (default: 5)
  -c, --currency CUR   Currency: xmr, btc, bch (default: xmr)
  -e, --endpoint URL   SporeStack API URL (default: ~a)
  -h, --help           Show this help

After payment confirms, paste the printed token into
deploy/secrets.scm as SPORESTACK_TOKEN.
" sporestack-default-endpoint)
  (exit 0))

(define (main args)
  (let* ((options (getopt-long args option-spec))
         (help?   (option-ref options 'help #f))
         (dollars (string->number (or (option-ref options 'dollars #f) "5")))
         (currency (or (option-ref options 'currency #f) "xmr"))
         (endpoint (or (option-ref options 'endpoint #f)
                       sporestack-default-endpoint)))
    (when help? (usage))
    (unless dollars
      (format (current-error-port) "error: --dollars must be a number~%")
      (exit 1))

    (let* ((token (generate-sporestack-token))
           (creds (make-sporestack-creds endpoint token)))

      (format #t "~%=== SporeStack Token Creation ===~%~%")
      (format #t "Token:    ~a~%" token)
      (format #t "Endpoint: ~a~%" endpoint)
      (format #t "Amount:   $~a (~a)~%" dollars currency)
      (format #t "~%Requesting invoice...~%")

      (let* ((invoice (sporestack-add-funds creds
                                            #:currency currency
                                            #:dollars dollars))
             (uri-str (invoice-payment-uri invoice))
             (uri     (parse-monero-uri uri-str))
             (addr    (and uri (monero-uri-address uri)))
             (amount  (and uri (monero-uri-amount-xmr uri))))

        (format #t "~%──────────────────────────────────────────~%")
        (format #t "  Payment URI: ~a~%" uri-str)
        (when addr
          (format #t "  Address:     ~a~%" addr))
        (when amount
          (format #t "  Amount XMR:  ~a~%" amount))
        (format #t "  Expires:     ~a~%"
                (let ((exp (invoice-expires invoice)))
                  (if (and exp (number? exp))
                      (date->string (time-utc->date
                                     (make-time time-utc 0 exp))
                                    "~Y-~m-~d ~H:~M:~S UTC")
                      "unknown")))
        (format #t "──────────────────────────────────────────~%")
        (format #t "~%Send exactly ~a ~a to the address above.~%"
                (or amount "the displayed amount") (string-upcase currency))
        (format #t "Waiting for payment confirmation (polling every 15s)...~%~%")

        (let ((info (wait-for-token-funded
                     creds
                     #:max-ticks 240   ; CLI: 1 hour patience for human-in-the-loop XMR send
                     #:on-tick
                     (lambda (tick)
                       (when (zero? (modulo tick 4))
                         (format #t "  ... still waiting (~a min)~%"
                                 (inexact->exact (round (/ (* tick 15) 60)))))))))
          (if info
              (let ((cents (or (assoc-ref info "cents") 0)))
                (format #t "~%=== Payment confirmed! Balance: $~a ===~%~%"
                        (or (assoc-ref info "usd") (/ cents 100.0)))
                (format #t "Your token:~%~%")
                (format #t "  ~a~%~%" token)
                (format #t "Add this to deploy/secrets.scm:~%~%")
                (format #t "  (setenv \"SPORESTACK_TOKEN\" \"~a\")~%~%" token)
                (format #t "Done.~%"))
              (begin
                (format #t "~%Timeout after 1 hour. The token is still valid:~%")
                (format #t "  ~a~%" token)
                (format #t "Check balance later with:~%")
                (format #t "  guile -L module -c '(use-modules (playnet fleet sporestack)) (display (sporestack-balance (make-sporestack-creds \"~a\" \"~a\")))'~%"
                        endpoint token))))))))

(main (command-line))
