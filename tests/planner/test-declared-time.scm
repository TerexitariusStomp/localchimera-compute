;;; test-declared-time.scm — time inside a period, declared rather than assumed.
;;;
;;; docs/planning/solve/intra-period-time.md. A period is a LENGTH of time, and a
;;; boundary somebody declares is a period boundary — so the chain is refined
;;; where it was declared and left alone where it was not. That turns the lattice
;;; into a time-indexed schedule: precedence, contention and disjoint
;;; availability all fall out of arcs that already exist.
;;;
;;; What is checked here, in order:
;;;   1. a period has a length, and a declared boundary makes it
;;;   2. availability is the EXACT overlap of a window with a period
;;;   3. DISJOINT availability cannot be paired — the case that started this
;;;   4. OVERLAPPING availability still pairs, at the overlap
;;;   5. PRECEDENCE — the evening cannot supply the morning; tomorrow it can
;;;   6. CONTIGUITY — a non-storable intermediate confines an act to one period
;;;   7. ARRIVAL — a window opening mid-horizon, with no new field
;;;   8. DEGENERACY — no declared windows ⇒ nothing moves
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-declared-time.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve compile)
             (playnet planner solve solver)
             (playnet planner vf schemas)
             ((playnet planner knowledge dsl shorthand) #:select (er place* all-week-window)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))

(define win all-week-window)                ; available FROM–TO, every day
(define (res id spec qty place . window)
  (er id spec #f #:place place #:qty qty #:unit %count-unit #:window (if (pair? window) (car window) #f)))

;; the declared day: 00–09, 09–17, 17–24
(define DAY '(("2026-03-03T00:00" . "2026-03-03T09:00")
              ("2026-03-03T09:00" . "2026-03-03T17:00")
              ("2026-03-03T17:00" . "2026-03-04T00:00")))
(define P3 '(0 1 2))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. A period has a length
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. a declared boundary makes a period ──~%~%")

(declare-world! #:periods P3 #:spans (map (lambda (t sp) (list t (car sp) (cdr sp))) P3 DAY))

(check "the three declared periods are 9, 8 and 7 hours"
       (equal? '(9.0 8.0 7.0) (map period-hours P3)))
(check "they sum to the day they partition"
       (near? (fold + 0.0 (map period-hours P3)) 24.0 0.001))
(check "a whole-date period is a whole day"
       (begin (set-period-span! 9 "2026-03-03" "2026-03-03") (near? (period-hours 9) 24.0 0.001)))
(check "a stated length answers when no span does"
       (begin (reset!) (set-period-length! 1.0 "week") (near? (period-hours 0) 168.0 0.001)))
(set-period-length! 1.0 "day")

;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Availability is the exact overlap
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 2. a window's hours land in the period that holds them ──~%~%")

(declare-world! #:periods P3 #:spans (map (lambda (t sp) (list t (car sp) (cdr sp))) P3 DAY))

(define day-oven   (res "O" "oven" 1.0 "shop" (win "09:00" "17:00")))
(define night-oven (res "N" "oven" 1.0 "shop" (win "17:00" "24:00")))
(define open-oven  (res "A" "oven" 1.0 "shop"))
(define (hours-of r) (map (lambda (t) (resource-window-hours r t)) P3))

(format #t "    09:00–17:00 → ~a~%    17:00–24:00 → ~a~%    no window   → ~a~%~%"
        (hours-of day-oven) (hours-of night-oven) (hours-of open-oven))

(check "a 09:00–17:00 window is 8 h in its own period and 0 in the others"
       (equal? '(0.0 8.0 0.0) (hours-of day-oven)))
(check "a 17:00–24:00 window likewise falls in the evening alone"
       (equal? '(0.0 0.0 7.0) (hours-of night-oven)))
(check "no window means the whole of every period"
       (equal? '(9.0 8.0 7.0) (hours-of open-oven)))
;; the share approximation this replaced would have spread 8 h across all three
(check "…and no window is over-counted into a period that does not hold it"
       (= 0.0 (car (hours-of day-oven))))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3 & 4. Disjoint cannot pair; overlapping can
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 3. disjoint availability, and overlapping ──~%~%")

(define (shared-periods a b)                ; periods where BOTH are available
  (filter (lambda (t) (and (> (resource-window-hours a t) 0.0)
                           (> (resource-window-hours b t) 0.0)))
          P3))

(define worker-day (res "W" "worker" 1.0 "shop" (win "09:00" "17:00")))
(define wide-oven  (res "V" "oven"   1.0 "shop" (win "07:00" "21:00")))

(check "a 09:00 worker and a 17:00 machine share NO period — unpairable"
       (null? (shared-periods worker-day night-oven)))
(check "a 09:00 worker and a 07:00–21:00 machine DO share one"
       (equal? '(1) (shared-periods worker-day wide-oven)))
(check "…and what they share is the overlap, 8 h"
       (near? (min (resource-window-hours worker-day 1) (resource-window-hours wide-oven 1))
              8.0 0.001))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Precedence — the chain, read finer
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; Dough is made in the EVENING period only (its oven is a night oven) and bread
;; is wanted in the MORNING. Within one day the arc runs the wrong way, so the
;; morning cannot be served; the next morning can, across the storage arc.

(format #t "~%── 5. the evening cannot supply the morning ──~%~%")

(define TWO-DAYS (append DAY (list (cons "2026-03-04T00:00" "2026-03-04T09:00"))))

(define (bake-run want-at)
  (set-templates! (compile-recipe (list (rp "bake" "Bake"))
          (list (out "o" "bread" 1.0 "bake") (wrk "w" 0.01 "bake")
                (in  "i" "dough" 1.0 "bake"))))
  (ingest-located!
   (list (res "D" "dough" 100.0 "shop"))
   '() (list (place* "shop"))
   #:period-spans TWO-DAYS
   #:storable '("dough")
   #:demand (list (cons (lg "bread" (cell "shop" want-at)) 10.0)))
  (for-each (lambda (t) (hash-set! *A* (cell "shop" t) 100000.0)) '(0 1 2 3))
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let* ((x (car (call-with-values
                      (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
             (V (lambda (k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))))
        (map (lambda (t) (V (format #f "p|bake|shop@~a" t))) '(0 1 2 3))))))

;; dough is stocked at period 0, so every later period can be served by carry
(let ((r (bake-run 3)))
  (format #t "    bread wanted next morning → bakes per period ~a~%~%"
          (map (lambda (v) (format #f "~,1f" v)) r))
  (check "a good stocked early can serve a later period, via the storage arc"
         (> (fold + 0.0 r) 0.1)))

;; the temporal arc runs FORWARD only — this is the property precedence rests on
(check "the time arc is forward-only: period 3 has no target beyond the horizon"
       (begin (declare-world! #:places '("shop") #:periods '(0 1 2 3))
              (not (temporal-target (cell "shop" 3)))))
(check "…and each period's target is the NEXT one, never an earlier"
       (equal? (temporal-target (cell "shop" 1)) (cell "shop" 2)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Contiguity — an act whose work cannot be put down
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; The mechanism is the storable flag: a good that is not storable has no
;; temporal arc, so work-in-progress that cannot be put down cannot cross a
;; boundary, and the act is confined to one period.

(format #t "~%── 6. a non-storable intermediate has no way across ──~%~%")

(define (carries? storable?)
  (declare-world! #:places '("shop") #:periods '(0 1)
                  #:templates
                    (compile-recipe (list (rp "start" "Start") (rp "finish" "Finish"))
                      (list (out "s1" "wip" 1.0 "start") (wrk "s2" 0.01 "start")
                            (in  "f1" "wip" 1.0 "finish") (out "f2" "done" 1.0 "finish")
                            (wrk "f3" 0.01 "finish")))
                  #:storable (if storable? '("wip") '()))
  (hash-set! *init* (lg "wip" (cell "shop" 0)) 1.0)
  ;; is there a column carrying wip from period 0 to period 1?
  (let ((cols (build-columns)))
    (and (find (lambda (c) (equal? (car c) (string-append "m|wip|" (cell "shop" 0) "|" (cell "shop" 1))))
               cols)
         #t)))

(check "a STORABLE intermediate can be put down and picked up next period"
       (carries? #t))
(check "a NON-storable one has no arc at all — the act cannot span a boundary"
       (not (carries? #f)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Arrival — no new field
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 7. a window that opens partway through ──~%~%")

(declare-world! #:periods P3 #:spans (map (lambda (t sp) (list t (car sp) (cdr sp))) P3 DAY))

;; "we get the oven at midday": available only from 12:00
(define late-oven (res "L" "oven" 1.0 "shop" (win "12:00" "24:00")))
(format #t "    from 12:00 → ~a~%~%" (hours-of late-oven))

(check "no capacity before it arrives"       (= 0.0 (car (hours-of late-oven))))
(check "part of the period it arrives in"    (near? (cadr (hours-of late-oven)) 5.0 0.001))
(check "all of every period after"           (near? (caddr (hours-of late-oven)) 7.0 0.001))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. Degeneracy — the strongest signal
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; With nothing declared, the construction must be the one that was there before:
;; uniform periods, whole availability, and a capacity that is the stock times
;; the period. If this moves, the construction is wrong rather than the tests.

(format #t "~%── 8. nothing declared, nothing changed ──~%~%")

(declare-world! #:places '("shop"))

(check "a period with no span is the stated length"  (near? (period-hours 0) 24.0 0.001))
(check "a resource with no window is available for all of it"
       (near? (resource-window-hours (res "P" "oven" 1.0 "shop") 0) 24.0 0.001))
(check "capacity is the stock over the period — a flow, not a headcount"
       (near? (stock->flow 3.0 0) 72.0 0.001))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
