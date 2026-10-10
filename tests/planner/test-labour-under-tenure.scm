;;; test-labour-under-tenure.scm — tenure governs what can be TAKEN; labour
;;; cannot be taken, so a person's skill enters the commune's solve as their
;;; own capacity, while their bike stays out until lent.
;;;
;;; The regression this guards (2026-08-22): commune-resource-view's tenure
;;; rule — commune-owned, commune-custodied, or unattributed — was the
;;; INVENTORY filter copied onto the SOLVE's view, and the engine defines a
;;; person's skills as exactly the resources they are accountable for
;;; (vf-agent-skills). Under that rule no citizen's labour entered prod's
;;; socialized solve: met 0, nobody could work, and no suite exercised a
;;; declared skill through socialized-plan-fn. Now the recipes say what
;;; labour is (labour-specs-of: every spec a `work` flow conforms to), and
;;; the view lets it through tenure; consent for labour is the accept.
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope))
(use-modules (playnet test harness)
             (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner doors service)          ; ^planner-service
             (playnet governance socialization) (playnet keri acdc-store)               ; socialize-private-resource, socialized-plan-fn
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define OWNER   "EAlice")
(define COMMUNE "ECommune")
(define FUTURE  "2099-12-31T00:00:00Z")

;; bake needs skill-bake hours AND a bike's use (the means that needs lending)
(define procs (list (make-recipe-process #:id "bake" #:name "Bake")))
(define flows
  (list (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill-bake"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bu" #:action 'use #:resource-conforms-to "bike"
                          #:resource-quantity (make-measure 1.0 %count-unit)
                          #:effort-quantity (make-measure 0.1 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))
;; A period here is a WEEK: Alice's 09:00–17:00 every day is 56 h of baking, the
;; labour this fixture was sized on, and the same on any date.
(use-modules ((playnet planner solve engine) #:select (set-period-length!)))
(set-period-length! 1.0 "week")
(define win (all-week-window "09:00" "17:00"))
(define agents (list (make-agent #:id OWNER #:type 'person #:name "Alice" #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
;; the skill EXACTLY as declare-skill seeds it: accountable = the person
(define (skill) (make-economic-resource #:id (string-append "skill:" OWNER ":skill-bake") #:conforms-to "skill-bake" #:classified-as '()
                  #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:current-location "town" #:primary-accountable OWNER))
;; her bike, a private MEANS: accountable = the person, no custodian
(define (bike) (make-economic-resource #:id "res:bike" #:conforms-to "bike" #:classified-as '()
                                       #:onhand-quantity (make-measure 1 %count-unit)
                                       #:current-location "town" #:primary-accountable OWNER))
(define vat (spawn-vat #:name "labour-under-tenure"))

(define (run lend-bike?)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (_ (when lend-bike? (socialize-private-resource store OWNER COMMUNE "bike" 1 #:until FUTURE)))
           ;; the observer states what the fold nodes read at wiring (service.scm
           ;; scope-node-specs): holdings per agent for the labour pool, the
           ;; hours reads for the voice fold, and the listener the folds hang on
           (obs (spawn ^mock `((all-resources . ,(lambda () (list (skill) (bike)))) (record-event . ,(lambda (e) "ok"))
                               (skills-of . ,(lambda (aid) (filter (lambda (r) (equal? (economic-resource-primary-accountable r) aid)) (list (skill) (bike)))))
                               (add-event-listener . ,(lambda (f) #t))
                               (hours-by . ,(lambda (key-of . _) '()))
                               (hours-on . ,(lambda (part . _) 0))
                               ;; the reading fold's own gate (observer.scm fold-by): no events
                               ;; here to fold, so no cells — the reading pool wires clean
                               (fold-by . ,(lambda (actions key-of value-of combine) '()))
                               ;; cache-solve!'s claim-commitment reconciliation (service.scm):
                               ;; no claims stand here, so nothing is open
                               (open-fulfillments . ,(lambda () '())))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)) (set-on-agent . ,(lambda (f) #t)))))
           (acct (spawn ^mock `((credit-cells . ,(lambda () '())) (add-change-listener . ,(lambda (f) #t)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes)) (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid) (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid) (equal? (recipe-flow-recipe-output-of f) pid))) flows) '()))))))
           (ps  (spawn ^mock `((all-meta . ,(lambda () '())) (all-commitments . ,(lambda () '())) (all-intents . ,(lambda () '()))
                               (add-intent-listener . ,(lambda (f) #t)) (set-fresh-check . ,(lambda (f) #t)))))
           (root (spawn ^mock `((name . ,(lambda () COMMUNE)) (observer . ,(lambda () obs)) (agent-store . ,(lambda () as))
                                (spatial-thing-store . ,(lambda () sts)) (recipe-store . ,(lambda () rs)) (plan-store . ,(lambda () ps))
                                (account-store . ,(lambda () acct)))))
           (svc (spawn ^planner-service (hashmap-set (hashmap) COMMUNE root) plain-plan-fn #f (socialized-readers store)))
           (res ($ svc 'plan COMMUNE (list (list "bread" "town" 0 20.0)))))
      (cdr res))))

(display "\n── labour passes tenure; a means waits for its lend ──\n")
(define unlent (run #f))
(define lent   (run #t))
(check "the view names labour off the recipes: skill-bake is a work spec"
       (equal? '("skill-bake")
               (with-vat vat (labour-specs-of
                              (spawn ^mock `((recipe-store . ,(lambda ()
                                               (spawn ^mock `((all-recipes . ,(lambda () recipes))
                                                              (get-process-chain . ,(lambda (rid) procs))
                                                              (flows-for-process . ,(lambda (pid) (cons flows '())))))))))))))
(check "her bike unlent: tenure keeps the means out, so bake cannot run — met 0"
       (< (or (assq-ref unlent 'met) 0) 0.01))
(check "her bike lent: the means enters by consent, her labour by right — bread is baked"
       (> (or (assq-ref lent 'met) 0) 0.9))
(check "…and the baker is her: the work row names the skill's holder"
       (any (lambda (w) (equal? OWNER (assq-ref w 'provider))) (or (assq-ref lent 'work) '())))

(test-summary!)
