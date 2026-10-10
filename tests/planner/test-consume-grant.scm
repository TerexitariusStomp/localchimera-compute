;;; test-consume-grant.scm — socializing MONEY: a consume-grant lends a quantity
;;; to be SPENT, and the commune's plan draws on exactly that much.
;;;
;;; Alice holds 100 EUR. She lends 10 of it into the commune with a CONSUME
;;; grant (kind 'consume on the same custody attestation a lent bike rides).
;;; The commune's recipe buys bread at 1 EUR each; twenty loaves are wanted.
;;; Ten are bought — the grant, not the purse, is the bound. No grant, no
;;; bread: her private purse is hers. And a consume grant is stock, never
;;; service: no Svc|spec-eur capacity appears.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-consume-grant.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

(define procs (list (make-recipe-process #:id "buy" #:name "Buy bread")))
(define flows
  (list (make-recipe-flow #:id "b-eur" #:action 'consume #:resource-conforms-to "spec-eur" #:resource-quantity (make-measure 1.0 "EUR")
                          #:recipe-input-of "buy")
        (make-recipe-flow #:id "b-out" #:action 'produce #:resource-conforms-to "bread" #:resource-quantity (make-measure 1.0 %count-unit)
                          #:recipe-output-of "buy" #:is-primary #t)))
(define recipes (list (make-recipe #:id "buy-recipe" #:name "Buy bread" #:primary-output "bread"
                                   #:recipe-processes '() #:recipe-exchanges '())))

(define (purse)
  (make-economic-resource #:id "res:purse" #:name "Alice's purse" #:conforms-to "spec-eur" #:classified-as '()
                          #:onhand-quantity (make-measure 100 "EUR") #:current-location "town" #:primary-accountable OWNER))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "consume-grant"))

(define (run qty kind)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER COMMUNE "spec-eur" qty
                                                    #:until FUTURE #:kind kind)))
           (obs (spawn ^mock `((all-resources . ,(lambda () (list (purse))))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (plan-commune-scope scope store COMMUNE
                          #:demand '(("bread#town@0" . 20.0))
                          #:never-raw '("spec-eur")
                          #:backend 'native-c))))

(define none    (run #f 'use))
(define lent-10 (run 10 'consume))
(define lent-15 (run 15 'consume))
(define as-use  (run 10 'use))

(define (met r) (assq-ref r 'met))
(display "\n── a consume-grant of EUR; 20 loaves wanted at 1 EUR each ──\n")
(format #t "  no grant        ⇒ met ~,2f~%" (met none))
(format #t "  lend 10 EUR     ⇒ met ~,2f   (≈ 10/20)~%" (met lent-10))
(format #t "  lend 15 EUR     ⇒ met ~,2f   (≈ 15/20)~%" (met lent-15))
(format #t "  lend 10 as USE  ⇒ met ~,2f   (a purse is not a service)~%" (met as-use))

(check "her private purse buys nothing for the commune until she lends it"
       (< (met none) 0.01))
(check "a consume-grant of 10 EUR buys 10 loaves — the grant bounds the draw, not the purse"
       (and (> (met lent-10) 0.45) (< (met lent-10) 0.55)))
(check "lend more ⇒ buy more, still bounded"
       (and (> (met lent-15) 0.70) (< (met lent-15) 0.80)))
(check "a USE grant over the purse lends its service, none of its substance: nothing is spent"
       (< (met as-use) 0.01))
(check "no Svc|spec-eur capacity: a consume grant is stock, never service"
       (not (member "Svc|spec-eur" (or (assq-ref lent-10 'rented-goods) '()))))
(check "the grant carries its kind as a claim"
       (with-vat vat
         (let* ((store (spawn-acdc-store))
                (c (socialize-private-resource store OWNER COMMUNE "spec-eur" 10
                                               #:until FUTURE #:kind 'consume)))
           (and (grant-consume? c) (equal? "consume" (cred-claim c 'kind))))))
(check "a use grant carries no kind claim — its SAID is the one it always had"
       (with-vat vat
         (let* ((store (spawn-acdc-store))
                (c (socialize-private-resource store OWNER COMMUNE "bike" 2 #:until FUTURE)))
           (and (not (grant-consume? c)) (not (cred-claim c 'kind))))))

(test-summary!)
