;;; test-thermal-form-door.scm — a scope declares a warmed form, and everything follows.
;;;
;;; knowledge/thermal.scm `declare-thermal-form!` on a scope's recipe store: the
;;; warmed form becomes a spec of its own with its heat and entropy STATED on the
;;; spec (docs/observation/physics.md §2–4), the base's row states the frame's
;;; zero, and the relaxation recipe that holds the form in its enclosure is on
;;; the store. Nothing is remembered anywhere else: the lint reads the store's
;;; stated compositions, the solve reads them through scope-composition, and a
;;; second scope knows nothing of the first's forms.
;;;
;;; Run:  guile -q -L module tests/planner/test-thermal-form-door.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas) (srfi srfi-1) (playnet vf schemas)
             (playnet knowledge catalogues thermal) (playnet knowledge dsl vf-lint)
             (playnet knowledge dsl findings)
             ((playnet knowledge catalogues substances) #:select (second-law-production *contains*))
             (goblins) (srfi srfi-1))

(define (approx= a b) (< (abs (- a b)) 1e-9))
(define vat (spawn-vat))
(define root (with-vat vat (spawn-scope-root "bakery")))
(define rs (with-vat vat ($ root 'recipe-store)))
(define* (spec! id unit #:optional (kip #f))
  ($ rs 'add-resource-spec (make-resource-specification #:id id #:name id
                                                        #:default-unit-of-resource unit
                                                        #:keep-in-place kip)))
(define (kinds fs) (map finding-kind fs))
(define (subjects fs kind) (map finding-subject (filter (lambda (f) (eq? (finding-kind f) kind)) fs)))

(display "\n── the declaration ──\n")
(define WARMED
  (with-vat vat
    (spec! "dough" "kg") (spec! "room" "hours/day" #t) (spec! "spec-sp-electricity" "kWh") (spec! "ambient-heat" "kWh")
    (declare-thermal-form! rs "dough" 2.5 6 "room" #:fraction 0.2)))
(check "the warmed form is named by its excess" WARMED "dough+6K")
(with-vat vat
  (let* ((w ($ rs 'get-resource-spec WARMED)) (b ($ rs 'get-resource-spec "dough"))
         (stated ($ rs 'stated-compositions)))
    (check-pred "the warmed spec exists in the base's unit" (and w (equal? "kg" (resource-specification-default-unit-of-resource w))))
    (check-pred "…and STATES its heat, 0.004167 kWh/kg, and its entropy"
                (and (approx= (assoc-ref (resource-specification-composition w) "heat") (/ 15.0 3600))
                     (assoc-ref (resource-specification-composition w) "entropy")))
    (check-pred "the base states the frame's zero" (and (assoc-ref (resource-specification-composition b) "heat")
                                                        (= 0.0 (assoc-ref (resource-specification-composition b) "entropy"))))
    (check "two stated compositions on the store, no more" (length stated) 2)
    (check-pred "the relaxation recipe is on the store, holding the form in the room"
                (let ((rp ($ rs 'get-recipe-process (string-append "relax." WARMED))))
                  (and rp (let ((fl ($ rs 'flows-for-process (string-append "relax." WARMED))))   ; (inputs . outputs)
                            (any (lambda (f) (and (eq? (recipe-flow-action f) 'use)
                                                  (equal? "room" (recipe-flow-resource-conforms-to f))))
                                 (append (car fl) (cdr fl)))))))))

(display "\n── the lint reads the store, and the second law reads the form ──\n")
(with-vat vat
  ;; a heat pump into the declared form claiming a hundredfold: refused; a tenfold passes
  (define Q (/ 15.0 3600))
  (define (pump! id cop)
    ($ rs 'add-recipe-process (make-recipe-process #:id id #:name id
                                                   #:has-duration (make-duration 1 %effort-unit)))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append id ".b") #:action 'consume
                                             #:resource-conforms-to "dough"
                                             #:resource-quantity (make-measure 1 "kg")
                                             #:recipe-input-of id))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append id ".w") #:action 'consume
                                             #:resource-conforms-to "spec-sp-electricity"
                                             #:resource-quantity (make-measure (/ Q cop) "kWh")
                                             #:recipe-input-of id))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append id ".a") #:action 'consume
                                             #:resource-conforms-to "ambient-heat"
                                             #:resource-quantity (make-measure (- Q (/ Q cop)) "kWh")
                                             #:recipe-input-of id))
    ($ rs 'add-recipe-flow (make-recipe-flow #:id (string-append id ".o") #:action 'produce
                                             #:resource-conforms-to WARMED
                                             #:resource-quantity (make-measure 1 "kg")
                                             #:recipe-output-of id #:is-primary #t))
    ($ rs 'add-recipe (make-recipe #:id (string-append "r-" id) #:name id #:primary-output WARMED
                                   #:recipe-processes (list id))))
  (pump! "pump-100" 100) (pump! "pump-10" 10))
(define fs (with-vat vat (lint-recipe-store rs)))
(check-pred "a hundredfold across six kelvin is refused by the second law, read off the store's rows"
            (member "pump-100" (subjects fs 'second-law)))
(check-pred "a tenfold passes" (not (member "pump-10" (subjects fs 'second-law))))
(check-pred "the relaxation recipe itself produces entropy and passes"
            (not (member (string-append "relax." WARMED) (subjects fs 'second-law))))

(display "\n── another scope knows nothing of it ──\n")
(define other (with-vat vat (spawn-scope-root "farm")))
(with-vat vat
  (check "a fresh scope states no composition" ($ ($ other 'recipe-store) 'stated-compositions) '())
  (check-pred "…and the chemistry table carries no warmed dough" (not (assoc-ref *contains* WARMED))))

(test-summary!)
