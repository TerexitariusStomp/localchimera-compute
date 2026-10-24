;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-accept-proposal.scm — proposal → agreement → commitments chain
;;;
;;; Exercises the fixed accept-proposal actor method:
;;;   - tail-position bcom actually updates plan-store state
;;;   - promoted commitments carry clause-of = agreement-id
;;;   - commitments-for-agreement filter resolves the set back
;;;   - reciprocal intents are promoted with counterparty flipped

(use-modules ((localchimera utils units) #:select (%count-unit)))
(use-modules (localchimera test harness)
             (localchimera scope root) (localchimera vf schemas)
             (goblins)
             (goblins utils hashmap)
             (srfi srfi-1))


(define vat (spawn-vat))

(with-vat vat

  (define scope (spawn-scope-root "accept-test"))
  (define ps    ($ scope 'plan-store))

  ;; ── Seed one primary intent (alice delivers bread) and one
  ;;    reciprocal intent (bob delivers coin), both with provider set,
  ;;    so promotion has complete agents without needing counterparty
  ;;    defaults.
  (define primary-id
    ($ ps 'add-intent
       (make-intent
         #:id "i-bread" #:action 'produce #:name "bread delivery" #:resource-conforms-to "spec-bread" #:resource-classified-as '()
         #:resource-quantity (make-measure 20 %count-unit)
         #:provider "alice"           ;; provider=alice, receiver open
 #:in-scope-of '("scope-A"))))

  (define reciprocal-id
    ($ ps 'add-intent
       (make-intent
         #:id "i-coin" #:action 'transfer #:name "coin payment" #:resource-conforms-to "spec-coin" #:resource-classified-as '()
         #:resource-quantity (make-measure 100 %count-unit)
         #:provider "bob"             ;; provider=bob, receiver open
 #:in-scope-of '("scope-A"))))

  (define prop-id
    ($ ps 'add-proposal
       (make-proposal
         #:id "p-exchange-1" #:name "Bread-for-coin exchange"
         #:purpose 'offer
         #:in-scope-of (list "scope-A")             ;; in-scope-of
         #:publishes (list primary-id)             ;; publishes (primary)
         #:reciprocal (list reciprocal-id)          ;; reciprocal
         #:proposed-to '())))                        ;; proposed-to (open)


  ;; ── Accept the proposal. Counterparty fills the open receiver
  ;;    slots on both the primary (bread → bob) and the reciprocal
  ;;    (coin → alice, flipped automatically).

  (define result
    ($ ps 'accept-proposal "p-exchange-1"
       '((provider . "alice") (receiver . "bob"))))

  (check-pred "accept-proposal returns an alist"
              (and (list? result) (pair? result)))

  (define agr-id  (assq-ref result 'agreement-id))
  (define all-cids (assq-ref result 'commitments))

  (check-pred "agreement-id is a string"
              (string? agr-id))
  (check-pred "two commitments returned (primary + reciprocal)"
              (= 2 (length all-cids)))


  ;; ── Agreement record exists in plan-store.

  (define agr ($ ps 'get-agreement agr-id))
  (check-pred "agreement record was stored"
              (and agr #t))
  (check-pred "agreement name = proposal name"
              (equal? "Bread-for-coin exchange" (agreement-name agr)))
  (check-pred "agreement stipulates one primary commitment"
              (= 1 (length (agreement-stipulates agr))))
  (check-pred "agreement stipulates-reciprocal one commitment"
              (= 1 (length (agreement-stipulates-reciprocal agr))))


  ;; ── Commitments are back-referenced to the agreement via clause-of.

  (for-each
    (lambda (cid)
      (let ((c ($ ps 'get-commitment cid)))
        (check-pred (string-append "commitment " cid " has clause-of = agreement")
                    (equal? agr-id (commitment-clause-of c)))
        (check-pred (string-append "commitment " cid " has satisfies = intent")
                    (member (commitment-satisfies c)
                            (list primary-id reciprocal-id)))))
    all-cids)


  ;; ── commitments-for-agreement resolves the set.

  (define cfa ($ ps 'commitments-for-agreement agr-id))
  (check-pred "commitments-for-agreement returns 2 entries"
              (= 2 (length cfa))))


;; ────────────────────────────────────────────────────────────────────

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
