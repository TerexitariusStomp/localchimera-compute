;;; admm-probe.scm — the federated solve, run by the browser build.
;;;
;;; `solve-decomposed` coordinates scopes that each solve their own program and
;;; meet on the goods that cross between them. A device in that federation solves
;;; its scope with the reference core (no compiled kernel in a page), so this
;;; entry runs the test chain of scopes (playnet/test/planner/federated-fixtures.scm, the one
;;; every federated test builds) through the browser build and logs, per chain
;;; length: the met percentage, the rounds, the milliseconds. The native build
;;; measures 99.90% met in 35 rounds at S=4 (tests/federated-reference-core-test.scm).
;;;
;;; Run:  make hoot-probe-admm

(use-modules (hoot ffi) (playnet solve engine) (playnet solve decomposed) (playnet solve solver))
(include-from-path "playnet/test/planner/federated-fixtures.scm")

(define-foreign %now "performance" "now" -> f64)
(define-foreign %log "console" "log" f64 -> none)

(define (probe S)
  (let ((t0 (%now)))
    (call-with-values (lambda () (solve-decomposed (fx-chain S) #:accel #t #:iters 400))
      (lambda (plans met rounds pulls)
        (%log (exact->inexact S))
        (%log (- (%now) t0))
        (%log met)
        (%log (exact->inexact rounds))))))

(probe 2) (probe 4)
