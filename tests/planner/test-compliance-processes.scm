;;; test-compliance-processes.scm — the compliance ProcessSpecification catalogue.
;;;
;;; Compliance is WORK: obtaining a permit is a Process (application + fee + admin
;;; labour → the credential), renewing / filing / disclosing likewise. This proves
;;; the reusable catalogue seeds well-formed VF recipes, and that the whole
;;; compliance metabolism for a jurisdiction falls out of its demand bill.
;;; Pure data (no observer, no solve) ⇒ no blake3.
;;;
;;; Run: guile -L module tests/planner/test-compliance-processes.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner vf schemas) (srfi srfi-1)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(use-modules (playnet planner legal crossings))
(use-modules (playnet planner legal registry))
(use-modules (playnet planner legal registry-actor))
(use-modules (playnet planner knowledge recipes compliance-processes))
(use-modules (playnet planner knowledge recipes compliance-food))

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
;; flat flow list for a process (flows-for-process returns (inputs . outputs)).
(define (flat-flows rs rp) (let ((fp ($ rs 'flows-for-process rp)))
                             (append (if (list? (car fp)) (car fp) '())
                                     (if (list? (cdr fp)) (cdr fp) '()))))
(define (actions-of flows) (map recipe-flow-action flows))

(define vat (spawn-vat))
(define out
  (with-vat vat
    (let ((rs (empty-rs)))
      ;; drive the WHOLE compliance metabolism off the food-vending bill — one
      ;; obtain recipe per credential, one file-return per levy. (The bill-seeder
      ;; calls seed-compliance-process-catalogue + each builder internally.)
      (define bill
        (car (call-with-values
               (lambda () (legal-demands (legal-context #:crossings '(food-vending)
                                                        #:place-path '("foodville" "world") #:act 'food)
                                         #:rules (list (compliance-food-rule))))
               list)))
      (define seeded (seed-compliance-recipes-for-bill rs bill #:authority "auth:foodville-health" #:fee 50))
      (define rp (car seeded))                          ; the entity-permit obtain process
      (list rp
            (flat-flows rs rp)
            ($ rs 'get-process-spec "pspec-obtain-permit")
            (recipe-process-process-conforms-to ($ rs 'get-recipe-process rp))
            ($ rs 'get-resource-spec "Food Establishment Permit")   ; auto-registered credential spec
            seeded
            ($ rs 'recipe-for-output "Food Establishment Permit")   ; the obtain recipe
            ($ rs 'recipe-for-output "Sales Tax")                    ; the file-return recipe
            (recipe-process-process-conforms-to ($ rs 'get-recipe-process "rp-file:Sales Tax"))))))

(define rp        (list-ref out 0))
(define flows     (list-ref out 1))
(define pspec     (list-ref out 2))
(define conforms  (list-ref out 3))
(define cred-spec (list-ref out 4))
(define seeded    (list-ref out 5))
(define perm-rec  (list-ref out 6))
(define tax-rec   (list-ref out 7))
(define tax-conf  (list-ref out 8))

(display "\n── the generic catalogue: obtain-permit as a reusable Process ──\n")
(format #t "  process ~a conforms-to ~a ; flows: ~a\n" rp conforms (actions-of flows))
(check-pred "the generic ProcessSpecification exists" (and pspec #t))
(check "the concrete recipe conforms to pspec-obtain-permit" conforms "pspec-obtain-permit")
(check-pred "it PRODUCES the credential holding-status will read"
            (any (lambda (f) (and (eq? (recipe-flow-action f) 'produce)
                                  (equal? (recipe-flow-resource-conforms-to f) "Food Establishment Permit")))
                 flows))
(check-pred "it WORKS admin labour (plannable — a duration + a skill)"
            (any (lambda (f) (and (eq? (recipe-flow-action f) 'work)
                                  (equal? (recipe-flow-resource-conforms-to f) "spec-admin"))) flows))
(check-pred "it CITES the application filing (the legal/filings.scm document)"
            (any (lambda (f) (and (eq? (recipe-flow-action f) 'cite)
                                  (equal? (recipe-flow-resource-conforms-to f) "filing"))) flows))
(check-pred "it CONSUMES the fee (state money — the fiat crossing)"
            (any (lambda (f) (and (eq? (recipe-flow-action f) 'consume)
                                  (equal? (recipe-flow-resource-conforms-to f) "spec-state-money"))) flows))
(check-pred "the credential spec was auto-registered" (and cred-spec #t))

(display "\n── the payoff: the whole compliance metabolism from the bill ──\n")
(format #t "  seeded recipe-processes: ~a\n" seeded)
(check "the bill seeded 3 compliance recipes (permit + card + sales tax)" (length seeded) 3)
(check-pred "an obtain recipe exists for the entity permit" (and perm-rec #t))
(check-pred "a file-return recipe exists for the sales-tax levy" (and tax-rec #t))
(check "…and its process conforms to pspec-file-return" tax-conf "pspec-file-return")

(display "\n")
(test-summary!)
