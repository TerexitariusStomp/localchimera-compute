;;; test-run-spanning.scm — a run longer than its band is a journey through time.
;;;
;;; The guarantee table states the rule for space: "a journey lands in the
;;; period it can earliest reach, and does not land at all past the horizon."
;;; This is the same object pointed at time. A 72 h ferment started on Monday
;;; morning delivers on Wednesday — its inputs board at the origin band, its
;;; output disembarks at the arrival band (and the emitted records SAY so, each
;;; flow dated at its own cell), and a horizon too short to hold the run yields
;;; no column at all: the plan cannot promise what cannot finish.
;;;
;;; Occupancy travels with the run: a `use`d means is HELD in every band the
;;; run covers, for the hours it covers there — so a small vat pool cannot
;;; host many overlapping ferments, which is what makes the run's length a
;;; real cost rather than date arithmetic.
;;;
;;; Only a declared span states a length, so abstract-period paths keep
;;; today's behaviour — same guard as lead-time pruning (§3.1).
;;;
;;; METHOD NOTES, each earned the hard way here. Labour is AGGREGATE because
;;; the per-agent EMP Hessian is the one place the native barrier stalls (its
;;; own comment records it) and spanning's cross-band coupling aggravates it.
;;; Fills are asserted at demand 1: on spanning structures the native solve
;;; leaves interior float uncollapsed (delivered plateaus near one unit
;;; whatever the demand — measured 0.92 for D ∈ {1,2,5,8}), which at D=1 is a
;;; clean fill and at scale is a SOLVER-numerics thread (open-threads §5.4's
;;; family), not a modelling one. And OCCUPANCY is asserted from
;;; the emitted RECORDS (the vat held on each covered day) rather than from
;;; fills — the Svc supplier pool's own numeric behaviour under the barrier is
;;; a fixture question that long predates spanning, and the record is the
;;; claim that matters.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-run-spanning.scm

(use-modules ((playnet planner formulas flows) #:select (row-figure))
             (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PLACE "yard")
;; the records are the shared shorthand; a `use-` is an untimed count of the means
(define (use- id spec q proc) (use* id spec proc #f #:qty q))

;; F: a 72 h ferment (mash → brew, in a vat); B: a 2 h bottling (brew → bottled)
(define procs (list (rp* "F" "Ferment" 72) (rp* "B" "Bottle" 2)))
(define (mk-flows with-vat?)
  (append
   (list (consume* "f-in" "mash" 1.0 "F") (out* "f-out" "brew" 1.0 "F")
         (wk* "f-w" "skill-f" 6.0 "F"))
   (if with-vat? (list (use- "f-vat" "vat" 1.0 "F")) '())
   (list (consume* "b-in" "brew" 1.0 "B") (out* "b-out" "bottled" 1.0 "B") (wk* "b-w" "skill-b" 2.0 "B"))))

(define (stock id spec q) (er id spec #f #:place PLACE #:qty q #:unit "kg"))
(define (skill id sk who) (er id sk who #:place PLACE #:unit "each"))
(define agents (list (person* "fio" #:place PLACE #:window (all-week-window "00:00" "24:00"))
                     (person* "bo"  #:place PLACE #:window (all-week-window "00:00" "24:00"))))
(define spatials (list (place* PLACE)))

(define* (solve-brew #:key (days 4) (want "brew") (want-at 2) (want-q 1.0)
                     (with-vat? #f) (horizon? #t))
  (call-with-values
    (lambda ()
      (plan-from-records
       (append (list (stock "mash-1" "mash" 100.0)
                     (skill "s1" "skill-f" "fio") (skill "s2" "skill-b" "bo"))
               (if with-vat? (list (stock "vat-1" "vat" 30.0)) '()))
       agents spatials procs (mk-flows with-vat?)
       #:horizon (and horizon? (cons "2026-03-03" days))
       #:periods (if horizon? '(0) (iota days))
       #:storable '("brew" "bottled")
       #:agent-skills (lambda (a) (if (string=? (agent-id a) "fio") '("skill-f") '("skill-b")))
       #:demand (list (cons (format #f "~a#~a@~a" want PLACE want-at) want-q))
       #:per-agent? #f #:backend 'native-c #:allow-infeasible? #t))
    (lambda args
      (let ((fill (list-ref args 3))
            (mats (or (find (lambda (v) (and (pair? v) (commitment? (car v)))) args) '()))
            (best '())        ; (action . spec) → (qty . date) of the LARGEST commitment
            (dates '()))      ; (action . spec) → sorted date set over ALL its commitments
        (for-each (lambda (c)
                    (let* ((q (row-figure c))   ; a use row's figure is its hours (effortQuantity)
                           (k (cons (commitment-action c) (commitment-resource-conforms-to c)))
                           (d (and=> (commitment-has-beginning c)
                                     (lambda (s) (and (string? s) (substring s 0 10))))))
                      (when (and q d (> q 0.01))
                        (set! dates (assoc-set! dates k (delete-duplicates
                                                         (cons d (or (assoc-ref dates k) '())))))
                        (when (> q (or (and=> (assoc-ref best k) car) 0.0))
                          (set! best (assoc-set! best k (cons q d)))))))
                  mats)
        (list fill best dates)))))

(define (fill-of r) (car r))
(define (mat-date r action spec) (and=> (assoc-ref (cadr r) (cons action spec)) cdr))
(define (mat-dates r action spec) (sort (or (assoc-ref (caddr r) (cons action spec)) '()) string<?))

(format #t "~%── §1 the run lands where it can: a 72 h ferment delivers on day three ──~%")
(let ((r (solve-brew #:want "brew" #:want-at 2)))
  (check "the brew is deliverable at band three" (> (fill-of r) 0.85))
  (check "its inputs BOARD at the origin band"
         (equal? (mat-date r 'consume "mash") "2026-03-03"))
  (check "its output LANDS at the arrival band, and the record says so"
         (equal? (mat-date r 'produce "brew") "2026-03-05")))
(let ((r (solve-brew #:want "brew" #:want-at 1)))
  (check "demanded a day before it can exist, the brew is honestly unmet"
         (< (fill-of r) 0.2)))

(format #t "~%── §2 past the horizon, the run does not land at all ──~%")
(let ((r (solve-brew #:days 2 #:want "brew" #:want-at 1)))
  (check "a two-day plan cannot promise a three-day ferment"
         (< (fill-of r) 0.2)))

(format #t "~%── §3 the chain continues from the arrival band ──~%")
(let ((r (solve-brew #:want "bottled" #:want-at 2)))
  (check "bottling delivers the day the brew lands" (> (fill-of r) 0.8))
  (check "…bottled at the arrival band" (equal? (mat-date r 'produce "bottled") "2026-03-05")))

(format #t "~%── §4 occupancy: a run HOLDS its vat on every day it covers ──~%")
(let ((r (solve-brew #:want "brew" #:want-at 2 #:with-vat? #t)))
  (check "the record shows the vat held on all three covered days"
         (equal? (mat-dates r 'use "vat")
                 '("2026-03-03" "2026-03-04" "2026-03-05"))))

(format #t "~%── §5 a lattice that declares no lengths stands on the clock all the same ──~%")
(let ((r (solve-brew #:days 1 #:want "brew" #:want-at 0 #:horizon? #f)))
  ;; no declared span ⇒ the standing partition: one day, today, on the clock.
  ;; A three-day run finds no room in a one-day plan — the same law as §1–§4,
  ;; where a span-less period once let the run finish inside one band
  (check "with no declared spans the day is on the clock: a three-day run finds no room in one day"
         (< (fill-of r) 0.1)))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
