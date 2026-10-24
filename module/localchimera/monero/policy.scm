;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/monero/policy.scm — declarative spend policy + governance actor
;;;
;;; The ^wallet-policy actor wraps a raw ^monero-wallet cap with a
;;; declarative budget. The policy itself — monthly budget, allowlist,
;;; per-transfer caps — is a plain record, intended to be constructed
;;; at deploy time in machines.scm. Changes to the policy require a
;;; redeploy. The actor's *runtime state* — amount spent this period,
;;; when the period started — is persisted via the Goblins portrait
;;; mechanism so it survives process restarts.
;;;
;;; Enforcement order in `transfer`:
;;;
;;;   1. Maybe roll over the period (if > 30 days since period start,
;;;      reset spent-atomic to 0 and bump period-start to now).
;;;   2. Sum the atomic amounts across all destinations.
;;;   3. For each destination, look up its address in the allowlist;
;;;      reject if not found.
;;;   4. Check per-transfer cap (per-payee override, falling back to
;;;      the policy's default).
;;;   5. Check aggregate budget (spent + this-tx <= monthly-budget).
;;;   6. Forward the transfer to the wrapped wallet.
;;;   7. On success, bcom self with the bumped tally and return the
;;;      wallet's return value.
;;;
;;; The forward-then-bcom ordering is intentional: if the on-chain
;;; transfer fails for any reason (network, daemon, insufficient
;;; unlocked balance), the actor's spend tally is NOT debited. That
;;; is safe because Goblins method execution is synchronous-within-vat
;;; — no other call can observe the pre-bcom state.
;;;
;;; Two spend entrypoints are exposed:
;;;
;;;   (transfer destinations)        — full budget + allowlist + per-tx
;;;                                    cap check, forwards to wallet
;;;   (reserve-budget amount payee)  — budget-only debit, does NOT touch
;;;                                    wallet. Used by the fleet reconciler
;;;                                    for XMR↔fiat out-of-band flows:
;;;                                    operator funds fiat vendor externally,
;;;                                    localchimera tracks the envelope against
;;;                                    the XMR budget.
;;;
;;; Persistence: the wallet capability is NOT in the portrait. The actor
;;; re-spawns with `wallet = #f` on restore, and the gateway bootstrap
;;; code must call `($ wallet-policy 'rewire wallet)` immediately after
;;; re-spawning both the wallet and the policy. See
;;; `monero-policy-env` for the persistence env declaration.

(define-module (localchimera monero policy)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (localchimera monero wallet)
  #:use-module (localchimera utils time)
  #:export (make-monero-spend-policy
            monero-spend-policy?
            monero-spend-policy-monthly-budget
            monero-spend-policy-default-max-per-tx
            monero-spend-policy-allowlist
            monero-spend-policy-note

            make-allowed-payee
            allowed-payee?
            allowed-payee-name
            allowed-payee-address
            allowed-payee-max-per-tx
            allowed-payee-note

            ^wallet-policy
            monero-policy-env

            serialize-policy
            deserialize-policy))

;;; ── Policy records ──────────────────────────────────────────────────────

(define-record-type <allowed-payee>
  (make-allowed-payee name address max-per-tx note)
  allowed-payee?
  (name       allowed-payee-name)        ; string — human label
  (address    allowed-payee-address)     ; string — Monero address
  (max-per-tx allowed-payee-max-per-tx)  ; XMR (number) or #f
  (note       allowed-payee-note))       ; string or #f

(define-record-type <monero-spend-policy>
  (make-monero-spend-policy monthly-budget default-max-per-tx allowlist note)
  monero-spend-policy?
  (monthly-budget      monero-spend-policy-monthly-budget)      ; XMR number
  (default-max-per-tx  monero-spend-policy-default-max-per-tx)  ; XMR number
  (allowlist           monero-spend-policy-allowlist)           ; list of <allowed-payee>
  (note                monero-spend-policy-note))               ; string or #f

