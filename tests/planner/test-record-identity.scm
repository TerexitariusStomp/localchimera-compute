;;; test-record-identity.scm — a record is the same kind of thing on both sides.
;;;
;;; The planner's schemas are reached two ways: imported as a module by
;;; `(playnet planner)`, and `primitive-load`ed by the solver engine when it runs
;;; standalone. `make-record-type` mints a fresh type per evaluation, so the same
;;; definition produced two types sharing a name and nothing else.
;;;
;;; This is the ORDER that failed: engine first, module second. A <time-range>
;;; built by the engine was rejected by the module's own predicate, and the
;;; module's accessor raised "wrong type" on it. That is why the arithmetic in
;;; utils/clock.scm had to live at the string layer.
;;;
;;; Run: guile --no-auto-compile -L module tests/planner/test-record-identity.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (srfi srfi-1) (ice-9 format))

;; the engine, standalone — this defines the schemas in guile-user
(use-modules (playnet vf schemas) (playnet vf beyond schedules))

;; …and now the module path, which evaluates the same definitions again
(use-modules (playnet vf facts availability)
             ((playnet utils records) #:select (vf-record-type vf-record-constructor vf-record-accessor vf-record-copier vf-record-maker vf-record-from-list vf-record-type-fields)))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(format #t "~%── a value crosses the load seam ──~%~%")

(define engine-tr (make-time-range "09:00" "17:00"))

(check "the module's predicate accepts the engine's record"
       (time-range? engine-tr))
(check "the module's accessor reads the engine's record"
       (equal? "09:00" (time-range-start-time engine-tr)))

;; the operation that actually failed: it maps over pairs and reads both sides
(define got (intersect-time-ranges (list engine-tr)
                                   (list (make-time-range "12:00" "20:00"))))
(check "intersect-time-ranges works across the seam"
       (and (= 1 (length got))
            (equal? "12:00" (time-range-start-time (car got)))
            (equal? "17:00" (time-range-end-time (car got)))))

(format #t "~%── the mechanism ──~%~%")

(check "interning twice yields the SAME type object"
       (eq? (vf-record-type 'SeamProbe '((immutable a)))
            (vf-record-type 'SeamProbe '((immutable a)))))

;; two shapes under one name is a real disagreement, not something to reconcile
(check "…and a redefinition with different fields raises rather than lying"
       (catch #t
         (lambda () (vf-record-type 'SeamProbe '((immutable a) (immutable b))) #f)
         (lambda _ #t)))

;; the whole point: what clock.scm had to work around
(check "a record built either side answers the same predicate"
       (every time-range? (list engine-tr (make-time-range "00:00" "01:00"))))

(format #t "~%── the functional update ──~%~%")

(define %probe-type (vf-record-type 'CopyProbe '((immutable a) (immutable b) (immutable c))))
(define %make-probe (vf-record-constructor %probe-type))
(define %probe-a (vf-record-accessor %probe-type 'a))
(define %probe-b (vf-record-accessor %probe-type 'b))
(define %probe-c (vf-record-accessor %probe-type 'c))
(define copy-probe (vf-record-copier %probe-type))
(let ((p (copy-probe (%make-probe 1 2 3) #:b 20)))
  (check "a copy carries every field it was not told to change"
         (equal? (list (%probe-a p) (%probe-b p) (%probe-c p)) '(1 20 3))))
(check "a copy with no overrides equals its original field for field"
       (let ((p (copy-probe (%make-probe 1 2 3))))
         (equal? (list (%probe-a p) (%probe-b p) (%probe-c p)) '(1 2 3))))
(check "a keyword naming no field raises rather than being dropped"
       (catch #t (lambda () (copy-probe (%make-probe 1 2 3) #:d 4) #f) (lambda _ #t)))

(format #t "~%── the keyword constructor ──~%~%")
(define probe (vf-record-maker %probe-type))
(check "a record made by keyword carries what it states and #f elsewhere"
       (let ((p (probe #:c 3 #:a 1)))
         (equal? (list (%probe-a p) (%probe-b p) (%probe-c p)) '(1 #f 3))))
(check "a keyword naming no field raises"
       (catch #t (lambda () (probe #:d 4) #f) (lambda _ #t)))
(check "a positional argument is refused: a record is made by naming its fields"
       (catch #t (lambda () (probe 1 2) #f) (lambda _ #t)))
(check "a stored field list reads back, the trailing fields left off as #f"
       (let ((p ((vf-record-from-list %probe-type) '(1 2))))
         (equal? (list (%probe-a p) (%probe-b p) (%probe-c p)) '(1 2 #f))))
(check "an intent made by keyword is the intent read from its stored field list, field for field"
       (let ((k (make-intent #:id "i1" #:action 'consume #:resource-conforms-to "bread"))
             (p ((vf-record-from-list <intent>) '("i1" consume #f #f #f #f #f #f "bread"))))   ; trailing fields left off
         (every (lambda (f) (equal? ((vf-record-accessor <intent> f) k) ((vf-record-accessor <intent> f) p)))
                (vf-record-type-fields <intent>))))
(check "an economic event copied with one field keeps the other twenty-nine"
       (let* ((e (make-economic-event #:id "e1" #:action 'work #:input-of "P" #:provider "alice"
                                      #:receiver "bob" #:effort-quantity (make-measure 2 %effort-unit)
                                      #:note "n"))
              (c (copy-economic-event e #:corrects "e0")))
         (and (equal? (economic-event-corrects c) "e0")
              (equal? (economic-event-provider c) "alice")
              (equal? (economic-event-note c) "n")
              (equal? (economic-event-effort-quantity c) (economic-event-effort-quantity e)))))

(format #t "~%~a passed, ~a failed~%~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
