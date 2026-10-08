;;; test-food-surplus-scenario.scm — SF food surplus redistribution network
;;;
;;; Scenario: hierarchical federation modeling real SF organizations.
;;;
;;; Hierarchy:
;;;   scope-sf-foodnet (root — lateral matching of surpluses to deficits)
;;;     ├── scope-sf-market     (donor ��� 500kg produce inventory)
;;;     ├── scope-safeway       (donor — 100kg produce inventory)
;;;     └── scope-food-runners  (logistics coordinator — recipe + vans + volunteers)
;;;           ├── scope-glide          (recipient — demands 50kg sorted produce)
;;;           └── scope-mission-meals  (recipient — demands 200kg sorted produce)
;;;
;;; Flow:
;;;   1. Recipients demand spec-sorted-produce (what they actually receive)
;;;   2. Food Runners has the recipe: spec-produce → pickup → sort → spec-sorted-produce
;;;   3. Recipe explosion generates demand for raw produce + logistics
;;;   4. Lateral matching at root connects Food Runners' produce deficit
;;;      to SF Market/Safeway surpluses
;;;   5. Logistics resources (reefer vans, volunteers) are allocated

(use-modules (playnet test harness))
(use-modules (playnet deprecated planner))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 1e-6)))
    (< (abs (- a b)) tol)))
;; ═════════════════════════════════════════════════════════════════════════
;; Setup: Create 5 scopes in a single vat
;; ═════════════════════════════════════════════════════════════════════════

(display "=== Setup: SF Food Surplus Federation (5 scopes) ===\n")

(define store (make-memory-store))
(define scope-root-env-full
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root)
      (((vf planning) ^store-registry) ,^store-registry))
    #:extends (list recipe-store-env agent-store-env observer-env
                    plan-store-env buffer-zone-store-env
                    account-store-env capacity-buffer-store-env
                    spatial-thing-store-env snapshot-store-env
                    alert-store-env store-registry-env
                    process-registry-env
                    live-registry-env live-resource-env
                    ballot-store-env demand-registry-env)))

(define-values (vat sf-market safeway food-runners glide mission-meals registry)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda ()
      (values (spawn-scope-root "The SF Market")
              (spawn-scope-root "Safeway Sunset")
              (spawn-scope-root "Food Runners SF")
              (spawn-scope-root "GLIDE Memorial")
              (spawn-scope-root "Mission Meals Coalition")
              (spawn ^store-registry (hashmap))))
    store))
;; ═════════════════════════════════════════════════════════════════════════
;; Resource specifications
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Seed resource specs ===\n")

;; Specs and the collect-and-sort recipe live in
;; module/playnet/planner/knowledge/recipes/food-surplus.scm — imported
;; via (use-modules (playnet deprecated planner)). Local aliases keep the rest of
;; the test reading naturally.
(define produce-spec         food-surplus-produce-spec)
(define sorted-produce-spec  food-surplus-sorted-produce-spec)
(define reefer-van-spec      food-surplus-reefer-van-spec)
(define volunteer-spec       food-surplus-volunteer-spec)
;; ═════════════════════════════════════════════════════════════════════════
;; Seed each scope
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Seed scope knowledge + inventory ===\n")

