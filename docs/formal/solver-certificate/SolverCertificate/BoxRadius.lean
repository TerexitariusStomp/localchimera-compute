-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.BoxBounds

/-!
# `feasible-box-radius` is sound (solver.scm §3, lines 975-994)

`BoxBounds.lean` certifies the per-coordinate caps `u`; `SuboptimalityBound.lean`
needs a bound on `‖x − x'‖` for its `‖r‖·‖x − x'‖` term. `feasible-box-radius`
is the piece between them, and until this file it was asserted in prose at both
ends ("these bounds feed `feasible-box-radius`, which feeds `dist-geometry`")
and proved at neither.

The code does not take the crude diameter. Given the current point `x` it
sharpens for free, and the justification lives entirely in a docstring comment
(solver.scm:981-984):

    Both x and x* lie in the box [0, u], so |xⱼ − x*ⱼ| ≤ max(xⱼ, uⱼ − xⱼ)
    componentwise — the distance to the FARTHER end of each interval, never
    the whole interval.

That is the "theorem in a comment" pattern this development exists to remove,
and it is load-bearing in the unsafe direction: the radius enters the
certificate multiplied by `‖r‖`, so a `D` that is too SMALL under-reports the
gap and flatters the plan. Both readings are proved here — the sharpened one
the code uses (`boxRadius`) and the crude one it falls back to when no `x` is
supplied (`boxRadiusCrude`, the `#:optional x` branch) — along with the fact
that sharpening only ever helps.

Finiteness discipline, as in `BoxBounds.lean`: `+inf` is not a real, so "the
radius is `+inf`" is represented by the absence of a `ValidBounds` vector, and
every `boxRadius` here is finite by construction. `box_bounded_of_validBounds`
records what that buys — a genuinely bounded feasible set, which is the
condition `box-bounded?` (solver.scm:968) checks before declaring the geometry
branch live.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- The radius `feasible-box-radius` computes when given the current point:
`√(Σⱼ max(xⱼ, uⱼ − xⱼ)²)`, the distance to the farther end of each interval
`[0, uⱼ]`. -/
noncomputable def boxRadius (u : Fin n → ℝ) (x : Vec n) : ℝ :=
  Real.sqrt (∑ j, (max (x j) (u j - x j)) ^ 2)

/-- The radius with no current point to sharpen against — `feasible-box-radius`
with its `#:optional x` omitted, i.e. `√(Σⱼ uⱼ²)`. -/
noncomputable def boxRadiusCrude (u : Fin n → ℝ) : ℝ :=
  Real.sqrt (∑ j, (u j) ^ 2)

/-- **The sharpened radius is a genuine bound on `‖x − x'‖`.** For `u` a valid
bound vector, the Euclidean distance from `x` to any feasible nonnegative `x'`
is at most `boxRadius u x`. This is exactly the `‖x − x'‖` factor
`suboptimality_bound` leaves open, so it discharges the geometry branch's only
geometric hypothesis.

