;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-reproduction-live.scm — reproduction floors on the LIVE entry point.
;;;
;;; reproduction-diet-test proved the mechanism at the low-level globals; this proves
;;; the SAME floor flows through the real records pipeline `plan-from-records` (the one
;;; `plan-scope` calls over a live scope) via the new #:repro-floors kwarg. A floor is
;;; the deficiency edge of a reproduction band: a HARD minimum, distinct from #:demand
;;; (soft desire). Here there is NO demand at all — only the floor — so any production
;;; is the constraint side alone feeding the person.
;;;
;;; Ada can grow food (1 h → 10 kcal). Nobody demands kcal. A reproduction floor is
;;; set via #:repro-floors ⇒ the plan must grow at least that much to keep the balance.
;;;
;;; Both floors sit INSIDE Ada's labour budget — she offers 56 h/period, so 400 kcal
;;; costs 40 h and leaves room. A floor above 560 kcal asks for hours that do not
;;; exist, and the honest answer there is `feasible? #f`, not a bigger number: the
;;; solver returns its phase-I point for a program with no answer, and a test that
;;; reads only the quantity would pass on a plan spending labour nobody has. So each
;;; solve's verdict is asserted alongside its quantity.
;;;
;;; Run:  guile --no-auto-compile -L module tests/solve/test-reproduction-live.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve plan)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

;; A period here is a WEEK: the roster's window every day is 56 h a period, the
;; labour these floors were sized on, and the same on any date.
(set-period-length! 1.0 "week")
(define win (all-week-window "09:00" "17:00"))
(define agents (list (person* "ada" #:name "Ada" #:window win)))
(define spatials (list (place* "town")))
(define resources (list (er "sk-ada" "skill-grow" "ada" #:qty 1.0 #:unit "kg")))
(define procs (list (rp* "grow" "Grow")))
(define flows (list (out* "f1" "kcal" 10.0 "grow" "kcal")
                    (wk* "f2" "skill-grow" 1.0 "grow")))

;; a realistic labour disutility so the plan doesn't grow food nobody wants — then
;; the ONLY thing that summons production is the reproduction floor (or a demand).
(set! *emp-rho* 0.5)
;; → (kcal-grown . feasible?). The verdict rides along so a quantity is never read
;; without the answer to "is this a plan at all".
(define (kcal-made floors)
  (call-with-values
    (lambda () (plan-from-records resources agents spatials procs flows
                 #:demand '() #:repro-floors floors #:backend 'native-c))
    (lambda (ints coms material fill cols x idx ntot report)
      (cons (fold (lambda (c a)
                    (if (and (eq? (commitment-action c) 'produce)
                             (equal? (commitment-resource-conforms-to c) "kcal"))
                        (+ a (measure-has-numerical-value (commitment-resource-quantity c))) a))
                  0.0 material)
            (assq-ref (assq-ref report 'certificate) 'feasible?)))))

(define r-none (kcal-made '()))                          ; no floor, no demand
(define r200   (kcal-made '(("kcal#town@0" . 200.0))))   ; reproduction floor 200 kcal → 20 h
(define r400   (kcal-made '(("kcal#town@0" . 400.0))))   ; reproduction floor 400 kcal → 40 h
(define none (car r-none)) (define f200 (car r200)) (define f400 (car r400))

(format #t "~%── reproduction floor through plan-from-records (the live entry point) ──~%")
(format #t "  no floor, no demand → kcal grown = ~,1f  (only the barrier's small interior residual)~%" none)
(format #t "  reproduction floor 200 → kcal grown = ~,1f~%" f200)
(format #t "  reproduction floor 400 → kcal grown = ~,1f~%" f400)

(let* ((c1 (>= f200 (* 0.99 200.0)))                     ; floor 200 honored to solver tolerance
       (c2 (>= f400 (* 0.99 400.0)))                     ; floor 400 honored to solver tolerance
       (c3 (< (abs (- (- f400 f200) 200.0)) 20.0))       ; BINDING: a +200 floor passes ~1:1 into production
       (c4 (< none (* 0.2 f200)))                        ; the floor, not the barrier residual, drives production
       ;; every quantity above describes a real plan — each solve stayed inside
       ;; Ada's 56 h, so none of these numbers is spent labour that never existed
       (c5 (and (eq? #t (cdr r-none)) (eq? #t (cdr r200)) (eq? #t (cdr r400))))
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] floor 200 honored to solver tolerance — grows ~~200 kcal (~,1f)~%" (if c1 "✓" "✗") f200)
  (format #t "  [~a] floor 400 honored to solver tolerance (~,1f)~%" (if c2 "✓" "✗") f400)
  (format #t "  [~a] the floor is BINDING: +200 floor → +~,1f kcal grown (≈1:1)~%" (if c3 "✓" "✗") (- f400 f200))
  (format #t "  [~a] the floor — not the barrier residual (~,1f) — drives provisioning~%" (if c4 "✓" "✗") none)
  (format #t "  [~a] every solve is FEASIBLE (~a / ~a / ~a) — the quantities are plans, not phase-I points~%"
          (if c5 "✓" "✗") (cdr r-none) (cdr r200) (cdr r400))
  (format #t "~%  ~a #:repro-floors carries the constraint-dial floor through the live records pipeline~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
