;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation-crossing-fixture.scm — the economy the crossing tests solve.
;;;
;;; A scope is a granary-and-bakery: a boundary column, grain, bread; land that
;;; limits grain, a labour budget, and a demand for bread. Its boundary column
;;; is built by hand to go one way: it gives grain (the column leaves the
;;; grain balance) or takes it (the column enters it). One good, "G", is shared
;;; by every scope; the reference is the MONOLITH — the scopes' programs side
;;; by side in one record, with the single row that says what is drawn is at
;;; most what is supplied.
;;;
;;; `load`ed by the tests (a file, not a module: it defines into the test's own
;;; top level, where the solver's DSL is in scope).

(use-modules ((localchimera solve federation-oracle) #:select (make-boundary-oracle))
             (localchimera solve solver))

;; ── the economy ─────────────────────────────────────────────────────────────
;; A scope is a granary-and-bakery: a boundary column, grain, bread; land that
;; limits grain, a labour budget, and a demand for bread. Its boundary column
;; gives (it leaves the grain balance) or takes (it enters it).
(define DEM 100.0)
(define (scope-forms off bcol soil A sign)
  (let* ((g (+ off 1)) (b (+ off 2)))
    (append (map (lambda (i) (mk-bar 0.0 (list (cons (+ off i) 1.0)))) '(0 1 2))
            (list (mk-bar soil (list (cons g -1.0)))
                  (mk-bar A (list (cons g -0.3) (cons b -0.5)))
                  (mk-bar 0.0 (list (cons g 1.0) (cons b -1.0) (cons bcol (* sign -1.0))))
                  (mk-des (mk-bar 0.0 (list (cons b 1.0))) DEM 1000.0)))))
;; sign +1: the column gives; −1: it takes
(define (scope-record spec)
  (let ((soil (list-ref spec 1)) (A (list-ref spec 2)) (sign (list-ref spec 3)))
    (list (cons 'forms (scope-forms 0 0 soil A sign))
          (cons 'labform (list (cons 1 0.3) (cons 2 0.5)))
          (cons 'x0 (make-vector 3 0.1))
          (cons 'crossings (list (cons* 0 "G" sign 0))))))
;; the monolith: the scopes side by side, and one row — what is drawn is at
;; most what is supplied
(define (monolith specs)
  (let* ((n (length specs))
         (forms (append-map (lambda (s spec)
                              (scope-forms (* 3 s) (* 3 s) (list-ref spec 1) (list-ref spec 2) (list-ref spec 3)))
                            (iota n) specs))
         (pool (mk-bar 0.0 (map (lambda (s spec) (cons (* 3 s) (exact->inexact (list-ref spec 3)))) (iota n) specs))))
    (list (cons 'forms (append forms (list pool)))
          (cons 'labform (append-map (lambda (s) (list (cons (+ (* 3 s) 1) 0.3) (cons (+ (* 3 s) 2) 0.5))) (iota n)))
          (cons 'x0 (make-vector (* 3 n) 0.1))
          (cons 'crossings '()))))
(define (monolith-met specs)
  (let ((o (make-boundary-oracle (monolith specs))))
    (cdr (assq 'met (o 'solve! '() 1.0)))))

;; a spec: (name soil labour sign)
(define (economy label soil-mult)
  (let ((m soil-mult))
    (case label
      ((one-supplies)  `(("granary" ,(* 360.0 m) 150.0 1) ("baker-1" ,(* 42.0 m) 90.0 -1) ("baker-2" ,(* 42.0 m) 90.0 -1)))
      ((two-supply) `(("granary-1" ,(* 180.0 m) 75.0 1) ("granary-2" ,(* 180.0 m) 75.0 1) ("baker" ,(* 42.0 m) 90.0 -1)))
      ((two-and-two)   `(("granary-1" ,(* 180.0 m) 75.0 1) ("granary-2" ,(* 180.0 m) 75.0 1)
                         ("baker-1" ,(* 42.0 m) 90.0 -1) ("baker-2" ,(* 42.0 m) 90.0 -1))))))

