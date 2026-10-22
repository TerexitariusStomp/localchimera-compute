;;; module/playnet/test/e2e.scm — helpers for scenario-level tests.
;;;
;;; Unit suites check one act; an e2e suite walks a whole story through the
;;; door layer — offer, claim, envelope, receipt, dispute, settlement — and
;;; the prose between checks is half the point. These helpers keep each
;;; suite to the same shape: a door call that unwraps or fails loudly, a
;;; scenario step that narrates, and a controllable clock over
;;; *compute-clock* so timelines that take days compress into a test.
;;;
;;;   (define clock (make-fake-clock 1_700_000_000))
;;;   (parameterize ((*compute-clock* (car clock))) …)
;;;   ((cdr clock) 3600)    ;; advance one hour

(define-module (playnet test e2e)
  #:use-module (goblins)
  #:use-module (ice-9 format)
  #:export (door-call ok-value scenario make-fake-clock))

(define (ok-value resp)
  "Unwrap a door's (ok . value); on (error . msg) raise so the scenario's
   check names the door that refused instead of matching on a pair."
  (if (and (pair? resp) (eq? (car resp) 'ok))
      (cdr resp)
      (error "door refused" resp)))

(define (door-call gov identity door . args)
  "($ gov DOOR IDENTITY . ARGS), unwrapped — the linear-scenario form of a
   door call. The door's own (error …) surfaces as a raised error so a
   scenario fails at the step that refused, not three checks later."
  (ok-value (apply $ gov door identity args)))

(define (scenario label)
  "A section header — the suite reads as the story it tells."
  (format #t "~%── ~a ──~%" label))

(define (make-fake-clock start-seconds)
  "→ ((getter) . (advance! seconds)). Bind *compute-clock* to the getter;
   advance! moves the doors' 'now' forward. The getter is a thunk because
   the parameter is called — ((*compute-clock*)) — not dereferenced."
  (let ((now start-seconds))
    (cons (lambda () now)
          (lambda (secs) (set! now (+ now secs)) now))))
