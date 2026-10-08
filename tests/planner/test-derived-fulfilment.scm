;;; test-derived-fulfilment.scm — fulfilment is a reading of the events, not a counter.
;;;
;;; ValueFlows (concepts/flows.md): an event fulfils a commitment by naming it
;;; (`fulfills`), a commitment satisfies an intent (`satisfies`), an event
;;; settles a claim (`settles`). How much has been fulfilled is DERIVED
;;; information: the sum of the quantities of the events that name the commitment,
;;; and anything recalculated from the same events says the same. So:
;;;
;;;   ORDER      An event recorded before its commitment is registered counts.
;;;   REPEAT     Registering a commitment again changes its target, never its progress.
;;;   JOIN       An event counts toward a commitment of its own action and spec, in
;;;              a unit that converts; no other event does.
;;;   DATA       Over-fulfilment is the true sum with a flag; a correction is a signed
;;;              event that nets; "finished" is one comparison with one tolerance.
;;;   LADDER     Fulfilment flows through a commitment to the intent it satisfies,
;;;              whichever of the two was registered first.
;;;   REPLAY     The log folded into a fresh observer, or a snapshot loaded, reads
;;;              the same.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-derived-fulfilment.scm

(use-modules (playnet test harness)
             (playnet test events)
             ((playnet test books) #:select (mq))
             (playnet planner observation observer) (playnet planner vf schemas) (playnet planner observation states)
             (playnet planner observation observer)
             ((playnet planner vf serdes) #:select (vf-serialize))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define* (commitment id act spec q #:key (unit "kg") (proc "P") satisfies)
  ;; id action note input-of output-of inventoried conforms classified res-qty effort provider receiver
  ;; begin end point due created at in-scope stage state satisfies clause-of independent planned finished avail
  (make-commitment #:id id #:action act #:input-of (and (eq? act 'consume) proc) #:output-of (and (eq? act 'produce) proc) #:resource-conforms-to spec
                   #:resource-quantity (make-measure q unit) #:satisfies satisfies))
(define* (intent id spec q #:key (unit "kg"))
  (make-intent #:id id #:action 'produce #:resource-conforms-to spec #:resource-quantity (make-measure q unit)))

(define (fulfilling e cid) (copy-economic-event e #:fulfills cid))
(define* (made id q cid #:key (spec "flour") (unit "kg") (rid "n1"))
  (fulfilling (ev id 'produce #:rid rid #:spec spec #:q q #:unit unit #:output "P") cid))

(define (fulfilled obs cid) (let ((fs ($ obs 'get-fulfillment cid))) (and fs (mq (fulfillment-state-total-fulfilled fs)))))
(define (finished? obs cid) (let ((fs ($ obs 'get-fulfillment cid))) (and fs (fulfillment-state-finished fs))))
(define (over? obs cid) (let ((fs ($ obs 'get-fulfillment cid))) (and fs (fulfillment-state-over-fulfilled fs))))
(define (events-of obs cid) (let ((fs ($ obs 'get-fulfillment cid))) (and fs (sort (fulfillment-state-fulfilling-events fs) string<?))))
(define (new-observer) (spawn ^observer (empty-observer-state) '()))

(define vat (spawn-vat))
(with-vat vat

  (display "\n── ORDER: an event recorded before its commitment counts ──\n")
  (let ((o (new-observer)))
    ($ o 'record-event (made "e1" 10.0 "c1"))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    (check "the 10 already produced are fulfilled" (fulfilled o "c1") 10.0)
    (check "…and the commitment is finished"       (finished? o "c1") #t)
    (check "…naming the event that did it"         (events-of o "c1") '("e1")))

  (display "\n── REPEAT: registering again changes the target, never the progress ──\n")
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    (check "re-registered: 6 still fulfilled"            (fulfilled o "c1") 6.0)
    ($ o 'record-event (made "e2" 4.0 "c1"))
    (check "the last 4 finish it: 10 of 10"              (list (fulfilled o "c1") (finished? o "c1")) '(10.0 #t))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 20.0))
    (check "restated to 20: still 10 in, now unfinished" (list (fulfilled o "c1") (finished? o "c1")) '(10.0 #f))
    (check "…the committed total is the restated 20"
           (mq (fulfillment-state-total-committed ($ o 'get-fulfillment "c1"))) 20.0))

  (display "\n── JOIN: only an event of the commitment's own action and spec counts ──\n")
  (let ((o (new-observer)))
    ($ o 'seed-resource (make-economic-resource #:id "r1" #:name "r1" #:conforms-to "flour" #:accounting-quantity (make-measure 100.0 "kg") #:onhand-quantity (make-measure 100.0 "kg")
                                               #:current-location "A"))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ o 'record-event (fulfilling (ev "x1" 'consume #:rid "r1" #:spec "flour" #:q 10.0 #:input "P") "c1"))
    (check "a consume does not fulfil a produce commitment" (fulfilled o "c1") 0)
    ($ o 'record-event (made "x2" 10.0 "c1" #:spec "gold" #:rid "n2"))
    (check "an event of another spec does not either"       (fulfilled o "c1") 0)
    ($ o 'record-event (made "x3" 4000.0 "c1" #:unit "g" #:rid "n3"))
    (check "4000 g count as the 4 kg they are"              (fulfilled o "c1") 4.0)
    ($ o 'record-event (made "x4" 3.0 "c1" #:unit "litre" #:rid "n4"))
    (check "litres do not count toward kilograms"           (fulfilled o "c1") 4.0)
    (check "the stock still moved by every one of them"
           (mq (economic-resource-onhand-quantity ($ o 'get-resource "r1"))) 90.0))

  (display "\n── JOIN: an acquisition is planned as a produce and recorded as a raise ──\n")
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 5.0))
    ($ o 'record-event (fulfilling (ev "r1" 'raise #:rid "n1" #:spec "flour" #:q 5.0) "c1"))
    (check "a raise fulfils the commitment to produce the good" (list (fulfilled o "c1") (finished? o "c1")) '(5.0 #t)))
  (let ((o (new-observer)))
    ($ o 'seed-resource (make-economic-resource #:id "r1" #:name "r1" #:conforms-to "flour" #:accounting-quantity (make-measure 9.0 "kg") #:onhand-quantity (make-measure 9.0 "kg")
                                               #:current-location "A"))
    ($ o 'register-commitment (commitment "c2" 'consume "flour" 5.0))
    ($ o 'record-event (fulfilling (ev "l1" 'lower #:rid "r1" #:spec "flour" #:q 5.0) "c2"))
    (check "a lower fulfils the commitment to consume it"       (fulfilled o "c2") 5.0))

  (display "\n── JOIN: a quantity counts against a target of its own kind ──\n")
;; a `use` states both quantities (how many were engaged, for how long): a commitment
;; of hours is answered by the hours, and a commitment of vans by the vans
(let ((o (new-observer)))
  ($ o 'seed-resource (make-economic-resource #:id "van" #:name "van" #:conforms-to "van" #:accounting-quantity (make-measure 1.0 "each") #:onhand-quantity (make-measure 1.0 "each")
                                             #:current-location "A"))
  ($ o 'register-commitment (commitment "hrs" 'use "van" 2.0 #:unit "hours"))
  ($ o 'register-commitment (commitment "cnt" 'use "van" 1.0 #:unit "each"))
  (let ((u (ev "u1" 'use #:rid "van" #:spec "van" #:q 1.0 #:unit "each" #:effort '(2.0 . "hour"))))
    ($ o 'record-event (copy-economic-event u #:fulfills "hrs"))
    ($ o 'record-event (copy-economic-event (ev "u2" 'use #:rid "van" #:spec "van" #:q 1.0 #:unit "each" #:effort '(2.0 . "hour")) #:fulfills "cnt")))
  (check "a commitment of 2 hours reads the 2 hours, not the 1 van" (fulfilled o "hrs") 2.0)
  (check "a commitment of 1 each reads the 1 van, not the 2 hours" (fulfilled o "cnt") 1.0))

(display "\n── DATA: over-fulfilment, corrections, tolerance ──\n")
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ o 'record-event (made "e1" 10.0 "c1"))
    ($ o 'record-event (made "e2" 10.0 "c1"))
    (check "20 produced against 10: the true sum is kept" (fulfilled o "c1") 20.0)
    (check "…flagged over-fulfilled and finished"         (list (over? o "c1") (finished? o "c1")) '(#t #t)))
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ o 'record-event (made "e1" 10.0 "c1"))
    ($ o 'record-event (copy-economic-event (made "e1x" -4.0 "c1") #:corrects "e1"))
    (check "a correction fulfilling the same commitment nets: 6" (fulfilled o "c1") 6.0)
    (check "…and the commitment is open again"                   (finished? o "c1") #f))
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 0.3))
    ($ o 'record-event (made "e1" 0.1 "c1"))
    ($ o 'record-event (made "e2" 0.2 "c1"))
    (check "0.1 + 0.2 finishes a commitment of 0.3" (finished? o "c1") #t))

  (display "\n── LADDER: through the commitment to the intent, in either order ──\n")
  (let ((o (new-observer)))
    ($ o 'register-intent (intent "i1" "flour" 10.0))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i1"))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    (check "the intent reads 6 satisfied"     (mq (satisfaction-state-total-satisfied ($ o 'get-satisfaction "i1"))) 6.0))
  (let ((o (new-observer)))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i1"))
    ($ o 'register-intent (intent "i1" "flour" 10.0))
    (check "registered last, the intent reads the same 6"
           (mq (satisfaction-state-total-satisfied ($ o 'get-satisfaction "i1"))) 6.0)
    ($ o 'record-event (copy-economic-event (ev "d1" 'produce #:rid "n2" #:spec "flour" #:q 4.0 #:output "P") #:satisfies "i1"))
    (check "an event that satisfies the intent directly adds: 10, finished"
           (let ((ss ($ o 'get-satisfaction "i1")))
             (list (mq (satisfaction-state-total-satisfied ss)) (satisfaction-state-finished ss)))
           '(10.0 #t)))

  (display "\n── REPLAY: the log folded fresh, and a snapshot, read the same ──\n")
  (let ((live (new-observer)) (fresh (new-observer)))
    ($ live 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ live 'record-event (made "e1" 6.0 "c1"))
    ($ live 'record-event (made "e2" 4.0 "c1"))
    (for-each (lambda (e) ($ fresh 'record-event e)) (reverse ($ live 'all-events)))
    ($ fresh 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    (check "a fresh observer replaying the log, then registered, reads the same"
           (list (fulfilled fresh "c1") (finished? fresh "c1") (events-of fresh "c1"))
           (list (fulfilled live "c1") (finished? live "c1") (events-of live "c1")))
    (let ((loaded (new-observer)))
      ($ loaded 'load-snapshot ($ live 'serialize))
      (check "a snapshot loaded reads the same"
             (list (fulfilled loaded "c1") (finished? loaded "c1") (events-of loaded "c1"))
             (list (fulfilled live "c1") (finished? live "c1") (events-of live "c1")))))

  (display "\n── a withdrawn commitment keeps its tally for a restated one ──\n")
  (let ((o (new-observer)))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    ($ o 'record-event (made "e1" 3.0 "c1"))
    ($ o 'retire-commitment "c1")
    (check "retired: nothing to read"                  ($ o 'get-fulfillment "c1") #f)
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0))
    (check "restated: the 3 already made still count" (fulfilled o "c1") 3.0))
  ;; withdrawing the target leaves what is already recorded as the join read it: the
  ;; events that never counted toward the commitment still do not count toward the
  ;; intent it satisfied
  (let ((o (new-observer)))
    ($ o 'register-intent (intent "i1" "flour" 10.0))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i1"))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    ($ o 'record-event (made "e2" 100.0 "c1" #:spec "gold" #:rid "n2"))
    (let ((read (lambda () (mq (satisfaction-state-total-satisfied ($ o 'get-satisfaction "i1"))))))
      (check "the intent reads the 6 flour, not the gold" (read) 6.0)
      ($ o 'retire-commitment "c1")
      (check "after the commitment is withdrawn it still reads 6" (read) 6.0)))

  (display "\n── STORE: the books hold what was registered, and no count ──\n")
  (let ((o (new-observer)))
    ($ o 'register-intent (intent "i1" "flour" 10.0))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i1"))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    (let ((st (deserialize-observer-state-portable ($ o 'serialize))))
      (check "a commitment is held as its target, a measure"
             (measure? (hashmap-ref (os-commitment-targets st) "c1" #f)) #t)
      (check "an intent is held as its target and its plan"
             (let ((s (hashmap-ref (os-intent-targets st) "i1" #f))) (and (pair? s) (mq (car s)))) 10.0)
      (check "the snapshot says the commitment satisfies the intent, off the terms"
             (hashmap-ref (os-satisfiers st) "i1" '()) '("c1")))
    ;; the edges are the terms read the other way, so restating a commitment moves them
    ($ o 'register-intent (intent "i2" "flour" 10.0))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i2"))
    (check "restated to satisfy another intent: the 6 flow there"
           (list (mq (satisfaction-state-total-satisfied ($ o 'get-satisfaction "i1")))
                 (mq (satisfaction-state-total-satisfied ($ o 'get-satisfaction "i2"))))
           '(0 6.0)))

  (display "\n── LEGACY: a snapshot that held state records reads the same ──\n")
  ;; before the states were derived a snapshot's three slots held a state record per
  ;; registration, counts and all; the target is read out of it and the counts left
  (let ((o (new-observer)))
    ($ o 'register-intent (intent "i1" "flour" 10.0))
    ($ o 'register-commitment (commitment "c1" 'produce "flour" 10.0 #:satisfies "i1"))
    ($ o 'record-event (made "e1" 6.0 "c1"))
    (let* ((st (deserialize-observer-state-portable ($ o 'serialize)))
           (zero (make-measure 0 "kg")) (ten (make-measure 10.0 "kg"))
           (stale (make-measure 99.0 "kg"))        ; a count the events contradict
           (old  (lambda (id rec) (hashmap-set (hashmap) id (vf-serialize rec))))
           (legacy (positional-snapshot st
                     #:commitments (old "c1" (make-fulfillment-state "c1" ten stale '("gone") #t #t))
                     #:intents     (old "i1" (make-satisfaction-state "i1" ten stale '("gone") '("c1") #t "plan-1"))
                     #:claims      (old "k1" (make-claim-state "k1" ten zero '() #f))))
           (loaded (spawn ^observer (deserialize-observer-state legacy) '())))
      (check "the commitment reads what the events say, 6 of 10"
             (list (fulfilled loaded "c1") (finished? loaded "c1") (events-of loaded "c1")) '(6.0 #f ("e1")))
      (check "the intent reads 6 through its commitment, and keeps its plan"
             (let ((ss ($ loaded 'get-satisfaction "i1")))
               (list (mq (satisfaction-state-total-satisfied ss)) (satisfaction-state-plan-id ss)
                     (satisfaction-state-satisfying-commitments ss)))
             '(6.0 "plan-1" ("c1")))
      (check "the claim keeps its target"
             (mq (claim-state-total-claimed ($ loaded 'get-claim-state "k1"))) 10.0)
      (check "the targets-per-registration form reads the same"
             (let ((mid (spawn ^observer (deserialize-observer-state (positional-snapshot st)) '())))
               (list (fulfilled mid "c1") (mq (satisfaction-state-total-satisfied ($ mid 'get-satisfaction "i1")))))
             '(6.0 6.0))
      (check "every index a loaded snapshot holds is the one the events built"
             (let ((back (deserialize-observer-state (serialize-observer-state st)))
                   (same? (lambda (a b) (equal? (hashmap-fold (lambda (k v acc) (acons k v acc)) '() a)
                                                (hashmap-fold (lambda (k v acc) (acons k v acc)) '() b)))))
               (and (equal? (map economic-event-id (os-events back)) (map economic-event-id (os-events st)))
                    (every (lambda (idx) (same? (idx back) (idx st)))
                           (list os-idx-by-resource os-idx-by-process os-idx-by-agent os-idx-by-action
                                 os-idx-by-link os-idx-by-spec os-satisfiers))))
             #t)
      (check "saved again, it is in today's form"
             (measure? (hashmap-ref (os-commitment-targets (deserialize-observer-state-portable ($ loaded 'serialize))) "c1" #f))
             #t))))

(test-summary!)
