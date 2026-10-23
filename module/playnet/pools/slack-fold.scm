;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/slack-fold.scm — ^slack-node: the federation fold, over desire.
;;;
;;; The earth face tints each place by how whole its demand reads — met over
;;; wanted — and each container by the geometric mean of the places within it.
;;; Today the per-place ratio is computed per request off one scope's cached
;;; solve (service.scm location-slacks) and the geomean is folded in the
;;; browser. This is the same thing as a fold: each scope contributes its OWN
;;; per-place cells, the tree sums them keyed, and the ratio and the geomean
;;; are reads over the standing total — so the overlay is one read at any
;;; node, refederation-safe, and the browser draws rather than folds.
;;;
;;; Cells: (want . place) and (met . place), summed up the tree — keyed-sum-
;;; monoid. Slack is min(1, met/want), a READ (ratios never add); a geomean
;;; is a read over a place set, exact from the per-place sums (no log
;;; accumulator is needed once the sums themselves climb).
;;;
;;; Writes: slack-changed (scope-id own-cells) — the holder of the solve
;;; cache fires it when a solve lands; the fold derives nothing itself.

(define-module (playnet pools slack-fold)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf aggregation fold-node)
  #:export (slack-monoid ^slack-node slack-reads slack-writes
            slack-of geomean-slack cells->slacks))

(define slack-monoid keyed-sum-monoid)

(define (cell-ref cells key)
  (let ((p (assoc key cells))) (if p (cdr p) 0)))

(define (slack-of cells place)
  "min(1, met/want) at PLACE, or #f when nothing is wanted there."
  (let ((w (cell-ref cells (cons 'want place))))
    (and (> w 0) (min 1.0 (/ (cell-ref cells (cons 'met place)) w)))))

(define (cells->slacks cells)
  "((place . slack) …) for every place with a want."
  (filter-map (lambda (c)
                (and (eq? (caar c) 'want)
                     (let ((s (slack-of cells (cdar c))))
                       (and s (cons (cdar c) s)))))
              cells))

(define (geomean-slack cells places)
  "The geometric mean of the slacks at PLACES (those with a want), or #f."
  (let ((ss (filter-map (lambda (p) (slack-of cells p)) places)))
    (and (pair? ss)
         (exp (/ (fold + 0 (map (lambda (s) (log (max s 1e-9))) ss))
                 (length ss))))))

(define slack-reads
  `((cells   . ,(lambda (t) t))
    (slacks  . ,(lambda (t) (cells->slacks t)))
    (slack   . ,(lambda (t place) (slack-of t place)))
    (geomean . ,(lambda (t . places)
                  (geomean-slack t (if (pair? places) (car places)
                                       (map car (cells->slacks t))))))))

(define slack-writes
  `((slack-changed . ,(lambda (own cells) cells))))

(define ^slack-node
  (fold-aggregate slack-monoid slack-reads slack-writes #:prefix "slack"))
