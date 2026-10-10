;;; tests/planner/test-claim-means.scm — WHAT A PROCESS USES, NO PERSON CLAIMS.
;;;
;;; The verb decides the rail. A citizen may ask for "oven~ada" the way she asks
;;; for "bread~ada"; the bake `use`s the oven, so the oven is a means of
;;; production and no claim edge is built for it — the ask stays an unmet want,
;;; felt at zero, never a claim. Bread, which nothing uses, gets its edge. The
;;; published claimable set says the same: bread in, oven out, however tagged.
;;; Fixture: test-owned-delivery's, with an oven the bake uses and a stock of it.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-claim-means.scm
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules ((playnet vf facts rail) #:select (spec-claimable? claimable-specs spec-rail))
             ((playnet legal crossings) #:select (rail-channel))
             ((playnet vf formulas actions) #:select (relocating-actions)))
(use-modules (playnet test harness)
             (playnet algorithms custody) (playnet legal crossings) (playnet vf facts rail) (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (playnet governance socialization) (playnet keri acdc-store)
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
        (make-recipe-flow #:id "bu" #:action 'use #:resource-conforms-to "oven"
                          #:resource-quantity (make-measure 1.0 %count-unit) #:recipe-input-of "bake")   ; the bake USES the oven
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
(define resources
  (list (make-economic-resource #:id "sk-baker" #:conforms-to "skill-bake" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "baker")
        ;; an oven stands, and is even TAGGED for the rail — the tag is an ask, the verb answers
        (make-economic-resource #:id "oven-1" #:name "The oven" #:conforms-to "oven" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:current-location PLACE #:primary-accountable COMMUNE
          #:distribution-mode 'individual-claimable)
        ;; a stock of gold, TAGGED communal: nothing makes, consumes or uses it, so it is a
        ;; final good nobody's input — individual by the verbs, whatever the record says
        (make-economic-resource #:id "gold-1" #:name "Gold" #:conforms-to "gold" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable COMMUNE
          #:distribution-mode 'communal)))

(define vat (spawn-vat #:name "claim-means"))

(define r
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
           (ps  (spawn ^mock `((all-intents . ,(lambda () (list (need "ada" "bread" 20.0) (need "ada" "oven" 1.0))))
                               (all-commitments . ,(lambda () '())))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap)))))))
      (plan-commune-scope root store COMMUNE
        #:demand-scope scope #:periods '(0)
        #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) 100.0))
        #:backend 'native-c))))

(define claims (or (assq-ref r 'claims) '()))
(define (claimed-spec spec) (any (lambda (c) (equal? (assq-ref c 'conforms-to) spec)) claims))

(format #t "~%── ada asks for bread~~ada and oven~~ada; the bake uses the oven ──~%")
(format #t "  claims: ~s~%  claimable set: ~s~%" (map (lambda (c) (assq-ref c 'conforms-to)) claims) (claimable-specs))
(check "bread is claimed — a means of consumption gets its edge" (claimed-spec "bread") #t)
(check "the oven is never claimed — what a process uses, no person claims" (claimed-spec "oven") #f)
(check "bread is on the rail" (spec-claimable? "bread") #t)
(check "the oven is not, however it is tagged" (spec-claimable? "oven") #f)
;; the set is the goods the scope offers: a person's metabolism (the eat recipes'
;; by-products, their nutrient pools "nu|aid") and a held skill are no goods to claim
(check "no nutrient pool is claimable" (filter (lambda (sp) (string-contains sp "|")) (claimable-specs)) '())
(check "no metabolic by-product is claimable"
       (filter (lambda (sp) (member sp '("faeces" "co2" "urea" "ambient-heat" "h2o-g"))) (claimable-specs)) '())
(check "a held skill is not claimable" (spec-claimable? "skill-bake") #f)
;; the whole rail, as the plan published it — three words, each read off a verb
(format #t "  rails: bread ~s · wheat ~s · oven ~s~%" (spec-rail "bread") (spec-rail "wheat") (spec-rail "oven"))
(check "bread: a claim consumes it for someone — individual" (spec-rail "bread") 'individual)
(check "wheat: only the bake consumes it — communal" (spec-rail "wheat") 'communal)
(check "oven: the bake uses it — means" (spec-rail "oven") 'means)
;; …and the two readers that once read the declared field read this word instead
(check "the legal channel: a claimed good lands hand to hand" (rail-channel "bread") 'personal)
(check "a communal good lands nobody-to-nobody" (rail-channel "wheat") 'non-personal)
(check "a means implies no channel" (rail-channel "oven") #f)
(check "a stocked good nobody's input is individual, whatever its record says" (spec-rail "gold") 'individual)
(check "a spec nothing names carries no rail at all" (spec-rail "silver") #f)
;; ── rights move by construction, through the action table alone ──────────
;; A communal good stays the commune's because no custody verb can move rights:
;; the observer changes `primary-accountable` only where the action table says
;; `new` / `update-to` (or implies an all-rights transfer), and the box door
;; admits only the relocating verbs. The property, not a snapshot of the table.
(define (rights-moving? def)
  (or (memq (action-definition-accountable-effect def) '(new update-to))
      (eq? (action-definition-implies-transfer def) 'all-rights)))
(define rights-movers
  (sort (filter-map (lambda (p) (and (rights-moving? (cdr p)) (car p))) *action-definitions*)
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))
(check "the verbs that can move rights are the minting and transferring ones alone"
       rights-movers '(consume copy lower produce raise transfer transfer-all-rights))
(check "every custody verb leaves rights where they are"
       (every (lambda (a) (not (rights-moving? (get-action-def a))))
              (append relocating-actions '(accept modify transfer-custody)))
       #t)
(define (produced alist spec)
  (fold (lambda (m a) (if (and (eq? (assq-ref m 'action) 'produce) (equal? (assq-ref m 'conforms-to) spec))
                          (+ a (abs (or (assq-ref m 'quantity) 0))) a))
        0.0 (or (assq-ref alist 'material) '())))
(format #t "  bread~~ada ~,1f · oven~~ada ~,1f~%" (produced r "bread~ada") (produced r "oven~ada"))
;; The oven is a means: one of it, one bake per period, 10 kg. The people in the scope eat
;; first (each has an eat~bread process, the reproduction floor), so what the claim
;; delivers is the bake less what is eaten.
(define (eaten alist spec)
  (fold (lambda (m a)
          (if (and (eq? (assq-ref m 'action) 'consume) (equal? (assq-ref m 'conforms-to) spec)
                   (string-prefix? "eat~" (or (assq-ref m 'input-of) "")))
              (+ a (abs (or (assq-ref m 'quantity) 0))) a))
        0.0 (or (assq-ref alist 'material) '())))
(check "ada is delivered her bread through the claim — one bake, the oven's capacity, 10 kg, less what is eaten"
       (< (abs (- (produced r "bread~ada") (- 10.0 (eaten r "bread")))) 0.3) #t)
(check "the bake is the oven's one: no more than 10 kg of bread is made"
       (<= (produced r "bread") 10.001) #t)
(check "what is eaten and what is claimed account for the whole bake"
       (< (abs (- (+ (eaten r "bread") (produced r "bread~ada")) (produced r "bread"))) 0.3) #t)
(check "no oven~ada is ever produced — the ask is an unmet want, never a claim" (= 0.0 (produced r "oven~ada")) #t)

(display "\n")
(test-summary!)
