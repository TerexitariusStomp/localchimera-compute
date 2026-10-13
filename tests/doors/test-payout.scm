;;; test-payout.scm — "send N XMR of mine to ⟨address⟩": a member's standing
;;; payout intent, bounded by their claim, moved by the commons' wallet under
;;; its policy, settled as a VF transfer out of the claim.
;;;
;;; alice earns 40 h, claims 1 XMR (20 h). She asks to send 0.6 XMR to an
;;; address: accepted; 0.6 more: refused (claim is 1, 0.6 pending). The runner
;;; opens the policy for that address, transfers, settles: her claim is 0.4,
;;; the intent reads sent:<txid>. A transfer the policy refuses leaves the
;;; claim whole and parks the intent as failed. Nobody's key but the wallet's.
;;;
;;; Run: guile -L module -L tests tests/doors/test-payout.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet doors service))
(use-modules (playnet monero specs))
(use-modules (playnet monero payout))
(use-modules ((playnet legal crossings) #:select (record-crossings)) (srfi srfi-1))
(use-modules (srfi srfi-13) (playnet utils clock))
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))
(use-modules ((playnet observation account) #:select (declare-claimable!)))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture

;; Left for documentation only: spec-xmr is on the bar list
;; (vf/facts/barred-specs.scm) now, so this stand-in — what the fixture would
;; need if the rail were read off the recipes alone — has no effect; the
;; claim door's own refusal of spec-xmr is asserted directly below, and
;; alice's already-claimed state is seeded by hand instead (see "claim, then
;; ask to send").
(declare-claimable! "spec-xmr")

(define ADDR "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A")

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))
(define (raise-xmr! obs xmr)
  ($ obs 'record-event
     (make-economic-event #:id "ev-donation" #:action 'raise
       #:resource-inventoried-as %xmr-resource-id #:resource-conforms-to "spec-xmr" #:resource-classified-as '("donation") #:receiver "agent-playnet"
       #:resource-quantity (make-measure xmr "XMR") #:in-scope-of '())))

;; a policy in miniature: the bracket's three verbs, a transfer log, a switch
;; that makes the wallet refuse
(define (^mock-policy bcom)
  (define log '())
  (define refuse? #f)
  (define allowed '())
  (define outgoing '())                      ; what the wallet says left
  (lambda (msg . args)
    (case msg
      ((get-outgoing) `(("out" . ,(list->vector outgoing))))
      ((outgoing!)    (set! outgoing (car args)) #t)
      ((authorize-invoice) (set! allowed (cons (car args) allowed)) (car args))
      ((revoke-invoice)    (set! allowed (delete (car args) allowed)) #t)
      ((transfer)
       (when refuse? (error "wallet-policy: monthly budget exhausted"))
       (set! log (cons (car args) log))
       '(("tx_hash" . "abc123") ("fee" . 1)))
      ((refuse!)  (set! refuse? (car args)) #t)
      ((log)      log)
      ((allowed)  allowed)
      (else (error "mock-policy: no method" msg)))))

(define vat (spawn-vat))
(define SR #f)
(define-values (svc policy)
  (with-vat vat
    (let* ((sr  (begin (set! SR (spawn-scope-root "Payout Scope")) SR))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr)))
           (pol (spawn ^mock-policy)))
      (bootstrap-monero-resource! sr)
      (work! obs "alice" "spec-labor" 40 "ev1" "in1")
      (raise-xmr! obs 1)
      (plan-claim! obs %xmr-spec-id "alice" 1)   ; the plan's row: the 1 XMR alice claims below
      (values svc pol))))

;; the door answers through its table (doors/record-rows.scm my-payouts): the page's rows
(define (avail) (let ((a (assoc-ref (cdr ($ svc 'my-payouts "s1" "alice" #f)) "available")))
                  (/ (round (* a 10000)) 10000.0)))   ; XMR to 4 places — claim arithmetic is float
(define (payouts) (vector->list (assoc-ref (cdr ($ svc 'my-payouts "s1" "alice" #f)) "payouts")))
(define (claim-onhand)
  (let ((r ($ ($ svc 'scope-root "s1") 'observer)))
    #f))

(with-vat vat
  (display "\n── claim, then ask to send ──\n")
  ;; The claim door now correctly refuses spec-xmr: no citizen may claim a
  ;; financial instrument against credit (vf/facts/barred-specs.scm). This test
  ;; is about the PAYOUT RUNNER's own behaviour once a citizen already holds
  ;; XMR, not about whether the claim itself should be let through —
  ;; test-external-asset-claim.scm covers that directly — so the fixture
  ;; stands in for an already-settled claim the same way raise-xmr!/work!
  ;; stand in for the chain and the hour log: it records the transfer event
  ;; account-store's own 'claim method would have written, without walking
  ;; through the now-closed door.
  (check "the claim door itself refuses spec-xmr, as it should"
         (car ($ svc 'claim "s1" %xmr-resource-id 1 "alice" #f)) 'error)
  (let ((obs ($ SR 'observer)))
    ($ obs 'record-event
       (make-economic-event #:id "ev-claim-stand-in" #:action 'transfer
                            #:resource-inventoried-as %xmr-resource-id
                            #:to-resource-inventoried-as (string-append %xmr-resource-id "-alice")
                            #:resource-conforms-to %xmr-spec-id
                            #:resource-classified-as '("currency" "cryptocurrency")
                            #:provider "agent-playnet" #:receiver "alice"
                            #:resource-quantity (make-measure 1 "XMR")
                            #:effort-quantity (make-measure 20 %effort-unit)
                            #:in-scope-of '()
                            #:distribution-mode 'individual-claimable)))
  (check "1 XMR available to send" (avail) 1.0)

  (check "a typo is not an address"
         (car ($ svc 'request-payout "s1" "alice" #f "4xyz" 0.1 "" "")) 'error)
  (check "zero is not an amount"
         (car ($ svc 'request-payout "s1" "alice" #f ADDR 0 "" "")) 'error)
  (let ((r ($ svc 'request-payout "s1" "alice" #f ADDR 0.6 "" "rent")))
    (check "0.6 XMR to a real address: accepted" (car r) 'ok)
    (check "0.4 left to ask for" (avail) 0.4))
  ;; the record the door writes says what the act is: no tag names the crossing
  (let ((asks (filter (lambda (i) (eq? 'transfer (intent-action i)))
                      ($ ($ SR 'plan-store) 'all-intents)))
        (resolve (lambda (id) ($ ($ SR 'recipe-store) 'get-resource-spec id))))
    (check "the intent a payout writes derives hold-funds"
           (and (pair? asks)
                (every (lambda (i) (and (memq 'hold-funds (record-crossings i resolve)) #t)) asks))
           #t))
  (check "0.6 more is past her claim: refused"
         (car ($ svc 'request-payout "s1" "alice" #f ADDR 0.6 "" "")) 'error)
  (check "bob holds nothing: refused"
         (car ($ svc 'request-payout "s1" "bob" #f ADDR 0.1 "" "")) 'error)
  (check "the intent is hers, pending, at the address"
         (let ((p (car (payouts))))
           (and (equal? "pending" (assoc-ref p "state"))
                (equal? ADDR (assoc-ref p "address"))
                (= 0.6 (assoc-ref p "xmr")))))
  (check "a future-dated payout is not due yet"
         (let* ((r ($ svc 'request-payout "s1" "alice" #f ADDR 0.1 "2099-01-01T00:00:00Z" "later"))
                (due (cdr ($ svc 'due-payouts "s1" "2026-08-20T00:00:00Z"))))
           (and (eq? 'ok (car r)) (= 1 (length due)))))
  (check "…and she can retire it while pending"
         (let* ((later (find (lambda (p) (equal? "later" (assoc-ref p "note"))) (payouts))))
           (and (eq? 'ok (car ($ svc 'retire-payout "s1" "alice" (assoc-ref later "id"))))
                (= 1 (length (payouts))))))
  (check "bob cannot retire hers"
         (car ($ svc 'retire-payout "s1" "bob" (assoc-ref (car (payouts)) "id"))) 'error))

;; the runner: one tick, promise-pipelined, so the result lands a turn later
(with-vat vat (run-payouts! svc policy "s1" #f #:now-iso "2026-08-20T12:00:00Z"))
(with-vat vat #t) (with-vat vat #t) (with-vat vat #t) (with-vat vat #t)

(with-vat vat
  (display "\n── the runner moves it under the policy and settles ──\n")
  (let ((p (car (payouts))) (log ($ policy 'log)))
    (check "exactly one transfer went to the wallet" (length log) 1)
    (check "…to her address, in atomic units"
           (let ((d (car (car log))))
             (and (equal? ADDR (assoc-ref d "address"))
                  (= 600000000000 (assoc-ref d "amount")))))
    (check "the allowlist bracket is closed again" ($ policy 'allowed) '())
    (check "the intent reads sent:<txid>" (assoc-ref p "state") "sent:abc123")
    (check "her claim is 0.4 XMR now" (avail) 0.4))
  (check "a second tick sends nothing more"
         (begin (run-payouts! svc policy "s1" #f #:now-iso "2026-08-20T12:00:00Z") #t)))
(with-vat vat #t) (with-vat vat #t)
(with-vat vat
  (check "…still one transfer" (length ($ policy 'log)) 1)

  (display "\n── a refused transfer leaves the claim whole ──\n")
  ($ policy 'refuse! #t)
  (check "ask 0.3 more" (car ($ svc 'request-payout "s1" "alice" #f ADDR 0.3 "" "")) 'ok)
  (run-payouts! svc policy "s1" #f #:now-iso "2026-08-20T12:00:00Z"))
(with-vat vat #t) (with-vat vat #t) (with-vat vat #t) (with-vat vat #t)
(with-vat vat
  (let ((failed (find (lambda (p) (string-prefix? "failed:" (assoc-ref p "state"))) (payouts))))
    (check "the intent is parked as failed, with the reason"
           (and failed (string-contains (assoc-ref failed "state") "budget") #t))
    (check "no transfer was logged" (length ($ policy 'log)) 1)
    (check "the bracket is closed" ($ policy 'allowed) '())
    (check "her 0.4 XMR claim is whole" (avail) 0.4)))

;; a reconcile pass reads three answers in turn (what is sending, what has settled, what the
;; wallet shows) before it settles, so the vat is turned enough times for all of them
(define (settle-turns) (for-each (lambda (_) (with-vat vat #t)) (iota 7)))
(define (by-state pfx) (filter (lambda (p) (string-prefix? pfx (assoc-ref p "state"))) (payouts)))
(define NOW (instant->unix (now)))               ; unix seconds, as the wallet stamps them
(define (ask! xmr note) ($ svc 'request-payout "s1" "alice" #f ADDR xmr "" note))
(define (begin-all!)                             ; the gateway "dies" right after begin
  (for-each (lambda (p) ($ svc 'begin-payout "s1" (assoc-ref p "id"))) (by-state "pending")))
;; a wallet row: its transaction id is its own (EXTRA may state one), as a real wallet's are
(define (row addr xmr ts . extra)
  `(,@extra ("txid" . ,(format #f "tx-~a" ts)) ("timestamp" . ,ts) ("amount" . ,(inexact->exact (round (* xmr 1e12))))
    ("destinations" . #((("address" . ,addr) ("amount" . ,(inexact->exact (round (* xmr 1e12)))))))))

(with-vat vat
  (display "\n── reconciliation: a transfer the gateway lost sight of ──\n")
  ($ policy 'refuse! #f)
  (check "ask 0.1, then the gateway dies after begin" (car (ask! 0.1 "lost")) 'ok)
  (begin-all!)
  (check "it stands as sending" (length (by-state "sending")) 1)
  (check "…and still reserves the claim" (avail) 0.3)
  ;; the wallet shows nothing yet, and we are inside the grace window: wait
  (reconcile-payouts! svc policy "s1" #f #:now-epoch NOW))
(settle-turns)
(with-vat vat
  (check "nothing seen, inside the window: left alone" (length (by-state "sending")) 1)
  ;; now the wallet shows a matching outgoing row after it began
  ($ policy 'outgoing! (list (row ADDR 0.1 (+ NOW 5) '("txid" . "deadbeef"))))
  (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 10)))
(settle-turns)
(with-vat vat
  (check "matched on chain: settled with the wallet's txid"
         (let ((done (by-state "sent:")))
           (and (= 2 (length done))
                (member "sent:deadbeef" (map (lambda (p) (assoc-ref p "state")) done)) #t)))
  (check "her claim is 0.3 now" (avail) 0.3)

  (display "\n── the wallet says it failed ──\n")
  (check "ask 0.05" (car (ask! 0.05 "wallet-fail")) 'ok)
  (begin-all!)
  ($ policy 'outgoing! (list (row ADDR 0.05 (+ NOW 100) '("failed" . #t))))
  (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 200)))
(settle-turns)
(with-vat vat
  (check "a failed row fails the payout" (length (by-state "failed:the wallet")) 1)
  (check "…and frees the claim" (avail) 0.3)

  (display "\n── nothing seen past the grace window ──\n")
  (check "ask 0.2" (car (ask! 0.2 "vanished")) 'ok)
  (begin-all!)
  ($ policy 'outgoing! '())
  (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 100000)))
(settle-turns)
(with-vat vat
  (check "parked unsettled, never auto-failed" (length (by-state "unsettled:")) 1)
  (check "an unsettled payout still reserves the claim (no double pay on re-ask)" (avail) 0.1)
  (check "a second tick leaves it where it is" (begin (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 200000)) #t)))
(settle-turns)
(with-vat vat
  (check "…still one unsettled" (length (by-state "unsettled:")) 1)
  (let ((id (assoc-ref (car (by-state "unsettled:")) "id")))
    (check "the operator settles it by hand, with the txid"
           (car ($ svc 'settle-payout "s1" id "op-found-it" #f)) 'ok)
    (check "claim debited by it" (avail) 0.1)))

(with-vat vat
  (display "\n── two payouts, same address, same amount: one real transfer must not settle both ──\n")
  (check "ask 0.05, one" (car (ask! 0.05 "twin-a")) 'ok)
  (check "ask 0.05, two" (car (ask! 0.05 "twin-b")) 'ok)
  (begin-all!))
(settle-turns)
(with-vat vat
  (check "both stand as sending" (length (by-state "sending")) 2)
  ;; only ONE matching wallet row exists for BOTH payouts — the real bug:
  ;; payout-match's `find` over a shared row list let a second payout match
  ;; the same already-consumed row, settling twice off one real transfer
  ($ policy 'outgoing! (list (row ADDR 0.05 (+ NOW 300))))
  (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 310)))
(settle-turns)
(with-vat vat
  (check "exactly ONE of the twins settles off the one real transfer, the real bug fixed"
         (= 1 (length (filter (lambda (p) (and (string-prefix? "twin-" (assoc-ref p "note"))
                                                (string-prefix? "sent:" (assoc-ref p "state"))))
                               (payouts)))))
  (check "…and the other is still sending, not falsely settled"
         (= 1 (length (by-state "sending"))))
  ;; drain the still-sending twin so it doesn't linger for the privacy check below
  ($ policy 'outgoing! (list (row ADDR 0.05 (+ NOW 300)) (row ADDR 0.05 (+ NOW 305))))
  (reconcile-payouts! svc policy "s1" #f #:now-epoch (+ NOW 310)))
(settle-turns)
(with-vat vat
  (check "…and once the wallet shows a SECOND real row, that one settles too"
         (length (by-state "sending")) 0))

(with-vat vat
  (display "\n── privacy: addresses never leave the member ──\n")
  (let* ((snap ($ svc 'scope-snapshot "s1" #f))
         (txt  (format #f "~s" snap)))
    (let ((i (string-contains txt "payout:"))) (when i (format #t "LEAK: …~a…~%" (substring txt (max 0 (- i 200)) (min (string-length txt) (+ i 100))))))
    (check "the scope snapshot carries no payout intent" (not (string-contains txt "payout:")) #t)
    (check "…and no address" (not (string-contains txt ADDR)) #t)))

(display "\n")
(test-summary!)
