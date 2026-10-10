;;; tests/economy/test-claimed-stock.scm — WHAT A CITIZEN HOLDS ENTERS THE PLAN AS THEIR OWN.
;;;
;;; A loaf ada claimed sits in the scope's inventory under her accountability.
;;; The next plan ingests it as "bread~ada", so her want is met from it first and
;;; the plan claims only the remainder — the claim loop closes across plans, and
;;; a claimed good is never claimed twice. Fixture: test-owned-delivery's, plus
;;; five loaves ada already holds.
;;;
;;; Run:  guile -L module -L tests tests/economy/test-claimed-stock.scm
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define COMMUNE "ECommune")
(define PLACE   "town")
(define* (need aid spec qty #:optional (loc PLACE))
  (make-intent #:id (string-append "need:" aid ":" spec) #:action 'consume #:name spec #:resource-conforms-to spec
               #:resource-quantity (make-measure qty "kg") #:receiver aid #:at-location loc #:in-scope-of '()))

(define procs (list (make-recipe-process #:id "bake" #:name "Bake")))
(define flows
  (list (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill-bake"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "wheat"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "bake")
        (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes (list "bake"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
(define win (all-week-window "00:00" "23:59"))
(define agents (list (make-agent #:id "baker" #:type 'person #:name "Baker" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)))
(define skill-res
  (make-economic-resource #:id "sk-baker" #:conforms-to "skill-bake" #:classified-as '()
    #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "baker"))
(define held-loaves            ; five loaves ada claimed last plan: accountable to HER
  (make-economic-resource #:id "r-bread-ada" #:name "ada's bread" #:conforms-to "bread" #:classified-as '()
    #:accounting-quantity (make-measure 5.0 "kg") #:onhand-quantity (make-measure 5.0 "kg") #:current-location PLACE #:primary-accountable "ada"))

(define vat (spawn-vat #:name "claimed-stock"))

(define (run resources)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           (ps  (spawn ^mock `((all-intents . ,(lambda () (list (need "ada" "bread" 20.0))))
                               (all-commitments . ,(lambda () '())))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap)))))))
      (plan-commune-scope root store COMMUNE
        #:demand-scope scope #:periods '(0)
        #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) 100.0))
        #:backend 'native-c))))

(define (claimed alist aid spec)
  (fold (lambda (c a) (if (and (equal? (assq-ref c 'claimant) aid) (equal? (assq-ref c 'conforms-to) spec))
                          (+ a (assq-ref c 'quantity)) a))
        0.0 (or (assq-ref alist 'claims) '())))

(define without (run (list skill-res)))
(define with    (run (list skill-res held-loaves)))

(format #t "~%── ada wants 20 loaves ──~%")
(format #t "  holding none:  claims ~,1f~%" (claimed without "ada" "bread"))
(format #t "  holding five:  claims ~,1f~%" (claimed with "ada" "bread"))
(check "holding none, the plan claims her 20" (>= (claimed without "ada" "bread") 19.5) #t)
(check "holding five, the plan claims only the other 15 — her loaves are her own"
       (let ((q (claimed with "ada" "bread"))) (and (>= q 14.5) (<= q 15.5))) #t)

(display "\n")
(test-summary!)
