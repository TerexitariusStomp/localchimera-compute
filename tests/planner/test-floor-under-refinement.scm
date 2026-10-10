;;; test-floor-under-refinement.scm — a reproduction floor stated for a day
;;; holds for the DAY once the clock refines it into bands.
;;;
;;; The bug this closes: apply-repro-bands! poured a bare floor into *init* at
;;; its literal key, and under sub-day refinement that key named a band no
;;; column touched — so the floor EVAPORATED silently (feasible certificate,
;;; nothing produced). Now every band key takes the world's own addressing
;;; (*locate-key*: date → period, coarse → its stretch's first piece), a floor
;;; over a stretch becomes the day's balance wall (Σ bands ≥ floor, each
;;; band's own conservation untouched), and a band on a good no column of its
;;; stretch touches dies loudly. Span-less worlds are byte-identical to before.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-floor-under-refinement.scm

(use-modules (playnet test harness)
             ((playnet test planner prelude) #:select ())
             (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (playnet knowledge recipes bread-commune-seed)
             ((playnet utils clock) #:select (now instant->civil))
             (srfi srfi-1))

(define procs bread-procs)
(define flows bread-flows)
(define resources (append bread-stores   ; what the stones, the loaf and the oven draw
                  (list (er "soil-1" "soil" #f #:qty 1000.0) (er "sk1" "skill-farm" "farmer")
                        (er "sk2" "skill-bake" "ada") (er "sk3" "skill-mill" "ada"))))
;; 09:00–17:00 every day: the clock boundaries that refine each day into bands
(define win bread-window)
(define agents (list (make-agent #:id "farmer" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "ada" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials bread-spatials)
(define (day+ n) (substring (instant->civil (inexact->exact (round (+ (now) (* n 86400))))) 0 10))
(define three-days (map (lambda (n) (cons (day+ n) (day+ n))) '(0 1 2)))

(define (solve . kw)
  (call-with-values
    (lambda () (apply plan-from-records resources agents spatials procs flows
                      #:per-agent? #f #:backend 'native-c kw))
    (lambda (ints coms mat fill cols x idx ntot report)
      (let ((c (assq-ref report 'certificate)))
        (list (and (list? c) (assq-ref c 'feasible?))
              ;; total runs of PROC across every column
              (lambda (proc)
                (fold (lambda (col acc)
                        (let ((parts (string-split (col-key col) #\|)))
                          (let ((j (hash-ref idx (col-key col) #f)))   ; a pruned column has no slot
                            (if (and j (= 3 (length parts)) (equal? proc (cadr parts)))
                                (+ acc (vector-ref x j))
                                acc))))
                      0.0 cols)))))))
(define (raises? thunk) (catch #t (lambda () (thunk) #f) (lambda _ #t)))

(display "\n── 1. span-less: the floor pours into *init* exactly as before ──\n")
(let* ((r (solve #:demand '(("bread#town@0" . 4.0)) #:repro-floors '(("bread#town@0" . 1.0))))
       (runs (cadr r)))
  (check "feasible" (eq? #t (car r)))
  (check "the want sits on top of the floor: bake ≈ 5 (4 wanted + 1 floor)"
         (< (abs (- (runs "bake") 5.0)) 0.2)))

(display "\n── 2. refined days: a floor stated for day 2 holds for DAY 2 ──\n")
(let* ((r (solve #:demand '() #:repro-floors '(("bread#town@2" . 1.0))
                 #:storable '("soil" "grain" "flour" "bread") #:period-spans three-days))
       (runs (cadr r)))
  (check "feasible — the floor is a day's wall over its bands, no longer a first-band fact"
         (eq? #t (car r)))
  (check "…and bread is actually baked (≥ the floor)" (>= (runs "bake") 0.99)))

(display "\n── 3. refined day: a same-day one-step floor holds — with NO storable declared ──\n")
;; the soil stock lands on the day's first band (00:00–09:00); the farmer
;; works 09:00–17:00. What a day holds carries between its own bands
;; whatever the storability declaration says — storability is cross-day.
(let* ((r (solve #:demand '() #:repro-floors '(("grain#town@0" . 1.0))
                 #:period-spans (list (car three-days))))
       (runs (cadr r)))
  (check "feasible: the morning's soil is the same soil at noon" (eq? #t (car r)))
  (check "grain grown ≥ the floor" (>= (runs "grow") 0.99)))
(check "…and across DAYS nothing non-storable carries (storability keeps its meaning)"
       ;; the impossibility IS the point here, and the plan-invariants contract
       ;; wants that declared: without #:allow-infeasible? an infeasible solve
       ;; raises instead of certifying (solver.scm)
       ;; nothing storable: day 1's grow has no soil, its mill no power (both stayed
       ;; on day 0) and day 0's grain cannot wait ⇒ the day-1 floor cannot be held.
       ;; With no column left touching day 1's grain the solve refuses the floor
       ;; outright (section 4's refusal); with one left it certifies it unmet.
       (catch #t
         (lambda ()
           (let ((r (solve #:demand '() #:repro-floors '(("grain#town@1" . 1.0))
                           #:period-spans three-days #:allow-infeasible? #t)))
             (not (eq? #t (car r)))))
         (lambda _ #t)))

(display "\n── 4. fail-closed: a floor on a good no column touches dies loudly ──\n")
(check "span-less: refused"
       (raises? (lambda () (solve #:demand '() #:repro-floors '(("cheese#town@0" . 1.0))))))
(check "refined: refused"
       (raises? (lambda () (solve #:demand '() #:repro-floors '(("cheese#town@0" . 1.0))
                                  #:period-spans (list (car three-days))))))

(test-summary!)
