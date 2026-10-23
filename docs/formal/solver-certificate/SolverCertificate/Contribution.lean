-- SPDX-License-Identifier: AGPL-3.0-or-later
import Mathlib.Data.Real.Basic
import Mathlib.Order.Bounds.Basic
import Mathlib.Data.Set.Image
import Mathlib.Tactic.Linarith

/-!
# The supply side: contribution is weakly dominant, and free-riding has a price
(docs/planning/truth-telling.md §supply; temporary socialization —
custody ACDC, `plan-scope`'s means pool)

The demand side needed geometry because a want is unverifiable; the supply
side needs only this file's arithmetic, because a contribution moves the
*constraint set*, never the contributor's private return. The planner pays
nothing for contributed capacity — custody never vests, voice comes from
witnessed hours, duals are not incomes — so the one question left is what a
self-interested holder loses by handing an oven to the pool. The answers:

* `enlarge_of_ceiling` — the engine's wall shape: raising a capacity
  ceiling is a superset of feasible plans. The model's one axiom
  (`Feasible keep ⊆ Feasible give`), proved for the constraint form the
  solver actually carries.
* `PlanEnv.welfare_mono` — a larger feasible set weakly raises the
  optimum: planned welfare is monotone under contribution.
* `no_stakeholder_harmed` — every agent holding a nonnegative stake in
  planned welfare weakly gains from anyone's contribution: contribution
  is a Pareto move on stakes.
* `contribute_dominant` / `contribute_weakly_dominant` — a holder whose
  payoff is a nonnegative stake in welfare plus the private use-value of
  the capacity as they hold it weakly prefers contributing whenever
  handing over custody forgoes nothing (`vKeep ≤ vGive` — revocable
  custody, bounded draw, free exit make this the design's target), and
  this holds against *every* profile of the others' contributions: weak
  dominance in the game, not merely a best reply.
* `freeride_iff` — the exact threshold: withholding strictly pays iff the
  private use-value forgone exceeds the holder's stake in the welfare
  gain. Free-riding bites exactly when the price of generosity exceeds
  the holder's share of the harmony gain — so the design's lever is to
  shrink that price (revocable custody), never to pay for contribution,
  which would re-open the private-return channel the demand-side results
  need closed.
-/

namespace SolverCertificate
namespace Contribution

/-! ### Welfare over a feasible set -/

/-- A planning environment: contribution profiles select feasible sets,
the objective scores plans, and `W` is planned welfare — a least upper
bound of the objective over what the profile makes possible. -/
structure PlanEnv (Profile X : Type*) where
  Feasible : Profile → Set X
  obj : X → ℝ
  W : Profile → ℝ
  hW : ∀ c, IsLUB (obj '' Feasible c) (W c)

variable {Profile X : Type*}

/-- More capacity, more plans, weakly more welfare: enlarging the feasible
set weakly raises its optimum. -/
theorem PlanEnv.welfare_mono (E : PlanEnv Profile X) {c c' : Profile}
    (h : E.Feasible c ⊆ E.Feasible c') : E.W c ≤ E.W c' :=
  (E.hW c).2 fun _ hx => (E.hW c').1 (Set.image_mono h hx)

/-- The engine's wall shape grounds the enlargement axiom: a capacity
constraint is `g x ≤ c`, and raising the ceiling is a superset. -/
theorem enlarge_of_ceiling (g : X → ℝ) {c c' : ℝ} (h : c ≤ c') :
    {x | g x ≤ c} ⊆ {x | g x ≤ c'} :=
  fun _ hx => le_trans hx h

/-! ### The holder's decision -/

/-- A holder's payoff: a stake `α` in planned welfare plus the private
use-value `v` of the capacity as they hold it. -/
def payoff (α w v : ℝ) : ℝ := α * w + v

/-- Contribution is a Pareto move on stakes: every agent holding a
nonnegative stake in planned welfare weakly gains from anyone's
contribution. -/
theorem no_stakeholder_harmed (E : PlanEnv Profile X) {keep give : Profile}
    (henl : E.Feasible keep ⊆ E.Feasible give) {α : ℝ} (hα : 0 ≤ α) :
    α * E.W keep ≤ α * E.W give :=
  mul_le_mul_of_nonneg_left (E.welfare_mono henl) hα

/-- The theorem: contributing capacity weakly enlarges the feasible set,
so it weakly raises the optimum — and a holder with a nonnegative stake in
social satisfaction who forgoes nothing by handing over custody
(`vKeep ≤ vGive`) weakly prefers to contribute. -/
theorem contribute_dominant (E : PlanEnv Profile X) {keep give : Profile}
    (henl : E.Feasible keep ⊆ E.Feasible give)
    {α vGive vKeep : ℝ} (hα : 0 ≤ α) (hv : vKeep ≤ vGive) :
    payoff α (E.W keep) vKeep ≤ payoff α (E.W give) vGive :=
  add_le_add (no_stakeholder_harmed E henl hα) hv

/-- Weak dominance in the game: against *every* profile of the others'
contributions (`Rest` indexes them; `keep r`/`give r` are the full
profiles with the holder withholding or contributing), contributing weakly
beats withholding. The holder needs no forecast of anyone else. -/
theorem contribute_weakly_dominant {Rest : Type*} (E : PlanEnv Profile X)
    (keep give : Rest → Profile)
    (henl : ∀ r, E.Feasible (keep r) ⊆ E.Feasible (give r))
    {α vGive vKeep : ℝ} (hα : 0 ≤ α) (hv : vKeep ≤ vGive) :
    ∀ r, payoff α (E.W (keep r)) vKeep ≤ payoff α (E.W (give r)) vGive :=
  fun r => contribute_dominant E (henl r) hα hv

/-- The exact threshold: withholding strictly pays iff the private
use-value forgone exceeds the holder's stake in the welfare gain. The
design's lever is the right-hand side's `vKeep - vGive` — the price of
generosity — which revocable custody drives toward zero. -/
theorem freeride_iff (α wGive wKeep vGive vKeep : ℝ) :
    payoff α wGive vGive < payoff α wKeep vKeep ↔
      α * (wGive - wKeep) < vKeep - vGive := by
  unfold payoff
  constructor <;> intro h <;> nlinarith

/-! ### Rigor audit (2026-09): two hypotheses the reading must not overrun

`no_stakeholder_harmed` and `contribute_dominant` are stated exactly as
strong as their hypotheses make them, and no stronger: `α ≥ 0` buys a
share of the AGGREGATE reading `W`, never a claim about any person's own
realized bundle, and `henl` (the feasible-set enlargement) is a genuine
hypothesis to discharge at the custody ceremony, never a free consequence
of "more capacity exists." Two witnesses below make both limits precise
rather than assumed. -/

/-- **Aggregate welfare rising does not imply a stakeholder's own utility
rises.** A minimal witness: the plan optimises `x` itself (`W c` is the
LUB of `id` over `[0, c⁺]`), so enlarging capacity from `1` to `2` genuinely
raises `W`, the aggregate `no_stakeholder_harmed` covers — but a person
whose own payoff moves the OPPOSITE way with the very quantity the plan
is now producing more of (occupying no `α ≥ 0` stake in `W` at all) is
made strictly worse off by the same contribution. `no_stakeholder_harmed`
is exactly as narrow as its `0 ≤ α` hypothesis says: a stake in the
aggregate, not a person's own consumption. -/
theorem aggregate_gain_can_hide_individual_loss :
    ∃ (E : PlanEnv ℝ ℝ) (c c' : ℝ),
      E.Feasible c ⊆ E.Feasible c' ∧ E.W c < E.W c' ∧
      -- a bystander's own payoff over the realized optimum, the opposite sign of W
      -(E.W c') < -(E.W c) := by
  refine ⟨⟨fun c => Set.Icc 0 (max c 0), id, fun c => max c 0, fun c => ?_⟩, 1, 2, ?_, ?_, ?_⟩
  · simpa using isLUB_Icc (le_max_right c 0)
  · exact Set.Icc_subset_Icc le_rfl (by norm_num)
  · norm_num
  · norm_num

/-- Two profiles, `keep` and `give`: withholding leaves a 5-unit ceiling
untouched; contributing raises no ceiling at all but attaches a 2-unit
maintenance draw, leaving only 3. The custody ceremony must rule THIS out
— `henl` is exactly the promise that it does. -/
noncomputable def obligationEnv : PlanEnv Bool ℝ where
  Feasible := fun accept => if accept then Set.Icc 0 3 else Set.Icc 0 5
  obj := id
  W := fun accept => if accept then 3 else 5
  hW := fun accept => by
    cases accept
    · simpa using isLUB_Icc (by norm_num : (0:ℝ) ≤ 5)
    · simpa using isLUB_Icc (by norm_num : (0:ℝ) ≤ 3)

/-- **A ceiling that arrives with an obligation need not enlarge anything.**
`henl` — the hypothesis every dominance result above rests on — is a
design commitment (custody stays revocable, the draw stays bounded), not
an automatic fact about "more capacity." Accepting an asset that binds a
NEW constraint (a maintenance floor, an upkeep draw) can make the
contributed profile's feasible set a strict SUBSET of withholding's, and
then welfare strictly falls: `contribute_dominant` correctly does not fire
here, because its hypothesis does not hold here — exactly the case
`freeride_iff` prices as withholding paying. -/
theorem obligation_can_shrink_feasibility :
    ¬ (obligationEnv.Feasible false ⊆ obligationEnv.Feasible true) ∧
      obligationEnv.W true < obligationEnv.W false := by
  constructor
  · intro h
    have h4 : (4 : ℝ) ∈ obligationEnv.Feasible false := by
      simp only [obligationEnv]; norm_num
    have := h h4
    simp only [obligationEnv] at this
    norm_num at this
  · simp only [obligationEnv]; norm_num

end Contribution
end SolverCertificate
