;;; algorithms-foundation.scm — Tests for Layer 2 foundation algorithms
;;;
;;; Tests: propagation (SNLT, duration), SNE, DDMRP (ADU, DLT, NFP, zones),
;;;        signals (signal->intent, intent->signal round-trip).

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

(define pass-count 0)
(define (check label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (format #t "  ok: ~a\n" label))
      (error (string-append "FAIL: " label))))

(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))


;; =========================================================================
;; Setup: Create a scope with recipes for testing
;; =========================================================================

(display "=== Setup: Create test scope ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (ps ($ scope 'plan-store)))

    ;; Specs
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-bread" "Bread" #f #f #f "each" #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-mill" "Milling" #f #f #f #f #f #f #f))
    ($ rs 'add-process-spec
       (make-process-specification "pspec-bake" "Baking" #f #f #f #f #f #f #f))

    ;; Recipe: wheat -> flour (milling, 2h) -> bread (baking, 4h)
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-mill" "Mill" #f #f "pspec-mill" #f
                            (make-duration 2 "hours") #f #f))
    ($ rs 'add-recipe-process
       (make-recipe-process "rp-bake" "Bake" #f #f "pspec-bake" #f
                            (make-duration 4 "hours") #f #f))
    ;; Mill flows: consume 10kg wheat, produce 8kg flour, 1h work
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-w-in" 'consume "spec-wheat" #f
                         (make-measure 10 "kg") #f "rp-mill" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-f-out" 'produce "spec-flour" #f
                         (make-measure 8 "kg") #f #f "rp-mill" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-work-mill" 'work #f #f
                         #f (make-measure 1 "hours") "rp-mill" #f #f #f #f #f #f #f))
    ;; Bake flows: consume 8kg flour, produce 20 bread, 2h work
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-f-in" 'consume "spec-flour" #f
                         (make-measure 8 "kg") #f "rp-bake" #f #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-b-out" 'produce "spec-bread" #f
                         (make-measure 20 "each") #f #f "rp-bake" #f #f #f #f #f #f))
    ($ rs 'add-recipe-flow
       (make-recipe-flow "rf-work-bake" 'work #f #f
                         #f (make-measure 2 "hours") "rp-bake" #f #f #f #f #f #f #f))

    ($ rs 'add-recipe
       (make-recipe "recipe-bread" "Bread" #f #f "spec-bread"
                    (list "rp-mill" "rp-bake") #f))


    ;; =====================================================================
    ;; Test 1: Propagation — Duration conversion
    ;; =====================================================================

    (display "\n=== Test: Propagation ===\n")

    (let ((rp-mill ($ rs 'get-recipe-process "rp-mill"))
          (rp-bake ($ rs 'get-recipe-process "rp-bake")))
      (check "mill duration ms" (= 7200000 (rp-duration-ms rp-mill)))
      (check "bake duration ms" (= 14400000 (rp-duration-ms rp-bake)))
      (check "mill duration days" (approx= (/ 2 24) (rp-duration-days rp-mill) 0.001))
      (check "bake duration days" (approx= (/ 4 24) (rp-duration-days rp-bake) 0.001)))


    ;; =====================================================================
    ;; Test 2: SNLT
    ;; =====================================================================

    (display "\n=== Test: SNLT ===\n")

    (let ((snlt (compute-snlt rs "recipe-bread")))
      ;; Total work: 1h (mill) + 2h (bake) = 3h
      ;; Total output: 20 bread
      ;; SNLT = 3/20 = 0.15 hours/bread
      (check "snlt bread" (approx= 0.15 snlt 0.001)))


    ;; =====================================================================
    ;; Test 3: SNE index
    ;; =====================================================================

    (display "\n=== Test: SNE ===\n")

    (let ((index (build-sne-index rs)))
      (let ((bread-sne (hashmap-ref index "spec-bread" #f)))
        (check "sne bread computed" (number? bread-sne))
        ;; SNE for bread = (1h work + 2h work) / 20 bread = 0.15
        (check "sne bread value" (approx= 0.15 bread-sne 0.001))))


    ;; =====================================================================
    ;; Test 4: DDMRP — Buffer zone computation
    ;; =====================================================================

    (display "\n=== Test: DDMRP Buffer Zones ===\n")

    (let* ((profile (make-buffer-profile
                      "bp-1" "Test Profile" 'manufactured
                      1.0  ;; leadTimeFactor
                      #f #f
                      0.5  ;; variabilityFactor
                      7    ;; orderCycleDays
                      #f #f #f #f #f #f))
           ;; ADU=25, DLT=10, MOQ=50
           (levels (compute-buffer-zone-levels profile 25 "kg" 10 50 "kg")))
      ;; red-base = ADU * DLT * LTF = 25 * 10 * 1.0 = 250
      (check "red-base" (approx= 250 (assq-ref levels 'red-base)))
      ;; red-safety = red-base * VF = 250 * 0.5 = 125
      (check "red-safety" (approx= 125 (assq-ref levels 'red-safety)))
      ;; TOR = red-base + red-safety = 375
      (check "tor" (approx= 375 (assq-ref levels 'tor)))
      ;; TOY = TOR + ADU * DLT = 375 + 250 = 625
      (check "toy" (approx= 625 (assq-ref levels 'toy)))
      ;; green = max(ADU*DOC, red-base, MOQ) = max(175, 250, 50) = 250
      ;; TOG = TOY + green = 625 + 250 = 875
      (check "tog" (approx= 875 (assq-ref levels 'tog))))


    ;; =====================================================================
    ;; Test 5: DDMRP — ADU from events
    ;; =====================================================================

    (display "\n=== Test: DDMRP ADU ===\n")

    ;; Seed wheat and record some consume events
    ($ obs 'seed-resource
       (make-economic-resource
         "r-wheat" "Wheat" #f #f #f "spec-wheat" #f
         (make-measure 1000 "kg") (make-measure 1000 "kg")
         #f #f "agent-commune" #f #f #f #f #f #f #f #f))

    ;; Record 7 days of consumption: 10kg/day
    (let ((base-time (iso-datetime->epoch "2026-03-20T00:00:00Z")))
      (do ((day 0 (+ day 1)))
          ((= day 7))
        ($ obs 'record-event
           (make-economic-event
             (string-append "ev-adu-" (number->string day))
             'consume #f #f "r-wheat" #f "spec-wheat" #f
             "agent-commune" "agent-commune"
             (make-measure 10 "kg") #f
             #f #f (string-append "2026-03-"
                     (if (< (+ 20 day) 10) "0" "")
                     (number->string (+ 20 day)) "T12:00:00Z")
             #f #f #f #f #f #f #f #f #f #f #f #f #f #f))))

    (let* ((events ($ obs 'all-events))
           (as-of (iso-datetime->epoch "2026-03-27T00:00:00Z"))
           (adu-result (compute-adu events "spec-wheat" 7 as-of)))
      ;; 70kg consumed over 7 days = 10 kg/day
      (check "adu value" (approx= 10.0 (assq-ref adu-result 'adu) 0.1))
      (check "adu samples" (= 7 (assq-ref adu-result 'sample-count))))


    ;; =====================================================================
    ;; Test 6: DDMRP — NFP
    ;; =====================================================================

    (display "\n=== Test: DDMRP NFP ===\n")

    ;; After 7 days * 10kg = 70kg consumed, wheat should be at 930kg
    (let ((r ($ obs 'get-resource "r-wheat")))
      (check "wheat after consumption" (approx= 930
               (measure-has-numerical-value
                 (economic-resource-onhand-quantity r)) 1)))

    ;; Create a buffer zone for wheat
    (let ((bzs ($ scope 'buffer-zone-store)))
      ($ bzs 'add-zone
         (make-buffer-zone
           "bz-wheat" "spec-wheat" "bp-1" 'replenished
           #f #f #f #f #f
           10 "kg" #f #f #f #f #f #f #f #f #f  ;; ADU=10
           10 0 "kg" #f #f #f #f #f             ;; DLT=10, MOQ=0
           375 625 875 #f #f #f #f #f #f #f #f  ;; TOR/TOY/TOG
           "2026-03-27T00:00:00Z")))

    (let* ((bz ($ ($ scope 'buffer-zone-store) 'get-zone "bz-wheat"))
           (profile (make-buffer-profile
                      "bp-1" "Test" 'manufactured 1.0 #f #f 0.5 7 #f #f #f #f #f #f))
           (nfp-result (compute-nfp "spec-wheat" bz profile ps obs)))
      ;; NFP = onhand(930) + onorder(0) - qualifiedDemand(0) = 930
      (check "nfp" (approx= 930 (assq-ref nfp-result 'nfp) 1))
      ;; 930 > TOG(875) → excess
      (check "nfp zone" (eq? 'excess (assq-ref nfp-result 'zone))))


    ;; =====================================================================
    ;; Test 7: Buffer status
    ;; =====================================================================

    (display "\n=== Test: Buffer Status ===\n")

    (let ((bz ($ ($ scope 'buffer-zone-store) 'get-zone "bz-wheat")))
      ;; At 930 onhand, TOR=375, TOY=625, TOG=875 → excess
      (let ((status (buffer-status 930 bz)))
        (check "status excess" (eq? 'excess (assq-ref status 'zone))))
      ;; At 400 onhand → yellow
      (let ((status (buffer-status 400 bz)))
        (check "status yellow" (eq? 'yellow (assq-ref status 'zone))))
      ;; At 200 onhand → red
      (let ((status (buffer-status 200 bz)))
        (check "status red" (eq? 'red (assq-ref status 'zone)))))


    ;; =====================================================================
    ;; Test 8: Replenishment signal generation
    ;; =====================================================================

    (display "\n=== Test: Replenishment Signal ===\n")

    (let* ((bz ($ ($ scope 'buffer-zone-store) 'get-zone "bz-wheat"))
           ;; Simulate yellow-zone NFP
           (fake-nfp `((nfp . 500) (onhand . 500) (onorder . 0)
                       (qualified-demand . 0) (zone . yellow) (priority . 0.57)))
           (signal (generate-replenishment-signal
                     "spec-wheat" fake-nfp bz
                     (iso-datetime->epoch "2026-03-27T00:00:00Z"))))
      (check "signal generated" (replenishment-signal? signal))
      ;; recommended = TOG - NFP = 875 - 500 = 375
      (check "signal qty" (approx= 375 (replenishment-signal-recommended-qty signal) 1))
      (check "signal zone" (eq? 'yellow (replenishment-signal-zone signal)))
      (check "signal status" (eq? 'open (replenishment-signal-status signal))))


    ;; =====================================================================
    ;; Test 9: Signals — round-trip conversion
    ;; =====================================================================

    (display "\n=== Test: Signal Round-Trip ===\n")

    ;; Deficit signal
    (let* ((deficit `((kind . deficit) (spec-id . "spec-wheat")
                      (qty . 50) (unit . "kg") (scope . "commune-1")
                      (due . "2026-04-01T00:00:00Z")
                      (original-shortfall . 50) (resolved-at . ()))))
      (let-values (((intent meta) (signal->intent deficit "plan-1")))
        (check "deficit intent" (intent? intent))
        (check "deficit tag" (member "tag:plan:deficit"
                               (or (intent-resource-classified-as intent) '())))
        (check "deficit qty" (= 50 (measure-has-numerical-value
                                      (intent-resource-quantity intent))))
        ;; Round-trip
        (let ((reconstructed (intent->signal intent meta)))
          (check "deficit round-trip kind" (eq? 'deficit (assq-ref reconstructed 'kind)))
          (check "deficit round-trip qty" (= 50 (assq-ref reconstructed 'qty)))
          (check "deficit round-trip spec" (equal? "spec-wheat"
                                                    (assq-ref reconstructed 'spec-id))))))

    ;; Surplus signal
    (let* ((surplus `((kind . surplus) (spec-id . "spec-flour")
                      (qty . 30) (unit . "kg") (scope . "farm-1")
                      (available-from . "2026-04-02T00:00:00Z"))))
      (let-values (((intent meta) (signal->intent surplus "plan-1")))
        (check "surplus intent" (intent? intent))
        (let ((reconstructed (intent->signal intent meta)))
          (check "surplus round-trip" (eq? 'surplus (assq-ref reconstructed 'kind)))
          (check "surplus qty" (= 30 (assq-ref reconstructed 'qty))))))


    ;; =====================================================================
    ;; Test 10: Recipe lead time
    ;; =====================================================================

    (display "\n=== Test: Recipe Lead Time ===\n")

    (let ((dlt (recipe-lead-time "recipe-bread" rs)))
      ;; 2h milling + 4h baking = 6h = 0.25 days
      (check "recipe DLT" (approx= 0.25 dlt 0.01)))


    ;; =====================================================================
    ;; Test 11: Prioritized share
    ;; =====================================================================

    (display "\n=== Test: Prioritized Share ===\n")

    (let* ((slots (list `((id . "loc-a") (onhand . 50) (tor . 100) (toy . 200) (tog . 300))
                        `((id . "loc-b") (onhand . 150) (tor . 100) (toy . 200) (tog . 300))))
           ;; 200 units to share
           (result (prioritized-share slots 200)))
      ;; Phase 1: fill to TOR: loc-a needs 50, loc-b needs 0 → 50 used
      ;; Phase 2: fill to TOY: loc-a needs 100 more (to 200), loc-b needs 50 → 150 used (total 200)
      (let ((alloc-a (or (assoc-ref result "loc-a") 0))
            (alloc-b (or (assoc-ref result "loc-b") 0)))
        (check "share total" (approx= 200 (+ alloc-a alloc-b) 1))
        ;; loc-a: 50 (to TOR) + 100 (to TOY) = 150
        (check "share loc-a" (approx= 150 alloc-a 1))
        ;; loc-b: 0 (already at TOR) + 50 (to TOY) = 50
        (check "share loc-b" (approx= 50 alloc-b 1))))))


;; =========================================================================
;; Summary
;; =========================================================================

(format #t "\n~a/~a foundation algorithm checks passed.\n" pass-count pass-count)
(display "Foundation algorithms test complete.\n")
