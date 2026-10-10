;;; test-credentials.scm — ACDC constructors + mandate-spec compile

(use-modules (playnet test harness))
(use-modules (playnet credentials commitments) (playnet credentials delegation) (playnet credentials membership) (playnet credentials registry) (playnet keri acdc) (playnet keri acdc))
(use-modules (goblins) (goblins utils hashmap))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Delegation credential structure + SAID determinism
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Credential structure ──\n")

(let ((c (make-delegation-credential #:issuer-aid "alice"
                                     #:holder-aid "bob"
                                     #:franchise 'federation
                                     #:fraction 0.4
                                     #:mandate-spec #f)))
  (check-pred "schema is playnet-delegation/v1"
              (equal? *schema-playnet-delegation* (cred-schema c)))
  (check-pred "issuer alice"   (equal? "alice" (cred-issuer c)))
  (check-pred "holder bob"     (equal? "bob"   (cred-holder c)))
  (check-pred "fraction 0.4"   (= 0.4 (cred-claim c 'fraction)))
  (check-pred "franchise 'federation"
              (eq? 'federation (cred-claim c 'franchise)))
  (check-pred "mandate #f"     (not (cred-claim c 'mandate)))
  (check-pred "not revoked"    (not (cred-revoked? c)))
  (check-pred "SAID is string" (string? (cred-said c))))

(let ((c1 (make-delegation-credential #:issuer-aid "alice"
                                      #:holder-aid "bob"
                                      #:franchise 'federation
                                      #:fraction 0.4
                                      #:mandate-spec #f))
      (c2 (make-delegation-credential #:issuer-aid "alice"
                                      #:holder-aid "bob"
                                      #:franchise 'federation
                                      #:fraction 0.4
                                      #:mandate-spec #f)))
  (check-pred "same content → same SAID"
              (equal? (cred-said c1) (cred-said c2))))

(let ((c1 (make-delegation-credential #:issuer-aid "alice"
                                      #:holder-aid "bob"
                                      #:franchise 'federation
                                      #:fraction 0.4
                                      #:mandate-spec #f))
      (c2 (make-delegation-credential #:issuer-aid "alice"
                                      #:holder-aid "bob"
                                      #:franchise 'federation
                                      #:fraction 0.5
                                      #:mandate-spec #f)))
  (check-pred "different content → different SAID"
              (not (equal? (cred-said c1) (cred-said c2)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. CCF, exclusion, federation-membership, membership credentials
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Other schemas ──\n")

(let ((c (make-ccf-credential #:issuer-group-aid "watershed-gov"
                              #:holder-aid "grandma"
                              #:commune "Watershed"
                              #:ccf 0
                              #:assessed-at "2026-04-15"
                              #:reason "advanced dementia")))
  (check-pred "ccf schema" (equal? *schema-playnet-ccf-assessment* (cred-schema c)))
  (check-pred "ccf 0"      (= 0 (cred-claim c 'ccf)))
  (check-pred "commune"    (equal? "Watershed" (cred-claim c 'commune))))

(let ((c (make-exclusion-credential #:issuer-group-aid "watershed-gov"
                                    #:holder-aid "outlaw"
                                    #:commune "Watershed"
                                    #:excluded-at "2026-04-15")))
  (check-pred "exclusion schema"
              (equal? *schema-playnet-exclusion* (cred-schema c))))

(let ((c (make-federation-membership-credential #:issuer-group-aid "river-fed-gov"
                                                 #:commune-aid "watershed-aid"
                                                 #:federation "River-Federation"
                                                 #:commune-id "watershed"
                                                 #:admitted-at "2026-04-15")))
  (check-pred "fed-mem schema"
              (equal? *schema-playnet-federation-membership* (cred-schema c)))
  (check-pred "commune-id watershed"
              (equal? "watershed" (cred-claim c 'commune-id))))

(let ((c (make-membership-credential #:issuer-group-aid "watershed-gov"
                                     #:holder-aid "alice"
                                     #:commune "Watershed"
                                     #:admitted-at "2026-04-15")))
  (check-pred "membership schema"
              (equal? *schema-playnet-membership* (cred-schema c))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Mandate-spec compile + round-trip via DSL
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Mandate-spec DSL ──\n")

(let ((pred (compile-mandate-spec '(equal-position yes))))
  (check-pred "equal-position yes accepts 'yes"
              (pred (list 'stance "p-1" 'yes "alice" "E_alice")))
  (check-pred "equal-position yes rejects 'no"
              (not (pred (list 'stance "p-1" 'no "alice" "E_alice")))))

(let ((pred (compile-mandate-spec '(any-of-position (yes abstain)))))
  (check-pred "any-of accepts 'yes"
              (pred (list 'stance "p-1" 'yes "alice" "E_alice")))
  (check-pred "any-of accepts 'abstain"
              (pred (list 'stance "p-1" 'abstain "alice" "E_alice")))
  (check-pred "any-of rejects 'no"
              (not (pred (list 'stance "p-1" 'no "alice" "E_alice")))))

(let* ((pred (compile-mandate-spec '(min-distribution "plan-A" 0.5)))
       (good-dist (hashmap-set (hashmap) "plan-A" 0.6))
       (bad-dist  (hashmap-set (hashmap) "plan-A" 0.3))
       (good-stance (list 'expression 'plan "e-1" good-dist "alice" "E_alice"))
       (bad-stance  (list 'expression 'plan "e-1" bad-dist  "alice" "E_alice")))
  (check-pred "min-dist accepts 0.6 ≥ 0.5"  (pred good-stance))
  (check-pred "min-dist rejects 0.3 < 0.5" (not (pred bad-stance))))

(check-pred "opaque compiles to #f"
            (not (compile-mandate-spec 'opaque)))
(check-pred "unknown spec compiles to #f"
            (not (compile-mandate-spec '(unknown-form))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. mandate helper registers spec for round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. mandate helper round-trip ──\n")

(let* ((spec '(equal-position yes))
       (pred (mandate spec)))
  (check-pred "mandate compiles"     (procedure? pred))
  (check-pred "predicate works"      (pred (list 'stance "p" 'yes "a" "E_a")))
  (check-pred "spec recoverable via mandate-spec-of"
              (equal? spec (mandate-spec-of pred))))

(let ((unregistered-pred (lambda (s) #t)))
  (check-pred "anonymous predicate is opaque"
              (eq? 'opaque (mandate-spec-of unregistered-pred))))


(display "\n── 5. compute-plan-said: content-addressed plan ids ──\n")

;; A plan's identity is its content (scope-aid + sorted intent set).
;; Same content → same SAID (convergence). Any change → different SAID
;; (no silent amendment of confirmed plans).

(let ((said-1 (compute-plan-said "E_bakery" '("I-bread" "I-flour")))
      (said-2 (compute-plan-said "E_bakery" '("I-flour" "I-bread")))
      (said-3 (compute-plan-said "E_bakery" '("I-bread" "I-flour" "I-yeast")))
      (said-4 (compute-plan-said "E_other"  '("I-bread" "I-flour"))))

  (check-pred "deterministic: same inputs → same SAID"
              (equal? said-1 (compute-plan-said "E_bakery"
                                                '("I-bread" "I-flour"))))
  (check-pred "order-independent: same set in any order → same SAID"
              (equal? said-1 said-2))
  (check-pred "content-sensitive: adding an intent → different SAID"
              (not (equal? said-1 said-3)))
  (check-pred "issuer-sensitive: same intents under different scope → different SAID"
              (not (equal? said-1 said-4)))
  (check-pred "SAID is CESR qb64 with E prefix and 44 chars"
              (and (string? said-1)
                   (= 44 (string-length said-1))
                   (eq? #\E (string-ref said-1 0)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
