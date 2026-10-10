;;; containment-cascade-test.scm — consuming a CONTAINER draws down its CONTENTS.
;;; A carrot resource holds nutrient resources (nitrogen, carbon) via contained-in.
;;; Consuming part of the carrot must consume that fraction of each nutrient, and
;;; nested containment (a vehicle holding the carrot) must cascade too. This is
;;; the substrate for substance flow: nutrients ride inside the products that
;;; carry them, conserved through consume.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/planner/containment-cascade-test.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas) (srfi srfi-1)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1))

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Cascade Test")) store))

(define (onhand obs id)
  (let ((r ($ obs 'get-resource id)))
    (and r (measure-has-numerical-value (economic-resource-onhand-quantity r)))))
(define (~= a b) (and a b (< (abs (- a b)) 1e-9)))

(with-vat vat
  (let ((obs ($ scope 'observer)))
    ;; a carrot batch (100 kg), holding nitrogen (2.6 kg) and carbon (12 kg)
    ;; contained-in it — the 16th field is contained-in.
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-carrot" #:name "Carrots" #:conforms-to "carrot"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "field"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-carrot-N" #:name "Nitrogen in carrots" #:conforms-to "N"
         #:accounting-quantity (make-measure 2.6 "kg") #:onhand-quantity (make-measure 2.6 "kg") #:primary-accountable "field" #:contained-in "r-carrot"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "r-carrot-C" #:name "Carbon in carrots" #:conforms-to "C"
         #:accounting-quantity (make-measure 12 "kg") #:onhand-quantity (make-measure 12 "kg") #:primary-accountable "field" #:contained-in "r-carrot"))

    (check-pred "carrot contains two nutrient resources"
                (= (length ($ obs 'resources-contained-in "r-carrot")) 2))

    ;; consume HALF the carrot → its nutrients halve
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-eat-half" #:action 'consume #:input-of "proc-eat"
         #:resource-inventoried-as "r-carrot" #:resource-conforms-to "carrot"
         #:provider "household" #:receiver "household"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-06-12T12:00:00Z"))

    (check-pred "carrot drawn down to 50" (~= (onhand obs "r-carrot") 50))
    (check-pred "nitrogen halved to 1.3"  (~= (onhand obs "r-carrot-N") 1.3))
    (check-pred "carbon halved to 6"      (~= (onhand obs "r-carrot-C") 6.0))

    ;; consume the REST → nutrients go to zero (conservation: nothing stranded)
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-eat-rest" #:action 'consume #:input-of "proc-eat"
         #:resource-inventoried-as "r-carrot" #:resource-conforms-to "carrot"
         #:provider "household" #:receiver "household"
         #:resource-quantity (make-measure 50 "kg") #:has-point-in-time "2026-06-12T12:05:00Z"))

    (check-pred "carrot fully consumed" (~= (onhand obs "r-carrot") 0))
    (check-pred "nitrogen fully consumed" (~= (onhand obs "r-carrot-N") 0))
    (check-pred "carbon fully consumed"   (~= (onhand obs "r-carrot-C") 0))))

;;; ── nested containment: a vehicle holds the carrot, which holds nutrients ──
(define store2 (make-memory-store))
(define-values (vat2 scope2)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Cascade Nested")) store2))

(with-vat vat2
  (let ((obs ($ scope2 'observer)))
    ($ obs 'seed-resource
       (make-economic-resource #:id "v" #:name "Vehicle load" #:conforms-to "load"
         #:accounting-quantity (make-measure 10 %count-unit) #:onhand-quantity (make-measure 10 %count-unit) #:primary-accountable "A"))
    ($ obs 'seed-resource    ; carrot contained in the vehicle load
       (make-economic-resource #:id "c" #:name "Carrots" #:conforms-to "carrot"
         #:accounting-quantity (make-measure 100 "kg") #:onhand-quantity (make-measure 100 "kg") #:primary-accountable "A" #:contained-in "v"))
    ($ obs 'seed-resource    ; nitrogen contained in the carrot
       (make-economic-resource #:id "n" #:name "Nitrogen" #:conforms-to "N"
         #:accounting-quantity (make-measure 2.6 "kg") #:onhand-quantity (make-measure 2.6 "kg") #:primary-accountable "A" #:contained-in "c"))

    ;; consume 4 of the 10 load units → everything two levels down scales ×0.6
    ($ obs 'record-event
       (make-economic-event
         #:id "ev-load" #:action 'consume #:input-of "p" #:resource-inventoried-as "v" #:resource-conforms-to "load" #:provider "a" #:receiver "a"
         #:resource-quantity (make-measure 4 %count-unit) #:has-point-in-time "2026-06-12T13:00:00Z"))

    (check-pred "vehicle load → 6"        (~= (onhand obs "v") 6))
    (check-pred "carrot cascaded ×0.6 → 60" (~= (onhand obs "c") 60))
    (check-pred "nitrogen cascaded two levels → 1.56" (~= (onhand obs "n") 1.56))))

;;; ── a count's lower and raise are inverses, and a void takes the cascade back ──
(use-modules ((playnet observation adjustment) #:select (adjustment-event))
             ((playnet observation observer) #:select (void-event))
             ((playnet utils clock) #:select (civil->instant)))

(define store3 (make-memory-store))
(define-values (vat3 scope3)
  (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "Cascade Count")) store3))

(with-vat vat3
  (let ((obs ($ scope3 'observer))
        (count (lambda (id delta at)
                 (adjustment-event id "b" "bin" delta %count-unit #:provider "a" #:receiver "a"
                                   #:process "count:stated" #:when at #:created at))))
    ($ obs 'seed-resource
       (make-economic-resource #:id "b" #:name "Bin" #:conforms-to "bin"
         #:accounting-quantity (make-measure 10 %count-unit) #:onhand-quantity (make-measure 10 %count-unit) #:primary-accountable "A"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "j" #:name "Jars" #:conforms-to "jar"
         #:accounting-quantity (make-measure 50 %count-unit) #:onhand-quantity (make-measure 50 %count-unit) #:primary-accountable "A" #:contained-in "b"))
    ($ obs 'seed-resource
       (make-economic-resource #:id "l" #:name "Lids" #:conforms-to "lid"
         #:accounting-quantity (make-measure 5 %count-unit) #:onhand-quantity (make-measure 5 %count-unit) #:primary-accountable "A" #:contained-in "j"))

    ($ obs 'record-event (count "c1" -2 "2026-06-12T10:00:00Z"))
    (check-pred "a lower scales the contents ×0.8" (~= (onhand obs "j") 40))
    (check-pred "and what is in them" (~= (onhand obs "l") 4))
    ($ obs 'record-event (count "c2" 2 "2026-06-12T11:00:00Z"))
    (check-pred "the bin is back at 10" (~= (onhand obs "b") 10))
    (check-pred "the raise that answers it restores the contents" (~= (onhand obs "j") 50))
    (check-pred "all the way down" (~= (onhand obs "l") 5))

    ;; the ledger as of an instant: what stands now, less what happened since
    (let ((at (lambda (iso) (civil->instant iso))))
      (check-pred "as of before both counts"
                  (~= ($ obs 'onhand-as-of "b" (at "2026-06-12T09:00:00Z")) 10))
      (check-pred "as of between them"
                  (~= ($ obs 'onhand-as-of "b" (at "2026-06-12T10:30:00Z")) 8))
      (check-pred "contents as of between them, read off the cascade"
                  (~= ($ obs 'onhand-as-of "j" (at "2026-06-12T10:30:00Z")) 40))
      (check-pred "no such stock" (not ($ obs 'onhand-as-of "nope" 0))))

    ;; a third count lowers the bin; a void of it puts bin and contents back
    ($ obs 'record-event (count "c3" -5 "2026-06-12T12:00:00Z"))
    (check-pred "halved" (and (~= (onhand obs "j") 25) (~= (onhand obs "l") 2.5)))
    ($ obs 'record-event
       (void-event ($ obs 'get-event "c3") "c3-void" "voided" "s" "2026-06-12T13:00:00Z"))
    (check-pred "the void restores the bin" (~= (onhand obs "b") 10))
    (check-pred "and its contents" (~= (onhand obs "j") 50))
    (check-pred "all the way down" (~= (onhand obs "l") 5))
    (check-pred "the voided count's cascade leaves the standing log"
                (not (any (lambda (e) (string-prefix? "c3" (economic-event-id e)))
                          ($ obs 'standing-log))))
    (check-pred "a standing count's cascade stays in it"
                (any (lambda (e) (equal? "c1~contains~j" (economic-event-id e)))
                     ($ obs 'standing-log)))
    ;; the void is dated when it was made (accounting.md: the correction is "as of the
    ;; date of the correction"): the count had run by 12:30 and is backed out by 13:30
    (check-pred "as of before the void, the voided count's cascade is still in the ledger"
                (~= ($ obs 'onhand-as-of "j" (civil->instant "2026-06-12T12:30:00Z")) 25))
    (check-pred "as of after the void, the contents read as if it never ran"
                (~= ($ obs 'onhand-as-of "j" (civil->instant "2026-06-12T13:30:00Z")) 50))

    ;; a raise from nothing has no proportion: the contents stay as they are
    ($ obs 'record-event (count "c4" -10 "2026-06-12T14:00:00Z"))
    ($ obs 'record-event (count "c5" 10 "2026-06-12T15:00:00Z"))
    (check-pred "emptied, then found again: contents stay at nothing" (~= (onhand obs "j") 0))))

(test-summary!)
