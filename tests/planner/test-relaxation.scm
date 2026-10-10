;;; test-relaxation.scm — a warmed form relaxes to its base through the enclosure
;;; that holds it, and heat closes like carbon.
;;;
;;; docs/observation/readings-are-counts.md §1.5 facts 2, 5 and 6, on the engine
;;; as it stands (no engine change): the relaxation recipe of knowledge/thermal.scm
;;; is a store recipe whose loss lands in two named outputs, the base form and
;;; `ambient-heat`, so the plan that wants a warmed batch two days on must warm
;;; enough on Monday for what relaxes, and every kWh of heat in a warmed form was
;;; bought as electricity — element closure over the leaf "heat".
;;;
;;;   • held k periods, a fraction f relaxing each: to deliver D the plan warms
;;;     at least D/(1−f)^k, and each hop holds at most (1−f) of the one before.
;;;     Both are BOUNDS: the interior-point backend sits a few percent inside
;;;     every balance row, so the exact arithmetic is pinned on the pure
;;;     functions (tests/planner/test-reading-convert.scm) and the engine is
;;;     held to the physics as inequalities plus a slack ceiling. The lattice
;;;     here is 12-hour bands (a 12-hour window refines the day), so f is per
;;;     band and a warmed form never rides the day's free intra-day carry: an
;;;     excess relaxes within the day (engine.scm build-columns, excess-good?);
;;;   • the fraction from τ is 1 − e^(−p/τ), from convert.scm;
;;;   • closure: a warm recipe stating less electricity than the heat it puts in the
;;;     form cannot run (creation refused); one stating exactly it runs;
;;;   • no conductance ⇒ no records ⇒ nothing in the world changes.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-relaxation.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet knowledge catalogues thermal)
             ((playnet observation convert) #:select (carry-fraction time-constant)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b . tol) (< (abs (- a b)) (if (pair? tol) (car tol) 1e-3)))

(define PLACE "farm")
(define F 0.2)                                 ; a fifth relaxes each band (12 h)
(define C 2.5)                                 ; kJ/(kg·K), dough
(define DT 6)                                  ; six degrees over ambient
(define DH (/ (* C DT) 3600.0))                ; kWh per kg of excess: 0.004167
(define win0 (hours-of 12))                    ; Ada works Monday alone

(define-values (WARMED COMP) (thermal-composition "dough" C DT))

(define (records electricity-per-kg with-relax?)
  (let* ((room-spec (spec* "room" "The warm room" "hours/day" #:keep-in-place #t))
         (room  (er "room1" "room" #f #:name "the room" #:place PLACE #:qty 100.0 #:unit "hours/day"))
         (power (er "grid" "spec-sp-electricity" #f #:name "the grid" #:place PLACE #:qty 1000.0 #:unit "kWh"))
         (skill (er "sk" "skill" "ada" #:place PLACE #:qty 1.0 #:unit "kg"))
         (procs (list (rp* "grow" "Grow") (rp* "warm" "Warm the dough")))
         (flows (list (out* "go" "dough" 100.0 "grow")
                      (wk* "gw" "skill" 1.0 "grow")
                      (consume* "wi" "dough" 1.0 "warm")
                      (consume* "we" "spec-sp-electricity" electricity-per-kg "warm" "kWh")
                      (out* "wo" WARMED 1.0 "warm")
                      (wk* "ww" "skill" 0.01 "warm"))))
    (call-with-values
      (lambda () (if with-relax?
                     (relaxation-records WARMED "dough" DH "room" #:fraction F)
                     (values '() '())))
      (lambda (rprocs rflows)
        (values (list room power skill) (append procs rprocs) (append flows rflows) (list room-spec))))))

(define (solve electricity-per-kg with-relax? demand-qty)
  (call-with-values (lambda () (records electricity-per-kg with-relax?))
    (lambda (resources procs flows specs)
      (call-with-values
        (lambda () (plan-from-records resources
                     (list (person* "ada" #:name "Ada" #:place PLACE #:window win0))
                     (list (place* PLACE))
                     procs flows
                     #:specs specs
                     #:composition COMP
                     #:demand (list (cons (format #f "~a#~a@4" WARMED PLACE) demand-qty))   ; Wednesday morning: four bands on
                     #:horizon (cons "2026-08-03" 3)      ; Mon, Tue, Wed — six 12-hour bands
                     #:per-agent? #f #:backend 'native-c
                     #:allow-infeasible? #t))
        (lambda (i c material fill cols x idx nt rep)
          (define (col k) (let ((j (hash-ref idx k #f))) (if j (vector-ref x j) 0.0)))
          (list fill
                (col (format #f "p|warm|~a@0" PLACE))
                (map (lambda (t) (col (format #f "p|relax.~a|~a@~a|~a@~a" WARMED PLACE t PLACE (+ t 1)))) '(0 1 2 3))
                (col (format #f "m|~a|~a@0|~a@1" WARMED PLACE PLACE))
                (assq-ref (assq-ref rep 'certificate) 'feasible?)))))))

(format #t "~%── the fraction, from the physics ──~%")
(check "1 − e^(−p/τ): τ = 24/ln(1.25) h gives a fifth per day"
       (near? (relaxation-fraction #:tau (/ 24.0 (log 1.25)) #:period-hours 24.0) F 1e-9))
(check "…and from mass, specific heat and conductance through time-constant"
       (near? (relaxation-fraction #:mass 100 #:specific-heat C #:ua 0.01 #:period-hours 24.0)
              (- 1.0 (carry-fraction (time-constant 100 C 0.01) 24.0)) 1e-12))
(check "no conductance stated: nothing relaxes, no records"
       (and (= 0.0 (relaxation-fraction))
            (call-with-values (lambda () (relaxation-records WARMED "dough" DH "room")) (lambda (p f) (and (null? p) (null? f))))))
(check "the warmed form is named by its excess and carries 0.0042 kWh/kg"
       (and (string=? WARMED "dough+6K") (near? (assoc-ref (assoc-ref COMP WARMED) "heat") DH 1e-9)))

(format #t "~%── warmed grain wanted Wednesday morning; Ada works Monday alone ──~%")
(define D 10.0)
(define r (solve DH #t D))
(define held (third r))
(format #t "  fill ~,3f · warm ~,3f · held per band ~s · free carry ~,3f · feasible ~a~%"
        (first r) (second r) (map (lambda (v) (/ (round (* 1000 v)) 1000)) held) (fourth r) (fifth r))
(check "the demand is met" (near? (first r) 1.0 1e-3))
(define least (/ D (expt (- 1 F) 4)))          ; 24.414 kg: less warmed could never deliver D
(check "the plan warms at least D/(1−f)⁴ on Monday morning (24.414 kg), and within the solver's slack of it"
       (and (>= (second r) (* 0.99 least)) (<= (second r) (* 1.15 least))))
(check "what is held through the first band is at most what was warmed" (<= (first held) (* 1.01 (second r))))
(check "…and each band holds at most (1−f) of the one before, and near it: the relaxed fifth became grain"
       (every (lambda (a b) (and (<= b (* (- 1 F) a 1.01)) (>= b (* (- 1 F) a 0.95)))) held (cdr held)))
(check "a warmed form never rides the day's free carry" (< (fourth r) 1e-6))

(format #t "~%── heat closes like carbon ──~%")
(define cheat (solve (* 0.5 DH) #t D))
(format #t "  half the electricity: fill ~,3f · warm ~,3f~%" (first cheat) (second cheat))
(check "a warm recipe buying half the heat it puts in the form cannot run (creation refused)"
       (< (second cheat) 1e-6))
(define honest (solve (* 1.5 DH) #t D))
(check "one buying more than the heat runs; the surplus is loss, allowed" (near? (first honest) 1.0 1e-3))

(format #t "~%── without the relaxation recipe nothing carries ──~%")
(define bare (solve DH #f D))
(check "no store shape at all: the warmed grain has no way to Wednesday" (< (first bare) 1e-3))

(format #t "~%════════════════════════════════════════════~%")
(format #t "relaxation-test: ~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
