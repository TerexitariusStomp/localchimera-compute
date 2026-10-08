import SolverCertificate.CrossCell
import Mathlib.Algebra.BigOperators.Fin
import Mathlib.Tactic.FinCases
import Mathlib.Tactic.NormNum

/-!
# Multi-supply: what widens, what breaks, and what truth still buys
(docs/planning/quantity-as-a-cap.md — the "next widening")

`cross_cell_truth_dominant` covers every cell drawing on ONE shared supply.
This file settles the widening to several supplies with production trading
between them, and the answer has two halves:

* **The naive widening is FALSE** (`shading_pays`): with heterogeneous
  conversion rates and utilities counted in physical units, understating a
  want you truly hold can free inputs that convert into MORE units of
  another good you want — a concrete two-good instance where shading
  strictly gains. The wedge is between the objective's pull and
  physical-unit utilities across goods; no level rule closes it.
* **Value-dominance is TRUE** (`multi_supply_value_dominant`): measured at
  the technology's own pulls, no rewrite of one's asks can obtain a bundle
  worth more — the one-supply theorem, transported along the pull
  rescaling. A lie can only slide the citizen's bundle along the plan's
  isovalue surface, never climb it.

So the honest reading for the engine: within-good and one-supply honesty is
exact; ACROSS goods with real technology, lying is value-neutral at best —
the residue is a self-financed swap of one's own bundle, the same family as
pad-and-gift (value-conserved, visible in the plan, and diluted at scale:
the freed input's yield is shared among every rationed claimant of the
target good, so the physical gain vanishes like the crowd grows).
-/

namespace SolverCertificate
namespace MultiSupply
open CrossCell

/-! ### The counterexample: physical-unit truth-dominance fails -/

/-- Two goods, one unit of input; good 1 converts at rate 10. The "walls +
efficient conversion" rule the naive widening would run: serve the good-0
ask from the input, convert the remainder. -/
noncomputable def naiveRule (q : Fin 2 → ℝ) : Fin 2 → ℝ :=
  fun k => if k = 0 then min (q 0) 1 else min (q 1) (10 * (1 - min (q 0) 1))

theorem naiveRule_capped (q : Fin 2 → ℝ) (k : Fin 2) : naiveRule q k ≤ q k := by
  fin_cases k <;> simp [naiveRule]

/-- True peaks (1, 10). Truth is served (1, 0): utility 1. Shading the
good-0 ask to 0 — denying a want genuinely held — is served (0, 10):
utility 10. Understatement strictly pays; the one-supply theorem cannot
widen to heterogeneous conversion in physical units. -/
theorem shading_pays :
    (∑ k, min (naiveRule (fun j => if j = 0 then (1 : ℝ) else 10) k)
              ((fun j => if j = 0 then (1 : ℝ) else 10) k))
      < (∑ k, min (naiveRule (fun j => if j = 0 then (0 : ℝ) else 10) k)
                  ((fun j => if j = 0 then (1 : ℝ) else 10) k)) := by
  norm_num [Fin.sum_univ_two, naiveRule, min_def]

/-! ### The theorem that survives: value-dominance -/

private theorem mul_min_of_nonneg' {c a b : ℝ} (hc : 0 ≤ c) :
    min (c * a) (c * b) = c * min a b := by
  rcases le_total a b with h | h
  · rw [min_eq_left (mul_le_mul_of_nonneg_left h hc), min_eq_left h]
  · rw [min_eq_right (mul_le_mul_of_nonneg_left h hc), min_eq_right h]

/-- No rewrite of one's own asks obtains a bundle worth more at the
technology's pulls `p`: the one-supply theorem transported along the
rescaling `s ↦ p·s`. Value feasibility at the deviation, value no-waste at
truth — the same per-solve obligations, in the numéraire the technology
conserves. -/
theorem multi_supply_value_dominant {ι : Type*} [Fintype ι] [DecidableEq ι]
    (Λ : ι → ℝ → ℝ) (μ : (ι → ℝ) → ℝ) (p : ι → ℝ) (S : ℝ) (P : Finset ι) (t q : ι → ℝ)
    (hp : ∀ k, 0 < p k)
    (hΛ : ∀ k, Antitone (Λ k))
    (hdev : ∀ k ∉ P, q k = t k)
    (hfeas : ∑ k, p k * alloc Λ μ q k ≤ S)
    (hnw : (∑ k, p k * alloc Λ μ t k = S) ∨ (∀ k, alloc Λ μ t k = t k)) :
    ∑ k ∈ P, p k * min (alloc Λ μ q k) (t k)
      ≤ ∑ k ∈ P, p k * min (alloc Λ μ t k) (t k) := by
  -- the value-unit system: reports, peaks and levels all scaled by p
  set Λ' : ι → ℝ → ℝ := fun k m => p k * Λ k m with hΛ'def
  set μ' : (ι → ℝ) → ℝ := fun r => μ (fun k => r k / p k) with hμ'def
  set t' : ι → ℝ := fun k => p k * t k with ht'def
  set q' : ι → ℝ := fun k => p k * q k with hq'def
  have hback : ∀ r : ι → ℝ, μ' (fun k => p k * r k) = μ r := by
    intro r; simp only [hμ'def]
    congr 1; funext k
    exact mul_div_cancel_left₀ (r k) (hp k).ne'
  have hallocEq : ∀ (r : ι → ℝ) k,
      alloc Λ' μ' (fun j => p j * r j) k = p k * alloc Λ μ r k := by
    intro r k
    simp only [alloc, hΛ'def, hback r]
    exact mul_min_of_nonneg' (hp k).le
  have h := cross_cell_truth_dominant Λ' μ' S P t' q'
    (fun k => (hΛ k).const_mul (hp k).le)
    (fun k hk => by simp only [hq'def, ht'def, hdev k hk])
    (by simpa only [hq'def, hallocEq q] using hfeas)
    (by rcases hnw with h | h
        · exact Or.inl (by simpa only [ht'def, hallocEq t] using h)
        · exact Or.inr fun k => by simp only [ht'def, hallocEq t, h k])
  simpa only [u, hq'def, ht'def, hallocEq q, hallocEq t,
              mul_min_of_nonneg' (hp _).le] using h

end MultiSupply
end SolverCertificate
