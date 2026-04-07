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

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1)
             (srfi srfi-11))

(define pass-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  ok: ~a\n" label))
      (error (string-append "FAIL: " label))))
(define (approx= a b . r) (< (abs (- a b)) (if (pair? r) (car r) 0.01)))


;; ═════════════════════════════════════════════════════════════════════════
;; Setup: Create 5 scopes in a single vat
;; ═════════════════════════════════════════════════════════════════════════

(display "=== Setup: SF Food Surplus Federation (5 scopes) ===\n")

(define store (make-memory-store))
(define scope-env-full
  (make-persistence-env
    `((((vf) ^scope-root) ,^scope-root)
      (((vf planning) ^store-registry) ,^store-registry))
    #:extends (list recipe-store-env agent-store-env observer-env
                    plan-store-env buffer-zone-store-env
                    account-store-env capacity-buffer-store-env
                    spatial-thing-store-env snapshot-store-env
                    alert-store-env store-registry-env
                    process-registry-env
                    live-registry-env live-resource-env)))

(define-values (vat sf-market safeway food-runners glide mission-meals registry)
  (spawn-persistent-vat
    scope-env-full
    (lambda ()
      (values (spawn-scope "The SF Market")
              (spawn-scope "Safeway Sunset")
              (spawn-scope "Food Runners SF")
              (spawn-scope "GLIDE Memorial")
              (spawn-scope "Mission Meals Coalition")
              (spawn ^store-registry (hashmap))))
    store))


;; ═════════════════════════════════════════════════════════════════════════
;; Resource specifications
;; ═════════════════════════════════════════════════════════════════════════

(display "\n=== Seed resource specs ===\n")

;; Food specs — two stages: raw surplus and inspected/sorted
(define produce-spec
  (make-resource-specification "spec-produce" "Fresh Produce" #f #f #f "kg" #f #f #f #f #f))
(define sorted-produce-spec
  (make-resource-specification "spec-sorted-produce" "Sorted Produce" #f #f #f "kg" #f #f #f #f #f))

;; Infrastructure (used via 'use and 'work actions)
(define reefer-van-spec
  (make-resource-specification "spec-reefer-van" "Refrigerated Van" #f #f #f "hours" #f #f #f #f #f))
(define volunteer-spec
  (make-resource-specification "spec-volunteer-hours" "Volunteer Driver Hours" #f #f #f "hours" #f #f #f #f #f))


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
       (make-economic-resource "r-sfmarket-produce" "SF Market Surplus Produce"
         #f #f #f "spec-produce" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         "loc-bayview" #f "agent-sf-market" #f #f #f #f #f #f #f #f)))

  ;; ── Safeway Sunset: grocery surplus ──
  (let ((rs ($ safeway 'recipe-store))
        (obs ($ safeway 'observer)))
    ($ rs 'add-resource-spec produce-spec)
    ($ obs 'seed-resource
       (make-economic-resource "r-safeway-produce" "Safeway Sunset Surplus Produce"
         #f #f #f "spec-produce" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         "loc-sunset" #f "agent-safeway" #f #f #f #f #f #f #f #f)))

  ;; ── Food Runners: logistics coordinator ──
  ;; Has the collection recipe + logistics resources.
  ;; Recipe: consume raw produce → use reefer van → work volunteer hours
  ;;       → produce sorted produce (90% yield, 10% shrinkage from inspection)
  (let ((rs ($ food-runners 'recipe-store))
        (obs ($ food-runners 'observer)))
    ($ rs 'add-resource-spec produce-spec)
    ($ rs 'add-resource-spec sorted-produce-spec)
    ($ rs 'add-resource-spec reefer-van-spec)
    ($ rs 'add-resource-spec volunteer-spec)

    ;; Single-process recipe: pickup + sort in one step (1.5h total)
    ;; In reality this is two steps but combining keeps the recipe simple
    ;; while still modeling the resource transformations correctly.
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-collect-sort" "Collect & Sort Produce" #f #f #f #f
                            (make-duration 1.5 "hours") #f #f))
    ;; Input: consume raw produce
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-produce-in" 'consume "spec-produce" #f
                         (make-measure 100 "kg") #f "rp-collect-sort" #f #f #f #f #f #f #f))
    ;; Input: use reefer van for the run
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-van-use" 'use "spec-reefer-van" #f
                         (make-measure 1.5 "hours") #f "rp-collect-sort" #f #f #f #f #f #f #f))
    ;; Input: volunteer driver labor
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-driver-work" 'work "spec-volunteer-hours" #f
                         (make-measure 1.5 "hours") #f "rp-collect-sort" #f #f #f #f #f #f #f))
    ;; Output: sorted produce (90% yield — 10% shrinkage from quality rejects)
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-sorted-out" 'produce "spec-sorted-produce" #f
                         (make-measure 90 "kg") #f #f "rp-collect-sort" #f #f #f #f #f #f))
    ;; Recipe
    ($ rs 'add-recipe (make-recipe "recipe-collect-produce" "Collect & Sort Produce"
                                   #f #f "spec-sorted-produce"
                                   (list "rp-collect-sort") #f))

    ;; Logistics resources: 2 reefer vans (8h each) + volunteer pool (16h)
    ($ obs 'seed-resource
       (make-economic-resource "r-van-1" "Reefer Van #1"
         #f #f #f "spec-reefer-van" #f
         (make-measure 8 "hours") (make-measure 8 "hours")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-van-2" "Reefer Van #2"
         #f #f #f "spec-reefer-van" #f
         (make-measure 8 "hours") (make-measure 8 "hours")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f))
    ($ obs 'seed-resource
       (make-economic-resource "r-volunteers" "Volunteer Driver Pool"
         #f #f #f "spec-volunteer-hours" #f
         (make-measure 16 "hours") (make-measure 16 "hours")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f)))

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
     (make-intent "i-glide-need" 'transfer
       "GLIDE daily kitchen produce" #f #f #f #f #f
       "spec-sorted-produce" #f
       (make-measure 50 "kg") #f #f #f
       #f "agent-glide"
       #f #f #f "2026-04-03T10:00:00Z"
       "loc-tenderloin" #f #f #f #f #f #f #f))

  ;; Mission Meals: 200kg sorted produce for weekly family boxes
  ($ ($ mission-meals 'plan-store) 'add-intent
     (make-intent "i-mission-need" 'transfer
       "Mission Meals weekly produce boxes" #f #f #f #f #f
       "spec-sorted-produce" #f
       (make-measure 200 "kg") #f #f #f
       #f "agent-mission-meals"
       #f #f #f "2026-04-05T10:00:00Z"
       "loc-mission" #f #f #f #f #f #f #f)))


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
          (purchases (assq-ref result 'purchase-intents)))
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
    (let ((purchases (assq-ref result 'purchase-intents)))
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
    (let ((purchases (assq-ref result 'purchase-intents)))
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
                                              (string-append "i-fr-fed-" (intent-id pi))
                                              'produce
                                              (string-append "Collect for child: "
                                                             (or (intent-name pi) ""))
                                              #f #f #f #f #f
                                              spec #f
                                              (make-measure qty (measure-has-unit
                                                                  (intent-resource-quantity pi)))
                                              #f #f #f
                                              #f "agent-food-runners"
                                              #f #f #f
                                              (if (number? due-val)
                                                  (number->string due-val)
                                                  due-val)
                                              #f #f #f #f #f #f #f #f))))))
                                 (or (assq-ref child-result 'purchase-intents) '())))
                             child-results))

                         (let ((result (plan-for-unit
                                         (list scope-id) horizon rs ps obs
                                         #:plan-name (string-append scope-id " fed plan"))))
                           ;; Convert purchase intents to deficit signals for
                           ;; lateral matching at the root level
                           (let* ((purchases (or (assq-ref result 'purchase-intents) '()))
                                  (purchase-deficits
                                    (filter-map
                                      (lambda (pi)
                                        (let ((rq (intent-resource-quantity pi)))
                                          (and rq (> (measure-has-numerical-value rq) 0)
                                               `((kind . deficit)
                                                 (spec-id . ,(intent-resource-conforms-to pi))
                                                 (qty . ,(measure-has-numerical-value rq))
                                                 (source . purchase-intent)))))
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
              (purchases (or (assq-ref fr-result 'purchase-intents) '())))
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
        (let ((purchases (or (assq-ref glide-result 'purchase-intents) '())))
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
    scope-env-full
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
     (make-spatial-thing "loc-sf" "San Francisco" #f 37.7749 -122.4194 #f #f #f))
  ($ location-store 'add-location
     (make-spatial-thing "loc-bayview" "Bayview (SF Market)" #f 37.7276 -122.3831 #f #f "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing "loc-sunset" "Sunset (Safeway)" #f 37.7527 -122.4939 #f #f "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing "loc-soma" "SoMa (Food Runners HQ)" #f 37.7785 -122.3950 #f #f "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing "loc-tenderloin" "Tenderloin (GLIDE)" #f 37.7836 -122.4138 #f #f "loc-sf"))
  ($ location-store 'add-location
     (make-spatial-thing "loc-mission" "Mission (Mission Meals)" #f 37.7599 -122.4148 #f #f "loc-sf"))

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

(with-vat vat
  (let ((rs ($ food-runners 'recipe-store)))
    ;; Intermediate spec: collected but not yet sorted
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-collected" "Collected Produce"
         #f #f #f "kg" #f #f #f #f #f))

    ;; Process specs for each step
    ($ rs 'add-process-spec
       (make-process-specification "pspec-pickup" "Pickup" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-sort" "Sort & Inspect" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-deliver" "Deliver" #f #f #f #f #f #f #f))

    ;; --- Step 1: Pickup (0.5h) ---
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cd-pickup" "Pickup from donor" #f #f
         "pspec-pickup" #f (make-duration 0.5 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-produce-in" 'consume "spec-produce" #f
         (make-measure 100 "kg") #f "rp-cd-pickup" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-van-pickup" 'use "spec-reefer-van" #f
         (make-measure 0.5 "hours") #f "rp-cd-pickup" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-labor-pickup" 'work "spec-volunteer-hours" #f
         (make-measure 0.5 "hours") #f "rp-cd-pickup" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-collected-out" 'produce "spec-collected" #f
         (make-measure 100 "kg") #f #f "rp-cd-pickup" #f #f #f #f #f #f))

    ;; --- Step 2: Sort & inspect (0.75h) ---
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cd-sort" "Sort & inspect" #f #f
         "pspec-sort" #f (make-duration 0.75 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-collected-in" 'consume "spec-collected" #f
         (make-measure 100 "kg") #f "rp-cd-sort" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-labor-sort" 'work "spec-volunteer-hours" #f
         (make-measure 0.75 "hours") #f "rp-cd-sort" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-sorted-out" 'produce "spec-sorted-produce" #f
         (make-measure 90 "kg") #f #f "rp-cd-sort" #f #f #f #f #f #f))

    ;; --- Step 3: Deliver (0.25h) ---
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-cd-deliver" "Deliver to recipient" #f #f
         "pspec-deliver" #f (make-duration 0.25 "hours") #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-sorted-in" 'consume "spec-sorted-produce" #f
         (make-measure 90 "kg") #f "rp-cd-deliver" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-van-deliver" 'use "spec-reefer-van" #f
         (make-measure 0.25 "hours") #f "rp-cd-deliver" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-labor-deliver" 'work "spec-volunteer-hours" #f
         (make-measure 0.25 "hours") #f "rp-cd-deliver" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-cd-delivered-out" 'produce "spec-sorted-produce" #f
         (make-measure 90 "kg") #f #f "rp-cd-deliver" #f "pspec-deliver" #f #f #f #f))

    ;; Assemble the 3-step recipe
    ($ rs 'add-recipe
       (make-recipe "recipe-collect-deliver" "Full Collection & Delivery Pipeline"
         #f #f "spec-sorted-produce"
         (list "rp-cd-pickup" "rp-cd-sort" "rp-cd-deliver") #f))

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
     (make-intent "i-fr-enriched" 'produce
       "Enriched collection run" #f #f #f #f #f
       "spec-sorted-produce" #f
       (make-measure 100 "kg") #f #f #f
       #f "agent-food-runners"
       #f #f #f "2026-04-04T08:00:00Z"
       "loc-soma" #f #f #f #f #f #f #f))

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
    ($ ps 'add-plan (make-plan cp-plan-id "Critical Path Test" #f #f #f #f #f #f))

    ;; Register 3 processes with timestamps encoding durations
    ;; Pickup: 06:00-06:30 (0.5h = 1800s = 1800000ms)
    ($ pr 'register
       (make-process "proc-cp-pickup" "Pickup" #f "pspec-pickup" #f
         cp-plan-id #f #f "2026-04-03T06:00:00Z" "2026-04-03T06:30:00Z" #f))
    ;; Sort: 06:30-07:15 (0.75h = 2700s = 2700000ms)
    ($ pr 'register
       (make-process "proc-cp-sort" "Sort" #f "pspec-sort" #f
         cp-plan-id #f #f "2026-04-03T06:30:00Z" "2026-04-03T07:15:00Z" #f))
    ;; Deliver: 07:15-07:30 (0.25h = 900s = 900000ms)
    ($ pr 'register
       (make-process "proc-cp-deliver" "Deliver" #f "pspec-deliver" #f
         cp-plan-id #f #f "2026-04-03T07:15:00Z" "2026-04-03T07:30:00Z" #f))

    ;; Commitments that create the dependency edges:
    ;; pickup produces collected → sort consumes collected
    ($ ps 'add-commitment
       (make-commitment "c-cp-pickup-out" 'produce #f #f "proc-cp-pickup"
         #f "spec-collected" #f
         (make-measure 100 "kg") #f
         "agent-food-runners" #f
         #f #f #f #f #f #f #f #f #f #f #f #f cp-plan-id #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-cp-sort-in" 'consume #f "proc-cp-sort" #f
         #f "spec-collected" #f
         (make-measure 100 "kg") #f
         #f "agent-food-runners"
         #f #f #f #f #f #f #f #f #f #f #f #f cp-plan-id #f #f))
    ;; sort produces sorted → deliver consumes sorted
    ($ ps 'add-commitment
       (make-commitment "c-cp-sort-out" 'produce #f #f "proc-cp-sort"
         #f "spec-sorted-produce" #f
         (make-measure 90 "kg") #f
         "agent-food-runners" #f
         #f #f #f #f #f #f #f #f #f #f #f #f cp-plan-id #f #f))
    ($ ps 'add-commitment
       (make-commitment "c-cp-deliver-in" 'consume #f "proc-cp-deliver" #f
         #f "spec-sorted-produce" #f
         (make-measure 90 "kg") #f
         #f "agent-food-runners"
         #f #f #f #f #f #f #f #f #f #f #f #f cp-plan-id #f #f))

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
       (make-economic-resource "r-received-produce" "Received Produce (SoMa)"
         #f #f #f "spec-produce" #f
         (make-measure 250 "kg") (make-measure 250 "kg")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f))

    ;; Event 1: Consume raw produce at warehouse (the pickup result)
    (record-and-monitor obs
      (make-economic-event
        "ev-consume-produce" 'consume "proc-cp-pickup" #f
        "r-received-produce" #f "spec-produce" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 250 "kg") #f
        #f #f "2026-04-03T06:30:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-received-produce")))
      (check "received produce consumed (0kg remaining)"
        (= 0 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 2: Sort — produce 225kg sorted produce at warehouse
    ($ obs 'seed-resource
       (make-economic-resource "r-sorted-soma" "Sorted Produce (SoMa)"
         #f #f #f "spec-sorted-produce" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f))

    (record-and-monitor obs
      (make-economic-event
        "ev-sort-produce" 'produce #f "proc-cp-sort"
        "r-sorted-soma" #f "spec-sorted-produce" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 225 "kg") #f
        #f #f "2026-04-03T07:00:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-sorted-soma")))
      (check "sorted produce = 225kg after sort"
        (= 225 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 3: Deliver 50kg sorted produce to GLIDE (transfer-custody)
    ($ obs 'seed-resource
       (make-economic-resource "r-sorted-glide" "Sorted Produce (GLIDE)"
         #f #f #f "spec-sorted-produce" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         "loc-tenderloin" #f "agent-glide" #f #f #f #f #f #f #f #f))

    (record-and-monitor obs
      (make-economic-event
        "ev-deliver-glide" 'transfer-custody #f #f
        "r-sorted-soma" "r-sorted-glide" "spec-sorted-produce" #f
        "agent-food-runners" "agent-glide"
        (make-measure 50 "kg") #f
        #f #f "2026-04-03T09:00:00Z" #f
        "loc-soma" "loc-tenderloin" #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    (let ((r ($ obs 'get-resource "r-sorted-glide")))
      (check "GLIDE received 50kg sorted produce"
        (= 50 (measure-has-numerical-value (economic-resource-onhand-quantity r)))))

    ;; Event 4: Large delivery drains buffer to yellow zone — triggers alert
    ;; Deliver 150kg more, leaving 25kg onhand (between TOR=50 ... wait, 25 < TOR=50 → red)
    (record-and-monitor obs
      (make-economic-event
        "ev-deliver-mission" 'transfer-custody #f #f
        "r-sorted-soma" #f "spec-sorted-produce" #f
        "agent-food-runners" "agent-mission-meals"
        (make-measure 150 "kg") #f
        #f #f "2026-04-03T10:00:00Z" #f
        "loc-soma" "loc-mission" #f
        #f #f #f #f #f #f #f #f #f #f)
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
;; Note: compute.scm redefines current-custodian/held-by with (ledger, id) order
;; (shadowing custody.scm's (id, ledger) order). We use the compute.scm signatures
;; since $ALL loads it last.
(let ((ledger (make-custody-ledger)))
  ;; Initial custody: SF Market holds produce
  (let ((ev (make-economic-event
              "ev-custody-init" 'transfer-custody #f #f
              #f "r-sfmarket-produce" "spec-produce" #f
              #f "agent-sf-market"
              (make-measure 500 "kg") #f
              #f #f "2026-04-01T00:00:00Z" #f
              #f "loc-bayview" #f
              #f #f #f #f #f #f #f #f #f 200)))
    (apply-transfer-custody ev 200 ledger))

  ;; Transfer: SF Market → Food Runners (pickup)
  (let ((ev (make-economic-event
              "ev-custody-pickup" 'transfer-custody #f #f
              "r-sfmarket-produce" #f "spec-produce" #f
              "agent-sf-market" "agent-food-runners"
              (make-measure 250 "kg") #f
              #f #f "2026-04-03T06:00:00Z" #f
              "loc-bayview" "loc-soma" #f
              #f #f #f #f #f #f #f #f #f 100)))
    (apply-transfer-custody ev 100 ledger))

  ;; Verify custody via the mutable ledger's hash table directly
  ;; (apply-transfer-custody mutates the hash tables in-place)
  (let* ((records (ledger-records ledger))
         (rec (hash-ref records "r-sfmarket-produce" #f)))
    (check "Food Runners holds produce after pickup"
      (and rec (equal? "agent-food-runners" (assq-ref rec 'holder)))))

  ;; Transfer: Food Runners → GLIDE (delivery)
  (let ((ev (make-economic-event
              "ev-custody-deliver" 'transfer-custody #f #f
              "r-sorted-glide" #f "spec-sorted-produce" #f
              "agent-food-runners" "agent-glide"
              (make-measure 50 "kg") #f
              #f #f "2026-04-03T09:00:00Z" #f
              "loc-soma" "loc-tenderloin" #f
              #f #f #f #f #f #f #f #f #f 30)))
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

;; Metabolic accounting — compute.scm shadows metabolism.scm's metabolic-balance
;; with a relational-facts version, so we do the accounting inline.
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
       (make-commitment "c-deliver-glide" 'transfer-custody #f #f #f
         "r-sorted-soma" "spec-sorted-produce" #f
         (make-measure 50 "kg") #f
         "agent-food-runners" "agent-glide"
         #f #f #f "2026-04-03T10:00:00Z"
         #f #f #f #f #f #f #f #f #f #f #f))

    ;; Register the commitment with the observer for fulfillment tracking
    ($ obs 'register-commitment
       ($ ps 'get-commitment "c-deliver-glide"))

    ;; Record the fulfilling event (at 09:00, due is 10:00 → on time)
    ;; Use #f for resource-inventoried-as to avoid double-decrementing r-sorted-soma
    ;; (Section G already moved the actual resource; this just links fulfillment)
    ($ obs 'record-event
       (make-economic-event
         "ev-fulfill-glide" 'transfer-custody #f #f
         #f "r-sorted-glide" "spec-sorted-produce" #f
         "agent-food-runners" "agent-glide"
         (make-measure 50 "kg") #f
         #f #f "2026-04-03T09:00:00Z" #f
         "loc-soma" "loc-tenderloin" #f
         "c-deliver-glide" #f #f #f #f #f #f #f #f #f))

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
    scope-env-full
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
       (make-commitment "c-work-alice-run1" 'work #f #f #f
         #f #f #f
         #f (make-measure 1.5 "hours")
         "alice" "agent-food-runners"
         #f #f #f "2026-04-03T06:00:00Z"
         #f #f #f #f #f #f #f #f cp-plan-id #f #f))

    ;; Second shift for alice — delivery (0.25h)
    ($ ps 'add-commitment
       (make-commitment "c-work-alice-deliver" 'work #f #f #f
         #f #f #f
         #f (make-measure 0.25 "hours")
         "alice" "agent-food-runners"
         #f #f #f "2026-04-03T07:15:00Z"
         #f #f #f #f #f #f #f #f cp-plan-id #f #f))

    ;; Van use commitment
    ($ ps 'add-commitment
       (make-commitment "c-use-van1-run1" 'use #f #f #f
         "r-van-1" "spec-reefer-van" #f
         (make-measure 1.5 "hours") #f
         "agent-food-runners" #f
         #f #f #f "2026-04-03T06:00:00Z"
         #f #f #f #f #f #f #f #f cp-plan-id #f #f))

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
       (make-economic-resource "r-received-produce-2" "Received Produce Run 2"
         #f #f #f "spec-produce" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         "loc-soma" #f "agent-food-runners" #f #f #f #f #f #f #f #f))

    ;; Event 1: Consume raw produce (pickup from Safeway)
    (record-and-monitor obs
      (make-economic-event
        "ev-consume-run2" 'consume "proc-run2-pickup" #f
        "r-received-produce-2" #f "spec-produce" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 100 "kg") #f
        #f #f "2026-04-04T06:30:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    (check "run2: received produce consumed"
      (= 0 (measure-has-numerical-value
              (economic-resource-onhand-quantity
                ($ obs 'get-resource "r-received-produce-2")))))

    ;; Event 2: Sort — produce 90kg sorted produce (90% yield)
    ;; r-sorted-soma was at 25kg after Section G deliveries
    (record-and-monitor obs
      (make-economic-event
        "ev-sort-run2" 'produce #f "proc-run2-sort"
        "r-sorted-soma" #f "spec-sorted-produce" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 90 "kg") #f
        #f #f "2026-04-04T07:15:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
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
        "ev-use-van2" 'use #f #f
        "r-van-2" #f "spec-reefer-van" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 1.5 "hours") #f
        #f #f "2026-04-04T06:00:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    ;; 'use action is no-effect on onhand (VF spec) — it logs usage, not consumption
    ;; Verify the event was recorded by checking events-for-resource
    (let ((van-events ($ obs 'events-for-resource "r-van-2")))
      (check "van-2 use event recorded" (pair? van-events)))

    ;; Event 4: Volunteer hours consumed
    (record-and-monitor obs
      (make-economic-event
        "ev-work-vol-run2" 'work #f #f
        "r-volunteers" #f "spec-volunteer-hours" #f
        "agent-food-runners" "agent-food-runners"
        (make-measure 1.5 "hours") #f
        #f #f "2026-04-04T06:00:00Z" #f
        "loc-soma" #f #f
        #f #f #f #f #f #f #f #f #f #f)
      exec-ctx als)

    ;; 'work action is also no-effect on onhand — verify event recorded
    (let ((vol-events ($ obs 'events-for-resource "r-volunteers")))
      (check "volunteer work event recorded" (pair? vol-events)))

    ;; Event 5: Deliver 90kg to Mission Meals
    ($ obs 'seed-resource
       (make-economic-resource "r-sorted-mission-2" "Sorted Produce (Mission Meals)"
         #f #f #f "spec-sorted-produce" #f
         (make-measure 0 "kg") (make-measure 0 "kg")
         "loc-mission" #f "agent-mission-meals" #f #f #f #f #f #f #f #f))

    (record-and-monitor obs
      (make-economic-event
        "ev-deliver-mission-run2" 'transfer-custody #f #f
        "r-sorted-soma" "r-sorted-mission-2" "spec-sorted-produce" #f
        "agent-food-runners" "agent-mission-meals"
        (make-measure 90 "kg") #f
        #f #f "2026-04-04T08:00:00Z" #f
        "loc-soma" "loc-mission" #f
        #f #f #f #f #f #f #f #f #f #f)
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
           (make-intent "i-fr-replan-1" 'produce
             "Replenishment triggered by buffer alert" #f #f #f #f #f
             "spec-sorted-produce" #f
             (make-measure shortfall "kg") #f #f #f
             #f "agent-food-runners"
             #f #f #f "2026-04-05T06:00:00Z"
             "loc-soma" #f #f #f #f #f #f #f))

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
       (make-economic-resource "r-glide-sorted" "GLIDE Sorted Produce"
         #f #f #f "spec-sorted-produce" #f
         (make-measure 50 "kg") (make-measure 50 "kg")
         "loc-tenderloin" #f "agent-glide" #f #f #f #f #f #f #f #f))

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
