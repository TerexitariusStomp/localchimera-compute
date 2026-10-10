;;; test-custody-lift.scm — lift-custody-facts + fact-custodian-of-o

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (playnet credentials custody) (playnet keri acdc) (playnet keri acdc))
(use-modules (srfi srfi-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. lift-custody-facts: live attestations → (custodian-of …) tuples
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Lift live attestations ──\n")

(let* ((a1 (make-custody-attestation-credential
            #:issuing-authority-aid "EAuth"
            #:custodian-aid "EScopeA"
            #:resource-spec "spec:widget"
            #:qty 100))
       (a2 (make-custody-attestation-credential
            #:issuing-authority-aid "EAuth"
            #:custodian-aid "EScopeB"
            #:resource-spec "spec:gear"
            #:qty 50
            #:valid-from "2026-01-01T00:00:00Z"))
       (facts (lift-custody-facts (list a1 a2))))
  (check-pred "two facts lifted" (= 2 (length facts)))
  (check-pred "fact head is custodian-of"
              (every (lambda (f) (eq? 'custodian-of (car f))) facts))
  (let ((widget-fact (find (lambda (f) (equal? "spec:widget" (cadr f))) facts)))
    (check-pred "widget fact has scope A"
                (equal? "EScopeA" (caddr widget-fact)))
    (check-pred "widget fact has qty 100"
                (= 100 (cadddr widget-fact)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Expired attestations are filtered out
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Expiry filter ──\n")

(let* ((live    (make-custody-attestation-credential
                 #:issuing-authority-aid "EAuth"
                 #:custodian-aid "EA"
                 #:resource-spec "spec:x"
                 #:qty 10
                 #:valid-until "2099-12-31T23:59:59Z"))
       (expired (make-custody-attestation-credential
                 #:issuing-authority-aid "EAuth"
                 #:custodian-aid "EB"
                 #:resource-spec "spec:y"
                 #:qty 20
                 #:valid-until "2000-01-01T00:00:00Z"))
       (facts   (lift-custody-facts (list live expired))))
  (check-pred "expired filtered out" (= 1 (length facts)))
  (check-pred "live one survives"
              (equal? "spec:x" (cadr (car facts)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Revoked attestations are filtered out
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Revocation filter ──\n")

(let* ((live    (make-custody-attestation-credential
                 #:issuing-authority-aid "EAuth"
                 #:custodian-aid "EA"
                 #:resource-spec "spec:x"
                 #:qty 10))
       (revoked (cred-with-revoked
                 (make-custody-attestation-credential
                  #:issuing-authority-aid "EAuth"
                  #:custodian-aid "EB"
                  #:resource-spec "spec:y"
                  #:qty 20)
                 #t))
       (facts   (lift-custody-facts (list live revoked))))
  (check-pred "revoked filtered out" (= 1 (length facts))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. custody-cred-live? primitive
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. custody-cred-live? ──\n")

(let ((open-ended (make-custody-attestation-credential #:issuing-authority-aid "EA"
                                                       #:custodian-aid "EH"
                                                       #:resource-spec "s"
                                                       #:qty 1))
      (future     (make-custody-attestation-credential
                   #:issuing-authority-aid "EA"
                   #:custodian-aid "EH"
                   #:resource-spec "s"
                   #:qty 1
                   #:valid-until "2099-12-31T00:00:00Z"))
      (past       (make-custody-attestation-credential
                   #:issuing-authority-aid "EA"
                   #:custodian-aid "EH"
                   #:resource-spec "s"
                   #:qty 1
                   #:valid-until "1999-01-01T00:00:00Z")))
  (check-pred "open-ended is live"   (custody-cred-live? open-ended))
  (check-pred "future is live"       (custody-cred-live? future))
  (check-pred "past is not live"     (not (custody-cred-live? past))))


(display "\n")
(test-summary!)
