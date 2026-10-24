;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/free-time-fold.scm — ^freetime-node: the federation fold, over time.
;;;
;;; The plan states how much of the people's time it places; social free time
;;; f = 1 − Σ planned / Σ offered is what credit and consumer voice blend by.
;;; One f per federation, read off the tree like every other aggregate, so it
;;; follows refederation (a scope that leaves takes its cells with it,
;;; `drop-child` exact) and every node can answer for the scopes under it.
;;;
;;; A QUANTITY fold, nameless above the home (docs/planning/federation/
;;; federation-identity-and-folds.md §8–9). Each person is counted once, at the
;;; scope they are at home in, so the sum is sound by the home and needs no
;;; join; and no person is visible above their own scope. A scope states two
;;; cells, the hours its plan places on the people at home here and the time
;;; those people have, summed up the tree like slack's:
;;;
;;;   (planned . *)   (offered . *)
;;;
;;; The ratio is a READ (ratios never add): `free-time` is `free-time-fraction`
;;; over the two sums, the one arithmetic every reading of free time shares.
;;;
;;; Writes: freetime-changed (own-cells) — the holder of the solve cache fires
;;; it when a plan lands (doors/planner/solve-cache.scm scope-own-plan-time);
;;; the fold derives nothing itself.

(define-module (localchimera pools free-time-fold)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module ((localchimera algorithms free-time) #:select (free-time-fraction))
  #:export (freetime-monoid ^freetime-node
            freetime-reads freetime-writes
            freetime-planned freetime-offered freetime-of))

(define freetime-monoid keyed-sum-monoid)

(define (cell-ref cells key)
  (let ((p (assoc key cells))) (if p (cdr p) 0)))

(define (freetime-planned cells) (cell-ref cells '(planned . *)))
(define (freetime-offered cells) (cell-ref cells '(offered . *)))

(define (freetime-of cells)
  "f over CELLS: the fraction of the offered time the plans leave unplanned;
   0 where no plan has stated anyone."
  (free-time-fraction (freetime-planned cells) (freetime-offered cells)))

(define freetime-reads
  `((cells     . ,(lambda (t) t))
    (planned   . ,(lambda (t) (freetime-planned t)))
    (offered   . ,(lambda (t) (freetime-offered t)))
    (free-time . ,(lambda (t) (freetime-of t)))))

(define freetime-writes
  `((freetime-changed . ,(lambda (own cells) cells))))

(define ^freetime-node
  (fold-aggregate freetime-monoid freetime-reads freetime-writes #:prefix "freetime"))
