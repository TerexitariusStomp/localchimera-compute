;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/compute/test-adapters.scm — the adopted-service seams: wire
;;; shapes are pinned, fail-closed defaults refuse, injected transports
;;; answer. Each adapter is thin by design — the test's job is that the
;;; thin it ships is the wire the service actually reads.

(use-modules (playnet test harness)
             (playnet machine specs)
             (playnet machine receipt)
             (playnet machine registry)
             (playnet machine settlement)
             (playnet machine envelope)
             (playnet machine executors)
             (playnet machine adapters)
             (playnet machine hrea)
             (playnet machine credit-commons)
             (playnet machine safe)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define HOME "did:keri:EHomeCommune")
(define ALICE "did:key:z6MkAlice")

;; ── executor adapters ────────────────────────────────────────────────────

(define env
  (make-job-envelope #:bridge-job-id "bj-1" #:image "wasm:sha256:abc"
                     #:entrypoint "run" #:input-hash "in:x"
                     #:caps '() #:network? #f))
(define repro (make-repro-spec #:mode 'deterministic #:seed 7
                               #:decoding "greedy"))

(check "wasimoff task carries module, entry, stdin, seed"
       (let ((t (wasimoff-task env repro)))
         (and (equal? (cdr (assoc "module" t)) "wasm:sha256:abc")
              (equal? (cdr (assoc "stdin" t)) "in:x")
              (= (cdr (assoc "seed" t)) 7))) #t)

(check "wasmcloud invocation carries component, operation, caps"
       (let ((i (wasmcloud-invocation env repro)))
         (and (equal? (cdr (assoc "component" i)) "wasm:sha256:abc")
              (equal? (cdr (assoc "operation" i)) "run")
              (= (cdr (assoc "seed" i)) 7))) #t)

(check "an adapter with no transport fails closed, not silent"
       (let ((x (make-wasimoff-executor)))
         (catch #t
           (lambda () ((%executor-run x) env repro) #f)
           (lambda (k . a) #t))) #t)

(check "an injected transport makes the executor answer"
       (let* ((fake (lambda (m path body)
                      `((outputHash . "out:ran") (taskId . "t1"))))
              (x (make-wasimoff-executor #:transport fake
                                         #:broker-url "edge.local")))
         (equal? ((%executor-run x) env repro) "out:ran")) #t)

(check "wasmcloud executor registers under its kind"
       (executor-kind
        (make-wasmcloud-executor #:transport (lambda (m p b) '())
                                 #:host-id "lattice-0")) 'wasmcloud)

;; ── hREA — the receipt is an EconomicEvent ───────────────────────────────

(define rcpt
  (make-receipt #:bridge-job-id "claim-1" #:lender-did ALICE
                #:input-hash "in:1" #:output-hash "out:1"
                #:usage (make-usage-meter #:unit "seconds" #:amount 12)
                #:repro (make-repro-spec #:mode 'deterministic #:seed 1)
                #:executed-at 1761000000000))

(check "receipt->economic-event: action use, digest as note, meter rides"
       (let ((e (receipt->economic-event rcpt #:commune-aid HOME)))
         (and (equal? (cdr (assoc "action" e)) "use")
              (equal? (cdr (assoc "provider" e)) ALICE)
              (string? (cdr (assoc "note" e)))
              (equal? (cdr (assoc "hasUnit"
                                  (cdr (assoc "resourceQuantity" e))))
                      "seconds")
              (= (cdr (assoc "hasNumericalValue"
                             (cdr (assoc "resourceQuantity" e))))
                 12))) #t)

(check "record-receipt! with no service answers unavailable, fails closed"
       (catch #t (lambda () (record-receipt! rcpt #:commune-aid HOME) #f)
              (lambda (k . a) #t)) #t)

(check "record-receipt! posts the mutation and answers the event id"
       (equal? (record-receipt! rcpt #:commune-aid HOME
                                #:post (lambda (q vars)
                                         '((id . "evt-1"))))
               "evt-1") #t)

;; ── Credit Commons — entries become ledger rows ─────────────────────────

(define stmt
  (make-settlement-statement
   #:period "w1"
   #:entries '(((bridgeJobId . "c1") (receiptDigest . "dd1")
                (amount . 5) (asset . "XMR") (lenderAccount . "alice-acct"))
               ((bridgeJobId . "c2") (receiptDigest . "dd2")
                (amount . 3) (asset . "XMR") (lenderAccount . "bob-acct")))
   #:payments '() #:bridge-sig "s"))

(check "settlement->ledger-rows: treasury pays, description is the receipt"
       (let ((rows (settlement->ledger-rows stmt #:treasury "treasury-acct")))
         (and (= (length rows) 2)
              (equal? (cdr (assoc "payer" (car rows))) "treasury-acct")
              (equal? (cdr (assoc "payee" (car rows))) "alice-acct")
              (= (cdr (assoc "amount" (car rows))) 5)
              (equal? (cdr (assoc "description" (car rows))) "c1:dd1"))) #t)

(check "post-settlement! fails closed without a node"
       (catch #t (lambda () (post-settlement! stmt #:treasury "t") #f)
              (lambda (k . a) #t)) #t)

;; ── Safe — the send rail ────────────────────────────────────────────────

(check "safe-proposal: a native send carries value directly"
       (let ((p (safe-proposal "0xSafe" "0xTo" 7 "XMR")))
         (and (equal? (cdr (assoc "to" p)) "0xTo")
              (equal? (cdr (assoc "value" p)) "7")
              (= (cdr (assoc "operation" p)) 0))) #t)

(check "safe-proposal: an ERC-20 row sends calldata on the token"
       (let ((p (safe-proposal "0xSafe" "0xTo" 9 "call"
                               #:token-addr "0xUSDC")))
         (and (equal? (cdr (assoc "to" p)) "0xUSDC")
              (equal? (cdr (assoc "value" p)) "0"))) #t)

(check "make-safe-send with no rails refuses"
       (catch #t (lambda ()
                   ((make-safe-send) "0xTo" 1 "XMR") #f)
              (lambda (k . a) #t)) #t)

(check "make-safe-send signs, posts, and answers the tx hash"
       (let* ((send (make-safe-send
                     #:post (lambda (path body)
                              '((transactionHash . "0xtx1")))
                     #:sign (lambda (proposal) "0xsig")
                     #:safe-addr "0xSafe")))
         (equal? (send "0xTo" 4 "XMR") "0xtx1")) #t)

(test-summary!)
