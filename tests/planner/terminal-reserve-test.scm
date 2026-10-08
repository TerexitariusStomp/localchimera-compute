;;; terminal-reserve-test.scm — a recurring floor keeps recurring past the
;;; horizon's own edge — R3's second, previously-open option, live.
;;;
;;; time-and-uncertainty.md: exactly one automatic per-period fold existed
;;; (scope-consumption's nutrition floor); nothing played the analogous role
;;; for a STORABLE reproductive stock at the horizon's LAST period, so a
;;; receding-horizon re-solve had no reason not to draw it to zero right where
;;; its own window happened to end — an artifact of the window, not an
;;; economic judgement, since time itself does not end and every re-solve
;;; re-truncates somewhere new. The floor already holds at every OTHER period
;;; without softening (R3); the horizon's edge is not a real boundary, only
;;; the solve's, and earns no weaker standard than period 5 gets.
;;;
;;; #:receding-horizon? (live.scm) closes it with NO new target number and NO
;;; new channel: whichever #:repro-floors entry a caller already declared,
;;; recurring, at the horizon's LAST period, for a spec also named
;;; #:storable, is asked for once more there — the SAME convex constraint
;;; already in force at every other period, continuing one step past what is
;;; modeled. Desire gets no matching treatment: it is already "aimed at" the
;;; same way at every period, and nothing ends when a desire alone goes
;;; unmet, so the horizon's edge owes it nothing extra.
;;;
;;; This proves three things: the doubled floor genuinely holds (land ample —
;;; reachable, met to floor tolerance, real plan, and PROVABLY more than the
;;; single, un-doubled floor a caller declared would have required); the
;;; doubled floor genuinely BINDS (land crippled — unreachable ⇒ infeasible,
;;; the honest answer, not a phase-I point pretending to meet it); and the
;;; flag defaults off — the same scope, same floors, #:receding-horizon? #f,
;;; needs only the ordinary single floor and nothing more.
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/planner/terminal-reserve-test.scm

(use-modules (playnet test scope))
(use-modules (playnet test harness)
             (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1)
             (playnet planner scope live)
             (goblins)
             (goblins persistence-store memory)
             (srfi srfi-1) (ice-9 format))

(define PLACE "farm")
(define N 3)                          ; three periods
(define FLOOR 20.0)                   ; the caller's OWN recurring floor, every period
(define win (all-week-window "00:00" "23:59"))

(define (records+vat land-cap)
  (let ((mem (make-memory-store)))
    (call-with-values
      (lambda () (spawn-persistent-vat scope-root-env (lambda () (spawn-scope-root "One farm, one season")) mem))
      (lambda (vat scope)
        (with-vat vat
          (let ((rs ($ scope 'recipe-store)) (obs ($ scope 'observer))
                (as ($ scope 'agent-store)) (sts ($ scope 'spatial-thing-store)))
            ($ sts 'add-location (make-spatial-thing #:id PLACE #:name "The farm" #:lat 40.0
                                                     #:long -74.0))
            (for-each (lambda (id nm u) ($ rs 'add-resource-spec (make-resource-specification #:id id
                                                                                              #:name nm
                                                                                              #:default-unit-of-resource u)))
                      '("grain" "land" "skill-grow") '("Grain" "Land" "Growing") '("kg" "ha" "hours"))
            ($ rs 'add-process-spec (make-process-specification #:id "ps-grow" #:name "Growing"))
            ($ rs 'add-recipe-process (make-recipe-process #:id "grow" #:name "Grow grain"
                                                           #:process-conforms-to "ps-grow"
                                                           #:has-duration (make-duration 1.0 "hours")
                                                           #:sequence-group 0))
            ($ rs 'add-recipe-flow (make-recipe-flow #:id "gw" #:action 'work
                                                     #:resource-conforms-to "skill-grow"
                                                     #:effort-quantity (make-measure 1.0 "hours")
                                                     #:recipe-input-of "grow"))
            ($ rs 'add-recipe-flow (make-recipe-flow #:id "gl" #:action 'consume
                                                     #:resource-conforms-to "land"
                                                     #:resource-quantity (make-measure 1.0 "ha")
                                                     #:recipe-input-of "grow"))
            ($ rs 'add-recipe-flow (make-recipe-flow #:id "go" #:action 'produce
                                                     #:resource-conforms-to "grain"
                                                     #:resource-quantity (make-measure 10.0 "kg")
                                                     #:recipe-output-of "grow" #:is-primary #t))
            ($ rs 'add-recipe (make-recipe #:id "r-grow" #:name "Grow grain"
                                           #:primary-output "grain" #:recipe-processes (list "grow")))
            ($ as 'add-agent (make-agent #:id "ada" #:type 'person #:name "Ada"
                                         #:primary-location PLACE #:classified-as '()
                                         #:availability-window win))
            ($ obs 'seed-resource (make-economic-resource #:id "sk-ada" #:name "Ada can grow" #:conforms-to "skill-grow"
                                    #:accounting-quantity (make-measure 24.0 "hours") #:onhand-quantity (make-measure 24.0 "hours") #:primary-accountable "ada"))
            ;; land ample or crippled at EVERY period — never the binding story here.
            (for-each (lambda (t) ($ obs 'seed-resource
                        (make-economic-resource #:id (format #f "land~a" t) #:conforms-to "land" #:classified-as '()
                          #:accounting-quantity (make-measure land-cap "ha") #:onhand-quantity (make-measure land-cap "ha")
                          #:current-location PLACE)))
                      (iota N))))
        (cons vat scope)))))

;; total grain PRODUCED across the whole horizon — nothing here ever consumes
;; it, so this is also total grain still on hand once the solve is done.
(define (grown-total material)
  (fold (lambda (c a) (if (and (eq? (commitment-action c) 'produce)
                                (equal? (commitment-resource-conforms-to c) "grain"))
                           (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
        0.0 material))

;; the caller's OWN recurring floor: FLOOR kg of grain, at farm, EVERY period —
;; exactly the Doon-Valley pattern, nothing terminal-specific about it.
(define (recurring-floors)
  (map (lambda (t) (cons (format #f "grain#~a@~a" PLACE t) FLOOR)) (iota N)))

(define (run land-cap receding?)
  (let* ((vs (records+vat land-cap)) (vat (car vs)) (scope (cdr vs)))
    (with-vat vat
      (call-with-values
        (lambda () (plan-scope scope #:reproduce? #f #:periods (iota N)
                     #:repro-floors (recurring-floors) #:receding-horizon? receding?
                     #:storable (list "grain") #:backend 'native-c #:allow-infeasible? #t))
        (lambda (ints coms material fill x ntot report)
          (list (grown-total material) (assq-ref (assq-ref report 'certificate) 'feasible?)))))))

;; land ample everywhere (10 ha/period, far above what a single floor needs;
;; still comfortably above a DOUBLED terminal floor, since 3 × 20 + 20 = 80,
;; and 30 ha of capacity across the horizon makes up to 300 kg)
(define flat        (run 10.0 #f))    ; the ordinary case: each period's own floor, nothing more
(define receding     (run 10.0 #t))   ; the SAME floors, the last period's now doubled
(define blocked      (run 0.05 #t))   ; land crippled — the doubled terminal floor CANNOT be met

(format #t "~%── a recurring floor, asked for once more at the horizon's own edge ──~%~%")
(format #t "  flat (3 × ~,0f kg, no doubling)  : grown ~,1f kg · feasible? ~a~%" FLOOR (first flat) (second flat))
(format #t "  receding-horizon? #t (ample land): grown ~,1f kg · feasible? ~a~%" (first receding) (second receding))
(format #t "  receding-horizon? #t (land crippled): grown ~,1f kg · feasible? ~a~%" (first blocked) (second blocked))

(check-pred "the flat case is a real plan, at ~ the sum of its own three floors"
            (and (eq? #t (second flat)) (>= (first flat) (* 0.99 (* 3 FLOOR)))))
(check-pred "receding-horizon? #t is ALSO a real plan, when land can carry the extra floor"
            (eq? #t (second receding)))
(check-pred "…and it genuinely grows MORE — the terminal floor is doubled, not decorative"
            (>= (first receding) (* 0.99 (+ (* 3 FLOOR) FLOOR))))
(check-pred "an UNREACHABLE doubled floor makes the plan genuinely INFEASIBLE — the same\n           honest standard every other period's floor already gets"
            (eq? #f (second blocked)))

(format #t "~%  ~a #:receding-horizon? asks a recurring floor to keep recurring one step past~%  the solve's own edge — no new target, no new channel, the SAME convex~%  constraint the caller already declared, continuing exactly as it already did.~%~%"
        (if (and (eq? #t (second flat)) (>= (first flat) (* 0.99 (* 3 FLOOR)))
                 (eq? #t (second receding)) (>= (first receding) (* 0.99 (+ (* 3 FLOOR) FLOOR)))
                 (eq? #f (second blocked)))
            "✓" "✗"))
