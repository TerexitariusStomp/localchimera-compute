;;; test-rest-catalogue.scm — SNIRT, the time floor of the right to rest.
;;;
;;; Pins the claims docs/planning/food/reproduction-of-labour-power.md §2a–2c makes:
;;;   1. the base: sleep by age band plus meals and washing, a person's own
;;;      stated need, pregnancy, and the labour increment;
;;;   2. disposable time D = period − SNIRT.
;;; The sleep span and the away days are tags the schedule reads
;;; (test-schedulable-window.scm).
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-rest-catalogue.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (playnet planner knowledge catalogues rest))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))
(define (near? a b) (< (abs (- a b)) 1e-9))

(format #t "~%── 1. the base and its layers ──~%")
(check "an adult's SNIRT is 8 h of sleep and 2 h of meals and washing: 10 h"
       (near? 10.0 (snirt-hours '((age . 30)))))
(check "sleep follows the age bands: an infant 14, a school child 10.5, a teen 9, an elder 7.5"
       (and (near? 14.0 (sleep-hours '((age . 0)))) (near? 10.5 (sleep-hours '((age . 9))))
            (near? 9.0 (sleep-hours '((age . 15)))) (near? 7.5 (sleep-hours '((age . 70))))))
(check "the bands do not overlap: age 18 reads the adult band, age 65 the elder's"
       (and (near? 8.0 (sleep-hours '((age . 18)))) (near? 7.5 (sleep-hours '((age . 65))))))
(check "pregnancy adds an hour of sleep"
       (near? 9.0 (sleep-hours '((age . 30) (pregnant . #t)))))
(check "a person's own stated sleep replaces the band, kept inside 4–14 h"
       (and (near? 6.0 (sleep-hours '((age . 30) (sleep-hours . 6))))
            (near? 4.0 (sleep-hours '((age . 30) (sleep-hours . 1))))
            (near? 14.0 (sleep-hours '((age . 30) (sleep-hours . 20))))))
(check "the labour increment rises with the hours worked: 8 h at effort 1 adds 0.8 h"
       (near? 10.8 (snirt-hours '((age . 30) (labour-hours . 8)))))
(check "…and with the effort the recipe states: effort 2 doubles the increment"
       (near? 11.6 (snirt-hours '((age . 30) (labour-hours . 8) (effort . 2)))))
(check "the ratified standard may only raise: 1.25 lifts the base, below 1 reads as 1"
       (and (near? 12.5 (snirt-hours '((age . 30) (rest-standard . 1.25))))
            (near? 10.0 (snirt-hours '((age . 30) (rest-standard . 0.5))))))

(check "a clock span states its length, wrapping midnight: 23:00–07:00 is 8 h, 22:30–06:00 is 7.5 h; and stated as sleep it is the need"
       (and (near? 8.0 (span-hours "23:00" "07:00")) (near? 7.5 (span-hours "22:30" "06:00"))
            (near? 8.0 (snirt-hours `((age . 30) (sleep-hours . ,(span-hours "00:00" "06:00")))))))

(format #t "~%── 2. disposable time ──~%")
(check "an adult has 14 h of disposable time a day"
       (near? 14.0 (disposable-hours '((age . 30)))))
(check "over a 7-day period disposable time is 98 h"
       (near? 98.0 (disposable-hours '((age . 30)) #:days 7)))
(check "heavy labour shrinks D: an adult working 10 h at effort 1 has 13 h left"
       (near? 13.0 (disposable-hours '((age . 30) (labour-hours . 10)))))

(format #t "~%  ✓ — ~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
