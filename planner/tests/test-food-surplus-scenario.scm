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
;; Summary
;; ═════════════════════════════════════════════════════════════════════════

(format #t "\n~a/~a SF food surplus federation checks passed.\n" pass-count pass-count)
(display "Food surplus redistribution scenario test complete.\n")
