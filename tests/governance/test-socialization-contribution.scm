;;; test-socialization-contribution.scm — a lend may carry a flat share of the
;;; lent thing's running cost, as one more reciprocal clause of its agreement.
;;;
;;; docs/legal/structure.md §5: the commune bears utilities and upkeep of a
;;; lent thing as a fixed sum by period, never a price per use. accept-socialization
;;; (governance/scope.scm) takes 'contribution (money-spec amount unit due) and
;;; mints a money commitment beside the return commitment; the agreement
;;; credential stipulates both as reciprocal. Without it, nothing changes.
;;;
;;; Run: guile -L module tests/governance/test-socialization-contribution.scm

(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas)
             (playnet governance scope) (playnet governance socialization)
             (playnet credentials commitments) (playnet credentials custody)
             (playnet keri acdc) (playnet keri acdc-store)
             (goblins) (goblins vat) (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")
(define vat (spawn-vat))

(define (accept! contribution)
  "→ (values agreement return-commitment share-commitment-or-#f store)"
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (root  (spawn-scope-root "Commune"))
           (scope (spawn-scope "Commune" #:kind 'commune #:scope-root-ref root
                               #:scope-aid COMMUNE #:acdc-store store))
           (gov   ($ scope 'mint-gov-cap "op"))
           (grant (socialize-private-resource store OWNER COMMUNE "spec:cargo-bike" 4
                                              #:until FUTURE #:movable? #t))
           (agr-said (if contribution
                         ($ scope 'accept-socialization gov (cred-said grant) 'contribution contribution)
                         ($ scope 'accept-socialization gov (cred-said grant))))
           (by (lambda (s) (find (lambda (c) (equal? s (cred-said c))) ($ store 'all))))
           (agr (by agr-said))
           (recips (map by (cred-claim agr 'reciprocal-commitment-ids))))
      (values agr
              (find (lambda (c) (equal? "spec:cargo-bike" (cred-claim c 'resource-conforms-to))) recips)
              (find (lambda (c) (equal? "spec:eur" (cred-claim c 'resource-conforms-to))) recips)
              store))))

(display "\n── a lend with a flat contribution ──\n")
(define-values (agr ret share store) (accept! (list "spec:eur" 40 "EUR" FUTURE)))
(check-pred "the agreement stipulates two reciprocal clauses"
            (= 2 (length (cred-claim agr 'reciprocal-commitment-ids))))
(check-pred "the return of the thing is unchanged: transfer-custody, due at the window's end"
            (and ret (equal? "transfer-custody" (format #f "~a" (cred-claim ret 'action)))
                 (equal? FUTURE (cred-claim ret 'due))))
(check-pred "the share is a money transfer from the commune to the owner"
            (and share (equal? COMMUNE (cred-issuer share)) (equal? OWNER (cred-holder share))
                 (equal? "transfer" (format #f "~a" (cred-claim share 'action)))))
(check-pred "…of a fixed sum, due on a date, triggered by nothing"
            (and share (equal? FUTURE (cred-claim share 'due))
                 (not (cred-claim share 'triggered-by))
                 (let ((q (cred-claim share 'resource-quantity)))
                   (and q (= 40 (if (pair? q) (car q) (assq-ref q 'qty)))))))

(display "\n── a lend without one ──\n")
(define-values (agr2 ret2 share2 store2) (accept! #f))
(check-pred "one reciprocal clause, the return" (= 1 (length (cred-claim agr2 'reciprocal-commitment-ids))))
(check "no share is minted" share2 #f)

(test-summary!)
