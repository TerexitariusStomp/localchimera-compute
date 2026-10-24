;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; algorithms/unit-conversion.scm — Unit normalization for the netter.
;;;
;;; The netter does quantity arithmetic on plain numbers. When donors
;;; report in cases, pallets, lbs, and pieces, these must normalize
;;; to a canonical unit before entering the netter. The canonical unit
;;; is the resource-specification's default-unit-of-resource.
;;;
;;; Conversion factors are stored as an alist on the recipe-store
;;; (or could be on the resource-specification itself). The table
;;; maps (from-unit . to-unit) → factor.

(use-modules (srfi srfi-1))


(define *unit-conversions*
  ;; Default conversion table. Projects can extend via recipe-store metadata.
  '(("kg" . (("lbs" . 0.4536) ("g" . 0.001) ("tonnes" . 1000)))
    ("each" . (("case" . 12) ("pallet" . 480) ("dozen" . 12)))
    ("hours" . (("minutes" . 0.01667) ("days" . 24)))))

(define (find-conversion from to)
  "Find conversion factor: 1 FROM = ? TO. Returns factor or #f."
  (cond
    ((equal? from to) 1)
    ((let ((row (assoc to *unit-conversions*)))
       (and row (let ((entry (assoc from (cdr row))))
                  (and entry (cdr entry))))))
    ((let ((row (assoc from *unit-conversions*)))
       (and row (let ((entry (assoc to (cdr row))))
                  (and entry (/ 1 (cdr entry)))))))
    (else #f)))

(define (normalize-quantity qty from-unit spec)
  "Normalize QTY from FROM-UNIT to the spec's canonical unit.
   Returns (values normalized-qty canonical-unit) or (values qty from-unit)
   if no conversion is available."
  (let ((canonical (and spec (resource-specification-default-unit-of-resource spec))))
    (if (or (not canonical) (equal? from-unit canonical))
        (values qty from-unit)
        (let ((factor (find-conversion from-unit canonical)))
          (if factor
              (values (* qty factor) canonical)
              (values qty from-unit))))))

(define (normalize-supply-entry entry recipe-store)
  "Normalize a supply entry's quantity to canonical units."
  (let* ((spec-id (assq-ref entry 'spec-id))
         (spec (and spec-id recipe-store
                    ($ recipe-store 'get-resource-spec spec-id)))
         (qty (assq-ref entry 'quantity))
         (unit (or (assq-ref entry 'unit) "each")))
    (if (not spec) entry
        (let-values (((nq nu) (normalize-quantity qty unit spec)))
          (cons (cons 'quantity nq)
                (cons (cons 'unit nu)
                      (filter (lambda (p)
                                (not (memq (car p) '(quantity unit))))
                              entry)))))))
