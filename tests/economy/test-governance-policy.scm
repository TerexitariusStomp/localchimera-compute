;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/economy/test-governance-policy.scm — require-ratification closes the "any
;;; member can accept" gap, opt-in per scope.
;;;
;;; docs/localchimera.typ: "Plan acceptance is a production-governance act —
;;; weighted by labour-voice alone." accept-socialization/accept-
;;; reimbursement (and admit-commune/merge-with/split/rejoin-federation)
;;; accept an OPTIONAL 'ratification SAID; a bare gov-cap — self-mintable
;;; by any member — is enough unless a scope has opted into
;;; require-ratification (scope/policy.scm). This proves both
;;; halves: default-off leaves today's behaviour untouched, and opting in
;;; actually refuses an unratified accept while a correctly-ratified one
;;; still goes through.

(use-modules (localchimera test harness))
(use-modules (localchimera scope root))
(use-modules (localchimera credentials commitments) (localchimera credentials voting) (localchimera keri acdc) (localchimera boot scope) (localchimera economy socialization) (localchimera keri acdc) (localchimera keri acdc-store))
(use-modules (goblins) (goblins vat))
(use-modules ((localchimera scope live) #:select (scope-standard)))

(define vat (spawn-vat))

(define OWNER   "EOwner")
(define COMMUNE "ECommune")
(define FUTURE  "2099-01-01T00:00:00Z")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Commune"))
         (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                             #:scope-aid COMMUNE #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op")))

    ;; ── default: require-ratification unset, gov-cap alone is enough ──
    (let ((grant (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                             #:until FUTURE)))
      (check-pred "default policy: gov-cap alone accepts a grant"
                  (string? ($ scope 'accept-socialization gov (cred-said grant)))))

    ;; ── opt in: this commune now requires a passing ratification ──
    ($ scope 'set-governance-policy! gov '((require-ratification . #t)))

    (let ((grant2 (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 5
                                              #:until FUTURE)))
      (check-pred "opted-in policy: gov-cap alone is now refused"
                  (catch #t
                    (lambda () ($ scope 'accept-socialization gov (cred-said grant2)) #f)
                    (lambda _ #t)))

      ;; a ratification for the WRONG grant doesn't rescue it
      (let* ((wrong-rat (make-recomposition-ratification-credential
                         #:scope-aid COMMUNE
                         #:proposal-type 'accept-socialization
                         #:proposal-spec "not-this-grant"
                         #:ballot-said "E_snap_wrong"
                         #:tally '((accept . 5) (refuse . 0)))))
        ($ store 'issue wrong-rat)
        (check-pred "mismatched ratification is still refused"
                    (catch #t
                      (lambda () ($ scope 'accept-socialization gov (cred-said grant2)
                                    'ratification (cred-said wrong-rat))
                                 #f)
                      (lambda _ #t))))

      ;; the correctly-targeted ratification lets it through
      (let* ((rat (make-recomposition-ratification-credential
                   #:scope-aid COMMUNE
                   #:proposal-type 'accept-socialization
                   #:proposal-spec (cred-said grant2)
                   #:ballot-said "E_snap_ok"
                   #:tally '((accept . 5) (refuse . 0)))))
        ($ store 'issue rat)
        (check-pred "matching ratification: acceptance succeeds"
                    (string? ($ scope 'accept-socialization gov (cred-said grant2)
                                'ratification (cred-said rat))))))

    ;; ── the same policy gates accept-reimbursement too ──
    (let* ((claim (make-commitment-credential
                   #:provider-aid OWNER
                   #:receiver-aid COMMUNE
                   #:commitment-id "claim-1"
                   #:action 'transfer
                   #:resource-conforms-to "spec-eur"
                   #:resource-quantity '(20 . "EUR"))))
      ($ store 'issue claim)
      (check-pred "opted-in policy: accept-reimbursement without ratification refused"
                  (catch #t
                    (lambda () ($ scope 'accept-reimbursement gov (cred-said claim)) #f)
                    (lambda _ #t)))
      (let* ((rat (make-recomposition-ratification-credential
                   #:scope-aid COMMUNE
                   #:proposal-type 'accept-reimbursement
                   #:proposal-spec (cred-said claim)
                   #:ballot-said "E_snap_debt"
                   #:tally '((accept . 5) (refuse . 0)))))
        ($ store 'issue rat)
        (check-pred "matching ratification: accept-reimbursement succeeds"
                    (pair? ($ scope 'accept-reimbursement gov (cred-said claim)
                              'ratification (cred-said rat))))))))

(display "\n── the one registry of governed numbers ──\n")
;; every dial the engine reads at solve time has one default here, equal to
;; the engine's own, so a scope with no policy row solves as the engine does
(use-modules ((localchimera scope policy) #:select (*governed-dials* policy-dials governance-policy))
             ((localchimera solve engine) #:select (*pref-bound* want-as-cap?))
             ((localchimera solve solver) #:select (*kappa*)))
(check "the registry names the voice bound, β, ρ, κ, the cap shape, the draw weight and the ratified rest standard"
       (map car *governed-dials*) '(voice-tau pref-bound emp-rho kappa want-as-cap stock-draw-hours rest-standard))
(check "β's default is the engine's" (governance-policy #f 'pref-bound) *pref-bound*)
(check "κ's default is the solver's" (governance-policy #f 'kappa) *kappa*)
(check "the cap shape's default is the engine's" (governance-policy #f 'want-as-cap) (want-as-cap?))
(check "policy-dials hands every dial as a keyword, in registry order"
       (let loop ((d (policy-dials #f)) (acc '()))
         (if (null? d) (reverse acc) (loop (cddr d) (cons (car d) acc))))
       (map cdr *governed-dials*))
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Dials"))
         (scope (spawn-scope "Dials" #:kind 'commune #:scope-root-ref root
                             #:scope-aid "EDials" #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (ps    ($ root 'plan-store)))
    ($ scope 'set-governance-policy! gov '((kappa . 0.5) (voice-tau . 0.2)))
    (check "a set row binds the next read of every dial together"
           (let ((d (policy-dials ps)))
             (list (cadr (memq #:kappa d)) (cadr (memq #:voice-tau d)) (cadr (memq #:emp-rho d))))
           '(0.5 0.2 0.05))))

;; the STANDARD the floors are held to is a governed number too: a scope's own
;; ratified word, 1 (bare physiology) until it states one, and only ever raising
(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Standard"))
         (scope (spawn-scope "Standard" #:kind 'commune #:scope-root-ref root
                             #:scope-aid "EStandard" #:acdc-store store))
         (gov   ($ scope 'mint-gov-cap "op"))
         (ps    ($ root 'plan-store)))
    (check "a scope that has ratified no standard holds its floors to 1"
           (scope-standard ps) 1)
    ($ scope 'set-governance-policy! gov '((standard . 1.3)))
    (check "a ratified standard binds the next read of the floors"
           (scope-standard ps) 1.3)
    ($ scope 'set-governance-policy! gov '((standard . 0.4)))
    (check "a standard below 1 reads as 1: the standard only raises"
           (scope-standard ps) 1)))

(display "\n")
(test-summary!)
