;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-festival.scm — real-time planning of a growing nomadic festival with
;;; free food distribution for thousands.
;;;
;;; The festival is a SCOPE that relocates each period; feeding attendees is
;;; internal provision (SHARE), and everyone-gets-fed is a HARD reproduction
;;; floor (#:repro-floors), not soft desire. "Multi-period" here is the honest
;;; real-time shape: a SEQUENCE of per-site solves (re-plan each site-day), the
;;; observer carrying custody between them.
;;;
;;;   Site A · jurisdiction X · 500 people · no gathering rule
;;;       → free food is licenceless; the reproduction floor feeds everyone.
;;;   Site B · jurisdiction Y · 2000 people (GROWN) · a Festival Gathering Permit
;;;       → without the permit the crowd cannot be legally fed (the serve column
;;;         is pruned); registering unlocks feeding thousands.
;;;
;;; Same dual-store pattern as test-food-distribution: real legal stores drive
;;; the decorate, mock productive stores drive the solve. Pure solver ⇒ no blake3.
;;;
;;; Run: guile -L module tests/scope/test-festival.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet scope spatial-things) (playnet observation observer) (playnet vf schemas) (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet legal registry-actor))
(use-modules (playnet legal gate)) (use-modules (playnet legal compliance))

(define (empty-rs)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define (held-permit id spec holder)
  (make-economic-resource #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert") #:primary-accountable holder #:state "active"))
(define win (all-week-window "00:00" "23:59"))
;; serving a meal at a mass gathering trips `mass-gathering` (tag on the produce
;; the crowd is fed). Cheap labour so one kitchen crew feeds thousands.
(define (seed-serve-recipe rs)   ; the REAL recipe, for the decorate's crossing derivation
  (for-each (lambda (s) ($ rs 'add-resource-spec s))
            (list (make-resource-specification #:id "produce" #:name "Produce"
                                               #:resource-classified-as '("food" "crossing:mass-gathering")
                                               #:default-unit-of-resource "kg")
                  (make-resource-specification #:id "meal" #:name "Meal"
                                               #:resource-classified-as '("food")
                                               #:default-unit-of-resource "meal")
                  (make-resource-specification #:id "cook" #:name "Cook"
                                               #:resource-classified-as '()
                                               #:default-unit-of-resource %effort-unit)))
  ($ rs 'add-recipe-process (make-recipe-process #:id "rp-serve" #:name "Serve Meal"
                                                 #:has-duration (make-duration 0.001 %effort-unit)))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "sv-in" #:action 'consume
                                           #:resource-conforms-to "produce"
                                           #:resource-quantity (make-measure 1.0 "kg")
                                           #:recipe-input-of "rp-serve"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "sv-cook" #:action 'work
                                           #:resource-conforms-to "cook"
                                           #:effort-quantity (make-measure 0.001 %effort-unit)
                                           #:recipe-input-of "rp-serve"))
  ($ rs 'add-recipe-flow (make-recipe-flow #:id "sv-out" #:action 'produce
                                           #:resource-conforms-to "meal"
                                           #:resource-quantity (make-measure 1.0 "meal")
                                           #:recipe-output-of "rp-serve" #:is-primary #t))
  ($ rs 'add-recipe (make-recipe #:id "recipe-serve" #:name "Serve Meal" #:primary-output "meal"
                                 #:recipe-processes (list "rp-serve"))))

;; the mock planner view of the same recipe (proc id matches: rp-serve)
(define serve-procs (list (make-recipe-process #:id "rp-serve" #:name "Serve")))
(define serve-flows
  (list (make-recipe-flow #:id "sv-out" #:action 'produce #:resource-conforms-to "meal"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of "rp-serve"
                          #:is-primary #t)
        (make-recipe-flow #:id "sv-in"  #:action 'consume #:resource-conforms-to "produce"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "rp-serve")
        (make-recipe-flow #:id "sv-cook" #:action 'work #:resource-conforms-to "cook"
                          #:effort-quantity (make-measure 0.001 %effort-unit)
                          #:recipe-input-of "rp-serve")))
(define serve-recipes (list (make-recipe #:id "recipe-serve" #:name "Serve" #:primary-output "meal"
                                         #:recipe-processes '() #:recipe-exchanges '())))
(define serve-specs (list (make-resource-specification #:id "cook" #:name "Cook"
                                                       #:resource-classified-as '()
                                                       #:default-unit-of-effort %effort-unit)))
(define (chain-for r) (if (equal? r "recipe-serve") serve-procs '()))

;; jurisdiction Y demands a gathering permit; X has no rule.
(define (gathering-rule)
  (rule (all-of (in-jurisdiction "juris-y") (on-crossing 'mass-gathering))
        (list (obtain #:rides 'entity #:name "Festival Gathering Permit" #:issuer "county-y"
                      #:per 'each-event #:spec '(safety sanitation crowd-control)))
        #:label "juris-y/mass-gathering" #:source "(worked example ordinance)"
        #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:festival"))

;; plan one site-day. The crowd's food need is modelled as demand = attendance
;; (fill = fraction fed); in production the attendees are person agents and
;; plan-scope's built-in reproduction (#:reproduce? #t) floors their nutrition
;; directly — the worst-off-protecting "everyone is fed" guarantee. We keep it
;; off here so the witness is the clean legal-gating fill.
(define (festival-at site juris attendance permit?)
  (define v (spawn-vat))
  (with-vat v
    (let* ((lrs  (empty-rs))
           (lsts (spawn ^spatial-thing-store (hashmap)))
           (reg  (spawn ^legal-registry (list (gathering-rule))))
           (cobs (spawn ^observer (empty-observer-state) '())))
      (seed-serve-recipe lrs)
      ($ lsts 'add-location (make-spatial-thing #:id "world"))
      ($ lsts 'add-location (make-spatial-thing #:id juris #:lat 40.0 #:long -74.0
                                                #:contained-in "world"))
      ($ lsts 'add-location (make-spatial-thing #:id site #:lat 40.0 #:long -74.0
                                                #:contained-in juris))
      (when permit?
        ($ cobs 'seed-resource (held-permit "res:gp" "Festival Gathering Permit" "scope:festival")))
      (let* ((dec (make-legal-decorate/observer
                   #:recipe-store lrs #:spatial-thing-store lsts #:registry reg #:observer cobs
                   #:act 'gathering #:as-of "2026-07-14" #:subject-at (lambda (p c) "scope:festival")))
             (resources (list (er "pr" "produce" "a" #:place site #:qty attendance)
                              (er "ck" "cook" "w-cook" #:place site #:qty 1.0)))
             (agents (list (make-agent #:id "w-cook" #:type 'person #:primary-location site
                                       #:classified-as '() #:availability-window win)))
             (spatials (list (make-spatial-thing #:id site #:lat 40.0 #:long -74.0)))
             (obs (spawn ^mock `((all-resources . ,(lambda () resources))
                                 (skill-hours-of . ,(lambda (a) '())) (record-event . ,(lambda (e) "ok")))))
             (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
             (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
             (rs (mock-recipe-store #:recipes serve-recipes #:specs serve-specs #:chain-of chain-for #:flows serve-flows))
             (scope (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
        (call-with-values
          (lambda () (plan-scope scope #:demand (list (cons (string-append "meal#" site "@0") attendance))
                                 #:reproduce? #f #:backend 'native-c #:legal-decorate dec))
          (lambda (i c m fill x n r) fill))))))

;; the festival's tour — three site-days re-planned in sequence.
(define fill-A       (festival-at "siteA" "juris-x" 500.0  #f))  ; free, licenceless — all fed
(define fill-B-noperm(festival-at "siteB" "juris-y" 2000.0 #f))  ; grown crowd, NO permit → gated
(define fill-B-perm  (festival-at "siteB" "juris-y" 2000.0 #t))  ; registered → thousands fed

(display "\n── Site A · jurisdiction X · 500 people · free food, licenceless ──\n")
(format #t "  fill: ~,3f\n" fill-A)
(check-pred "at site A the free-food need is met for all 500 (no permit tripped)" (> fill-A 0.95))

(display "\n── Site B · jurisdiction Y · 2000 people (grown) · gathering permit required ──\n")
(format #t "  fill  no permit: ~,3f   ·   registered: ~,3f\n" fill-B-noperm fill-B-perm)
(check-pred "without the gathering permit, the grown crowd cannot be legally fed" (< fill-B-noperm 0.05))
(check-pred "registering the festival unlocks feeding thousands at site B" (> fill-B-perm 0.95))
(check-pred "…and the festival grew 500 → 2000 fed across the move" (> fill-B-perm 0.95))
(check-pred "the permit is exactly what turned the crowd from unfed to fed"
            (and (< fill-B-noperm 0.05) (> fill-B-perm 0.95)))

(display "\n")
(test-summary!)
