;;; test-redistribution.scm — redistribution mandate + breach detection

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet federation auditor) (playnet credentials audit) (playnet credentials commitments) (playnet keri acdc) (playnet boot scope) (playnet federation structural-invariants) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))


(define (make-leaf store name aid)
  (let ((root (spawn-scope-root name)))
    (spawn-scope name
                 #:kind 'commune
                 #:scope-root-ref root
                 #:scope-aid aid
                 #:acdc-store store)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Mandate-credential round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Mandate ACDC ──\n")

(let ((m (make-redistribution-mandate-credential
          "EFED" "ELEAF"
          '(custody-of-spec-above "spec:grain" 100)
          'federation-pool)))
  (check-pred "schema correct"
              (equal? *schema-playnet-redistribution-mandate*
                      (cred-schema m)))
  (check-pred "issuer = federation" (equal? "EFED"  (cred-issuer m)))
  (check-pred "holder = leaf"       (equal? "ELEAF" (cred-holder m)))
  (check-pred "threshold round-trips"
              (equal? '(custody-of-spec-above "spec:grain" 100)
                      (cred-claim m 'threshold-spec)))
  (check-pred "recipient round-trips"
              (eq? 'federation-pool (cred-claim m 'recipient-policy))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Threshold compiler
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Threshold compiler ──\n")

(let ((p (compile-threshold-spec
          '(custody-of-spec-above "spec:grain" 100))))
  (check-pred "p is a procedure" (procedure? p))
  (check-pred "p(50)  = #f"      (not (p 50)))
  (check-pred "p(100) = #f"      (not (p 100)))
  (check-pred "p(150) = #t"      (p 150)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Healthy leaf (under threshold) → no breach
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Compliant leaf ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "L" "EL"))
         (gov   ($ leaf 'mint-gov-cap "op")))
    ($ store 'issue
       (make-redistribution-mandate-credential
        "EFED" "EL" '(custody-of-spec-above "spec:grain" 100) 'federation-pool))
    ($ leaf 'attest-custody gov "spec:grain" 50)
    (check-pred "no breaches"
                (null? (redistribution-mandate-breaches leaf)))
    (check-pred "redistribution coherent"
                (redistribution-coherent? leaf))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Leaf above threshold → breach
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Breach detection ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "L4" "EL4"))
         (gov   ($ leaf 'mint-gov-cap "op")))
    ($ store 'issue
       (make-redistribution-mandate-credential
        "EFED" "EL4" '(custody-of-spec-above "spec:grain" 100) 'federation-pool))
    ($ leaf 'attest-custody gov "spec:grain" 250)
    (let ((breaches (redistribution-mandate-breaches leaf)))
      (check-pred "one breach reported" (= 1 (length breaches)))
      (check-pred "breach qty = 250"    (= 250 (cdr (car breaches)))))
    (check-pred "redistribution incoherent"
                (not (redistribution-coherent? leaf)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. After redistribution (transfer-custody) → no longer breached
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. Compliance via transfer ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "L5" "EL5"))
         (gov   ($ leaf 'mint-gov-cap "op")))
    ($ store 'issue
       (make-redistribution-mandate-credential
        "EFED" "EL5" '(custody-of-spec-above "spec:grain" 100) 'federation-pool))
    ($ leaf 'attest-custody gov "spec:grain" 250)
    (check-pred "before transfer: breached"
                (not (redistribution-coherent? leaf)))
    ;; Transfer surplus to federation pool
    ($ leaf 'transfer-custody gov "spec:grain" 250 "EPool"
       'carries '())
    (check-pred "after transfer: no breach"
                (redistribution-coherent? leaf))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Auditor surfaces redistribution breach in incoherence-alert
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Auditor surfaces breach ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (leaf  (make-leaf store "L6" "EL6"))
         (top   (spawn-scope "TOP6"
                             #:kind 'federation
                             #:scope-aid "ETOP6"
                             #:acdc-store store))
         (gtop  ($ top 'mint-gov-cap "op"))
         (gleaf ($ leaf 'mint-gov-cap "op")))
    ($ top 'admit-commune gtop "leaf" leaf)
    ($ store 'issue
       (make-redistribution-mandate-credential
        "ETOP6" "EL6" '(custody-of-spec-above "spec:grain" 100) 'federation-pool))
    ($ leaf 'attest-custody gleaf "spec:grain" 500)
    (let* ((auditor (spawn-federation-auditor top))
           (_ ($ auditor 'audit!))
           (alerts ($ store 'by-schema *schema-playnet-incoherence-alert*)))
      (check-pred "alert emitted" (= 1 (length alerts)))
      (let ((violations (cred-claim (car alerts) 'violations)))
        (check-pred "redistribution-breaches reported"
                    (assq-ref violations 'redistribution-breaches))))))


(display "\n")
(test-summary!)
