;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-debts.scm — economy/debts.scm's own surface: what the commons
;;; owes a member back for a purchase they fronted, minted through
;;; accept-reimbursement (see that module's header). This test mints debts
;;; directly with debt-commitment, the way accept-reimbursement does, and
;;; checks reading, pricing, and event-sourced partial/full settlement.
;;;
;;; Run: guile -L module -L tests tests/monero/test-debts.scm

(use-modules (localchimera test harness)
             (localchimera credentials commitments) (localchimera keri acdc) (localchimera economy debts) (localchimera keri acdc) (localchimera keri acdc-store)
             (localchimera scope root) (localchimera vf schemas) (srfi srfi-1)
             ((localchimera monero specs) #:select (bootstrap-monero-resource! bootstrap-external-asset!))
             (srfi srfi-1)
             (goblins) (goblins vat))

(define COMMUNE "ECommune") (define ALICE "EAlice")
(define FUTURE "2099-12-31T00:00:00Z")

(define vat (spawn-vat #:name "debts"))

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (root  (spawn-scope-root "Debts"))
         (obs   ($ root 'observer))
         (rs    ($ root 'recipe-store)))
    ;; the commons' one price for money: XMR at 20 h, EUR at 0.02 h — so
    ;; 1 EUR = 0.001 XMR, the same ratio request-payout/settle-payout use.
    (bootstrap-monero-resource! root)
    (bootstrap-external-asset! root #:spec-id "spec-eur" #:name "Euros" #:unit "EUR"
                               #:categories '("external/fiat") #:acquisition-hours 0.02)

    (display "\n── minting: the shape every debt takes ──\n")
    (let ((d (debt-commitment COMMUNE ALICE "debt:a:1" "spec-eur" 100 "EUR" FUTURE)))
      (check-pred "a commitment-credential, commune issues, member holds"
                  (and (equal? *schema-localchimera-commitment* (cred-schema d))
                       (equal? COMMUNE (cred-issuer d)) (equal? ALICE (cred-holder d))))
      (check-pred "action transfer — equivalent value, no object to hand back"
                  (eq? 'transfer (cred-claim d 'action)))
      ($ store 'issue-idempotent d))

    (display "\n── reading: open-debts, whoever minted it ──\n")
    (let ((d2 (debt-commitment COMMUNE ALICE "debt:a:2" "spec-eur" 50 "EUR" FUTURE)))
      ($ store 'issue-idempotent d2))
    (check "two open debts, both alice's" (length (open-debts store COMMUNE ALICE)) 2)
    (check "a stranger has none" (length (open-debts store COMMUNE "EBob")) 0)
    (check-pred "nothing paid yet: remaining = face amount"
           (< (abs (- 150 (fold + 0 (map (lambda (k) (debt-remaining obs k)) (open-debts store COMMUNE ALICE))))) 1e-9))

    (display "\n── pricing: debts-owed-in-xmr at the acquisition-SNLT ratio ──\n")
    (check-pred "€150 owed = 0.15 XMR" (< (abs (- 0.15 (debts-owed-in-xmr rs obs store COMMUNE ALICE))) 1e-9))
    (let ((unpriced (debt-commitment COMMUNE ALICE "debt:a:unpriced" "spec-nope" 10 "spec-nope" FUTURE)))
      ($ store 'issue-idempotent unpriced)
      (check-pred "a spec with no acquisition recipe is owed but not priced — skipped, not crashed"
             (< (abs (- 0.15 (debts-owed-in-xmr rs obs store COMMUNE ALICE))) 1e-9))
      ($ store 'revoke (cred-said unpriced)))

    (display "\n── settlement: event-sourced, oldest-first, partial then full ──\n")
    ;; 0.03 XMR = €30 — less than the first debt (€100), so it alone absorbs it
    (let ((left (settle-debts! rs obs store COMMUNE ALICE 0.03 #:stamp "2026-08-21T00:00:00Z")))
      (check "nothing left over: the first debt covers it" left 0.0))
    (check "still two open debts — the first is PARTIALLY paid, not revoked"
           (length (open-debts store COMMUNE ALICE)) 2)
    (check-pred "€70 remains on the first, €50 untouched on the second"
           (< (abs (- 120 (fold + 0 (map (lambda (k) (debt-remaining obs k)) (open-debts store COMMUNE ALICE))))) 1e-9))

    ;; pay the rest: €120 = 0.12 XMR, with €0.05 XMR (=€50) left over for the claim
    (let ((left (settle-debts! rs obs store COMMUNE ALICE 0.17 #:stamp "2026-08-21T00:05:00Z")))
      (check "€120 settles both debts fully; 0.05 XMR (€50) left for the claim"
             (< (abs (- left 0.05)) 1e-9)))
    (check "both debts revoked — fully paid" (length (open-debts store COMMUNE ALICE)) 0)

    (display "\n── a payment counts once, by the link it states or by the id it was recorded under ──\n")
    (let* ((d4 (debt-commitment COMMUNE ALICE "debt:a:link" "spec-eur" 40 "EUR" FUTURE))
           (said (cred-said d4))
           (pay (lambda (id settles)
                  ($ obs 'record-event
                     (make-economic-event #:id id #:action 'transfer #:resource-conforms-to "spec-eur"
                                          #:provider COMMUNE #:receiver ALICE
                                          #:resource-quantity (make-measure 10 "EUR")
                                          #:has-point-in-time "2026-08-21T01:00:00Z" #:settles settles)))))
      ($ store 'issue-idempotent d4)
      (pay (string-append "debt-paid:" said ":linked") said)   ; states the debt it settles
      (pay (string-append "debt-paid:" said ":old") #f)         ; recorded before payments stated one
      (check-pred "40 less a linked 10 and a legacy 10 is 20, each counted once"
                  (< (abs (- 20 (debt-remaining obs d4))) 1e-9))
      ($ store 'revoke said))
    (check "nothing left to price" (debts-owed-in-xmr rs obs store COMMUNE ALICE) 0.0)

    (display "\n── open-debts-alist: the injectable read my-payouts wants ──\n")
    (let ((d3 (debt-commitment COMMUNE ALICE "debt:a:3" "spec-eur" 20 "EUR" FUTURE)))
      ($ store 'issue-idempotent d3))
    (let ((row (car (open-debts-alist obs store COMMUNE ALICE))))
      (check-pred "id/spec/amount/unit/remaining/due all ride the alist"
                  (and (equal? "spec-eur" (assq-ref row 'spec))
                       (= 20 (assq-ref row 'amount)) (equal? "EUR" (assq-ref row 'unit))
                       (= 20 (assq-ref row 'remaining)) (equal? FUTURE (assq-ref row 'due)))))))

(test-summary!)
