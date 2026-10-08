;;; events.scm — events and the pure observer fold, stated once for the suites.
;;;
;;; Every suite that pins the observer's accounting builds events the same way and
;;; folds them through the same kernel (`observer-record-event`), so the builder
;;; and the fold are here, beside `(playnet test harness)` and `(playnet test
;;; scope)`. Nothing here is a vat or a store: a state is the pure
;;; `<observer-state>`, and a resource comes into being as VF says, by an event.
;;;
;;;   (define st (fold-events (list (ev "open" 'raise #:rid "f1" #:spec "flour" #:q 100.0)
;;;                                 (ev "c1" 'consume #:rid "f1" #:spec "flour" #:q 10.0 #:input "P"))))
;;;   (onhand st "f1")            ; => 90.0
;;;   (try-record st (ev …))      ; => (ok . state) | (error . irritants)

(define-module (playnet test events)
  #:use-module (playnet planner observation observer)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner vf serdes) #:select (vf-serialize))
  #:use-module ((playnet utils store-utils) #:select (serialize-hashmap))
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:export (ev fold-events try-record resource onhand unit-of near? event-count
            positional-snapshot))

(define* (ev id action #:key rid to-rid spec q (unit "kg") effort provider receiver
             input output at corrects)
  "An <economic-event> by keyword: RID / TO-RID the resource and the one it moves
   into, Q the resource quantity in UNIT, EFFORT (value . unit) the effort quantity."
  (make-economic-event #:id id #:action action #:input-of input #:output-of output #:resource-inventoried-as rid #:to-resource-inventoried-as to-rid #:resource-conforms-to spec #:provider provider #:receiver receiver
    #:resource-quantity (and q (make-measure q unit)) #:effort-quantity (and effort (make-measure (car effort) (cdr effort))) #:at-location at #:corrects corrects))

(define (fold-events events)
  "The observer state after EVENTS, oldest first, folded through the kernel."
  (fold (lambda (e st)
          (call-with-values (lambda () (observer-record-event st e)) (lambda (st* _) st*)))
        (empty-observer-state) events))

(define (try-record st e)
  "(ok . state) or (error . irritants): the kernel throws on a refused event."
  (catch #t
    (lambda () (call-with-values (lambda () (observer-record-event st e))
                 (lambda (st* _) (cons 'ok st*))))
    (lambda (k . args) (cons 'error (if (pair? args) args k)))))

(define (resource st id) (hashmap-ref (os-resources st) id #f))
(define (onhand st id)
  (let ((r (resource st id)))
    (and r (measure-has-numerical-value (economic-resource-onhand-quantity r)))))
(define (unit-of st id)
  (let ((r (resource st id)))
    (and r (measure-has-unit (economic-resource-onhand-quantity r)))))
(define (near? a b) (and a b (< (abs (- a b)) 1e-9)))
(define (event-count st) (length (os-events st)))

(define* (positional-snapshot st #:key (slots 7) commitments intents claims)
  "ST as a snapshot in the positional form the observer wrote before a snapshot named
   its parts, for the suites that hold the reader to it. SLOTS is how many of the
   later slots it carries (agreements, batches, resource batches, plan and intent
   validations, join terms, processes): fewer is an older snapshot. COMMITMENTS,
   INTENTS and CLAIMS stand in for the three registration slots when given (a
   hashmap of id -> serialized state record, as the oldest form held)."
  (let ((records (lambda (hm) (serialize-hashmap hm vf-serialize))))
    (append
     (list (map vf-serialize (os-events st))
           (records (os-resources st))
           (or commitments (records (os-commitment-targets st)))
           (or intents (serialize-hashmap (os-intent-targets st)
                                          (lambda (stated) (list (vf-serialize (car stated)) (cdr stated)))))
           (or claims (records (os-claim-targets st)))
           (os-idx-by-resource st) (os-idx-by-process st) (os-idx-by-agent st) (os-idx-by-action st)
           (records (os-events-by-id st))
           (os-idx-by-spec st))
     (list-head (list (os-agreements st) (records (os-batches st)) (os-resource-batches st)
                      (os-plan-validations st) (os-intent-validations st)
                      (os-terms st) (records (os-processes st)))
                slots))))
