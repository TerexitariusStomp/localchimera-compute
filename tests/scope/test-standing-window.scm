;;; test-standing-window.scm — a standing declaration's window re-stands.
;;;
;;; The festival's crowd terms carry a rolling three-day window, and the
;;; reassert inside seed-berlin-festival-arm! is the one re-stand door: a
;;; term whose window aged out (or was finished) is stood back up on the
;;; fresh window, while a current one is left exactly as it stands — which
;;; is what lets the gateway's plan tick call the seed every interval.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-standing-window.scm
(use-modules (playnet knowledge recipes berlin-festival-seed) (playnet scope root) (playnet vf schemas)
             (playnet knowledge recipes berlin-festival-seed)
             ((playnet vf facts tension-terms) #:select (with-tension-terms))
             ((playnet utils clock) #:select (now instant->civil))
             (goblins) (goblins vat) (srfi srfi-1) (ice-9 format))
(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ok: ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  FAIL: ~a~%" name))))
(define today (instant->civil (now) "%Y-%m-%d"))
(define vat (spawn-vat #:name "standing-window"))
(with-vat vat
  (let* ((root (spawn-scope-root "fest"))
         (ps   ($ root 'plan-store))
         (until-of (lambda (id) (intent-has-end ($ ps 'get-intent id)))))
    (seed-berlin-festival-arm! root)
    (check "the crowd's want stands on a window reaching past today"
           (string>=? (until-of "need:festival-crowd:meal") today))
    (let ((u0 (until-of "need:festival-crowd:meal")))
      (seed-berlin-festival-arm! root)
      (check "a current window is left exactly as it stands"
             (equal? u0 (until-of "need:festival-crowd:meal"))))
    ;; the window ages out: the same declaration, ended years ago
    ($ ps 'remove-intent "need:festival-crowd:meal")
    ($ ps 'add-intent
       (make-intent #:id "need:festival-crowd:meal" #:action 'consume #:name "festival meals" #:image "🥗" #:resource-conforms-to "meal"
                    #:resource-classified-as (with-tension-terms '() "des" 100)
                    #:resource-quantity (make-measure 60.0 "kg") #:receiver "festival-crowd"
                    #:has-beginning "2020-01-01" #:has-end "2020-01-03"
                    #:at-location "berlin-festival"))
    (seed-berlin-festival-arm! root)
    (check "an aged-out window is stood back up on the fresh one"
           (string>=? (until-of "need:festival-crowd:meal") today))
    (check "…and the floor rides the same fresh window"
           (string>=? (until-of "need:festival-crowd:meal-floor") today))))
(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
