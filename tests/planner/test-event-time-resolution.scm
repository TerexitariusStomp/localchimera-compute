;;; test-event-time-resolution.scm — a confirmed flow names the stock it really moved.
;;;
;;; ValueFlows: an event names the resource it acts on (resourceInventoriedAs) and, for a
;;; move, the one it moves into (toResourceInventoriedAs). When a person says "this
;;; happened", which resource that was is a fact about the books at that moment, so it is
;;; resolved THEN, against what the observer holds: the resources whose good (spec, stage,
;;; state) is the flow's good and which sit at the flow's place (where their own record
;;; says, or where their container is). Taking from stock the books do not hold is refused,
;;; as is taking more than they hold; stock is drawn in a fixed order; the commons' pool
;;; before a person's own holding.
;;;
;;;   NAME     a consume or move origin resolves to a resource of the flow's good at the
;;;            flow's place (a contained stock is at its container's place); a produce
;;;            adds to the lot there or founds one, conforming to the bare spec
;;;   REFUSE   no stock there, or less than asked, is refused and changes nothing
;;;   ORDER    among several lots, the one that holds enough, then the lowest id; a draw
;;;            larger than any one lot is split across lots, one event each
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-event-time-resolution.scm

(use-modules (playnet test harness)
             (playnet test books)
             (playnet planner vf schemas) (playnet planner observation states) (srfi srfi-11)
             (playnet planner scope live)
             (playnet planner doors service)
             (goblins) (goblins vat) (goblins persistence-store memory) (goblins utils hashmap)
             (srfi srfi-1))

(define cache-solve! (@@ (playnet planner doors service) cache-solve!))

