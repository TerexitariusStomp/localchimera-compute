;;; tests/governance/test-custodian-heartbeat.scm

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness)
             (playnet keys bran-custody) (playnet credentials audit) (playnet keri acdc) (playnet keri acdc) (playnet keri acdc-store)
             (playnet keys bran-custodians)
             (rnrs bytevectors)
             (goblins))

(define vat (spawn-vat))

;; ── Setup: split a bran into 3-of-5 custodians ─────────────────────

(define %subject-aid "E_test_scope_AID")
(define %bran (make-bytevector 32 7))
(define %holders '("H1" "H2" "H3" "H4" "H5"))

(define %store #f)
(define %custodians #f)
(define %heartbeat #f)

(with-vat vat
  (set! %store (spawn-acdc-store))
  (set! %custodians (split-and-spawn-custodians! %bran %holders 3 %subject-aid))
  (set! %heartbeat (spawn-custodian-heartbeat
                    %subject-aid %custodians 3
                    #:sink-store %store)))

;; ── Healthy tick: all 5 reachable, no alert ────────────────────────

(define %tick1
  (with-vat vat ($ %heartbeat 'tick!)))

(check "healthy: 5/5 reachable"
       (and (eq? 'reachable (car %tick1))
            (= 5 (cadr %tick1))))

(check "healthy: healthy? = #t"
       (eq? #t (cadr (memq 'healthy? %tick1))))

(check "healthy: no incoherence-alert emitted"
       (null? (with-vat vat
                ($ %store 'by-schema *schema-playnet-incoherence-alert*))))

;; ── Simulate failures by reducing the custodian list ───────────────
;; Drop 3 custodians (keep 2) — below the threshold of 3.

(define %heartbeat-degraded #f)
(with-vat vat
  (set! %heartbeat-degraded
        (spawn-custodian-heartbeat
         %subject-aid
         (list (car %custodians) (cadr %custodians))   ; only 2
         3
         #:sink-store %store)))

(define %tick2
  (with-vat vat ($ %heartbeat-degraded 'tick!)))

(check "degraded: 2/2 reachable but threshold 3"
       (and (= 2 (cadr %tick2))
            (eq? #f (cadr (memq 'healthy? %tick2)))))

(check "degraded: incoherence-alert emitted"
       (= 1 (length (with-vat vat
                      ($ %store 'by-schema
                         *schema-playnet-incoherence-alert*)))))

;; ── Inspect the alert payload ──────────────────────────────────────

(let ((alerts (with-vat vat
                ($ %store 'by-schema *schema-playnet-incoherence-alert*))))
  (check "alert has custody-shares-unreachable in violations"
         (let* ((cred (car alerts))
                (viols (cred-claim cred 'violations)))
           (and (assoc 'custody-shares-unreachable viols) #t))))

(test-summary!)
