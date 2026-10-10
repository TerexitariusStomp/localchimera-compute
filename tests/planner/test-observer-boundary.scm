;;; test-observer-boundary.scm — what the ledger admits at its door.
;;;
;;; The observer's fold is the project's accounting. Three things hold at its
;;; boundary, so no door has to remember them:
;;;
;;;   IDEMPOTENCY   The event log is a set keyed by event id. The same event
;;;                 delivered twice is one event; a different event under a used
;;;                 id is refused (events are immutable records).
;;;   QUANTITIES    A quantity is a finite number, negative only on an event that
;;;                 `corrects` another. Effort never moves stock (VF actions.md:
;;;                 "The event's effortQuantity does not affect economic resources").
;;;   UNITS         An event's quantity is added to a resource in the resource's
;;;                 unit: 500 g on a kilogram stock is half a kilogram; litres on
;;;                 a kilogram stock refuse.
;;;
;;; Pure kernel (observer-record-event): no vat. A resource comes into being the
;;; way VF says, by an event (a `raise`, the opening balance).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-observer-boundary.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet test events)
             (playnet observation observer)
             (playnet observation observer)
             (goblins utils hashmap)
             (srfi srfi-1))


;; a 100 kg flour stock, opened by an event
(define (flour) (fold-events (list (ev "open" 'raise #:rid "f1" #:spec "flour" #:q 100.0))))

;; ── idempotency ──────────────────────────────────────────────────────────────
(display "\n── the event log is a set keyed by id ──\n")
(let* ((e  (ev "c1" 'consume #:rid "f1" #:spec "flour" #:q 10.0 #:input "P"))
       (s1 (cdr (try-record (flour) e)))
       (r2 (try-record s1 e))
       (s2 (cdr r2)))
  (check "the first delivery applies"                 (near? (onhand s1 "f1") 90.0) #t)
  (check "the same event again is accepted"           (car r2) 'ok)
  (check "…and changes nothing: stock still 90"       (near? (onhand s2 "f1") 90.0) #t)
  (check "…and the log holds it once"                 (= (event-count s2) (event-count s1)) #t)
  (check "…and the resource's index lists it once"
         (length (hashmap-ref (os-idx-by-resource s2) "f1" '())) 2)       ; the opening raise and c1
  (let ((r3 (try-record s1 (ev "c1" 'consume #:rid "f1" #:spec "flour" #:q 3.0 #:input "P"))))
    (check "a different event under a used id is refused" (car r3) 'error)
    (check "…and the stock stays 90"                      (near? (onhand s1 "f1") 90.0) #t)))

;; an event whose provider and receiver are one agent belongs to that agent once
(let* ((s (cdr (try-record (flour) (ev "self" 'consume #:rid "f1" #:spec "flour" #:q 1.0 #:input "P"
                                       #:provider "alice" #:receiver "alice")))))
  (check "a self-scoped event is indexed once under its agent"
         (length (hashmap-ref (os-idx-by-agent s) "alice" '())) 1))

;; ── quantities ───────────────────────────────────────────────────────────────
(display "\n── a quantity is a finite number ──\n")
(for-each
 (lambda (label q)
   (let* ((s0 (flour))
          (r (try-record s0 (ev "bad" 'consume #:rid "f1" #:spec "flour" #:q q #:input "P"))))
     (check (string-append label " is refused") (car r) 'error)))
 '("+nan.0" "+inf.0" "-inf.0") (list +nan.0 +inf.0 -inf.0))
(let* ((s0 (flour))
       (_  (try-record s0 (ev "nan" 'consume #:rid "f1" #:spec "flour" #:q +nan.0 #:input "P")))
       (s1 (cdr (try-record s0 (ev "p1" 'produce #:rid "f1" #:spec "flour" #:q 10.0 #:output "P")))))
  (check "a refused NaN does not poison the stock"    (near? (onhand s1 "f1") 110.0) #t))

(display "\n── negative quantities belong to corrections ──\n")
(let* ((s0 (flour))
       (r1 (try-record s0 (ev "neg" 'consume #:rid "f1" #:spec "flour" #:q -10.0 #:input "P"))))
  (check "a negative consume that corrects nothing is refused" (car r1) 'error)
  (check "…and the stock stays 100"                   (near? (onhand s0 "f1") 100.0) #t))
(let* ((s1 (cdr (try-record (flour) (ev "c1" 'consume #:rid "f1" #:spec "flour" #:q 10.0 #:input "P"))))
       (r2 (try-record s1 (ev "c1b" 'consume #:rid "f1" #:spec "flour" #:q 10.0 #:input "P" #:corrects "c1"))))
  (check "an event that corrects another is accepted" (car r2) 'ok))
(check "a zero quantity is a no-op, not an error"
       (car (try-record (flour) (ev "z" 'consume #:rid "f1" #:spec "flour" #:q 0.0 #:input "P"))) 'ok)

(display "\n── effort never moves stock ──\n")
(let* ((s1 (cdr (try-record (flour)
                 (ev "w1" 'consume #:rid "f1" #:spec "flour" #:effort '(5.0 . "hour") #:input "P")))))
  (check "an effort-only consume leaves the stock at 100" (near? (onhand s1 "f1") 100.0) #t))

;; ── units ────────────────────────────────────────────────────────────────────
(display "\n── an event's quantity is added in the resource's unit ──\n")
(check "500 g consumed from 100 kg leaves 99.5 kg"
       (near? (onhand (cdr (try-record (flour) (ev "g1" 'consume #:rid "f1" #:spec "flour" #:q 500.0 #:unit "g" #:input "P"))) "f1") 99.5) #t)
(check "5 lb produced onto 100 kg adds 2.26796 kg"
       (< (abs (- (onhand (cdr (try-record (flour) (ev "l1" 'produce #:rid "f1" #:spec "flour" #:q 5.0 #:unit "lb" #:output "P"))) "f1")
                  102.26796)) 1e-4) #t)
(let ((s (fold-events (list (ev "o1" 'raise #:rid "n1" #:spec "flour" #:q 1000.0 #:unit "g")
                            (ev "p2" 'produce #:rid "n1" #:spec "flour" #:q 2.0 #:unit "kg" #:output "P")))))
  (check "a stock born in grams takes 2 kg as 2000 g"  (near? (onhand s "n1") 3000.0) #t)
  (check "…and keeps its own unit"                     (unit-of s "n1") "g"))
(check "hour and hours are one unit"
       (near? (onhand (cdr (try-record (fold-events (list (ev "o2" 'raise #:rid "h1" #:spec "hrs" #:q 10.0 #:unit %effort-unit)))
                                       (ev "u1" 'consume #:rid "h1" #:spec "hrs" #:q 2.0 #:unit %effort-unit #:input "P"))) "h1") 8.0) #t)
(let ((r (try-record (flour) (ev "v1" 'consume #:rid "f1" #:spec "flour" #:q 2.0 #:unit "litre" #:input "P"))))
  (check "litres cannot be taken from a kilogram stock" (car r) 'error))
;; the planner's rows carry the placeholder unit "unit" until the doors state the
;; specification's own unit: a placeholder reads in the resource's unit
(check "the placeholder unit \"unit\" reads in the resource's own unit"
       (near? (onhand (cdr (try-record (flour) (ev "pl" 'consume #:rid "f1" #:spec "flour" #:q 10.0 #:unit "unit" #:input "P"))) "f1") 90.0) #t)

;; a quantity is read in a stock's unit where it is APPLIED to that stock: a thing
;; of 3 kg put into a box counted in hours leaves the box's count alone, and the
;; box has no kilograms to refuse
(display "\n── a unit is checked where the quantity is applied ──\n")
(let* ((s0 (fold-events (list (ev "ob" 'raise #:rid "box" #:spec "case" #:q 4.0 #:unit %effort-unit)
                              (ev "oi" 'raise #:rid "i1" #:spec "bread" #:q 3.0))))
       (r  (try-record s0 (ev "cmb" 'combine #:rid "i1" #:to-rid "box" #:spec "bread" #:q 3.0 #:input "P"))))
  (check "combining 3 kg into a box counted in hours is accepted" (car r) 'ok)
  (check "…the box's count is untouched"  (near? (onhand (cdr r) "box") 4.0) #t)
  (check "…and the box is counted as before" (near? (onhand (cdr r) "box") 4.0) #t))


;; ── effort is a duration ─────────────────────────────────────────────────────
(display "\n── an effort quantity is stated in a unit of time ──\n")
(for-each
 (lambda (u)
   (check (string-append u " is no unit of time, and the event is refused")
          (car (try-record (empty-observer-state)
                           (ev "w" 'work #:spec "weld" #:effort (cons 5.0 u) #:provider "ana" #:input "P")))
          'error))
 '("widgets" "kg"))
(check "minutes are"
       (car (try-record (empty-observer-state)
                        (ev "w" 'work #:spec "weld" #:effort (cons 90.0 "minute") #:provider "ana" #:input "P")))
       'ok)

;; ── a use of a stock in hours leaves the stock's figure alone, wherever it is read ──
(display "\n── what an event does to a stock is read the way it was applied ──\n")
(let* ((st  (flour))
       (use (ev "u1" 'use #:rid "f1" #:spec "flour" #:q 2.0 #:unit %effort-unit #:input "P")))
  (check "a use measured in hours is accepted on a kilogram stock" (car (try-record st use)) 'ok)
  (check "…and moves none of it, as the fold applied it"
         (event-onhand-delta use "f1" (resource st "f1")) 0))

(test-summary!)
