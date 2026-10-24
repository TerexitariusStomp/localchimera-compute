;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/machine/credit-commons.scm — the mutual-credit rail:
;;; Credit Commons cc-node (GPL-3.0) is the adopted ledger for commons
;;; credit settlement; this is the wire shape a settled statement becomes
;;; and the seam its transport plugs into.
;;;
;;; The bridge model: the hive's treasury is the node account the commune
;;; settles through — PoI payments land ONLY at the treasury (that rule
;;; lives in payout.scm), and this adapter is how a hive-credit leg of
;;; that settlement would post to a cc-node ledger. Each settled entry —
;;; a receipt that reconciled — becomes one transaction row: payee is the
;;; treasury account, the receipt's lender is the credited party inside
;;; the hive's own books, and the digest rides as the description so the
;;; ledger line and the receipt are the same fact.
;;;
;;; WHAT IS HERE:
;;;   • settlement->ledger-rows — entries → cc-node transaction wires.
;;;   • %cc-unavailable — the fail-closed transport.
;;;   • post-settlement! — (statement treasury-acct #:key post) → the
;;;     transaction refs the node answered, or 'unavailable.

(define-module (localchimera machine credit-commons)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (localchimera machine settlement)
  #:export (settlement->ledger-rows post-settlement! %cc-unavailable))


(define (%cc-unavailable . _)
  (error "credit-commons: no transport injected — cc-node not wired"))


;;; ── the wire shape ───────────────────────────────────────────────────────
;;; cc-node's transaction row: {payee, payer, amount, description}. In
;;; hive credit the TREASURY pays — entries are earnings the treasury
;;; owes the lender; payee is the lender's ledger account, description
;;; carries bridgeJobId:receiptDigest — the ledger line IS the receipt.

(define* (settlement->ledger-rows statement #:key (treasury #f))
  "Each statement entry → a cc-node transaction wire. Entries carry
   bridgeJobId, receiptDigest, amount, asset; lender resolves through
   the ledger account the bridge bound for that lender — the adapter
   does not invent one, a missing account is an error the caller sees."
  (map (lambda (e)
         `(("payee"       . ,(assq-ref e 'lenderAccount))
           ("payer"       . ,treasury)
           ("amount"      . ,(statement-entry-amount e))
           ("description" . ,(string-append
                              (or (statement-entry-bridge-job-id e) "")
                              ":" (or (statement-entry-receipt-digest e) "")))))
       (settlement-statement-entries statement)))


;;; ── the seam ─────────────────────────────────────────────────────────────

(define* (post-settlement! statement #:key (treasury #f)
                           (post %cc-unavailable))
  "Post each entry as a cc-node transaction; answers the list of refs
   the node returned. post: (lambda (path body) → parsed). Fail-closed."
  (map (lambda (row) (assq-ref (post "/transactions" row) 'ref))
       (settlement->ledger-rows statement #:treasury treasury)))
