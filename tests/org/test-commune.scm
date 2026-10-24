;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-commune.scm — ^commune with 4-seal facets

(use-modules (localchimera test harness))
(use-modules (localchimera scope root) (localchimera vf schemas) (localchimera observation states))
(use-modules (localchimera utils endorsement))
(use-modules (localchimera boot scope) ((localchimera keri acdc-store) #:select (spawn-acdc-store)))
(use-modules (goblins) (goblins utils hashmap))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Spawn commune; mint authorities
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Spawn + mint authorities ──\n")

(define vat (spawn-vat))

(define commune
  (with-vat vat
    (let ((scope (spawn-scope-root "Watershed")))
      ;; the assessment IS a credential, so the commune carries a store
      (spawn-commune "Watershed" scope #:acdc-store (spawn-acdc-store)))))

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
  ;; grandma's factor is the commune's assessment credential, read by the
  ;; store through the standing the commune handed it; nothing is pre-stated

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
                 'ccf-of "grandma")))
    (check "grandma CCF = 0 after set" acct 0)))


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
