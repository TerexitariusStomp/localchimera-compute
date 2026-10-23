;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/machine/payout.scm — ring-3 settlement pays the treasury,
;;; only the treasury, and only through a live payout binding (spec §2).
;;;
;;; A SettlementStatement says what the bridge owes for a period; the
;;; payout rail says where it may land: ONE payee, the commune's treasury
;;; Safe, bound to the scope's grant by a `purpose:payout AccountLink that
;;; both sides signed. Lender asset preference is internal policy and never
;;; appears in the statement — this module does not see it either.
;;;
;;; WHAT IS HERE:
;;;   • payout-binding — the link shape the rail demands: purpose 'payout,
;;;     account a CAIP-10. Its signatures are checked by verify-binding
;;;     (compute/binding.scm) before a send is planned.
;;;   • payout-plan — statement × binding → the sends the rail would make:
;;;     every entry's (digest, amount, asset) folded to one total per
;;;     asset, addressed to the bound account ONLY. A plan to anywhere
;;;     else is an error, not a send.
;;;   • execute-payout — injected send seam, fail-closed like verify-quote:
;;;     (send to amount asset) → tx-hash string. The default refuses.
;;;   • payout-row — a result row per send, the shape a statement's
;;;     `payments` list carries: txHash, asset, amount, to.
;;;
;;; economy/payouts.scm is the internal rail (VF intents → the ledger);
;;; this module is the bridge edge — it produces the sends and records the
;;; tx-hashes the reconciler matches on-chain.

(define-module (playnet machine payout)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (playnet machine settlement)
  #:use-module (playnet machine binding)
  #:export (payout-binding payout-plan execute-payout %payout-unavailable
            settlement->member-plan
            payout-row-tx-hash payout-row-asset payout-row-amount payout-row-to))


;;; ── the binding the rail demands ────────────────────────────────────────

(define (payout-binding b)
  "B must bind a payout account (a CAIP-10 Safe) or the rail has nowhere
   it is allowed to pay."
  (let ((link (account-binding-link b)))
    (unless (eq? (account-link-purpose link) 'payout)
      (error "payout: binding's purpose is not payout"))
    (when (keri-account? (account-link-account link))
      (error "payout: a keri: account is an identity binding, not a payee"))
    b))


;;; ── the plan ────────────────────────────────────────────────────────────
;;; One send per asset the statement names, summed over its entries, all
;;; addressed to the bound account. Returns a list of (to asset amount);
;;; zero entries → the empty plan (nothing owed, nothing sent).

(define (payout-plan statement b)
  (let* ((b (payout-binding b))
         (to (account-link-account (account-binding-link b)))
         (entries (settlement-statement-entries statement))
         (by-asset
          (fold (lambda (e acc)
                  (let* ((asset (statement-entry-asset e))
                         (amt (or (statement-entry-amount e) 0))
                         (p (assoc asset acc)))
                    (if p (cons (cons asset (+ (cdr p) amt)) (alist-delete asset acc equal?))
                        (cons (cons asset amt) acc))))
                '() entries)))
    (map (lambda (p) (list to (car p) (cdr p))) by-asset)))


;;; ── the send ────────────────────────────────────────────────────────────
;;; (send to amount asset) → tx-hash string, or raises. The real send is a
;;; Safe execution through the account side's rail (protocol-kit on the
;;; bridge, or the commune's own wallet where it signs); the default
;;; refuses — a payout that cannot verify its rail sends nothing.

(define (%payout-unavailable to amount asset)
  (error "payout: no send executor injected" asset))

(define-record-type <payout-row>
  (%make-payout-row tx-hash asset amount to)
  payout-row?
  (tx-hash payout-row-tx-hash)
  (asset   payout-row-asset)
  (amount  payout-row-amount)
  (to      payout-row-to))

(define* (execute-payout statement b #:key (send %payout-unavailable))
  "Run the plan: one send per asset, all to the bound treasury account.
   Returns a list of <payout-row> — the `payments` a closure statement
   carries. Any send that raises aborts the list: a partial payout is a
   finding, not a silent half-payment."
  (map (lambda (plan-row)
         (let ((to (car plan-row)) (asset (cadr plan-row)) (amt (caddr plan-row)))
           (%make-payout-row (send to amt asset) asset amt to)))
       (payout-plan statement b)))


;;; ── the member-level partition — the opt-in pay layer ────────────────────
;;; The treasury settles the statement; what each lender then receives is
;;; commune distribution — commons credit by default, token on opt-in.
;;; The opt-in signature is the dual-signed 'payout AccountLink itself: a
;;; lender whose LIVE payout binding names a chain account takes the token
;;; leg — their entries become sends to the BOUND account (never a
;;; free-form address — the link is what proves the account is theirs).
;;; Everyone else's entries stay credit rows for the commons ledger, which
;;; needs nothing of them.
;;;
;;; Answers ((token . rows) (credit . entries)) — the caller posts each
;;; side through its own rail; this module decides the partition, never
;;; executes it. A member who never binds stays fully in credit, and
;;; nothing in the wire ever tells them otherwise.

(define* (settlement->member-plan statement
                                  #:key (binding-of (lambda _ #f))
                                        (now #f))
  "Partition STATEMENT's entries by rail: BINDING-OF resolves each entry's
   lender to their <account-binding> | #f (the entry's lenderAccount or
   lender identity — the caller knows which key its entries carry). A
   live 'payout binding → a token row to the bound CAIP-10; anything else
   → the credit list, unchanged. NOW is the liveness clock."
  (let loop ((es (settlement-statement-entries statement))
             (token '()) (credit '()))
    (if (null? es)
        `((token . ,(reverse token)) (credit . ,(reverse credit)))
        (let* ((e (car es))
               (b (binding-of e)))
          (if (and b
                   (binding-live? b now)
                   (eq? 'payout
                        (account-link-purpose (account-binding-link b)))
                   ;; a keri: account is an identity, not a payee — the
                   ;; same rule the treasury rail keeps
                   (not (keri-account?
                         (account-link-account (account-binding-link b)))))
              (loop (cdr es)
                    (cons `(("to" . ,(account-link-account
                                      (account-binding-link b)))
                            ("asset" . ,(statement-entry-asset e))
                            ("amount" . ,(statement-entry-amount e))
                            ("receiptDigest"
                             . ,(statement-entry-receipt-digest e)))
                          token)
                    credit)
              (loop (cdr es) token (cons e credit)))))))
