;;; test-crossing-derivation.scm — a crossing is read off the records.
;;;
;;; The law is written on crossings. What trips one is a pattern in the
;;; ValueFlows records: an action, on a kind of thing, with or without something
;;; coming back, with custody and rights together or apart
;;; (legal/crossings.scm `*crossing-patterns*`). These properties hold the derivation
;;; to that: what the records say, no tag need say; what a tag says still
;;; stands; and a derived crossing reaches the law like any other.
;;;
;;; Run: guile -L module tests/planner/test-crossing-derivation.scm

(use-modules (playnet test harness) (playnet planner knowledge recipes store) (playnet planner knowledge recipes dwelling) (playnet planner knowledge recipes food-surplus) (playnet planner knowledge recipes household) (playnet planner scope spatial-things) (playnet planner legal crossings) (playnet planner observation observer) (playnet planner vf schemas) (playnet planner formulas actions) (srfi srfi-1)
             (playnet planner legal crossings) (playnet planner doors legal)
             ((playnet planner vf schemas) #:select (*action-definitions* action-definition-accountable-effect)) ((playnet planner formulas actions) #:select (*rights-moving-actions*))
             (playnet planner legal gate) (playnet planner legal registry-actor)
             (playnet planner knowledge law lint) (playnet planner knowledge dsl findings)
             (playnet planner knowledge recipes food-surplus)
             (playnet planner knowledge recipes compliance-food)
             (playnet planner knowledge recipes dwelling)
             (playnet planner knowledge recipes household)
             (playnet planner knowledge law way-recipes)
             ((playnet planner knowledge dsl vf-lint) #:select (lint-recipe-store))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))
(define (flow id action spec in out . clause)          ; a recipe flow, by what matters here
  (make-recipe-flow #:id id #:action action #:resource-conforms-to spec #:resource-quantity (make-measure 1 "each") #:recipe-input-of in #:recipe-output-of out
                    #:recipe-clause-of (and (pair? clause) (car clause))))
(define (spec id classes . money?)
  (make-resource-specification #:id id #:name id #:resource-classified-as classes #:default-unit-of-resource "each"
                               #:medium-of-exchange (and (pair? money?) (car money?))))
(define vat (spawn-vat))
(define-syntax-rule (in-vat body ...) (with-vat vat body ...))

;;; ─── the real recipes ────────────────────────────────────────────────────
(display "\n── what the knowledge recipes' own records say ──\n")
(define real
  (in-vat
    (let ((rs (empty-recipe-store)))
      (for-each (lambda (seed) (seed rs))
                (list seed-food-surplus-recipe seed-food-surplus-3step-recipe
                      seed-compliance-food-recipe seed-food-distribution-recipes
                      seed-dwelling-recipe seed-rent-recipe
                      seed-household-recipes))      ; the household's specs: the euro among them
      (let ((resolve (lambda (id) ($ rs 'get-resource-spec id)))
            (xflows  (lambda (id) ($ rs 'flows-for-exchange id))))
        (list
         (map (lambda (pid)
                (let ((flows (legal-proc-flows rs pid)))
                  (list pid
                        (process-crossings rs pid)
                        (recipe-crossings/derived flows resolve #:exchange-flows xflows)
                        (recipe-crossings/declared flows resolve))))
              (append-map (lambda (r) (map recipe-process-id ($ rs 'get-process-chain (recipe-id r))))
                          ($ rs 'all-recipes)))
         (crossing-sources rs))))))
(define rows (car real))
(define (row pid) (assoc pid rows))
(check-pred "there are processes to read" (> (length rows) 5))
(check-pred "what a tag declares still stands: derived ∪ declared holds every declared crossing"
            (every (lambda (r) (lset<= eq? (list-ref r 3) (list-ref r 1))) rows))
(check-pred "a process is the union of the two, and nothing else"
            (every (lambda (r) (lset= eq? (list-ref r 1) (lset-union eq? (list-ref r 2) (list-ref r 3))))
                   rows))
(check-pred "paying rent trips state-money, with no tag"
            (and (memq 'state-money (list-ref (row "rp-rent-shelter") 2))
                 (null? (list-ref (row "rp-rent-shelter") 3))))
(check-pred "a night's shelter in a dwelling trips occupancy, with no tag"
            (and (memq 'occupancy (list-ref (row "rp-shelter-night") 2)) #t))
(check-pred "a meal handed over with nothing coming back is shared food, with no tag"
            (and (memq 'share-food (list-ref (row "rp-fd-share") 2))
                 (null? (list-ref (row "rp-fd-share") 3))))
(check-pred "the same meal with money coming back is food sold, with no tag"
            (and (memq 'food-vending (list-ref (row "rp-fd-vend") 2))
                 (not (memq 'share-food (list-ref (row "rp-fd-vend") 2)))
                 (null? (list-ref (row "rp-fd-vend") 3))))
(check-pred "food received with nothing going back is recovered surplus, with no tag"
            (and (memq 'recover-surplus (list-ref (row "rp-cd-pickup") 2))
                 (null? (list-ref (row "rp-cd-pickup") 3))))
(check-pred "only the process that hands over shares: sorting in between trips nothing"
            (null? (list-ref (row "rp-cd-sort") 1)))

;;; ─── one graph, with and without something coming back ───────────────────
(display "\n── a sale is an exchange with money coming back ──\n")
(define (cook-store sold?)
  (let ((rs (empty-recipe-store)))
    ($ rs 'add-resource-spec (spec "s-veg" '("food")))
    ($ rs 'add-resource-spec (spec "s-meal" '("food")))
    ($ rs 'add-resource-spec (spec "s-coin" '() #t))
    ($ rs 'add-process-spec (make-process-specification #:id "ps-cook" #:name "Cook"))
    ($ rs 'add-recipe-process (make-recipe-process #:id "rp-cook" #:name "Cook" #:process-conforms-to "ps-cook"
                                                   #:has-duration (make-duration 1 "hours")))
    ($ rs 'add-recipe-flow (flow "f-in" 'consume "s-veg" "rp-cook" #f))
    (when sold?
      ($ rs 'add-recipe-exchange (make-recipe-exchange #:id "rx-meal" #:name "A meal for money"))
      ($ rs 'add-recipe-flow (flow "f-pay" 'transfer "s-coin" #f #f "rx-meal")))
    ($ rs 'add-recipe-flow (flow "f-out" 'produce "s-meal" #f "rp-cook" (and sold? "rx-meal")))
    ($ rs 'add-recipe (make-recipe #:id "r-cook" #:name "Cook" #:primary-output "s-meal" #:recipe-processes (list "rp-cook")
                                   #:recipe-exchanges (if sold? (list "rx-meal") #f)))
    rs))
(define (cook-crossings sold?)
  (in-vat
    (let ((rs (cook-store sold?)))
      (recipe-crossings (legal-proc-flows rs "rp-cook")
                        (lambda (id) ($ rs 'get-resource-spec id))
                        #:exchange-flows (lambda (id) ($ rs 'flows-for-exchange id))))))
(define given (cook-crossings #f))
(define sold  (cook-crossings #t))
(check-pred "the meal with nothing coming back is no sale"
            (and (not (memq 'public-sale given)) (not (memq 'food-vending given))))
(check-pred "the same meal, a clause of an exchange with money coming back, is a sale of food"
            (and (memq 'public-sale sold) (memq 'food-vending sold) #t))

;;; ─── a thing at the cell ─────────────────────────────────────────────────
(display "\n── custody and rights, together or apart ──\n")
(define purse-rule
  (rule (on-crossing 'hold-funds)
        (list (forbid #:reason "holding another's funds needs a licence"))
        #:label "test/hold-funds" #:confidence 'verified))
(define (purse-gate custodian accountable)
  (in-vat
    (let ((rs  (empty-recipe-store))
          (sts (spawn ^spatial-thing-store (hashmap)))
          (obs (spawn ^observer (empty-observer-state) '()))
          (reg (spawn ^legal-registry (list purse-rule))))
      ($ rs 'add-resource-spec (spec "s-coin" '() #t))
      ($ rs 'add-recipe-process (make-recipe-process #:id "rp-keep" #:name "Keep the purse"
                                                     #:has-duration (make-duration 1 "hours")))
      ($ rs 'add-recipe-flow (flow "f-keep" 'use "s-coin" "rp-keep" #f))
      ($ rs 'add-recipe (make-recipe #:id "r-keep" #:name "Keep" #:primary-output "s-coin"
                                     #:recipe-processes (list "rp-keep")))
      ($ sts 'add-location (make-spatial-thing #:id "town"))
      ($ obs 'seed-resource
         (make-economic-resource #:id "res-purse" #:name "purse" #:conforms-to "s-coin" #:classified-as '() #:current-location "town"
                                 #:primary-accountable accountable #:custodian-scope custodian))
      ((make-legal-gate #:recipe-store rs #:spatial-thing-store sts #:registry reg #:observer obs)
       "rp-keep" "town@0"))))
(check-pred "money one agent keeps and another has the rights to is funds held: the rule fires"
            (purse-gate "the-commune" "ada"))
(check-pred "money its own holder has the rights to trips nothing"
            (not (purse-gate "ada" "ada")))
(check "an asset says so itself"
       (asset-crossings (list '((conforms-to . "land") (classified-as . ())
                                (custodian-scope . "a") (primary-accountable . "a")))
                        (lambda (id) #f))
       '(own-property))

;;; ─── a derived crossing is a crossing ────────────────────────────────────
(display "\n── the law reads a derived crossing like any other ──\n")
(define here "derivation-test-place")
(place! here "Derivation test place" #f #:kind 'locality)
(define money-rule
  (rule (all-of (in-jurisdiction here) (on-crossing 'state-money))
        (list (tell #:name "Receipt kept" #:to "the tax office"))
        #:label "test/state-money" #:confidence 'reported))
(check "a rule on a crossing only the records yield is asked of the process"
       (stance-at here (list-ref (row "rp-rent-shelter") 1) #:act 'activity
                  #:rules (list money-rule))
       'notice)
(check-pred "every crossing a pattern yields is in the catalogue"
            (every known-crossing? (derivable-crossings)))
(check-pred "every crossing left declared says which fact the records lack"
            (every (lambda (r) (every crossing-lacks (list-ref r 3))) rows))

;;; ─── a way and its recipe ────────────────────────────────────────────────
(display "\n── a way trips what the recipe that is it trips ──\n")
(define all-modes (append-map activity-modes *activities*))
(check-pred "every way names the recipe that is it"
            (every (lambda (m) (member (assq-ref m 'recipe) (way-recipe-ids))) all-modes))
(check-pred "a way trips what its recipe trips, and hands on as its recipe does"
            (every (lambda (m)
                     (and (equal? (assq-ref m 'crossings) (way-recipe-crossings (assq-ref m 'recipe)))
                          (eq? (assq-ref m 'channel) (way-recipe-channel (assq-ref m 'recipe)))))
                   all-modes))
;; the recipes behind the ways are ValueFlows the planner could run
(define way-findings
  (in-vat (let ((rs (way-recipes-lint-store)))
            (list (lint-recipe-store rs #:specs-complete? #f)
                  (crossing-sources rs)))))
(check-pred "the ways' recipes pass the recipe lint with no error"
            (null? (filter (lambda (f) (eq? 'error (finding-severity f))) (car way-findings))))
(check-pred "what a way's recipe declares by tag, the records could not say: each names the missing fact"
            (every (lambda (f) (string-contains (finding-detail f) "the records lack"))
                   (filter (lambda (f) (eq? 'declared-crossing (finding-kind f))) (cadr way-findings))))
(check-pred "acquiring land is property, and is no sale"
            (let ((x (way-recipe-crossings "recipe-way-land-trust")))
              (and (memq 'own-property x) (not (memq 'public-sale x)))))

;;; ─── provenance ──────────────────────────────────────────────────────────
(display "\n── which crossings the records say, and which a tag says ──\n")
;; the whole catalogue: a crossing is read off the records, or its own row says
;; which fact the records lack
(check-pred "every crossing in the catalogue is derived, or says what the records lack"
            (every (lambda (c) (or (memq c (derivable-crossings)) (crossing-lacks c)))
                   (all-crossings)))
(check-pred "the sale pattern's actions are the ones the action table says move rights"
            (and (lset= eq? *rights-moving-actions* '(transfer transfer-all-rights))
                 (every (lambda (a)
                          (eq? 'update-to (action-definition-accountable-effect
                                           (assq-ref *action-definitions* a))))
                        *rights-moving-actions*)))
(define prov (cadr real))
(define (subjects kind) (map finding-subject (filter (lambda (f) (eq? kind (finding-kind f))) prov)))
(check-pred "the food recipes declare nothing: every crossing they trip, their records say"
            (null? (subjects 'declared-crossing)))
(check-pred "nothing these recipes trip is missing from the catalogue"
            (null? (subjects 'unregistered-crossing)))
(define restated
  (in-vat
    (let ((rs (empty-recipe-store)))
      ($ rs 'add-resource-spec (spec "s-coin" '("crossing:state-money" "crossing:made-up-word"
                                                "crossing:feed-in-public") #t))
      ($ rs 'add-recipe-process (make-recipe-process #:id "rp-pay" #:name "Pay"
                                                     #:has-duration (make-duration 1 "hours")))
      ($ rs 'add-recipe-flow (flow "f-pay" 'consume "s-coin" "rp-pay" #f))
      ($ rs 'add-recipe (make-recipe #:id "r-pay" #:name "Pay" #:primary-output "s-coin"
                                     #:recipe-processes (list "rp-pay")))
      (crossing-sources rs))))
(check-pred "a crossing only a tag can say is reported with the fact the records lack"
            (any (lambda (f) (and (eq? 'declared-crossing (finding-kind f))
                                  (eq? 'feed-in-public (finding-subject f))
                                  (string-contains (finding-detail f) "the records lack where it happens")))
                 restated))
(check-pred "a tag the records already say is reported as restated; an unknown word as unregistered"
            (and (any (lambda (f) (and (eq? 'restated-crossing (finding-kind f))
                                       (eq? 'state-money (finding-subject f))))
                      restated)
                 (any (lambda (f) (and (eq? 'unregistered-crossing (finding-kind f))
                                       (eq? 'warning (finding-severity f))
                                       (eq? 'made-up-word (finding-subject f))))
                      restated)))

(test-summary!)
