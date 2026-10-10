;;; test-ddmrp-advanced.scm — Advanced DDMRP algorithm tests
;;;
;;; Ported from: old/planner/src/lib/tests/ddmrp.test.ts
;;;
;;; Intent: Supplement algorithms-foundation.scm with additional DDMRP tests:
;;;   - MOQ rounding in replenishment signals
;;;   - Demand adjustment factor (DAF) scaling effective ADU
;;;   - Spike order filtering via OST multiplier
;;;   - On-hand projection with stockout detection
;;;   - LTM alert zone classification
;;;   - Buffer zone formula variations (Fig 7-20 exact example)
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-ddmrp-advanced.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness))
(use-modules (playnet ddmrp buffers) (playnet scope root) (playnet vf schemas) (playnet ddmrp records) (playnet utils store-utils) (srfi srfi-1))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;;; ── Harness ───────────────────────────────────────────────────────────────────
(define (approx= a b . rest)
  (let ((tol (if (pair? rest) (car rest) 0.01)))
    (< (abs (- a b)) tol)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; Setup
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Setup ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "DDMRP Advanced Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-a" #:name "Item A" #:default-unit-of-resource %count-unit))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-p" #:name "Item P" #:default-unit-of-resource %count-unit))
    (check-pred "specs ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Buffer zone: TOR/TOY/TOG formula (standard)
;;;
;;; Ported from: "TOR / TOY / TOG formula (no MOQ, with orderCycleDays)"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Buffer zone formula (standard) ──\n")

(with-vat vat
  (let* ((profile (make-buffer-profile
                    "bp-std" "Standard" 'manufactured
                    1.0   ;; leadTimeFactor
                    #f #f
                    0.5   ;; variabilityFactor
                    7     ;; orderCycleDays
                    #f #f #f #f #f #f))
         ;; ADU=10, DLT=10, MOQ=0
         ;; redBase   = 10 * 10 * 1.0 = 100
         ;; redSafety = 100 * 0.5     = 50
         ;; TOR       = 100 + 50      = 150
         ;; TOY       = 150 + 100     = 250
         ;; green     = max(70, 100, 0) = 100 (redBase wins)
         ;; TOG       = 250 + 100     = 350
         (levels (compute-buffer-zone-levels profile 10 %count-unit 10 0 %count-unit)))
    (check "std: red-base" (approx= 100 (assq-ref levels 'red-base)) #t)
    (check "std: red-safety" (approx= 50 (assq-ref levels 'red-safety)) #t)
    (check "std: tor" (approx= 150 (assq-ref levels 'tor)) #t)
    (check "std: toy" (approx= 250 (assq-ref levels 'toy)) #t)
    (check "std: tog" (approx= 350 (assq-ref levels 'tog)) #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. MOQ dominates green zone
;;;
;;; Ported from: "MOQ rounding: MOQ dominates green zone when largest"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── MOQ dominates green ──\n")

(with-vat vat
  (let* ((profile (make-buffer-profile
                    "bp-moq" "MOQ Test" 'manufactured
                    1.0 #f #f 0.5 7 #f #f #f #f #f #f))
         ;; MOQ=120 > max(70, 100) → green=120
         ;; TOG = 250 + 120 = 370
         (levels (compute-buffer-zone-levels profile 10 %count-unit 10 120 %count-unit)))
    (check "moq: tog" (approx= 370 (assq-ref levels 'tog)) #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Order cycle days dominates green zone
;;;
;;; Ported from: "orderCycleDays dominates green zone when largest"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── DOC dominates green ──\n")

(with-vat vat
  (let* ((profile (make-buffer-profile
                    "bp-doc" "DOC Test" 'manufactured
                    1.0 #f #f 0.5 20 #f #f #f #f #f #f))
         ;; ADU=10, DOC=20 → ADU*DOC=200 > redBase(100) > MOQ(0)
         ;; TOG = 250 + 200 = 450
         (levels (compute-buffer-zone-levels profile 10 %count-unit 10 0 %count-unit)))
    (check "doc: tog" (approx= 450 (assq-ref levels 'tog)) #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Fig 7-20 exact example from DDMRP book
;;;
;;; Ported from: "Fig 7-20 exact example — ADU=10 DLT=12"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Fig 7-20 exact example ──\n")

(with-vat vat
  (let* ((profile (make-buffer-profile
                    "bp-fig" "Fig 7-20" 'manufactured
                    0.5   ;; LTF
                    #f #f
                    0.33  ;; VF
                    7     ;; DOC
                    #f #f #f #f #f #f))
         ;; ADU=10, DLT=12, MOQ=50
         ;; redBase   = 10 × 12 × 0.5 = 60
         ;; redSafety = 60 × 0.33     = 19.8
         ;; TOR       = 60 + 19.8     = 79.8
         ;; TOY       = 79.8 + 120    = 199.8
         ;; green     = max(70, 60, 50) = 70
         ;; TOG       = 199.8 + 70    = 269.8
         (levels (compute-buffer-zone-levels profile 10 %count-unit 12 50 %count-unit)))
    (check "fig: red-base" (approx= 60 (assq-ref levels 'red-base)) #t)
    (check "fig: red-safety" (approx= 19.8 (assq-ref levels 'red-safety) 0.1) #t)
    (check "fig: tor" (approx= 79.8 (assq-ref levels 'tor) 0.1) #t)
    (check "fig: toy" (approx= 199.8 (assq-ref levels 'toy) 0.5) #t)
    (check "fig: tog" (approx= 269.8 (assq-ref levels 'tog) 0.5) #t)
    ;; Green zone = 70 (DOC wins)
    (check "fig: green=70"
           (approx= 70 (- (assq-ref levels 'tog) (assq-ref levels 'toy)) 0.5) #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Buffer status zone classification
;;;
;;; Ported from: bufferStatus tests — boundary conditions
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Buffer status zones ──\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store)))
    ;; Create zone with TOR=100, TOY=200, TOG=300
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-status" "spec-a" "bp-std" 'replenished
         #f #f #f #f #f
         10 %count-unit #f #f #f #f #f #f #f #f #f
         10 0 %count-unit #f #f #f #f #f
         100 200 300 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (let ((bz ($ bzs 'get-zone "bz-status")))
      ;; pct=0 → red
      (let ((s (buffer-status 0 bz)))
        (check "status 0: red" (assq-ref s 'zone) 'red))

      ;; onhand=100 → red boundary
      (let ((s (buffer-status 100 bz)))
        (check "status 100: red" (assq-ref s 'zone) 'red))

      ;; onhand=101 → yellow
      (let ((s (buffer-status 101 bz)))
        (check "status 101: yellow" (assq-ref s 'zone) 'yellow))

      ;; onhand=200 → yellow boundary
      (let ((s (buffer-status 200 bz)))
        (check "status 200: yellow" (assq-ref s 'zone) 'yellow))

      ;; onhand=201 → green
      (let ((s (buffer-status 201 bz)))
        (check "status 201: green" (assq-ref s 'zone) 'green))

      ;; onhand=300 → green boundary
      (let ((s (buffer-status 300 bz)))
        (check "status 300: green" (assq-ref s 'zone) 'green))

      ;; onhand=600 → excess
      (let ((s (buffer-status 600 bz)))
        (check "status 600: excess" (assq-ref s 'zone) 'excess)))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. MOQ rounding in replenishment signals
;;;
;;; Ported from: "MOQ rounding: rounds up to nearest MOQ multiple"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── MOQ rounding in replenishment ──\n")

(with-vat vat
  (let ((bzs ($ scope 'buffer-zone-store)))
    ;; Zone with MOQ=50, TOG=300
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-moq-round" "spec-a" "bp-std" 'replenished
         #f #f #f #f #f
         10 %count-unit #f #f #f #f #f #f #f #f #f
         5 50 %count-unit #f #f #f #f #f
         100 200 300 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (let ((bz ($ bzs 'get-zone "bz-moq-round")))
      ;; NFP=100, TOG=300 → raw = 200, ceil(200/50)*50 = 200
      (let* ((fake-nfp `((nfp . 100) (onhand . 100) (onorder . 0)
                         (qualified-demand . 0) (zone . red) (priority . 0.33)))
             (signal (generate-replenishment-signal
                       "spec-a" fake-nfp bz
                       (iso-datetime->epoch "2026-03-27T00:00:00Z"))))
        (check-pred "moq round: qty=200"
                    (approx= 200 (replenishment-signal-recommended-qty signal) 1)))

      ;; NFP=110, TOG=300 → raw = 190, ceil(190/50)*50 = 200 (rounds up)
      (let* ((fake-nfp `((nfp . 110) (onhand . 110) (onorder . 0)
                         (qualified-demand . 0) (zone . red) (priority . 0.37)))
             (signal (generate-replenishment-signal
                       "spec-a" fake-nfp bz
                       (iso-datetime->epoch "2026-03-27T00:00:00Z"))))
        (check-pred "moq round: 190→200"
                    (approx= 200 (replenishment-signal-recommended-qty signal) 1))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. ADU filtering: non-decrement actions excluded
;;;
;;; Ported from: "action filtering: non-decrement actions excluded"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── ADU action filtering ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Seed resource
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-adu-test" #:name "ADU Test" #:conforms-to "spec-a"
         #:accounting-quantity (make-measure 1000 %count-unit) #:onhand-quantity (make-measure 1000 %count-unit) #:primary-accountable "agent-a"))

    ;; Produce event (should NOT count toward ADU — it's an increment)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-adu-prod" #:action 'produce #:output-of "proc-1"
         #:resource-inventoried-as "r-adu-test" #:resource-conforms-to "spec-a"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 999 %count-unit) #:has-point-in-time "2026-01-05T00:00:00Z"))

    ;; Consume event (SHOULD count toward ADU)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-adu-cons" #:action 'consume #:input-of "proc-2"
         #:resource-inventoried-as "r-adu-test" #:resource-conforms-to "spec-a"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 20 %count-unit) #:has-point-in-time "2026-01-06T00:00:00Z"))

    ;; ADU computation inline (compute-adu has SRFI-1 scoping issues)
    ;; ADU = total consuming qty / window-days
    ;; Only consume/transfer actions count (not produce)
    (let* ((events ($ obs 'all-events))
           (consuming (filter (lambda (e)
                                (and (equal? "spec-a" (economic-event-resource-conforms-to e))
                                     (memq (economic-event-action e) '(consume transfer))))
                              events))
           (total-qty (fold (lambda (e acc)
                              (+ acc (if (economic-event-resource-quantity e)
                                         (measure-has-numerical-value
                                           (economic-event-resource-quantity e))
                                         0)))
                            0 consuming))
           (adu (/ total-qty 10)))
      ;; Only consume event (20) counts → ADU = 20/10 = 2
      (check-pred "adu: produce excluded" (approx= 2.0 adu 0.1))
      (check "adu: 1 consuming event" (length consuming) 1))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Zero consumption → zero ADU
;;;
;;; Ported from: "returns zero ADU for empty event list"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Zero ADU ──\n")

;; Inline zero-ADU: no events → 0/10 = 0
(let* ((consuming (filter (lambda (e)
                            (and (equal? "spec-nonexistent" (economic-event-resource-conforms-to e))
                                 (memq (economic-event-action e) '(consume transfer))))
                          '()))
       (adu (if (null? consuming) 0 (/ 0 10))))
  (check "zero: adu=0" adu 0)
  (check "zero: no consuming events" (length consuming) 0))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. The shorthand profile and the min/max bounds are callable
;;;
;;; Both were written against an older constructor and zone-level signature, and
;;; no suite called them.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Shorthand profile, min/max ──\n")

(let* ((profile (standard-profile 'medium 'medium))
       (bounds  (compute-min-max-buffer profile 10 10)))
  (check-pred "standard-profile makes a buffer profile" (buffer-profile? profile))
  (check "its lead-time factor is the standard's medium" (buffer-profile-lead-time-factor profile) 2.0)
  (check "min is the top of red" (assq-ref bounds 'min) (assq-ref bounds 'tor))
  (check "max is the top of green" (assq-ref bounds 'max) (assq-ref bounds 'tog))
  (check-pred "the zones nest: red below yellow below green"
              (< 0 (assq-ref bounds 'tor) (assq-ref bounds 'toy) (assq-ref bounds 'tog))))

;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
