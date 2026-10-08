;;; test-backend-verdict-parity.scm — the two backends agree about what is IMPOSSIBLE.
;;;
;;; The engine already parity-locks its backends on delivered demand: they solve
;;; the same forms by different methods and must reach the same satisfied
;;; fraction. It never locked them on the other thing a solve reports — whether
;;; there is a plan at all.
;;;
;;; That gap is not hypothetical. `solve-native` has always confirmed an
;;; infeasible verdict from a strictly-interior start before believing it, because
;;; phase-I can stop short from a far seed; `solve-native-c` trusted its first
;;; verdict, and so the two disagreed about a program the reference backend solved
;;; perfectly well. The compiled backend now runs the same confirming pass.
;;;
;;; With `located-warm` corrected to seed in RUNS, no test reaches that branch any
;;; more — even a demand 100000× capacity converges from the seed. So this suite
;;; is what keeps it honest: it does not test the branch, it tests the PROPERTY the
;;; branch exists to hold. If someone deletes the confirming pass because nothing
;;; seems to exercise it, the property is what should fail.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/planner/test-backend-verdict-parity.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner knowledge dsl shorthand))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas))
;; A period here is a WEEK: the roster's Monday 00:00–12:00 is twelve hours a period, on any date.
(set-period-length! 1.0 "week")

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define win (hours-of 12))
(define agents (list (person* "ada" #:name "Ada" #:place "p" #:window win)))
(define spatials (list (place* "p")))
(define procs (list (rp* "grow" "Grow")))
(define flows
  (list (out* "o" "food" 1.0 "grow")
        (consume* "s" "soil" 1.0 "grow" "u")
        (wk* "w" "skill" 1.0 "grow")))
(define (soil q) (er "soil" "soil" #f #:place "p" #:qty q #:unit "u"))
(define skill (er "sk" "skill" "ada" #:place "p" #:qty 1.0 #:unit "kg"))

;; A FLOOR, not a desire — a desire yields and both backends would agree trivially.
;; A floor is what forces the question "does a plan exist at all".
;; The two backends DELIVER the verdict differently, by design: `solve-native`
;; raises (`signal-infeasible!` — one place, so the message and the certificate can
;; never say different things), while `solve-native-c` returns a plan whose
;; certificate carries feasible? #f, because live callers expect a plan back and
;; read the certificate. Parity is about the DECISION, not the delivery, so a raise
;; and a #f certificate are the same answer and this reads them as one.
(define (verdict-on backend soil-q floor-kg)
  (catch #t
    (lambda ()
      (call-with-values
        (lambda () (plan-from-records (list (soil soil-q) skill) agents spatials procs flows
                     #:repro-floors (list (cons "food#p@0" floor-kg))
                     #:periods '(0) #:per-agent? #f #:backend backend
                     #:allow-infeasible? #t))
        (lambda (i c m fill cols x idx nt rep)
          (assq-ref (assq-ref rep 'certificate) 'feasible?))))
    (lambda (k . a)
      (if (string-contains (format #f "~a ~a" k a) "INFEASIBLE") #f
          (error "unexpected failure" k a)))))

;; three programs: comfortably possible, exactly at the wall, plainly impossible
(define cases
  (list (list "affordable      (soil 50, floor 5)"   50.0  5.0)
        (list "tight           (soil 6,  floor 5)"    6.0  5.0)
        (list "impossible      (soil 2,  floor 50)"   2.0 50.0)))

(format #t "~%── do the two backends agree about what is possible? ──~%~%")
(format #t "  ~38a ~12a ~a~%" "program" "native-c" "native")
(format #t "  ~38a ~12a ~a~%" "───────" "────────" "──────")
(define results
  (map (lambda (c)
         (let ((a (verdict-on 'native-c (second c) (third c)))
               (b (verdict-on 'native   (second c) (third c))))
           (format #t "  ~38a ~12a ~a~%" (first c) a b)
           (list (first c) a b)))
       cases))

(format #t "~%")
(for-each (lambda (r)
            (check (format #f "the backends agree on: ~a" (string-trim-right (first r)))
                   (eq? (second r) (third r))))
          results)
;; and the agreement is not vacuous — the cases really do span both answers
(check "the cases span both verdicts, so agreeing is a claim and not a constant"
       (and (any (lambda (r) (eq? #t (second r))) results)
            (any (lambda (r) (eq? #f (second r))) results)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — one program, one verdict, whichever backend is~%  asked. This is what solve-native-c's confirming pass is FOR; delete it and~%  this is what should notice.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED — the backends disagree about whether a plan~%  exists, which means one of them is answering a different question.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
