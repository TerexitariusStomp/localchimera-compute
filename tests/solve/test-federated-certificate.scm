;;; test-federated-certificate.scm — what a federated solve can and cannot prove.
;;;
;;; Spec: docs/social-category.typ §6 (constraints glue exactly, objectives glue
;;;       by iterating boundary pulls) + §8 Obligation 8.
;;;
;;; The monolithic path publishes a certified bound on its distance from optimal.
;;; The federated path published nothing at all — plans, met%, rounds, pulls, and
;;; no way for anyone to check any of it. That is the mode intended for actual
;;; federations, so it was the one place the system asked to be trusted rather
;;; than believed.
;;;
;;; It now reports a CERTIFIED BOUND, by the monolithic derivation plus one term.
;;; With local duals y_s and the coupling dual λ (the boundary pulls), write
;;; ∇f = Aᵀy + A_cᵀλ + r; then for any coupling-feasible x* (so A_c x* = 0),
;;;
;;;     f(x) − f(x*)  ≤  Σ_s y_sᵀs_s(x)  +  λᵀ(A_c x)  +  ‖r‖‖x − x*‖
;;;
;;; the extra term being the DISAGREEMENT PRICED AT THE BOUNDARY DUALS. The
;;; fields:
;;;
;;;   feasible?    every scope's plan satisfies that scope's own constraints.
;;;                PROVEN, per scope, by the same KKT test the monolith uses.
;;;   local-bound  Σ per-scope certified gaps, each measured against the scope's
;;;                own program PLUS the boundary pull it is coordinating under.
;;;                Without the pull this measures "the scope did not act
;;;                selfishly", which is not a defect and not the question.
;;;   disagreement-in-hours   λᵀ|A_c x| — the link violations at what the federation
;;;                says those goods are worth. Measured at 1e-4 or less here: the
;;;                pull-coordination is tight, and the bound is dominated entirely
;;;                by how loosely the inner solves converged.
;;;   gap-bound    the sum. CERTIFIED.
;;;
;;; TWO honesty clauses. The bound is on the OBJECTIVE, and while consensus > 0
;;; the plan is not coupling-feasible — scopes disagree about what crosses, so it
;;; is near-optimal in VALUE and not yet consistent in QUANTITY; reconciliation is
;;; a separate step. And the bound is currently LOOSE (order 1e2–1e7 against
;;; objectives of order 1e2), because Σ local dominates it.
;;;
;;; Run: guile tests/solve/test-federated-certificate.scm

(use-modules (playnet solve decomposed))
(use-modules (playnet test planner prelude)
             (playnet solve engine)
             (playnet solve solver)
             (srfi srfi-1)
             (ice-9 format))
(primitive-load (fixture-file "federated-fixtures.scm"))

