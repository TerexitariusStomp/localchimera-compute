;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-host-facts.scm — the machine reads itself: herd/ps/proc text →
;;; placement ledger → ^live-resource facts in the scope's live-registry.
;;;
;;; Everything runs from fixture strings (the parsers are pure), so this
;;; passes in the pure test environment with no shepherd and no /proc
;;; dependence.

(use-modules (localchimera test harness))
(use-modules (localchimera observation host-facts) (localchimera scope root) (srfi srfi-1))
(use-modules ((localchimera observation facts-sync) #:select (handle-snapshot!)))
(use-modules (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

;; =========================================================================
;; Fixtures — the exact text shapes the live commands emit
;; =========================================================================

(define meminfo-fixture
  "MemTotal:        7648256 kB
MemFree:          512000 kB
MemAvailable:    4194304 kB
Buffers:          123456 kB
")

(define loadavg-fixture "1.50 0.80 0.40 2/345 12345\n")

;; shepherd's sectioned listing (0.10-style)
(define herd-sectioned-fixture
  "Started:
 + root
 + mosquitto
 + dev-bridge
Stopped:
 - qgis-worker
One-shot:
 * host-name
")

;; the older one-line listing
(define herd-oneline-fixture
  "Started: (root mosquitto dev-bridge)\nStopped: (qgis-worker)\n")

;; shepherd 0.10 shape (the box's) and the older Running-value shape
(define herd-mosquitto-status
  "● Status of mosquitto:
  It is running since 12:00:01 PM (2 hours ago).
  Main PID: 200
  It is enabled.
")

(define herd-oldstyle-status
  "Status of mosquitto:
  It is running since 12:00:01 PM (2 hours ago).
  Running value is 200.
")

(define herd-devbridge-status
  "Status of dev-bridge:
  It is running since 12:00:02 PM (2 hours ago).
  Running value is 300.
")

;; pid ppid rss(kB) pcpu — mosquitto is pid 200 (no children);
;; dev-bridge is 300 with a child 301 (the launched agent).
(define ps-fixture
  "    1     0  10240  0.0
  200     1 524288  25.0
  300     1 262144  10.0
  301   300 262144  15.0
  999     1  51200  5.0
")

;; =========================================================================
;; 1. Parsers
;; =========================================================================

(display "=== Phase 1: parsers ===\n")

(let ((mem (parse-meminfo meminfo-fixture)))
  (check "MemTotal → GB" (< (abs (- (assq-ref mem 'total-gb) 7.294)) 0.01))
  (check "MemAvailable → GB" (= 4.0 (assq-ref mem 'available-gb))))

(check "loadavg 1m" (= 1.5 (parse-loadavg loadavg-fixture)))

(check "herd sectioned"
       (equal? '("root" "mosquitto" "dev-bridge")
               (parse-herd-running herd-sectioned-fixture)))
(check "herd one-line"
       (equal? '("root" "mosquitto" "dev-bridge")
               (parse-herd-running herd-oneline-fixture)))

(check "Main PID → pid" (= 200 (parse-running-value herd-mosquitto-status)))
(check "Running value → pid" (= 200 (parse-running-value herd-oldstyle-status)))
(check "non-process running value"
       (not (parse-running-value "Status of x:\n  Running value is #t.\n")))

(let ((table (parse-ps-table ps-fixture)))
  (check "ps rows" (= 5 (length table)))
  (let ((solo (process-tree-usage table 200))
        (tree (process-tree-usage table 300)))
    (check "solo rss 0.5 GB" (< (abs (- (car solo) 0.5)) 0.001))
    (check "solo cpu 0.25 cores" (< (abs (- (cdr solo) 0.25)) 0.001))
    (check "tree rss folds child (0.5 GB)" (< (abs (- (car tree) 0.5)) 0.001))
    (check "tree cpu folds child (0.25 cores)" (< (abs (- (cdr tree) 0.25)) 0.001))))

;; =========================================================================
;; 2. Placement ledger — the attribution algebra
;; =========================================================================

(display "\n=== Phase 2: placement ledger ===\n")

(define facts-fixture
  ;; What read-host-facts would assemble from the fixtures above:
  ;; 4 cores under 1.5 load; 7.294 GB total, 4.0 GB kernel-available;
  ;; two services with process-tree usage.
  `((host . "box")
    (cores . 4)
    (mem-total-gb . 7.294)
    (mem-available-gb . 4.0)
    (load-1m . 1.5)
    (services . (((name . "mosquitto") (pid . 200)
                  (rss-gb . 0.5) (cpu-cores . 0.25))
                 ((name . "dev-bridge") (pid . 300)
                  (rss-gb . 0.5) (cpu-cores . 0.25))))))

(define ledger (placement-ledger facts-fixture))
(define c-entry (assq-ref ledger 'compute))
(define m-entry (assq-ref ledger 'memory))

(define (rsv-of entry name)
  (assoc-ref (assq-ref entry 'reservations) name))

;; compute: total 4, kernel-available 2.5, services sum 0.5 → other 1.0
(check "compute total" (= 4 (assq-ref c-entry 'total)))
(check "compute service reservation" (= 0.25 (rsv-of c-entry "mosquitto")))
(check "compute other = load beyond services"
       (< (abs (- (rsv-of c-entry "other") 1.0)) 0.001))
(check "compute available = kernel truth"
       (< (abs (- (assq-ref c-entry 'available) 2.5)) 0.001))
(check "compute invariant total = available + Σ reservations"
       (< (abs (- (assq-ref c-entry 'total)
                  (+ (assq-ref c-entry 'available)
                     (fold + 0 (map cdr (assq-ref c-entry 'reservations))))))
          1e-9))

;; memory: total 7.294, kernel-available 4.0, services sum 1.0 → other 2.294
(check "memory other = used beyond services"
       (< (abs (- (rsv-of m-entry "other") 2.294)) 0.001))
(check "memory invariant total = available + Σ reservations"
       (< (abs (- (assq-ref m-entry 'total)
                  (+ (assq-ref m-entry 'available)
                     (fold + 0 (map cdr (assq-ref m-entry 'reservations))))))
          1e-9))

;; over-attribution (shared-page RSS double count): availability yields
(let* ((over `((host . "tiny") (cores . 1) (load-1m . 0.0)
               (mem-total-gb . 1.0) (mem-available-gb . 0.9)
               (services . (((name . "fat") (pid . 1)
                             (rss-gb . 0.5) (cpu-cores . 0.0))))))
       (m (assq-ref (placement-ledger over) 'memory)))
  (check "over-attribution clamps other at 0" (not (assoc-ref (assq-ref m 'reservations) "other")))
  (check "over-attribution: available yields to Σ services"
         (< (abs (- (assq-ref m 'available) 0.5)) 1e-9)))

;; =========================================================================
;; 3. Into the scope — live-registry holds the placement facts
;; =========================================================================

(display "\n=== Phase 3: sync into a scope ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Box Commune"))
    store))

(with-vat vat
  (let* ((synced (sync-host-facts! scope facts-fixture))
         (lr     ($ scope 'live-registry))
         (compute ($ lr 'get "box:compute"))
         (memory  ($ lr 'get "box:memory")))
    (check "two resources synced" (= 2 (length synced)))
    (check "registry holds box:compute" (not (not compute)))
    (check "registry holds box:memory" (not (not memory)))
    (check "compute conforms to spec:compute"
           (equal? "spec:compute" ($ compute 'spec)))
    (check "compute located at host" (equal? "box" ($ compute 'location)))
    (check "compute unit cores" (equal? "cores" ($ compute 'unit)))
    (check "available survives the actor" (< (abs (- ($ compute 'available) 2.5)) 0.001))
    (check "services are named reservations"
           (equal? 0.5 (assoc-ref ($ memory 'reservations) "dev-bridge")))
    ;; the placement question, answered off the actor:
    (check "placement ledger readable" (= 3 (length ($ memory 'reservations))))
    ;; a planner-style reserve against what the probe says is free
    (let ((rsv ($ memory 'reserve 2.0)))
      (check "reserve against probed free capacity" (string? rsv))
      (check "available drops" (< (abs (- ($ memory 'available)
                                          (- 4.0 2.0))) 0.001)))))

;; re-sync replaces the snapshot under the same id
(with-vat vat
  (sync-host-facts! scope facts-fixture)
  (let ((memory ($ ($ scope 'live-registry) 'get "box:memory")))
    (check "re-sync refreshes under the same id"
           (< (abs (- ($ memory 'available) 4.0)) 0.001))))

;; =========================================================================
;; 4. The MQTT consumer — handle-snapshot! (facts-sync.scm)
;; =========================================================================

(display "\n=== Phase 4: snapshot handler ===\n")

(check "a snapshot payload syncs"
       (eq? 'synced
            (handle-snapshot! vat (lambda () scope)
                              "localchimera/facts/host/box"
                              (object->string facts-fixture))))

(with-vat vat
  (let ((compute ($ ($ scope 'live-registry) 'get "box:compute")))
    (check "handler landed the reading in the registry"
           (< (abs (- ($ compute 'available) 2.5)) 0.001))))

(check "steward scope not up yet → held"
       (eq? 'no-scope
            (handle-snapshot! vat (lambda () #f)
                              "localchimera/facts/host/box"
                              (object->string facts-fixture))))

(check "garbage payload → unreadable, no crash"
       (eq? 'unreadable
            (handle-snapshot! vat (lambda () scope)
                              "localchimera/facts/host/box" "{json, not sexp")))

(check "non-facts sexp → unreadable"
       (eq? 'unreadable
            (handle-snapshot! vat (lambda () scope)
                              "localchimera/facts/host/box" "(1 2 3)")))

(test-summary!)
