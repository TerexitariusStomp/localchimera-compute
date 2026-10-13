;;; test-register-once.scm — a commitment is armed once, ended once, and a purchase names one edge.
;;;
;;; The plan-store decides which commitments stand; the observer's books read their
;;; fulfilment off the events that name them. Three properties hold for every door:
;;;
;;;   ARMED    every way a commitment enters the store (added, recovered silently,
;;;            promoted from an intent, accepted in a proposal) arms its target on the
;;;            observer, so no door has to remember to say so
;;;   ENDED    a commitment ends fulfilled when the books say its target is met: a
;;;            partial confirmation leaves it open, the last one ends it, and a second
;;;            ending changes nothing (doors/effort.scm and the confirming doors keep
;;;            the one rule, scope/live.scm end-fulfilled!)
;;;   ONE EDGE a purchase that corroborates a planned commitment fulfils it and
;;;            names no intent beside it: the observer refuses an event with both
;;;
;;; Run: guile --no-auto-compile -q -L module -L . -L tests tests/doors/test-register-once.scm

(use-modules (playnet test harness) (playnet test books)
             (playnet vf schemas) (playnet scope live)
             ((playnet vf formulas flows) #:select (make-work-event make-work-commitment))
             ((playnet utils units) #:select (%effort-unit))
             (playnet doors service)
             ((playnet knowledge recipes transport) #:select (seed-baseline-modes!))
             (goblins) (goblins vat) (goblins utils hashmap) (srfi srfi-1) (srfi srfi-11))

(define (armed? obs cid) (and ($ obs 'get-fulfillment cid) #t))

(display "\n── ARMED: every way in arms the target ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)) (ps ($ scope 'plan-store)))
      (let ((c (make-work-commitment #:id "c-add" #:provider "ana" #:skill "baking" #:hours 4.0)))
        ($ ps 'add-commitment c)
        (check "a commitment added to the store is armed" (armed? obs "c-add") #t))
      (let ((c (make-work-commitment #:id "c-silent" #:provider "ana" #:skill "baking" #:hours 4.0)))
        ($ ps 'add-commitment-silent c)
        (check "a commitment recovered silently is armed too" (armed? obs "c-silent") #t))
      ($ ps 'add-intent (make-intent #:id "i-bake" #:action 'work #:resource-conforms-to "baking"
                                     #:effort-quantity (make-measure 2.0 %effort-unit)
                                     #:provider "ana"))
      (let ((cid ($ ps 'promote-to-commitment "i-bake" '((provider . "ana") (receiver . "T")))))
        (check "a commitment promoted from an intent is armed" (armed? obs cid) #t)))))

(display "\n── ENDED: partial leaves it open, the last confirmation ends it ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)) (ps ($ scope 'plan-store)))
      ($ ps 'add-commitment (make-work-commitment #:id "c-4h" #:provider "ana" #:skill "baking" #:hours 4.0))
      (let ((work! (lambda (eid hours)
                     ($ obs 'record-event
                        (make-work-event #:id eid #:provider "ana" #:effort-qty hours #:fulfills "c-4h"
                                         #:resource-spec "baking")))))
        (work! "ev-1" 1.0)
        (end-fulfilled! scope "c-4h")
        (check "one hour of four leaves the commitment open"
               (commitment-finished ($ ps 'get-commitment "c-4h")) #f)
        (work! "ev-2" 3.0)
        (end-fulfilled! scope "c-4h")
        (check "the last three hours end it"
               (commitment-finished ($ ps 'get-commitment "c-4h")) #t)
        (check "a second ending changes nothing (no error, still ended)"
               (begin (end-fulfilled! scope "c-4h") (commitment-finished ($ ps 'get-commitment "c-4h"))) #t)))))

(display "\n── ONE EDGE: a purchase against a planned commitment and an open need ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)) (ps ($ scope 'plan-store))
          (svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope))))
      ($ ps 'add-commitment (make-commitment #:id "c-flour" #:action 'produce #:resource-conforms-to "flour"
                                             #:resource-quantity (make-measure 2.0 "kg")
                                             #:provider "ana" #:receiver "org:t"))
      ($ ps 'add-intent (make-intent #:id "i-need" #:action 'consume #:resource-conforms-to "flour"
                                     #:resource-quantity (make-measure 2.0 "kg") #:receiver "org:t"))
      (let ((r ($ svc 'record-purchase "org:t" "ana" "flour" 2.0 "kg" "" 5 "A" "" "")))
        (check "the purchase is recorded" (ok? r) #t)
        (check "it fulfils the planned commitment" (assq-ref (cdr r) 'fulfills) "c-flour")
        (check "and names no intent beside it" (assq-ref (cdr r) 'satisfies) #f)))))

(display "\n── GATED: arriving is the person's own door, like departing ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((svc (spawn ^planner-service (hashmap-set (hashmap) "org:t" scope))))
      (seed-baseline-modes! ($ scope 'recipe-store))
      (let* ((began ($ svc 'journey-begin "org:t" "Dana" "A" "B" "pedestrian"))
             (cid (assq-ref (cdr began) 'commitment)))
        ($ svc 'set-personhood-checker! (lambda (aid) #f))
        (check "without personhood the arrival is refused"
               ($ svc 'journey-end "org:t" "Dana" cid "A" "B" "pedestrian") '(error . "needs-personhood"))
        ($ svc 'set-personhood-checker! (lambda (aid) #t))
        (check "with it the arrival lands"
               (car ($ svc 'journey-end "org:t" "Dana" cid "A" "B" "pedestrian")) 'ok)))))

(test-summary!)
