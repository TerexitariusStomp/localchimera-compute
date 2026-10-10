;;; test-holdings-audit.scm — every holding, against the catalogue that claims it.
;;;
;;; A durable's service capacity is `stock × the hours it stands available`. That
;;; conversion presupposes the stock is a COUNT — three ovens, one Lastenrad — and
;;; the presupposition is unchecked at the point it is used, because ingest sees a
;;; number with its unit already dropped.
;;;
;;; Two ways it goes wrong, and both have happened:
;;;
;;;   A HOLDING CONTRADICTS ITS SPEC. `spec-bt-cargo-bike` was denominated `each`
;;;   by the transit shed and `hours` by the food chain — one object, two
;;;   catalogues, two answers, and which one won depended on which scope asked.
;;;
;;;   A HOLDING IS A CAPACITY IN DISGUISE. `bfs-lastenrad` held "40 hours": not a
;;;   count of anything, but a capacity with no interval attached, against a spec
;;;   that says bikes are counted in bikes. One bike cannot render forty bike-hours
;;;   in a twenty-four hour day, so the plan was physically overstated and nothing
;;;   said so.
;;;
;;; SILENCE IS NOT CLEAN. The first version of this audit passed while the cargo
;;; bike collision was live, because a spec the store never registered compared
;;; equal to nothing and was skipped. An unregistered spec is now a finding in its
;;; own right: an unanswerable question is not a satisfied one.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module tests/planner/test-holdings-audit.scm

