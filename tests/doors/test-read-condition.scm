;;; tests/doors/test-read-condition.scm — a reading names the form the stock is in.
;;;
;;; A thermometer's degrees are no count (docs/observation/readings-are-counts.md
;;; §1.1); a state is a form (§2.3). So read-condition finds, among the forms a
;;; base has declared, the one the reading names, and lands the counts that say
;;; so: the stock of the form the books held is found to be nothing, and the
;;; whole of it is found in the form named. Pinned here:
;;;
;;;   • an extensive unit is refused: that is a count;
;;;   • a reading at rest names the base; one at a declared excess names that
;;;     form; one at an excess nobody declared is refused by name;
;;;   • the move: the old stock reads 0, the new stock reads the quantity, in the
;;;     stock's own unit, and the reply says which form from which;
;;;   • a stock already in the form named moves nothing.
;;;
;;; Run from project root:
;;;   tools/test/own-ccache.sh guile --no-auto-compile -q -L module tests/doors/test-read-condition.scm

(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas)
             ((playnet doors count-door) #:select (do-read-condition))
             ((playnet knowledge catalogues thermal) #:select (declare-thermal-form!))
             ((playnet observation observer) #:select (measure-qty))
             ((playnet utils clock) #:select ((now . clock-now) instant->civil))
             (goblins) (srfi srfi-1))

(define vat (spawn-vat))
(define root (with-vat vat (spawn-scope-root "bakery")))
(define rs (with-vat vat ($ root 'recipe-store)))
(define obs (with-vat vat ($ root 'observer)))
(define* (spec! id unit #:optional (kip #f))
  ($ rs 'add-resource-spec (make-resource-specification #:id id #:name id
                                                        #:default-unit-of-resource unit
                                                        #:keep-in-place kip)))
(define (onhand rid)
  (with-vat vat
    (let ((r ($ obs 'get-resource rid)))
      (and r (measure-qty (economic-resource-onhand-quantity r))))))
(define (read! rid v u . rest)
  (with-vat vat (apply do-read-condition root "bakery" "ada" rid v u rest)))

(display "\n── the forms, and a batch of dough at rest ──\n")
(with-vat vat
  (spec! "dough" "kg") (spec! "room" "hours/day" #t) (spec! "spec-sp-electricity" "kWh") (spec! "ambient-heat" "kWh")
  (declare-thermal-form! rs "dough" 2.5 6 "room" #:fraction 0.2)
  ($ obs 'record-event
     (make-economic-event #:id "evt-seed" #:action 'raise #:resource-inventoried-as "batch-7"
                          #:resource-conforms-to "dough" #:resource-quantity (make-measure 40.0 "kg")
                          #:has-point-in-time (instant->civil (- (clock-now) 3600))   ; a flow of an hour ago
                          #:provider "ada" #:receiver "ada" #:in-scope-of (list "bakery"))))
(check "the batch stands as dough" (onhand "batch-7") 40.0)

(display "\n── refusals ──\n")
(let ((r (read! "batch-7" 40 "kg")))
  (check "an extensive unit is a count, not a condition" (car r) 'error)
  (check-pred "…and the refusal says where a count goes" (string-contains (cdr r) "count-stock")))
(let ((r (read! "batch-7" 40 "°C")))
  (check "an excess nobody declared is refused" (car r) 'error)
  (check-pred "…by name: the base and the excess" (and (string-contains (cdr r) "dough") (string-contains (cdr r) "20"))))
(check "no such stock" (car (read! "batch-8" 26 "°C")) 'error)

(display "\n── a reading at rest names the base; nothing moves ──\n")
(let ((r (read! "batch-7" 20.2 "°C")))
  (check "ok" (car r) 'ok)
  (check "the form is the base" (assq-ref (cdr r) 'form) "dough")
  (check "nothing moved" (assq-ref (cdr r) 'moved) 0))

(display "\n── the reading names the warmed form, and the stock moves to it ──\n")
(let ((r (read! "batch-7" 26 "°C")))
  (check "ok" (car r) 'ok)
  (check "the form named" (assq-ref (cdr r) 'form) "dough+6K")
  (check "from the base" (assq-ref (cdr r) 'was) "dough")
  (check "the whole batch, in its own unit" (list (assq-ref (cdr r) 'moved) (assq-ref (cdr r) 'unit)) '(40.0 "kg"))
  (check "the warmed stock is named by its form" (assq-ref (cdr r) 'to-stock) "batch-7+6K")
  (check "the old stock reads nothing" (onhand "batch-7") 0.0)
  (check "the warmed stock reads the batch" (onhand "batch-7+6K") 40.0)
  (check-pred "the raise is on the books, in words" (with-vat vat
                                                     (let ((e ($ obs 'get-event (assq-ref (cdr r) 'event))))
                                                       (and e (string-contains (economic-event-note e) "dough+6K"))))))

(display "\n── read again at the same excess: already in that form ──\n")
(let ((r (read! "batch-7+6K" 26.3 "°C")))
  (check "ok" (car r) 'ok)
  (check "the form the books hold" (assq-ref (cdr r) 'form) "dough+6K")
  (check "nothing moved" (assq-ref (cdr r) 'moved) 0))

(display "\n── and back to rest: the warmed stock empties into the base's ──\n")
(let ((r (read! "batch-7+6K" 20 "°C" #:ambient 20)))
  (check "ok" (car r) 'ok)
  (check "the base again" (assq-ref (cdr r) 'form) "dough")
  (check "to the base's own stock" (assq-ref (cdr r) 'to-stock) "batch-7")
  (check "the warmed stock reads nothing" (onhand "batch-7+6K") 0.0)
  (check "the base stock reads the batch" (onhand "batch-7") 40.0))

(display "\n── a reading of an instant is one reading, however often it lands ──\n")
(with-vat vat
  ($ obs 'record-event
     (make-economic-event #:id "evt-seed-9" #:action 'raise #:resource-inventoried-as "batch-9"
                          #:resource-conforms-to "dough" #:resource-quantity (make-measure 12.0 "kg")
                          #:has-point-in-time (instant->civil (- (clock-now) 7200))
                          #:provider "ada" #:receiver "ada" #:in-scope-of (list "bakery"))))
(let* ((at (instant->civil (- (clock-now) 600)))
       (first (read! "batch-9" 26 "°C" #:when-iso at))
       (events (with-vat vat (length ($ obs 'all-events))))
       (second (read! "batch-9" 26 "°C" #:when-iso at)))
  (check "the first reading moves the batch to its warmed form" (list (car first) (assq-ref (cdr first) 'moved)) '(ok 12.0))
  (check "the second names the same reading" (assq-ref (cdr second) 'event) (assq-ref (cdr first) 'event))
  (check-pred "…says it had it, and what it moved" (and (assq-ref (cdr second) 'again) (= 12.0 (assq-ref (cdr second) 'moved))))
  (check "…and lands nothing more" (with-vat vat (length ($ obs 'all-events))) events)
  (check "the warmed stock holds the batch once" (onhand "batch-9+6K") 12.0))

(display "\n")
(test-summary!)
