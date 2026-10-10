;;; test-steward-grant.scm — the grant's `eligible` claim: append-only and
;;; SAID-stable, read back as the steward rule, and carried on by
;;; transfer-custody with every other term of the grant.
;;;
;;; Run:  guile --no-auto-compile -L module -L tests tests/governance/test-steward-grant.scm

(use-modules (playnet test harness)
             (playnet scope root) (srfi srfi-1)
             (playnet doors service)
             (playnet credentials custody) (playnet keri acdc) (playnet governance scope) (playnet governance socialization) (playnet keri acdc) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define UNTIL "2099-01-01T00:00:00Z")
(define RULE  "{\"filter-rule\":[\"aid\",\"ETia\"]}")

(display "\n── the eligible claim is append-only, emitted only when set ──\n")
(define plain  (socialization-credential "EAlice" "EHearth" "oven" 1 #:until UNTIL))
(define blank  (socialization-credential "EAlice" "EHearth" "oven" 1 #:until UNTIL #:eligible ""))
(define ruled  (socialization-credential "EAlice" "EHearth" "oven" 1 #:until UNTIL #:eligible RULE))
(check "a grant without a rule carries no eligible claim" (assq 'eligible (cred-claims plain)) #f)
(check "an empty rule is the absent rule — the SAID every earlier grant had"
       (cred-said blank) (cred-said plain))
(check "a rule is a different grant" (equal? (cred-said ruled) (cred-said plain)) #f)
(check "the rule reads back as the filter-rule" (grant-steward-rule ruled) #("aid" "ETia"))
(check "no rule reads as #f" (grant-steward-rule plain) #f)

(display "\n── transfer-custody carries the grant's terms to the next custodian ──\n")
(define vat (spawn-vat))
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Kitchen"))
         (scope (spawn-scope "Kitchen" #:kind 'commune #:scope-root-ref root
                             #:scope-aid "EKitchen" #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))
    ;; the standing attestation, every optional term set
    ($ store 'issue
       (make-custody-attestation-credential "EKitchen" "EKitchen" "oven" 1
         #:valid-from "2026-01-01T00:00:00Z" #:valid-until UNTIL
         #:movable #t #:return-to "home" #:condition-floor "clean"
         #:qty-unit "hours/day" #:eligible RULE #:ref "r1"))
    ($ scope 'transfer-custody gov "oven" 1 "ENext" 'carries '())
    (let ((next (find (lambda (c) (and (equal? "ENext" (cred-holder c))
                                       (not (cred-revoked? c))))
                      ($ store 'by-schema *schema-playnet-custody-attestation*))))
      (check "the next custodian holds a live attestation" (and next #t) #t)
      (check "the window travels"        (cred-claim next 'valid-until) UNTIL)
      (check "movability travels"        (cred-claim next 'movable) #t)
      (check "the return place travels"  (cred-claim next 'return-to) "home")
      (check "the condition floor travels" (cred-claim next 'condition-floor) "clean")
      (check "the unit travels"          (cred-claim next 'qty-unit) "hours/day")
      (check "the steward rule travels"  (cred-claim next 'eligible) RULE)
      (check "the ref is per-issuance and stays behind" (cred-claim next 'ref) #f))))

(test-summary!)
