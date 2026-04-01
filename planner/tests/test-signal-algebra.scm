;;; test-signal-algebra.scm — Signal algebra: emit, query, round-trip
;;;
;;; Ported from: old/planner/src/lib/tests/signal-algebra.test.ts
;;;
;;; Intent: Verify the signal system — deficit, surplus, conservation,
;;; and replenishment signals are correctly emitted as tagged intents,
;;; round-trip through signal→intent→signal conversion, and can be
;;; queried by kind.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-signal-algebra.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))


;;; ── Harness ───────────────────────────────────────────────────────────────────

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
    scope-env
    (lambda () (spawn-scope "Signal Test Commune"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (ps ($ scope 'plan-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-wheat" "Wheat" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-flour" "Flour" #f #f #f "kg" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-steel" "Steel" #f #f #f "ton" #f #f #f #f #f))
    ($ rs 'add-resource-spec
       (make-resource-specification "spec-water" "Water" #f #f #f "litre" #f #f #f #f #f))
    ($ ps 'add-plan (make-plan "plan-sig" "Signal Plan" #f
                               "2026-04-07T00:00:00Z" "2026-03-27T00:00:00Z"
                               #f #f #f))
    (check-pred "setup ok" #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Deficit signal → intent round-trip
;;;
;;; Ported from: "emits a deficit signal with correct tags"
;;;              "deficit round-trip"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Deficit signal ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Create deficit signal as tagged alist
    (let* ((deficit `((kind . deficit) (spec-id . "spec-wheat")
                      (qty . 50) (unit . "kg") (scope . "commune-1")
                      (due . "2026-04-01T00:00:00Z")
                      (original-shortfall . 50) (resolved-at . ()))))

      ;; Convert signal → intent
      (let-values (((intent meta) (signal->intent deficit "plan-sig")))
        (check-pred "deficit: creates intent" (intent? intent))

        ;; Tags
        (check-pred "deficit: has deficit tag"
                    (member "tag:plan:deficit"
                            (or (intent-resource-classified-as intent) '())))

        ;; Quantity
        (check "deficit: qty=50"
               (measure-has-numerical-value (intent-resource-quantity intent))
               50)

        ;; Spec
        (check "deficit: spec=wheat"
               (intent-resource-conforms-to intent)
               "spec-wheat")

        ;; Round-trip: intent → signal
        (let ((reconstructed (intent->signal intent meta)))
          (check "deficit RT: kind" (assq-ref reconstructed 'kind) 'deficit)
          (check "deficit RT: qty" (assq-ref reconstructed 'qty) 50)
          (check "deficit RT: spec" (assq-ref reconstructed 'spec-id) "spec-wheat"))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Surplus signal → intent round-trip
;;;
;;; Ported from: "emits a surplus signal with correct tags"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Surplus signal ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    (let* ((surplus `((kind . surplus) (spec-id . "spec-flour")
                      (qty . 30) (unit . "kg") (scope . "farm-1")
                      (available-from . "2026-04-02T00:00:00Z"))))

      (let-values (((intent meta) (signal->intent surplus "plan-sig")))
        (check-pred "surplus: creates intent" (intent? intent))
        (check-pred "surplus: has surplus tag"
                    (member "tag:plan:surplus"
                            (or (intent-resource-classified-as intent) '())))

        ;; Round-trip
        (let ((reconstructed (intent->signal intent meta)))
          (check "surplus RT: kind" (assq-ref reconstructed 'kind) 'surplus)
          (check "surplus RT: qty" (assq-ref reconstructed 'qty) 30))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Replenishment signal generation
;;;
;;; Ported from: algorithms-foundation "replenishment signal" +
;;;              signal-algebra "replenishment round-trip"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Replenishment signal ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (ps ($ scope 'plan-store)))

    ;; Create a buffer zone for wheat
    (let ((bzs ($ scope 'buffer-zone-store)))
      ($ bzs 'add-zone
         (make-buffer-zone
           "bz-wheat-sig" "spec-wheat" "bp-1" 'replenished
           #f #f #f #f #f
           10 "kg" #f #f #f #f #f #f #f #f #f
           10 0 "kg" #f #f #f #f #f
           100 200 300 #f #f #f #f #f #f #f #f
           "2026-03-27T00:00:00Z")))

    ;; Simulate yellow-zone NFP
    (let* ((bz ($ ($ scope 'buffer-zone-store) 'get-zone "bz-wheat-sig"))
           (fake-nfp `((nfp . 150) (onhand . 150) (onorder . 0)
                       (qualified-demand . 0) (zone . yellow) (priority . 0.5)))
           (signal (generate-replenishment-signal
                     "spec-wheat" fake-nfp bz
                     (iso-datetime->epoch "2026-03-27T00:00:00Z"))))

      (check-pred "replenishment: signal generated" (replenishment-signal? signal))
      ;; recommended = TOG - NFP = 300 - 150 = 150
      (check-pred "replenishment: qty=150"
                  (approx= 150 (replenishment-signal-recommended-qty signal) 1))
      (check "replenishment: zone=yellow"
             (replenishment-signal-zone signal) 'yellow)
      (check "replenishment: status=open"
             (replenishment-signal-status signal) 'open))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Signal tags don't pollute regular intents
;;;
;;; Ported from: "intentToSignal returns null for a plain intent"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Plain intent is not a signal ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Add a regular production intent (no signal tags)
    ($ ps 'add-intent
       (make-intent "i-plain" 'produce "Regular production" #f #f
                    #f "proc-1" #f "spec-wheat" #f
                    (make-measure 100 "kg") #f #f #f
                    "agent-a" #f
                    #f #f #f #f
                    #f #f #f "plan-sig" #f #f #f #f))

    (let ((intent ($ ps 'get-intent "i-plain")))
      ;; No signal tags
      (check-pred "plain intent: no deficit tag"
                  (not (member "tag:plan:deficit"
                               (or (intent-resource-classified-as intent) '()))))
      (check-pred "plain intent: no surplus tag"
                  (not (member "tag:plan:surplus"
                               (or (intent-resource-classified-as intent) '())))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Multiple signals of different kinds
;;;
;;; Ported from: "signalsOfKind returns typed signals matching emissions"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Multiple signal kinds ──\n")

(with-vat vat
  (let ((ps ($ scope 'plan-store)))
    ;; Emit two deficit signals and one surplus
    (let-values (((d1 m1) (signal->intent
                            `((kind . deficit) (spec-id . "spec-wheat")
                              (qty . 10) (unit . "kg") (scope . "s1")
                              (original-shortfall . 10) (resolved-at . ()))
                            "plan-sig")))
      ($ ps 'add-intent d1))

    (let-values (((d2 m2) (signal->intent
                            `((kind . deficit) (spec-id . "spec-flour")
                              (qty . 20) (unit . "kg") (scope . "s1")
                              (original-shortfall . 20) (resolved-at . ()))
                            "plan-sig")))
      ($ ps 'add-intent d2))

    (let-values (((s1 m3) (signal->intent
                            `((kind . surplus) (spec-id . "spec-steel")
                              (qty . 5) (unit . "ton") (scope . "s1"))
                            "plan-sig")))
      ($ ps 'add-intent s1))

    ;; Count intents with deficit tag
    (let* ((all-intents ($ ps 'all-intents))
           (deficit-tagged (filter
                             (lambda (i)
                               (member "tag:plan:deficit"
                                       (or (intent-resource-classified-as i) '())))
                             all-intents))
           (surplus-tagged (filter
                             (lambda (i)
                               (member "tag:plan:surplus"
                                       (or (intent-resource-classified-as i) '())))
                             all-intents)))
      (check-pred "2 deficit signals" (= 2 (length deficit-tagged)))
      (check-pred "1 surplus signal" (= 1 (length surplus-tagged))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