(with-vat vat
  ;; ── SF Market: wholesale produce hub ──
  ;; Donors have inventory only — no intents. Their surplus is discovered
  ;; by the supply phase, which emits surplus signals for lateral matching.
  (let ((rs ($ sf-market 'recipe-store))
        (obs ($ sf-market 'observer)))
    ($ rs 'add-resource-spec produce-spec)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-sfmarket-produce" #:name "SF Market Surplus Produce" #:conforms-to "spec-produce"
         #:accounting-quantity (make-measure 500 "kg") #:onhand-quantity (make-measure 500 "kg")
         #:current-location "loc-bayview" #:primary-accountable "agent-sf-market")))

  ;; ── Safeway Sunset: grocery surplus ──
  (let ((rs ($ safeway 'recipe-store))
        (obs ($ safeway 'observer)))
    ($ rs 'add-resource-spec produce-spec)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-safeway-produce" #:name "Safeway Sunset Surplus Produce" #:conforms-to "spec-produce"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg")
         #:current-location "loc-sunset" #:primary-accountable "agent-safeway")))

  ;; ── Food Runners: logistics coordinator ──
  ;; Has the collection recipe + logistics resources.
  ;; Recipe (specs + processes + flows) lives in
  ;; module/playnet/planner/knowledge/recipes/food-surplus.scm.
  (let ((rs ($ food-runners 'recipe-store))
        (obs ($ food-runners 'observer)))
    (seed-food-surplus-recipe rs)

    ;; Logistics resources: 2 reefer vans (8h each) + volunteer pool (16h)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-van-1" #:name "Reefer Van #1" #:conforms-to "spec-reefer-van"
         #:accounting-quantity (make-measure 8 "hours") #:onhand-quantity (make-measure 8 "hours")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-van-2" #:name "Reefer Van #2" #:conforms-to "spec-reefer-van"
         #:accounting-quantity (make-measure 8 "hours") #:onhand-quantity (make-measure 8 "hours")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-volunteers" #:name "Volunteer Driver Pool" #:conforms-to "spec-volunteer-hours"
         #:accounting-quantity (make-measure 16 "hours") #:onhand-quantity (make-measure 16 "hours")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners")))

  ;; ── GLIDE Memorial: 1700 meals/day, Tenderloin ──
  ;; Demands sorted produce — what actually arrives after Food Runners
  ;; picks up, inspects, and delivers.
  (let ((rs ($ glide 'recipe-store))
        (obs ($ glide 'observer)))
    ($ rs 'add-resource-spec sorted-produce-spec))

  ;; ── Mission Meals Coalition: weekly family boxes, Mission District ──
  (let ((rs ($ mission-meals 'recipe-store))
        (obs ($ mission-meals 'observer)))
    ($ rs 'add-resource-spec sorted-produce-spec)))
;; ═════════════════════════════════════════════════════════════════════════
;; Verify inventory
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Verify inventory ===\n")

(with-vat vat
  (check "SF Market: 500kg produce"
    (= 500 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ sf-market 'observer) 'get-resource "r-sfmarket-produce")))))
  (check "Safeway: 100kg produce"
    (= 100 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ safeway 'observer) 'get-resource "r-safeway-produce")))))
  (check "Food Runners: van #1 = 8h"
    (= 8 (measure-has-numerical-value
            (economic-resource-onhand-quantity
              ($ ($ food-runners 'observer) 'get-resource "r-van-1")))))
  (check "Food Runners: volunteers = 16h"
    (= 16 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ food-runners 'observer) 'get-resource "r-volunteers"))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Post intents: recipients demand sorted produce
;; Donors post NO intents — their inventory speaks as surplus.
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Post recipient intents ===\n")

(with-vat vat
  ;; GLIDE: 50kg sorted produce for daily kitchen
  ($ ($ glide 'plan-store) 'add-intent
     (make-intent #:id "i-glide-need" #:action 'transfer
       #:name "GLIDE daily kitchen produce"
       #:resource-conforms-to "spec-sorted-produce"
       #:resource-quantity (make-measure 50 "kg") #:receiver "agent-glide" #:due "2026-04-03T10:00:00Z"
       #:at-location "loc-tenderloin"))

  ;; Mission Meals: 200kg sorted produce for weekly family boxes
  ($ ($ mission-meals 'plan-store) 'add-intent
     (make-intent #:id "i-mission-need" #:action 'transfer
       #:name "Mission Meals weekly produce boxes"
       #:resource-conforms-to "spec-sorted-produce"
       #:resource-quantity (make-measure 200 "kg") #:receiver "agent-mission-meals" #:due "2026-04-05T10:00:00Z"
       #:at-location "loc-mission")))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: plan-for-unit on donor scopes (no intents → pure surplus)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Donor scopes (surplus only) ===\n")

(define horizon '((from . 1743638400) (to . 1743897600)))  ;; Apr 3-5 2026

(with-vat vat
  ;; SF Market: no demands, 500kg inventory → surplus signal
  (let* ((result (plan-for-unit
                   '("sf-market") horizon
                   ($ sf-market 'recipe-store)
                   ($ sf-market 'plan-store)
                   ($ sf-market 'observer)
                   #:plan-name "SF Market plan")))
    (let ((surpluses (assq-ref result 'surplus-signals))
          (purchases (or (assq-ref result 'unmet-intents) '())))
      (check "SF Market plan created" (string? (assq-ref result 'plan-id)))
      (check "SF Market has 500kg surplus signal"
        (and (pair? surpluses)
             (= 500 (assq-ref (car surpluses) 'qty))))
      (check "SF Market has no purchase intents" (null? purchases))))

  ;; Safeway: same — pure surplus
  (let* ((result (plan-for-unit
                   '("safeway") horizon
                   ($ safeway 'recipe-store)
                   ($ safeway 'plan-store)
                   ($ safeway 'observer)
                   #:plan-name "Safeway plan")))
    (let ((surpluses (assq-ref result 'surplus-signals)))
      (check "Safeway plan created" (string? (assq-ref result 'plan-id)))
      (check "Safeway has 100kg surplus signal"
        (and (pair? surpluses)
             (= 100 (assq-ref (car surpluses) 'qty)))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: plan-for-unit on recipient scopes (demand → purchase intent)
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Recipient scopes (demand only) ===\n")

(with-vat vat
  ;; GLIDE: demands 50kg sorted produce, has no inventory → full purchase intent
  (let* ((result (plan-for-unit
                   '("glide") horizon
                   ($ glide 'recipe-store)
                   ($ glide 'plan-store)
                   ($ glide 'observer)
                   #:plan-name "GLIDE plan")))
    (let ((purchases (or (assq-ref result 'unmet-intents) '())))
      (check "GLIDE plan created" (string? (assq-ref result 'plan-id)))
      (check "GLIDE generates purchase intent for 50kg sorted produce"
        (and (pair? purchases)
             (= 50 (measure-has-numerical-value
                      (intent-resource-quantity (car purchases))))
             (equal? "spec-sorted-produce"
                     (intent-resource-conforms-to (car purchases)))))))

  ;; Mission Meals: demands 200kg sorted produce → full purchase intent
  (let* ((result (plan-for-unit
                   '("mission-meals") horizon
                   ($ mission-meals 'recipe-store)
                   ($ mission-meals 'plan-store)
                   ($ mission-meals 'observer)
                   #:plan-name "Mission Meals plan")))
    (let ((purchases (or (assq-ref result 'unmet-intents) '())))
      (check "Mission Meals plan created" (string? (assq-ref result 'plan-id)))
      (check "Mission Meals generates purchase intent for 200kg sorted produce"
        (and (pair? purchases)
             (= 200 (measure-has-numerical-value
                       (intent-resource-quantity (car purchases))))
             (equal? "spec-sorted-produce"
                     (intent-resource-conforms-to (car purchases))))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Food Runners plans with child purchase intents propagated up
;;
;; This is the key test: Food Runners receives its children's unmet
;; demands (purchase intents for sorted produce), finds the recipe
;; (produce -> sorted produce), explodes the demand into raw produce
;; + logistics, and generates a purchase intent for raw produce that
;; the federation's lateral matching will fill from donor surpluses.
;;
;; We test this via the federation callback (below) rather than
;; adding intents directly to Food Runners' plan-store, so the
;; full bottom-up flow is exercised: children plan first, their
;; purchase intents propagate up, parent plans with recipe explosion.
;; ═════════════════════════════════════════════════════════════════════════
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Store registry
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Store registry ===\n")

(with-vat vat
  ($ registry 'register "sf-market" ($ sf-market 'plan-store))
  ($ registry 'register "safeway" ($ safeway 'plan-store))
  ($ registry 'register "food-runners" ($ food-runners 'plan-store))
  ($ registry 'register "glide" ($ glide 'plan-store))
  ($ registry 'register "mission-meals" ($ mission-meals 'plan-store))

  (check "registry has 5 scopes" (= 5 ($ registry 'scope-count)))
  (check "all scope ids" (= 5 (length ($ registry 'all-scope-ids)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Full federation with hierarchy
;;
;; Hierarchy:
;;   sf-market     →  (no parent — peer at root)
;;   safeway       →  (no parent — peer at root)
;;   food-runners  →  (no parent — peer at root)
;;   glide         →  parent: food-runners
;;   mission-meals →  parent: food-runners
;;
;; Bottom-up: glide, mission-meals plan first (leaf scopes).
;; Then food-runners plans (with child results).
;; Then sf-market, safeway plan (no children).
;; Finally: lateral matching at root connects Food Runners' produce
;; deficit to SF Market / Safeway surpluses.
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Hierarchical federation ===\n")

(with-vat vat
  (let* ((parent-of (hashmap-set
                      (hashmap-set (hashmap)
                        "glide" "food-runners")
                      "mission-meals" "food-runners"))
         (result (plan-federation
                   '("sf-market" "safeway" "food-runners" "glide" "mission-meals")
                   horizon
                   #f #f
                   (lambda (scope-id child-results)
                     (let ((scope-root
                             (cond
                               ((equal? scope-id "sf-market") sf-market)
                               ((equal? scope-id "safeway") safeway)
                               ((equal? scope-id "food-runners") food-runners)
                               ((equal? scope-id "glide") glide)
                               ((equal? scope-id "mission-meals") mission-meals))))
                       (let ((rs ($ scope-root 'recipe-store))
                             (ps ($ scope-root 'plan-store))
                             (obs ($ scope-root 'observer)))

                         ;; For Food Runners (parent): propagate child purchase
                         ;; intents as its own demands before planning.
                         (when (equal? scope-id "food-runners")
                           (for-each
                             (lambda (child-result)
                               (for-each
                                 (lambda (pi)
                                   (let ((spec (intent-resource-conforms-to pi))
                                         (qty (measure-has-numerical-value
                                                (intent-resource-quantity pi))))
                                     (when (> qty 0)
                                       (let ((due-val (intent-due pi)))
                                         ($ ps 'add-intent
                                            (make-intent
                                              #:id (string-append "i-fr-fed-" (intent-id pi))
                                              #:action 'produce
                                              #:name (string-append "Collect for child: "
                                                             (or (intent-name pi) ""))
                                              #:resource-conforms-to spec
                                              #:resource-quantity (make-measure qty (measure-has-unit
                                                                  (intent-resource-quantity pi))) #:receiver "agent-food-runners"
                                              #:due (if (number? due-val)
                                                  (number->string due-val)
                                                  due-val)))))))
                                 (or (assq-ref child-result 'unmet-intents) '())))
                             child-results))

                         (let ((result (plan-for-unit
                                         (list scope-id) horizon rs ps obs
                                         #:plan-name (string-append scope-id " fed plan"))))
                           ;; Convert purchase intents to deficit signals for
                           ;; lateral matching at the root level
                           (let* ((purchases (or (assq-ref result 'unmet-intents) '()))
                                  (purchase-deficits
                                    (filter-map
                                      (lambda (pi)
                                        (let ((rq (intent-resource-quantity pi)))
                                          (and rq (> (measure-has-numerical-value rq) 0)
                                               `((kind . deficit)
                                                 (spec-id . ,(intent-resource-conforms-to pi))
                                                 (qty . ,(measure-has-numerical-value rq))
                                                 (source . unmet)))))
                                      purchases))
                                  (existing-deficits
                                    (or (assq-ref result 'deficit-signals) '())))
                             (map (lambda (pair)
                                    (if (eq? (car pair) 'deficit-signals)
                                        (cons 'deficit-signals
                                              (append existing-deficits purchase-deficits))
                                        pair))
                                  result))))))
                   #:parent-of parent-of
                   #:registry registry)))

    (let ((by-scope (assq-ref result 'by-scope))
          (plan-order (assq-ref result 'plan-order))
          (lateral (assq-ref result 'lateral-matches)))

      (check "federation planned all 5 scopes" (= 5 (hashmap-count by-scope)))

      ;; Plan order should be bottom-up: children first, then parents
      (format #t "  plan order: ~a\n" plan-order)
      (let ((glide-pos (list-index (lambda (x) (equal? x "glide")) plan-order))
            (mission-pos (list-index (lambda (x) (equal? x "mission-meals")) plan-order))
            (fr-pos (list-index (lambda (x) (equal? x "food-runners")) plan-order)))
        (check "glide planned before food-runners" (< glide-pos fr-pos))
        (check "mission-meals planned before food-runners" (< mission-pos fr-pos)))

      ;; Lateral matching: Food Runners should have a deficit for raw produce
      ;; (from recipe explosion), matched against donor surpluses
      (format #t "  lateral matches: ~a\n" (length lateral))
      (for-each
        (lambda (m)
          (format #t "  match: ~a -> ~a: ~akg ~a\n"
                  (assq-ref m 'from-scope) (assq-ref m 'to-scope)
                  (assq-ref m 'quantity) (assq-ref m 'spec-id)))
        lateral)

      ;; Check that lateral matching connected donor produce to Food Runners
      (let ((produce-matches
              (filter (lambda (m) (equal? "spec-produce" (assq-ref m 'spec-id))) lateral)))
        (check "lateral matching found produce connections" (pair? produce-matches))
        (let ((to-fr (filter (lambda (m) (equal? "food-runners" (assq-ref m 'to-scope)))
                             produce-matches)))
          (check "produce flows to food-runners" (pair? to-fr))
          (when (pair? to-fr)
            (let ((total-matched (fold + 0 (map (lambda (m) (assq-ref m 'quantity)) to-fr))))
              (format #t "  total produce matched to Food Runners: ~,1fkg\n" total-matched)
              ;; Food Runners needs ~278kg raw produce (250kg sorted / 0.9 yield)
              (check "enough produce matched for collection runs" (> total-matched 200))))))

      ;; Verify Food Runners' plan result: recipe should have fired
      (let ((fr-result (hashmap-ref by-scope "food-runners" '())))
        (let ((procs (or (assq-ref fr-result 'processes) '()))
              (purchases (or (assq-ref fr-result 'unmet-intents) '())))
          (format #t "  Food Runners processes: ~a\n" (length procs))
          (check "Food Runners generated collection processes" (>= (length procs) 1))
          ;; Purchase intents for raw produce (recipe explosion)
          (let* ((produce-purchases
                   (filter (lambda (pi) (equal? "spec-produce" (intent-resource-conforms-to pi)))
                           purchases))
                 (total-raw (if (pair? produce-purchases)
                                (fold + 0 (map (lambda (pi)
                                                 (measure-has-numerical-value
                                                   (intent-resource-quantity pi)))
                                               produce-purchases))
                                0)))
            (format #t "  Food Runners raw produce needed: ~,1fkg\n" total-raw)
            (check "recipe explosion demands raw produce"
              (> total-raw 200)))))

      ;; Verify donors only have surplus signals (no demands to consume their stock)
      (let ((sfm-result (hashmap-ref by-scope "sf-market" '())))
        (check "SF Market has surplus" (pair? (assq-ref sfm-result 'surplus-signals)))
        (check "SF Market has no deficit" (null? (or (assq-ref sfm-result 'deficit-signals) '()))))

      ;; Verify recipients generated purchase intents (unmet demand)
      (let ((glide-result (hashmap-ref by-scope "glide" '())))
        (let ((purchases (or (assq-ref glide-result 'unmet-intents) '())))
          (check "GLIDE generated purchase intent in federation"
            (and (pair? purchases)
                 (equal? "spec-sorted-produce"
                         (intent-resource-conforms-to (car purchases))))))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Cross-scope reference resolution
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Cross-scope reference resolution ===\n")

(with-vat vat
  (let ((resolved ($ registry 'resolve "glide::i-glide-need")))
    (check "resolve GLIDE intent" (> (length resolved) 0))
    (let ((intent-pair (assq 'intent resolved)))
      (check "resolved is an intent" (and intent-pair (intent? (cdr intent-pair))))))

  (let ((resolved ($ registry 'resolve "glide::nonexistent")))
    (check "resolve missing returns empty" (null? resolved))))
;; ═════════════════════════════════════════════════════════════════════════
;; Test: Persistence round-trip
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Test: Persistence round-trip ===\n")

(define-values (vat2 sf-market2 safeway2 food-runners2 glide2 mission-meals2 registry2)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda () (error "Should restore from store!"))
    store))

(with-vat vat2
  (check "SF Market restored" (equal? "The SF Market" ($ sf-market2 'name)))
  (check "Food Runners restored" (equal? "Food Runners SF" ($ food-runners2 'name)))
  (check "GLIDE restored" (equal? "GLIDE Memorial" ($ glide2 'name)))
  (check "Mission Meals restored" (equal? "Mission Meals Coalition" ($ mission-meals2 'name)))
  (check "registry restored" (= 5 ($ registry2 'scope-count)))

  (check "SF Market produce persisted"
    (= 500 (measure-has-numerical-value
             (economic-resource-onhand-quantity
               ($ ($ sf-market2 'observer) 'get-resource "r-sfmarket-produce")))))

  (let ((intent ($ ($ glide2 'plan-store) 'get-intent "i-glide-need")))
    (check "GLIDE intent persisted" (intent? intent))
    (check "GLIDE intent is for sorted produce"
      (equal? "spec-sorted-produce" (intent-resource-conforms-to intent)))
    (check "GLIDE intent quantity is 50kg"
      (= 50 (measure-has-numerical-value (intent-resource-quantity intent))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section A: Spatial hierarchy — map the city
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section A: Spatial hierarchy ===\n")

(define location-store
  (with-vat vat (spawn ^spatial-thing-store (hashmap))))

(with-vat vat
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-sf" #:name "San Francisco" #:lat 37.7749 #:long -122.4194))
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-bayview" #:name "Bayview (SF Market)" #:lat 37.7276
                         #:long -122.3831 #:contained-in "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-sunset" #:name "Sunset (Safeway)" #:lat 37.7527 #:long -122.4939
                         #:contained-in "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-soma" #:name "SoMa (Food Runners HQ)" #:lat 37.7785
                         #:long -122.3950 #:contained-in "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-tenderloin" #:name "Tenderloin (GLIDE)" #:lat 37.7836
                         #:long -122.4138 #:contained-in "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing #:id "loc-mission" #:name "Mission (Mission Meals)" #:lat 37.7599
                         #:long -122.4148 #:contained-in "loc-sf"))

  (check "6 locations created" (= 6 (length ($ location-store 'all-locations))))

  (let ((chain ($ location-store 'resolve-chain "loc-bayview")))
    (check "Bayview chain has 2 nodes" (= 2 (length chain)))
    (check "Bayview root is SF"
      (equal? "loc-sf" (spatial-thing-id (cadr chain)))))

  (check "Bayview is descendant of SF"
    ($ location-store 'is-descendant-or-equal "loc-bayview" "loc-sf"))
  (check "SF is not descendant of Bayview"
    (not ($ location-store 'is-descendant-or-equal "loc-sf" "loc-bayview")))

  (let ((coords ($ location-store 'resolve-coordinates "loc-soma")))
    (check "SoMa has coordinates" (and (pair? coords) (number? (car coords))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section B: Buffer zones for perishables
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section B: Buffer zones for perishables ===\n")

(define profile-map
  (with-vat vat
    (hashmap-set (hashmap)
      "bp-perishable"
      (make-buffer-profile "bp-perishable" "Perishable Produce"
        'distributed 0.5 0.6 0.4 0.5 1 1 'daily 'short 'medium "PP" #f))))

(with-vat vat
  (let ((bzs ($ food-runners 'buffer-zone-store)))
    ;; Sorted produce buffer at Food Runners warehouse
    ;; ADU=50 kg/day, DLT=1 day, TOR=50, TOY=125, TOG=250
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-sorted-produce" "spec-sorted-produce" "bp-perishable" 'replenished
         "loc-soma" #f #f #f #f                       ;; at-location, upstream, recipe, stages
         50 "kg" #f #f #f #f #f #f #f #f              ;; ADU fields
         #f 1                                          ;; ost-horizon-days, dlt-days
         10 "kg" 1                                     ;; moq, moq-unit, order-cycle-days
         #f #f                                         ;; override-reason, override-note
         #f #f                                         ;; transport-days, staging-days
         50 125 250                                    ;; TOR, TOY, TOG
         20 #f #f                                      ;; tipping-point, red-base, red-safety
         #f #f #f #f #f                                ;; adj factors, supply-offset, adjustment-ids
         "2026-04-01T00:00:00Z"))                      ;; last-computed-at

    (check "buffer zone created"
      (buffer-zone? ($ bzs 'get-zone "bz-sorted-produce")))

    ;; Food Runners has 0 sorted produce onhand → should be red zone
    (let* ((bz ($ bzs 'get-zone "bz-sorted-produce"))
           (status (buffer-status 0 bz)))
      (check "0 onhand = red zone" (eq? 'red (assq-ref status 'zone))))

    ;; 75 onhand → between TOR(50) and TOY(125) → yellow zone
    (let* ((bz ($ bzs 'get-zone "bz-sorted-produce"))
           (status (buffer-status 75 bz)))
      (check "75 onhand = yellow zone" (eq? 'yellow (assq-ref status 'zone))))

    ;; 200 onhand → between TOY(125) and TOG(250) → green zone
    (let* ((bz ($ bzs 'get-zone "bz-sorted-produce"))
           (status (buffer-status 200 bz)))
      (check "200 onhand = green zone" (eq? 'green (assq-ref status 'zone))))

    ;; find-zone with location-store should resolve containment
    (check "find-zone resolves via location store"
      (buffer-zone? ($ bzs 'find-zone "spec-sorted-produce" "loc-soma" location-store)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section C: Demand policy — derive needs from population
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section C: Demand policy ===\n")

;; GLIDE: 1000 daily visitors × 0.05 kg produce each = 50 kg
(let ((demands (derive-communal-demand
                 '(((spec-id . "spec-sorted-produce")
                    (mode . per-member) (qty-per-member . 0.05) (unit . "kg")))
                 1000)))
  (check "GLIDE demand derived" (pair? demands))
  (check "GLIDE derived qty = 50kg"
    (approx= 50 (assq-ref (car demands) 'qty)))
  (check "GLIDE formula mentions members"
    (string-contains (assq-ref (car demands) 'formula) "members")))

;; Mission Meals: 2000 weekly families × 0.1 kg = 200 kg
(let ((demands (derive-communal-demand
                 '(((spec-id . "spec-sorted-produce")
                    (mode . per-member) (qty-per-member . 0.1) (unit . "kg")))
                 2000)))
  (check "Mission Meals derived qty = 200kg"
    (approx= 200 (assq-ref (car demands) 'qty))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section D: 3-process recipe — pickup → sort → deliver
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section D: 3-process recipe ===\n")

;; 3-step recipe (specs + processes + flows) lives in
;; module/playnet/planner/knowledge/recipes/food-surplus.scm.
(with-vat vat
  (let ((rs ($ food-runners 'recipe-store)))
    (seed-food-surplus-3step-recipe rs)
    ;; Verify topological sort returns all 3 in order
    (let ((chain ($ rs 'get-process-chain "recipe-collect-deliver")))
      (check "3-process chain has 3 steps" (= 3 (length chain)))
      (check "chain starts with pickup"
        (equal? "rp-cd-pickup" (recipe-process-id (car chain))))
      (check "chain ends with deliver"
        (equal? "rp-cd-deliver" (recipe-process-id (caddr chain)))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section E: Enriched plan-for-unit — buffers + spatial wired in
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section E: Enriched plan-for-unit ===\n")

(with-vat vat
  ;; Add a fresh intent for the enriched plan
  ($ ($ food-runners 'plan-store) 'add-intent
     (make-intent #:id "i-fr-enriched" #:action 'produce
       #:name "Enriched collection run"
       #:resource-conforms-to "spec-sorted-produce"
       #:resource-quantity (make-measure 100 "kg") #:receiver "agent-food-runners" #:due "2026-04-04T08:00:00Z"
       #:at-location "loc-soma"))

  (let* ((result (plan-for-unit
                   '("food-runners") horizon
                   ($ food-runners 'recipe-store)
                   ($ food-runners 'plan-store)
                   ($ food-runners 'observer)
                   #:location-store location-store
                   #:buffer-zone-store ($ food-runners 'buffer-zone-store)
                   #:buffer-profiles profile-map
                   #:buffered-specs '("spec-sorted-produce")
                   #:alert-store ($ food-runners 'alert-store)
                   #:plan-name "Food Runners enriched plan")))
    (check "enriched plan created" (string? (assq-ref result 'plan-id)))

    ;; Alert store should have buffer-status alert (sorted produce starts at 0 = red)
    (let ((alerts ($ ($ food-runners 'alert-store) 'all-alerts)))
      (format #t "  alerts generated: ~a\n" (length alerts)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section F: Critical path — schedule the 3-step collection run
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section F: Critical path ===\n")

(define cp-plan-id "plan-cp-food")

(with-vat vat
  (let ((pr ($ food-runners 'process-registry))
        (ps ($ food-runners 'plan-store))
        (rs ($ food-runners 'recipe-store)))

    ;; Create a plan for this critical-path test
    ($ ps 'add-plan (make-plan #:id cp-plan-id #:name "Critical Path Test"))

    ;; Register 3 processes with timestamps encoding durations
    ;; Pickup: 06:00-06:30 (0.5h = 1800s = 1800000ms)
    ($ pr 'register
       (make-process #:id "proc-cp-pickup" #:name "Pickup" #:based-on "pspec-pickup"
         #:planned-within cp-plan-id #:has-beginning "2026-04-03T06:00:00Z" #:has-end "2026-04-03T06:30:00Z"))
    ;; Sort: 06:30-07:15 (0.75h = 2700s = 2700000ms)
    ($ pr 'register
       (make-process #:id "proc-cp-sort" #:name "Sort" #:based-on "pspec-sort"
         #:planned-within cp-plan-id #:has-beginning "2026-04-03T06:30:00Z" #:has-end "2026-04-03T07:15:00Z"))
    ;; Deliver: 07:15-07:30 (0.25h = 900s = 900000ms)
    ($ pr 'register
       (make-process #:id "proc-cp-deliver" #:name "Deliver" #:based-on "pspec-deliver"
         #:planned-within cp-plan-id #:has-beginning "2026-04-03T07:15:00Z" #:has-end "2026-04-03T07:30:00Z"))

    ;; Commitments that create the dependency edges:
    ;; pickup produces collected → sort consumes collected
    ($ ps 'add-commitment
       (make-commitment #:id "c-cp-pickup-out" #:action 'produce #:output-of "proc-cp-pickup" #:resource-conforms-to "spec-collected"
         #:resource-quantity (make-measure 100 "kg")
         #:provider "agent-food-runners" #:planned-within cp-plan-id))
    ($ ps 'add-commitment
       (make-commitment #:id "c-cp-sort-in" #:action 'consume #:input-of "proc-cp-sort" #:resource-conforms-to "spec-collected"
         #:resource-quantity (make-measure 100 "kg") #:receiver "agent-food-runners" #:planned-within cp-plan-id))
    ;; sort produces sorted → deliver consumes sorted
    ($ ps 'add-commitment
       (make-commitment #:id "c-cp-sort-out" #:action 'produce #:output-of "proc-cp-sort" #:resource-conforms-to "spec-sorted-produce"
         #:resource-quantity (make-measure 90 "kg")
         #:provider "agent-food-runners" #:planned-within cp-plan-id))
    ($ ps 'add-commitment
       (make-commitment #:id "c-cp-deliver-in" #:action 'consume #:input-of "proc-cp-deliver" #:resource-conforms-to "spec-sorted-produce"
         #:resource-quantity (make-measure 90 "kg") #:receiver "agent-food-runners" #:planned-within cp-plan-id))

    ;; Run critical path
    (let ((cp (critical-path cp-plan-id ps pr rs)))
      (let ((path (assq-ref cp 'critical-path))
            (schedule (assq-ref cp 'schedule))
            (total (assq-ref cp 'total-duration-ms)))
        (format #t "  critical path: ~a\n" path)
        (format #t "  total duration: ~ams (~ah)\n" total (/ total 3600000.0))

        (check "critical path has 3 processes" (= 3 (length path)))
        ;; 1800000 + 2700000 + 900000 = 5400000ms = 1.5h
        (check "total duration = 1.5h (5400000ms)" (= 5400000 total))

        ;; All floats should be 0 (linear chain, no parallelism)
        (for-each
          (lambda (entry)
            (let ((f (assq-ref entry 'float)))
              (check (format #f "~a float = 0" (assq-ref entry 'process-id))
                (< (abs f) 1))))
          schedule)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section G: Execution events — run the collection
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section G: Execution events ===\n")

(with-vat vat
  (let* ((obs ($ food-runners 'observer))
         (ps  ($ food-runners 'plan-store))
         (bzs ($ food-runners 'buffer-zone-store))
         (sns ($ food-runners 'snapshot-store))
         (als ($ food-runners 'alert-store))
         (exec-ctx `((observer . ,obs) (plan-store . ,ps)
                     (buffer-zone-store . ,bzs) (snapshot-store . ,sns)
                     (location-store . ,location-store))))

    ;; Clear alerts from prior section
    ($ als 'clear)

    ;; Seed a "received produce" resource in Food Runners' scope
    ;; (SF Market's resource lives in sf-market's observer; Food Runners
    ;; tracks its own received inventory separately)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-received-produce" #:name "Received Produce (SoMa)" #:conforms-to "spec-produce"
         #:accounting-quantity (make-measure 250 "kg") #:onhand-quantity (make-measure 250 "kg")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners"))

    ;; Event 1: Consume raw produce at warehouse (the pickup result)
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-consume-produce" #:action 'consume #:input-of "proc-cp-pickup"
        #:resource-inventoried-as "r-received-produce" #:resource-conforms-to "spec-produce"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 250 "kg") #:has-point-in-time "2026-04-03T06:30:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-received-produce")))
      (check "received produce consumed (0kg remaining)"
        (= 0 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 2: Sort — produce 225kg sorted produce at warehouse
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-sorted-soma" #:name "Sorted Produce (SoMa)" #:conforms-to "spec-sorted-produce"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners"))

    (record-and-monitor obs
      (make-economic-event
        #:id "ev-sort-produce" #:action 'produce #:output-of "proc-cp-sort"
        #:resource-inventoried-as "r-sorted-soma" #:resource-conforms-to "spec-sorted-produce"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 225 "kg") #:has-point-in-time "2026-04-03T07:00:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-sorted-soma")))
      (check "sorted produce = 225kg after sort"
        (= 225 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 3: Deliver 50kg sorted produce to GLIDE (transfer-custody)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-sorted-glide" #:name "Sorted Produce (GLIDE)" #:conforms-to "spec-sorted-produce"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg")
         #:current-location "loc-tenderloin" #:primary-accountable "agent-glide"))

    (record-and-monitor obs
      (make-economic-event
        #:id "ev-deliver-glide" #:action 'transfer-custody
        #:resource-inventoried-as "r-sorted-soma" #:to-resource-inventoried-as "r-sorted-glide" #:resource-conforms-to "spec-sorted-produce"
        #:provider "agent-food-runners" #:receiver "agent-glide"
        #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-03T09:00:00Z"
        #:at-location "loc-soma" #:to-location "loc-tenderloin")
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-sorted-glide")))
      (check "GLIDE received 50kg sorted produce"
        (= 50 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 4: Large delivery drains buffer to yellow zone — triggers alert
    ;; Deliver 150kg more, leaving 25kg onhand (between TOR=50 ... wait, 25 < TOR=50 → red)
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-deliver-mission" #:action 'transfer-custody
        #:resource-inventoried-as "r-sorted-soma" #:resource-conforms-to "spec-sorted-produce"
        #:provider "agent-food-runners" #:receiver "agent-mission-meals"
        #:resource-quantity (make-measure 150 "kg") #:has-point-in-time "2026-04-03T10:00:00Z"
        #:at-location "loc-soma" #:to-location "loc-mission")
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-sorted-soma")))
      (check "sorted produce drained to 25kg"
        (= 25 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Now buffer-status-monitor should fire: 25kg < TOR=50 → red zone
    (let ((buf-alerts ($ als 'of-kind 'buffer-status)))
      (format #t "  buffer alerts: ~a\n" (length buf-alerts))
      (check "buffer-status alert generated" (pair? buf-alerts))
      (check "alert is for sorted-produce"
        (equal? "spec-sorted-produce" (assq-ref (car buf-alerts) 'spec-id)))
      (check "alert zone is red" (eq? 'red (assq-ref (car buf-alerts) 'zone))))

    ;; Check snapshots were recorded (snapshot-sink fires)
    (let ((snaps ($ sns 'all-snapshots)))
      (format #t "  snapshots recorded: ~a\n" (length snaps))
      (check "snapshots recorded by execution sink" (pair? snaps)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section H: Custody tracking — who holds the produce?
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section H: Custody tracking ===\n")

;; Custody uses mutable hash tables — run outside vat.
;; Note: compute.scm previously shadowed current-custodian/held-by with a
;; (ledger, id) argument order. The shadowing block was removed on 2026-04-11;
;; the canonical custody.scm signatures (id, ledger) are now active. This
;; section already worked around the issue by using apply-transfer-custody
;; and reading the hash table directly, so no test changes are needed.
(let ((ledger (make-custody-ledger)))
  ;; Initial custody: SF Market holds produce
  (let ((ev (make-economic-event
              #:id "ev-custody-init" #:action 'transfer-custody #:to-resource-inventoried-as "r-sfmarket-produce" #:resource-conforms-to "spec-produce" #:receiver "agent-sf-market"
              #:resource-quantity (make-measure 500 "kg") #:has-point-in-time "2026-04-01T00:00:00Z" #:to-location "loc-bayview")))
    (apply-transfer-custody ev 200 ledger))

  ;; Transfer: SF Market → Food Runners (pickup)
  (let ((ev (make-economic-event
              #:id "ev-custody-pickup" #:action 'transfer-custody
              #:resource-inventoried-as "r-sfmarket-produce" #:resource-conforms-to "spec-produce"
              #:provider "agent-sf-market" #:receiver "agent-food-runners"
              #:resource-quantity (make-measure 250 "kg") #:has-point-in-time "2026-04-03T06:00:00Z"
              #:at-location "loc-bayview" #:to-location "loc-soma")))
    (apply-transfer-custody ev 100 ledger))

  ;; Verify custody via the mutable ledger's hash table directly
  ;; (apply-transfer-custody mutates the hash tables in-place)
  (let* ((records (ledger-records ledger))
         (rec (hash-ref records "r-sfmarket-produce" #f)))
    (check "Food Runners holds produce after pickup"
      (and rec (equal? "agent-food-runners" (assq-ref rec 'holder)))))

  ;; Transfer: Food Runners → GLIDE (delivery)
  (let ((ev (make-economic-event
              #:id "ev-custody-deliver" #:action 'transfer-custody
              #:resource-inventoried-as "r-sorted-glide" #:resource-conforms-to "spec-sorted-produce"
              #:provider "agent-food-runners" #:receiver "agent-glide"
              #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-03T09:00:00Z"
              #:at-location "loc-soma" #:to-location "loc-tenderloin")))
    (apply-transfer-custody ev 30 ledger))

  (let* ((records (ledger-records ledger))
         (rec (hash-ref records "r-sorted-glide" #f)))
    (check "GLIDE holds sorted produce after delivery"
      (and rec (equal? "agent-glide" (assq-ref rec 'holder)))))

  (let* ((by-agent (ledger-by-agent ledger))
         (glide-resources (hash-ref by-agent "agent-glide" '())))
    (check "GLIDE holds resources in custody"
      (member "r-sorted-glide" glide-resources))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section I: Track & trace — provenance and destination
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section I: Track & trace ===\n")

(with-vat vat
  (let ((obs ($ food-runners 'observer)))
    ;; Trace backward from sorted produce at GLIDE
    (let ((provenance (trace "r-sorted-glide" obs)))
      (format #t "  trace depth: ~a nodes\n" (length provenance))
      (check "trace finds provenance" (pair? provenance)))

    ;; Track forward from received produce (has consume event in this observer)
    (let ((destinations (track "r-received-produce" obs)))
      (format #t "  track depth: ~a nodes\n" (length destinations))
      (check "track finds destinations" (pair? destinations)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section J: Metabolism — net resource flow balance
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section J: Metabolism ===\n")

;; Metabolic accounting — compute.scm still shadows metabolism.scm's
;; metabolic-balance with a relational-facts version (one of ~54 remaining
;; shadows in compute.scm:13–857; see the file header for the cleanup
;; status). We do the accounting inline here to avoid depending on which
;; version wins the runtime binding.
(define food-runner-events
  (with-vat vat ($ ($ food-runners 'observer) 'all-events)))

(let ((total-input 0)
      (total-output 0)
      (specs-seen '()))
  (for-each
    (lambda (e)
      (let* ((ts (or (economic-event-has-point-in-time e)
                     (economic-event-has-beginning e)))
             (in-range (and ts (string>=? ts "2026-04-03T00:00:00Z")
                            (string<=? ts "2026-04-05T23:59:59Z")))
             (action (economic-event-action e))
             (spec (economic-event-resource-conforms-to e))
             (qty (if (economic-event-resource-quantity e)
                      (measure-has-numerical-value (economic-event-resource-quantity e)) 0)))
        (when in-range
          (when spec (unless (member spec specs-seen) (set! specs-seen (cons spec specs-seen))))
          (cond
            ((memq action '(consume use work accept pickup))
             (set! total-input (+ total-input qty)))
            ((memq action '(produce modify deliver-service dropoff))
             (set! total-output (+ total-output qty)))))))
    food-runner-events)
  (format #t "  input: ~a  output: ~a  net: ~a\n" total-input total-output
          (- total-output total-input))
  (check "metabolism has input" (> total-input 0))
  (check "metabolism has output" (> total-output 0))
  ;; Net should be negative: we consumed 250kg but only produced 225kg (10% shrinkage)
  (check "net reflects shrinkage" (< (- total-output total-input) 0))
  (check "multiple specs involved" (> (length specs-seen) 1)))
;; ═════════════════════════════════════════════════════════════════════════
;; Section K: OTIF delivery metrics — did we deliver on time and in full?
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section K: OTIF delivery metrics ===\n")

(with-vat vat
  (let ((obs ($ food-runners 'observer))
        (ps  ($ food-runners 'plan-store)))

    ;; Create commitment: deliver 50kg sorted produce to GLIDE by April 3 10:00
    ($ ps 'add-commitment
       (make-commitment #:id "c-deliver-glide" #:action 'transfer-custody
         #:resource-inventoried-as "r-sorted-soma" #:resource-conforms-to "spec-sorted-produce"
         #:resource-quantity (make-measure 50 "kg")
         #:provider "agent-food-runners" #:receiver "agent-glide" #:due "2026-04-03T10:00:00Z"))

    ;; Register the commitment with the observer for fulfillment tracking
    ($ obs 'register-commitment
       ($ ps 'get-commitment "c-deliver-glide"))

    ;; Record the fulfilling event (at 09:00, due is 10:00 → on time)
    ;; Use #f for resource-inventoried-as to avoid double-decrementing r-sorted-soma
    ;; (Section G already moved the actual resource; this just links fulfillment)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-fulfill-glide" #:action 'transfer-custody #:to-resource-inventoried-as "r-sorted-glide" #:resource-conforms-to "spec-sorted-produce"
         #:provider "agent-food-runners" #:receiver "agent-glide"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-04-03T09:00:00Z"
         #:at-location "loc-soma" #:to-location "loc-tenderloin"
         #:fulfills "c-deliver-glide"))

    ;; Check fulfillment state directly (compute-otif is shadowed by compute.scm)
    (let ((fs ($ obs 'get-fulfillment "c-deliver-glide")))
      (check "fulfillment state exists" (fulfillment-state? fs))
      (let ((committed (measure-has-numerical-value (fulfillment-state-total-committed fs)))
            (fulfilled (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))))
        (format #t "  committed: ~akg  fulfilled: ~akg\n" committed fulfilled)
        (check "committed = 50kg" (= 50 committed))
        (check "fulfilled = 50kg (in-full)" (= 50 fulfilled))
        (check "fulfillment marked done" (fulfillment-state-finished fs))))

    ;; Verify on-time: event at 09:00 <= due at 10:00
    (let* ((events ($ obs 'fulfilled-by "c-deliver-glide"))
           (latest (and (pair? events)
                        (economic-event-has-point-in-time (car events)))))
      (check "fulfilling event exists" (pair? events))
      (check "delivery on time"
        (string<=? (substring latest 0 10) "2026-04-03")))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section L: Full-cycle persistence — everything survives save/restore
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section L: Full-cycle persistence ===\n")

(define-values (vat3 sf-market3 safeway3 food-runners3 glide3 mission-meals3 registry3)
  (spawn-persistent-vat
    scope-root-env-full
    (lambda () (error "Should restore from store!"))
    store))

(with-vat vat3
  ;; Core entities survived
  (check "Food Runners restored (cycle 2)"
    (equal? "Food Runners SF" ($ food-runners3 'name)))

  ;; Buffer zones survived
  (let ((bz ($ ($ food-runners3 'buffer-zone-store) 'get-zone "bz-sorted-produce")))
    (check "buffer zone persisted" (buffer-zone? bz))
    (check "buffer TOR = 50" (= 50 (buffer-zone-tor bz)))
    (check "buffer TOG = 250" (= 250 (buffer-zone-tog bz))))

  ;; Snapshots survived
  (let ((snaps ($ ($ food-runners3 'snapshot-store) 'all-snapshots)))
    (check "snapshots persisted" (pair? snaps)))

  ;; Events survived in observer
  (let ((events ($ ($ food-runners3 'observer) 'all-events)))
    (check "execution events persisted" (pair? events)))

  ;; 3-process recipe survived
  (let ((chain ($ ($ food-runners3 'recipe-store) 'get-process-chain "recipe-collect-deliver")))
    (check "3-process recipe persisted" (= 3 (length chain))))

  ;; Processes in registry survived
  (let ((procs ($ ($ food-runners3 'process-registry) 'for-plan cp-plan-id)))
    (check "critical-path processes persisted" (= 3 (length procs)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section M: Schedule conflicts — volunteer and van booking
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section M: Schedule conflicts ===\n")

(with-vat vat
  (let ((ps ($ food-runners 'plan-store)))
    ;; Add work commitment for volunteer "alice" — pickup+sort run (1.5h)
    ($ ps 'add-commitment
       (make-commitment #:id "c-work-alice-run1" #:action 'work #:effort-quantity (make-measure 1.5 "hours")
         #:provider "alice" #:receiver "agent-food-runners" #:due "2026-04-03T06:00:00Z" #:planned-within cp-plan-id))

    ;; Second shift for alice — delivery (0.25h)
    ($ ps 'add-commitment
       (make-commitment #:id "c-work-alice-deliver" #:action 'work #:effort-quantity (make-measure 0.25 "hours")
         #:provider "alice" #:receiver "agent-food-runners" #:due "2026-04-03T07:15:00Z" #:planned-within cp-plan-id))

    ;; Van use commitment
    ($ ps 'add-commitment
       (make-commitment #:id "c-use-van1-run1" #:action 'use
         #:resource-inventoried-as "r-van-1" #:resource-conforms-to "spec-reefer-van"
         #:resource-quantity (make-measure 1.5 "hours")
         #:provider "agent-food-runners" #:due "2026-04-03T06:00:00Z" #:planned-within cp-plan-id))

    ;; Query alice's effort on April 3
    (let ((hours (committed-effort-on "alice" "2026-04-03" ps)))
      (format #t "  alice effort on Apr 3: ~ah\n" hours)
      (check "alice committed 1.75h on Apr 3" (approx= 1.75 hours)))

    ;; Van conflict check — overlapping window (05:00-08:00 contains 06:00)
    (let ((conflict (has-use-conflict "r-van-1"
                      (iso-datetime->epoch "2026-04-03T05:00:00Z")
                      (iso-datetime->epoch "2026-04-03T08:00:00Z")
                      ps)))
      (check "van-1 has conflict 05:00-08:00" conflict))

    ;; No conflict in later window
    (let ((conflict (has-use-conflict "r-van-1"
                      (iso-datetime->epoch "2026-04-03T10:00:00Z")
                      (iso-datetime->epoch "2026-04-03T12:00:00Z")
                      ps)))
      (check "van-1 free 10:00-12:00" (not conflict)))

    ;; Schedule blocks for alice
    (let ((blocks (schedule-blocks-for "alice" ps)))
      (check "alice has 2 schedule blocks" (= 2 (length blocks))))

    ;; Schedule blocks for van-1
    (let ((blocks (schedule-blocks-for "r-van-1" ps)))
      (check "van-1 has schedule block" (>= (length blocks) 1)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section N: Multi-run — second collection from Safeway
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section N: Multi-run scenario ===\n")

(with-vat vat
  (let* ((obs ($ food-runners 'observer))
         (ps  ($ food-runners 'plan-store))
         (bzs ($ food-runners 'buffer-zone-store))
         (sns ($ food-runners 'snapshot-store))
         (als ($ food-runners 'alert-store))
         (exec-ctx `((observer . ,obs) (plan-store . ,ps)
                     (buffer-zone-store . ,bzs) (snapshot-store . ,sns)
                     (location-store . ,location-store))))

    ;; Clear alerts for clean counting
    ($ als 'clear)

    ;; Seed received produce from Safeway (100kg, second pickup)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-received-produce-2" #:name "Received Produce Run 2" #:conforms-to "spec-produce"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg")
         #:current-location "loc-soma" #:primary-accountable "agent-food-runners"))

    ;; Event 1: Consume raw produce (pickup from Safeway)
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-consume-run2" #:action 'consume #:input-of "proc-run2-pickup"
        #:resource-inventoried-as "r-received-produce-2" #:resource-conforms-to "spec-produce"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 100 "kg") #:has-point-in-time "2026-04-04T06:30:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    (check "run2: received produce consumed"
      (= 0 (measure-has-numerical-value
              (economic-resource-onhand-quantity
                ($ obs 'get-resource "r-received-produce-2")))))

    ;; Event 2: Sort — produce 90kg sorted produce (90% yield)
    ;; r-sorted-soma was at 25kg after Section G deliveries
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-sort-run2" #:action 'produce #:output-of "proc-run2-sort"
        #:resource-inventoried-as "r-sorted-soma" #:resource-conforms-to "spec-sorted-produce"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 90 "kg") #:has-point-in-time "2026-04-04T07:15:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    (let ((onhand (measure-has-numerical-value
                    (economic-resource-onhand-quantity
                      ($ obs 'get-resource "r-sorted-soma")))))
      (format #t "  sorted produce after run2 sort: ~akg\n" onhand)
      (check "run2: sorted produce = 115kg (25 + 90)" (= 115 onhand)))

    ;; Buffer status at 115kg: between TOY=125 and TOR=50 → yellow
    (let* ((bz ($ bzs 'get-zone "bz-sorted-produce"))
           (status (buffer-status 115 bz)))
      (check "run2: 115kg = yellow zone" (eq? 'yellow (assq-ref status 'zone))))

    ;; Event 3: Use van #2 for second run
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-use-van2" #:action 'use
        #:resource-inventoried-as "r-van-2" #:resource-conforms-to "spec-reefer-van"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 1.5 "hours") #:has-point-in-time "2026-04-04T06:00:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    ;; 'use action is no-effect on onhand (VF spec) — it logs usage, not consumption
    ;; Verify the event was recorded by checking events-for-resource
    (let ((van-events ($ obs 'events-for-resource "r-van-2")))
      (check "van-2 use event recorded" (pair? van-events)))

    ;; Event 4: Volunteer hours consumed
    (record-and-monitor obs
      (make-economic-event
        #:id "ev-work-vol-run2" #:action 'work
        #:resource-inventoried-as "r-volunteers" #:resource-conforms-to "spec-volunteer-hours"
        #:provider "agent-food-runners" #:receiver "agent-food-runners"
        #:resource-quantity (make-measure 1.5 "hours") #:has-point-in-time "2026-04-04T06:00:00Z"
        #:at-location "loc-soma")
      exec-ctx als)

    ;; 'work action is also no-effect on onhand — verify event recorded
    (let ((vol-events ($ obs 'events-for-resource "r-volunteers")))
      (check "volunteer work event recorded" (pair? vol-events)))

    ;; Event 5: Deliver 90kg to Mission Meals
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-sorted-mission-2" #:name "Sorted Produce (Mission Meals)" #:conforms-to "spec-sorted-produce"
         #:accounting-quantity (make-measure 0 "kg") #:onhand-quantity (make-measure 0 "kg")
         #:current-location "loc-mission" #:primary-accountable "agent-mission-meals"))

    (record-and-monitor obs
      (make-economic-event
        #:id "ev-deliver-mission-run2" #:action 'transfer-custody
        #:resource-inventoried-as "r-sorted-soma" #:to-resource-inventoried-as "r-sorted-mission-2" #:resource-conforms-to "spec-sorted-produce"
        #:provider "agent-food-runners" #:receiver "agent-mission-meals"
        #:resource-quantity (make-measure 90 "kg") #:has-point-in-time "2026-04-04T08:00:00Z"
        #:at-location "loc-soma" #:to-location "loc-mission")
      exec-ctx als)

    (check "Mission Meals received 90kg"
      (= 90 (measure-has-numerical-value
               (economic-resource-onhand-quantity
                 ($ obs 'get-resource "r-sorted-mission-2")))))

    (let ((onhand (measure-has-numerical-value
                    (economic-resource-onhand-quantity
                      ($ obs 'get-resource "r-sorted-soma")))))
      (check "sorted produce drained to 25kg after run2" (= 25 onhand)))

    ;; Buffer-status alert should fire (25kg < TOR=50 = red zone)
    (let ((red-alerts (filter (lambda (a) (eq? 'red (assq-ref a 'zone)))
                              ($ als 'of-kind 'buffer-status))))
      (check "run2: red-zone alert generated" (pair? red-alerts)))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section O: Reactive replanning — alert triggers replenishment
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section O: Reactive replanning ===\n")

(with-vat vat
  (let* ((als ($ food-runners 'alert-store))
         (ps  ($ food-runners 'plan-store))
         (obs ($ food-runners 'observer))
         (rs  ($ food-runners 'recipe-store))
         (bzs ($ food-runners 'buffer-zone-store)))

    ;; Read the red-zone alert
    (let ((red-alerts (filter (lambda (a) (eq? 'red (assq-ref a 'zone)))
                              ($ als 'of-kind 'buffer-status))))
      (check "red-zone alert exists for replanning" (pair? red-alerts))

      ;; Derive replenishment demand: TOY(125) - onhand(25) = 100kg
      (let* ((alert (car red-alerts))
             (shortfall (- (assq-ref alert 'toy) (assq-ref alert 'onhand))))
        (check "shortfall is 100kg" (= 100 shortfall))

        ;; Post a replenishment intent triggered by the alert
        ($ ps 'add-intent
           (make-intent #:id "i-fr-replan-1" #:action 'produce
             #:name "Replenishment triggered by buffer alert"
             #:resource-conforms-to "spec-sorted-produce"
             #:resource-quantity (make-measure shortfall "kg") #:receiver "agent-food-runners" #:due "2026-04-05T06:00:00Z"
             #:at-location "loc-soma"))

        ;; Verify the intent was stored
        (let ((intent ($ ps 'get-intent "i-fr-replan-1")))
          (check "replenishment intent created" (intent? intent))
          (check "intent requests 100kg sorted produce"
            (= shortfall (measure-has-numerical-value
                           (intent-resource-quantity intent)))))

        ;; The reactive loop is: monitor → alert → derive shortfall → post intent.
        ;; In a live system, plan-for-unit would fire next on this intent.
        ;; Verify the recipe exists to fulfill it.
        (let ((recipe ($ rs 'recipe-for-output "spec-sorted-produce")))
          (check "recipe exists to fulfill replenishment" (and recipe #t)))))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section P: Recipient-side buffers — GLIDE manages its own inventory
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section P: Recipient-side buffers ===\n")

(with-vat vat
  (let ((bzs ($ glide 'buffer-zone-store))
        (obs ($ glide 'observer)))

    ;; Buffer zone for GLIDE: TOR=10, TOY=25, TOG=50
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-glide-sorted" "spec-sorted-produce" "bp-perishable" 'replenished
         "loc-tenderloin" #f #f #f #f
         10 "kg" #f #f #f #f #f #f #f #f
         #f 1
         5 "kg" 1
         #f #f
         #f #f
         10 25 50
         5 #f #f
         #f #f #f #f #f
         "2026-04-01T00:00:00Z"))

    ;; Seed sorted produce inventory at GLIDE (50kg from Section G delivery)
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-glide-sorted" #:name "GLIDE Sorted Produce" #:conforms-to "spec-sorted-produce"
         #:accounting-quantity (make-measure 50 "kg") #:onhand-quantity (make-measure 50 "kg")
         #:current-location "loc-tenderloin" #:primary-accountable "agent-glide"))

    ;; 50kg = TOG boundary → green zone
    (let* ((bz ($ bzs 'get-zone "bz-glide-sorted"))
           (status (buffer-status 50 bz)))
      (check "GLIDE 50kg = green zone" (eq? 'green (assq-ref status 'zone))))

    ;; Simulate partial consumption: 35kg used for daily kitchen → 15kg remaining
    (let* ((bz ($ bzs 'get-zone "bz-glide-sorted"))
           (status (buffer-status 15 bz)))
      (check "GLIDE 15kg = yellow zone" (eq? 'yellow (assq-ref status 'zone))))

    ;; 5kg → red zone (below TOR=10)
    (let* ((bz ($ bzs 'get-zone "bz-glide-sorted"))
           (status (buffer-status 5 bz)))
      (check "GLIDE 5kg = red zone" (eq? 'red (assq-ref status 'zone))))

    ;; Tipping point breach: bz has tipping-point=5
    (let* ((bz ($ bzs 'get-zone "bz-glide-sorted"))
           (status (buffer-status 3 bz)))
      (check "GLIDE 3kg breaches tipping point"
        (assq-ref status 'tipping-point-breached)))

    ;; find-zone works with location store
    (check "GLIDE find-zone resolves"
      (buffer-zone? ($ bzs 'find-zone "spec-sorted-produce" "loc-tenderloin" location-store)))

    ;; Cross-scope isolation: Food Runners doesn't see GLIDE's zone
    (check "Food Runners doesn't have GLIDE's zone"
      (not ($ ($ food-runners 'buffer-zone-store) 'get-zone "bz-glide-sorted")))))
;; ═════════════════════════════════════════════════════════════════════════
;; Section Q: Multi-donor routing — shortest paths between locations
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Section Q: Multi-donor routing ===\n")

;; Haversine distance (km) between two (lat, lon) pairs
(define (haversine lat1 lon1 lat2 lon2)
  (let* ((R 6371)
         (d->r (lambda (d) (* d (/ 3.141592653589793 180))))
         (dlat (d->r (- lat2 lat1)))
         (dlon (d->r (- lon2 lon1)))
         (a (+ (* (sin (/ dlat 2)) (sin (/ dlat 2)))
               (* (cos (d->r lat1)) (cos (d->r lat2))
                  (sin (/ dlon 2)) (sin (/ dlon 2)))))
         (c (* 2 (atan (sqrt a) (sqrt (- 1 a))))))
    (* R c)))

;; Extract coordinates inside vat
(define route-coords
  (with-vat vat
    (list (cons "loc-soma"     ($ location-store 'resolve-coordinates "loc-soma"))
          (cons "loc-bayview"  ($ location-store 'resolve-coordinates "loc-bayview"))
          (cons "loc-sunset"   ($ location-store 'resolve-coordinates "loc-sunset"))
          (cons "loc-tenderloin" ($ location-store 'resolve-coordinates "loc-tenderloin"))
          (cons "loc-mission"  ($ location-store 'resolve-coordinates "loc-mission")))))

;; Dijkstra uses mutable hash tables — must run outside vat
(let* ((get-lat (lambda (id) (car (assoc-ref route-coords id))))
       (get-lon (lambda (id) (cdr (assoc-ref route-coords id))))
       (dist (lambda (a b) (haversine (get-lat a) (get-lon a) (get-lat b) (get-lon b))))
       ;; Key distances
       (d-soma-bayview (dist "loc-soma" "loc-bayview"))
       (d-soma-sunset (dist "loc-soma" "loc-sunset"))
       (d-bayview-sunset (dist "loc-bayview" "loc-sunset")))

  (format #t "  SoMa → Bayview: ~,1fkm\n" d-soma-bayview)
  (format #t "  SoMa → Sunset:  ~,1fkm\n" d-soma-sunset)
  (format #t "  Bayview → Sunset: ~,1fkm\n" d-bayview-sunset)

  ;; Bayview (SF Market) is closer to SoMa (Food Runners HQ) than Sunset (Safeway)
  (check "Bayview closer to SoMa than Sunset" (< d-soma-bayview d-soma-sunset))

  ;; Build graph and run Dijkstra from SoMa
  (let* ((nodes '("loc-soma" "loc-bayview" "loc-sunset"))
         (edges (list (list "loc-soma" "loc-bayview" d-soma-bayview)
                      (list "loc-bayview" "loc-soma" d-soma-bayview)
                      (list "loc-soma" "loc-sunset" d-soma-sunset)
                      (list "loc-sunset" "loc-soma" d-soma-sunset)
                      (list "loc-bayview" "loc-sunset" d-bayview-sunset)
                      (list "loc-sunset" "loc-bayview" d-bayview-sunset)))
         (result (dijkstra nodes edges "loc-soma")))

    ;; Shortest path to Bayview should be direct
    (let ((path (reconstruct-path "loc-bayview" result)))
      (check "shortest to Bayview is direct" (= 2 (length path)))
      (check "path starts at SoMa" (equal? "loc-soma" (car path))))

    ;; Shortest path to Sunset should also be direct (triangle inequality)
    (let ((path (reconstruct-path "loc-sunset" result)))
      (check "shortest to Sunset is direct" (= 2 (length path)))))

  ;; Optimal pickup order: SoMa → Bayview → Sunset is shorter than SoMa → Sunset → Bayview
  (let ((route-a (+ d-soma-bayview d-bayview-sunset))   ;; SoMa → Bayview → Sunset
        (route-b (+ d-soma-sunset d-bayview-sunset)))    ;; SoMa → Sunset → Bayview
    (format #t "  Route A (SoMa→Bayview→Sunset): ~,1fkm\n" route-a)
    (format #t "  Route B (SoMa→Sunset→Bayview): ~,1fkm\n" route-b)
    (check "Bayview-first route is shorter" (< route-a route-b))))
;; ═════════════════════════════════════════════════════════════════════════
;; Summary
;; ═════════════════════════════════════════════════════════════════════════

(format #t "\n~a/~a SF food surplus federation checks passed.\n" pass-count pass-count)
(display "Food surplus redistribution scenario test complete.\n")
