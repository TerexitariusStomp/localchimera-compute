;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-rest-standard-reaches-solve.scm — a scope's ratified rest standard is
;;; what ITS solve keeps of a person's day for rest.
;;;
;;; `rest-standard` lifts the base of what a body keeps for rest (sleep, meals,
;;; washing) above bare adequacy, and may only raise (catalogues/rest.scm). The
;;; reservation of rest is one process-wide hook, so a scope's own number rides
;;; the solve as a keyword (`#:rest-standard`, the governed dial) down to the
;;; place the hook is asked, and is never read from a cell another scope last
;;; wrote. N·T, the free-time base, is the sum of what every body leaves.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-rest-standard-reaches-solve.scm
(use-modules (playnet solve world) (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf facts availability) (playnet vf facts agent-time)
             (playnet vf schemas) (playnet knowledge dsl shorthand)
             ((playnet knowledge catalogues rest) #:select (disposable-hours))
             ((playnet scope live) #:select (agent->subsistence-ctx))   ; installs the live reservation-of-rest hook
             (playnet test harness)
             (srfi srfi-1))

(define spatials (list (place* "town")))
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "o" "bread" 1.0 "bake") (wk* "w" #f 0.5 "bake")))
(define ada (person* "ada" #:place "town" #:tags '("general" "age:30" "sex:F") #:window (all-week-window)))

(define (available . kw)
  (call-with-values
    (lambda () (apply plan-from-records '() (list ada) spatials procs flows
                      #:demand '(("bread#town@0" . 2.0)) #:per-agent? #t kw))
    (lambda (ints coms material fill cols x idx ntot report) (assq-ref (assq-ref report 'social) 'available))))
(define (leaves std) (disposable-hours (agent->subsistence-ctx ada 0 #f #:rest-standard std) #:days 1))
(define (near? a b) (< (abs (- a b)) 0.05))

(display "\n── the scope's rest standard is what the solve keeps ──\n")
(check "unstated, the solve reads bare adequacy: N·T is what a body leaves at 1"
       (near? (available) (leaves 1)))
(check "a ratified standard of 1.5 keeps more of the day for rest: N·T falls to what a body leaves at 1.5"
       (near? (available #:rest-standard 1.5) (leaves 1.5)))
(check "…and that is less than at 1"
       (< (available #:rest-standard 1.5) (available)))
(check "a standard below 1 reads as 1: the standard only raises"
       (near? (available #:rest-standard 0.5) (available)))
(check "the next solve, with no standard stated, is back at bare adequacy: no cell carries it over"
       (near? (available) (leaves 1)))

(test-summary!)
