;;; structural-edit-test.scm — path-addressed paredit-style ops
;;;
;;; Run:  guile --no-auto-compile -q -L module -l module/playnet/tools/tests/structural-edit-test.scm

(use-modules (playnet test harness)
             (playnet tools structural-edit))

(define sample
  '((define (classify x)
      (cond
       ((< x 0) 'negative)
       ((= x 0) 'zero)))
    (define (helper y) (* y 2))))

(check "get-at-path reads without mutating"
       (get-at-path sample '(0))
       '(define (classify x)
          (cond
           ((< x 0) 'negative)
           ((= x 0) 'zero))))

(check "append-child-at-path adds a new cond clause"
       (append-child-at-path sample '(0 2) '((> x 0) 'positive))
       '((define (classify x)
           (cond
            ((< x 0) 'negative)
            ((= x 0) 'zero)
            ((> x 0) 'positive)))
         (define (helper y) (* y 2))))

(check "replace-at-path swaps a subform"
       (replace-at-path sample '(1 2 2) 3)
       '((define (classify x)
           (cond
            ((< x 0) 'negative)
            ((= x 0) 'zero)))
         (define (helper y) (* y 3))))

(check "insert-after-at-path adds a new top-level form"
       (insert-after-at-path '((define (a) 1) (define (c) 3)) '(0) '(define (b) 2))
       '((define (a) 1)
         (define (b) 2)
         (define (c) 3)))

(check "wrap-at-path wraps a single node in a new head"
       (get-at-path (wrap-at-path (list '(do-thing)) '(0) 'when) '(0))
       '(when (do-thing)))

(check "splice-at-path unwraps a node into its parent"
       (splice-at-path '(a (b c) d) '(1))
       '(a b c d))

(check "slurp-forward-at-path pulls the next sibling in"
       (slurp-forward-at-path '((+ x 1) y) '(0))
       '((+ x 1 y)))

(check "barf-forward-at-path pushes the last element out"
       (barf-forward-at-path '((+ x 1)) '(0))
       '((+ x) 1))

(check "raise-at-path replaces the parent with the focus"
       (raise-at-path '(begin (inner)) '(1))
       '(inner))

(test-summary!)
