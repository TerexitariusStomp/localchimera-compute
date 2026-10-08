;;; tests/monero/test-monero-policy.scm — ^wallet-policy unit tests
;;;
;;; Exercises the full enforcement order + persistence round-trip
;;; against a stub wallet actor. The stub wallet records every
;;; transfer call in a mutable log, and can be configured to throw
;;; on transfer to verify the forward-then-bcom rollback property.
;;;
;;; Run:  guile -L module -L tests tests/monero/test-monero-policy.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins persistence-store memory)
             (playnet test harness)
             (srfi srfi-1)
             (ice-9 format)
             (playnet monero wallet)
             (playnet monero policy))

;;; ── Stub wallet ──────────────────────────────────────────────────────────
;;;
;;; Records transfer calls in a box-style cons cell (set-car!/set-cdr!).
;;; Optionally throws on transfer to simulate on-chain failure.
;;;
;;; Persistable variant is required for the persistence round-trip test:
;;; Goblins walks the actor graph reachable from persistent roots, so
;;; if the policy holds a ref to the stub, the stub must also have a
;;; portrait or the vat can't save a delta.

(define (make-log) (list 'log))
(define (log-append! log entry) (set-cdr! log (cons entry (cdr log))))
(define (log-entries log) (reverse (cdr log)))

(define (^stub-wallet _bcom call-log throw-on-transfer?)
  (methods
    [(transfer destinations)
     (log-append! call-log `(transfer ,destinations))
     (when throw-on-transfer?
       (error "simulated on-chain failure"))
     (list (cons "tx_hash" "deadbeef00000000000000000000000000000000000000000000000000000000")
           (cons "amount" (fold + 0 (map (lambda (d) (assoc-ref d "amount")) destinations)))
           (cons "fee" 10000000))]
    [(get-balance)
     (make-balance-info 10000000000000 10000000000000 0)]
    [(get-address)
     "44Stub000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"]
    [(calls) (log-entries call-log)]))

;; Persistable variant — identical behavior, but has a portrait so it
;; can live in a persistent vat alongside the policy. The log and
;; throw flag are both serialized.
(define-actor (^stub-wallet-p bcom logged-entries throw-on-transfer?)
  #:portrait
  (lambda () (list logged-entries throw-on-transfer?))

  #:version 1

  #:restore
  (lambda (version entries throw?)
    (spawn ^stub-wallet-p entries throw?))

  (methods
    [(transfer destinations)
     (when throw-on-transfer?
       (error "simulated on-chain failure"))
     (bcom (^stub-wallet-p bcom
                           (cons `(transfer ,destinations) logged-entries)
                           throw-on-transfer?)
           (list (cons "tx_hash" "deadbeef00000000000000000000000000000000000000000000000000000000")
                 (cons "amount" (fold + 0 (map (lambda (d) (assoc-ref d "amount")) destinations)))
                 (cons "fee" 10000000)))]
    [(get-balance) (make-balance-info 10000000000000 10000000000000 0)]
    [(get-address)
     "44Stub000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"]
    [(calls) (reverse logged-entries)]))

