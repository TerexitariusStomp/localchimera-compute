;;; test-free-time-publication.scm — f is published where a root plan lands.
;;;
;;; The service publishes the plan's social free time when a plan LANDS for a
;;; scope declared under nothing (a root). A what-if brief stands for nothing and
;;; a child scope's plan covers its own roster alone, so neither moves the f that
;;; credit and consumer voice read.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-free-time-publication.scm
(use-modules (playnet scope root) (playnet vf schemas)
             (playnet doors service)
             (playnet algorithms elastic)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))
(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ok: ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  FAIL: ~a~%" name))))
(define (near? a b) (< (abs (- a b)) 1e-9))
(define (kw-ref kws k)
  (let loop ((l kws)) (cond ((null? l) #f) ((eq? (car l) k) (cadr l)) (else (loop (cdr l))))))

;; the plan's f by who asks: the root 0.30, the child 0.80, any what-if 0.95
(define (stub-plan-fn root sid . kw)
  (let ((f (cond ((pair? (kw-ref kw #:demand)) 0.95)
                 ((equal? sid "C") 0.80)
                 (else 0.30))))
    `((met . 1.0) (feasible . #t) (x . #(1.0 2.0 3.0)) (intend) (work) (material)
      (social . ((free-time . ,f))))))

(set-social-free-time! 0)
(define vat (spawn-vat #:name "free-time-publication"))
(with-vat vat
  (let* ((svc   (spawn ^planner-service (hashmap) stub-plan-fn))
         (root  (spawn-scope-root "R"))
         (child (spawn-scope-root "C")))
    ($ svc 'add-scope! "R" root)
    ($ svc 'add-scope! "C" child)
    ($ svc 'move-scope! "C" "R")
    (check "before any solve f is 0" (near? (current-social-free-time) 0))

    (display "\n── a root plan lands: f is published ──\n")
    ($ svc 'solve "R" '())
    (check "the landed root plan's f is the published f" (near? (current-social-free-time) 0.30))

    (display "\n── a question stands for nothing ──\n")
    ($ svc 'solve-brief "R" '((demand . (("soup" "town" 0 5.0)))))
    (check "a what-if brief leaves f where the root plan put it" (near? (current-social-free-time) 0.30))

    (display "\n── a child's plan covers its own roster ──\n")
    ($ svc 'solve "C" '())
    (check "a child scope's landed plan leaves f alone" (near? (current-social-free-time) 0.30))))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
