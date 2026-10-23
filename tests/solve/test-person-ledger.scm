;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-person-ledger.scm — the plan's social ledger, person by person.
;;;
;;; The social block states the plan's hours as totals (direct + transport +
;;; training planned; N·T available). `by-person` states the same hours for
;;; each person, and the totals are their sums: one ledger read two ways, so a
;;; fold over scopes can sum the people a plan places without a second account
;;; of them. Without rest reserved a person's time is their offered hours; with
;;; rest reserved it is what their body leaves.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-person-ledger.scm

(use-modules (playnet solve world) (playnet test planner prelude)
             (playnet solve engine) (playnet solve plan)
             (playnet vf facts availability)
             (playnet vf facts agent-time)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand)
             (srfi srfi-1) (ice-9 format))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))
(define (near? a b) (< (abs (- a b)) 1e-6))

(define spatials (list (place* "town")))
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "o" "bread" 1.0 "bake") (wk* "w" #f 0.5 "bake")))
(define ada (person* "ada" #:place "town" #:tags '("general") #:window (all-week-window)))
(define bo  (person* "bo"  #:place "town" #:tags '("general") #:window (all-week-window "09:00" "17:00")))

(define (social)
  (call-with-values
    (lambda () (plan-from-records '() (list ada bo) spatials procs flows
                                  #:demand '(("bread#town@0" . 4.0)) #:per-agent? #t))
    (lambda (ints coms material fill cols x idx ntot report) (assq-ref report 'social))))

(define (sum f rows) (fold + 0.0 (map f rows)))
(define (ids rows) (sort (map car rows) string<?))

(define (checks label s)
  (let* ((rows (assq-ref s 'by-person))
         (spent (+ (assq-ref s 'direct-labour) (assq-ref s 'transport) (assq-ref s 'training))))
    (format #t "~%── ~a ──~%" label)
    (check "by-person states every person the plan counts" (equal? (ids rows) '("ada" "bo")))
    (check "the planned hours sum to direct + transport + training"
           (near? (sum cadr rows) spent))
    (check "the offered hours sum to N·T, the available hours"
           (near? (sum caddr rows) (assq-ref s 'available)))
    (check "no one is planned past their own time"
           (every (lambda (r) (<= (cadr r) (+ (caddr r) 1e-6))) rows))
    (check "f reads off the sums: 1 − Σ planned / Σ offered"
           (near? (assq-ref s 'free-time) (- 1.0 (/ (sum cadr rows) (sum caddr rows)))))))

(set-agent-disposable! #f)
(checks "nothing reserved: a person's time is what they offer" (social))

(set-agent-disposable! (lambda (a days) (* days 14.0)))
(checks "rest reserved: a person's time is what the body leaves" (social))
(check "…Ada and Bo each stand at 14 h"
       (every (lambda (r) (near? (caddr r) 14.0)) (assq-ref (social) 'by-person)))
(set-agent-disposable! #f)

(format #t "~%  ✓ — ~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
