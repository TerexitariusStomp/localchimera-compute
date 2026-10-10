;;; test-derived-partition.scm — a declared boundary IS a period boundary.
;;;
;;; The solve has honoured declared boundaries for a while, but only once a
;;; caller stated the matching span BY HAND. A scope that simply said "the baker
;;; works 09:00–17:00" got no boundary at 09:00, so its window was read as a
;;; share of a coarse day — the approximation the whole thread was about.
;;;
;;; Boundaries are now the horizon's own, plus every declared clock boundary
;;; falling strictly inside one of them. Sort, dedupe, emit.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-derived-partition.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet knowledge dsl shorthand))
(use-modules (playnet solve engine)
             (playnet vf schemas))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))
(define (near? a b tol) (< (abs (- a b)) tol))

(define win all-week-window)
(define (res id spec place . window)
  (er id spec #f #:place place #:qty 1.0 #:unit %count-unit
      #:window (if (pair? window) (car window) #f)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The rule itself
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 1. cutting a span ──~%~%")

(define ONE-DAY '(("2026-03-03" . "2026-03-03")))

(check "no declared boundary leaves the partition alone"
       (equal? ONE-DAY (refine-spans ONE-DAY '())))

(define cut (refine-spans ONE-DAY (list 540 1020)))     ; 09:00 and 17:00
(format #t "    a day cut at 09:00 and 17:00 → ~a pieces~%" (length cut))
(for-each (lambda (sp) (format #t "      ~a → ~a~%" (car sp) (cdr sp))) cut)
(newline)

(check "a day cut twice is three periods"     (= 3 (length cut)))
(check "the first runs midnight to 09:00"
       (equal? '("2026-03-03T00:00" . "2026-03-03T09:00") (car cut)))
(check "the last closes at the following midnight"
       (equal? "2026-03-04T00:00" (cdr (last cut))))
(check "they tile the day with no gap and no overlap"
       (every (lambda (a b) (equal? (cdr a) (car b))) (drop-right cut 1) (cdr cut)))

;; refining is idempotent — a span already cut has no boundary strictly inside
(check "deriving twice is deriving once"
       (equal? cut (refine-spans cut (list 540 1020))))

;; a boundary that is not inside anything changes nothing
;; midnight is where the day already ends, so cutting there yields the same one
;; period — written as explicit datetimes, which is the same span said precisely
(let ((m (refine-spans ONE-DAY '(0))))
  (check "a boundary at midnight is a DATE boundary, not a new cut"
         (and (= 1 (length m))
              (equal? '("2026-03-03T00:00" . "2026-03-04T00:00") (car m)))))

(format #t "~%── 2. reading the boundaries off what people declared ──~%~%")

(define staff (list (res "O" "oven" "shop" (win "09:00" "17:00"))
                    (res "N" "oven" "shop" (win "22:00" "02:00"))))
(define found (declared-clock-boundaries staff '()))
(format #t "    declared: ~a~%~%" found)
(check "every stated endpoint is a boundary, midnight excepted"
       (equal? '(120 540 1020 1320) found))          ; 02:00 09:00 17:00 22:00
(check "a scope that declares no clock declares no boundary"
       (null? (declared-clock-boundaries (list (res "P" "oven" "shop")) '())))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. End to end: nobody states a span, and the window still lands
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; This is the case that was broken. One day of horizon, one declared window, and
;; NO #:period-spans anywhere.

(format #t "~%── 3. \"the baker works 09:00–17:00\", and nothing else ──~%~%")

(define (hours-by-period refine?)
  (let ((oven (res "O" "oven" "shop" (win "09:00" "17:00"))))
    (ingest-located! (list oven) '()
                     (list (place* "shop"))
                     #:horizon (cons "2026-03-03" 1)
                     #:refine-periods? refine?)
    (map (lambda (t) (cons (period-hours t) (resource-window-hours oven t))) *periods*)))

(define derived (hours-by-period #t))
(define stated  (hours-by-period #f))

(format #t "    derived: ~a~%    off:     ~a~%~%" derived stated)

(check "the day became three periods because somebody named two boundaries"
       (= 3 (length derived)))
(check "…which are 9, 8 and 7 hours long"
       (equal? '(9.0 8.0 7.0) (map car derived)))
(check "the window's 8 hours land in the period that HOLDS them"
       (equal? '(0.0 8.0 0.0) (map cdr derived)))
(check "with derivation off the day stays one period"
       (= 1 (length stated)))
;; The count is right either way — a whole-date period already totals a window
;; exactly. What derivation adds is PLACEMENT: undivided, the 8 hours are "8 of
;; this day's 24" and could be any of them, which is what let disjoint hours look
;; pairable. Section 5 is where that difference bites.
(check "…and undivided, those 8 hours are merely somewhere in the 24"
       (and (near? (car (car stated)) 24.0 0.001)
            (near? (cdr (car stated)) 8.0 0.001)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Degeneracy — declaring no clock changes nothing at all
;;; ════════════════════════════════════════════════════════════════════════════

(format #t "~%── 4. nothing declared, nothing changed ──~%~%")

(define (plain refine?)
  (let ((oven (res "O" "oven" "shop")))
    (ingest-located! (list oven) '()
                     (list (place* "shop"))
                     #:horizon (cons "2026-03-03" 3)
                     #:refine-periods? refine?)
    (list (length *periods*) (map period-hours *periods*)
          (map (lambda (t) (resource-window-hours oven t)) *periods*))))

(check "a horizon with no declared clock is untouched by derivation"
       (equal? (plain #t) (plain #f)))
(check "…and it is still three whole days"
       (equal? (list 3 '(24.0 24.0 24.0) '(24.0 24.0 24.0)) (plain #t)))

;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Two people, disjoint hours — the case that started the thread
;;; ════════════════════════════════════════════════════════════════════════════
;;
;; A worker 09:00–17:00 and a machine 17:00–24:00 share no period, and nobody had
;; to state a single span for that to be true.

(format #t "~%── 5. disjoint hours, derived ──~%~%")

(define worker  (res "W" "worker" "shop" (win "09:00" "17:00")))
(define evening (res "M" "mixer"  "shop" (win "17:00" "24:00")))
(ingest-located! (list worker evening) '()
                 (list (place* "shop"))
                 #:horizon (cons "2026-03-03" 1)
                 #:refine-periods? #t)

(define shared (filter (lambda (t) (and (> (resource-window-hours worker t) 0.0)
                                        (> (resource-window-hours evening t) 0.0)))
                       *periods*))
(format #t "    periods ~a; worker ~a; mixer ~a~%~%"
        (length *periods*)
        (map (lambda (t) (resource-window-hours worker t)) *periods*)
        (map (lambda (t) (resource-window-hours evening t)) *periods*))

(check "they share NO period — unpairable, with nothing stated by hand"
       (null? shared))
(check "and each still has its own full hours"
       (and (near? (fold + 0.0 (map (lambda (t) (resource-window-hours worker t)) *periods*)) 8.0 0.001)
            (near? (fold + 0.0 (map (lambda (t) (resource-window-hours evening t)) *periods*)) 7.0 0.001)))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
