;;; test-refine-gate.scm — the federated refinement gate, measured across covers
;;; instead of asserted at one point.
;;;
;;; `refine` re-solves each scope exactly at the converged pulls, dropping the
;;; proximal term to drive its stationarity residual to zero — and ‖r‖·D is what
;;; the federated bound is made of, so a smaller ‖r‖ is a tighter certificate.
;;; Dropping the prox is also what lets scopes walk apart, so the result is
;;; GATED: kept only when it improves the bound and (with reconciliation off)
;;; does not cost agreement.
;;;
;;; test-federated-certificate.scm asserts that composing refinement with
;;; reconciliation tightens the star's bound. It does — at S=16. Measured over
;;; the grid, that is the ONLY place in it where the gate accepts:
;;;
;;;     cover  S    plain bound   both bound    accepted?
;;;     star   4      1.883E-1     1.883E-1     no
;;;     star   8      3.325E-1     3.325E-1     no
;;;     star  16      1.080E+0     3.925E-1     YES  (0.363×)
;;;     star  32      2.631E+0     2.631E+0     no
;;;     chain  4      2.547E+0     2.547E+0     no
;;;     chain  8      5.774E+1     5.774E+1     no
;;;     chain 16      3.903E+0     3.903E+0     no
;;;     chain 32      1.910E+4     1.910E+4     no
;;;
;;; So the S=16 result is a point, not a property, and this file says which of
;;; the two things there is actually a property. What must hold EVERYWHERE is
;;; that the gate is sound — it never ships a worse bound than refusing would
;;; have. What must hold SOMEWHERE is that it accepts at all, or the machinery
;;; is dead code kept for a comment. Those are the two checks.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-refine-gate.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))
(primitive-load "module/playnet/test/planner/federated-fixtures.scm")

(define (bound-of scopes reconcile?)
  (call-with-values (lambda () (solve-decomposed scopes #:accel #t #:reconcile? reconcile?))
    (lambda (plans met rounds pulls)
      (assq-ref (certificate-of-last-solve) 'gap-bound))))

(define GRID
  (append (map (lambda (s) (cons 'star s))  '(4 8 16))
          (map (lambda (s) (cons 'chain s)) '(4 8 16))))

(display "\n── the refine gate over a grid of covers ──\n")
(format #t "  cover  S    refused      accepted     ratio  accepted?\n")

(define results
  (map (lambda (cs)
         (let* ((mk (if (eq? 'star (car cs)) fx-star fx-chain))
                (S  (cdr cs))
                (scopes (mk S))
                (plain (bound-of scopes #f))
                (both  (bound-of scopes #t))
                (ratio (if (> plain 0.0) (/ both plain) 1.0)))
           (format #t "  ~5a ~3a  ~10,3e  ~10,3e  ~6,3f  ~a\n"
                   (car cs) S plain both ratio (if (< ratio 0.95) "YES" "no"))
           (list (car cs) S plain both ratio)))
       GRID))

;; SOUNDNESS — the property. Refinement is only ever kept when it beats the
;; alternative, so composing it must never leave a WORSE bound than refusing it.
;; A tiny tolerance because the two paths are separate solves and the plain
;; bound is not bit-reproducible across them.
(check "the gate never ships a worse bound than refusing would have"
       (every (lambda (r) (< (list-ref r 4) 1.02)) results))

;; LIVENESS — the gate accepts somewhere, so the refinement is not dead code.
;; Deliberately not "at star S=16": that pins the test to the one configuration
;; the property was discovered in, which is what this file exists to stop.
(check "…and it does accept somewhere — the refinement is live"
       (any (lambda (r) (< (list-ref r 4) 0.95)) results))

;; And the shape of WHERE it accepts, stated as the narrow fact it is rather
;; than left as an impression that refinement generally helps.
(let ((wins (filter (lambda (r) (< (list-ref r 4) 0.95)) results)))
  (format #t "\n  accepted in ~a of ~a covers: ~s\n"
          (length wins) (length results)
          (map (lambda (r) (list (car r) (cadr r))) wins))
  (check "acceptance is the exception, and this file records it as such"
         (< (length wins) (length results))))

(check-done "  The gate is sound everywhere and helps in one place — measured, not assumed.~%")
