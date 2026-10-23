-- SPDX-License-Identifier: AGPL-3.0-or-later
import Mathlib.Analysis.InnerProductSpace.Basic
import Mathlib.Analysis.InnerProductSpace.PiL2

/-!
# The suboptimality bound (solver.scm §3, lines 616–626)

This is the master theorem behind every certificate `kkt-report` publishes:

    f(x) − f(x*) ≤ yᵀs(x) + ‖r‖·‖x − x*‖

for any feasible `x`, any dual `y ≥ 0`, and `r = ∇f(x) − Aᵀy`.

Design choice: rather than deriving the first-order subgradient inequality
`f(x') ≥ f(x) + ⟨∇f(x), x' - x⟩` from `ConvexOn` + `fderiv` (which pulls in a
larger slice of Mathlib's calculus API and its own side conditions), we take
it as an explicit hypothesis, `subgrad`. This matches what `solver.scm`
itself does — `csr-grad` computes ∇f directly, there is no separate proof
that the constructed vector is a genuine derivative — so the Lean statement
and the Scheme implementation share the same primitive. Anyone later wanting
to derive `subgrad` from `ConvexOn` gets a strictly stronger corollary for
free; nothing here depends on that derivation existing.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n m : ℕ}

abbrev Vec (n : ℕ) := EuclideanSpace ℝ (Fin n)

/-- The affine slack map `s(x) = c + A·x`, one row `i` at a time. -/
def slack (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (x : Vec n) (i : Fin m) : ℝ :=
  c i + ∑ j, A i j * x j

/-- `Aᵀ·y` as a vector in `ℝⁿ`. -/
def transposeMulVec (A : Matrix (Fin m) (Fin n) ℝ) (y : Fin m → ℝ) (j : Fin n) : ℝ :=
  ∑ i, A i j * y i

/-- **The adjoint identity.** `⟪Aᵀy, x − x'⟫ = Σᵢ yᵢ·(s(x)ᵢ − s(x')ᵢ)`: pairing
the dual against a difference of points is the same as pairing it against the
difference of their slacks. The `c i` constants cancel inside the difference,
so only the `A·x` parts survive; `Finset.sum_comm` is the swap of the `i` (row)
and `j` (column) summations.

This is the one step where `y` meets the geometry, and it is shared verbatim by
every bound in the development — the geometry branch here and the curvature
branch in `DistCurvature.lean` — so it is stated once rather than inlined into
each. -/
theorem inner_transposeMulVec_sub (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (y : Fin m → ℝ) (x x' : Vec n) :
    (inner (𝕜 := ℝ)
      ((EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j)) (x - x')) =
      ∑ i, y i * (slack A c x i - slack A c x' i) := by
  rw [PiLp.inner_apply]
  simp [RCLike.inner_apply, transposeMulVec, slack, Finset.mul_sum, ← Finset.sum_sub_distrib]
  rw [Finset.sum_comm]
  exact Finset.sum_congr rfl fun _ _ => Finset.sum_congr rfl fun _ _ => by ring

/-- **The certified suboptimality bound.**

Hypotheses:
* `subgrad` — the first-order inequality at `x`, for *every* candidate `x'`
  (this is what "f convex and differentiable at x" buys you).
* `hy` — dual feasibility, `y ≥ 0` pointwise.
* `hr` — `r` is exactly `∇f(x) − Aᵀy`, built from *this* `A`, `c` (see
  `WorldMethodSeparation.lean` for why "this A, c" is load-bearing).

Conclusion: for every feasible `x'`, `f(x) − f(x') ≤ yᵀs(x) + ‖r‖·‖x − x'‖`.

Note: `x` itself need not be feasible under `s` — checked via
`lean_minimal_hypotheses`, confirmed by the proof: every step below reads
`slack A c x i` as a plain real number (the `yᵀs(x)` term), never asks that
it be `≥ 0`. Only `x'`'s feasibility (`hx'feas`, introduced in the proof) is
load-bearing, via `step4`. `kkt-report` (solver.scm:1178) computes
`bar-slacks-feasible?` and folds it into the *reported* `feasible?` verdict,
but that check is doing something the certificate's *bound* itself never
required — it protects the human reading `certificate-summary` from an
infeasible `x` being presented as a plan, not the arithmetic of the bound.
-/
theorem suboptimality_bound
    (f : Vec n → ℝ) (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (grad : Vec n) (y : Fin m → ℝ) (r : Vec n)
    (subgrad : ∀ x' : Vec n, f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)))
    (hy : ∀ i, 0 ≤ y i)
    (hr : r = grad - (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j)) :
    ∀ x' : Vec n, (∀ i, 0 ≤ slack A c x' i) →
      f x - f x' ≤ (∑ i, y i * slack A c x i) + ‖r‖ * ‖x - x'‖ := by
  intro x' hx'feas
  -- Step 1 (convexity): f(x) - f(x') ≤ ⟪grad, x - x'⟫.
  have step1 : f x - f x' ≤ (inner (𝕜 := ℝ) grad (x - x')) := by
    have h := subgrad x'
    rw [show x' - x = -(x - x') by abel, inner_neg_right] at h
    linarith
  -- Step 3 (adjoint identity): ⟪Aᵀy, x-x'⟫ = Σᵢ yᵢ·(A(x-x'))ᵢ = Σᵢ yᵢ·(s(x)ᵢ - s(x')ᵢ).
  have key := inner_transposeMulVec_sub A c y x x'
  -- Step 2 (substitute r = grad - Aᵀy): ⟪grad, x-x'⟫ = ⟪r, x-x'⟫ + ⟪Aᵀy, x-x'⟫.
  have step2 : (inner (𝕜 := ℝ) grad (x - x')) =
      (inner (𝕜 := ℝ) r (x - x')) + ∑ i, y i * (slack A c x i - slack A c x' i) := by
    have hgrad : grad =
        r + (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j) := by
      rw [hr]; abel
    rw [hgrad, inner_add_left, key]
  -- Step 4 (y ≥ 0, s(x') ≥ 0): Σᵢ yᵢ·(s(x)ᵢ - s(x')ᵢ) ≤ Σᵢ yᵢ·s(x)ᵢ.
  have step4 : ∑ i, y i * (slack A c x i - slack A c x' i) ≤ ∑ i, y i * slack A c x i :=
    Finset.sum_le_sum fun i _ =>
      mul_le_mul_of_nonneg_left (by linarith [hx'feas i]) (hy i)
  -- Step 5 (Cauchy–Schwarz): ⟪r, x-x'⟫ ≤ ‖r‖·‖x-x'‖.
  have step5 : (inner (𝕜 := ℝ) r (x - x')) ≤ ‖r‖ * ‖x - x'‖ := real_inner_le_norm r (x - x')
  linarith

end SolverCertificate
