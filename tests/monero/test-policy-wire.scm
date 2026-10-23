;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/monero/test-policy-wire.scm — the wallet policy across a process boundary
;;;
;;; The gateway holds the policy through OCapN, and CapTP's Syrup refuses a
;;; dotted pair and a record. These checks stand on the property that
;;; matters: everything the wire facet hands out, and everything the client
;;; hands in, is something Syrup encodes — and a caller of the client sees
;;; the policy's own values, a <balance-info> included.
;;;
;;; Run:  guile -L module tests/monero/test-policy-wire.scm

(use-modules (goblins)
             (goblins vat)
             (goblins actor-lib methods)
             (goblins contrib syrup)
             (playnet test harness)
             (playnet monero wallet)
             (playnet monero policy)
             (playnet monero policy-wire)
             (srfi srfi-1))

(define (syrup-safe? v)
  (catch #t (lambda () (syrup-encode v) #t) (lambda _ #f)))

;;; ── The codec ─────────────────────────────────────────────────────────────

(define %values
  (list 0 1500000000000 -3 3/2 1.5 "tx" 'ok #t #f '()
        '(1 2 3)
        '((reserved . 5) (remaining . 7) (payee . "vps"))
        '(("tx_hash" . "abc") ("fee" . 10))
        `(("in" . ,(vector '(("amount" . 5) ("height" . 9)))))
        (list '(("address" . "4A") ("amount" . 100)))))

(check "plain values survive the wire unchanged"
       (every (lambda (v) (equal? v (wire-decode (wire-encode v)))) %values))

(check "every encoded value is one string, which Syrup carries"
       (every (lambda (v) (let ((w (wire-encode v))) (and (string? w) (syrup-safe? w))))
              %values))

(check "the same values, bare, are what Syrup refuses (the reason for the wire)"
       (not (syrup-safe? '((reserved . 5)))))

(let ((bi (wire-decode (wire-encode (make-balance-info 9 7 3)))))
  (check "a balance-info is rebuilt on the far side"
         (and (balance-info? bi)
              (= 9 (balance-info-atomic bi))
              (= 7 (balance-info-unlocked-atomic bi))
              (= 3 (balance-info-blocks-to-unlock bi)))))

(check "a method's empty answer crosses, and comes back as no value"
       (unspecified? (wire-decode (wire-encode (if #f #f)))))

(check-error "a procedure cannot cross"
             (lambda () (wire-encode (lambda () #t))))
(check-error "a wire value is a string"
             (lambda () (wire-decode 42)))
(check-error "a wire string holds one datum"
             (lambda () (wire-decode "1 2")))
(check-error "a forged balance-info is refused"
             (lambda () (wire-decode "(%balance-info 1 \"x\" 3)")))

;;; ── Through both actors, across two vats ──────────────────────────────────

(define %address "49AS5K3Btest")
(define %transferred '())

(define (^fake-wallet bcom)
  (methods
   ((get-balance) (make-balance-info 2000000000000 1500000000000 4))
   ((get-address) %address)
   ((get-transfers filter)
    `(("out" . ,(vector `(("txid" . "t1") ("amount" . 5))))
      ("asked" . ,filter)))
   ((transfer destinations)
    (set! %transferred destinations)
    '(("tx_hash" . "deadbeef") ("fee" . 10000)))))

(define wallet-vat  (spawn-vat #:name "wallet"))
(define gateway-vat (spawn-vat #:name "gateway"))

(define-values (policy-ref wire)
  (with-vat wallet-vat
    (let* ((wallet (spawn ^fake-wallet))
           (policy (spawn ^wallet-policy wallet
                          (deserialize-policy '(policy 5 2 () "test"))
                          0 0 (lambda (evt) #t) (lambda (_) #t))))
      (values policy (spawn ^wallet-policy-wire policy)))))

;; What the facet itself hands out — this is what meets Syrup.
(check "the facet answers get-balance with a Syrup-safe string"
       (let ((w (with-vat wallet-vat ($ wire 'get-balance))))
         (and (string? w) (syrup-safe? w))))
(check "the facet answers stats with a Syrup-safe string"
       (syrup-safe? (with-vat wallet-vat ($ wire 'stats))))

(check-error "rewire is no method of the wire"
             (lambda () (with-vat wallet-vat ($ wire 'rewire #f))))
(check-error "the raw policy record is no method of the wire"
             (lambda () (with-vat wallet-vat ($ wire 'policy))))
(check "the wire's method list leaves the rewiring methods out"
       (not (any (lambda (m) (memq m %wire-methods))
                 '(rewire rewire-audit rewire-credential-check policy))))

;; The client asks for the facet on every call; %current-wire is what the
;; wallet "last announced".
(define %current-wire wire)

(define client
  (with-vat gateway-vat
    (spawn ^wallet-policy-client (lambda () %current-wire))))

(define (ask . message)
  "Send MESSAGE to the client from the gateway vat; wait for the answer."
  (let ((result #f))
    (with-vat gateway-vat
      (on (apply <- client message)
          (lambda (v) (set! result (cons 'ok v)))
          #:catch (lambda (e) (set! result (cons 'error e)))))
    (let loop ((n 0))
      (cond (result result)
            ((> n 500) (cons 'timeout #f))
            (else (usleep 10000) (loop (+ n 1)))))))

(let ((r (ask 'get-balance)))
  (check "a caller of the client sees a balance-info, as it always did"
         (and (pair? r) (eq? 'ok (car r))
              (balance-info? (cdr r))
              (= 1500000000000 (balance-info-unlocked-atomic (cdr r))))))

(let ((r (ask 'get-address)))
  (check "get-address comes back as the address string"
         (equal? r (cons 'ok %address))))

(let ((r (ask 'stats)))
  (check "stats comes back as its symbol-keyed alist"
         (and (eq? 'ok (car r))
              (= 5 (assq-ref (cdr r) 'monthly-budget-xmr))
              (eq? #t (assq-ref (cdr r) 'wallet-wired)))))

(let ((r (ask 'get-outgoing 3760000)))
  (check "get-outgoing carries its argument in and its JSON alist back"
         (and (eq? 'ok (car r))
              (equal? "t1" (assoc-ref (vector-ref (assoc-ref (cdr r) "out") 0) "txid"))
              (= 3760000 (assoc-ref (assoc-ref (cdr r) "asked") "min_height")))))

;; A transfer: authorize the payee through the wire, then pay it — the
;; destinations are a list of alists, the shape Syrup refuses bare.
(let ((r (ask 'authorize-invoice "inv-1" %address 1)))
  (check "authorize-invoice goes through" (eq? 'ok (car r))))

(let* ((dests (list `(("address" . ,%address) ("amount" . 500000000000))))
       (r (ask 'transfer dests)))
  (check "transfer carries its destinations in and the tx alist back"
         (and (eq? 'ok (car r))
              (equal? "deadbeef" (assoc-ref (cdr r) "tx_hash"))
              (equal? %transferred dests))))

;; revoke-invoice answers nothing. The facet encodes inside the policy's turn,
;; so an answer it could not encode would unwind the revocation itself.
(let ((r (ask 'revoke-invoice "inv-1")))
  (check "revoke-invoice goes through" (eq? 'ok (car r))))
(check "and the entry is really gone from the policy's allowlist"
       (null? (monero-spend-policy-allowlist
               (with-vat wallet-vat ($ policy-ref 'policy)))))

(let ((r (ask 'transfer (list '(("address" . "4Stranger") ("amount" . 1))))))
  (check "the policy's refusal reaches the caller as a broken promise"
         (eq? 'error (car r))))

;; The wallet process restarts: a new facet, a new identity. The same client
;; follows it, with no one re-spawning anything on the gateway's side.
(define %address-2 "49AS5K3Bsecond-run")

(define wire-2
  (with-vat wallet-vat
    (let* ((wallet (spawn (lambda (bcom)
                            (methods ((get-address) %address-2)))))
           (policy (spawn ^wallet-policy wallet
                          (deserialize-policy '(policy 5 2 () "test"))
                          0 0 (lambda (evt) #t) (lambda (_) #t))))
      (spawn ^wallet-policy-wire policy))))

(set! %current-wire wire-2)
(check "after the wallet restarts, the same client reaches the new facet"
       (equal? (ask 'get-address) (cons 'ok %address-2)))

(set! %current-wire #f)
(check "while no policy is announced, a call is a broken promise"
       (eq? 'error (car (ask 'get-address))))

(test-summary!)
