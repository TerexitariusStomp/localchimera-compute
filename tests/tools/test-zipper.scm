;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/tools/test-zipper.scm — round trips and local moves over the Huet zipper
;;;
;;; Run:  guile --no-auto-compile -q -L module -l tests/tools/test-zipper.scm

(use-modules (localchimera test harness)
             (localchimera tools zipper))

(check "round trip with no edits is identity"
       (zip-root (make-zipper '(define (foo x) (+ x 1))))
       '(define (foo x) (+ x 1)))

(check "down/right/replace/up/root edits in place"
       (let* ((z (make-zipper '(define (foo x) (+ x 1))))
              (z (zip-down z))    ; define
              (z (zip-right z))   ; (foo x)
              (z (zip-right z))   ; (+ x 1)
              (z (zip-down z))    ; +
              (z (zip-replace z '-)))
         (zip-root z))
       '(define (foo x) (- x 1)))

(check "insert-right adds a sibling without disturbing focus"
       (let* ((z (make-zipper '(a b d)))
              (z (zip-down z))   ; a
              (z (zip-right z))  ; b
              (z (zip-insert-right z 'c)))
         (zip-root z))
       '(a b c d))

(check "insert-left adds a sibling before focus"
       (let* ((z (make-zipper '(a b c)))
              (z (zip-down z))   ; a
              (z (zip-right z))  ; b
              (z (zip-insert-left z 'x)))
         (zip-root z))
       '(a x b c))

(check "remove drops focus and moves to left sibling"
       (let* ((z (make-zipper '(a b c)))
              (z (zip-down z))   ; a
              (z (zip-right z))  ; b
              (z (zip-right z))  ; c
              (z (zip-left z))   ; b
              (z (zip-remove z)))
         (zip-root z))
       '(a c))

(check "path reports child indices from the root"
       (let* ((z (make-zipper '(a b (c d))))
              (z (zip-down z))
              (z (zip-right z))
              (z (zip-right z))  ; (c d)
              (z (zip-down z)))  ; c
         (zip-path z))
       '(2 0))

(check "zip-find-down locates a sibling by predicate"
       (zipper-node (zip-find-down (make-zipper '(foo bar baz qux))
                                    (lambda (n) (eq? n 'baz))))
       'baz)

(test-summary!)
