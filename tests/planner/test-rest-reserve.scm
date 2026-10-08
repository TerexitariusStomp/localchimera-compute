;;; test-rest-reserve.scm — the engine's reservation of rest.
;;;
;;; A caller that knows what a person's body takes each day registers it once
;;; (set-agent-disposable!, matching/availability.scm); then (1) the hours a person offers sit inside their
;;; disposable time, and (2) N·T, the free-time fraction's base, is the sum of
;;; every person's disposable time — the spec's f = 1 − L / Σ_p D_p — offering
;;; or not. With nothing registered, every offer stands and N·T is the Σ of
;;; the offers.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-rest-reserve.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner facts availability)
             (playnet planner facts agent-time)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand)
             (srfi srfi-1) (ice-9 format))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (format #t "  [~a] ~a~%" (if ok "✓" "✗") name)
  (if ok (set! *pass* (+ *pass* 1)) (set! *fail* (+ *fail* 1))))
(define (near? a b) (< (abs (- a b)) 0.05))

(define spatials (list (place* "town")))
(define procs (list (rp* "bake" "Bake")))
(define flows (list (out* "o" "bread" 1.0 "bake") (wk* "w" #f 0.5 "bake")))

;; two people: Ada offers all day, Bo offers eight hours
(define ada (person* "ada" #:place "town" #:tags '("general") #:window (all-week-window)))
(define bo  (person* "bo"  #:place "town" #:tags '("general") #:window (all-week-window "09:00" "17:00")))

(define (ledger)
  (call-with-values
    (lambda () (plan-from-records '() (list ada bo) spatials procs flows
                                  #:demand '(("bread#town@0" . 4.0)) #:per-agent? #t))
    (lambda (ints coms material fill cols x idx ntot report) (assq-ref report 'social))))

(format #t "~%── nothing registered: the offers stand ──~%")
(set-agent-disposable! #f)
(define bare (ledger))
(format #t "  available ~a~%" (assq-ref bare 'available))
(check "N·T is Σ the offers: Ada's day and Bo's eight hours"
       (near? (assq-ref bare 'available) (+ (* 24.0 (/ 1439.0 1440.0)) 8.0)))

(format #t "~%── a body takes ten hours a day: 14 h are disposable ──~%")
(set-agent-disposable! (lambda (a days) (* days 14.0)))
(define reserved (ledger))
(format #t "  available ~a~%" (assq-ref reserved 'available))
(check "N·T is Σ disposable time: 14 h for each of the two, offering or not"
       (near? (assq-ref reserved 'available) 28.0))
(check "the hours each worker offers sit inside 14 h: Ada's whole day is kept to 14, Bo's eight stand"
       (let* ((ws (@@ (playnet planner solve engine) *workers*))
              (hours (lambda (id) (let ((w (find (lambda (w) (equal? (car w) id)) ws))) (and w (cadddr w))))))
         (and (hours "ada") (hours "bo") (near? (hours "ada") 14.0) (near? (hours "bo") 8.0))))
(check "f reads over the disposable time: f = 1 − spent / 28"
       (let ((spent (- (assq-ref reserved 'available) (assq-ref reserved 'free))))
         (near? (assq-ref reserved 'free-time) (- 1.0 (/ spent 28.0)))))
(check "a period that reserves nothing (the hook answers #f) leaves the offers standing"
       (begin (set-agent-disposable! (lambda (a days) #f))
              (let ((l (ledger))) (near? (assq-ref l 'available) (+ (* 24.0 (/ 1439.0 1440.0)) 8.0)))))

(format #t "~%── a stated sleep span is read by the schedule ──~%")
(set-agent-disposable! #f)
(define nurse (person* "nurse" #:place "town" #:tags '("general" "sleep:23:00-07:00") #:window (all-week-window)))
(define (worker-hours-of agents id)
  (call-with-values
    (lambda () (plan-from-records '() agents spatials procs flows #:demand '(("bread#town@0" . 4.0)) #:per-agent? #t))
    (lambda _ (let ((w (find (lambda (w) (equal? (car w) id)) (@@ (playnet planner solve engine) *workers*)))) (and w (cadddr w))))))
(check "a person who states 23:00–07:00 offers the day less those eight hours: about 16, not 24"
       (near? (worker-hours-of (list nurse) "nurse") (- (* 24.0 (/ 1439.0 1440.0)) 8.0)))
(check "the same person without the span offers the whole day"
       (near? (worker-hours-of (list ada) "ada") (* 24.0 (/ 1439.0 1440.0))))

(format #t "~%── unregistered again: the next build is as before ──~%")
(set-agent-disposable! #f)
(check "the disposable total does not outlive its build"
       (near? (assq-ref (ledger) 'available) (+ (* 24.0 (/ 1439.0 1440.0)) 8.0)))

(format #t "~%  ✓ — ~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
