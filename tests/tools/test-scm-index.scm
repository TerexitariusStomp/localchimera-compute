;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/tools/test-scm-index.scm — scope/shadow-aware find-callers + duplicate-shape detection
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/tools/test-scm-index.scm

(use-modules (localchimera test harness)
             (localchimera tools scm-index)
             (srfi srfi-1))

(define forms
  '((define (square x) (* x x))
    (define (sum-of-squares a b) (+ (square a) (square b)))
    (define (double x) (* x 2))
    (define (unrelated) (display "hi"))))

(check "find-def locates a top-level define by name"
       (find-def forms 'square)
       0)

(check "find-def returns #f for an unknown name"
       (find-def forms 'nonexistent)
       #f)

(check-pred "find-callers finds usages, excluding the definition site"
            (let ((paths (find-callers forms 'square)))
              (and (= (length paths) 2)
                   (every (lambda (p) (= (car p) 1)) paths))))

(check "recursive self-call in a definition's own body counts"
       (length (find-callers (list '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))) 'fact))
       1)

(check "lambda parameter shadows an outer name of the same spelling"
       (length (find-callers (list '(define (use-it) (lambda (x) (+ x 1)))) 'x))
       0)

(check "unshadowed reference to an outer name still counts"
       (length (find-callers (list '(define (use-it) (display x))) 'x))
       1)

(check "let binding's own value expr sees the outer name, not itself"
       (length (find-callers (list '(define (f) (let ((x x)) (g x)))) 'x))
       1)

(check "let* makes later bindings see earlier ones (shadowed, no outer match)"
       (length (find-callers (list '(define (f) (let* ((x 1) (y x)) y))) 'x))
       0)

(check "plain let does NOT let bindings see each other"
       (length (find-callers (list '(define (f) (let ((x 1) (y x)) y))) 'x))
       1)

(check "letrec lets a binding's value expr see sibling bindings"
       (length (find-callers
                (list '(define (f)
                         (letrec ((even? (lambda (n) (odd? n)))
                                  (odd? (lambda (n) (even? n))))
                           even?)))
                'even?))
       0)

(check "named let's loop name and vars shadow its body"
       (length (find-callers (list '(define (f n) (let loop ((n n)) (if (= n 0) 1 (loop (- n 1)))))) 'n))
       0)

(check "named let doesn't disturb an unrelated real call inside its body"
       (length (find-callers (list '(define (f n) (let loop ((n n)) (unrelated-fn n)))) 'unrelated-fn))
       1)

(check "internal define shadows subsequent forms but not earlier ones"
       (length (find-callers
                (list '(define (f) (display x) (define x 10) (display x)))
                'x))
       1)

(check "quoted symbols are data, not occurrences"
       (length (find-callers (list '(define (f) (list 'square 'circle))) 'square))
       0)

(check "list-defines enumerates all top-level defines in order"
       (list-defines forms)
       '((square . 0) (sum-of-squares . 1) (double . 2) (unrelated . 3)))

(check-pred "find-duplicate-shapes flags structurally identical bodies"
            (let ((groups (find-duplicate-shapes
                           '((define (add-one x) (+ x 1))
                             (define (increment y) (+ y 1))
                             (define (something-else z) (* z z))))))
              ;; add-one and increment have identical shape: (+ sym num)
              (and (= (length groups) 1)
                   (= (length (car groups)) 2))))

(test-summary!)
