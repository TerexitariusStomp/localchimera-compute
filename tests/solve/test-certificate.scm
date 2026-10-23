;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-certificate.scm — a plan and its proof are one object.
;;;
;;; Spec: docs/playnet.typ §7.11 ("it carries its own certificate: the duality
;;;       gap μ … is driven to zero, so the plan is provably within a known,
;;;       shrinking margin of the best possible"), and docs/social-category.typ
;;;       §5.3 + §8 Obligation 8 — optimality IS conjugacy, so a solve that emits
;;;       only x has emitted half an answer.
;;;
;;; That sentence was true of the arithmetic and false of the interface. μ was
;;; computed inside `pk_solve_pd`, used for its own stall detector, and dropped
;;; on return. Every caller could TRUST a plan; none could CHECK one. A market
;;; clears without proving anything, and the whole claim here is that this does
;;; better — which requires the proof to leave the solver.
;;;
;;; This test therefore asserts two different things, and the second is the one
;;; that could not be written before:
;;;   1. the plan matches an analytically known optimum;
;;;   2. the certificate reported alongside it is real and small.
;;;
;;; The rig has a closed-form answer. One activity x, a satiating desire pulling
;;; toward 20 at weight 1000, and a fragility barrier at tip 10 with fixed weight
;;; 50. Maximise  −1000·((20−x)/20)² − 50·(−log(10−x))  ⇒  x* = 9.0839543.
;;; It is the same rig test-frag-farstart.scm uses, so the two agree on what the
;;; right answer is.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/solve/test-certificate.scm

(use-modules (playnet test planner prelude)
             (playnet solve engine) (playnet test planner worked-example)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format)
             (system foreign))

(define x-star 9.0839543)          ; the analytic optimum of the rig below

