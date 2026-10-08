;;; formulas/flows.scm — a planned flow, read.
;;;
;;; What a plan lays down is ValueFlows: an Intent (an open need or an offer) or a
;;; Commitment (a flow somebody is held to). The two carry the same properties of a
;;; flow (its action, its specification, its quantity or effort, the process it
;;; stands on a side of, its place, when it begins), so everything that reads a
;;; plan's rows asks through the readers here and need not know which of the two it
;;; holds: `(row-action r)`, `(row-quantity r)`, `(row-place r)`.
;;;
;;; A quantity and an effort are read as their number, with `row-unit` for the unit
;;; the quantity is counted in, since the solve and the doors' tallies work in
;;; numbers of the specification's unit.
;;;
;;; A row is also read off the alist a plan held before its rows were records (a
;;; plan stored by an earlier build, docs/planning/codebase-organization.md §7): the
;;; same readers take it, so a stored plan reads as it did.

(define-module (playnet planner formulas flows)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:export (row-id row-action row-spec row-quantity row-unit row-effort
            row-provider row-input-of row-output-of row-run row-place
            row-when row-until row-note row-tags row-scope row-satisfies
            row-finished row-ambient? carried-lot-id %ambient-tag))

(define %ambient-tag "ambient")   ; resourceClassifiedAs of a flow with no stock behind it: the world's own, a means in use

(define (number-of m) (and m (measure-has-numerical-value m)))

;; one reader per property: of a Commitment, of an Intent, of a stored alist row
(define-syntax-rule (define-row-reader name of-commitment of-intent key)
  (define (name r)
    (cond ((commitment? r) (of-commitment r))
          ((intent? r) (of-intent r))
          (else (let ((p (and (pair? r) (assq 'key r)))) (and p (cdr p)))))))

(define-row-reader row-id        commitment-id intent-id id)
(define-row-reader row-spec      commitment-resource-conforms-to intent-resource-conforms-to conforms-to)
(define-row-reader row-provider  commitment-provider intent-provider provider)
(define-row-reader row-input-of  commitment-input-of intent-input-of input-of)
(define-row-reader row-output-of commitment-output-of intent-output-of output-of)
(define-row-reader row-place     commitment-at-location intent-at-location at-location)
(define-row-reader row-when      commitment-has-beginning intent-has-beginning when)
(define-row-reader row-until     commitment-has-end intent-has-end until)
(define-row-reader row-note      commitment-note intent-note note)
(define-row-reader row-tags      commitment-resource-classified-as intent-resource-classified-as classified-as)
(define-row-reader row-scope     commitment-in-scope-of intent-in-scope-of in-scope-of)
(define-row-reader row-satisfies commitment-satisfies intent-satisfies satisfies)
(define-row-reader row-finished  commitment-finished intent-finished finished)
(define-row-reader %action       commitment-action intent-action action)
(define-row-reader %quantity     commitment-resource-quantity intent-resource-quantity quantity)
(define-row-reader %effort       commitment-effort-quantity intent-effort-quantity effort)
(define-row-reader %unit         commitment-resource-quantity intent-resource-quantity unit)

(define (row-action r)
  "R's action, a symbol."
  (let ((a (%action r))) (if (string? a) (string->symbol a) a)))
(define (row-quantity r)
  "How much of its specification R moves, as a number; #f where it states none."
  (let ((q (%quantity r))) (if (measure? q) (number-of q) q)))
(define (row-unit r)
  "The unit R's quantity is counted in."
  (let ((u (%unit r))) (if (measure? u) (measure-has-unit u) u)))
(define (row-effort r)
  "The hours of effort R takes, as a number; #f where it states none."
  (let ((e (%effort r))) (if (measure? e) (number-of e) e)))

(define (row-run r)
  "The process R is a flow of: the one it is the output of, else the one it is an input of."
  (or (row-output-of r) (row-input-of r)))
(define (row-ambient? r)
  "No stock stands behind R: the world's own, or a means in use."
  (and (member %ambient-tag (or (row-tags r) '())) #t))
(define (carried-lot-id r)
  "The lot of its own a run's cargo is on the way: one per run and spec, the same for
   the pickup that fills it and the dropoff that empties it."
  (keyed-id "carry" (row-run r) (row-spec r)))
