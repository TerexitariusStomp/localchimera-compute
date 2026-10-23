;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/e2e/machine-payout-rails.scm — the opt-in pay layer end to end.
;;;
;;; Mutual credit is the default rail; token payout is per-member opt-in,
;;; and the opt-in signature is the dual-signed 'payout AccountLink —
;;; never a free-form address. settlement->member-plan partitions a
;;; reconciled statement: bound lenders' entries become sends to the
;;; BOUND CAIP-10, everyone else's entries stay credit rows. Rate
;;; statements carry the exchange reference a commune prices credit
;;; against; malformed assets refuse at the statement's own parse.
;;;
;;; Run: guile --no-auto-compile -L module -L tests tests/e2e/machine-payout-rails.scm

(use-modules (playnet test harness)
             (playnet test e2e)
             (playnet machine settlement)
             (playnet machine payout)
             (playnet machine binding)
             (srfi srfi-1))

(define HOME "did:keri:EHomeCommune")
(define ALICE "did:key:z6MkAliceLender")
(define CAROL "did:key:z6MkCarolLender")

;;; ── the partition — credit default, token on opt-in ─────────────────────

(display "\n── the opt-in partition — bound lenders take token, the rest credit ──\n")

(define entries
  `(((bridgeJobId . "bj-a") (receiptDigest . "d:a") (amount . 30)
     (asset . "eip155:100/erc20:0xGLM") (lenderAccount . "alice"))
    ((bridgeJobId . "bj-c") (receiptDigest . "d:c") (amount . 20)
     (asset . "eip155:100/erc20:0xGLM") (lenderAccount . "carol"))))

(define stmt
  (make-settlement-statement
   #:period "2026-W43" #:entries entries #:payments '()
   #:bridge-sig "sig-bridge"))

;; ALICE opted in: a live 'payout binding naming an eip155 Safe.
;; CAROL never bound — her entries stay credit, untouched.
(define alice-binding
  (make-account-binding
   (make-account-link #:did-key ALICE #:scope-aid HOME
                      #:account "eip155:100:0xAliceSafe"
                      #:purpose 'payout #:nonce "n1" #:expiry 9999999999)
   "sigS" "sigA"))

(define (binding-of e)
  (if (equal? (assq-ref e 'lenderAccount) "alice") alice-binding #f))

(let ((plan (settlement->member-plan stmt #:binding-of binding-of)))
  (let ((token (cdr (assq 'token plan)))
        (credit (cdr (assq 'credit plan))))
    (check "the bound lender's entry goes token"
           (length token) 1)
    (check "the token row pays the BOUND account, not a claimed one"
           (cdr (assoc "to" (car token))) "eip155:100:0xAliceSafe")
    (check "the row keeps its asset and amount"
           (and (equal? (cdr (assoc "asset" (car token)))
                        "eip155:100/erc20:0xGLM")
                (equal? (cdr (assoc "amount" (car token))) 30)) #t)
    (check "the digest rides — the send is the same fact as the receipt"
           (cdr (assoc "receiptDigest" (car token))) "d:a")
    (check "the unbound lender's entry stays a credit entry"
           (and (= (length credit) 1)
                (equal? (assq-ref (car credit) 'lenderAccount) "carol")) #t)))

(let ((plan (settlement->member-plan stmt))) ; no bindings at all
  (check "nobody bound → everything is credit, nothing token"
         (and (null? (cdr (assq 'token plan)))
              (= (length (cdr (assq 'credit plan))) 2)) #t))

(scenario "a binding that is not live does not opt in")
(let* ((stale
        (make-account-binding
         (make-account-link #:did-key ALICE #:scope-aid HOME
                            #:account "eip155:100:0xAliceSafe"
                            #:purpose 'payout #:nonce "n2" #:expiry 1000)
         "sigS" "sigA"))
       (plan (settlement->member-plan
              stmt #:binding-of (lambda (e)
                                  (if (equal? (assq-ref e 'lenderAccount)
                                              "alice")
                                      stale #f)))))
  (check "an expired 'payout binding keeps the entry in credit"
         (and (null? (cdr (assq 'token plan)))
              (= (length (cdr (assq 'credit plan))) 2)) #t))

(scenario "a keri: account is an identity, not a payee")
(let* ((id-bind
        (make-account-binding
         (make-account-link #:did-key ALICE #:scope-aid HOME
                            #:account "keri:EAliceAid"
                            #:purpose 'payout #:nonce "n3" #:expiry 9999999999)
         "sigS" "sigA"))
       (plan (settlement->member-plan
              stmt #:binding-of (lambda (e)
                                  (if (equal? (assq-ref e 'lenderAccount)
                                              "alice")
                                      id-bind #f)))))
  (check "a keri:-bound 'payout link pays nobody — stays credit"
         (and (null? (cdr (assq 'token plan)))
              (= (length (cdr (assq 'credit plan))) 2)) #t))

(scenario "a 'node-purpose binding is not an opt-in")
(let* ((node-bind
        (make-account-binding
         (make-account-link #:did-key ALICE #:scope-aid HOME
                            #:account "eip155:100:0xAliceSafe"
                            #:purpose 'node #:nonce "n4" #:expiry 9999999999)
         "sigS" "sigA"))
       (plan (settlement->member-plan
              stmt #:binding-of (lambda (e)
                                  (if (equal? (assq-ref e 'lenderAccount)
                                              "alice")
                                      node-bind #f)))))
  (check "purpose 'node binds the key, not the pay rail"
         (and (null? (cdr (assq 'token plan)))
              (= (length (cdr (assq 'credit plan))) 2)) #t))

;;; ── the rate statement — a signed exchange reference ────────────────────

(display "\n── rate statements — the exchange reference, signed like a settlement ──\n")

(let ((r (make-rate-statement #:base "eip155:100/erc20:0xGLM"
                              #:quote "hive:credit" #:rate 0.42
                              #:at "2026-10-23T00:00:00Z"
                              #:bridge-sig "sig-rate")))
  (check "a rate statement builds and reads"
         (and (equal? (rate-statement-base r) "eip155:100/erc20:0xGLM")
              (equal? (rate-statement-quote r) "hive:credit")
              (equal? (rate-statement-rate r) 0.42)) #t)
  (check "the wire form round-trips"
         (let ((back (alist->rate-statement (rate-statement->alist r))))
           (and (equal? (rate-statement-rate back) 0.42)
                (equal? (rate-statement-bridge-sig back) "sig-rate"))) #t)
  (check "string-keyed wire parses too"
         (rate-statement? (alist->rate-statement
                           '(("base" . "b") ("quote" . "q") ("rate" . 1)
                             ("at" . "t") ("bridgeSig" . "s")))) #t))

(check-error "a zero rate attests nothing"
             (lambda () (make-rate-statement #:base "b" #:quote "q"
                                             #:rate 0 #:at "t"
                                             #:bridge-sig "s")))
(check-error "a negative rate attests nothing"
             (lambda () (make-rate-statement #:base "b" #:quote "q"
                                             #:rate -1 #:at "t"
                                             #:bridge-sig "s")))
(check-error "unsigned is no attestation"
             (lambda () (make-rate-statement #:base "b" #:quote "q"
                                             #:rate 1 #:at "t"
                                             #:bridge-sig #f)))

;;; ── the asset shape — CAIP-19 or refused ────────────────────────────────

(display "\n── the asset shape — malformed denominations never reconcile ──\n")

(check "a CAIP-19 slip44 asset reads"
       (caip19? "eip155:1/slip44:60") #t)
(check "a CAIP-19 erc20 asset reads"
       (caip19? "eip155:100/erc20:0xGLM") #t)
(check "a bare word is not an asset"
       (caip19? "GLM") #f)
(check "a chain with no asset-ns is not an asset"
       (caip19? "eip155:1/60") #f)
(check "a non-string is not an asset"
       (caip19? 'eip155:1/slip44:60) #f)

(check-error "a statement entry with a bare-word asset refuses"
             (lambda ()
               (make-settlement-statement
                #:period "w"
                #:entries '(((bridgeJobId . "j") (receiptDigest . "d")
                             (amount . 1) (asset . "GLM")))
                #:payments '() #:bridge-sig "s")))
(check-error "a payment with a malformed asset refuses"
             (lambda ()
               (make-settlement-statement
                #:period "w" #:entries '()
                #:payments '(((txHash . "0x1") (asset . "GLM")
                              (amount . 1)))
                #:bridge-sig "s")))
(let ((ok (make-settlement-statement
           #:period "w" #:entries entries
           #:payments '(((txHash . "0xabc")
                         (asset . "eip155:100/erc20:0xGLM")
                         (amount . 50)))
           #:bridge-sig "s")))
  (check "well-formed CAIP-19 statements still build"
         (settlement-statement? ok) #t))

(test-summary!)