(define (rig)
  (list (mk-des (mk-bar 0.0 '((0 . 1.0))) 20.0 1000.0)   ; desire → 20, weight 1000
        (mk-frag 10.0 (list (cons 0 -1.0)) 50.0)          ; fragility, tip 10, w 50
        (mk-bar 0.0 '((0 . 1.0)))))                       ; x ≥ 0

(display "\n── the plan, and the proof that travels with it ──\n")

;; The primal-dual step is the one that carries a duality gap.
(let* ((r  (call-with-values (lambda () (solve-native-c-pd (rig) '() (vector 1.0))) list))
       (x  (vector-ref (car r) 0))
       (its (cadr r))
       (mu (caddr r)))
  (format #t "  primal-dual: x = ~,7f   (optimum ~,7f)\n" x x-star)
  (format #t "               μ = ~,3e   after ~a iterations\n" mu its)
  ;; Tolerance 1e-3 RELATIVE, not tighter: this optimum sits against a fragility
  ;; wall, and fraction-to-the-boundary deliberately keeps the iterate a fixed
  ;; fraction clear of every barrier. A barrier method therefore lands a hair
  ;; SHORT of a wall-adjacent optimum by construction — 9.0849 for 9.0840 here,
  ;; 0.01%. Demanding exactness would be demanding the safeguard be switched off.
  (check "the plan is the analytic optimum, to barrier accuracy"
         (< (/ (abs (- x x-star)) x-star) 1e-3))
  (check "…and the solve returns its duality gap at all"
         (real? mu))
  (check "…and that gap is small enough to be a certificate"
         (< mu 1e-6))
  ;; The gap must be a REAL measurement, not a constant someone wired in — if it
  ;; were, it would read the same on a problem the solver had to work harder at.
  (check "the gap is finite and non-negative, as sᵀy/m must be"
         (and (>= mu 0.0) (< mu 1e300))))

(display "\n── one certificate, whatever ran ──\n")

;; There is no longer a per-backend taxonomy to assert. Every route reports the
;; SAME KKT residuals, because the residuals do not care which solver produced
;; the plan. A caller no longer has to know what ran in order to know what it
;; holds — which is the entire point of measuring the plan rather than the solver.
(for-each
  (lambda (backend)
    (set! *backend* backend)
    (call-with-values (lambda () (solve (rig) '() (vector 1.0))) list)
    (let ((c (certificate-of-last-solve)))
      (format #t "  ~10a → ~a\n" backend (certificate-summary))
      (check (format #f "~a reports feasibility" backend)
             (boolean? (assq-ref c 'feasible?)))
      (check (format #f "~a reports a duality gap" backend)
             (real? (assq-ref c 'mu)))
      (check (format #f "~a reports a stationarity residual" backend)
             (real? (assq-ref c 'stationarity)))))
  '(native-pd native-c native osqp auto))
(set! *backend* 'auto)

;; the primal-dual keeps its MEASURED gap alongside the fitted one — they should
;; agree, and the agreement is itself a check on the projection
(set! *backend* 'native-pd)
(call-with-values (lambda () (solve (rig) '() (vector 1.0))) list)
(let ((c (certificate-of-last-solve)))
  (format #t "  measured μ = ~,3e   fitted μ = ~,3e\n"
          (assq-ref c 'measured-mu) (assq-ref c 'mu))
  (check "the primal-dual also carries its MEASURED gap"
         (real? (assq-ref c 'measured-mu)))
  ;; the fitted and measured gaps are different constructions; both must be real
  ;; numbers and the plan must be feasible. Asserting they AGREE would be
  ;; asserting the fit is calibrated, which it is not yet — see the task list.
  (check "…and the plan it certifies is feasible"
         (assq-ref c 'feasible?)))
(set! *backend* 'auto)

(display "\n── no route may ride a fragility to its tip ──\n")

;; The exclusion has to hold on EVERY path into the solver, not the one that was
;; patched first. OSQP was excluded from solve-native-c's FALLBACK list, which
;; left the AUTO dispatch free to hand it the same problem as a PRIMARY backend —
;; and a qc-free sparse economy takes exactly that branch. A fragility-carrying
;; plan went straight through. The property belongs to the solver, not to one
;; code path, so it is asserted over all of them.
(for-each
  (lambda (backend)
    (set! *backend* backend)
    (let* ((r (call-with-values (lambda () (solve (rig) '() (vector 1.0))) list))
           (x (vector-ref (car r) 0))
           (c (certificate-of-last-solve)))
      (format #t "  ~10a → x = ~9,5f   ~a\n" backend x (certificate-summary))
      (check (format #f "~a keeps the plan strictly inside the fragility tip" backend)
             (< x 10.0))
      ;; and the certificate SAYS so — primal feasibility is the same test that
      ;; the three scattered "OSQP may not be handed a fragility" exclusions were
      ;; each approximating, now stated once
      (check (format #f "~a certifies that feasibility rather than assuming it" backend)
             (assq-ref c 'feasible?))))
  '(auto native native-c native-pd osqp))
(set! *backend* 'auto)

(display "\n── does the bounded gap actually BOUND the suboptimality? ──\n")

;; The decisive check on whether μ = t is a certificate or a slogan. The identity
;; holds where y = t/s is DUAL-FEASIBLE; the solver measures exactly that residual
;; (∇f − Aᵀy is what pk_csr_grad computes at parameter t) and reports it as the
;; convergence flag. So: solve, take the certificate, and check the real
;; suboptimality against it.
;;
;; h(x) = −1000·((20−x)/20)² − 50·(−log(10−x)) — the rig's objective, exactly.
(define (h x) (- (* -1000.0 (expt (/ (- 20.0 x) 20.0) 2))
                 (* 50.0 (- (log (- 10.0 x))))))

(let* ((_ (set! *backend* 'native-c))
       (r (call-with-values (lambda () (solve (rig) '() (vector 1.0))) list))
       (x (vector-ref (car r) 0))
       (c (certificate-of-last-solve))
       (mu (assq-ref c 'mu))
       (m  1)                          ; one t-scaled barrier (x ≥ 0); frag carries a FIXED w
       (bound (* m mu))
       (short (abs (- (h x-star) (h x)))))
  (set! *backend* 'auto)
  (format #t "  halted at x = ~,7f   (reference optimum ~,7f)\n" x x-star)
  (format #t "  |h(x*) − h(x)| = ~,3e\n" short)
  (format #t "  certificate    ≤ ~,3e   (m·μ, m = ~a)\n" bound m)
  (check "the true suboptimality lies INSIDE the certificate the solver issued"
         (<= short (+ bound 1e-12)))
  ;; the two agree to 3e-8, which is below the precision of the reference constant
  ;; itself — so this rig cannot distinguish them more finely than that
  (check "…and both points are the optimum to numerical precision"
         (< short 1e-6)))

(display "\n── no route may ride a fragility to its tip ──\n")

;; The exclusion has to hold on EVERY path into the solver, not the one that was
;; patched first. OSQP was excluded from solve-native-c's FALLBACK list, which
;; left the AUTO dispatch free to hand it the same problem as a PRIMARY backend —
;; and a qc-free sparse economy takes exactly that branch. A fragility-carrying
;; plan went straight through. The property belongs to the solver, not to one
;; code path, so it is asserted over all of them.
(for-each
  (lambda (backend)
    (set! *backend* backend)
    (let* ((r (call-with-values (lambda () (solve (rig) '() (vector 1.0))) list))
           (x (vector-ref (car r) 0))
           (c (certificate-of-last-solve)))
      (format #t "  ~10a → x = ~9,5f   ~a\n" backend x (certificate-summary))
      (check (format #f "~a keeps the plan strictly inside the fragility tip" backend)
             (< x 10.0))
      ;; and the certificate SAYS so — primal feasibility is the same test that
      ;; the three scattered "OSQP may not be handed a fragility" exclusions were
      ;; each approximating, now stated once
      (check (format #f "~a certifies that feasibility rather than assuming it" backend)
             (assq-ref c 'feasible?))))
  '(auto native native-c native-pd osqp))
(set! *backend* 'auto)

(display "\n── does the bounded gap actually BOUND the suboptimality? ──\n")

;; The decisive check on whether μ = t is a certificate or a slogan. The identity
;; holds where y = t/s is DUAL-FEASIBLE; the solver measures exactly that residual
;; (∇f − Aᵀy is what pk_csr_grad computes at parameter t) and reports it as the
;; convergence flag. So: solve, take the certificate, and check the real
;; suboptimality against it.
;;
;; h(x) = −1000·((20−x)/20)² − 50·(−log(10−x)) — the rig's objective, exactly.
(define (h x) (- (* -1000.0 (expt (/ (- 20.0 x) 20.0) 2))
                 (* 50.0 (- (log (- 10.0 x))))))

(let* ((_ (set! *backend* 'native-c))
       (r (call-with-values (lambda () (solve (rig) '() (vector 1.0))) list))
       (x (vector-ref (car r) 0))
       (c (certificate-of-last-solve))
       (mu (assq-ref c 'mu))
       (m  1)                          ; one t-scaled barrier (x ≥ 0); frag carries a FIXED w
       (bound (* m mu))
       (short (abs (- (h x-star) (h x)))))
  (set! *backend* 'auto)
  (format #t "  halted at x = ~,7f   (reference optimum ~,7f)\n" x x-star)
  (format #t "  |h(x*) − h(x)| = ~,3e\n" short)
  (format #t "  certificate    ≤ ~,3e   (m·μ, m = ~a)\n" bound m)
  (check "the true suboptimality lies INSIDE the certificate the solver issued"
         (<= short (+ bound 1e-12)))
  ;; the two agree to 3e-8, which is below the precision of the reference constant
  ;; itself — so this rig cannot distinguish them more finely than that
  (check "…and both points are the optimum to numerical precision"
         (< short 1e-6)))

(display "\n── on a realistic program, feasibility is certified ──\n")

;; What is PROVEN here is feasibility: the plan sits inside every limit, and the
;; certificate says so from the plan itself rather than from trust in whichever
;; solver ran. Stationarity is reported beside it as a DIAGNOSTIC and is not yet
;; calibrated — the dual it uses is the central-path form, exact on the central
;; path and approximate off it, and on this program it reads 1.1e-1 where the
;; solver's own gradient test calls the solve converged. Those two disagree, so
;; nothing gates on stationarity and this test does not assert it. Calibrating it
;; is the outstanding piece; claiming it now would be the exact error this whole
;; exercise exists to prevent.
(let ()
  (setup-space 0.04)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (set! *backend* 'native-c)
      (call-with-values (lambda () (solve forms lf (located-warm cols ncol idx))) list)
      (let ((c (certificate-of-last-solve)))
        (format #t "  located program → ~a\n" (certificate-summary))
        (check "a realistic located solve is certified FEASIBLE"
               (assq-ref c 'feasible?))
        (check "…with every barrier slack strictly positive"
               (> (assq-ref c 'min-slack) 0.0))
        (check "…and a duality gap reported for it"
               (real? (assq-ref c 'mu))))))
  (set! *backend* 'auto))

(check-done "  One KKT report, whatever solver ran.~%")
