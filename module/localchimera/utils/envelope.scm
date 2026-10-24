;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; envelope.scm — the planner service's answer, ok or error
;;;
;;; A door returns either (ok . X) or (error . "message"); the browser
;;; pattern-matches on (car result). Mutation methods build the answer through
;;; these three, so a refusal has one shape on every door.

(define-module (localchimera utils envelope)
  #:export (success failure catch-as-failure)
  #:use-module ((localchimera utils catch) #:select (catch* throw* with-throw-handler*)))

(cond-expand (guile) (else (define (backtrace) #f)))   ; a page keeps no stack to print


(define (success x) (cons 'ok x))

(define (failure msg) (cons 'error msg))

(define (catch-as-failure thunk)
  "Run THUNK and either return its value or wrap any raised exception
   into a failure envelope. The caller gets the message; the operator's log
   gets the backtrace — a failure string names what, the log names where."
  (catch* #t
    (lambda () (with-throw-handler* #t thunk
                 (lambda (key . args)
                   (format (current-error-port) "[catch-as-failure] ~a ~a~%" key args)
                   (backtrace))))
    (lambda (key . args)
      (failure (format #f "~a: ~a" key args)))))
