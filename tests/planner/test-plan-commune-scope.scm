;;; test-plan-commune-scope.scm — socialization auto-applied at the scope level.
;;;
;;; test-socialization-live wires a commune's live grants into the solve by hand:
;;; #:resource-view = the custodian projection, #:eco-caps = the socialized Svc|
;;; capacity. plan-commune-scope folds BOTH in automatically — one call, the grants
;;; read per-solve. This test drives the identical scenario (Alice's cross-scope
;;; bike, socialized into a commune that owns nothing) through the wrapper and
;;; confirms it lands the SAME bounded-by-the-grant result: lend 2 ⇒ ~2/5 met,
;;; lend 4 ⇒ ~4/5 — with no manual #:resource-view / #:eco-caps at the call site.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-plan-commune-scope.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

(define procs (list (make-recipe-process #:id "deliver" #:name "Deliver")))
(define flows
  (list (make-recipe-flow #:id "d-use" #:action 'use #:resource-conforms-to "bike" #:resource-quantity (make-measure 1.0 %count-unit) #:effort-quantity (make-measure 1.0 %effort-unit)
                          #:recipe-input-of "deliver")
        (make-recipe-flow #:id "d-out" #:action 'produce #:resource-conforms-to "delivered" #:resource-quantity (make-measure 1.0 "kg")
                          #:recipe-output-of "deliver" #:is-primary #t)))
(define recipes (list (make-recipe #:id "deliver-recipe" #:name "Deliver"
                                   #:primary-output "delivered" #:recipe-processes '()
                                   #:recipe-exchanges '())))

(define (bike)
  (make-economic-resource #:id "res:bike" #:conforms-to "bike" #:classified-as '()
                          #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
(define vat (spawn-vat #:name "plan-commune-scope"))

;; one AUTO solve for a grant of QTY, demand 5 parcels. The commune owns nothing;
;; Alice's bike is resolved cross-scope by the federation resolver — everything the
;; solve needs (visibility, custody, capacity) is derived inside plan-commune-scope.
(define (run qty)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when qty (socialize-private-resource store OWNER COMMUNE "bike" qty #:until FUTURE)))
           (obs (spawn ^mock `((all-resources . ,(lambda () '()))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () '())))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs))
           ;; the sibling commune that actually holds Alice's bike, reachable via federation.
           (m-obs   (spawn ^mock `((all-resources . ,(lambda () (list (bike)))))))
           (m-root  (mock-scope-root #:observer m-obs))
           (m-commA (spawn ^mock `((scope-root . ,(lambda () m-root)))))
           (fed     (spawn ^mock `((members . ,(lambda () (hashmap-set (hashmap) "commA" m-commA))))))
           (resolve (federation-resource-resolver fed))
           ;; THE ONE CALL — no #:resource-view, no #:eco-caps; the wrapper derives both.
           (result  (plan-commune-scope scope store COMMUNE
                      #:resolve resolve
                      #:demand '(("delivered#town@0" . 5.0))
                      #:backend 'native-c)))
      result)))

(define res-2  (run 2))
(define res-4  (run 4))
(define lent-2 (assq-ref res-2 'met))
(define lent-4 (assq-ref res-4 'met))

(display "\n── socialization auto-applied by plan-commune-scope (demand 5) ──\n")
(format #t "  lent 2 ⇒ demand met ~,2f   (≈ 2/5)~%" lent-2)
(format #t "  lent 4 ⇒ demand met ~,2f   (≈ 4/5)~%" lent-4)

(check "one call auto-applies custody + capacity: lent 2 ⇒ ~2/5"
       (and (> lent-2 0.35) (< lent-2 0.45)))
(check "lend more ⇒ more communal use, still bounded: lent 4 ⇒ ~4/5"
       (and (> lent-4 0.75) (< lent-4 0.85)))
(check "lending more raises delivered use (the grant sizes it, derived per-solve)"
       (> lent-4 lent-2))

;; the loaned-in bike is RENTED to the commune (custody=commune, rights=owner), so the
;; solve surfaces it for the fragility wheel's rented sector — the projection reaching
;; the read path, the piece the observer alone could not show.
(check "the socialized bike surfaces as a rented good (Svc|bike) for the wheel"
       (member "Svc|bike" (or (assq-ref res-2 'rented-goods) '())) '("Svc|bike"))

(test-summary!)
