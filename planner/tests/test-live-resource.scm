;;; test-live-resource.scm — Tests for infrastructure as live-resource actors
;;;
;;; Exercises:
;;;   1. ^live-resource actor: reserve, release, resize
;;;   2. ^live-registry: register, get, remove
;;;   3. Planning integration: planner sees available, not total
;;;   4. Transactional: reserve + record-event in one vat turn
;;;   5. Persistence round-trip

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


;; =========================================================================
;; 1. Live-resource actor basics
;; =========================================================================

(display "=== Phase 1: ^live-resource basics ===\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Compute Commune"))
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
       (make-resource-specification "spec:compute" "CPU Hours" #f #f
                                   '("infrastructure" "compute")
                                   "cpu-hours" #f #f #f #f #f))

    ;; Seed the observer with total capacity via 'raise event
    ;; 29 fields: id action input-of output-of resource-inventoried-as
    ;;   to-resource-inventoried-as resource-conforms-to resource-classified-as
    ;;   provider receiver resource-quantity effort-quantity
    ;;   has-beginning has-end has-point-in-time created
    ;;   at-location to-location state fulfills satisfies corrects
    ;;   realization-of settles note in-scope-of previous-event
    ;;   exclude-from-adu market-value
    ($ obs 'record-event
       (make-economic-event
         "ev-raise-cpu" 'raise #f #f
         "cpu-1" #f "spec:compute" '("infrastructure")
         "agent-cluster" "agent-cluster"
         (make-measure 16 "cpu-hours") #f
         #f #f "2026-04-01T00:00:00Z" #f
         "dc-1" #f #f #f #f #f
         #f #f #f #f #f #f #f))

    ;; Verify observer tracks total=16
    (let ((r ($ obs 'get-resource "cpu-1")))
      (check "observer resource exists" (not (not r)))
      (check "observer total 16"
        (= 16 (measure-has-numerical-value
                (economic-resource-accounting-quantity r)))))

    ;; Lift facts WITHOUT live-registry — planner sees total (16)
    (let* ((facts-no-live (lift-planning-facts rs obs ps #f #f))
           (inv (find (lambda (f) (and (eq? (car f) 'inventory)
                                       (equal? (cadr f) "cpu-1")))
                      facts-no-live)))
      (check "without live-registry: inventory 16" (= 16 (cadddr inv))))

    ;; Lift facts WITH live-registry — planner sees available (12)
    (let* ((facts-live (lift-planning-facts rs obs ps #f lr))
           (inv (find (lambda (f) (and (eq? (car f) 'inventory)
                                       (equal? (cadr f) "cpu-1")))
                      facts-live)))
      (check "with live-registry: inventory 12" (= 12 (cadddr inv))))))


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
           "ev-use-cpu-1" 'use "proc-inference" #f
           "cpu-1" #f "spec:compute" #f
           "agent-cluster" "agent-cluster"
           (make-measure 3 "cpu-hours") #f
           #f #f "2026-04-01T01:00:00Z" #f
           #f #f #f #f #f #f
           #f #f #f #f #f #f #f))

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
    scope-env
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