;;; ── Serialization ───────────────────────────────────────────────────────
;;;
;;; Goblins can't serialize SRFI-9 records natively, so we flatten the
;;; policy to a tagged list: `(policy <monthly> <default-cap> <payees> <note>)`
;;; where each payee is `(payee <name> <addr> <max> <note>)`.

(define (payee->list p)
  (list 'payee
        (allowed-payee-name p)
        (allowed-payee-address p)
        (allowed-payee-max-per-tx p)
        (allowed-payee-note p)))

(define (list->payee lst)
  (match-list-expect lst 'payee 4
    (lambda (name addr max-per-tx note)
      (make-allowed-payee name addr max-per-tx note))))

(define (serialize-policy p)
  (list 'policy
        (monero-spend-policy-monthly-budget p)
        (monero-spend-policy-default-max-per-tx p)
        (map payee->list (monero-spend-policy-allowlist p))
        (monero-spend-policy-note p)))

(define (deserialize-policy lst)
  (match-list-expect lst 'policy 4
    (lambda (budget default-cap payees note)
      (make-monero-spend-policy budget
                                default-cap
                                (map list->payee payees)
                                note))))

(define (match-list-expect lst tag arity k)
  (unless (and (pair? lst) (eq? (car lst) tag))
    (error (format #f "serialize: expected ~a header, got ~a" tag lst)))
  (let ((rest (cdr lst)))
    (unless (= (length rest) arity)
      (error (format #f "serialize: ~a expected ~a fields, got ~a"
                     tag arity (length rest))))
    (apply k rest)))

;;; ── Helpers ─────────────────────────────────────────────────────────────

(define %seconds-per-period (* 30 86400))  ; 30 days

;; current-epoch-seconds imported from (localchimera utils time)

(define (sum-destinations destinations)
  "Sum the atomic amounts across all destinations of a transfer."
  (fold + 0
        (map (lambda (d) (or (assoc-ref d "amount") 0))
             destinations)))

(define (find-payee-by-address allowlist addr)
  (find (lambda (p) (string=? (allowed-payee-address p) addr))
        allowlist))

(define (find-payee-by-name allowlist name)
  (find (lambda (p) (string=? (allowed-payee-name p) name))
        allowlist))

(define (effective-tx-cap-atomic policy payee)
  "The per-tx cap in atomic units for PAYEE, falling back to the
policy default."
  (xmr->atomic
   (or (allowed-payee-max-per-tx payee)
       (monero-spend-policy-default-max-per-tx policy))))

;;; ── ^wallet-policy actor ────────────────────────────────────────────────

(define-actor (^wallet-policy bcom wallet policy spent-atomic period-start audit-fn credential-check-fn)
  ;; wallet        : raw ^monero-wallet ref (or #f on restore, must be rewired)
  ;; policy        : <monero-spend-policy>
  ;; spent-atomic  : integer — amount spent in the current period (atomic units)
  ;; period-start  : integer — epoch seconds when the current period began

  #:portrait
  (lambda ()
    ;; The wallet ref IS in the portrait — Goblins serializes cross-actor
    ;; references natively (see ^scope-root). If the wallet lives in the
    ;; same persistence env, it's rehydrated and re-connected automatically.
    ;; If the wallet is #f (unwired), that's fine too — portraits can hold
    ;; #f. Callers who spawn the wallet in a different env should spawn
    ;; policy with #f and call 'rewire after both sides are up.
    ;; audit-fn is deliberately #f in the portrait — it's a closure
    ;; that can't be serialized. Callers must rewire-audit after restore.
    (list wallet (serialize-policy policy) spent-atomic period-start))

  #:version 1

  #:restore
  (lambda (version wallet-ref policy-fields spent period)
    (case version
      ((1) (spawn ^wallet-policy wallet-ref
                  (deserialize-policy policy-fields)
                  spent period
                  (lambda (_) #f)       ; audit-fn (lost on restore, rewire)
                  ;; Fail CLOSED, matching require-wallet! below: a
                  ;; credential gate that silently reverted to
                  ;; always-allow after a restart would be a security
                  ;; regression, not a convenience. Denying by default
                  ;; surfaces the existing "failed credential check"
                  ;; error until an operator calls
                  ;; ($ wallet-policy 'rewire-credential-check fn).
                  (lambda (_) #f)))     ; credential-check-fn (lost on restore)
      (else (error "Unknown ^wallet-policy version" version))))

  (define (maybe-roll-period)
    ;; Returns (values current-spent current-period-start) — rolled over
    ;; if >30 days have elapsed since period-start, otherwise unchanged.
    (let ((now (current-epoch-seconds)))
      (if (and (> period-start 0)
               (> (- now period-start) %seconds-per-period))
          (values 0 now)
          (values spent-atomic (if (zero? period-start) now period-start)))))

  (define (require-wallet!)
    (unless wallet
      (error "^wallet-policy: wallet cap not yet rewired after restore")))

  ;; audit-fn is now a constructor arg, part of bcom state, not a set! var.

  (define (check-destinations! destinations)
    ;; Per-destination checks: payee must be in allowlist, per-tx cap.
    ;; Signals clean errors on any violation.
    (for-each
     (lambda (d)
       (let* ((addr (assoc-ref d "address"))
              (amt  (or (assoc-ref d "amount") 0))
              (payee (find-payee-by-address
                      (monero-spend-policy-allowlist policy) addr)))
         (unless payee
           (error (format #f
                          "wallet-policy: payee address ~a not in allowlist"
                          addr)))
         (let ((cap (effective-tx-cap-atomic policy payee)))
           (when (> amt cap)
             (error (format #f
                            "wallet-policy: transfer amount ~a atomic exceeds per-tx cap ~a for payee ~a"
                            amt cap (allowed-payee-name payee)))))
         ;; Optional KERI credential check: if credential-check-fn is
         ;; set (not the default #t thunk), verify the payee holds a
         ;; valid ACDC credential. Blocks the transfer if revoked.
         (unless (credential-check-fn (allowed-payee-name payee))
           (error (format #f
                          "wallet-policy: payee ~a failed credential check"
                          (allowed-payee-name payee))))))
     destinations))

  (define (check-budget! cur-spent additional)
    (let ((budget-atomic
           (xmr->atomic (monero-spend-policy-monthly-budget policy))))
      (when (> (+ cur-spent additional) budget-atomic)
        (error (format #f
                       "wallet-policy: monthly budget exhausted (would spend ~a + ~a > ~a)"
                       cur-spent additional budget-atomic)))))

  (methods

    ;; ── Wiring ──────────────────────────────────────────────────────
    [(rewire new-wallet)
     ;; Post-restore rewire: replace the #f wallet with a live cap.
     ;; Does not touch spent-atomic or period-start.
     (bcom (^wallet-policy bcom new-wallet policy spent-atomic period-start audit-fn credential-check-fn))]

    [(rewire-audit new-audit-fn)
     (bcom (^wallet-policy bcom wallet policy spent-atomic period-start new-audit-fn credential-check-fn))]

    [(rewire-credential-check new-fn)
     ;; Install a credential-check predicate. Takes a payee name,
     ;; returns #t if the payee's ACDC credentials are valid.
     ;; Default is (lambda (_) #t) — no check, backward-compatible.
     ;; Wire to (lambda (name) (verify-role-credential name %schema-supplier))
     ;; ((localchimera keri credentials)) to require a valid supplier ACDC for
     ;; each transfer.
     (bcom (^wallet-policy bcom wallet policy spent-atomic period-start audit-fn new-fn))]

    ;; ── Spend ───────────────────────────────────────────────────────
    [(transfer destinations)
     (require-wallet!)
     (call-with-values maybe-roll-period
       (lambda (cur-spent cur-start)
         (let ((total (sum-destinations destinations)))
           (check-destinations! destinations)
           (check-budget! cur-spent total)
           ;; Forward first, bcom only on success. If the wallet throws
           ;; (network error, daemon down, insufficient unlocked balance,
           ;; anything) the tally remains unchanged.
           (let ((result ($ wallet 'transfer destinations)))
             (audit-fn `((action . transfer)
                         (amount-atomic . ,total)
                         (destinations . ,destinations)
                         (epoch . ,(current-epoch-seconds))))
             (bcom (^wallet-policy bcom wallet policy
                                   (+ cur-spent total) cur-start audit-fn credential-check-fn)
                   result)))))]

    [(reserve-budget amount payee-name)
     ;; Budget-only debit for the out-of-band conversion path. The
     ;; reconciler uses this when the actual vendor payment happens
     ;; via fiat — we still want the XMR budget envelope enforced.
     (call-with-values maybe-roll-period
       (lambda (cur-spent cur-start)
         (unless (find-payee-by-name
                  (monero-spend-policy-allowlist policy) payee-name)
           (error (format #f
                          "wallet-policy: reserve-budget: payee name ~a not in allowlist"
                          payee-name)))
         (check-budget! cur-spent amount)
         (audit-fn `((action . reserve-budget)
                     (amount-atomic . ,amount)
                     (payee . ,payee-name)
                     (epoch . ,(current-epoch-seconds))))
         (bcom (^wallet-policy bcom wallet policy
                               (+ cur-spent amount) cur-start audit-fn credential-check-fn)
               `((reserved . ,amount)
                 (remaining . ,(- (xmr->atomic
                                    (monero-spend-policy-monthly-budget policy))
                                  (+ cur-spent amount)))
                 (payee . ,payee-name)))))]

    ;; ── Read-through to wallet ──────────────────────────────────────
    [(get-balance)
     (require-wallet!)
     ($ wallet 'get-balance)]

    [(get-address)
     (require-wallet!)
     ($ wallet 'get-address)]

    [(get-outgoing min-height)
     ;; Read-through for the payout reconciler (monero/payout.scm): the
     ;; wallet's OUTGOING and still-pending transfers from MIN-HEIGHT — each
     ;; with its txid, amount, timestamp and destinations — so a payout the
     ;; gateway lost track of mid-transfer can be matched against what
     ;; actually left. A read: it moves nothing and names no secret.
     (require-wallet!)
     ($ wallet 'get-transfers `(("out" . #t) ("pending" . #t) ("failed" . #t)
                                ("min_height" . ,min-height)))]

    [(get-incoming min-height)
     ;; Read-through for the donation watch (monero/poller.scm): the wallet's
     ;; confirmed INCOMING transfers from MIN-HEIGHT — each with its txid,
     ;; amount, height and subaddress. A read: it moves nothing and names no
     ;; secret.
     (require-wallet!)
     ($ wallet 'get-transfers `(("in" . #t)
                                ("filter_by_height" . #t)
                                ("min_height" . ,min-height)))]

    ;; ── Observability ───────────────────────────────────────────────
    [(stats)
     (let ((budget-atomic
            (xmr->atomic (monero-spend-policy-monthly-budget policy))))
       `((monthly-budget-xmr
          . ,(monero-spend-policy-monthly-budget policy))
         (monthly-budget-atomic . ,budget-atomic)
         (spent-atomic . ,spent-atomic)
         (remaining-atomic . ,(- budget-atomic spent-atomic))
         (period-start . ,period-start)
         (period-seconds-elapsed
          . ,(if (zero? period-start) 0
                 (- (current-epoch-seconds) period-start)))
         (wallet-wired . ,(if wallet #t #f))))]

    [(policy) policy]

    ;; ── Swap deposit management ────────────────────────────────────
    ;; Temporary allowlist entries for XMR→BTC swap deposit addresses.
    ;; The swap service generates a unique XMR address per swap that
    ;; we must send to. These methods let the swapper actor add/remove
    ;; entries scoped to a specific name and amount.

    [(authorize-swap-deposit name address max-per-tx-xmr)
     "Add a temporary payee to the allowlist for a swap deposit.
Returns the name as a handle for revocation."
     (let ((new-payee (make-allowed-payee name address max-per-tx-xmr
                                          "swap deposit (temporary)")))
       (audit-fn `((action . authorize-swap-deposit)
                   (name . ,name)
                   (address . ,address)
                   (max-per-tx-xmr . ,max-per-tx-xmr)
                   (epoch . ,(current-epoch-seconds))))
       (bcom (^wallet-policy bcom wallet
                             (make-monero-spend-policy
                              (monero-spend-policy-monthly-budget policy)
                              (monero-spend-policy-default-max-per-tx policy)
                              (cons new-payee (monero-spend-policy-allowlist policy))
                              (monero-spend-policy-note policy))
                             spent-atomic period-start audit-fn credential-check-fn)
             name))]

    [(revoke-swap-deposit name)
     "Remove a temporary swap deposit payee by name."
     (let ((new-list (filter (lambda (p)
                               (not (string=? (allowed-payee-name p) name)))
                             (monero-spend-policy-allowlist policy))))
       (audit-fn `((action . revoke-swap-deposit)
                   (name . ,name)
                   (epoch . ,(current-epoch-seconds))))
       (bcom (^wallet-policy bcom wallet
                             (make-monero-spend-policy
                              (monero-spend-policy-monthly-budget policy)
                              (monero-spend-policy-default-max-per-tx policy)
                              new-list
                              (monero-spend-policy-note policy))
                             spent-atomic period-start audit-fn credential-check-fn)))]

    ;; ── Invoice allowlist management ─────────────────────────────────
    ;; Parallel to swap-deposit: providers (SporeStack, VPSBG, ...) issue
    ;; per-invoice XMR addresses that can't be pre-declared. The fleet
    ;; reconciler calls authorize-invoice immediately before transfer and
    ;; revoke-invoice on completion (or failure), so only one unspent
    ;; address is reachable at any moment.

    [(authorize-invoice name address max-per-tx-xmr)
     "Add a temporary payee to the allowlist for a provider invoice.
Returns the name as a handle for revocation."
     (let ((new-payee (make-allowed-payee name address max-per-tx-xmr
                                          "invoice (temporary)")))
       (audit-fn `((action . authorize-invoice)
                   (name . ,name)
                   (address . ,address)
                   (max-per-tx-xmr . ,max-per-tx-xmr)
                   (epoch . ,(current-epoch-seconds))))
       (bcom (^wallet-policy bcom wallet
                             (make-monero-spend-policy
                              (monero-spend-policy-monthly-budget policy)
                              (monero-spend-policy-default-max-per-tx policy)
                              (cons new-payee (monero-spend-policy-allowlist policy))
                              (monero-spend-policy-note policy))
                             spent-atomic period-start audit-fn credential-check-fn)
             name))]

    [(revoke-invoice name)
     "Remove a temporary invoice payee by name."
     (let ((new-list (filter (lambda (p)
                               (not (string=? (allowed-payee-name p) name)))
                             (monero-spend-policy-allowlist policy))))
       (audit-fn `((action . revoke-invoice)
                   (name . ,name)
                   (epoch . ,(current-epoch-seconds))))
       (bcom (^wallet-policy bcom wallet
                             (make-monero-spend-policy
                              (monero-spend-policy-monthly-budget policy)
                              (monero-spend-policy-default-max-per-tx policy)
                              new-list
                              (monero-spend-policy-note policy))
                             spent-atomic period-start audit-fn credential-check-fn)))]))

;;; ── Persistence environment ─────────────────────────────────────────────

(define monero-policy-env
  (make-persistence-env
    `((((localchimera monero) ^wallet-policy) ,^wallet-policy))))
