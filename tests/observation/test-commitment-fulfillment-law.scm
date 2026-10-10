;;; test-commitment-fulfillment-law.scm — the time-axis unfold's law.
;;;
;;; The square (labour-fold.scm header holds the other side):
;;;
;;;                 up / fold                down / unfold
;;;   tree     ^fold-node (totals)     ^unfold-node — law: split-refold
;;;   time     ^observer (events)      the plan     — law: THIS FILE
;;;
;;; A plan unfolds a wanted state into intended events: intent → commitment →
;;; event, VF's own ladder. The unfold's law is that folding the ACTUAL events
;;; back reconstructs the committed value — the identity round trip
;;; split-refold states for the tree, stated for time:
;;;
;;;     fold (events fulfilling c)  =  committed value of c
;;;
;;; and, because the ladder has two rungs, the fold climbs both: fulfilment
;;; flows through the commitment to the intent it satisfies. Where the round
;;; trip is NOT the identity, the difference SURFACES — under-fulfilment as an
;;; unfinished state with its remainder readable, over-fulfilment as a flag
;;; with the true sum kept — never a silent clip or average.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/observation/test-commitment-fulfillment-law.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness)
             (playnet observation observer) (playnet vf schemas) (playnet observation states)
             (playnet observation observer)
             (goblins)
             (srfi srfi-1))

;; the shapes match test-observer-effects' chain section — the same ladder,
;; asked here for its algebra rather than its bookkeeping
(define (work-intent iid hours)
  (make-intent #:id iid #:action 'work #:resource-conforms-to "spec-cook" #:effort-quantity (make-measure hours %effort-unit)
               #:provider "ana" #:receiver "ana"))

(define (work-commitment cid iid hours)
  (make-commitment #:id cid #:action 'work #:input-of "proc-1" #:resource-conforms-to "spec-cook" #:effort-quantity (make-measure hours %effort-unit)
                   #:provider "ana" #:receiver "ana"
                   #:satisfies iid))

(define (work-event eid cid hours)
  (make-economic-event #:id eid #:action 'work #:input-of "proc-1" #:resource-conforms-to "spec-cook"
                       #:provider "ana" #:receiver "ana" #:effort-quantity (make-measure hours %effort-unit) #:has-point-in-time "2026-08-20T12:00:00Z"
                       #:fulfills cid))

(define (fulfilled-of fs) (measure-has-numerical-value
                           (fulfillment-state-total-fulfilled fs)))
(define (committed-of fs) (measure-has-numerical-value
                           (fulfillment-state-total-committed fs)))

(define vat (spawn-vat))

(with-vat vat

  (define (armed-observer cid iid hours)
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'register-intent (work-intent iid hours))
      ($ obs 'register-commitment (work-commitment cid iid hours))
      obs))
  (define (replay! obs evs) (for-each (lambda (e) ($ obs 'record-event e)) evs))

  (display "\n── 1. the round trip is the identity ──\n")
  (define obs-1 (armed-observer "c1" "i1" 10))
  (replay! obs-1 (list (work-event "e1" "c1" 6) (work-event "e2" "c1" 4)))
  (let ((fs ($ obs-1 'get-fulfillment "c1")))
    (check "fold (fulfilling events) = committed value"
           (fulfilled-of fs) (committed-of fs))
    (check "and the state says so: finished, not over"
           (list (fulfillment-state-finished fs)
                 (fulfillment-state-over-fulfilled fs))
           '(#t #f)))

  (display "\n── 2. the fold is order-free ──\n")
  (define obs-2 (armed-observer "c1" "i1" 10))
  (replay! obs-2 (list (work-event "e2" "c1" 4) (work-event "e1" "c1" 6)))
  (let ((a ($ obs-1 'get-fulfillment "c1")) (b ($ obs-2 'get-fulfillment "c1")))
    (check "either order, one fulfilment"
           (list (fulfilled-of b) (fulfillment-state-finished b))
           (list (fulfilled-of a) (fulfillment-state-finished a))))

  (display "\n── 3. under-fulfilment surfaces with its remainder ──\n")
  (define obs-3 (armed-observer "c1" "i1" 10))
  (replay! obs-3 (list (work-event "e1" "c1" 6)))
  (let ((fs ($ obs-3 'get-fulfillment "c1")))
    (check "unfinished, and the remainder is readable"
           (list (fulfillment-state-finished fs)
                 (- (committed-of fs) (fulfilled-of fs)))
           '(#f 4)))

  (display "\n── 4. over-fulfilment surfaces with the true sum ──\n")
  (define obs-4 (armed-observer "c1" "i1" 10))
  (replay! obs-4 (list (work-event "e1" "c1" 6) (work-event "e2" "c1" 7)))
  (let ((fs ($ obs-4 'get-fulfillment "c1")))
    (check "flagged over, sum kept — 13, never clipped to 10"
           (list (fulfillment-state-over-fulfilled fs) (fulfilled-of fs))
           '(#t 13)))

  (display "\n── 5. the fold climbs both rungs of the ladder ──\n")
  (let ((ss ($ obs-1 'get-satisfaction "i1")))
    (check "fulfilment flowed through the commitment to the intent"
           (list (measure-has-numerical-value
                  (satisfaction-state-total-satisfied ss))
                 (satisfaction-state-finished ss))
           '(10 #t))))

(test-summary!)
