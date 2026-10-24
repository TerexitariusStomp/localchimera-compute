;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/monero/payout.scm — the payout runner: members' standing
;;; "send N XMR of mine to ⟨address⟩" intents, moved on-chain from the
;;; commons' wallet under its ^wallet-policy.
;;;
;;; A member's monero is a CLAIM on the commons' wallet (the shop's claim of
;;; `res-xmr-main` into `res-xmr-main-<aid>`); a payout is their intent to
;;; have some of it sent out (planner service: request-payout / my-payouts /
;;; retire-payout). Nobody holds a key but the wallet-service process, and it
;;; spends only through the policy — budget, per-tx cap, and an allowlist the
;;; runner opens for exactly one address for exactly one transfer, the same
;;; `authorize-invoice` → transfer → `revoke-invoice` bracket the fleet
;;; reconciler uses for provider invoices. So a payout is bounded three ways:
;;; by the member's claim (the service refuses past it), by the policy's caps
;;; (governed), and by the wallet's unlocked balance (physics).
;;;
;;; One tick:
;;;   due-payouts  → for each: begin-payout ("pending" → "sending", so a
;;;   second tick never sends it twice) → authorize-invoice → transfer →
;;;   revoke-invoice → settle-payout (a VF transfer out of the member's
;;;   claim, txid on the record) — or fail-payout (the claim stays whole,
;;;   the reason on the intent, the member may retire it and ask again).
;;;
;;; Everything is promise-pipelined: the policy is an OCapN cap in another
;;; process and the planner service lives in its own vat, so the runner is
;;; written in `on`/`<-` and never blocks a vat turn. `start-payout-runner!`
;;; runs `run-payouts!` every INTERVAL seconds from a plain thread, each run
;;; inside one gateway-vat turn.

(define-module (localchimera monero payout)
  #:use-module (goblins)
  #:use-module (goblins vat)
  #:use-module (ice-9 format)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera monero wallet)
  #:use-module (localchimera utils clock)
  #:export (run-payouts! reconcile-payouts! payout-match start-payout-runner! payout-txid
            outgoing-rows outgoing-match))

(define (payout-txid result)
  "The tx hash in a wallet `transfer` reply — the raw RPC alist — or \"?\"."
  (or (and (list? result)
           (or (assoc-ref result "tx_hash")
               (and=> (assoc-ref result "tx_hash_list")
                      (lambda (l) (and (pair? l) (car l))))))
      "?"))