Only `x'` — the point compared against, in the intended reading the optimum
`x*` — has to live in the box. The queried point `x` can be anywhere: the
radius `√(Σⱼ max(xⱼ, uⱼ−xⱼ)²)` is measured *from* `x` outward, and what makes
it a bound is `x*` being trapped in `[0, u]`, not `x` being anywhere in
particular. This is the same fact as `suboptimality_bound`'s "`x` need not be
feasible" note, showing up in the geometry instead of in the algebra: an
infeasible or out-of-box iterate still gets an honest radius. -/
theorem norm_sub_le_boxRadius (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → ℝ) (hu : ValidBounds A c u)
    (x x' : Vec n)
    (hx' : ∀ j, 0 ≤ x' j) (hx'f : ∀ ℓ, 0 ≤ slack A c x' ℓ) :
    ‖x - x'‖ ≤ boxRadius u x := by
  rw [EuclideanSpace.norm_eq, boxRadius]
  refine Real.sqrt_le_sqrt (Finset.sum_le_sum fun j _ => ?_)
  -- componentwise: |xⱼ − x'ⱼ| ≤ max(xⱼ, uⱼ − xⱼ). No case split on which point is
  -- larger is needed — each side of the absolute value uses one end of x'ⱼ's own
  -- interval: `x'ⱼ ≤ uⱼ` bounds the difference below, `0 ≤ x'ⱼ` bounds it above.
  rw [show (x - x') j = x j - x' j from rfl, Real.norm_eq_abs, sq_abs]
  exact sq_le_sq'
    (by linarith [le_max_right (x j) (u j - x j), hu x' hx' hx'f j])
    (by linarith [le_max_left (x j) (u j - x j), hx' j])

/-- **Sharpening only helps.** The radius computed against the current point is
never worse than the crude one — "given the current x it is sharpened for
free". So the `#:optional x` branch is a strict weakening, never a correction. -/
theorem boxRadius_le_crude (u : Fin n → ℝ) (x : Vec n)
    (hx : ∀ j, 0 ≤ x j) (hxu : ∀ j, x j ≤ u j) :
    boxRadius u x ≤ boxRadiusCrude u := by
  refine Real.sqrt_le_sqrt (Finset.sum_le_sum fun j _ => ?_)
  have h0 : (0:ℝ) ≤ max (x j) (u j - x j) := le_trans (hx j) (le_max_left _ _)
  exact pow_le_pow_left₀ h0 (max_le (hxu j) (by linarith [hx j])) 2

/-- **The crude radius bounds the distance too** — the corollary a caller who
passes no current point gets. Unlike `norm_sub_le_boxRadius`, this one *does*
need `x` inside the box (`hx`, `hxf`): the crude radius is computed from `u`
alone and knows nothing about where `x` sits, so it can only cover an `x` that
is itself in `[0, u]`. Losing the sharpening costs a hypothesis as well as
tightness. -/
theorem norm_sub_le_boxRadiusCrude (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → ℝ) (hu : ValidBounds A c u)
    (x x' : Vec n)
    (hx : ∀ j, 0 ≤ x j) (hxf : ∀ ℓ, 0 ≤ slack A c x ℓ)
    (hx' : ∀ j, 0 ≤ x' j) (hx'f : ∀ ℓ, 0 ≤ slack A c x' ℓ) :
    ‖x - x'‖ ≤ boxRadiusCrude u :=
  le_trans (norm_sub_le_boxRadius A c u hu x x' hx' hx'f)
    (boxRadius_le_crude u x hx (fun j => hu x hx hxf j))

/-- Every feasible nonnegative point sits inside the crude ball. -/
theorem norm_le_boxRadiusCrude (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → ℝ) (hu : ValidBounds A c u)
    (x : Vec n) (hx : ∀ j, 0 ≤ x j) (hxf : ∀ ℓ, 0 ≤ slack A c x ℓ) :
    ‖x‖ ≤ boxRadiusCrude u := by
  rw [EuclideanSpace.norm_eq, boxRadiusCrude]
  refine Real.sqrt_le_sqrt (Finset.sum_le_sum fun j _ => ?_)
  rw [Real.norm_eq_abs, sq_abs]
  exact pow_le_pow_left₀ (hx j) (hu x hx hxf j) 2

/-- **`box-bounded?` earns the geometry branch.** A valid bound vector makes
the feasible nonnegative set genuinely bounded (solver.scm:968: the condition
"under which `feasible-box-radius` is finite and the certificate's geometry
branch is live"). Note the Lean reading of finiteness: `+inf` is not a real, so
possessing a `ValidBounds u` at all is what "every column is capped" means, and
boundedness is what it buys. -/
theorem box_bounded_of_validBounds (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → ℝ) (hu : ValidBounds A c u) :
    Bornology.IsBounded {x : Vec n | (∀ j, 0 ≤ x j) ∧ ∀ ℓ, 0 ≤ slack A c x ℓ} := by
  exact isBounded_iff_forall_norm_le.mpr
    ⟨boxRadiusCrude u, fun x hx => norm_le_boxRadiusCrude A c u hu x hx.1 hx.2⟩

end SolverCertificate
