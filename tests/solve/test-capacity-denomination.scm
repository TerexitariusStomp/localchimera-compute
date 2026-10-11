;;; test-capacity-denomination.scm — a capacity means the same at any period length.
;;;
;;; A period's length is a governed choice: `*period-length*` is what a scope sets
;;; to say how finely it wants to see its own commitments, and playnet.typ (§One
;;; program) asks only that the length be STATED. So a capacity that reads the
;;; period as its denominator is a quantity that moves when that choice moves —
;;; the same means over the same day sums differently depending on where the
;;; boundaries fall, and the plan is then a fact about the display resolution.
;;;
;;; The rule that fixes it is one multiplication (`holding-capacity`):
;;;
;;;     capacity in period t  =  what the holding renders per hour · hours available in t
;;;
;;; where a STOCK renders itself per hour (`3 each` ⇒ 3) and a RATE states its own
;;; denominator as one quotient unit (`200 hours/week` ⇒ 200/168). Both sum the
;;; same over any partition of a span, because the hours a window offers are
;;; additive over a partition and the denominator belongs to the holding.
;;;
;;; A bare quantity of time — `200 hours`, saying how much and not per how long — is
;;; a BUDGET: a total over its window, bounded by one bar rather than a ceiling at
;;; each cell. Its distinguishing property is the negation of a rate's: the total does
;;; not grow with the horizon. (On stock / rate / capacity / budget as four distinct
;;; quantities, see utils/capacity.scm.)
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-capacity-denomination.scm

(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine) (playnet solve world)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet vf formulas capacity))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 0.001))