(display "\n── NAME: the resource is the one the books hold at the flow's place ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "box" "box" 1.0 "P"))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "P" #:contained "box"))
      (confirm scope (flow-row "c1" 'consume "water" 30.0 "P" #:in "X"))
      (check "a consume at P draws the stock inside the box at P" (onhand-of obs "w1") 70.0)
      (check "…and founds no second resource" (resource-ids obs) '("box" "w1"))
      (confirm scope (flow-row "p1" 'produce "water" 30.0 "P" #:out "Y"))
      (check "a produce at P adds to the lot there" (list (onhand-of obs "w1") (resource-ids obs)) '(100.0 ("box" "w1"))))))

(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (confirm scope (flow-row "p1" 'produce "dough/proofed" 5.0 "P" #:out "proof"))
      (check "a produce with no lot founds one conforming to the bare spec"
             (map economic-resource-conforms-to ($ obs 'all-resources)) '("dough")))))

(display "\n── REFUSE: no stock, or not enough, changes nothing ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "Y"))
      (check "a consume at a place that holds none is refused"
             (raises? (lambda () (confirm scope (flow-row "c1" 'consume "water" 30.0 "X" #:in "P")))) #t)
      (check "a pickup from a place that holds none is refused"
             (raises? (lambda () (confirm scope (flow-row "m1" 'pickup "water" 20.0 "A" #:in "R")))) #t)
      (check "…and no stock was taken or conjured" (list (onhand-of obs "w1") (resource-ids obs)) '(100.0 ("w1"))))))

(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (check "a consume of more than is held is refused"
             (raises? (lambda () (confirm scope (flow-row "c1" 'consume "water" 150.0 "A" #:in "P")))) #t)
      (check "a pickup of more than is held is refused"
             (raises? (lambda () (confirm scope (flow-row "m1" 'pickup "water" 150.0 "A" #:in "R")))) #t)
      (check "…and the stock stands" (list (onhand-of obs "w1") (resource-ids obs)) '(100.0 ("w1"))))))

(display "\n── ORDER: a lot that holds enough, then the lowest id; the commons before a person ──\n")
(for-each
 (lambda (ids*)
   (let-values (((vat scope) (fresh-scope)))
     (with-vat vat
       (let ((obs ($ scope 'observer)))
         ($ obs 'seed-resource (res (car ids*) "water" 0.0 "P"))
         ($ obs 'seed-resource (res (cadr ids*) "water" 50.0 "P"))
         (confirm scope (flow-row "c1" 'consume "water" 10.0 "P" #:in "X"))
         (check (format #f "the lot with water is drawn, not the empty one (~a before ~a)" (car ids*) (cadr ids*))
                (list (onhand-of obs (car ids*)) (onhand-of obs (cadr ids*))) '(0.0 40.0))))))
 '(("a0" "z1") ("z0" "a1")))

(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w1" "water" 30.0 "P"))
      ($ obs 'seed-resource (res "w2" "water" 20.0 "P"))
      (confirm scope (flow-row "c1" 'consume "water" 40.0 "P" #:in "X"))
      (check "a draw larger than any one lot is split across lots, lowest id first"
             (list (onhand-of obs "w1") (onhand-of obs "w2")) '(0.0 10.0)))))

((@ (playnet planner solve engine) declare-world!)   ; water is a good some recipe makes, and none uses
 #:spans '((0 "2026-10-02" "2026-10-02"))
 #:templates (list (list "well" '(("water" . 1.0)) '() 0.0 '() '() '() '() '())))
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ ($ scope 'agent-store) 'add-agent (make-agent #:id "ana" #:type 'person #:name "ana"
                                                       #:classified-as '()))
      ($ obs 'seed-resource (res "a-ana" "water" 50.0 "P" #:acct "ana"))
      ($ obs 'seed-resource (res "z-pool" "water" 50.0 "P"))
      (confirm scope (flow-row "c1" 'consume "water" 10.0 "P" #:in "X"))
      (check "the commons' pool is drawn before a person's own holding"
             (list (onhand-of obs "a-ana") (onhand-of obs "z-pool")) '(50.0 40.0))
      (check "…and a good a person keeps is never drawn for the commons"
             (raises? (lambda () (confirm scope (flow-row "c2" 'consume "water" 45.0 "P" #:in "X")))) #t))))

(display "\n── a relocation names the lot it leaves and the lot it lands in ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      ($ obs 'seed-resource (res "w2" "water" 5.0 "B"))
      (let ((pu (flow-row "pu" 'pickup "water" 20.0 "A" #:in "R"))
            (do (flow-row "do" 'dropoff "water" 20.0 "B" #:out "R")))
        (confirm scope pu)
        (confirm scope do))
      (check "the origin gives and the lot at the destination receives; the cargo's own lot stands empty"
             (list (onhand-of obs "w1") (onhand-of obs "w2") (resource-ids obs))
             '(80.0 25.0 ("carry|R|water" "w1" "w2"))))))

(display "\n── the record-flow door records no more than the row holds ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (call (lambda (q) ($ svc 'record-flow "org:t" "consume" "water" q 10.0 "A" "2026-10-02" "P" #f)))
           (plan-row (lambda (id spec) `((id . ,id) (action . consume) (conforms-to . ,spec) (quantity . 10.0)
                                         (output-of . #f) (input-of . "P") (at-location . "A") (when . "2026-10-02") (note . #f)))))
      ($ obs 'seed-resource (res "w1" "water" 100.0 "A"))
      (check "a row the plan does not state is refused" (car (call 1.0)) 'error)
      (cache-solve! "org:t" '() `((material . (,(plan-row "mc|consume|water|P|A||2026-10-02" "water")))))
      (check "6 of the row's 10 record"              (car (call 6.0)) 'ok)
      (check "another 6 is more than the 4 it holds" (car (call 6.0)) 'error)
      (check "…and the stock took only the first 6"  (onhand-of obs "w1") 94.0)
      (check "the last 4 record"                     (car (call 4.0)) 'ok)
      (check "a finished row answers already"        (assq-ref (cdr (call 1.0)) 'already) #t))))

(display "\n── a staged good confirmed at the door fulfils its row ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let* ((obs ($ scope 'observer))
           (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope)))
           (cid "mc|produce|dough/proofed|proof|P||2026-10-02"))
      (cache-solve! "org:t" '() `((material . (((id . ,cid) (action . produce)
                                                (conforms-to . "dough/proofed") (quantity . 5.0) (output-of . "proof")
                                                (input-of . #f) (at-location . "P") (when . "2026-10-02") (note . #f))))))
      (check "the confirmation is accepted"
             (car ($ svc 'record-flow "org:t" "produce" "dough/proofed" 5.0 5.0 "P" "2026-10-02" "proof" #f)) 'ok)
      (check "the lot the event named conforms to the bare spec, and the row is fulfilled by it"
             (list (map economic-resource-conforms-to ($ obs 'all-resources))
                   (fulfillment-state-finished ($ obs 'get-fulfillment cid)))
             '(("dough") #t)))))

(test-summary!)
