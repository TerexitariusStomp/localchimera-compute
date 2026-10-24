;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-labour-budget.scm — a body has one week.
;;;
;;; The labour roster holds an entry per (person, skill), each carrying the
;;; person's whole week. A person with several skills is still one body:
;;;   • the pool's hour totals count them once;
;;;   • deployment spends one budget across their skills — the hours they offer
;;;     on the days the demand names (their week when it names none), less what
;;;     is already assigned them — so two skills in two buckets cannot sum past
;;;     what the body has.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/federation/test-labour-budget.scm

(use-modules ((localchimera utils units) #:select (%effort-unit)))
(use-modules (localchimera test harness)
             (localchimera vf schemas) (localchimera vf beyond schedules)
             (localchimera federation uc-matching)
             (localchimera pools availability-pool)
             (localchimera federation plan-bundle)
             (goblins utils hashmap)
             (srfi srfi-1))

(define (pool-of . entries)
  (fold (lambda (e p) (pool-add p e)) (make-labour-pool) entries))
(define (on-day day)
  (make-availability-window #f #f (list (make-day-schedule (list day) (list (make-time-range "09:00" "17:00")))) #f))
(define* (wi id skill hours #:optional (day 'monday))
  (make-intent #:id id #:action 'work #:input-of "bakery" #:resource-conforms-to skill
               #:effort-quantity (make-measure hours %effort-unit) #:at-location "town" #:planned-within "plan-1" #:availability-window (on-day day)))
(define (deploy intents pool . kw)
  (let ((prop (make-rising-proposal "prop-1" "plan-1" "scope-1" (map intent-id intents))))
    (car (apply greedy-deploy (list prop) `(("prop-1" ,@intents)) '(("prop-1" . 1)) pool kw))))

(display "\n── a day is offered once, however many ranges name it ──\n")
(use-modules ((localchimera vf facts availability)
              #:select (window-weekly-hours window-hours-on-dates)))
(define (monday . ranges)
  (make-availability-window #f #f (list (make-day-schedule '(monday) (map (lambda (r) (make-time-range (car r) (cdr r))) ranges))) #f))
(check "09-17 stated twice is eight hours" (window-weekly-hours (monday '("09:00" . "17:00") '("09:00" . "17:00"))) 8)
(check "09-13 and 11-15 overlap: they cover 09-15, six hours" (window-weekly-hours (monday '("09:00" . "13:00") '("11:00" . "15:00"))) 6)
(check "disjoint ranges add" (window-weekly-hours (monday '("09:00" . "12:00") '("14:00" . "16:00"))) 5)
(check "touching ranges add" (window-weekly-hours (monday '("09:00" . "12:00") '("12:00" . "14:00"))) 5)
(check "a range across midnight counts its length" (window-weekly-hours (monday '("22:00" . "02:00"))) 4)
(check "read on a date, the union again"
       (window-hours-on-dates (monday '("09:00" . "13:00") '("11:00" . "15:00")) '("2026-10-05")) 6)

(display "\n── the pool counts a person once ──\n")
(let ((pool (pool-of (make-entry "alice" "bake" #f "town" 8.0)
                     (make-entry "alice" "mill" #f "town" 8.0)
                     (make-entry "bo"    "bake" #f "town" 5.0))))
  (check "alice's two skills are one week of hours, bo's another" (pool-total-hours pool) 13.0)
  (check "asked for one skill, each of its holders once" (pool-total-hours pool #:skill "bake") 13.0)
  (check "asked for the skill only alice holds, her week" (pool-total-hours pool #:skill "mill") 8.0))

(display "\n── deployment spends one budget across a person's skills ──\n")
(let ((pool (pool-of (make-entry "alice" "bake" #f "town" 8.0)
                     (make-entry "alice" "mill" #f "town" 8.0))))
  (check "6 hours of baking and 6 of milling are 12 of alice's 8: one is assigned"
         (length (deploy (list (wi "wi1" "bake" 6.0) (wi "wi2" "mill" 6.0 (quote tuesday))) pool)) 1)
  (check "4 and 4 are 8 of 8: both are"
         (map commitment-provider (deploy (list (wi "wi1" "bake" 4.0) (wi "wi2" "mill" 4.0 (quote tuesday))) pool))
         '("alice" "alice")))

(display "\n── a seeded accept spends the budget too ──\n")
(let* ((pool (pool-of (make-entry "alice" "bake" #f "town" 8.0)
                      (make-entry "alice" "mill" #f "town" 8.0)))
       (accept (make-commitment #:id "a1" #:action 'work #:input-of "bakery" #:resource-conforms-to "bake"
                                #:effort-quantity (make-measure 6.0 %effort-unit) #:provider "alice" #:at-location "town")))
  (check "alice has 6 hours assigned already: 4 more of milling does not fit"
         (length (deploy (list (wi "wi2" "mill" 4.0 (quote tuesday))) pool #:seed (list accept))) 0)
  (check "2 does"
         (length (deploy (list (wi "wi2" "mill" 2.0 (quote tuesday))) pool #:seed (list accept))) 1))

(test-summary!)
