;;; test-maximin.scm — the wants judged without a probability.
;;;
;;; docs/antifragile/antifragile.md: maximize the minimum fraction of available
;;; value captured across the states of the world. The fixture is
;;; robust-records-test's farm: A yields 4.0 normal / 0.0 drought, B 1.3 / 1.2,
;;; one hectare, a want of 5 kg food in either future, no floor. Under the
;;; record's odds (normal 0.9) the expected plan plants A and the drought
;;; captures almost nothing of what it could have; under maximin the plan
;;; balances the two futures' captured FRACTIONS.
;;;
;;; Properties (not snapshots): every future captures at least τ of its own
;;; achievable value; the worst fraction under maximin beats the worst under
;;; expectation; the report names τ and each future's fraction.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-maximin.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (playnet solve engine) (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define spatials (list (place* "farm")))
(define resources
  (list (er "land1" "land" #f #:place "farm" #:unit "ha")))
(define procs (list (rp* "growA" "A")
                    (rp* "growB" "B")))
(define flows
  (list (consume* "aL" "land" 1.0 "growA" "ha")
        (out* "aF" "food" 1.0 "growA")
        (consume* "bL" "land" 1.0 "growB" "ha")
        (out* "bF" "food" 1.0 "growB")))
(define scenarios
  (list (make-planning-scenario "normal"  #f 0.9 '(("growA" . 4.0) ("growB" . 1.3)) #f)
        (make-planning-scenario "drought" #f 0.1 '(("growA" . 0.0) ("growB" . 1.2)) #f)))
(define want '(("food#farm@0" . 5.0)))

(when (getenv "BACKEND") ((@ (playnet solve solver) set-backend!) (string->symbol (getenv "BACKEND"))))
(define (plan maximin?)
  (call-with-values
    (lambda () (plan-from-records resources '() spatials procs flows
                 #:scenarios scenarios #:first-stage-procs '("growA" "growB")
                 #:demand want #:maximin? maximin? #:per-agent? #f))
    (lambda (ints coms material fill cols x idx ntot report) report)))
(define (fs report p) (or (assoc-ref (or (assoc-ref report 'first-stage-plan) '()) p) 0.0))
(define (fraction xA xB yA yB best) (/ (min 1.0 (/ (+ (* yA xA) (* yB xB)) 5.0)) best))
;; achievable: normal plants all A → 4/5 = 0.8; drought plants all B → 1.2/5 = 0.24
(define (fractions r) (let ((xA (fs r "growA")) (xB (fs r "growB")))
                        (cons (fraction xA xB 4.0 1.3 0.8) (fraction xA xB 0.0 1.2 0.24))))

(define ex (plan #f)) (define mm (plan #t))
(define fe (fractions ex)) (define fm (fractions mm))
(format #t "~%expected: A ~,3f B ~,3f → fractions normal ~,3f drought ~,3f~%" (fs ex "growA") (fs ex "growB") (car fe) (cdr fe))
(format #t "maximin:  A ~,3f B ~,3f → fractions normal ~,3f drought ~,3f~%" (fs mm "growA") (fs mm "growB") (car fm) (cdr fm))
(define rep (assoc-ref mm 'maximin))
(format #t "report: ~s~%" rep)
(check "expectation sacrifices the drought (its fraction < 0.5)" (< (cdr fe) 0.5))
(check "maximin lifts the worst fraction above expectation's worst" (> (min (car fm) (cdr fm)) (+ (min (car fe) (cdr fe)) 0.2)))
(check "maximin balances the futures (fractions within 0.15)" (< (abs (- (car fm) (cdr fm))) 0.15))
(check "the report names τ" (and rep (number? (assoc-ref rep 'tau))))
(check "every future captures at least τ (− tolerance)"
       (and rep (every (lambda (f) (>= (caddr f) (- (assoc-ref rep 'tau) 0.05))) (assoc-ref rep 'futures))))
(check "the report's fractions agree with the plan's (within 0.1)"
       (and rep (let ((fr (map caddr (assoc-ref rep 'futures))))
                  (and (< (abs (- (car fr) (car fm))) 0.1) (< (abs (- (cadr fr) (cdr fm))) 0.1)))))
(check "expectation's report carries no maximin entry" (not (assoc-ref ex 'maximin)))

(format #t "~%=== Results: ~a passed, ~a failed ===~%" *pass* *fail*)
(exit (if (= *fail* 0) 0 1))
