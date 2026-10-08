import SolverCertificate.SuboptimalityBound
import Mathlib.Analysis.Convex.Deriv
import Mathlib.Analysis.Calculus.Gradient.Basic

/-!
# Deriving `subgrad` from `ConvexOn` + `HasGradientAt` (closes scope caveat #1)

`suboptimality_bound` takes the first-order subgradient inequality as an
explicit hypothesis rather than deriving it from `ConvexOn` + differentiability
(see the design-choice note at the top of `SuboptimalityBound.lean`). That
was a deliberate choice — it matches what `solver.scm` itself computes
(`csr-grad` directly, with no separate derivative proof) — but it means the
theorem is conditional on `subgrad` actually holding, unverified against a
genuine convex function.

This file closes that gap: `subgrad_of_convexOn` derives the inequality from
`ConvexOn` + `HasGradientAt`, and `suboptimality_bound_of_convexOn` wires it
into the master theorem, so a caller with a genuinely convex, differentiable
`f` gets the certified bound without ever stating `subgrad` by hand.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n m : ℕ}

/-- The first-order subgradient inequality, derived rather than assumed:
for `f` convex on all of `Vec n` with gradient `grad` at `x`,
`f(x') ≥ f(x) + ⟪grad, x' - x⟫` for every `x'`.

Proof strategy: restrict to the line segment `t ↦ x + t • (x' - x)`, apply
`ConvexOn.le_slope_of_hasDerivAt` to the resulting one-variable convex
function on `[0,1]`, and relate its derivative at `0` to `grad` via the
chain rule and `HasGradientAt`/`inner_gradient_left`. -/
theorem subgrad_of_convexOn
    (f : Vec n → ℝ) (x grad : Vec n)
    (hconv : ConvexOn ℝ Set.univ f) (hgrad : HasGradientAt f grad x) :
    ∀ x' : Vec n, f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)) := by
  intro x'
  -- The segment through `x` and `x'`, as an affine map `ℝ →ᵃ[ℝ] Vec n`.
  set L : ℝ →ᵃ[ℝ] Vec n := AffineMap.lineMap x x' with hLdef
  have hL0 : L 0 = x := AffineMap.lineMap_apply_zero x x'
  have hL1 : L 1 = x' := AffineMap.lineMap_apply_one x x'
  -- Step 1: `f ∘ L` is convex on `ℝ`.
  have hgconv : ConvexOn ℝ (Set.univ : Set ℝ) (f ∘ L) := by
    simpa using hconv.comp_affineMap L
  -- Step 2: `L` has derivative `x' - x` everywhere, in particular at `0`.
  have hderivL : HasDerivAt L (x' - x) 0 := by
    have h : ⇑L = fun t : ℝ => t • (x' - x) + x := by
      funext t; simp [hLdef, AffineMap.lineMap_apply, sub_eq_add_neg]
    rw [h]
    simpa using ((hasDerivAt_id (0 : ℝ)).smul_const (x' - x)).add_const x
  -- Step 3: chain rule, so `(f ∘ L)' 0 = ⟪grad, x' - x⟫`.
  have hd : HasDerivAt (f ∘ L) (inner (𝕜 := ℝ) grad (x' - x)) 0 := by
    have hfd : HasFDerivAt f ((InnerProductSpace.toDual ℝ (Vec n)) grad) (L 0) := by
      rw [hL0]; exact hgrad.hasFDerivAt
    simpa [InnerProductSpace.toDual_apply_apply] using hfd.comp_hasDerivAt (0 : ℝ) hderivL
  -- Step 4: convexity gives `(f ∘ L)' 0 ≤ slope (f ∘ L) 0 1 = f x' - f x`.
  have hslope := hgconv.le_slope_of_hasDerivAt (Set.mem_univ (0 : ℝ))
    (Set.mem_univ (1 : ℝ)) zero_lt_one hd
  rw [slope_def_field] at hslope
  simp only [Function.comp_apply, hL0, hL1] at hslope
  have : inner (𝕜 := ℝ) grad (x' - x) ≤ f x' - f x := by
    simpa using hslope
  linarith

/-- `suboptimality_bound`, packaged for a genuinely convex, differentiable
`f` — no hand-stated `subgrad` hypothesis, only the two facts that make it
true. This is the "strictly stronger corollary" promised in
`SuboptimalityBound.lean`'s design-choice note. -/
theorem suboptimality_bound_of_convexOn
    (f : Vec n → ℝ) (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x grad : Vec n) (y : Fin m → ℝ) (r : Vec n)
    (hconv : ConvexOn ℝ Set.univ f) (hgrad : HasGradientAt f grad x)
    (hy : ∀ i, 0 ≤ y i)
    (hr : r = grad - (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j)) :
    ∀ x' : Vec n, (∀ i, 0 ≤ slack A c x' i) →
      f x - f x' ≤ (∑ i, y i * slack A c x i) + ‖r‖ * ‖x - x'‖ :=
  suboptimality_bound f A c x grad y r (subgrad_of_convexOn f x grad hconv hgrad) hy hr

end SolverCertificate
