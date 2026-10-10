;;; tests/planner/test-rail-per-scope.scm — one commune's rail is never another's.
;;;
;;; *spec-rail*/*social-portion* used to be one table for the whole process:
;;; whichever commune solved most recently decided, for EVERY commune, whether
;;; a shared spec id is a means of production (never individually claimable) or
;;; a means of consumption (claimable). Commune A's bike is a MEANS — her own
;;; recipe `use`s it, nobody's claim consumes it (test-claim-means.scm's own
;;; oven, renamed). Commune B, sharing the same bare spec id for something of
;;; its own, assembles and stocks a "bike" that nothing of hers uses or
;;; consumes — a final good, nobody's input, so her OWN rail (rails-of's
;;; `else` branch) calls it INDIVIDUAL. Before this fix, B solving after A
;;; flipped A's own protected means-of-production to claimable everywhere in
;;; the process (reproduced live in conversation, not committed here). Now
;;; each commune's rail is read through its own recipe-store, and cannot be
;;; another's no matter which solved last.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-rail-per-scope.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules ((playnet vf facts rail) #:select (spec-claimable? spec-rail))
             ((playnet observation account) #:select (resource-individually-claimable?)))
(use-modules (playnet test harness)
             (playnet vf facts rail) (playnet vf schemas)
             (playnet scope live)
             (playnet governance socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define PLACE "town")
(define* (need aid spec qty #:optional (loc PLACE))
  (make-intent #:id (string-append "need:" aid ":" spec) #:action 'consume #:name spec #:resource-conforms-to spec
               #:resource-quantity (make-measure qty "kg") #:receiver aid #:at-location loc #:in-scope-of '()))
(define win (all-week-window "00:00" "23:59"))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))

;; ── Commune A: her bike is a MEANS — a process USES it, nobody claims it ──
(define a-procs (list (make-recipe-process #:id "ride" #:name "Ride")))
(define a-flows
  (list (make-recipe-flow #:id "rw" #:action 'work #:resource-conforms-to "skill-ride"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "ride")
        (make-recipe-flow #:id "ri" #:action 'consume #:resource-conforms-to "fuel"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "ride")
        (make-recipe-flow #:id "ru" #:action 'use #:resource-conforms-to "bike"
                          #:resource-quantity (make-measure 1.0 %count-unit) #:recipe-input-of "ride")   ; the ride USES the bike
        (make-recipe-flow #:id "ro" #:action 'produce #:resource-conforms-to "distance"
                          #:resource-quantity (make-measure 10.0 "km") #:recipe-output-of "ride"
                          #:is-primary #t)))
(define a-recipes (list (make-recipe #:id "ride-recipe" #:name "Ride" #:primary-output "distance"
                                     #:recipe-processes (list "ride"))))
(define a-agents (list (make-agent #:id "cy" #:type 'person #:name "Cy" #:primary-location PLACE
                                   #:classified-as '() #:availability-window win)))
(define a-resources
  (list (make-economic-resource #:id "sk-cy" #:conforms-to "skill-ride" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "cy")
        (make-economic-resource #:id "bike-A" #:name "A's bike" #:conforms-to "bike" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:current-location PLACE #:primary-accountable "COMMUNE-A")))

;; ── Commune B: her OWN "bike" is a final good — assembled, nothing of hers
;;    uses or consumes it further, so her OWN rail calls it INDIVIDUAL ──
(define b-procs (list (make-recipe-process #:id "assemble" #:name "Assemble")))
(define b-flows
  (list (make-recipe-flow #:id "aw" #:action 'work #:resource-conforms-to "skill-assemble"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "assemble")
        (make-recipe-flow #:id "ai" #:action 'consume #:resource-conforms-to "parts"
                          #:resource-quantity (make-measure 1.0 %count-unit) #:recipe-input-of "assemble")
        (make-recipe-flow #:id "ao" #:action 'produce #:resource-conforms-to "bike"
                          #:resource-quantity (make-measure 1.0 %count-unit)
                          #:recipe-output-of "assemble" #:is-primary #t)))
(define b-recipes (list (make-recipe #:id "assemble-recipe" #:name "Assemble"
                                     #:primary-output "bike" #:recipe-processes (list "assemble"))))
(define b-agents (list (make-agent #:id "bo" #:type 'person #:name "Bo" #:primary-location PLACE
                                   #:classified-as '() #:availability-window win)))
(define b-resources
  (list (make-economic-resource #:id "sk-bo" #:conforms-to "skill-assemble" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "bo")))

(define (solve-commune commune procs flows recipes agents resources intents)
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
         (ps  (spawn ^mock `((all-intents . ,(lambda () intents)) (all-commitments . ,(lambda () '())))))
         (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
         (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap)))))))
    (plan-commune-scope root store commune
      #:demand-scope scope #:periods '(0) #:eco-caps '() #:backend 'native-c)
    rs))

(define vat (spawn-vat #:name "rail-per-scope"))

(with-vat vat
  (let* ((rs-a (solve-commune "ECommuneA" a-procs a-flows a-recipes a-agents a-resources
                              (list (need "cy" "distance" 5.0))))
         (rs-b (solve-commune "ECommuneB" b-procs b-flows b-recipes b-agents b-resources '())))

    (display "\n── each commune solved; B last ──\n")
    (format #t "  A's own rail on \"bike\": ~s · B's own rail on \"bike\": ~s~%"
            (spec-rail "bike" rs-a) (spec-rail "bike" rs-b))

    (check "A's bike is a means (her own ride USES it) — through A's own store"
           (spec-rail "bike" rs-a) 'means)
    (check "B's bike is individual (a final good, nothing of hers touches it further)"
           (spec-rail "bike" rs-b) 'individual)

    (check "A's bike is NEVER individually claimable through A's own store — even though B, sharing the same bare spec id, solved after her and calls her own bike individual"
           (spec-claimable? "bike" rs-a) #f)
    (check "...and the account-store gate (the actual door a claim walks through) agrees"
           (resource-individually-claimable?
             (make-economic-resource #:id "bike-A" #:name "A's bike" #:conforms-to "bike" #:classified-as '()
               #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:current-location PLACE #:primary-accountable "COMMUNE-A")
             rs-a)
           #f)
    (check "B's bike IS individually claimable through B's own store"
           (spec-claimable? "bike" rs-b) #t)))

(display "\n")
(test-summary!)
