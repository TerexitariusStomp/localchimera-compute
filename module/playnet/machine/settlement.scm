;;; SPDX-License-Identifier: AGPL-3.0-or-later
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
            caip19?
            <rate-statement> make-rate-statement rate-statement?
            rate-statement-base rate-statement-quote rate-statement-rate
            rate-statement-at rate-statement-bridge-sig
            rate-statement->alist alist->rate-statement
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

(define (caip19? s)
  "The CAIP-19 shape an asset string must take to name a chain asset:
   chain-ns:chain-ref/asset-ns:asset-ref — \"eip155:1/slip44:60\",
   \"eip155:100/erc20:0x…\". Loose on purpose (the registries grow) —
   what it refuses is a bare word that would reconcile as garbage."
  (and (string? s)
       (let ((slash (string-index s #\/)))
         (and slash
              (let ((chain (substring s 0 slash))
                    (asset (substring s (1+ slash))))
                (and (string-index chain #\:)
                     (string-index asset #\:)
                     #t))))))

(define (statement-entry? e)
  (and (list? e)
       (assq 'bridgeJobId e) (assq 'receiptDigest e)
       (assq 'amount e)
       ;; asset is the rail the entry settles on — a malformed string
       ;; would reconcile against nothing a ledger understands
       (caip19? (assq-ref e 'asset))))

(define (payment? p)
  (and (list? p) (assq 'txHash p) (caip19? (assq-ref p 'asset))
       (assq 'amount p)))

(define (statement-entry-bridge-job-id e) (assq-ref e 'bridgeJobId))
(define (statement-entry-receipt-digest e) (assq-ref e 'receiptDigest))
(define (statement-entry-amount e)         (assq-ref e 'amount))
(define (statement-entry-asset e)          (assq-ref e 'asset))


;;; ── the rate statement ──────────────────────────────────────────────────
;;; {base, quote, rate, at, bridgeSig} — an exchange reference a commune
;;; uses to price credit against an external denomination. "How much GLM
;;; is a credit" is not a market fact this module invents — it is a
;;; bridge attestation, signed like the statement that settles. BASE and
;;; QUOTE name the pair (a CAIP-19 asset, or a commons denomination like
;;; "hive:credit"); RATE is base per unit of quote, positive or the
;;; attestation says nothing; the bridge's signature binds it — the same
;;; trust the settlement statement's own signature carries.

(define-record-type <rate-statement>
  (%make-rate-statement base quote rate at bridge-sig)
  rate-statement?
  (base       rate-statement-base)       ; string — what one unit is priced in
  (quote      rate-statement-quote)      ; string — the denomination being priced
  (rate       rate-statement-rate)       ; positive number — base per quote unit
  (at         rate-statement-at)         ; string — the attestation instant
  (bridge-sig rate-statement-bridge-sig)) ; string — the bridge's signature

(define* (make-rate-statement #:key base quote rate at bridge-sig)
  (unless (and (string? base) (string? quote))
    (error "rate-statement: base and quote name the pair"))
  (unless (and (number? rate) (positive? rate))
    (error "rate-statement: a rate must be positive — 0 prices nothing"))
  (unless (string? bridge-sig)
    (error "rate-statement: unsigned is no attestation"))
  (%make-rate-statement base quote rate at bridge-sig))

(define (rate-statement->alist r)
  `(("base"      . ,(rate-statement-base r))
    ("quote"     . ,(rate-statement-quote r))
    ("rate"      . ,(rate-statement-rate r))
    ("at"        . ,(rate-statement-at r))
    ("bridgeSig" . ,(rate-statement-bridge-sig r))))

(define (alist->rate-statement a)
  (make-rate-statement
   #:base (or (assq-ref a 'base) (assoc-ref a "base"))
   #:quote (or (assq-ref a 'quote) (assoc-ref a "quote"))
   #:rate (or (assq-ref a 'rate) (assoc-ref a "rate"))
   #:at (or (assq-ref a 'at) (assoc-ref a "at"))
   #:bridge-sig (or (assq-ref a 'bridgeSig) (assoc-ref a "bridgeSig")
                    (assq-ref a 'bridge-sig))))


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
