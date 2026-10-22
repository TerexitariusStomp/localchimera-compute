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