(define PLACE "b")
(define win all-week-window)
(define (res id spec qty unit . window)
  (er id spec #f #:place PLACE #:qty qty #:unit unit
      #:window (if (pair? window) (car window) #f)))
;; a template whose only input is the spec's SERVICE good, which is what routes a
;; `use`d spec's stock through the capacity conversion (`used-spec-set`)
(define (tpl spec)
  (list (string-append "p-" spec) '(("thing" . 1.0))
        (list (cons (string-append "Svc|" spec) 1.0)) 0.0 '() '() '() '() '()))

(define (svc-caps spec)
  (map (lambda (t) (hash-ref *cap* (lg (svc-good spec) (cell PLACE t)) 0.0)) *periods*))
(define (total spec holdings spans)
  "Σ over the horizon of SPEC's per-period service cap, under the partition SPANS."
  (declare-world! #:periods (iota (length spans))
                  #:spans (map (lambda (t sp) (list t (car sp) (cdr sp))) (iota (length spans)) spans)
                  #:templates (list (tpl "m")))
  (ingest-stock! holdings)
  (fold + 0.0 (svc-caps "m")))

;;; One day, three ways of cutting it. The span is the same in each; only the
;;; boundaries differ, which is the choice a capacity must not depend on.
(define ONE   '(("2026-03-03" . "2026-03-03")))
(define TWO   '(("2026-03-03T00:00" . "2026-03-03T12:00")
                ("2026-03-03T12:00" . "2026-03-04T00:00")))
(define THREE '(("2026-03-03T00:00" . "2026-03-03T08:00")
                ("2026-03-03T08:00" . "2026-03-03T16:00")
                ("2026-03-03T16:00" . "2026-03-04T00:00")))
(define TWO-DAYS '(("2026-03-03" . "2026-03-04")))

(define (invariant? label holdings expect)
  (let ((a (total "m" holdings ONE))
        (b (total "m" holdings TWO))
        (c (total "m" holdings THREE)))
    (format #t "    ~a: undivided ~,2f · halved ~,2f · in thirds ~,2f~%" label a b c)
    (and (near? a expect) (near? b expect) (near? c expect))))

(format #t "~%── 1. a STOCK is denominated per thing ──~%~%")

;; three ovens, there all day: 3 × 24 = 72 oven-hours, however the day is cut
(check "three ovens over a day are 72 oven-hours under any partition"
       (invariant? "3 each" (list (res "r" "m" 3.0 %count-unit)) 72.0))

;; …and a window narrows it the same way in every partition
(check "staffed 08:00–16:00 they are 24, under any partition"
       (invariant? "3 each, 8h window"
                   (list (res "r" "m" 3.0 %count-unit (win "08:00" "16:00"))) 24.0))

(format #t "~%── 2. a RATE carries its own denominator ──~%~%")

;; 200 seat-hours a day IS 200 seat-hours in a day — the number is already the
;; answer for this span, and slicing the span cannot change it
(check "200 hours/day over a day is 200, under any partition"
       (invariant? "200 hours/day" (list (res "r" "m" 200.0 "hours/day")) 200.0))

;; the same holding read against a week: a day is a seventh of it
(check "200 hours/week over a day is 200/7, under any partition"
       (invariant? "200 hours/week" (list (res "r" "m" 200.0 "hours/week"))
                   (/ 200.0 7.0)))

;; a window restricts a rate exactly once — the failure the old reading had was
;; charging it twice undivided and not at all when refinement matched the window
(check "200 hours/day behind an 8h window is 200/3, under any partition"
       (invariant? "200 hours/day, 8h window"
                   (list (res "r" "m" 200.0 "hours/day" (win "08:00" "16:00")))
                   (/ 200.0 3.0)))

(format #t "~%── 3. length is not granularity ──~%~%")

;; Invariance is about WHERE the boundaries fall, not about how long the span is.
;; A rate over twice the span is twice the capacity — the property that tells a
;; genuine rate apart from a number that merely ignores the period.
(let ((one-day  (total "m" (list (res "r" "m" 200.0 "hours/day")) ONE))
      (two-days (total "m" (list (res "r" "m" 200.0 "hours/day")) TWO-DAYS)))
  (format #t "    one day ~,2f · two days ~,2f~%" one-day two-days)
  (check "200 hours/day over two days is 400" (near? two-days 400.0))
  (check "…which is twice the one-day figure" (near? two-days (* 2.0 one-day))))

;; and a count scales with the span too, for the same reason
(let ((one-day  (total "m" (list (res "r" "m" 3.0 %count-unit)) ONE))
      (two-days (total "m" (list (res "r" "m" 3.0 %count-unit)) TWO-DAYS)))
  (check "three ovens over two days are 144 oven-hours"
         (and (near? one-day 72.0) (near? two-days 144.0))))

(format #t "~%── 4. a bare quantity of time is a BUDGET, not a rate ──~%~%")

;; `200 hours` names no denominator because it HAS none: nothing regenerates, and
;; spending it in an afternoon or across a month is the same two hundred hours. So it
;; is bounded by ONE bar over its window rather than a ceiling at each cell — and the
;; test of that is the property a rate does NOT have: the total does not grow with
;; the horizon.
(define (budget-pool holdings spans)
  (declare-world! #:places (list PLACE) #:periods (iota (length spans))
                  #:spans (map (lambda (t sp) (list t (car sp) (cdr sp))) (iota (length spans)) spans)
                  #:templates (list (tpl "m")))
  (ingest-stock! holdings)
  (find (lambda (p) (string-prefix? "bg|" (car p))) *container-pools*))

(define bare (list (res "bare" "m" 200.0 %effort-unit)))
(let ((one  (budget-pool bare ONE))
      (two  (budget-pool bare TWO-DAYS))
      (three (budget-pool bare THREE)))
  (format #t "    one day: budget ~a over ~a cell(s)~%" (cadddr one) (length (caddr one)))
  (format #t "    two days: budget ~a over ~a cell(s)~%" (cadddr two) (length (caddr two)))
  (check "a bare quantity of time becomes a budget, not a per-cell cap"
         (and one (near? 200.0 (cadddr one))
              (= 0 (hash-fold (lambda (k v a) (if (string-prefix? "Svc|m" k) (+ a 1) a))
                              0 *cap*))))
  (check "the budget is the SAME over a longer horizon — a total, not a rate"
         (and two (near? 200.0 (cadddr two))))
  (check "…and the same under any partition of one span"
         (and three (near? 200.0 (cadddr three))))
  (check "it reaches every period it is available in"
         (and three (= 3 (length (caddr three))))))

;; A rate does the opposite, and that contrast is the whole distinction: 200/day over
;; two days is 400, where a budget of 200 is 200 however long the horizon runs.
(check "…where a RATE over two days is twice a rate over one"
       (near? 400.0 (total "m" (list (res "r" "m" 200.0 "hours/day")) TWO-DAYS)))

;; Asking a budget for a per-cell capacity is a caller that skipped the question.
(define (find-message x)
  (cond ((and (string? x) (string-contains x "budget has no per-period")) x)
        ((pair? x) (or (find-message (car x)) (find-message (cdr x))))
        (else #f)))
(define refused
  (catch #t
    (lambda () (let ((h (res "bare" "m" 200.0 %effort-unit)))
                 (holding-capacity 200.0 (economic-resource-onhand-quantity h) h 24.0))
               #f)
    (lambda (key . args) (or (find-message args) key))))
(format #t "    ~a~%" refused)
(check "and asking one for a per-period capacity says so by name"
       (and (string? refused) (string-contains refused "total rather than a rate")))

;;; A live availability reading is a LEVEL rather than a declared holding — it has no
;;; measure and therefore no unit to read — so it reads as a stock.
(format #t "~%── 5. a live level reads as a stock ──~%~%")
(declare-world! #:spans '((0 "2026-03-03" "2026-03-03"))
                #:templates (list (tpl "m")))
(ingest-stock! (list (res "r" "m" 3.0 %count-unit))
               #:live-avail (lambda (id) 5.0))
(check "a live level of 5 renders 5 × the period's hours"
       (near? (car (svc-caps "m")) 120.0))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a capacity states its own denominator, so~%  the plan's limits are facts about the means and not about the lattice.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
