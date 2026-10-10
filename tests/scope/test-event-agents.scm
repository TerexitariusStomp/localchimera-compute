;;; test-event-agents.scm — a stock event names the agent accountable for the stock.
;;;
;;; ValueFlows gives every EconomicEvent a provider and a receiver. An event that draws on
;;; a lot (a consume, a pickup) is given by the lot's primary accountable; an
;;; event that lands in a lot (a produce into a lot that stands, a dropoff) is received by
;;; that lot's primary accountable. The agent accountable on both sides is one, so no transfer
;;; of rights arises: the lot keeps its accountable.
;;;
;;;   CONSUME   the lot it draws on names its accountable agent as provider and as receiver
;;;   SPLIT     a draw over two lots is two events, each naming its own lot's accountable agent
;;;   PRODUCE   a produce into a lot that stands names that lot's accountable agent; into a place
;;;             with no lot, the event names no agent (the stock has no accountable agent yet)
;;;   STANDS    the accountable agent of every lot is the same before and after
;;;   CARRY     a pickup and a dropoff name the cargo's accountable agent
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-event-agents.scm

(use-modules (playnet test harness)
             (playnet test books)
             (playnet vf schemas) (srfi srfi-1) (srfi srfi-11)
             (playnet scope live)
             (goblins) (goblins vat)
             (srfi srfi-1) (srfi srfi-13))

(define (event-of obs id)
  (find (lambda (e) (equal? (economic-event-id e) id)) ($ obs 'all-events)))
(define (agents e) (list (economic-event-provider e) (economic-event-receiver e)))
(define (accountable-of obs id) (economic-resource-primary-accountable ($ obs 'get-resource id)))

(display "\n── CONSUME: the lot's accountable agent gives and receives ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w-ana" "water" 50.0 "A" #:acct "ana"))
      (let ((ev (event-of obs (confirm scope (flow-row "mc|c" 'consume "water" 20.0 "A" #:in "p1")))))
        (check "a consume names the lot's accountable agent as provider and receiver" (agents ev) '("ana" "ana"))
        (check "…the stock left the lot" (onhand-of obs "w-ana") 30.0)
        (check "STANDS: the lot has the accountable agent it had" (accountable-of obs "w-ana") "ana")))))

(display "\n── SPLIT: a draw over two lots names each lot's accountable agent ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w-ana" "water" 10.0 "A" #:acct "ana"))
      ($ obs 'seed-resource (res "w-bo" "water" 10.0 "A" #:acct "bo"))
      (let* ((id (confirm scope (flow-row "mc|s" 'consume "water" 15.0 "A" #:in "p1")))
             (evs (filter (lambda (e) (string-prefix? id (economic-event-id e))) ($ obs 'all-events))))
        (check "two events" (length evs) 2)
        (check "each names the accountable agent of the lot it drew on"
               (sort (map (lambda (e) (or (car (agents e)) "-")) evs) string<?) '("ana" "bo"))
        (check "…as provider and receiver both"
               (every (lambda (e) (apply equal? (agents e))) evs) #t)))))

(display "\n── PRODUCE: a lot that stands has an accountable agent; a new place has none ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w-ana" "water" 10.0 "A" #:acct "ana"))
      (let ((into (event-of obs (confirm scope (flow-row "mc|p" 'produce "water" 5.0 "A" #:out "p1"))))
            (fresh (event-of obs (confirm scope (flow-row "mc|q" 'produce "water" 5.0 "B" #:out "p1")))))
        (check "a produce into a standing lot names its accountable agent" (agents into) '("ana" "ana"))
        (check "…and the lot grew" (onhand-of obs "w-ana") 15.0)
        (check "a produce into a place with no lot names no agent" (agents fresh) '(#f #f))
        (check "STANDS: the standing lot kept its accountable agent" (accountable-of obs "w-ana") "ana")))))

(display "\n── CARRY: pickup and dropoff name the cargo's accountable agent ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w-ana" "water" 40.0 "A" #:acct "ana"))
      (let ((pu (event-of obs (confirm scope (flow-row "mc|pu" 'pickup "water" 10.0 "A" #:in "run1"))))
            (dr (event-of obs (confirm scope (flow-row "mc|do" 'dropoff "water" 10.0 "B" #:out "run1")))))
        (check "a pickup names the accountable agent" (agents pu) '("ana" "ana"))
        (check "a dropoff names the accountable agent" (agents dr) '("ana" "ana"))
        (check "the total is conserved, the accountable agent stands"
               (list (spec-total obs "water") (accountable-of obs "w-ana"))
               '(40.0 "ana"))))))

(test-summary!)
