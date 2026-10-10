;;; test-commune.scm — ^commune with 4-seal facets

(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (playnet observation states))
(use-modules (playnet utils endorsement))
(use-modules (playnet boot scope))
(use-modules (goblins) (goblins utils hashmap))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Spawn commune; mint authorities
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Spawn + mint authorities ──\n")

(define vat (spawn-vat))

(define commune
  (with-vat vat
    (let ((scope (spawn-scope-root "Watershed")))
      (spawn-commune "Watershed" scope))))

(with-vat vat
  (check-pred "commune name" (equal? "Watershed" ($ commune 'name)))

  (let ((gov-cap ($ commune 'mint-gov-cap "operator-1")))
    (check-pred "minted gov-cap is recognized" ($ commune 'gov-cap? gov-cap))
    (check-pred "minted gov-cap is NOT a planning-cap"
                (not ($ commune 'planning-cap? gov-cap)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. set-ccf gated by gov-authority
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. set-ccf gating ──\n")

(with-vat vat
  ;; Create an account in the wrapped scope first.
  (let ((as ($ ($ commune 'scope-root) 'account-store)))
    ($ as 'ensure-account "grandma"))

  (check-pred "set-ccf without gov-cap is rejected"
              (catch #t
                (lambda () ($ commune 'set-ccf #f "grandma" 0) #f)
                (lambda _ #t)))

  (let* ((gov-cap ($ commune 'mint-gov-cap "operator-1"))
         (planning-cap ($ commune 'mint-planning-cap "planner-1")))
    (check-pred "set-ccf with planning-cap rejected"
                (catch #t
                  (lambda () ($ commune 'set-ccf planning-cap "grandma" 0) #f)
                  (lambda _ #t)))

    (check-pred "set-ccf with gov-cap accepted"
                (catch #t
                  (lambda () ($ commune 'set-ccf gov-cap "grandma" 0) #t)
                  (lambda _ #f))))

  (let ((acct ($ ($ ($ commune 'scope-root) 'account-store)
                 'get-account "grandma")))
    (check "grandma CCF = 0 after set"
           (account-contribution-capacity-factor acct) 0)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. exclude-member then reinstate
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. exclude / reinstate ──\n")

(with-vat vat
  (let ((gov-cap ($ commune 'mint-gov-cap "operator-1")))
    ($ commune 'exclude-member gov-cap "grandma")
    (check-pred "grandma is excluded" ($ commune 'excluded-aid? "grandma"))
    ($ commune 'reinstate-member gov-cap "grandma")
    (check-pred "grandma is reinstated"
                (not ($ commune 'excluded-aid? "grandma")))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
