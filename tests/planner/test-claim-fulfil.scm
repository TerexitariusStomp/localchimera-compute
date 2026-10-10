;;; test-claim-fulfil.scm — a planned claim, confirmed: the plan's `claims` row
;;; becomes a transfer commitment, and each confirmation records the account
;;; store's claim event against it — custody moved, the certificate drawn, the
;;; commitment's FulfillmentState governing partials, `already` once finished.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-claim-fulfil.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet scope root) (playnet vf schemas) (playnet observation states) (srfi srfi-1))
(use-modules (playnet doors service))
(use-modules ((playnet observation account) #:select (declare-claimable!)))
(use-modules ((playnet test scope) #:select (plan-claim!)))   ; the plan's row, stood by the fixture
(use-modules (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1))

(declare-claimable! "spec-bread")   ; the fixture stands in for the plan: a claim recipe stands for bread

(define (work! obs aid skill hours eid iid)
  ($ obs 'register-intent
     (make-intent #:id iid #:action 'work #:resource-conforms-to skill
                  #:effort-quantity (make-measure hours %effort-unit) #:provider aid))
  ($ obs 'record-event
     (make-economic-event #:id eid #:action 'work #:resource-conforms-to skill #:provider aid
                          #:effort-quantity (make-measure hours %effort-unit)
                          #:has-point-in-time "2026-03-01T08:00:00Z" #:satisfies iid
                          #:in-scope-of '())))

(define vat (spawn-vat))
(define-values (svc-ref obs-ref)
  (with-vat vat
    (let* ((sr  (spawn-scope-root "Claim Scope"))
           (rs  ($ sr 'recipe-store))
           (obs ($ sr 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "s1" sr))))
      ($ rs 'add-recipe-process
         (make-recipe-process #:id "rp-bake" #:name "Bake" #:process-conforms-to "pspec-bake"
                              #:has-duration (make-duration 3 %effort-unit)))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-work" #:action 'work #:resource-conforms-to "spec-labor"
                           #:effort-quantity (make-measure 3 %effort-unit) #:recipe-input-of "rp-bake"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "rf-bake-out" #:action 'produce #:resource-conforms-to "spec-bread"
                           #:resource-quantity (make-measure 1 %count-unit) #:recipe-output-of "rp-bake"))
      ($ rs 'add-recipe (make-recipe #:id "recipe-bread" #:name "Bread"
                                     #:primary-output "spec-bread"
                                     #:recipe-processes (list "rp-bake")))
      (work! obs "alice" "spec-labor" 10 "ev1" "in1")            ; alice: 10 h gross
      ($ obs 'record-event
         (make-economic-event #:id "ev-bread" #:action 'produce #:resource-inventoried-as "r-bread" #:resource-conforms-to "spec-bread"
           #:resource-classified-as (list "individually-claimable") #:provider "commune" #:receiver "commune"
           #:resource-quantity (make-measure 10 %count-unit) #:has-point-in-time "2026-03-02T12:00:00Z"))
      (values svc obs))))

;; the plan said: alice claims 3 loaves at town — its row, registered as the
;; commitment each confirmation fulfils (service.scm plan-claims! does this on
;; a landed solve; the fixture stands it up)
(define cid (with-vat vat
              (plan-claim! obs-ref "spec-bread" "alice" 3 #:place "town" #:when-iso "2026-03-03T12:00:00Z")))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── the plan said: alice claims 3 loaves at town — she confirms 1 ──\n")
    (let ((r ($ svc 'record-claim "s1" "alice" "spec-bread" 1 3 "town" "2026-03-03T12:00:00Z")))
      (check "record-claim ok"                    (car r) 'ok)
      (check "it fulfils the plan's claim commitment" (assq-ref (cdr r) 'fulfills) cid)
      (check "the certificate drawn = 1 × 3 h"     (= 3 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance 10 − 3 = 7"                  (= 7 (assq-ref (cdr r) 'balance)) #t)
      (check "an event id came back"               (and (string? (assq-ref (cdr r) 'event-id))
                                                        (not (string-null? (assq-ref (cdr r) 'event-id)))) #t))

    (display "\n── she confirms the other 2 ──\n")
    (let ((r ($ svc 'record-claim "s1" "alice" "spec-bread" 2 3 "town" "2026-03-03T12:00:00Z")))
      (check "record-claim ok"                    (car r) 'ok)
      (check "drawn 2 × 3 = 6"                     (= 6 (assq-ref (cdr r) 'claimed)) #t)
      (check "balance 7 − 6 = 1"                   (= 1 (assq-ref (cdr r) 'balance)) #t))

    (display "\n── the commitment is finished: a third confirmation moves nothing ──\n")
    (let ((r ($ svc 'record-claim "s1" "alice" "spec-bread" 1 3 "town" "2026-03-03T12:00:00Z")))
      (check "ok, already"                         (and (eq? (car r) 'ok) (assq-ref (cdr r) 'already)) #t)
      (check "balance untouched"
             (= 1 (assq-ref (cdr ($ svc 'credit-balance "s1" "alice")) 'balance)) #t))))


;; ── a plan that restates a row (W9) ─────────────────────────────────────────
;; Each landed solve states its claim rows again. A row the plan restates moves
;; the commitment's target and leaves what was confirmed where the events have it;
;; a row the plan drops and later restates comes back with its confirmations.
(define (row spec who q place)
  `((conforms-to . ,spec) (claimant . ,who) (quantity . ,q) (at-location . ,place) (period . #f)))
(with-vat vat (work! obs-ref "alice" "spec-labor" 30 "ev-more" "in-more"))   ; credit for the rows below
(define (landed! . rows) (with-vat vat (plan-claims! "s1" `((claims . ,rows)))))
(define (confirm! q place)
  (with-vat vat ($ svc-ref 'record-claim "s1" "alice" "spec-bread" q 99 place #f)))
(define (remaining place)
  (with-vat vat
    (let ((fs (find (lambda (fs) (equal? (fulfillment-state-commitment-id fs) (string-append "claim|spec-bread|alice|" place "|")))
                    ($ obs-ref 'all-fulfillments))))
      (and fs (- (measure-has-numerical-value (fulfillment-state-total-committed fs))
                 (measure-has-numerical-value (fulfillment-state-total-fulfilled fs)))))))

(display "\n── the plan restates a row smaller than what was confirmed ──\n")
(landed! (row "spec-bread" "alice" 2 "mill"))
(check "alice confirms 1 of the 2"      (car (confirm! 1 "mill")) 'ok)
(landed! (row "spec-bread" "alice" 1 "mill"))
(check "the row says 1 and 1 is taken: nothing remains"  (= 0 (remaining "mill")) #t)
(let ((r (confirm! 1 "mill")))
  (check "one more moves nothing"
         (and (eq? (car r) 'ok) (assq-ref (cdr r) 'already)) #t))

(display "\n── the plan drops a row and states it again ──\n")
(landed! (row "spec-bread" "alice" 2 "quay"))
(check "alice confirms 1 of the 2"      (car (confirm! 1 "quay")) 'ok)
(landed! (row "spec-bread" "alice" 1 "mill"))       ; the quay row is gone from this plan
(check "a withdrawn row is not on the books"  (remaining "quay") #f)
(landed! (row "spec-bread" "alice" 2 "quay"))       ; …and back
(check "the confirmed 1 still counts: 1 remains of the 2"  (= 1 (remaining "quay")) #t)
(check "confirming 2 is refused, there is 1 to take"        (car (confirm! 2 "quay")) 'error)

(display "\n")
(test-summary!)
