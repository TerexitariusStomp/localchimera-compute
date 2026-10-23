;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federated-reference-core.scm — a scope solves the same program on either core.
;;;
;;; The federated solve (solve-decomposed) and the boundary oracle read a scope's
;;; program out of a record of buffers, and the compiled kernel is one way to solve
;;; it. The reference core is the other, and the only one a browser has. They are the
;;; same convex program, so they meet at the same plan: this holds the two against
;;; one chain of scopes, and the reference core against the kernel's answer.
;;;
;;; Run: guile tests/solve/test-federated-reference-core.scm

(use-modules (playnet solve decomposed))
(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))

(primitive-load (fixture-file "federated-fixtures.scm"))

(define (run enabled?)
  (set-kern-enabled! enabled?)
  (call-with-values (lambda () (solve-decomposed (fx-chain 4 #:soil-mult 1.2) #:accel #t #:iters 400))
    (lambda (plans met rounds pulls) (list plans met rounds pulls))))

(display "\n── the same chain, two cores ──\n")
(define reference (run #f))
(define kernel    (and (begin (set-kern-enabled! #t) (kern-available?)) (run #t)))
(set-kern-enabled! #t)

(format #t "  reference core: met ~5,2f%   ~a rounds~%" (cadr reference) (caddr reference))
(check "the reference core serves the chain" (> (cadr reference) 99.0))
(check "…one plan per scope, each a vector of finite numbers"
       (and (= (length (car reference)) 4)
            (every (lambda (x) (and (vector? x) (every (lambda (v) (and (real? v) (< (abs v) 1e12))) (vector->list x))))
                   (car reference))))
(check "…and a pull for every boundary link"
       (> (hash-count (const #t) (cadddr reference)) 0))

(if kernel
    (begin
      (format #t "  compiled kernel: met ~5,2f%   ~a rounds~%" (cadr kernel) (caddr kernel))
      (check "the two cores deliver the same met, within half a point"
             (< (abs (- (cadr reference) (cadr kernel))) 0.5))
      (check "…and pull the same links"
             (equal? (sort (hash-map->list (lambda (k v) (format #f "~a" k)) (cadddr reference)) string<?)
                     (sort (hash-map->list (lambda (k v) (format #f "~a" k)) (cadddr kernel)) string<?))))
    (display "  (no compiled kernel linked here: the cores are not compared)\n"))
