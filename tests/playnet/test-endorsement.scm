;;; test-endorsement.scm — tests for (playnet org endorsement) and capability-governed validation
;;; Run with:  guile -L module tests/test-endorsement.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet test harness))
(use-modules (playnet org gplay)
             (playnet org endorsement)
             (goblins)
             (goblins actor-lib sealers)
             (ice-9 receive))

;;; ── Harness ─────────────────────────────────────────────────────────────────
;;; ── Base bindings ──────────────────────────────────────────────────────────

(define test-base-bindings
  `((+       . ,+)
    (-       . ,-)
    (*       . ,*)
    (>       . ,>)
    (<       . ,<)
    (=       . ,=)
    (equal?  . ,equal?)
    (not     . ,not)
    (null?   . ,null?)
    (cons    . ,cons)
    (car     . ,car)
    (cdr     . ,cdr)
    (list    . ,list)
    (length  . ,length)
    (member  . ,member)
    (filter  . ,filter)
    (map     . ,map)
    (apply   . ,apply)
    (or      . ,(lambda args (let loop ((a args)) (cond ((null? a) #f) ((car a) => values) (else (loop (cdr a)))))))
    ;; Endorsement API
    (make-endorsement-authority . ,make-endorsement-authority)
    (endorse                    . ,endorse)
    (endorsed-with?             . ,endorsed-with?)
    (endorsed-value             . ,endorsed-value)
    (make-facet                 . ,make-facet)
    (make-faceted-validator     . ,make-faceted-validator)
    (make-attenuated-authority  . ,make-attenuated-authority)
    (name-prefix-predicate      . ,name-prefix-predicate)
    (name-set-predicate         . ,name-set-predicate)))

;;; ── Shared test vat ────────────────────────────────────────────────────────

(define test-vat (spawn-vat))

(define (ev expr org)
  (evaluate expr org '() ($ org 'current-expressor)))

(display "== Endorsement & Capability-Governed Validation Tests ==\n")

;;; ── 1. Backward compatibility: default-validator ───────────────────────────

(display "\n-- 1. backward compatibility: default-validator --\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    (ev '(define x 42) org)
    (check "define under default-validator" (ev 'x org) 42)
    (ev '(modify! 'y 99) org)
    (check "modify! under default-validator" (ev 'y org) 99)
    (ev '(enact! (lambda (e n v pre post) #t)) org)
    (check "enact! without endorsement (default)" (ev 'x org) 42)
    (check-error "self-rejecting validator still fails"
      (lambda () (ev '(enact! (lambda (e n v pre post) #f)) org)))))

;;; ── 2. Endorsement authority creation ──────────────────────────────────────

(display "\n-- 2. endorsement authority --\n")

(with-vat test-vat
  (receive (seal-proc unseal-proc sealed?-proc)
    (make-endorsement-authority)
    (let ((endorsed-val ($ seal-proc 42)))
      (check "seal-proc returns opaque value" (not (equal? endorsed-val 42)) #t)
      (check "sealed?-proc recognizes endorsed value" ($ sealed?-proc endorsed-val) #t)
      (check "unseal-proc extracts value" ($ unseal-proc endorsed-val) 42)
      (check "sealed?-proc rejects plain value" ($ sealed?-proc 42) #f))))

;;; ── 3. endorse / endorsed-with? / endorsed-value ───────────────────────────

(display "\n-- 3. endorse / endorsed-with? / endorsed-value --\n")

(with-vat test-vat
  (receive (seal-proc unseal-proc sealed?-proc)
    (make-endorsement-authority)
    (let ((bundle (endorse 1000 seal-proc)))
      (check "endorsed-with? recognizes bundle" (endorsed-with? sealed?-proc bundle) #t)
      (check "endorsed-value extracts inner value" (endorsed-value unseal-proc bundle) 1000)
      (check "endorsed-with? rejects plain value" (endorsed-with? sealed?-proc 1000) #f))))

;;; ── 4. Cross-authority isolation ───────────────────────────────────────────

(display "\n-- 4. cross-authority isolation --\n")

(with-vat test-vat
  (receive (seal-a unseal-a sealed?-a)
    (make-endorsement-authority)
    (receive (seal-b unseal-b sealed?-b)
      (make-endorsement-authority)
      (let ((bundle-a (endorse 42 seal-a)))
        (check "authority-a recognizes own bundle" (endorsed-with? sealed?-a bundle-a) #t)
        (check "authority-b rejects authority-a bundle"
               (endorsed-with? sealed?-b bundle-a) #f)))))

;;; ── 5. Faceted validator blocks non-endorsed modification ──────────────────

(display "\n-- 5. faceted validator blocks non-endorsed --\n")

(with-vat test-vat
  (receive (seal-proc unseal-proc sealed?-proc)
    (make-endorsement-authority)
    (let* ((org (make-initial-org test-base-bindings))
           (facet (make-facet (name-prefix-predicate 'treasury-) sealed?-proc))
           (fv (make-faceted-validator (list facet))))
      ;; Install faceted validator directly via $ call
      (let* ((version (next-version))
             (entry (list version ($ org 'current-expressor)
                          '(test) ($ org 'head-version))))
        ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
      ;; Unprotected name: should work
      (ev '(define x 42) org)
      (check "unprotected name allowed" (ev 'x org) 42)
      ;; Protected name without endorsement: should fail
      (check-error "protected name without endorsement fails"
        (lambda () (ev '(define treasury-balance 1000) org))))))

;;; ── 6. Faceted validator allows endorsed modification ──────────────────────

(display "\n-- 6. faceted validator allows endorsed --\n")

(with-vat test-vat
  (receive (seal-proc unseal-proc sealed?-proc)
    (make-endorsement-authority)
    (let* ((org (make-initial-org
                  (append `((seal-treasury . ,seal-proc)
                            (endorse . ,endorse))
                          test-base-bindings)))
           (facet (make-facet (name-prefix-predicate 'treasury-) sealed?-proc))
           (fv (make-faceted-validator (list facet))))
      ;; Install faceted validator
      (let* ((version (next-version))
             (entry (list version ($ org 'current-expressor)
                          '(test) ($ org 'head-version))))
        ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
      ;; Protected name with endorsement: should work
      (ev '(modify! 'treasury-balance (endorse 1000 seal-treasury)) org)
      ;; The stored value is the sealed bundle
      (check "endorsed value stored correctly"
             ($ sealed?-proc (ev 'treasury-balance org)) #t)
      ;; Unseal to verify the inner value
      (check "endorsed inner value is 1000"
             ($ unseal-proc (ev 'treasury-balance org)) 1000))))

;;; ── 7. enact! with endorsement installs new validator ──────────────────────

(display "\n-- 7. enact! with endorsement --\n")

(with-vat test-vat
  (receive (gov-seal gov-unseal gov-sealed?)
    (make-endorsement-authority)
    (let* ((org (make-initial-org
                  (append `((gov-seal . ,gov-seal)
                            (endorse . ,endorse))
                          test-base-bindings)))
           ;; Install a governance-checking faceted validator
           (gov-facet (make-facet (name-set-predicate '(validator)) gov-sealed?))
           (fv (make-faceted-validator (list gov-facet))))
      ;; First install the faceted validator (current is default, accepts anything)
      (let* ((version (next-version))
             (entry (list version ($ org 'current-expressor)
                          '(test) ($ org 'head-version))))
        ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
      ;; Now try enact! with endorsement via the evaluator
      (ev '(enact! (lambda (e n v pre post) #t)
                   (endorse (lambda (e n v pre post) #t) gov-seal))
          org)
      (check "enact! with valid endorsement succeeds" #t #t))))

;;; ── 8. enact! without endorsement fails when governance facet exists ───────

(display "\n-- 8. enact! without endorsement fails under governance --\n")

(with-vat test-vat
  (receive (gov-seal gov-unseal gov-sealed?)
    (make-endorsement-authority)
    (let* ((org (make-initial-org test-base-bindings))
           (gov-facet (make-facet (name-set-predicate '(validator)) gov-sealed?))
           (fv (make-faceted-validator (list gov-facet))))
      ;; Install faceted validator
      (let* ((version (next-version))
             (entry (list version ($ org 'current-expressor)
                          '(test) ($ org 'head-version))))
        ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
      ;; enact! without endorsement — the new-proc (a lambda) is not endorsed
      ;; so the governance facet rejects it
      (check-error "enact! without endorsement fails under governance"
        (lambda () (ev '(enact! (lambda (e n v pre post) #t)) org))))))

;;; ── 9. Attenuated authority ────────────────────────────────────────────────

(display "\n-- 9. attenuated authority --\n")

(with-vat test-vat
  (receive (full-seal full-unseal full-sealed?)
    (make-endorsement-authority)
    (receive (sub-seal sub-unseal sub-sealed?)
      (make-attenuated-authority full-sealed? (name-prefix-predicate 'treasury-))
      (let* ((org (make-initial-org
                    (append `((sub-seal . ,sub-seal)
                              (endorse . ,endorse))
                            test-base-bindings)))
             (treasury-facet (make-facet (name-prefix-predicate 'treasury-) sub-sealed?))
             (fv (make-faceted-validator (list treasury-facet))))
        ;; Install validator
        (let* ((version (next-version))
               (entry (list version ($ org 'current-expressor)
                            '(test) ($ org 'head-version))))
          ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
        ;; Sub-authority can endorse treasury-* names
        (ev '(modify! 'treasury-balance (endorse 5000 sub-seal)) org)
        (check "sub-authority endorsement accepted"
               ($ sub-sealed? (ev 'treasury-balance org)) #t)))))

;;; ── 10. Delegation chain ───────────────────────────────────────────────────

(display "\n-- 10. delegation chain --\n")

(with-vat test-vat
  (receive (alice-seal alice-unseal alice-sealed?)
    (make-endorsement-authority)
    ;; Alice creates a sub-authority for Bob
    (receive (bob-seal bob-unseal bob-sealed?)
      (make-attenuated-authority alice-sealed? (name-prefix-predicate 'budget-))
      (let* ((org (make-initial-org
                    (append `((bob-seal . ,bob-seal)
                              (endorse . ,endorse))
                            test-base-bindings)))
             (budget-facet (make-facet (name-prefix-predicate 'budget-) bob-sealed?))
             (fv (make-faceted-validator (list budget-facet))))
        ;; Install validator
        (let* ((version (next-version))
               (entry (list version ($ org 'current-expressor)
                            '(test) ($ org 'head-version))))
          ($ org 'enact! '(lambda (e n v pre post) #t) fv entry))
        ;; Bob can modify budget-* names
        (ev '(modify! 'budget-q1 (endorse 10000 bob-seal)) org)
        (check "delegated authority works" ($ bob-sealed? (ev 'budget-q1 org)) #t)
        ;; Alice's direct seal doesn't satisfy bob's facet
        (let ((alice-endorsed ($ alice-seal 999)))
          (check "alice seal doesn't satisfy bob facet"
                 ($ bob-sealed? alice-endorsed) #f))))))

;;; ── 11. Metacircular constraint still holds ────────────────────────────────

(display "\n-- 11. metacircular constraint --\n")

(with-vat test-vat
  (let ((org (make-initial-org test-base-bindings)))
    ;; Self-rejecting validator must fail
    (check-error "self-rejecting validator still fails"
      (lambda () (ev '(enact! (lambda (e n v pre post) #f)) org)))
    ;; Self-accepting validator must pass
    (ev '(enact! (lambda (e n v pre post) #t)) org)
    (check "self-accepting validator passes" #t #t)))

;;; ── 12. Name predicates ────────────────────────────────────────────────────

(display "\n-- 12. name predicates --\n")

(with-vat test-vat
  (let ((pred (name-prefix-predicate 'treasury-)))
    (check "prefix matches treasury-balance" ($ pred 'treasury-balance) #t)
    (check "prefix rejects budget-q1" ($ pred 'budget-q1) #f)
    (check "prefix matches exact prefix" ($ pred 'treasury-) #t)))

(with-vat test-vat
  (let ((pred (name-set-predicate '(validator rollback))))
    (check "set matches validator" ($ pred 'validator) #t)
    (check "set matches rollback" ($ pred 'rollback) #t)
    (check "set rejects treasury" ($ pred 'treasury) #f)))

;;; ── 13. Multiple facets ────────────────────────────────────────────────────

(display "\n-- 13. multiple facets --\n")

(with-vat test-vat
  (receive (econ-seal econ-unseal econ-sealed?)
    (make-endorsement-authority)
    (receive (infra-seal infra-unseal infra-sealed?)
      (make-endorsement-authority)
      (let* ((econ-facet (make-facet (name-prefix-predicate 'econ-) econ-sealed?))
             (infra-facet (make-facet (name-prefix-predicate 'infra-) infra-sealed?))
             (fv (make-faceted-validator (list econ-facet infra-facet))))
        ;; Test the validator directly
        (check "econ-endorsed passes econ facet"
               (fv 'anyone 'econ-budget ($ econ-seal 100) '() '()) #t)
        (check "infra-endorsed passes infra facet"
               (fv 'anyone 'infra-server ($ infra-seal "prod") '() '()) #t)
        (check "unendorsed fails econ facet"
               (fv 'anyone 'econ-budget 100 '() '()) #f)
        (check "wrong endorsement fails econ facet"
               (fv 'anyone 'econ-budget ($ infra-seal 100) '() '()) #f)
        (check "ungoverned name passes freely"
               (fv 'anyone 'free-var 42 '() '()) #t)))))

;;; ── Summary ────────────────────────────────────────────────────────────────

(newline)
(display (string-append "== " (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ==\n"))
