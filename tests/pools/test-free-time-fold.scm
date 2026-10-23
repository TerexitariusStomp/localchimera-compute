;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-free-time-fold.scm — ^freetime-node: social free time as a federation fold.
;;;
;;; A QUANTITY fold, nameless above the home: each scope states two cells, the
;;; hours its plan places on the people at home there and the time they have,
;;; and the tree sums them like slack's. What this suite pins:
;;;   • f is one read over the whole tree: two scopes' sums add;
;;;   • a node answers for the scopes under it;
;;;   • a scope restating its cells replaces them, it does not add to them;
;;;   • a departing subtree leaves exactly (refederation is drop-child);
;;;   • no cell names a person;
;;;   • no plan has stated anyone: f is 0.
;;; (The keyed sum's laws — associative, commutative — are held with the other
;;; folds' in tests/pools/test-fold-laws.scm.)
;;;
;;; Run:  guile -q -L module tests/pools/test-free-time-fold.scm

(use-modules (playnet test harness) (srfi srfi-1)
             (playnet pools free-time-fold)
             (playnet vf aggregation fold-node)
             (goblins) (goblins vat))

(define (near? a b) (< (abs (- a b)) 1e-9))
(define (own planned offered) (list (cons '(planned . *) planned) (cons '(offered . *) offered)))

(define vat (spawn-vat #:name "free-time-fold"))
(with-vat vat
  (let* ((uc (spawn ^freetime-node '() '() "uc"))
         (a  (spawn ^freetime-node '() '() "a"))
         (b  (spawn ^freetime-node '() '() "b")))
    (wire-fold-parent! a uc "a")
    (wire-fold-parent! b uc "b")

    (display "\n── nothing stated ──\n")
    (check "f is 0 until a plan states someone" (near? ($ uc 'free-time) 0))

    (display "\n── two scopes' sums add ──\n")
    ($ a 'freetime-changed (own 8.0 16.0))
    ($ b 'freetime-changed (own 4.0 8.0))
    (check "planned sums over the tree" (near? ($ uc 'planned) 12.0))
    (check "offered sums over the tree" (near? ($ uc 'offered) 24.0))
    (check "f = 1 − 12/24" (near? ($ uc 'free-time) 0.5))
    (check "a node answers for the scopes under it: a alone is 1 − 8/16" (near? ($ a 'free-time) 0.5))
    (check "…and b alone is 1 − 4/8" (near? ($ b 'free-time) 0.5))
    (check "no cell names a person"
           (every (lambda (c) (member (car c) '((planned . *) (offered . *)))) ($ uc 'cells)))

    (display "\n── a scope restating its cells replaces them ──\n")
    ($ a 'freetime-changed (own 2.0 16.0))
    (check "a's new plan stands in place of its old: planned 2 + 4" (near? ($ uc 'planned) 6.0))
    (check "f follows: 1 − 6/24" (near? ($ uc 'free-time) 0.75))

    (display "\n── a departing subtree leaves exactly ──\n")
    ($ uc 'drop-child "b")
    (check "b's hours are gone: planned 2 of 16" (near? ($ uc 'planned) 2.0))
    (check "f follows: 1 − 2/16" (near? ($ uc 'free-time) 0.875))))

(test-summary!)
