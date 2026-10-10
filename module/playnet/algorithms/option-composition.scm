;;; option-composition.scm — the option is WHICH RECIPES compose the plan.
;;;
;;; A leverage layer is NOT a constraint on "the plan" — it is a property of
;;; the recipes the plan is composed from. Withholding something a
;;; counterparty needs is a recipe set (withhold/maintain) plus a leverage
;;; STOCK; ordinary provisioning is other recipes. The convex planner already
;;; composes a plan from whatever recipe set a scope's recipe-store holds
;;; (plan-scope → gather-recipes). So different recipe sets are different
;;; plans with different premiums — and the premium is READ OFF each composed
;;; plan, never optimised (optimising premium ∝ V² would reward contested,
;;; unstable plans).
;;;
;;;   compose : a scope's recipe-store ∪ its leverage-pool stock
;;;   solve   : plan-scope meets needs from that set (the pool pays for repairs)
;;;   read off: B = the withheld leverage (the leverage pool / at-stake good)
;;;             → the concession the counterparty pays to defer it, the
;;;             leverage ρ-bound
;;;   wire    : feed the concession into the rollover Proposal.reciprocal
;;;
;;; PARTICIPATION is the variable that makes leverage real, and it is just the
;;; leverage-pool STOCK (the withheld good actually on hand). It needs no
;;; recipe add/remove and no eco-cap: usd is a seeded stock bounded by the
;;; pool, so coverage=0 ⇒ empty pool ⇒ no repair, and the recipe set is
;;; unchanged. coverage drives BOTH the capacity (how much can be withheld)
;;; and the credibility floor B(1−R) ≥ C of the bound.
;;;
;;; The concession is compute-attributed-premium's extractable bound; the
;;; rollover seam is Proposal.reciprocal. Loaded in the (playnet planner)
;;; umbrella after option-premium.scm (it needs only compute-attributed-premium + the VF
;;; record accessors).
;;;
;;; This module prices leverage generically — a holdout/bargaining-power
;;; model (the standard economics of withholding cooperation: Nash
;;; bargaining, strike-pay theory, holdout problems in contract theory), not
;;; a scenario-specific calculator. What demands, if any, a caller funds from
;;; the resulting concession is out of scope here: see reform.scm for the
;;; project's own (categorical, not scored) treatment of legal/political
;;; demands — it supersedes an earlier scored-ranking approach that tried to
;;; treat incommensurable demands as a common-unit knapsack and was retired
;;; for exactly that reason.

;;; ─── read off a composed plan ─────────────────────────────────────────────
;;; plan-scope/plan->material return <commitment> records; sum the produced or
;;; consumed quantity of one spec across the plan.
(define-module (playnet algorithms option-composition)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet algorithms option-premium)
  #:export (produced-of consumed-of concession-value price-leverage
            rollover-reciprocal-intent))

(define (produced-of material spec) (committed-quantity material spec creating-actions))
(define (consumed-of material spec) (committed-quantity material spec using-up-actions))

;;; ─── price the leverage a composition creates (the core; B-taking) ────────
;;; B is the leverage withheld — what the counterparty stands to lose (the
;;; leverage pool / the withheld good). The concession they pay to defer
;;; exercise is the extractable bound:  ≈ ρ²·N(1−R) + B(1−R) − C,
;;; credible ⇔ B(1−R)≥C.
;;; coverage (participation) drives the credibility floor: C = B·(1−coverage).
;;; rho is attribution (≈1 for a single counterparty; <1 for an index play).
(define* (concession-value B #:key (R 0.40) (rho 1.0) (coverage 1.0) (N 0))
  (let* ((C (* B (- 1.0 coverage)))
         (attr (compute-attributed-premium #:B B #:R R #:C C #:rho rho #:N N)))
    (list (cons 'leverage B)
          (cons 'coverage coverage)
          (cons 'credible (assq-ref attr 'credible?))
          (cons 'concession (assq-ref attr 'extractable))
          (cons 'bondholder-term (assq-ref attr 'bondholder-term))
          (cons 'derivative-term (assq-ref attr 'derivative-term)))))

;;; convenience: read B off the plan's PRODUCED at-stake good (the
;;; recipe-withholds-into-a-pool style, where a withhold recipe produces the
;;; pool). For a style where the pool is a SEEDED stock instead, pass B to
;;; concession-value directly.
(define* (price-leverage material
                         #:key (at-stake-spec "spec-usd") (R 0.40)
                               (rho 1.0) (coverage 1.0) (N 0))
  (concession-value (produced-of material at-stake-spec)
                    #:R R #:rho rho #:coverage coverage #:N N))

;;; ─── feed the read-off concession into the rollover Proposal.reciprocal ───
;;; The `reciprocal` of a rollover Proposal IS the premium. This turns a
;;; read-off (concession-value's alist) into the
;;; reciprocal Intent carrying that premium — the counterparty's request to pay
;;; to defer exercise. The provider is left unbound (the counterparty), the
;;; receiver is the commons collecting the premium. `^rollover-scheduler` is the
;;; CADENCE on top: on each tick it re-prices (ρ from a covariance-view) and its
;;; on-tick refreshes this Intent's quantity — see test-rollover-pricing.scm.
(define* (rollover-reciprocal-intent read-off
                                     #:key (id "i-rollover-premium")
                                           (premium-spec "spec-usd")
                                           (receiver "agent-commons")
                                           (plan "plan-rollover"))
  (make-intent #:id id #:action 'transfer
               #:name "Rollover premium — read off the composed plan" #:resource-conforms-to premium-spec
               #:resource-quantity (make-measure (assq-ref read-off 'concession) "usd") #:receiver receiver #:planned-within plan))
