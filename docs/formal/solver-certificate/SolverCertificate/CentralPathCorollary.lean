-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.SuboptimalityBound

/-!
# The central-path corollary (solver.scm §3, lines 532–538, 1179–1230)

Two "free" facts `plan-certificate` and `kkt-report` both lean on, made
checkable rather than asserted in a comment.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n m : ℕ}

/-- **Dual feasibility is free.** `solver.scm:633` — "yᵢ = t/sᵢ with t > 0 and
sᵢ > 0 is positive by construction, so the y ≥ 0 hypothesis holds
identically." This is exactly the `hy` hypothesis `suboptimality_bound`
needs. -/
theorem central_path_dual_nonneg
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (x : Vec n) (t : ℝ) (ht : 0 < t)
    (hs : ∀ i, 0 < slack A c x i) :
    ∀ i, 0 ≤ t / slack A c x i :=
  fun i => (div_pos ht (hs i)).le

/-- **`plan-certificate`'s `m·t` bound is the `r = 0` case of the master
theorem, not a separate fact.** `solver.scm:536-538` computes `m·t` for the
exact central-path point, where stationarity holds exactly (`r = 0`); when a
fitted dual leaves `r ≠ 0` (the ordinary case per the comment at line 628),
`kkt-report`'s `bound` binding (line 1228) is the *general* theorem, not a
different one. Both numbers a caller might see come from one theorem. -/
theorem central_path_bound_is_zero_residual_case
    (f : Vec n → ℝ) (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (grad : Vec n) (t : ℝ) (ht : 0 < t)
    (hs : ∀ i, 0 < slack A c x i)
    (y : Fin m → ℝ) (hy_central : ∀ i, y i = t / slack A c x i)
    (subgrad : ∀ x' : Vec n, f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)))
    (hstationary : grad = (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j)) :
    ∀ x' : Vec n, (∀ i, 0 ≤ slack A c x' i) → f x - f x' ≤ (Fintype.card (Fin m) : ℝ) * t := by
  -- yᵀs(x) = Σᵢ sᵢ·(t/sᵢ) = m·t exactly; r = grad - Aᵀy = 0 by hstationary,
  -- so suboptimality_bound's ‖r‖·‖x-x'‖ term vanishes and only m·t survives.
  intro x' hx'feas
  have hr : (0 : Vec n) =
      grad - (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j) := by
    rw [hstationary, sub_self]
  have hy : ∀ i, 0 ≤ y i := fun i => (hy_central i) ▸ le_of_lt (div_pos ht (hs i))
  have hbound := suboptimality_bound f A c x grad y 0 subgrad hy hr x' hx'feas
  -- yᵀs(x) = Σᵢ (t/sᵢ)·sᵢ = Σᵢ t = m·t, since every sᵢ > 0.
  have hsum : (∑ i, y i * slack A c x i) = (Fintype.card (Fin m) : ℝ) * t := by
    have : ∀ i : Fin m, y i * slack A c x i = t := fun i => by
      rw [hy_central i, div_mul_cancel₀ t (ne_of_gt (hs i))]
    rw [Finset.sum_congr rfl fun i _ => this i]
    simp [mul_comm]
  rw [hsum] at hbound
  simpa using hbound

end SolverCertificate
