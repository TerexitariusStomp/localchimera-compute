;;; family-probe.scm — the household split, run by the browser build.
;;;
;;; `family-split` is the planner's own solve (playnet doors family solve): the
;;; engine, the reference interior-point core, the recipes, all of it. This entry
;;; imports it the way a page would and times a few solves, so `make
;;; check-hoot-planner` proves the whole planner still compiles for Hoot, and a
;;; person can read the cost of a local solve off the console.
;;;
;;; Run:  make check-hoot-planner            (compiles it)
;;;       make hoot-probe-family             (compiles and runs it under node)

(use-modules (hoot ffi) (playnet doors family solve))

(define-foreign %now "performance" "now" -> f64)
(define-foreign %log "console" "log" f64 -> none)

;; per purse: the purse, milliseconds for the solve, euros spent, 1 when feasible
(define (probe purse)
  (let* ((t0 (%now))
         (r  (family-split %family-demo-needs purse))
         (t1 (%now)))
    (%log purse)
    (%log (- t1 t0))
    (%log (exact->inexact (assq-ref r 'spent)))
    (%log (if (assq-ref r 'feasible?) 1.0 0.0))))

(probe 250) (probe 250) (probe 400) (probe 400)
