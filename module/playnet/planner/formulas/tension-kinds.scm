;;; tension-kinds.scm — the SINGLE SOURCE OF TRUTH for per-kind term math.
;;;
;;; One spec → BOTH backends. `*kind-spec*` is a list of
;;;   (tag code value-expr grad-expr curv-expr)
;;; where each expr is an arithmetic form over the variables (s t D w). From it:
;;;   • the Scheme closures here (built by `eval`) — read by planner.scm's hot
;;;     loops term-coeffs / csr-grad / obj-value, and by the tension-registry actor;
;;;   • the C kernel helpers in kernel_kinds.h — emitted by gen-kernels.scm.
;;; The C and Scheme can no longer drift: they are generated from the same data,
;;; and test-tension-parity.scm checks them bit-for-bit.
;;;
;;;   value      φ(s)
;;;   grad-coeff φ′(s) = dφ/ds       (a form's gradient contribution is φ′·a)
;;;   curvature  φ″(s) = d²φ/ds²     (its rank-1 Hessian weight)
;;; Signs are folded into φ′ (bar's is −t/s) so every loop is just += φ′·a.
;;; Integer codes match `flatten`: 0=bar, 1=des, 2=qc, 3=frag, 4=held, 5=cap.
;;;
;;; `frag` is the white-paper FRAGILITY PROFILE (docs/planning/ecological-
;;; tipping-tensions.md): the SAME log barrier as `bar`, but carrying a FIXED
;;; governance weight w instead of the swept central-path t. So it diverges at
;;; the tipping point (never crossed) AND persists at the optimum (the federation
;;; "eases off before the limit"), which the swept `bar` does not. The endpoints
;;; (s_tip, s*) and direction are folded into the linear form at build time, so
;;; the slack s reaching the kind is already the normalised distance-to-tip
;;; (1 at the healthy state s*, →0 at the tip). One hard-limit shape serves every
;;; possibility-tension — ecological caps, tipping points, care-capacity.

(define-module (playnet planner formulas tension-kinds)
  #:export (sq make-kind kind-value kind-grad kind-curv *kind-spec* spec-tag spec-code
            spec-value spec-grad spec-curv mkfn spec->kind *kind-library* *kind-fns*
            priority-weight))

;; A priority LEVEL 0..9 weighs w = β^level, with β⁹ = 1000: a level-9 want
;; weighs a thousand level-0 ones. The one table for that ladder; the engine
;; consumes the weights and a need's terms (utils/tension-terms.scm) state the
;; level.
(define *priority-base* 2.154434690031884)   ; 1000^(1/9), written out: Hoot folds a constant expt at compile time and cannot
(define (priority-weight level) (expt *priority-base* level))

(define (sq x) (* x x))
(define (make-kind value grad curv) (vector value grad curv))
(define (kind-value k) (vector-ref k 0))
(define (kind-grad  k) (vector-ref k 1))
(define (kind-curv  k) (vector-ref k 2))

;; The spec is DATA (gen-kernels.scm emits the C from it) and CODE (the closures
;; below). One macro reads it once and yields both: the closures are compiled
;; where the spec is written, so nothing needs `eval` at load time — which a
;; whole-program build (Hoot) has not got. The variable names arrive from the
;; use site, so the expressions and the lambdas that bind them share one scope.
;;   *kind-library*  tag → builder thunk (persistence stores tags, not closures)
;;   *kind-fns*      hot-path dispatch, indexed by flatten's int code
;;                   (0=bar 1=des 2=qc 3=frag 4=held 5=cap)
(define-syntax define-kind-specs
  (syntax-rules ()
    ((_ (s t D w) spec lib fns ((tag code v g c) ...))
     (begin
       (define spec '((tag code v g c) ...))
       (define lib
         (list (cons 'tag (let ((k (make-kind (lambda (s t D w) v) (lambda (s t D w) g) (lambda (s t D w) c))))
                            (lambda () k))) ...))
       (define fns
         (let ((vec (make-vector 6)))
           (vector-set! vec code (make-kind (lambda (s t D w) v) (lambda (s t D w) g) (lambda (s t D w) c))) ...
           vec))))))

(define-kind-specs (s t D w) *kind-spec* *kind-library* *kind-fns*
  ((bar  0 (if (> s 1e-12) (* (- t) (log s)) 1e12)          ; hard possibility-tension
              (if (> s 1e-12) (- (/ t s)) 0.0)
              (if (> s 1e-12) (/ t (* s s)) 0.0))
    (des  1 (if (< s D) (* w (sq (/ (- D s) D))) 0.0)         ; soft desire-tension
              (if (< s D) (/ (* -2.0 w (- D s)) (* D D)) 0.0)
              (if (< s D) (/ (* 2.0 w) (* D D)) 0.0))
    (qc   2 (* w s s)                                          ; two-sided quadratic (EMP)
              (* 2.0 w s)
              (* 2.0 w))
    (frag 3 (if (> s 1e-12) (* (- w) (log s)) 1e12)            ; fragility profile: fixed-weight barrier
              (if (> s 1e-12) (- (/ w s)) 0.0)
              (if (> s 1e-12) (/ w (* s s)) 0.0))
    ;; `held` — a desire that does not ABANDON. Ordinary `des` is BOUNDED: a wholly
    ;; unmet want costs w and no more, so a want priced far above the rest can be
    ;; set aside for a finite price. That is right for wants and wrong for anything
    ;; the federation means to hold for everyone, and the only alternative used to
    ;; be promoting it to a hard floor — all or nothing.
    ;;
    ;; This is the middle. Writing u = s/D for the satisfied fraction,
    ;;   φ = w·(1−u)²/u
    ;; which is w·g² divided by the satisfaction it leaves. At satiation it agrees
    ;; with `des` in VALUE, GRADIENT and CURVATURE (all three: 0, 0, 2w/D²), so it
    ;; behaves exactly like an ordinary desire in the ordinary range and costs
    ;; nothing to swap in. As satisfaction collapses it diverges, so no finite
    ;; weight on any other tension can buy someone out of it entirely.
    ;;
    ;; USE IT CONSISTENTLY ACROSS A CLASS. An unbounded penalty always outbids a
    ;; bounded one in the limit, so a lone `held` beside ordinary desires does not
    ;; protect the worst-off — it consumes the budget and the DESIRES get dropped
    ;; instead. Measured on a two-need economy at a 100x cost ratio: `held` on the
    ;; dear need alone drove the cheap need to 0 and Φ to 0; `held` on BOTH moved
    ;; the dear need 1.51% → 2.28% and Φ 0.0298 → 0.0413. Where nothing binds the
    ;; two kinds agree to the barrier residue (99.900 vs 99.901 of 100), which is
    ;; the point: it costs nothing until someone is about to be left behind.
    (held 4 (if (< s D) (if (> s 1e-12) (/ (* w (sq (- D s))) (* D s)) 1e12) 0.0)
              (if (< s D) (if (> s 1e-12) (- (/ (* w (- (* D D) (* s s))) (* D s s))) 0.0) 0.0)
              (if (< s D) (if (> s 1e-12) (/ (* 2.0 w D) (* s s s)) 0.0) 0.0))
    ;; `cap` — a want whose ASK is a wall, not a target. `des` puts D inside
    ;; the value ((D−s)/D)², so a bigger ask pulls a bigger share under
    ;; scarcity: proportional rationing, and the reason a quantity paid to
    ;; pad (docs/planning/solve/quantity-as-a-cap.md). Here the value never sees D:
    ;;   φ = w/(1+s)
    ;; convex, decreasing, bounded (w at nothing delivered, → 0 with plenty),
    ;; so a want on a good nobody makes is simply unmet, never infeasible.
    ;; The ask enters only as the wall s ≤ D the engine emits beside it. At
    ;; the optimum every such term sits at −φ′ = μ, i.e. s = √(w/μ) − 1: a
    ;; WATER LEVEL set by the citizen's emphasis mass w and the good's
    ;; scarcity μ — never by their own report. Above the level the report is
    ;; inert (QuantityAsCap.lean forced_flatness); below it the wall binds,
    ;; and there truth is self-interest. D here is NOT an ask — it is the
    ;; spec's REFERENCE SCALE (one natural quantum of the good: a loaf, a
    ;; night, a litre; engine `set-cap-scale!`, default 1), so the term is
    ;; scale-free the way `des` was: measure the good in grams instead of
    ;; kilograms, state the scale in grams, and every level is unchanged.
    ;; Report-independent by construction — a scale a report could move
    ;; would re-open the very door this kind closes.
    (cap  5 (/ w (+ 1.0 (/ s D)))
              (- (/ w (* D (sq (+ 1.0 (/ s D))))))
              (/ (* 2.0 w) (* D D (+ 1.0 (/ s D)) (+ 1.0 (/ s D)) (+ 1.0 (/ s D)))))))

(define (spec-tag e)   (car e))     (define (spec-code e)  (cadr e))
(define (spec-value e) (caddr e))   (define (spec-grad e)  (cadddr e))
(define (spec-curv e)  (list-ref e 4))
(define mkfn                          ; an expression from outside the spec: the one place that needs `eval`
  (cond-expand (guile (lambda (expr) (eval (list 'lambda '(s t D w) expr) (current-module))))
               (else (lambda (expr) (error "mkfn needs eval; this build compiles the spec at expansion time" expr)))))
(define (spec->kind e) (make-kind (mkfn (spec-value e)) (mkfn (spec-grad e)) (mkfn (spec-curv e))))
