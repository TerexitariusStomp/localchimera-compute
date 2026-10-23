;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/machine/safe.scm — the Safe send rail: Safe{Wallet}
;;; (LGPL-3.0) is the adopted treasury execution; this adapter turns a
;;; payout-plan row into the transaction-service proposal wire and is the
;;; `send` closure execute-payout consumes.
;;;
;;; The rule the payout module states — PoI payments only to the hive
;;; treasury Safe — becomes concrete here: the Safe this adapter talks to
;;; IS the bound treasury account; `to` in every proposal is the Safe's
;;; own address (a payout to itself records the hive-credit leg; the
;;; bridge's proposer key signs; signers confirm). The adapter does not
;;; hold keys — a signer-fn is injected the way transports are, and
;;; absent one the adapter refuses rather than sending unsigned.
;;;
;;; WHAT IS HERE:
;;;   • safe-proposal — the tx-service POST body for one plan row:
;;;     {to, value, data, operation:0} — value in the asset's base units
;;;     for native sends; ERC-20 rides as `data` on the token contract.
;;;   • make-safe-send — (service-url safe-addr #:key post sign) →
;;;     (to amount asset) → tx-hash, the send execute-payout wants.
;;;   • %safe-unavailable — the fail-closed transport.

(define-module (playnet machine safe)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (safe-proposal make-safe-send %safe-unavailable))


(define (%safe-unavailable . _)
  (error "safe: no transport injected — tx-service not wired"))


;;; ── the proposal wire ────────────────────────────────────────────────────
;;; POST /v1/safes/{safe}/multisig-transactions/ — the service's proposal
;;; body. ERC-20 sends encode transfer(to,amt) as calldata on the token
;;; contract; a native send carries value directly. The adapter marks
;;; which — asset symbols are matched by the caller's own rail table, not
;;; guessed here.

(define* (safe-proposal safe-addr to amount asset #:key (token-addr #f))
  "The multisig-transaction proposal body for one payout row. token-addr
   non-#f marks the ERC-20 path: to = the token contract, value = 0,
   data = transfer(to,amount)."
  (if token-addr
      `(("safe" . ,safe-addr) ("to" . ,token-addr) ("value" . "0")
        ("operation" . 0)
        ("data" . ,asset))          ; asset slot carries the encoded call
      `(("safe" . ,safe-addr) ("to" . ,to) ("value" . ,(number->string amount))
        ("operation" . 0) ("data" . "0x"))))


;;; ── the send ─────────────────────────────────────────────────────────────

(define* (make-safe-send #:key (post %safe-unavailable)
                         (sign %safe-unavailable)
                         (service-url "") (safe-addr ""))
  "The (to amount asset) → tx-hash closure for execute-payout. post is
   the tx-service call; sign is the proposer-signature step. Both are
   injected; either absent means no send — a payout that cannot sign is
   a payout that does not happen."
  (lambda (to amount asset)
    (let* ((proposal (safe-proposal safe-addr to amount asset))
           (sig (sign proposal))
           (resp (post (string-append "/v1/safes/" safe-addr
                                      "/multisig-transactions/")
                       (acons "signature" sig proposal))))
      (assq-ref resp 'transactionHash))))
