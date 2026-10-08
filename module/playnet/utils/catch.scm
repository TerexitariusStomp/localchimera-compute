;;; catch.scm — Guile's catch/throw, on a build that has neither.
;;;
;;; The planner signals "this week has no plan" with (throw 'planner-starvation …)
;;; and its callers read the KEY to tell that from a bug (family.scm answers a
;;; starved week as "no plan" and rethrows anything else). Guile's `catch`,
;;; `throw` and `with-throw-handler` are the mechanism. Hoot (the browser build)
;;; implements none of them, so callers state them through this module:
;;;
;;;   catch*             (catch* TAG THUNK HANDLER)  — TAG a key or #t
;;;   throw*             (throw* KEY ARG …)
;;;   with-throw-handler* (with-throw-handler* KEY THUNK HANDLER) — the handler
;;;                       sees the throw where it happens, then it carries on
;;;
;;; On Guile each is the core procedure itself. On Hoot a throw is a raised
;;; <thrown> record, and any other raised condition (an `error`, a primitive's
;;; failure) reads as the key `misc-error`, which is what Guile calls it.

(define-module (playnet utils catch)
  #:use-module (srfi srfi-9)
  #:export (catch* throw* with-throw-handler*))

(cond-expand
 (guile
  (define catch* catch)
  (define throw* throw)
  (define with-throw-handler* with-throw-handler))
 (else
  (define-record-type <thrown>
    (make-thrown key args)
    thrown?
    (key thrown-key)
    (args thrown-args))

  (define (throw* key . args)
    (raise-exception (make-thrown key args)))

  (define (%key-of e) (if (thrown? e) (thrown-key e) 'misc-error))
  (define (%args-of e) (if (thrown? e) (thrown-args e) (list e)))
  (define (%wants? tag e) (or (eq? tag #t) (eq? tag (%key-of e))))

  (define (catch* tag thunk handler)
    (call/cc
     (lambda (k)
       (with-exception-handler
        (lambda (e)
          (if (%wants? tag e)
              (k (apply handler (%key-of e) (%args-of e)))
              (raise-exception e)))
        thunk))))

  (define (with-throw-handler* tag thunk handler)
    (with-exception-handler
     (lambda (e)
       (when (%wants? tag e) (apply handler (%key-of e) (%args-of e)))
       (raise-exception e))
     thunk))))