(define stub-wallet-env
  (make-persistence-env
    `((((test stub) ^stub-wallet-p) ,^stub-wallet-p))))

;;; ── Fixtures ─────────────────────────────────────────────────────────────

(define %hetzner-addr
  "44Hetzner00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
(define %dns-addr
  "44DnsRegistrar0000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
(define %unknown-addr
  "44Unknown0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")

(define %policy
  (make-monero-spend-policy
   10                   ; monthly-budget = 10 XMR
   2                    ; default per-tx cap = 2 XMR
   (list
    (make-allowed-payee "hetzner-treasury" %hetzner-addr 5 "fiat top-up")
    (make-allowed-payee "dns-registrar"   %dns-addr    #f "domain renewals"))
   "test policy"))

;;; ── Test 1: within budget + allowlist → forwards ─────────────────────────

(format #t "=== Within-budget transfer forwards to wallet ===~%")

(define vat1 (spawn-vat))
(define log1 (make-log))

(define wallet1 (with-vat vat1 (spawn ^stub-wallet log1 #f)))
(define policy1
  (with-vat vat1 (spawn ^wallet-policy wallet1 %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

(let ((result (with-vat vat1
                ($ policy1 'transfer
                   (list (list (cons "address" %hetzner-addr)
                               (cons "amount" (xmr->atomic 1.5))))))))
  (check "transfer returned wallet result"
         (and (pair? result) (string? (assoc-ref result "tx_hash"))))
  (check "stub wallet saw exactly one call"
         (= 1 (length (with-vat vat1 ($ wallet1 'calls)))))
  (let ((stats (with-vat vat1 ($ policy1 'stats))))
    (check "stats: spent-atomic == 1.5 XMR"
           (= (xmr->atomic 1.5) (assq-ref stats 'spent-atomic)))
    (check "stats: remaining == 8.5 XMR"
           (= (xmr->atomic 8.5) (assq-ref stats 'remaining-atomic)))))

;;; ── Test 2: exceeding monthly budget rejected ────────────────────────────

(format #t "~%=== Budget exhaustion rejected ===~%")

(define vat2 (spawn-vat))
(define log2 (make-log))
(define wallet2 (with-vat vat2 (spawn ^stub-wallet log2 #f)))
;; Start with 8 XMR already spent, monthly cap is 10.
(define policy2
  (with-vat vat2 (spawn ^wallet-policy wallet2 %policy
                        (xmr->atomic 8)
                        (- (car (gettimeofday)) 60)
                        (lambda (_) #f)
                        (lambda (_) #t))))

(check-error "3 XMR transfer rejected (8 + 3 > 10)"
  (lambda ()
    (with-vat vat2
      ($ policy2 'transfer
         (list (list (cons "address" %hetzner-addr)
                     (cons "amount" (xmr->atomic 3))))))))

(check "wallet was NOT called on budget reject"
       (null? (with-vat vat2 ($ wallet2 'calls))))

(check "tally preserved after rejection"
       (= (xmr->atomic 8)
          (assq-ref (with-vat vat2 ($ policy2 'stats)) 'spent-atomic)))

;;; ── Test 3: unknown payee rejected ───────────────────────────────────────

(format #t "~%=== Unknown payee rejected ===~%")

(define vat3 (spawn-vat))
(define log3 (make-log))
(define wallet3 (with-vat vat3 (spawn ^stub-wallet log3 #f)))
(define policy3
  (with-vat vat3 (spawn ^wallet-policy wallet3 %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

(check-error "transfer to address not in allowlist rejected"
  (lambda ()
    (with-vat vat3
      ($ policy3 'transfer
         (list (list (cons "address" %unknown-addr)
                     (cons "amount" (xmr->atomic 1))))))))

(check "wallet was NOT called on unknown-payee reject"
       (null? (with-vat vat3 ($ wallet3 'calls))))

;;; ── Test 4: per-tx cap (per-payee override) ──────────────────────────────

(format #t "~%=== Per-payee max-per-tx enforced ===~%")

(define vat4 (spawn-vat))
(define log4 (make-log))
(define wallet4 (with-vat vat4 (spawn ^stub-wallet log4 #f)))
(define policy4
  (with-vat vat4 (spawn ^wallet-policy wallet4 %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

;; hetzner-treasury has per-payee cap = 5 XMR, so 6 should be rejected.
(check-error "6 XMR to hetzner (cap 5) rejected"
  (lambda ()
    (with-vat vat4
      ($ policy4 'transfer
         (list (list (cons "address" %hetzner-addr)
                     (cons "amount" (xmr->atomic 6))))))))

;; dns-registrar has no override → falls back to default cap = 2 XMR.
(check-error "3 XMR to dns-registrar (default cap 2) rejected"
  (lambda ()
    (with-vat vat4
      ($ policy4 'transfer
         (list (list (cons "address" %dns-addr)
                     (cons "amount" (xmr->atomic 3))))))))

;; Under cap for hetzner is fine.
(let ((result (with-vat vat4
                ($ policy4 'transfer
                   (list (list (cons "address" %hetzner-addr)
                               (cons "amount" (xmr->atomic 4.5))))))))
  (check "4.5 XMR to hetzner (cap 5) accepted"
         (and (pair? result) (string? (assoc-ref result "tx_hash")))))

;;; ── Test 5: forward-then-bcom rollback on wallet throw ──────────────────

(format #t "~%=== Wallet throw does not debit tally ===~%")

(define vat5 (spawn-vat))
(define log5 (make-log))
(define bad-wallet (with-vat vat5 (spawn ^stub-wallet log5 #t)))  ; throws!
(define policy5
  (with-vat vat5 (spawn ^wallet-policy bad-wallet %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

(check-error "transfer through throwing wallet propagates error"
  (lambda ()
    (with-vat vat5
      ($ policy5 'transfer
         (list (list (cons "address" %hetzner-addr)
                     (cons "amount" (xmr->atomic 1))))))))

(check "stub wallet WAS called (checks ran, forward happened)"
       (= 1 (length (with-vat vat5 ($ bad-wallet 'calls)))))

(check "tally is unchanged after wallet throw"
       (= 0 (assq-ref (with-vat vat5 ($ policy5 'stats)) 'spent-atomic)))

;;; ── Test 6: month rollover resets tally ──────────────────────────────────

(format #t "~%=== Period rollover resets spent tally ===~%")

(define vat6 (spawn-vat))
(define log6 (make-log))
(define wallet6 (with-vat vat6 (spawn ^stub-wallet log6 #f)))

;; Simulate an old period by setting period-start to 31 days ago.
(define long-ago (- (car (gettimeofday)) (* 31 86400)))
(define policy6
  (with-vat vat6 (spawn ^wallet-policy wallet6 %policy
                        (xmr->atomic 9)   ; near budget cap
                        long-ago
                        (lambda (_) #f)
                        (lambda (_) #t))))

;; A 4 XMR transfer would exceed the old budget (9 + 4 > 10) but should
;; succeed because the period rolls over (0 + 4 <= 10).
(let ((result (with-vat vat6
                ($ policy6 'transfer
                   (list (list (cons "address" %hetzner-addr)
                               (cons "amount" (xmr->atomic 4))))))))
  (check "transfer after rollover accepted (tally was reset first)"
         (and (pair? result) (string? (assoc-ref result "tx_hash")))))

(let ((stats (with-vat vat6 ($ policy6 'stats))))
  (check "stats after rollover: spent = 4 XMR (not 13)"
         (= (xmr->atomic 4) (assq-ref stats 'spent-atomic)))
  (check "stats after rollover: period-start advanced"
         (> (assq-ref stats 'period-start) long-ago)))

;;; ── Test 7: persistence round-trip ──────────────────────────────────────

(format #t "~%=== Persistence round-trip preserves tally ===~%")

(define pstore (make-memory-store))

;; Extended env: monero-policy-env + our stub wallet so Goblins can
;; serialize the full reachable graph from the policy.
(define policy+stub-env
  (make-persistence-env
    `((((playnet monero) ^wallet-policy) ,^wallet-policy)
      (((test stub) ^stub-wallet-p) ,^stub-wallet-p))))

