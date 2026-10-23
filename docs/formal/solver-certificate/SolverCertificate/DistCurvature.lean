-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.SuboptimalityBound

/-!
# The curvature branch of the gap bound (solver.scm §3, `dist-curvature`)

`kkt-report` publishes two distance-flavored bounds and takes the better:
`dist-geometry = ‖r‖·D` (needs a feasible box) and `dist-curvature =
‖r‖²/(2σ)` (needs no geometry at all, only the curvature modulus σ from
`strong-convexity-modulus`). The geometry branch is already covered by
`suboptimality_bound` (its `‖r‖·‖x−x'‖` term, with `D ≥ ‖x−x'‖` supplied by
the box). This file certifies the curvature branch: strengthen the
first-order hypothesis to σ-strong convexity and the `‖r‖·‖x−x'‖` term
collapses to `‖r‖²/(2σ)` — uniformly in `x'`, which is the whole point: no
knowledge of where `x*` lives is needed.

The inner inequality is the Polyak–Łojasiewicz step: for any `b ≥ 0`,
`‖r‖·b − (σ/2)·b² ≤ ‖r‖²/(2σ)`, i.e. `0 ≤ (‖r‖ − σ·b)²`.

`sconv` is stated the way `subgrad` is in `suboptimality_bound` — as the
inequality strong convexity *buys* at `x`, not as `StrongConvexOn` — so the
Lean statement and `strong-convexity-modulus`'s output share one primitive:
`StrongConvexityModulus.lean` certifies the quadratic-form lower bound that
makes `sconv` true of the solver's objective with `σ = min_j d_j`.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- **The curvature gap bound.** Under σ-strong convexity at `x` (hypothesis
`sconv`), dual feasibility `y ≥ 0`, and `r = ∇f(x) − Aᵀy`, every feasible
`x'` satisfies `f(x) − f(x') ≤ yᵀs(x) + ‖r‖²/(2σ)` — the `dist-curvature`
line of the certificate, with no geometry hypothesis anywhere. -/
theorem suboptimality_bound_curvature
    (f : Vec n → ℝ) (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (grad : Vec n) (y : Fin m → ℝ) (r : Vec n)
    (σ : ℝ) (hσ : 0 < σ)
    (sconv : ∀ x' : Vec n,
      f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)) + σ / 2 * ‖x' - x‖ ^ 2)
    (hy : ∀ i, 0 ≤ y i)
    (hr : r = grad - (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j)) :
    ∀ x' : Vec n, (∀ i, 0 ≤ slack A c x' i) →
      f x - f x' ≤ (∑ i, y i * slack A c x i) + ‖r‖ ^ 2 / (2 * σ) := by
  intro x' hx'feas
  -- Step 1 (strong convexity): f(x) - f(x') ≤ ⟪grad, x - x'⟫ - σ/2·‖x - x'‖².
  have step1 : f x - f x' ≤ (inner (𝕜 := ℝ) grad (x - x')) - σ / 2 * ‖x - x'‖ ^ 2 := by
    have h := sconv x'
    have hin : (inner (𝕜 := ℝ) grad (x' - x)) = -(inner (𝕜 := ℝ) grad (x - x')) := by
      rw [show x' - x = -(x - x') by abel, inner_neg_right]
    have hnorm : ‖x' - x‖ = ‖x - x'‖ := norm_sub_rev _ _
    rw [hin, hnorm] at h
    linarith
  -- Step 3 (adjoint identity), the shared lemma from `SuboptimalityBound.lean`.
  have key := inner_transposeMulVec_sub A c y x x'
  -- Step 2 (substitute r = grad - Aᵀy).
  have step2 : (inner (𝕜 := ℝ) grad (x - x')) =
      (inner (𝕜 := ℝ) r (x - x')) + ∑ i, y i * (slack A c x i - slack A c x' i) := by
    have hgrad : grad =
        r + (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j) := by
      rw [hr]; abel
    rw [hgrad, inner_add_left, key]
  -- Step 4 (y ≥ 0, s(x') ≥ 0).
  have step4 : ∑ i, y i * (slack A c x i - slack A c x' i) ≤ ∑ i, y i * slack A c x i :=
    Finset.sum_le_sum fun i _ =>
      mul_le_mul_of_nonneg_left (by linarith [hx'feas i]) (hy i)
  -- Step 5 (Cauchy–Schwarz).
  have step5 : (inner (𝕜 := ℝ) r (x - x')) ≤ ‖r‖ * ‖x - x'‖ := real_inner_le_norm r (x - x')
  -- Step 6 (Polyak–Łojasiewicz): ‖r‖·b - σ/2·b² ≤ ‖r‖²/(2σ), i.e. 0 ≤ (‖r‖ - σ·b)².
  have step6 : ‖r‖ * ‖x - x'‖ - σ / 2 * ‖x - x'‖ ^ 2 ≤ ‖r‖ ^ 2 / (2 * σ) := by
    rw [le_div_iff₀ (by positivity)]
    nlinarith [sq_nonneg (‖r‖ - σ * ‖x - x'‖), hσ, norm_nonneg r, norm_nonneg (x - x')]
  linarith

end SolverCertificate
