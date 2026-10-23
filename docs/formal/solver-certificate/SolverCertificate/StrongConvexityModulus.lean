-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.SuboptimalityBound

/-!
# The strong-convexity modulus lower bound (solver.scm §3/§4, lines 642-666)

`strong-convexity-modulus` claims a rigorous lower bound on the curvature of
the solver's objective, used by `kkt-report`'s `dist-curvature` branch of the
certified suboptimality bound (`‖r‖²/(2σ)`, `solver.scm:1226`). Its docstring
already carries a proof sketch — the same "theorem in a comment" pattern §3
was full of:

    H = Σᵢ φ″ᵢ aᵢaᵢᵀ. Any term whose row touches a SINGLE variable contributes
    φ″·a² to that diagonal entry and nothing else, so H ⪰ diag(d) over those
    terms alone and λ_min(H) ≥ min_j dⱼ.

This file states and proves that claim directly as a statement about the
quadratic form `vᵀHv`, matching how `kkt-report` actually uses `σ` (always
through a Rayleigh-quotient-shaped bound, never through an eigenvalue
computation) and matching the finite-difference curvature check in
`tests/solve/test-property-solver-invariants.scm`, which spot-checks the
Scheme implementation against exactly this claim on random programs.

Deliberately abstracted away from CSR: a "term" is just `a : Vec n` (its full
row, dense, zero where the sparse row is absent) with a curvature weight
`c ≥ 0`. `whichVar ti = some k` encodes "this row touches only variable k" —
the same hypothesis `strong-convexity-modulus` reads off `(- hi lo) = 1` in
the CSR structure, restated as a semantic support condition instead of an
indexing fact, so nothing about CSR layout leaks into the theorem.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n nt : ℕ} [NeZero n]

-- `[NeZero n]` is kept in the statement to match the rest of the development (a solver always
-- has at least one variable); the proof happens not to need it, since `ciInf_le` only wants
-- boundedness below, which is automatic for a finite index type.
set_option linter.unusedSectionVars false in
/-- **The curvature lower bound.** `d k` collects exactly the single-variable
terms' contribution at coordinate `k`; every other term contributes something
nonnegative to `vᵀHv` regardless of direction, so the minimum single-variable
contribution alone already lower-bounds the full quadratic form. -/
theorem strong_convexity_modulus_lower_bound
    (a : Fin nt → Vec n) (c : Fin nt → ℝ) (hc : ∀ ti, 0 ≤ c ti)
    (whichVar : Fin nt → Option (Fin n))
    (hsupport : ∀ ti k, whichVar ti = some k →
      ∀ v : Vec n, (inner (𝕜 := ℝ) (a ti) v) = a ti k * v k)
    (d : Fin n → ℝ)
    (hd : ∀ k, d k = ∑ ti ∈ Finset.univ.filter (fun ti => whichVar ti = some k),
      c ti * (a ti k) ^ 2) :
    ∀ v : Vec n, (⨅ k, d k) * ‖v‖ ^ 2 ≤ ∑ ti, c ti * (inner (𝕜 := ℝ) (a ti) v) ^ 2 := by
  classical
  intro v
  -- `‖v‖² = Σ_k (v k)²` for the Euclidean structure on `Vec n`.
  have hnorm : ‖v‖ ^ 2 = ∑ k, (v k) ^ 2 := by
    rw [← real_inner_self_eq_norm_sq, PiLp.inner_apply]; simp [sq]
  -- The infimum over the (finite, nonempty) index type is a genuine lower bound.
  have hinf : ∀ k, (⨅ j, d j) ≤ d k := fun k => ciInf_le (Finite.bddBelow_range d) k
  -- Step A: replace the uniform modulus by the coordinatewise one.
  have hA : (⨅ k, d k) * ‖v‖ ^ 2 ≤ ∑ k, d k * (v k) ^ 2 := by
    rw [hnorm, Finset.mul_sum]
    exact Finset.sum_le_sum fun k _ => mul_le_mul_of_nonneg_right (hinf k) (sq_nonneg _)
  refine hA.trans ?_
  -- `S` = the terms that touch a single variable.
  set S : Finset (Fin nt) := Finset.univ.filter (fun ti => (whichVar ti).isSome) with hS
  -- Step B: regrouping `S` by fibers of `whichVar` turns `Σ_k d k (v k)²` into the `S`-part
  -- of the quadratic form exactly.
  have hB : ∑ k, d k * (v k) ^ 2 = ∑ ti ∈ S, c ti * (inner (𝕜 := ℝ) (a ti) v) ^ 2 := by
    have hmaps : ∀ ti ∈ S, whichVar ti ∈ Finset.univ.image (some : Fin n → Option (Fin n)) := by
      intro ti hti
      simp only [hS, Finset.mem_filter] at hti
      obtain ⟨k, hk⟩ := Option.isSome_iff_exists.mp hti.2
      simp [hk]
    rw [← Finset.sum_fiberwise_of_maps_to hmaps (fun ti => c ti * (inner (𝕜 := ℝ) (a ti) v) ^ 2),
      Finset.sum_image (by intro x _ y _ h; exact Option.some_injective _ h)]
    refine Finset.sum_congr rfl fun k _ => ?_
    have hfilter : S.filter (fun ti => whichVar ti = some k)
        = Finset.univ.filter (fun ti => whichVar ti = some k) := by
      ext ti; simp only [hS, Finset.mem_filter, Finset.mem_univ, true_and, and_iff_right_iff_imp]
      intro h; simp [h]
    rw [hfilter, hd k, Finset.sum_mul]
    refine Finset.sum_congr rfl fun ti hti => ?_
    rw [hsupport ti k (Finset.mem_filter.mp hti).2 v]
    ring
  rw [hB]
  -- Step C: the discarded terms are each `c ti * (…)² ≥ 0`.
  exact Finset.sum_le_sum_of_subset_of_nonneg (Finset.subset_univ S)
    (fun ti _ _ => mul_nonneg (hc ti) (sq_nonneg _))

end SolverCertificate
