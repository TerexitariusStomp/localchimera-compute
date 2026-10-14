;;; test-people-wire-standard.scm — the dial draws the floors the plan holds.
;;;
;;; The fragility face draws each person's floors from the catalogue in the
;;; browser; the plan holds the same floors at the scope's ratified standard. So
;;; the people rows the scope pushes carry that standard (`standard`, the wire's
;;; `person-intake`), 1 until the scope ratifies one, and the browser reads the
;;; row as a person (ui/app/nutrition.ts `nutritionWire`).
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/doors/test-people-wire-standard.scm
(use-modules (playnet test harness)
             (playnet scope root) (playnet vf schemas)
             ((playnet doors plan-wire) #:select (scope-reproduction-people))
             ((playnet utils governed-row) #:select (merge-governed-row!))
             (goblins) (goblins vat)
             (srfi srfi-1))

(define (near? a b) (< (abs (- a b)) 1e-9))

(with-vat (spawn-vat #:name "people-wire-standard")
  (let* ((root (spawn-scope-root "S"))
         (as   ($ root 'agent-store))
         (ps   ($ root 'plan-store)))
    ($ as 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada" #:classified-as '("sex:F" "age:30")))
    (let ((row (car (scope-reproduction-people root '()))))
      (check "a scope that has ratified no standard pushes its people at 1" (near? 1 (assq-ref row 'standard))))
    (merge-governed-row! ps "governance-policy" '((standard . 1.3)))
    (let ((row (car (scope-reproduction-people root '()))))
      (check "a ratified standard rides the person's row" (near? 1.3 (assq-ref row 'standard))))
    (merge-governed-row! ps "governance-policy" '((standard . 0.4)))
    (check "a standard below 1 is pushed as 1: it only raises"
           (near? 1 (assq-ref (car (scope-reproduction-people root '())) 'standard)))))

(test-summary!)