(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes berlin-commune-seed) (playnet knowledge recipes berlin-food-seed) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (goblins) (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(use-modules ((playnet utils units) #:select ((time-unit? . bare-time-unit?))))   ; the one reader of "is this a time?"

;;; A CAPACITY is a rate, and a rate is one unit written as a quotient —
;;; `hours/day`, `hours/week` (utils/units.scm §division units). So the two things
;;; this audit compares are a holding's unit and its catalogue's, and the
;;; comparison is dimensional rather than literal:
;;;
;;;   the DENOMINATOR is the holding's own. A catalogue says what a kind is
;;;   measured in — a network service in seat-hours per period — while how much
;;;   per how long is a fact about this pass: one gives 200 hours a week where
;;;   another gives fifty a month, of the one spec. So `hours/week` against a spec
;;;   of `hours/day` is agreement, and the numerator is what has to match.
;;;
;;;   a BARE quantity of time is the third shape. `200 hours` names no denominator
;;;   because it has none — it is a BUDGET, a total over its window — so it is
;;;   well-formed, and what makes it a FINDING is disagreeing with its catalogue: a
;;;   spec that says `hours/day` describes a kind that regenerates each period, and a
;;;   holding of it stated as a total means somebody dropped the denominator. That is
;;;   the check below, and it is why the two readings have to be told apart by more
;;;   than string equality.
(define (unit-numerator u)
  (and (string? u)
       (let ((i (string-index u #\/)))
         (if i (substring u 0 i) u))))
(define (rate-unit? u) (and (string? u) (string-index u #\/) #t))
(define (units-agree? su ru)
  (or (equal? su ru)
      ;; both rates: the numerator carries the substance, the denominator is local
      (and (rate-unit? su) (rate-unit? ru)
           (equal? (unit-numerator su) (unit-numerator ru)))))
;; The split the conversion turns on: a quotient over time is a RATE, a plain unit
;; is a STOCK, and a bare quantity of time is neither — reported on its own.
(define (time-rate-unit? u) (and (rate-unit? u) (bare-time-unit? (unit-numerator u))))

;;; The scopes a live plan is actually built from. Each is seeded exactly as its
;;; own suite seeds it, so this audits the real thing rather than a fixture.
(define %scopes
  (list (cons "berlin-food"    (lambda (root) (seed-berlin-food-scope! root #:place "berlin")))
        (cons "berlin-commune" (lambda (root) (seed-berlin-commune! root #:transit? #t)))))

(define vat (spawn-vat #:name "holdings-audit"))

(define (audit label seed!)
  (let ((root (with-vat vat (spawn-scope-root label))))
    (with-vat vat
      (seed! root)
      (let ((rs ($ root 'recipe-store)) (obs ($ root 'observer)))
        (filter-map
         (lambda (r)
           (let* ((rid (economic-resource-id r))
                  (sid (economic-resource-conforms-to r))
                  (sp  (and sid ($ rs 'get-resource-spec sid)))
                  (su  (and sp (resource-specification-default-unit-of-resource sp)))
                  (m   (economic-resource-onhand-quantity r))
                  (ru  (and m (measure-has-unit m)))
                  (q   (and m (measure-has-numerical-value m))))
             (cond
              ;; a holding whose spec nobody registered: unanswerable, so reported
              ((and sid (not sp))
               (format #f "~a: ~a conforms to ~a, which no spec in this scope declares"
                       label rid sid))
              ;; a spec that declares NO unit, for a thing somebody holds. The
              ;; chain that registers a means no longer guesses its denomination
              ;; (a draw's unit is not a stock's), which is right — but somebody
              ;; still has to say. An undeclared unit is the same unanswerable
              ;; question as an unregistered spec, wearing a different hat.
              ((and sp (not su) ru)
               (format #f "~a: ~a holds ~a ~s, and ~a declares no unit at all"
                       label rid q ru sid))
              ;; a spec that declares a unit the holding disagrees with
              ((and su ru (not (units-agree? su ru)))
               (format #f "~a: ~a holds ~a ~s, but ~a is counted in ~s"
                       label rid q ru sid su))
              (else #f))))
         ($ obs 'all-resources))))))

(define findings (append-map (lambda (p) (audit (car p) (cdr p))) %scopes))

(format #t "\n── ~a scope(s) audited ──\n" (length %scopes))
(for-each (lambda (l) (format #t "  ~a\n" l)) findings)

(check-pred "every holding is denominated the way its own catalogue denominates it"
            (null? findings))

;;; And the property the capacity conversion actually rests on — which is NOT
;;; "everything is a count". A commune that rides the U-Bahn holds two hundred
;;; seat-hours under the operator's rights; it owns no trains, and there is no
;;; count to demand. berlin-transit.scm says so where the resource is built: "not
;;; property: the operator holds the rights and can withdraw the service". That is
;;; a first-class category here, the rented sector, and a rule requiring counts
;;; would force a fiction to satisfy the solver.
;;;
;;; So the invariant is agreement, not uniformity: a means held as a RATE has a spec
;;; that says so, because the conversion divides a rate by its own denominator where
;;; it multiplies a stock by the hours on offer (utils/capacity.scm). Get that pair
;;; wrong in either direction and the span is applied once too often or once too few
;;; — silently, and by a factor of the period.
(define (denomination-splits label seed!)
  (let ((root (with-vat vat (spawn-scope-root (string-append label "-d")))))
    (with-vat vat
      (seed! root)
      (let ((rs ($ root 'recipe-store)))
        (filter-map
         (lambda (r)
           (let* ((sid (economic-resource-conforms-to r))
                  (sp  (and sid ($ rs 'get-resource-spec sid)))
                  (su  (and sp (resource-specification-default-unit-of-resource sp)))
                  (m   (economic-resource-onhand-quantity r))
                  (ru  (and m (measure-has-unit m))))
             (and su ru (not (eq? (time-rate-unit? ru) (time-rate-unit? su)))
                  (format #f "~a: ~a is stocked in ~s but ~a is declared ~s — one is a rate, the other a stock"
                          label (economic-resource-id r) ru sid su))))
         ($ ($ root 'observer) 'all-resources))))))

(define splits (append-map (lambda (p) (denomination-splits (car p) (cdr p))) %scopes))
(for-each (lambda (l) (format #t "  ~a\n" l)) splits)

(check-pred "a rate is declared a rate, and a stock a stock"
            (null? splits))

(test-summary!)
