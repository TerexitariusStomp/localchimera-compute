;;; test-host-facts-counts.scm — a probe's snapshot is a count of the host's stock.
;;;
;;; docs/observation/readings-are-counts.md §1.6 (4): cores and gigabytes are
;;; stocks. `sync-host-facts!` keeps the live registry as the fast read of the
;;; current snapshot and now also COUNTS each capacity total on the scope's
;;; observer (`count-host-stock!`): the first count mints the resource with a
;;; `raise`, a later snapshot that agrees leaves no event, one that disagrees
;;; lands the difference as a `raise` or `lower`. So the event log holds the
;;; history of what changed, and the reading fold's `drift` reads it.
;;;
;;; Run:  guile -q -L module tests/planner/test-host-facts-counts.scm

(use-modules (playnet test harness) (playnet planner observation host-facts) (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner observation host-facts)
             (playnet planner pools reading-fold)
             ((playnet planner vf schemas) #:select (economic-resource-onhand-quantity measure-has-numerical-value
                                                  economic-event-action economic-event-resource-quantity))
             (goblins) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-6))
(define (facts cores mem-total)
  `((host . "box") (cores . ,cores) (mem-total-gb . ,mem-total) (mem-available-gb . 4.0)
    (load-1m . 0.5) (services . ())))

(define vat (spawn-vat))
(with-vat vat
  (let* ((scope (spawn-scope-root "Box Commune")) (obs ($ scope 'observer)))
    (define (onhand rid) (let ((r ($ obs 'get-resource rid)))
                           (and r (measure-has-numerical-value (economic-resource-onhand-quantity r)))))
    (define (events) (filter (lambda (e) (memq (economic-event-action e) '(raise lower))) ($ obs 'all-events)))

    (display "\n── the first snapshot mints the stock ──\n")
    (sync-host-facts! scope (facts 4 8.0))
    (check "the compute stock is on hand at 4 cores" (approx= (onhand "box:compute") 4.0))
    (check "the memory stock is on hand at 8 GB" (approx= (onhand "box:memory") 8.0))
    (check "two raise events, one per kind" (= 2 (length (events))))

    (display "\n── a snapshot that agrees leaves nothing ──\n")
    (sync-host-facts! scope (facts 4 8.0))
    (check "no new event" (= 2 (length (events))))
    (check "the registry still answers the snapshot"
           (approx= 4.0 ($ ($ ($ scope 'live-registry) 'get "box:compute") 'total)))

    (display "\n── a snapshot that disagrees lands the difference ──\n")
    (sync-host-facts! scope (facts 6 7.5))
    (check "compute went up by two: a raise of 2" (approx= (onhand "box:compute") 6.0))
    (check "memory went down by half a gigabyte: a lower of 0.5" (approx= (onhand "box:memory") 7.5))
    (check "the event log holds exactly the adjustments between snapshots"
           (equal? (map (lambda (e) (cons (economic-event-action e)
                                          (measure-has-numerical-value (economic-event-resource-quantity e))))
                        (events))
                   '((raise . 4.0) (raise . 8.0) (raise . 2.0) (lower . 0.5))))
    (check "the registry answers the latest snapshot"
           (approx= 6.0 ($ ($ ($ scope 'live-registry) 'get "box:compute") 'total)))

    (display "\n── the reading fold reads the drift ──\n")
    (let ((own (scope-own-readings scope "box" #f)))
      (check "compute drift: two counts, net +6 (the mint and the rise), mean |q| 3"
             (equal? (drift-of own "spec:compute") '(2 3.0 6.0)))
      (check "memory drift: net +7.5 with one lower in it"
             (equal? (drift-of own "spec:memory") '(2 4.25 7.5)))
      (check "no cell names a person, every key ends in the scope"
             (every (lambda (c) (equal? (last (car c)) "box")) own)))))

(test-summary!)
