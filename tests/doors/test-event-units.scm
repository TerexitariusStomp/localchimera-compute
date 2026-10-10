;;; test-event-units.scm — a confirmed event counts in the unit of the good it moves.
;;;
;;; A ResourceSpecification states the unit its resources are counted in
;;; (`defaultUnitOfResource`), and a lot keeps the unit it was counted in. The doors that
;;; record a plan row therefore state that unit on the event: the specification's own,
;;; else the unit of the lot the event draws on or lands in, else the placeholder "unit" the
;;; observer reads in whatever the lot counts in. A lot an event creates is born in that
;;; unit, so the count door and the stock ingest read it as is.
;;;
;;;   BORN      a produce into a place with no lot makes a lot counted in the spec's unit
;;;   STANDS    a lot that stands keeps the unit it was counted in; the observer converts
;;;             the event's unit into it
;;;   CARRY     a pickup's carried lot and a dropoff's destination lot are counted in the
;;;             unit of the stock they carry
;;;   BARE      a good whose spec states no unit keeps the placeholder
;;;   ROW       a plan row is held in its spec's unit, so an event recorded in another unit of
;;;             that substance counts in the row's own: 2000 g meets a row of 2 kg
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-event-units.scm

(use-modules (playnet test harness)
             (playnet test books)
             (playnet vf schemas) (playnet observation states) (srfi srfi-11)
             (playnet scope live)
             ((playnet utils units) #:select (placeholder-unit?))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (lot-unit obs id)
  (let ((r ($ obs 'get-resource id)))
    (and r (measure-has-unit (economic-resource-onhand-quantity r)))))
(define (lots-of obs spec)
  (filter (lambda (r) (equal? spec (economic-resource-conforms-to r))) ($ obs 'all-resources)))
(define (declare-unit! scope id unit)
  ($ ($ scope 'recipe-store) 'add-resource-spec
     (make-resource-specification #:id id #:name id #:default-unit-of-resource unit)))

(display "\n── BORN: a produce into a place with no lot is counted in the spec's unit ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (declare-unit! scope "veg" "kg")
      (confirm scope (flow-row "mc|p" 'produce "veg" 5.0 "A" #:out "p1"))
      (let ((lots (lots-of obs "veg")))
        (check "one lot is made" (length lots) 1)
        (check "…counted in the spec's unit" (lot-unit obs (economic-resource-id (car lots))) "kg")
        (check "…holding what was produced" (onhand-of obs (economic-resource-id (car lots))) 5.0)))))

(display "\n── STANDS: a lot that stands keeps the unit it was counted in ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (declare-unit! scope "veg" "kg")
      ($ obs 'seed-resource (res "v1" "veg" 10.0 "A" #:unit "g"))
      (confirm scope (flow-row "mc|c" 'consume "veg" 0.004 "A" #:in "p1"))
      (check "a consume leaves the lot in the unit it was counted in" (lot-unit obs "v1") "g")
      (check "…and the spec's 0.004 kg came out of it as 4 g" (onhand-of obs "v1") 6.0))))

(display "\n── CARRY: the carried lot and the destination lot count in the cargo's unit ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (declare-unit! scope "veg" "kg")
      ($ obs 'seed-resource (res "v1" "veg" 40.0 "A" #:unit "kg"))
      (confirm scope (flow-row "mc|pu" 'pickup "veg" 10.0 "A" #:in "run1"))
      (confirm scope (flow-row "mc|do" 'dropoff "veg" 10.0 "B" #:out "run1"))
      (let ((made (filter (lambda (r) (not (equal? "v1" (economic-resource-id r)))) (lots-of obs "veg"))))
        (check "the cargo's two new lots (carried, destination) are counted in kg"
               (map (lambda (r) (lot-unit obs (economic-resource-id r))) made) '("kg" "kg"))))))

(display "\n── BARE: a good whose spec states no unit keeps the placeholder ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (confirm scope (flow-row "mc|p" 'produce "mystery" 3.0 "A" #:out "p1"))
      (check "a produce of an unstated spec is counted in the placeholder"
             (map (lambda (r) (lot-unit obs (economic-resource-id r))) (lots-of obs "mystery")) '("unit")))))

;; a plan row the way the plan states it, held on the observer the way the doors hold it
(define hold-row! (@@ (playnet doors service) hold-row!))
(define (row-in-kg id) (flow-row id 'consume "veg" 2.0 "A" #:in "p1" #:unit "kg"))
(define (event-of-grams id fulfills)
  (make-economic-event #:id id #:action 'consume #:input-of "p1" #:resource-inventoried-as "v1"
                       #:resource-conforms-to "veg" #:resource-quantity (make-measure 2000.0 "g")
                       #:at-location "A" #:fulfills fulfills))

(display "\n── ROW: a plan row counts in its spec's unit ──\n")
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      ($ obs 'seed-resource (res "v1" "veg" 10.0 "A" #:unit "kg"))
      (hold-row! obs "scope" (row-in-kg "mc|c"))
      (check "the row is held in the unit it states"
             (measure-has-unit (fulfillment-state-total-committed ($ obs 'get-fulfillment "mc|c"))) "kg")
      ($ obs 'record-event (event-of-grams "ev-g" "mc|c"))
      (let ((fs ($ obs 'get-fulfillment "mc|c")))
        (check "an event of 2000 g meets the 2 kg row, in kg"
               (list (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))
                     (measure-has-unit (fulfillment-state-total-fulfilled fs)))
               '(2.0 "kg"))
        (check "…and it has not passed it" (fulfillment-state-over-fulfilled fs) #f)))))
(let-values (((vat scope) (fresh-scope)))
  (with-vat vat
    (let ((obs ($ scope 'observer)))
      (hold-row! obs "scope" (flow-row "mc|c" 'consume "veg" 2.0 "A" #:in "p1"))
      (check "a row that states no unit is held in the placeholder"
             (placeholder-unit? (measure-has-unit (fulfillment-state-total-committed ($ obs 'get-fulfillment "mc|c")))) #t))))

(test-summary!)