(define* (solve-and-certify scopes #:key (reconcile? #t))
  (call-with-values (lambda () (solve-decomposed scopes #:accel #t #:reconcile? reconcile?))
    (lambda (plans met rounds pulls)
      (cons met (certificate-of-last-solve)))))

(display "\n── a federated solve now certifies something ──\n")

(let* ((r (solve-and-certify (fx-chain 4)))
       (c (cdr r)))
  (format #t "  chain S=4: met ~,2f%\n    ~a\n" (car r) (certificate-summary))
  (check "the certificate names itself federated"
         (eq? (assq-ref c 'kind) 'federated))
  (check "…over the right number of scopes" (= (assq-ref c 'scopes) 4))
  (check "every scope's plan is certified feasible on its own constraints"
         (assq-ref c 'feasible?))
  (check "…a Σ local gap is reported" (real? (assq-ref c 'local-bound)))
  (check "…and the consensus violation with it" (real? (assq-ref c 'consensus))))

(display "\n── the boundary pull belongs in the local certificate ──\n")

;; A coordinated scope is optimising its own program PLUS the pull of what
;; crosses its boundary. Measured against the program without the pull its residual is
;; large by construction — that reads as "far from optimal" when it means "not
;; acting alone". Including the pull is what makes the number mean what a reader
;; will take it to mean. Measured effect: 2.3e3 → 5.0e2 on this fixture, and
;; 2.6e4 → 7.4e2 on a 16-scope star.
(let* ((chain (cdr (solve-and-certify (fx-chain 16))))
       (star  (cdr (solve-and-certify (fx-star 16)))))
  (format #t "  chain S=16  Σ local gap ~,3e   consensus ~,3e\n"
          (assq-ref chain 'local-bound) (assq-ref chain 'consensus))
  (format #t "  star  S=16  Σ local gap ~,3e   consensus ~,3e\n"
          (assq-ref star 'local-bound) (assq-ref star 'consensus))
  ;; The certificate must SEE the topology effect the raw measurements show: a
  ;; low-diameter cover coordinates cheaply, a chain does not. If it cannot tell
  ;; them apart it is not measuring coordination quality.
  (check "the certificate discriminates: a star certifies tighter than a chain"
         (< (assq-ref star 'local-bound) (assq-ref chain 'local-bound)))
  (check "both remain feasible per scope"
         (and (assq-ref chain 'feasible?) (assq-ref star 'feasible?))))

(display "\n── the federated bound, and what it does NOT say ──\n")

;; With local duals y_s and the coupling dual λ, ∇f = Aᵀy + A_cᵀλ + r, and for any
;; coupling-feasible x* (A_c x* = 0) convexity gives
;;   f(x) − f(x*) ≤ Σ_s y_sᵀs_s(x) + λᵀ(A_c x) + ‖r‖‖x − x*‖
;; — the monolithic derivation with ONE extra term: the disagreement priced at the
;; boundary duals. So a bound does follow, and an earlier version of this test
;; asserted it could not. It can.
(let* ((c (cdr (solve-and-certify (fx-chain 16) #:reconcile? #f)))
       (summary (certificate-summary)))
  (format #t "  UNRECONCILED: certified ≤ ~,3e   [local ~,3e + priced disagreement ~,3e]\n"
          (assq-ref c 'gap-bound) (assq-ref c 'local-bound)
          (assq-ref c 'disagreement-in-hours))
  (format #t "  overdraw = ~,3e   coupling-feasible? ~a\n"
          (assq-ref c 'overdraw) (assq-ref c 'coupling-feasible?))
  (check "a federated bound IS reported"
         (and (real? (assq-ref c 'gap-bound)) (< (assq-ref c 'gap-bound) +inf.0)))
  (check "…and it is the sum of the local gaps and the priced disagreement"
         (< (abs (- (assq-ref c 'gap-bound)
                    (+ (assq-ref c 'local-bound) (assq-ref c 'disagreement-in-hours))))
            1e-9))
  ;; Left in on purpose. This is what the ADMM alone produces, and it is NOT
  ;; something a federation can act on: some scope is drawing goods its neighbour
  ;; is not sending. Near-optimal in VALUE, inconsistent in QUANTITY.
  (check "without reconciliation a real overdraw is reported, not hidden"
         (> (assq-ref c 'overdraw) 0.0))
  (check "…and the plan is flagged NOT coupling-feasible"
         (not (assq-ref c 'coupling-feasible?)))
  (check "…with the summary saying so"
         (string-contains summary "not yet consistent in quantity")))

(display "\n── RECONCILIATION: from near-optimal in value to executable ──\n")

;; Both sides of every link adopt one crossing quantity — the owner's shipment —
;; by CLAMPING each draw to it. Two larger constructions were tried first and
;; both overshoot, because the question is microscopic and they answer it
;; globally: re-solving each scope hauls the plan to wherever the (lagging) ADMM
;; duals point, and projecting onto the nearest capped plan is itself an
;; interior-point solve whose own barrier residue displaces more than the overdraw
;; does. The clamp moves the plan by exactly the overdraw and nothing else.
;;
;; The predicate is `drawn ≤ supplied`, not equality. An interior-point solve
;; approaches a bound from strictly inside and by different residues on the two
;; sides, so exact agreement is unreachable — and unnecessary. A surplus at the
;; border is waste; a DEFICIT is a plan that cannot be executed.
(for-each
 (lambda (name scopes)
   (let* ((raw (solve-and-certify scopes #:reconcile? #f))
          (rc  (solve-and-certify scopes #:reconcile? #t))
          (cr (cdr raw)) (cc (cdr rc)))
     (format #t "  ~a: bound ~,3e → ~,3e   overdraw ~,3e → ~,3e   met ~,2f% → ~,2f%\n"
             name (assq-ref cr 'gap-bound) (assq-ref cc 'gap-bound)
             (assq-ref cr 'overdraw) (assq-ref cc 'overdraw)
             (car raw) (car rc))
     (check (format #f "~a: nothing is overdrawn — no scope draws what nobody sends" name)
            (<= (assq-ref cc 'overdraw) 1e-9))
     (check (format #f "~a: …so the plan is coupling-feasible — executable" name)
            (assq-ref cc 'coupling-feasible?))
     (check (format #f "~a: …every scope still feasible on its own constraints" name)
            (assq-ref cc 'feasible?))
     (check (format #f "~a: …and delivery is not sacrificed to get there" name)
            (> (car rc) (- (car raw) 0.5)))
     ;; Reconciliation buys EXECUTABILITY, not tightness — and it is worth being
     ;; exact, because an earlier version of this file claimed it bought both.
     ;; That was an artefact: the unreconciled path had no coupling-graph radius,
     ;; so its bound was hostage to a vanishing σ and anything looked like an
     ;; improvement. With both paths taking the same radius the two coincide, and
     ;; what reconciliation actually delivers is a plan that can be carried out.
     (check (format #f "~a: …at no cost to the certificate" name)
            (<= (assq-ref cc 'gap-bound) (* 1.001 (assq-ref cr 'gap-bound))))))
 '("chain S=4" "chain S=16" "star S=16")
 (list (fx-chain 4) (fx-chain 16) (fx-star 16)))

(display "\n── what the federated bound was actually made of ──\n")

;; The reading this file carried for a while — that a high-diameter cover
;; certifies badly because it COORDINATES badly — was wrong, and the measurement
;; that overturned it is below.
;;
;; Measured per scope on a 16-scope chain: m·μ ≈ 3·10⁻² and ‖r‖ ≈ 2·10⁻⁴, both
;; negligible. The whole bound came from the CURVATURE branch ‖r‖²/(2σ) with
;; σ ≈ 3·10⁻⁹ — because σ is a min of t/s² and the boundary columns carry slacks
;; of order 10³. The geometry branch ‖r‖·D would have been far tighter and was
;; unavailable, because D is honestly +inf: a scope's taking column is a FREE
;; SOURCE, and nothing in that scope's own program bounds it.
;;
;; What bounds it is the federation. Once the crossings are agreed the boundary
;; columns are bounded, the radius is finite, and the bound stops being hostage to
;; a vanishing σ. So the topology penalty was mostly an artefact of missing
;; information, not a cost of coordination — it falls from ~16× to ~2×. The cover
;; still decides, and it decides by much less than the earlier numbers claimed.
(let* ((star  (cdr (solve-and-certify (fx-star 16))))
       (chain (cdr (solve-and-certify (fx-chain 16)))))
  (format #t "  star ~,3e   chain ~,3e   penalty ~,2f×\n"
          (assq-ref star 'gap-bound) (assq-ref chain 'gap-bound)
          (/ (assq-ref chain 'gap-bound) (assq-ref star 'gap-bound)))
  (check "the star still certifies tighter than the chain — the cover still decides"
         (< (assq-ref star 'gap-bound) (assq-ref chain 'gap-bound)))
  ;; Stated as a CEILING on the penalty, so a regression that reintroduces the
  ;; σ-dominated bound fails here rather than merely printing a bigger number.
  ;; Stated on the CHAIN's own absolute quality rather than as a ratio to the
  ;; star. The ratio moved to ~10x not because the chain got worse but because
  ;; the star got better — refinement is accepted there and refused on a chain —
  ;; so a ratio ceiling would fail on an improvement. What must not regress is
  ;; the chain returning to the sigma-dominated bound it had with no radius.
  (check "the chain's own bound stays far from the sigma-dominated one it had"
         (< (assq-ref chain 'gap-bound) 8.0))
  (check "both are executable" (and (assq-ref star 'coupling-feasible?)
                                    (assq-ref chain 'coupling-feasible?)))
  ;; AND THE QUANTIFIER IS PUBLISHED. The radius comes from capping each boundary
  ;; column at the crossing this plan agreed, so x* ranges over plans that do not
  ;; ship more — not over all coupling-feasible plans. The tightened number is a
  ;; genuinely weaker statement than the monolithic bound, and the difference is
  ;; exactly the kind that goes unnoticed because both are called "the bound".
  ;; AND THE QUANTIFIER IS THE UNRESTRICTED ONE. An earlier version of this bound
  ;; got its radius by capping each boundary column at the crossing THAT PLAN
  ;; agreed, which certifies only against plans shipping no more — strictly weaker
  ;; than the monolithic claim, and weaker in a way easy to quote as if it were
  ;; not. The caps now come from the coupling graph instead: what a scope gives is
  ;; bounded by its own capacity given a bound on what it takes, what it takes by
  ;; what is given upstream, iterated to a fixpoint. Those hold at EVERY coupling-feasible
  ;; point, so x* ranges over all of them and the bound means what its name says.
  (check "the bound is over ALL coupling-feasible plans, not just this plan's crossings"
         (eq? (assq-ref chain 'bound-over) 'coupling-feasible))
  ;; …and WITHOUT reconciliation too. The propagated caps hold at every
  ;; coupling-feasible point, so they were always the right radius for this path;
  ;; it kept the +inf one only because the fix landed on the reconciled branch.
  ;; Measured: chain S=4 3.1e1 → 2.5, chain S=16 1.7e1 → 3.9.
  (check "…on the unreconciled path as well"
         (eq? (assq-ref (cdr (solve-and-certify (fx-chain 16) #:reconcile? #f)) 'bound-over)
              'coupling-feasible))
  (check "…on every cover"
         (eq? (assq-ref star 'bound-over) 'coupling-feasible))
  (check "…and the summary makes no restricted-quantifier claim"
         (not (string-contains (certificate-summary) "USING THESE CROSSINGS"))))

(display "\n── refinement and reconciliation solve each other's problem ──\n")

;; The bound is now made of ‖r‖·D, and ‖r‖ is the residual ADMM leaves behind by
;; truncating its inner solves ON PURPOSE. Measured per scope on a 16-chain,
;; every scope carries ‖r‖ ≈ 1e-4 except the last, which converges to 5e-9 and
;; contributes only its irreducible m·μ — so driving ‖r‖ down is the remaining
;; lever, and `refine` (the exact local solve at the converged pulls) is what
;; does it.
;;
;; It was gated on not costing AGREEMENT, because dropping the proximal term
;; lets scopes walk apart. Reconciliation repairs precisely that, so the two
;; compose: refine to kill the residual, clamp to restore executability. Neither
;; is safe alone; together they are checked — the plan is kept only if the clamp
;; leaves it feasible with nothing overdrawn.
(let* ((plain (cdr (solve-and-certify (fx-star 16) #:reconcile? #f)))
       (both  (cdr (solve-and-certify (fx-star 16) #:reconcile? #t))))
  (format #t "  star S=16: ~,3e (no reconcile, conservative gate) → ~,3e (both)\n"
          (assq-ref plain 'gap-bound) (assq-ref both 'gap-bound))
  ;; The 40% tightening this once asserted was measured with the refine's
  ;; proximal term centred on −z (a qc form costs w·(const + Σv·x)², and the
  ;; centre went in unnegated): the "exact local solve" pulled every boundary
  ;; flow toward zero, and a plan that ships less certifies tighter against
  ;; its own forms. With the prox centred on the agreed z — the consensus the
  ;; rounds reached, which is what the comment above always claimed — the
  ;; refinement is a polish of the converged plan and the star's bound holds
  ;; where the rounds left it. What composition must never do is LOOSEN it.
  (check "composing them does not loosen the star's bound"
         (<= (assq-ref both 'gap-bound) (* (+ 1.0 1e-9) (assq-ref plain 'gap-bound))))
  (check "…and the result is still executable"
         (and (assq-ref both 'coupling-feasible?) (assq-ref both 'feasible?)))
  (check "…and it was the refinement that did it"
         (assq-ref both 'refined?)))

(display "\n── is the bound MEANINGFUL? (a bound above |f| proves nothing) ──\n")

;; A certificate is only worth the ratio it bears to the objective. Absolute
;; numbers hide this — 1.08 sounds excellent and 16.8 sounds fine, until you see
;; that the objective is 25.7 and the second is 65% of it. Asserted here so the
;; test says something a reader can act on, and so a regression that loosens the
;; bound past usefulness fails rather than merely printing a larger number.
(define meanfill-cap 100.0)     ; min(1,·) averaged ×100 — a definitional ceiling

(define (objective-of scopes plans)
  (fold (lambda (s a)
          (let* ((frm (assq-ref (list-ref scopes s) 'forms))
                 (lab (or (assq-ref (list-ref scopes s) 'labform) '()))
                 (C   (flatten frm)))
            (+ a (abs (obj-value C lab 0.0 (list-ref plans s)
                                 (term-values C (list-ref plans s)))))))
        0.0 (iota (length scopes))))

(define (relative-bound scopes)
  (call-with-values (lambda () (solve-decomposed scopes #:accel #t #:iters 600))
    (lambda (plans met rounds pulls)
      (let ((f (objective-of scopes plans))
            (b (assq-ref (certificate-of-last-solve) 'gap-bound)))
        (list (if (> f 0) (/ b f) +inf.0) f b met)))))

(let ((star  (relative-bound (fx-star 16)))
      (chain (relative-bound (fx-chain 16))))
  (format #t "  star  S=16: |f| ~,3e  certified ≤ ~,3e  = ~,2f% of |f|\n"
          (cadr star) (caddr star) (* 100.0 (car star)))
  (format #t "  chain S=16: |f| ~,3e  certified ≤ ~,3e  = ~,2f% of |f|\n"
          (cadr chain) (caddr chain) (* 100.0 (car chain)))
  ;; On a LOW-DIAMETER cover the bound is worth something and must stay so.
  (check "on a star the certificate is meaningful (< 10% of the objective)"
         (< (car star) 0.10))
  ;; This is the one that changed. A 16-scope chain used to certify to 65% of its
  ;; own objective and now certifies to ~15%.
  ;;
  ;; The remaining distance from the star is partly the QUANTIFIER, and that trade
  ;; is worth being explicit about: capping the boundary columns at this plan's own
  ;; crossings gives 9%, and the coupling-graph caps give 15%. The second is looser
  ;; because it quantifies over more plans, and it is the one reported, because a
  ;; bound whose x* is drawn from a set chosen by the plan being certified is not
  ;; the claim a reader takes from the words "certified within".
  (check "and NOW so is the chain, within a factor — 65% of |f| before the radius existed"
         (< (car chain) 0.20))
  ;; On a chain it is NOT, and the test says so rather than quietly passing.
  ;; This is the honest state, not an aspiration: a 16-scope chain certifies to
  ;; ~65% of its own objective, and a 32-scope chain to many multiples of it.
  ;; Federated near-optimality is provable on a well-cut cover and NOT on a
  ;; badly-cut one — which is the same conclusion the round counts reach, arrived
  ;; at independently through the certificate.
  (check "the star is still the tighter cover"
         (< (car star) (car chain)))
  ;; meanfill is min(1, delivered/demanded) averaged, so 100 is its DEFINITIONAL
  ;; cap, not a tuned target — "essentially all demand" is "within a percent of
  ;; the cap", which is what is written.
  (check "both plans still meet essentially all demand — the difference is PROOF"
         (and (> (list-ref star 3)  (- meanfill-cap 1.0))
              (> (list-ref chain 3) (- meanfill-cap 1.0)))))

(check-done "  The federation reports what it can prove, and says what it cannot.~%")
