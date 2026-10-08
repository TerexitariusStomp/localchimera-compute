import SolverCertificate.CsrSemantics
import Mathlib.Analysis.Calculus.Gradient.Basic
import Mathlib.Analysis.Calculus.FDeriv.Linear
import Mathlib.Analysis.Calculus.FDeriv.Add
import Mathlib.Analysis.Calculus.Deriv.Comp

/-!
# `csr-grad` really computes ∇f (solver.scm §0, lines 204-218)
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n m : ℕ}

/-- Row `i` of `A` as a vector of `Vec n`. -/
noncomputable def rowVec (A : Matrix (Fin m) (Fin n) ℝ) (i : Fin m) : Vec n :=
  (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => A i j)

theorem inner_rowVec (A : Matrix (Fin m) (Fin n) ℝ) (i : Fin m) (y : Vec n) :
    (inner (𝕜 := ℝ) (rowVec A i) y) = ∑ j, A i j * y j := by
  simp [rowVec, PiLp.inner_apply, RCLike.inner_apply, mul_comm]

/-- Each slack is affine with gradient the row itself. -/
theorem hasGradientAt_slack (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (i : Fin m) (x : Vec n) :
    HasGradientAt (fun y : Vec n => slack A c y i) (rowVec A i) x := by
  rw [hasGradientAt_iff_hasFDerivAt]
  have hfun : (fun y : Vec n => slack A c y i)
      = fun y => c i + (InnerProductSpace.toDual ℝ (Vec n) (rowVec A i)) y := by
    funext y
    rw [InnerProductSpace.toDual_apply_apply, inner_rowVec]
    rfl
  rw [hfun]
  exact HasFDerivAt.const_add (c i)
    (ContinuousLinearMap.hasFDerivAt (InnerProductSpace.toDual ℝ (Vec n) (rowVec A i)))

/-- The objective the CSR loops define (`obj-value`, solver.scm:214): each
term's `φ` applied to that term's own slack, plus the linear free-time term
`κ·labform`. The per-kind `φ` is left abstract exactly as the code leaves it
abstract — `*kind-fns*` is a dispatch table, and the loop is the same whatever
is in it. -/
noncomputable def csrObjective (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (φ : Fin m → ℝ → ℝ) (lin : Vec n) (y : Vec n) : ℝ :=
  (∑ i, φ i (slack A c y i)) + inner (𝕜 := ℝ) lin y

/-- `csr-grad`'s accumulator (solver.scm:204-213), written out: for each term
whose `φ′` is nonzero, walk the span adding `φ′·val[k]` into `g[idx[k]]`, then
add the `κ·labform` entries. Dropping the `φ′ = 0` terms — the `unless` guard —
is invisible here because those terms contribute `0` to the sum. -/
noncomputable def csrGradVec (A : Matrix (Fin m) (Fin n) ℝ)
    (dφ : Fin m → ℝ) (lin : Vec n) : Vec n :=
  (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => (∑ i, dφ i * A i j) + lin j)

/-- **`csr-grad` computes the gradient.** If each kind's `φ′` really is the
derivative of its `φ` at that term's slack (`hφ` — the per-kind obligation,
discharged for the shipped table in `TensionKinds.lean`), then the vector the
loop accumulates IS `∇f` at `x`.

This closes the last structural gap between the Scheme and the certificate.
`suboptimality_bound` takes `subgrad` as a hypothesis and
`subgrad_of_convexOn` derives it from `ConvexOn` + `HasGradientAt` — but the
`HasGradientAt` was, until now, about an abstract `grad`, with nothing
connecting it to the vector `csr-grad` returns. The chain rule is the whole
content: `∂/∂xⱼ Σᵢ φᵢ(sᵢ(x)) = Σᵢ φ′ᵢ(sᵢ(x))·aᵢⱼ`, and `aᵢⱼ` is what the span
walk reads. Note the theorem is agnostic about `t`: `csr-grad` is called at
`t = 0` for `∇f` and at the current `t` for `∇f − Aᵀy`, and both are instances,
since `t` only enters through the `φ`s. -/
theorem hasGradientAt_csrObjective (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (φ : Fin m → ℝ → ℝ) (dφ : Fin m → ℝ) (lin x : Vec n)
    (hφ : ∀ i, HasDerivAt (φ i) (dφ i) (slack A c x i)) :
    HasGradientAt (csrObjective A c φ lin) (csrGradVec A dφ lin) x := by
  rw [hasGradientAt_iff_hasFDerivAt]
  -- chain rule, one term at a time: ∂/∂x φᵢ(sᵢ(x)) = φ′ᵢ(sᵢ(x)) · ∇sᵢ, and ∇sᵢ is row i
  have hterm : ∀ i : Fin m, HasFDerivAt (fun y : Vec n => φ i (slack A c y i))
      ((dφ i) • (InnerProductSpace.toDual ℝ (Vec n) (rowVec A i))) x :=
    fun i => HasDerivAt.comp_hasFDerivAt x (hφ i)
      (HasGradientAt.hasFDerivAt (hasGradientAt_slack A c i x))
  -- the terms sum, which is the outer `do` loop over `ti`
  have hfunsum : (fun y : Vec n => ∑ i, φ i (slack A c y i))
      = ∑ i ∈ Finset.univ, (fun y : Vec n => φ i (slack A c y i)) := by
    funext y; simp
  have hsum : HasFDerivAt (fun y : Vec n => ∑ i, φ i (slack A c y i))
      (∑ i, (dφ i) • (InnerProductSpace.toDual ℝ (Vec n) (rowVec A i))) x := by
    rw [hfunsum]
    exact HasFDerivAt.sum (fun i _ => hterm i)
  -- the κ·labform term
  have hfunlin : (fun y : Vec n => inner (𝕜 := ℝ) lin y)
      = ⇑(InnerProductSpace.toDual ℝ (Vec n) lin) := by
    funext y; rw [InnerProductSpace.toDual_apply_apply]
  have hlin : HasFDerivAt (fun y : Vec n => inner (𝕜 := ℝ) lin y)
      (InnerProductSpace.toDual ℝ (Vec n) lin) x := by
    rw [hfunlin]
    exact ContinuousLinearMap.hasFDerivAt _
  -- the accumulated dual is the dual of the accumulated vector: `+=` into g[idx[k]]
  have hdual : (∑ i, (dφ i) • (InnerProductSpace.toDual ℝ (Vec n) (rowVec A i)))
      + InnerProductSpace.toDual ℝ (Vec n) lin
      = InnerProductSpace.toDual ℝ (Vec n) (csrGradVec A dφ lin) := by
    rw [Finset.sum_congr rfl (fun i _ => (map_smul (InnerProductSpace.toDual ℝ (Vec n))
        (dφ i) (rowVec A i)).symm), ← map_sum, ← map_add]
    congr 1
    ext j
    simp [csrGradVec, rowVec]
  rw [← hdual]
  exact hsum.add hlin

end SolverCertificate
