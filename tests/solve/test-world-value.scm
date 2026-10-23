;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-world-value.scm — the world is a value in hand, one per dynamic extent.
;;;
;;; `declare-world!` fills the world in hand; `(current-world)` is that value;
;;; `(call-with-world w thunk)` runs the thunk with W in hand and leaves the
;;; caller's world standing; `reset-world!` puts a fresh instance in hand. So a
;;; holder of one world may declare and solve another inside it and find its
;;; own untouched after, and two extents never share a table.
;;;
;;; Run: guile --no-auto-compile -L module tests/solve/test-world-value.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (playnet solve engine) (playnet solve world))

(define *pass* 0) (define *fail* 0)
(define (names) (map (lambda (p) (if (pair? p) (car p) p)) *places*))
(define (check name ok)
  (if ok (begin (set! *pass* (1+ *pass*)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (1+ *fail*)) (format #t "  ✗ ~a~%" name))))

(declare-world! #:places '(("A" 0.0 0.0)) #:periods '(0 1))
(hash-set! *init* "x#A@0" 7.0)
(define w1 (current-world))
(check "the world in hand is a <world>" (world? w1))
(check "declaring fills the world in hand" (equal? '("A") (names)))

(define w2
  (call-with-world (make-world)
    (lambda ()
      (check "inside call-with-world a fresh world is in hand" (not (eq? w1 (current-world))))
      (check "…and it is empty" (null? *places*))
      (declare-world! #:places '(("B" 1.0 1.0)) #:periods '(0))
      (check "a declaration inside fills the inner world" (equal? '("B") (names)))
      (check "the inner world's tables are its own" (not (hash-ref *init* "x#A@0" #f)))
      (current-world))))

(check "after the extent the caller's world is in hand again" (eq? w1 (current-world)))
(check "…with its places" (equal? '("A") (names)))
(check "…and its tables" (eqv? 7.0 (hash-ref *init* "x#A@0" #f)))
(check "the inner world is a value the caller may hold" (world? w2))
(call-with-world w2
  (lambda ()
    (check "a held world put back in hand reads as it was left" (equal? '("B") (names)))))
(check "the two worlds share no table"
       (not (eq? (call-with-world w1 (lambda () *init*)) (call-with-world w2 (lambda () *init*)))))

(reset-world!)
(check "reset-world! puts a fresh instance in hand" (not (eq? w1 (current-world))))
(check "…every table new" (and (null? *places*) (zero? (hash-count (const #t) *init*))))
(check "the old world stands as a value still"
       (eqv? 7.0 (call-with-world w1 (lambda () (hash-ref *init* "x#A@0" #f)))))

(format #t "~%~a passed, ~a failed~%" *pass* *fail*)
(exit (if (zero? *fail*) 0 1))
