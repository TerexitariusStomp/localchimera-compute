;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-live-resource.scm — Tests for infrastructure as live-resource actors
;;;
;;; Exercises:
;;;   1. ^live-resource actor: reserve, release, resize
;;;   2. ^live-registry: register, get, remove
;;;   3. Planning integration: planner sees available, not total
;;;   4. Transactional: reserve + record-event in one vat turn
;;;   5. Persistence round-trip

(use-modules (playnet solve records))
(use-modules (playnet solve world))
(use-modules (playnet test harness))
(use-modules (playnet observation live-registry) (playnet observation live-resource) (playnet scope root) (playnet vf schemas))
(use-modules ((playnet solve engine) #:select (declare-world! lg cell))   ; the door, for the live-avail composition check
             ((playnet solve ingest) #:select (ingest-stock!))
             ((playnet solve compile) #:select (svc-good)))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))
;; =========================================================================
;; 1. Live-resource actor basics
;; =========================================================================

(display "=== Phase 1: ^live-resource basics ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (spawn-scope-root "Compute Commune"))
    store))

(with-vat vat
  (let ((lr ($ scope 'live-registry)))
    (check "live-registry exists" (not (not lr)))
    (check "empty registry" (null? ($ lr 'all-ids)))))

;; Spawn a live compute resource
(define live-ref #f)
(define rsv-id #f)

(with-vat vat
  (let ((live (spawn ^live-resource
                "cpu-1" "spec:compute" 16 16 "cpu-hours" "dc-1" '())))
    (set! live-ref live)

    (check "id" (equal? "cpu-1" ($ live 'id)))
    (check "spec" (equal? "spec:compute" ($ live 'spec)))
    (check "total 16" (= 16 ($ live 'total)))
    (check "available 16" (= 16 ($ live 'available)))
    (check "unit" (equal? "cpu-hours" ($ live 'unit)))
    (check "location" (equal? "dc-1" ($ live 'location)))
    (check "no reservations" (null? ($ live 'reservations)))))
;; =========================================================================
;; 2. Reserve and release
;; =========================================================================

(display "\n=== Phase 2: Reserve and release ===\n")

(with-vat vat
  ;; Reserve 4 cpu-hours
  (set! rsv-id ($ live-ref 'reserve 4))
  (check "reservation returned" (string? rsv-id))
  (check "available 12" (= 12 ($ live-ref 'available)))
  (check "total unchanged" (= 16 ($ live-ref 'total)))
  (check "1 reservation" (= 1 (length ($ live-ref 'reservations))))

  ;; Reserve 6 more
  (let ((rsv2 ($ live-ref 'reserve 6)))
    (check "available 6" (= 6 ($ live-ref 'available)))
    (check "2 reservations" (= 2 (length ($ live-ref 'reservations))))

    ;; Release the second reservation
    ($ live-ref 'release rsv2)
    (check "available 12 after release" (= 12 ($ live-ref 'available)))
    (check "1 reservation after release" (= 1 (length ($ live-ref 'reservations))))))

;; Insufficient capacity
(with-vat vat
  (check "insufficient capacity errors"
    (catch #t
      (lambda () ($ live-ref 'reserve 20) #f)
      (lambda _args #t))))
;; =========================================================================
;; 3. Resize (elastic scaling)
;; =========================================================================

(display "\n=== Phase 3: Resize ===\n")

(with-vat vat
  ;; Currently: total=16, available=12 (4 reserved)
  ($ live-ref 'resize 32)
  (check "total 32" (= 32 ($ live-ref 'total)))
  (check "available 28" (= 28 ($ live-ref 'available)))

  ;; Scale back down
  ($ live-ref 'resize 16)
  (check "total 16 again" (= 16 ($ live-ref 'total)))
  (check "available 12 again" (= 12 ($ live-ref 'available))))
;; =========================================================================
;; 4. Registry integration
;; =========================================================================

(display "\n=== Phase 4: Live registry ===\n")

(with-vat vat
  (let ((lr ($ scope 'live-registry)))
    ;; Register the live-resource
    ($ lr 'register "cpu-1" live-ref)
    (check "registered" ($ lr 'has? "cpu-1"))
    (check "get returns actor" (equal? live-ref ($ lr 'get "cpu-1")))
    (check "1 id" (= 1 (length ($ lr 'all-ids))))

    ;; Can query through registry
    (check "available via registry" (= 12 ($ ($ lr 'get "cpu-1") 'available)))))
;; =========================================================================
;; 5. Planning integration — planner sees available, not total
;; =========================================================================

(display "\n=== Phase 5: Planning facts integration ===\n")

(with-vat vat
  (let ((rs  ($ scope 'recipe-store))
        (obs ($ scope 'observer))
        (ps  ($ scope 'plan-store))
        (lr  ($ scope 'live-registry)))

    ;; Add a resource spec for compute
    ($ rs 'add-resource-spec
       (make-resource-specification #:id "spec:compute" #:name "CPU Hours"
                                   #:resource-classified-as '("infrastructure" "compute")
                                   #:default-unit-of-resource "cpu-hours"))

    ;; Seed the observer with total capacity via 'raise event
    ;; 29 fields: id action input-of output-of resource-inventoried-as
    ;;   to-resource-inventoried-as resource-conforms-to resource-classified-as
    ;;   provider receiver resource-quantity effort-quantity
    ;;   has-beginning has-end has-point-in-time created
    ;;   at-location to-location state fulfills satisfies corrects
    ;;   realization-of settles note in-scope-of previous-event
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-raise-cpu" #:action 'raise
         #:resource-inventoried-as "cpu-1" #:resource-conforms-to "spec:compute" #:resource-classified-as '("infrastructure")
         #:provider "agent-cluster" #:receiver "agent-cluster"
         #:resource-quantity (make-measure 16 "cpu-hours") #:has-point-in-time "2026-04-01T00:00:00Z"
         #:at-location "dc-1"))

    ;; Verify observer tracks total=16
    (let ((r ($ obs 'get-resource "cpu-1")))
      (check "observer resource exists" (not (not r)))
      (check "observer total 16"
        (= 16 (measure-has-numerical-value
                (economic-resource-accounting-quantity r)))))

    ;; The live door: the registry as the engine's #:live-avail reading
    ;; (live-availability, threaded plan-from-records → ingest-records! →
    ;; ingest-stock!). A registered resource reads at its reservation-aware
    ;; `available`; anything unregistered reads #f, so the ingest falls back
    ;; to the observer's onhand.
    (let ((avail (live-availability lr)))
      (check "registered resource reads available (12), not total (16)"
             (= 12 (avail "cpu-1")))
      (check "unregistered resource reads #f (onhand fallback)"
             (not (avail "no-such-resource"))))

    ;; …and composed with the engine's ingest, end to end: declare a world
    ;; whose template `use`s the compute spec, ingest the OBSERVER's records
    ;; with the registry as #:live-avail, and the per-period service cap
    ;; renders from the live available (12), not the observer's total (16) —
    ;; a live reading is a level, so it renders per period-hour (12 × 24).
    (let ((tpl (list "p-compute" '(("thing" . 1.0))
                     (list (cons (svc-good "spec:compute") 1.0))
                     0.0 '() '() '() '() '())))
      (declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))
                      #:templates (list tpl))
      (ingest-stock! ($ obs 'all-resources)
                     #:live-avail (live-availability lr))
      (check "ingest renders the live available: Svc cap = 12 × 24"
             (= 288.0 (hash-ref *cap*
                                (lg (svc-good "spec:compute")
                                    (cell "dc-1" 0))
                                0.0))))))
;; =========================================================================
;; 6. Transactional: reserve + record-event in one turn
;; =========================================================================

(display "\n=== Phase 6: Atomic reserve + event ===\n")

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; Reserve 3 more cpu-hours AND record the use event — same turn
    (let ((rsv ($ live-ref 'reserve 3)))
      ($ obs 'record-event
         (make-economic-event
           #:id "ev-use-cpu-1" #:action 'use #:input-of "proc-inference"
           #:resource-inventoried-as "cpu-1" #:resource-conforms-to "spec:compute"
           #:provider "agent-cluster" #:receiver "agent-cluster"
           #:resource-quantity (make-measure 3 "cpu-hours") #:has-point-in-time "2026-04-01T01:00:00Z"))

      ;; Both mutations happened atomically
      (check "available 9 after reserve+event" (= 9 ($ live-ref 'available)))
      (check "observer still total 16"
        (= 16 (measure-has-numerical-value
                (economic-resource-accounting-quantity
                  ($ obs 'get-resource "cpu-1"))))))))
;; =========================================================================
;; 7. Persistence round-trip
;; =========================================================================

(display "\n=== Phase 7: Persistence ===\n")

(define-values (vat2 scope2)
  (spawn-persistent-vat
    scope-root-env
    (lambda () (error "Should restore from store, not create new!"))
    store))

(with-vat vat2
  (let ((lr  ($ scope2 'live-registry))
        (obs ($ scope2 'observer)))

    ;; Registry survived
    (check "restored: registry has cpu-1" ($ lr 'has? "cpu-1"))

    ;; Live-resource state survived
    (let ((live ($ lr 'get "cpu-1")))
      (check "restored: available 9" (= 9 ($ live 'available)))
      (check "restored: total 16" (= 16 ($ live 'total)))
      (check "restored: 2 reservations" (= 2 (length ($ live 'reservations)))))

    ;; Observer state survived
    (check "restored: observer resource"
      (= 16 (measure-has-numerical-value
              (economic-resource-accounting-quantity
                ($ obs 'get-resource "cpu-1")))))))
;; =========================================================================
;; Done
;; =========================================================================

(format #t "\n~a/~a checks passed.\n" pass-count pass-count)
