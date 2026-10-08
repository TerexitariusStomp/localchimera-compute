;;; test-skill-credential.scm — the skill membership ACDC (make-skill-credential)
;;;
;;; Asserts on schema / issuer / holder / claims / edges, NOT on SAID bytes
;;; (the test-custody-lift discipline), so it is independent of the blake3
;;; backend. Run: guile -L module tests/planner/test-skill-credential.scm

(use-modules (playnet test harness))
(use-modules )
(use-modules (playnet governance credentials) (playnet keri acdc))
(use-modules (srfi srfi-1))

;;; ════════════════════════════════════════════════════════════════════════════
;;; A skill credential carries the membership claim + founding-event edge
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Skill membership token ──\n")

(let* ((cred (make-skill-credential "EScope" "EWorker" "spec:surgeon" "Efounding-work-said")))
  (check "schema is playnet-skill" (cred-schema cred) *schema-playnet-skill*)
  (check "issuer is the scope"     (cred-issuer cred) "EScope")
  (check "holder is the worker"    (cred-holder cred) "EWorker")
  (check "skill claim"             (cred-claim cred 'skill) "spec:surgeon")
  (check "founding-event recorded in claims"
         (cred-claim cred 'founding-event-id) "Efounding-work-said")
  (check-pred "no hours field stored (derive, don't store)"
              (not (cred-claim cred 'hours)))
  (let ((e (cred-edge cred 'founding-event)))
    (check-pred "founding-event edge present" (pair? e))
    (check "edge targets the work event" (edge-target e) "Efounding-work-said")
    (check "edge is NI2I"                 (edge-operator e) 'NI2I)))

;;; Expiry convention (shared with custody, so recertification decay reuses it)
(display "\n── Live / expiry ──\n")
(let ((future (make-skill-credential "ES" "EW" "spec:baker" "Ee"
                                     #:valid-until "2099-12-31T00:00:00Z"))
      (past   (make-skill-credential "ES" "EW" "spec:baker" "Ee"
                                     #:valid-until "1999-01-01T00:00:00Z")))
  (check-pred "future valid-until carried"  (equal? "2099-12-31T00:00:00Z"
                                                    (cred-claim future 'valid-until)))
  (check-pred "past valid-until carried"    (equal? "1999-01-01T00:00:00Z"
                                                    (cred-claim past 'valid-until))))

(display "\n")
(test-summary!)