(define (%err->string key args)
  (format #f "~a~a" key (if (pair? args) (format #f ": ~a" args) "")))

(define* (send-payout! planner policy scope-id store p #:key (log! (lambda _ #f)))
  "One payout P (an alist from due-payouts) through the bracket. Returns
   nothing useful; the outcome lands on the intent via settle/fail."
  (let* ((id   (assq-ref p 'id))
         (addr (assq-ref p 'address))
         (xmr  (assq-ref p 'xmr))
         (name (string-append "payout:" id))
         (fail (lambda (why)
                 (log! "  [payout] ~a failed: ~a~%" id why)
                 (<-np policy 'revoke-invoice name)
                 (<-np planner 'fail-payout scope-id id why))))
    (on (<- planner 'begin-payout scope-id id)
        (lambda (r)
          (if (not (and (pair? r) (eq? 'ok (car r))))
              (log! "  [payout] ~a skipped: ~a~%" id r)   ; someone else has it
              (on (<- policy 'authorize-invoice name addr xmr)
                  (lambda (_)
                    (on (<- policy 'transfer
                            (list (list (cons "address" addr)
                                        (cons "amount"  (xmr->atomic xmr)))))
                        (lambda (res)
                          (let ((txid (payout-txid res)))
                            (log! "  [payout] ~a sent ~a XMR, tx ~a~%" id xmr txid)
                            (<-np policy 'revoke-invoice name)
                            (<-np planner 'settle-payout scope-id id txid store)))
                        #:catch (lambda (key . args) (fail (%err->string key args)))))
                  #:catch (lambda (key . args) (fail (%err->string key args))))))
        #:catch (lambda (key . args)
                  (log! "  [payout] ~a could not begin: ~a~%" id (%err->string key args))))))

;; ── Reconciliation: payouts the gateway lost sight of ───────────────────────
;; A payout is "sending" from begin-payout until settle/fail. If the gateway
;; dies in between, the coins may or may not have left. The wallet knows: its
;; outgoing transfers carry destinations, amounts and timestamps. So each
;; tick, every sending payout is looked for among the transfers that left
;; AFTER it began, to its address, for its exact atomic amount — found, it is
;; settled with the real txid; not found inside the grace window, it is
;; parked UNSETTLED (still reserving the claim) for an operator. Never failed
;; on its own: "not seen" is not "did not happen".

(define %reconcile-grace-seconds 1800)   ; how long "sending" may stand unmatched
(define %reconcile-slack-seconds 120)    ; clock skew between gateway and wallet

(define (outgoing-rows reply)
  "The transfer rows in a get-outgoing reply — out, pending and failed
   pooled — each an alist; a vector or list per the RPC decoder."
  (define (->l v) (cond ((vector? v) (vector->list v)) ((list? v) v) (else '())))
  (if (list? reply)
      (append (->l (assoc-ref reply "out"))
              (->l (assoc-ref reply "pending"))
              (->l (assoc-ref reply "failed")))
      '()))

(define (outgoing-match addr atomic floor-epoch rows)
  "The first outgoing row with a destination at ADDR for ATOMIC, timestamped
   no earlier than FLOOR-EPOCH (#f: whenever). A failed row matches too — the
   wallet's verdict, carried on the row. The one rule by which a transfer
   whose answer went missing is recognised: payouts and the fleet
   reconciler's invoice payments both stand on it."
  (find (lambda (row)
          (and (list? row)
               (let ((ts (or (assoc-ref row "timestamp") 0))
                     (ds (let ((d (assoc-ref row "destinations")))
                           (cond ((vector? d) (vector->list d)) ((list? d) d) (else '())))))
                 (and (or (not floor-epoch) (>= ts floor-epoch))
                      (any (lambda (d)
                             (and (list? d)
                                  (equal? addr (assoc-ref d "address"))
                                  (equal? atomic (assoc-ref d "amount"))))
                           ds)))))
        rows))

(define (payout-match p began-epoch rows)
  "The first outgoing row that is payout P: a destination at P's address for
   P's atomic amount, timestamped no earlier than BEGAN-EPOCH minus slack."
  (outgoing-match (assq-ref p 'address)
                  (xmr->atomic (assq-ref p 'xmr))
                  (- began-epoch %reconcile-slack-seconds)
                  rows))

;; Unix seconds at this boundary: the wallet's timestamps are Unix, the
;; clock module's instants are GPS (one clock, GPS canonical) — convert once,
;; here, and compare like with like.
(define (%iso->epoch iso)
  (and=> (civil->instant iso) instant->unix))
(define (%unix-now) (instant->unix (now)))

(define* (reconcile-payouts! planner policy scope-id store
                             #:key (now-epoch (%unix-now)) (log! (lambda _ #f))
                                   (grace %reconcile-grace-seconds))
  "One pass over the sending payouts of SCOPE-ID against the wallet's
   outgoing transfers. Inside a vat turn."
  (on (<- planner 'sending-payouts scope-id)
      (lambda (r)
        (when (and (pair? r) (eq? 'ok (car r)) (pair? (cdr r)))
          (let ((stuck (cdr r)))
            (log! "  [payout] reconciling ~a in flight~%" (length stuck))
            (on (<- planner 'settled-payout-txids scope-id)
                (lambda (settled)
                  (let ((spent (if (and (pair? settled) (eq? 'ok (car settled))) (cdr settled) '())))
                    (on (<- policy 'get-outgoing 0)
                        (lambda (reply)
                          ;; a mutable remainder, not the raw list `for-each` would
                          ;; share across every payout: two distinct sending payouts
                          ;; to the same address for the same atomic amount (a flat
                          ;; recurring payout, or a retry that slipped through) would
                          ;; otherwise both `find` the SAME single wallet row and
                          ;; both settle against it — one real transfer marked as
                          ;; fulfilling two separate claims (verified live: exactly
                          ;; this, one on-chain row, two payouts both landing
                          ;; "sent:" with its txid). Removing a matched row the
                          ;; instant it's used means the next payout in this same
                          ;; pass can no longer see it; a row that settled a payout
                          ;; in an earlier pass is spent for good, since the ledger
                          ;; records one transfer once.
                          (let ((rows (remove (lambda (r) (member (assoc-ref r "txid") spent))
                                              (outgoing-rows reply))))
                            (for-each
                             (lambda (p)
                               (let* ((id    (assq-ref p 'id))
                                      (began (or (%iso->epoch (assq-ref p 'began)) now-epoch))
                                      (hit   (payout-match p began rows)))
                                 (when hit (set! rows (delq hit rows)))
                                 (cond
                                  ((and hit (assoc-ref hit "failed"))
                                   (log! "  [payout] ~a: wallet reports the transfer failed~%" id)
                                   (<-np planner 'fail-payout scope-id id "the wallet reports the transfer failed"))
                                  (hit
                                   (let ((txid (or (assoc-ref hit "txid") "?")))
                                     (log! "  [payout] ~a: found on chain, tx ~a~%" id txid)
                                     (<-np planner 'settle-payout scope-id id txid store)))
                                  ((> (- now-epoch began) grace)
                                   (log! "  [payout] ~a: no outgoing transfer seen in ~as — parked unsettled~%" id grace)
                                   (<-np planner 'unsettle-payout scope-id id
                                         "no matching outgoing transfer seen; an operator must settle or fail it"))
                                  (else #f))))          ; still inside the window — wait
                             stuck)))
                        #:catch (lambda (key . args)
                                  (log! "  [payout] reconcile: wallet unreachable: ~a~%" (%err->string key args))))))
                #:catch (lambda (key . args)
                          (log! "  [payout] reconcile: settled list unreadable: ~a~%" (%err->string key args)))))))
      #:catch (lambda (key . args)
                (log! "  [payout] reconcile failed: ~a~%" (%err->string key args)))))

(define* (run-payouts! planner policy scope-id store
                       #:key (now-iso (instant->civil (now))) (now-epoch (%unix-now))
                             (log! (lambda _ #f)) (reconcile? #t))
  "One tick: reconcile what is in flight, then send every payout due at
   NOW-ISO in SCOPE-ID through the bracket. Call inside a vat turn (the
   gateway's)."
  (when reconcile?
    (reconcile-payouts! planner policy scope-id store #:now-epoch now-epoch #:log! log!))
  (on (<- planner 'due-payouts scope-id now-iso)
      (lambda (r)
        (when (and (pair? r) (eq? 'ok (car r)) (pair? (cdr r)))
          (log! "  [payout] ~a due~%" (length (cdr r)))
          (for-each (lambda (p) (send-payout! planner policy scope-id store p #:log! log!))
                    (cdr r))))
      #:catch (lambda (key . args)
                (log! "  [payout] tick failed: ~a~%" (%err->string key args)))))

(define* (start-payout-runner! vat planner policy scope-id store
                               #:key (interval-seconds 120) (log! (lambda _ #f)))
  "A background thread that runs one tick every INTERVAL-SECONDS inside VAT.
   Returns a thunk that stops it."
  (let ((running? #t))
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (when running?
           (catch #t
             (lambda () (with-vat vat (run-payouts! planner policy scope-id store #:log! log!)))
             (lambda (key . args) (log! "  [payout] runner: ~a~%" (%err->string key args))))
           (sleep interval-seconds)
           (loop)))))
    (lambda () (set! running? #f))))
