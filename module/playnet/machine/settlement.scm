;;; compute/settlement.scm — ring-3 settlement: what the bridge lands.
;;;
;;; WHAT THE FILE HOLDS. The two wire records spec/playnet-compute.md §5-6
;;; names — SettlementStatement and AccountLink — and the reconciliation a
;;; commune runs when a statement arrives: every entry's receiptDigest is
;;; looked up in the dispatch book, and a statement is only as good as its
;;; coverage.
;;;
;;; THE RULE THE RECORD KEEPS. A statement carries no lender payout
;;; preference and no per-lender address — asset is a CAIP-19 in each entry
;;; and each payment, and the commune's treasury Safe is the only address
;;; the statement reconciles. What a lender wants paid in is commune
;;; policy (the payout fold), internal by the spec's own rule.
;;;
;;; Entries are alists, not records, because the wire is JSON: the bridge
;;; produces them and the statement lands verbatim. Receipts are looked up
;;; by digest through the caller's resolver — the settlement module never
;;; holds the registry, it is given the answer.

(define-module (playnet machine settlement)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (<settlement-statement> make-settlement-statement
            settlement-statement? settlement-statement-period
            settlement-statement-entries settlement-statement-payments
            settlement-statement-bridge-sig
            statement-entry-bridge-job-id statement-entry-receipt-digest
            statement-entry-amount statement-entry-asset
            <account-link> make-account-link account-link?
            account-link-did-key account-link-scope-aid account-link-account
            account-link-purpose account-link-nonce account-link-expiry
            account-link-live?
            reconcile-statement))


;;; ── the statement ───────────────────────────────────────────────────────
;;; {period, entries:[{bridgeJobId, receiptDigest, amount, asset:CAIP-19}],
;;;  payments:[{txHash, asset, amount}], bridgeSig}
;;;
;;; Entries are alists with symbol keys of the wire's own names. amount is
;;; a number; asset names the CAIP-19 asset string ("eip155:1/slip44:60").
;;; The statement never carries an amount on a job — pricing lives here,
;;; in the settlement, exactly as the spec's envelope rule demands.

(define-record-type <settlement-statement>
  (%make-settlement-statement period entries payments bridge-sig)
  settlement-statement?
  (period     settlement-statement-period)   ; string — "2026-W43" or an epoch range label
  (entries    settlement-statement-entries)  ; alist list
  (payments   settlement-statement-payments) ; alist list
  (bridge-sig settlement-statement-bridge-sig)) ; string — the bridge's signature

(define* (make-settlement-statement #:key period entries payments bridge-sig)
  (unless (and (list? entries) (every statement-entry? entries))
    (error "settlement: entries must be a list of entries" entries))
  (unless (and (list? payments) (every payment? payments))
    (error "settlement: payments must be a list of payments" payments))
  (%make-settlement-statement period entries payments bridge-sig))

(define (statement-entry? e)
  (and (list? e)
       (assq 'bridgeJobId e) (assq 'receiptDigest e)
       (assq 'amount e) (assq 'asset e)))

(define (payment? p)
  (and (list? p) (assq 'txHash p) (assq 'asset p) (assq 'amount p)))

(define (statement-entry-bridge-job-id e) (assq-ref e 'bridgeJobId))
(define (statement-entry-receipt-digest e) (assq-ref e 'receiptDigest))
(define (statement-entry-amount e)         (assq-ref e 'amount))
(define (statement-entry-asset e)          (assq-ref e 'asset))


;;; ── the account link ────────────────────────────────────────────────────
;;; {didKey, scopeAid, account:CAIP-10, purpose:node|payout, nonce, expiry}
;;; — the binding between a member's DID, the commune they lend through,
;;; and the external account settlement pays. purpose names what the
;;; account is FOR: 'node (a machine identity) or 'payout (where money
;;; lands). expiry is epoch seconds; a link past it answers #f to live?.

(define-record-type <account-link>
  (%make-account-link did-key scope-aid account purpose nonce expiry)
  account-link?
  (did-key   account-link-did-key)
  (scope-aid account-link-scope-aid)
  (account   account-link-account)   ; CAIP-10 — "eip155:1:0xabc…"
  (purpose   account-link-purpose)   ; 'node | 'payout
  (nonce     account-link-nonce)     ; string — replay domain
  (expiry    account-link-expiry))   ; epoch seconds

(define* (make-account-link #:key did-key scope-aid account purpose nonce expiry)
  (unless (memq purpose '(node payout))
    (error "account-link: purpose must be node or payout" purpose))
  (%make-account-link did-key scope-aid account purpose nonce expiry))

(define* (account-link-live? link #:optional (now #f))
  "A link stands until its expiry; NOW is epoch seconds, #f reads the clock."
  (let ((now (or now (current-seconds))))
    (< now (account-link-expiry link))))

(define (current-seconds)
  ;; srfi-19-free: the same convention utils/time.scm keeps, inlined so the
  ;; module carries no import for one call.
  (car (gettimeofday)))


;;; ── reconciliation ──────────────────────────────────────────────────────
;;; (reconcile-statement statement receipt-of) →
;;;   (matched missing total-claimed total-paid)
;;;
;;; RECEIPT-OF is a resolver: digest → receipt | #f. Every entry's digest
;;; is looked up; matched entries have a stored receipt, missing do not.
;;; total-claimed sums entry amounts; total-paid sums payment amounts —
;;; the two differ only when the statement's own arithmetic disagrees,
;;; which is itself a finding the caller reports rather than a number
;;; this routine papers over.

(define (reconcile-statement statement receipt-of)
  (let* ((entries (settlement-statement-entries statement))
         (payments (settlement-statement-payments statement))
         (matched '()) (missing '()))
    (for-each
      (lambda (e)
        (if (receipt-of (statement-entry-receipt-digest e))
            (set! matched (cons e matched))
            (set! missing (cons e missing))))
      entries)
    (list (reverse matched) (reverse missing)
          (fold (lambda (e acc) (+ acc (or (statement-entry-amount e) 0)))
                0 entries)
          (fold (lambda (p acc) (+ acc (or (assq-ref p 'amount) 0)))
                0 payments))))
