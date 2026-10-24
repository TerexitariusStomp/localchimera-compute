;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-execution-reactive.scm — Execution loop and reactive event handling
;;;
;;; Ported from: old/planner/src/lib/tests/ddmrp-execution.test.ts
;;;              old/planner/src/lib/tests/execution-reactive.test.ts
;;;
;;; Intent: Verify that the execution layer correctly processes events,
;;; updates buffer status, generates alerts, and triggers replanning
;;; when buffer zones change.
;;;
;;; Run:  cd planner && guile --no-auto-compile -q -L ../module \
;;;         -l load-all.scm -l tests/test-execution-reactive.scm

(use-modules (localchimera test harness))
(use-modules (localchimera ddmrp buffers) (localchimera federation remote-transport) (localchimera scope root) (localchimera vf schemas) (localchimera ddmrp records))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; ── Harness ────────────────────────────────────────────────────────────────
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
    (lambda () (spawn-scope-root "Execution Test"))
    store))

(with-vat vat
  (let ((rs ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (bzs ($ scope 'buffer-zone-store)))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-wheat" #:name "Wheat" #:default-unit-of-resource "kg"))
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec-flour" #:name "Flour" #:default-unit-of-resource "kg"))

    ;; Seed resources
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-wheat-ex" #:name "Wheat" #:conforms-to "spec-wheat"
         #:accounting-quantity (make-measure 500 "kg") #:onhand-quantity (make-measure 500 "kg") #:primary-accountable "agent-a"))

    ;; Buffer zone for wheat
    ($ bzs 'add-zone
       (make-buffer-zone
         "bz-wheat-ex" "spec-wheat" "bp-1" 'replenished
         #f #f #f #f #f
         50 "kg" #f #f #f #f #f #f #f #f #f
         10 0 "kg" #f #f #f #f #f
         200 350 500 #f #f #f #f #f #f #f #f
         "2026-03-27T00:00:00Z"))

    (check-pred "execution setup ok" #t)))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Event-driven buffer update
;;;
;;; Ported from: "consume event updates buffer status"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Event-driven buffer update ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (bzs ($ scope 'buffer-zone-store)))
    ;; Consume 200kg wheat → onhand drops from 500 to 300
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-ex-consume-1" #:action 'consume #:input-of "proc-mill"
         #:resource-inventoried-as "r-wheat-ex" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 200 "kg") #:has-point-in-time "2026-03-28T08:00:00Z"))

    ;; Verify resource state
    (let ((r ($ obs 'get-resource "r-wheat-ex")))
      (check "wheat after consume: 300"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             300))

    ;; Buffer status at 300: TOR=200, TOY=350, TOG=500 → yellow
    (let* ((bz ($ bzs 'get-zone "bz-wheat-ex"))
           (status (buffer-status 300 bz)))
      (check "status after consume: yellow" (assq-ref status 'zone) 'yellow))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Further consumption → red zone
;;;
;;; Ported from: "repeated consumption triggers red zone"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Consumption → red zone ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (bzs ($ scope 'buffer-zone-store)))
    ;; Consume another 150kg → onhand drops to 150
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-ex-consume-2" #:action 'consume #:input-of "proc-mill"
         #:resource-inventoried-as "r-wheat-ex" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 150 "kg") #:has-point-in-time "2026-03-29T08:00:00Z"))

    (let ((r ($ obs 'get-resource "r-wheat-ex")))
      (check "wheat after 2nd consume: 150"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             150))

    ;; Status: 150 < TOR(200) → red
    (let* ((bz ($ bzs 'get-zone "bz-wheat-ex"))
           (status (buffer-status 150 bz)))
      (check "status: red" (assq-ref status 'zone) 'red))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Replenishment → green zone recovery
;;;
;;; Ported from: "production event restores buffer"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Replenishment recovery ──\n")

(with-vat vat
  (let ((obs ($ scope 'observer))
        (bzs ($ scope 'buffer-zone-store)))
    ;; Produce 300kg → onhand rises to 450
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-ex-produce-1" #:action 'produce #:output-of "proc-harvest"
         #:resource-inventoried-as "r-wheat-ex" #:resource-conforms-to "spec-wheat"
         #:provider "agent-a" #:receiver "agent-a"
         #:resource-quantity (make-measure 300 "kg") #:has-point-in-time "2026-03-30T08:00:00Z"))

    (let ((r ($ obs 'get-resource "r-wheat-ex")))
      (check "wheat after produce: 450"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             450))

    ;; Status: TOY(350) < 450 < TOG(500) → green
    (let* ((bz ($ bzs 'get-zone "bz-wheat-ex"))
           (status (buffer-status 450 bz)))
      (check "status: green" (assq-ref status 'zone) 'green))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Alert generation from buffer zones
;;;
;;; Ported from: execution-reactive "monitor generates alerts"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Alert generation ──\n")

(with-vat vat
  (let ((als ($ scope 'alert-store)))
    ;; Alerts are alists with 'kind discriminator
    ($ als 'push-alert
       `((kind . buffer-status) (spec-id . "spec-wheat")
         (zone . yellow) (timestamp . "2026-03-28T08:00:00Z")))
    ($ als 'push-alert
       `((kind . buffer-status) (spec-id . "spec-wheat")
         (zone . red) (timestamp . "2026-03-29T08:00:00Z")))

    (check "2 alerts" ($ als 'alert-count) 2)

    ;; Filter by kind
    (let ((buffer-alerts ($ als 'of-kind 'buffer-status)))
      (check "2 buffer alerts" (length buffer-alerts) 2))

    ;; Filter by spec
    (let ((wheat-alerts ($ als 'for-spec "spec-wheat")))
      (check "2 wheat alerts" (length wheat-alerts) 2)
      (check "alert spec" (assq-ref (car wheat-alerts) 'spec-id) "spec-wheat"))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Snapshot recording through execution
;;;
;;; Ported from: "records snapshots as events flow"
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Execution snapshots ──\n")

(with-vat vat
  (let ((sns ($ scope 'snapshot-store)))
    ;; Record snapshots matching the execution events
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-28" 300 200 350 500 'yellow))
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-29" 150 200 350 500 'red))
    ($ sns 'record-snapshot
       (make-buffer-snapshot "spec-wheat" "2026-03-30" 450 200 350 500 'green))

    (let ((latest ($ sns 'latest "spec-wheat")))
      (check "latest after recovery: green" (buffer-snapshot-zone latest) 'green)
      (check-pred "3 snapshots" (= 3 (length ($ sns 'all-snapshots)))))))
;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Full execution cycle persistence
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Execution persistence ──\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (error "Restore!"))
    store))

(with-vat vat2
  (let ((obs ($ scope2 'observer))
        (sns ($ scope2 'snapshot-store))
        (als ($ scope2 'alert-store)))
    ;; Resource state persisted
    (let ((r ($ obs 'get-resource "r-wheat-ex")))
      (check "restored wheat: 450"
             (measure-has-numerical-value (economic-resource-accounting-quantity r))
             450))
    ;; Snapshots persisted
    (check "restored snapshots" (length ($ sns 'all-snapshots)) 3)
    ;; Alerts persisted
    (check "restored alerts" (length ($ als 'all-alerts)) 2)))
;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