(define-values (pvat pwallet ppolicy)
  (spawn-persistent-vat
   policy+stub-env
   (lambda ()
     (let* ((w (spawn ^stub-wallet-p '() #f))
            (p (spawn ^wallet-policy w %policy 0 0 (lambda (_) #f) (lambda (_) #t))))
       (values w p)))
   pstore
   #:name "test-wallet-policy"
   #:version 1))

;; Spend some through the policy.
(with-vat pvat
  ($ ppolicy 'transfer
     (list (list (cons "address" %hetzner-addr)
                 (cons "amount" (xmr->atomic 2.5))))))

(let ((stats (with-vat pvat ($ ppolicy 'stats))))
  (check "before halt: spent = 2.5 XMR"
         (= (xmr->atomic 2.5) (assq-ref stats 'spent-atomic))))

(vat-halt! pvat)

;; Second run: rehydrate from store. The persistent stub wallet and
;; the policy come back wired together — the policy's `wallet` field
;; is re-serialized through the graph, so we don't need a rewire here.
(define-values (pvat2 pwallet2 ppolicy2)
  (spawn-persistent-vat
   policy+stub-env
   (lambda () (error "restore thunk should not run"))
   pstore
   #:name "test-wallet-policy"
   #:version 1))

(let ((stats (with-vat pvat2 ($ ppolicy2 'stats))))
  (check "after restore: spent = 2.5 XMR (preserved)"
         (= (xmr->atomic 2.5) (assq-ref stats 'spent-atomic)))
  (check "after restore: wallet-wired = #t (stub was persisted)"
         (assq-ref stats 'wallet-wired)))

(check "after restore: stub wallet's call log also persisted"
       (= 1 (length (with-vat pvat2 ($ pwallet2 'calls)))))

;; Unlike the wallet ref, credential-check-fn is a closure and can't
;; survive the portrait — #:restore fails it CLOSED by default (a
;; credential gate must not silently revert to always-allow after a
;; restart). This test doesn't exercise credential gating, so rewire
;; back to the same always-allow stand-in the original spawn used.
(with-vat pvat2 ($ ppolicy2 'rewire-credential-check (lambda (_) #t)))

;; Continue spending on top of the restored tally.
(let ((result (with-vat pvat2
                ($ ppolicy2 'transfer
                   (list (list (cons "address" %hetzner-addr)
                               (cons "amount" (xmr->atomic 1))))))))
  (check "post-restore transfer succeeds"
         (and (pair? result) (string? (assoc-ref result "tx_hash")))))

(let ((stats (with-vat pvat2 ($ ppolicy2 'stats))))
  (check "tally accumulates on top (2.5 + 1 = 3.5)"
         (= (xmr->atomic 3.5) (assq-ref stats 'spent-atomic))))

(vat-halt! pvat2)

;;; ── Test 8: reserve-budget debits envelope without wallet ───────────────

(format #t "~%=== reserve-budget envelope-only debit ===~%")

(define vat8 (spawn-vat))
(define log8 (make-log))
(define wallet8 (with-vat vat8 (spawn ^stub-wallet log8 #f)))
(define policy8
  (with-vat vat8 (spawn ^wallet-policy wallet8 %policy 0 0 (lambda (_) #f) (lambda (_) #t))))

(let ((result (with-vat vat8
                ($ policy8 'reserve-budget
                   (xmr->atomic 3.2)
                   "hetzner-treasury"))))
  (check "reserve-budget returned reserved amount"
         (= (xmr->atomic 3.2) (assq-ref result 'reserved))))

(check "reserve-budget did NOT call wallet"
       (null? (with-vat vat8 ($ wallet8 'calls))))

(let ((stats (with-vat vat8 ($ policy8 'stats))))
  (check "reserve-budget advanced the tally"
         (= (xmr->atomic 3.2) (assq-ref stats 'spent-atomic))))

(check-error "reserve-budget to unknown payee name rejected"
  (lambda ()
    (with-vat vat8
      ($ policy8 'reserve-budget (xmr->atomic 0.1) "nope-not-here"))))

;; Budget exhaustion on reserve-budget path.
(check-error "reserve-budget over remaining budget rejected"
  (lambda ()
    (with-vat vat8
      ($ policy8 'reserve-budget (xmr->atomic 100) "hetzner-treasury"))))

;;; ── Test 9+10: Credential check ─────────────────────────────────────

(format #t "~%=== KERI credential check integration ===~%")

;; Test 9: credential check passes → transfer succeeds
(define vat9 (spawn-vat))
(define log9 (make-log))
(define wallet9 (with-vat vat9 (spawn ^stub-wallet log9 #f)))
(define policy9
  (with-vat vat9 (spawn ^wallet-policy wallet9 %policy 0 0
                        (lambda (_) #f)     ; audit no-op
                        (lambda (_) #t))))   ; credential check always passes

(let ((result (with-vat vat9
                ($ policy9 'transfer
                   (list (list (cons "address" %hetzner-addr)
                               (cons "amount" (xmr->atomic 1))))))))
  (check "credential check passes: transfer succeeds"
         (and (pair? result) (string? (assoc-ref result "tx_hash")))))

;; Test 10: credential check fails → transfer rejected
(define vat10 (spawn-vat))
(define log10 (make-log))
(define wallet10 (with-vat vat10 (spawn ^stub-wallet log10 #f)))
(define policy10
  (with-vat vat10 (spawn ^wallet-policy wallet10 %policy 0 0
                         (lambda (_) #f)     ; audit no-op
                         (lambda (_) #f))))   ; credential check ALWAYS FAILS

(check-error "credential check fails: transfer rejected"
  (lambda ()
    (with-vat vat10
      ($ policy10 'transfer
         (list (list (cons "address" %hetzner-addr)
                     (cons "amount" (xmr->atomic 1))))))))

(check "credential check fails: wallet NOT called"
       (null? (with-vat vat10 ($ wallet10 'calls))))

;;; ── Summary ──────────────────────────────────────────────────────────────

(test-summary!)
