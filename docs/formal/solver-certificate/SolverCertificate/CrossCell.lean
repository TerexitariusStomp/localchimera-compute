-- SPDX-License-Identifier: AGPL-3.0-or-later
import Mathlib.Data.Real.Basic
import Mathlib.Order.MinMax
import Mathlib.Algebra.Order.BigOperators.Group.Finset
import Mathlib.Tactic.Linarith

/-!
# Across cells: misreporting any ask is weakly dominated
(docs/planning/quantity-as-a-cap.md, the cross-cell seam)

`QuantityAsCap.lean` settles one cell. Here the agent holds want terms in
MANY cells (`P : Finset ι`, one term per (citizen, cell) row of a solve),
the cells share ONE endogenous supply `S`, and the engine's water-filling
shape is abstracted to exactly what it is: a scarcity scalar `μ` — an
ARBITRARY function of the whole report vector, which is where production
endogeneity lives — and per-term level maps `Λ k`, each antitone in μ (the
voice-tilted water level; the weight is inside `Λ`). A term is served
`min (q k) (Λ k (μ q))`: the ask enters only as its own wall.

`cross_cell_truth_dominant`: an agent who misreports any subset of their own
asks — padding, shading, decoy rows (a term with true peak 0), any mixture —
gets at most truth's utility, where utility is satiated per cell and
additive across cells (free disposal, no resale). Two hypotheses about the
rule carry the whole theorem:

* `hfeas` — feasibility AT THE DEVIATION: the rule never hands out more
  than the supply;
* `hnw` — no waste AT TRUTH: either supply binds, or every term is served
  its whole ask. This is the water-filling optimum's dichotomy for a pull
  that never satiates (φ′ < 0 everywhere — `cap`'s w/(1+s/c) qualifies):
  with slack supply nothing but the walls can bind.

Notably ABSENT: any monotonicity of μ in the reports, any structure on μ at
all, nonnegativity of peaks or reports, and (in the levels-fell case) even
the two hypotheses above — if the deviation raises scarcity, every own term
is pointwise below its truthful allocation, unconditionally.

Honest scope: one shared supply. Several supplies with production trading
between them is the next widening, not covered here.
-/

namespace SolverCertificate
namespace CrossCell

variable {ι : Type*} [Fintype ι] [DecidableEq ι]

/-- What a term is served: its own ask, capped by its water level at the
scarcity the full report vector produces. -/
noncomputable def alloc (Λ : ι → ℝ → ℝ) (μ : (ι → ℝ) → ℝ) (q : ι → ℝ) (k : ι) : ℝ :=
  min (q k) (Λ k (μ q))

/-- The agent's utility over their terms `P`, at true peaks `t`, when the
report vector is `q`: satiated per cell, additive across cells. -/
noncomputable def u (Λ : ι → ℝ → ℝ) (μ : (ι → ℝ) → ℝ) (P : Finset ι) (t q : ι → ℝ) : ℝ :=
  ∑ k ∈ P, min (alloc Λ μ q k) (t k)

/-- Misreporting any of one's own asks, in any cells, is weakly dominated. -/
theorem cross_cell_truth_dominant
    (Λ : ι → ℝ → ℝ) (μ : (ι → ℝ) → ℝ) (S : ℝ) (P : Finset ι) (t q : ι → ℝ)
    (hΛ : ∀ k, Antitone (Λ k))
    (hdev : ∀ k ∉ P, q k = t k)
    (hfeas : ∑ k, alloc Λ μ q k ≤ S)
    (hnw : (∑ k, alloc Λ μ t k = S) ∨ (∀ k, alloc Λ μ t k = t k)) :
    u Λ μ P t q ≤ u Λ μ P t t := by
  simp only [u, alloc] at hfeas hnw ⊢
  -- at truth an own term's utility IS its allocation (allocation ≤ peak)
  have hR : ∀ k : ι, min (min (t k) (Λ k (μ t))) (t k) = min (t k) (Λ k (μ t)) :=
    fun k => min_eq_left (min_le_left _ _)
  simp only [hR]
  rcases le_total (μ t) (μ q) with hmu | hmu
  · -- scarcity rose (levels fell): every own term sits below its truthful
    -- allocation pointwise — no supply accounting needed at all
    refine Finset.sum_le_sum fun k _ => ?_
    calc min (min (q k) (Λ k (μ q))) (t k)
        ≤ min (Λ k (μ q)) (t k) := min_le_min (min_le_right _ _) le_rfl
      _ ≤ min (Λ k (μ t)) (t k) := min_le_min (hΛ k hmu) le_rfl
      _ = min (t k) (Λ k (μ t)) := min_comm _ _
  · -- scarcity fell (levels rose): the others are served at least their
    -- truthful allocations, so what is left inside the supply for the
    -- agent is at most what truth handed them
    rcases hnw with hS | hall
    · have hsum_q := Finset.sum_add_sum_compl P (fun k => min (q k) (Λ k (μ q)))
      have hsum_t := Finset.sum_add_sum_compl P (fun k => min (t k) (Λ k (μ t)))
      have hcompl : ∑ k ∈ Pᶜ, min (t k) (Λ k (μ t)) ≤ ∑ k ∈ Pᶜ, min (q k) (Λ k (μ q)) := by
        refine Finset.sum_le_sum fun k hk => ?_
        rw [hdev k (Finset.mem_compl.mp hk)]
        exact min_le_min le_rfl (hΛ k hmu)
      have hle : ∑ k ∈ P, min (min (q k) (Λ k (μ q))) (t k)
          ≤ ∑ k ∈ P, min (q k) (Λ k (μ q)) :=
        Finset.sum_le_sum fun k _ => min_le_left _ _
      linarith
    · -- truth serves everyone whole: truth's utility is the ceiling
      refine Finset.sum_le_sum fun k _ => ?_
      rw [hall k]
      exact min_le_right _ _

end CrossCell
end SolverCertificate
