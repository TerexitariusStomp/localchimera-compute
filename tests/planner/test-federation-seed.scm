;;; test-federation-seed.scm — a federation's inventories are seeded as resources.
;;;
;;; seed-federation-inventory named `generate-id` without importing it, so seeding any
;;; scope's inventory raised on its first item.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-federation-seed.scm

(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet knowledge recipes federation)
             (goblins) (srfi srfi-1))

(define vat (spawn-vat #:name "fed-seed"))
(define seeded '())
(define observer (with-vat vat (spawn ^mock `((seed-resource . ,(lambda (r) (set! seeded (cons r seeded)) "ok"))))))

(with-vat vat
  (seed-federation-inventory observer
    '(("commune-a" ("wheat" 40.0 "kg") ("tools" 3.0 "each"))
      ("commune-b" ("wheat" 10.0 "kg")))))

(display "\n── each inventory item becomes a resource of its scope ──\n")
(check "one resource per item" (length seeded) 3)
(check "each holds what the inventory states"
       (sort (map (lambda (r) (list (economic-resource-primary-accountable r) (economic-resource-conforms-to r)
                                    (measure-has-numerical-value (economic-resource-onhand-quantity r))))
                  seeded)
             (lambda (a b) (string<? (format #f "~s" a) (format #f "~s" b))))
       '(("commune-a" "tools" 3.0) ("commune-a" "wheat" 40.0) ("commune-b" "wheat" 10.0)))
(check "ids are distinct" (length (delete-duplicates (map economic-resource-id seeded))) 3)

(test-summary!)
