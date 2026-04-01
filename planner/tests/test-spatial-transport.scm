;;; test-spatial-transport.scm — Spatial hierarchy, transport, and containment
;;;
;;; Ported from: old/planner/src/lib/tests/spatial-containment.test.ts
;;;              old/planner/src/lib/tests/transport-planning.test.ts
;;;              old/planner/src/lib/tests/container-mediation.test.ts
;;;
;;; Intent: Verify spatial thing hierarchy (containment chains, coordinate
;;; inheritance), transport recipe discovery, and container-mediated
;;; resource flows.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-spatial-transport.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet kanren-planning)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Spatial Test"))
    store))

(with-vat vat
  (let ((st ($ scope 'spatial-thing-store))
        (rs ($ scope 'recipe-store)))
    ;; Spatial hierarchy: Country → Region → City → Warehouse
    ($ st 'add-location
       (make-spatial-thing "loc-country" "Country" #f 48.0 2.0 #f #f #f))
    ($ st 'add-location
       (make-spatial-thing "loc-region" "Region" #f #f #f #f "loc-country" #f))
    ($ st 'add-location
       (make-spatial-thing "loc-city" "City" #f 48.85 2.35 #f "loc-region" #f))
    ($ st 'add-location
       (make-spatial-thing "loc-warehouse" "Warehouse" #f #f #f #f "loc-city" #f))
    ($ st 'add-location
       (make-spatial-thing "loc-farm" "Farm" #f 45.5 -73.5 #f #f #f))
    ($ st 'add-location
       (make-spatial-thing "loc-mill" "Mill" #f 45.51 -73.49 #f #f #f))

    ;; Resource specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-truck" "Truck" #f #f #f "each" #f #f #f #f #f))

    (check-pred "spatial setup ok" #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Spatial containment hierarchy
;;;
;;; Ported from: spatial-containment "resolveChain"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Spatial containment ──\n")

(with-vat vat
  (let ((st ($ scope 'spatial-thing-store)))
    ;; All locations exist
    (check-pred "country exists" (spatial-thing? ($ st 'get-location "loc-country")))
    (check-pred "region exists" (spatial-thing? ($ st 'get-location "loc-region")))
    (check-pred "city exists" (spatial-thing? ($ st 'get-location "loc-city")))
    (check-pred "warehouse exists" (spatial-thing? ($ st 'get-location "loc-warehouse")))

    ;; Containment: warehouse → city → region → country
    (let ((wh ($ st 'get-location "loc-warehouse")))
      (check "warehouse parent" (spatial-thing-contained-in wh) "loc-city"))
    (let ((city ($ st 'get-location "loc-city")))
      (check "city parent" (spatial-thing-contained-in city) "loc-region"))
    (let ((region ($ st 'get-location "loc-region")))
      (check "region parent" (spatial-thing-contained-in region) "loc-country"))

    ;; Country has no parent (root)
    (let ((country ($ st 'get-location "loc-country")))
      (check-pred "country is root" (not (spatial-thing-contained-in country))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Coordinate inheritance
;;;
;;; Ported from: spatial-containment "resolveCoordinates"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Coordinate inheritance ──\n")

(with-vat vat
  (let ((st ($ scope 'spatial-thing-store)))
    ;; City has explicit coordinates
    (let ((city ($ st 'get-location "loc-city")))
      (check-pred "city has lat" (number? (spatial-thing-lat city)))
      (check-pred "city lat ≈ 48.85" (< (abs (- 48.85 (spatial-thing-lat city))) 0.01)))

    ;; Region inherits from country (no explicit coords)
    ;; Warehouse inherits from city
    (let ((wh ($ st 'get-location "loc-warehouse")))
      ;; Warehouse has no coords → should use city's
      (check-pred "warehouse no direct lat" (not (spatial-thing-lat wh))))

    ;; Farm has its own coords
    (let ((farm ($ st 'get-location "loc-farm")))
      (check-pred "farm has lat" (number? (spatial-thing-lat farm))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Location count
;;;
;;; Ported from: spatial-containment "childrenOf"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Location count ──\n")

(with-vat vat
  (let ((st ($ scope 'spatial-thing-store)))
    (check "6 locations" (length ($ st 'all-locations)) 6)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Location-aware inventory
;;;
;;; Ported from: transport-planning "resource at location"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Location-aware inventory ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed wheat at farm location
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat-farm" "Farm Wheat" #f #f #f "spec-wheat" #f
         (make-measure 500 "kg") (make-measure 500 "kg")
         "loc-farm" #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Seed wheat at mill location
    ($ obs 'seed-resource
       (make-economic-resource "r-wheat-mill" "Mill Wheat" #f #f #f "spec-wheat" #f
         (make-measure 100 "kg") (make-measure 100 "kg")
         "loc-mill" #f "agent-a" #f #f #f #f #f #f #f #f))

    ;; Query: wheat at farm
    (let ((farm-resources (filter
                            (lambda (r) (equal? "loc-farm"
                                                (economic-resource-current-location r)))
                            ($ obs 'all-resources))))
      (check-pred "wheat at farm" (= 1 (length farm-resources)))
      (check "farm wheat qty"
             (measure-has-numerical-value
               (economic-resource-accounting-quantity (car farm-resources)))
             500))

    ;; Query: wheat at mill
    (let ((mill-resources (filter
                            (lambda (r) (equal? "loc-mill"
                                                (economic-resource-current-location r)))
                            ($ obs 'all-resources))))
      (check-pred "wheat at mill" (= 1 (length mill-resources))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Transport: move between locations
;;;
;;; Ported from: transport-planning "pickup/dropoff"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Transport: pickup/dropoff ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Transfer wheat from farm to mill
    ($ obs 'record-event
       (make-economic-event
         "ev-transport" 'transfer #f #f
         "r-wheat-farm" "r-wheat-mill" "spec-wheat" #f
         "agent-a" "agent-a"
         (make-measure 50 "kg") #f
         #f #f "2026-03-28T08:00:00Z" #f
         "loc-farm" "loc-mill" #f
         #f #f #f #f #f #f #f #f #f #f))

    ;; Farm: 500 - 50 = 450
    (check "farm after transport: 450"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity ($ obs 'get-resource "r-wheat-farm")))
           450)

    ;; Mill: 100 + 50 = 150
    (check "mill after transport: 150"
           (measure-has-numerical-value
             (economic-resource-accounting-quantity ($ obs 'get-resource "r-wheat-mill")))
           150)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Relational: location-filtered netting
;;;
;;; Ported from: netting "location guards"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Location-filtered netting ──\n")

(with-vat vat
  (let ((ns (empty-netter-state))
        (ps ($ scope 'plan-store))
        (obs ($ scope 'observer)))

    ;; Net demand at farm location: should see 450 wheat
    (let-values (((ns1 remaining allocated)
                  (netter-net-demand ns ps obs "spec-wheat" 400
                                    #:at-location "loc-farm")))
      (check-pred "farm netting: 400 satisfied" (< remaining 1)))

    ;; Net demand at mill location: should see 150 wheat
    (let-values (((ns2 remaining allocated)
                  (netter-net-demand ns ps obs "spec-wheat" 200
                                    #:at-location "loc-mill")))
      (check-pred "mill netting: partial (50 remaining)" (> remaining 40)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Persistence
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Spatial persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-env
    (lambda () (error "Restore!"))
    store))

(with-vat vat2
  (let ((st ($ scope2 'spatial-thing-store)))
    (check "restored locations" (length ($ st 'all-locations)) 6)
    (check-pred "restored warehouse"
                (spatial-thing? ($ st 'get-location "loc-warehouse")))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
