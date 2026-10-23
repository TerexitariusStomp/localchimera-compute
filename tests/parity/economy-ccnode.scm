;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/parity/economy-ccnode.scm — settlement ↔ cc-node parity.
;;; The contract: each settled entry — treasury pays lender,
;;; bridgeJobId:receiptDigest as the reference — is the ledger line.
;;; Invariant leg pins settlement->ledger-rows; live leg posts.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (playnet machine settlement)
             (playnet machine credit-commons)
             (srfi srfi-1))

(define fixture-statement
  (make-settlement-statement
   #:period "2026-W45"
   #:entries (list '((bridgeJobId . "bj-1") (receiptDigest . "d-1")
                     (amount . 10) (asset . "eip155:1/erc20:0xUSD")
                     (lenderAccount . "did:key:z6MkLen")))
   #:payments '()
   #:bridge-sig "sig-parity"))

(let ((rows (settlement->ledger-rows fixture-statement #:treasury "safe:0xT")))
  (check "every settled entry is a ledger row carrying its receipt ref"
         (and (pair? rows)
              (assoc "payer" (car rows))
              (assoc "description" (car rows))
              (string=? (cdr (assoc "description" (car rows))) "bj-1:d-1")
              #t) #t))

(parity-live "PLAYNET_CCNODE_URL"
  "cc-node accepts the settlement's ledger rows"
  (lambda (endpoint)
    (catch #t
      (lambda ()
        (let ((post (lambda (path body)
                      (let ((r ((%json-http-transport endpoint) "POST" path body)))
                        `(('ref . ,(car r)))))))
          (post-settlement! fixture-statement
                            #:treasury "safe:0xT" #:post post)
          #t))
      (lambda _ #f))))

(test-summary!)
