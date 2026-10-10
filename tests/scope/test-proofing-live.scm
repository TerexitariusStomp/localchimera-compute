;;; test-proofing-live.scm — a thermal step a scope plans, live: proofed dough.
;;;
;;; knowledge/recipes/proofing.scm seeds knead → proof → bake-proofed on a scope's
;;; recipe store through the one door, and the live solve (`plan-scope`, with
;;; energy closure on: live.scm scope-composition passes the elements and heat)
;;; plans it: bread wanted today is baked from proofed dough, and the proof buys
;;; exactly c·ΔT of electricity per kilogram. Without electricity to draw, the
;;; proof cannot run and no bread is baked — the thermal step is a real step,
;;; priced like any other input (docs/observation/physics.md §2–3).
;;;
;;; Run:  guile -q -L module tests/scope/test-proofing-live.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet scope root) (playnet vf schemas)
             (playnet knowledge dsl shorthand) (playnet knowledge dsl world)
             (playnet knowledge recipes proofing)
             ((playnet scope live) #:select (plan-scope scope-composition))
             (goblins) (srfi srfi-1))

(define PLACE "town")
(define win (all-week-window "06:00" "18:00"))   ; every day: the test stands on today, whatever day that is

(define (scope-with! electricity-kwh)
  "A scope with flour, a baker, a proofing box, ELECTRICITY-KWH on hand, and the
   proofing chain seeded; returns the root."
  (let ((root (spawn-scope-root "bakery")))
    (seed-world! root
      (world #:specs (list (spec* "flour" "Flour" "kg") (spec* "bread" "Bread" "kg") (spec* "skill-bake" "Bake labour" %effort-unit)
                           (spec* "spec-sp-electricity" "Electricity" "kWh")
                           (spec* "proofing-box" "Proofing box" "hours/day" #:keep-in-place #t))
             #:spatials (list (place* PLACE))
             #:agents (list (person* "ada" #:name "Ada" #:place PLACE #:window win))
             #:resources (append
                          (list (er "fl" "flour" #f #:name "flour" #:place PLACE #:qty 100.0 #:unit "kg")
                                (er "skill-bake:ada" "skill-bake" "ada")
                                (er "box" "proofing-box" #f #:name "the box" #:place PLACE #:qty 100.0 #:unit "hours/day"))
                          (if (> electricity-kwh 0)
                              (list (er "grid" "spec-sp-electricity" #f #:name "grid" #:place PLACE #:qty electricity-kwh #:unit "kWh"))
                              '()))))
    (seed-proofing! ($ root 'recipe-store))
    root))

(define (fill-of root)
  (call-with-values (lambda () (plan-scope root #:reproduce? #f #:demand (list (cons (format #f "bread#~a@0" PLACE) 10.0))
                                          #:periods '(0) #:backend 'native-c #:allow-infeasible? #t))
    (lambda (ints coms material fill x ntot report) fill)))

(define vat (spawn-vat))
(with-vat vat
  (display "\n── the seed ──\n")
  (let* ((root (scope-with! 1000.0)) (rs ($ root 'recipe-store)))
    (check "the proofed form is on the store, named by its excess" (and ($ rs 'get-resource-spec proofed-dough-id) #t) #t)
    (check-pred "…with its heat stated, c·ΔT per kilogram over the dough's own formation: one frame"
                (let ((row (resource-specification-composition ($ rs 'get-resource-spec proofed-dough-id)))
                      (base (resource-specification-composition ($ rs 'get-resource-spec "dough"))))
                  (< (abs (- (- (assoc-ref row "heat") (assoc-ref base "heat")) (/ (* %dough-specific-heat %proof-delta-t) 3600.0))) 1e-9)))
    (check-pred "the scope's composition in force carries the form's heat, for the solve's closure"
                (let ((row (assoc-ref (scope-composition root) proofed-dough-id)))
                  (and row (assoc-ref row "heat") #t)))
    (check-pred "the relaxation recipe holds it in the box" (and ($ rs 'get-recipe-process (string-append "relax." proofed-dough-id)) #t))

    (display "\n── the live solve ──\n")
    (let ((fill (fill-of root)))
      (format #t "  with electricity: bread demand met ~,3f~%" fill)
      (check-pred "bread wanted today is baked from proofed dough: the demand is met" (> fill 0.95))))
  ;; a trace of electricity, far short of what a proof of this dough draws: a
  ;; scope that declares electricity and holds none is a hole in the books
  ;; (RAW-LINT reads it as starved), and a trace says the same thing honestly
  (let* ((root (scope-with! 0.001)) (fill (fill-of root)))
    (format #t "  with a trace of electricity: bread demand met ~,3f~%" fill)
    (check-pred "without the electricity a proof draws, it cannot run and no bread is baked: the thermal step is priced"
                (< fill 0.05))))

(test-summary!)
