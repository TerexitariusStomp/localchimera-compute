;;; test-free-time.scm — free time is stated once: f = 1 − hours/capacity.
;;;
;;; The plan's placed hours over what its people offer, a scope tree's
;;; validated hours over N·T, and a household's declared hours over its members'
;;; time are three readings of one arithmetic (algorithms/free-time.scm). It is
;;; bounded to [0,1], falls as hours rise, is whole when nothing is planned and
;;; spent when capacity is filled; with no capacity there is no time, and none of
;;; it free.
;;;
;;; Run:  guile -L module tests/pools/test-free-time.scm
(use-modules (playnet test harness)
             (playnet algorithms free-time)
             ((playnet observation account) #:select (household-social-free-time))
             (srfi srfi-1))

(define (near? a b) (< (abs (- a b)) 1e-12))
(define hours-grid    '(0 0.5 1 7.5 40 100 1000 -3))
(define capacity-grid '(1 8 40 160 1000))

(display "\n── free-time-fraction ──\n")
(check "bounded to [0,1] over the grid"
       (every (lambda (c) (every (lambda (h) (let ((f (free-time-fraction h c))) (and (>= f 0) (<= f 1)))) hours-grid))
              capacity-grid))
(check "whole when nothing is planned"
       (every (lambda (c) (near? 1 (free-time-fraction 0 c))) capacity-grid))
(check "spent when capacity is filled or overfilled"
       (every (lambda (c) (and (near? 0 (free-time-fraction c c)) (near? 0 (free-time-fraction (* 2 c) c)))) capacity-grid))
(check "falls as hours rise (non-increasing)"
       (every (lambda (c)
                (let loop ((hs (sort hours-grid <)))
                  (or (null? hs) (null? (cdr hs))
                      (and (>= (free-time-fraction (car hs) c) (free-time-fraction (cadr hs) c))
                           (loop (cdr hs))))))
              capacity-grid))
(check "half the time planned leaves half" (near? 0.5 (free-time-fraction 20 40)))
(check "no capacity, no free time" (and (near? 0 (free-time-fraction 0 0)) (near? 0 (free-time-fraction 5 0))))
(check "negative capacity is no capacity" (near? 0 (free-time-fraction 1 -4)))

(display "\n── the household states it the same way ──\n")
(define members '(("ada" 1 10) ("bo" 1 20) ("cy" 0.5 0)))
(check "household f = the fraction of its members' time"
       (near? (household-social-free-time members #:per-citizen-hours 40.0)
              (free-time-fraction 30 120)))
(check "a household with no members has no free time"
       (near? 0 (household-social-free-time '() #:per-citizen-hours 40.0)))

(test-summary!)
