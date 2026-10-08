;;; test-federated-bound-floor.scm — what the federated certificate is made of,
;;; and why its SIZE moves the way it does.
;;;
;;; §7.2 recorded the chain cover's bound as erratic in S — 2.5 at S=4, 57.7 at
;;; S=8, 3.9 at S=16 — and left the reason open. This file is the reason,
;;; measured.
;;;
;;; THE BOUND IS A SUM OF TWO TERMS THAT MOVE IN OPPOSITE DIRECTIONS.
;;; `local-bound` is Σ over scopes of each scope's own certified gap, and each
;;; of those is m·t plus a stationarity term. Lower the path floor t and the
;;; first shrinks; lower it too far and the inner solves can no longer reach it
;;; inside their budget, so the second grows. Measured on the chain fixtures:
;;;
;;;     cover  S    t=0.005    t=0.0005   t=0.00005
;;;     chain  4     2.55        1.70        0.139
;;;     chain  8    57.7         9.20        2.99
;;;     chain 16     3.90      101.9       350.1     (met falls 99.92 → 99.48)
;;;
;;; So at S=4 and S=8 the barrier term dominates and a smaller floor is worth
;;; ~19×; at S=16 the stationarity term dominates and the same change is worth
;;; -90×, in a plan that also serves less demand.
;;;
;;; WHY THE FLOOR IS THE SHIPPED CONSTANT HERE AT ALL. §7.3: in a cover of S
;;; scopes exactly ONE — the root, the only scope with no taking column — has a
;;; bounded box, and deriving t = target-gap/m is licensed only where the box is
;;; bounded. So S−1 scopes take `*kern-tmin-default*`, a constant chosen for
;;; single-scope programs, and whether that constant happens to sit on the good
;;; side of the crossover for a given cover is not something anything decides.
;;; That is the whole of the erraticism: not a defect of the certificate, which
;;; reports what it is given, but a floor nobody chose for the scopes that use
;;; it.
;;;
;;; A COROLLARY WORTH HAVING. `refine` exists to drive the stationarity term to
;;; zero, so it can only help where that term is the binding one — which is
;;; exactly why the gate accepts at star S=16 and refuses across the rest of the
;;; grid (§7.2). The gate is not mysterious; it is reading the term that happens
;;; to dominate.
;;;
;;; AND WHY MORE ROUNDS IS NOT THE ANSWER. The outer loop stops on consensus and
;;; a plateau in `met`, neither of which is the quantity being certified, so the
;;; bound is a snapshot of the last inner solves at an arbitrary point. Running
;;; longer is not monotone: chain S=4 with the plateau exit relaxed ran 244
;;; rounds instead of 35 and certified 10.6 instead of 2.55.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/planner/test-federated-bound-floor.scm

(use-modules (playnet test planner prelude)
             (playnet planner solve engine)
             (playnet planner solve solver)
             (srfi srfi-1)
             (ice-9 format))
(primitive-load "module/playnet/test/planner/federated-fixtures.scm")

;; the floor is a global, so it is set and put back — a test that leaves the
;; engine retuned is a test that breaks whatever runs after it in the same image
(define (at-floor floor thunk)
  (let ((d *kern-tmin-default*) (c *kern-tmin*))
    (dynamic-wind
      (lambda () (set! *kern-tmin-default* floor) (set! *kern-tmin* floor))
      thunk
      (lambda () (set! *kern-tmin-default* d) (set! *kern-tmin* c)))))

(define (chain-bound S floor)
  (at-floor floor
    (lambda ()
      (call-with-values
        (lambda () (solve-decomposed (fx-chain S) #:accel #t #:reconcile? #f))
        (lambda (plans met rounds pulls)
          (cons (assq-ref (certificate-of-last-solve) 'local-bound) met))))))

(display "\n── the bound against the path floor, on a chain ──\n")
(format #t "   S   floor       local-bound     met%\n")
(define (row S floor)
  (let ((r (chain-bound S floor)))
    (format #t "  ~2a   ~8,5f    ~,4e   ~7,3f\n" S floor (car r) (cdr r))
    r))

(define s8-shipped (row 8 0.005))
(define s8-fine    (row 8 0.00005))
(define s16-shipped (row 16 0.005))
(define s16-fine    (row 16 0.00005))

;;; ── the barrier term is real, and it is large ───────────────────────────────
;;; On the 8-scope chain the shipped floor is most of the bound: dropping it two
;;; decades buys an order of magnitude. If this ever stops holding, the bound is
;;; no longer dominated by m·t there and the explanation above has changed.
(check "on an 8-scope chain the shipped floor dominates the bound"
       (> (car s8-shipped) (* 5.0 (car s8-fine))))

;;; ── and the stationarity term is real too, in the other direction ───────────
;;; The same change on the 16-scope chain makes the bound WORSE, because the
;;; inner solves cannot reach the tighter floor in budget. This is the half that
;;; makes "just lower the floor" the wrong fix, and it is the half a single
;;; measurement would have missed.
(check "…while on a 16-scope chain the same floor change makes it worse"
       (> (car s16-fine) (car s16-shipped)))
(check "…and costs served demand, so it is not a free tightening"
       (< (cdr s16-fine) (cdr s16-shipped)))

;;; ── which is why the size of a federated bound is not a measure of the cover ─
;;; Two covers of the same shape, certified under one floor, differ by more than
;;; an order of magnitude in a direction that reverses under another floor. Any
;;; reading that compares bounds ACROSS S is comparing where each solve stopped.
(check "the bound is not monotone in S at a fixed floor — S=8 exceeds S=16"
       (> (car s8-shipped) (car s16-shipped)))

;;; What is NOT in question is soundness. Every bound above is a valid upper
;;; bound on its own plan's optimality gap; the certificate is honest about a
;;; solve it was handed. The open question is the floor those solves are given,
;;; and it is a design question — see docs/planning/solve/planner-coherence-open-threads.md §7.6.
(check-done)
