import SolverCertificate.BoxRadius
import SolverCertificate.DistCurvature

/-!
# The number `kkt-report` publishes (solver.scm §3, lines 1240-1263)

Every other file certifies one claim. This one certifies the arithmetic the
certificate actually prints. `kkt-report` assembles

    b-geo  = ‖r‖ · rad                       ; geometry branch
    b-cvx  = ‖r‖² / (2σ)                     ; curvature branch
    bdist  = (min b-geo b-cvx)
    bound  = yᵀs(x) + bdist

and both branches were already proved here — `suboptimality_bound` and
`suboptimality_bound_curvature` — but never the `min`, and never with `rad`
being the radius `feasible-box-radius` computes rather than an abstract
`‖x − x'‖`. Those two joins are what this file supplies, so that a single
theorem covers the published number end to end:

* `subgrad_of_strongConvex` — the curvature hypothesis subsumes the convexity
  one, so the capstone needs only `sconv`. (The code makes the same
  identification: `strong-convexity-modulus` returning `σ > 0` is not a
  *different* assumption about `f`, it is a stronger reading of the same one.)
* `kkt_bound_correct` — the whole assembly, with `rad = boxRadius u x`.

Whichever branch the `min` selects, the published bound is valid; the code
takes the better of the two and this says taking the better is allowed. The
`+inf` cases (`rad` infinite, or `σ = 0`) are, per the finiteness discipline
of `BoxBounds.lean`, the cases where the corresponding hypothesis is simply
absent — a `+inf` branch constrains nothing and the `min` falls through to the
other one, which is exactly what the two single-branch theorems already say.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n m : ℕ}

/-- σ-strong convexity implies the plain first-order inequality: the extra
`σ/2·‖x' − x‖²` term is nonnegative. So a caller who has `sconv` need not
also carry `subgrad`. -/
theorem subgrad_of_strongConvex (f : Vec n → ℝ) (x grad : Vec n) (σ : ℝ) (hσ : 0 ≤ σ)
    (sconv : ∀ x' : Vec n,
      f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)) + σ / 2 * ‖x' - x‖ ^ 2) :
    ∀ x' : Vec n, f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)) := by
  intro x'
  have h := sconv x'
  have hpos : 0 ≤ σ / 2 * ‖x' - x‖ ^ 2 := by positivity
  linarith

/-- **The certificate's published bound is correct.** With a valid bound
vector `u` (the geometry branch's input, from `column-caps`), a curvature
modulus `σ > 0` (from `strong-convexity-modulus`), a nonnegative dual `y`, and
`r = ∇f(x) − Aᵀy`, every feasible nonnegative `x'` — in particular the optimum
`x*` — satisfies

    f(x) − f(x') ≤ yᵀs(x) + min (‖r‖ · boxRadius u x) (‖r‖² / (2σ)).

This is `bound` at solver.scm:1246 with `bdist` at 1245, `b-geo` at 1243 and
`b-cvx` at 1244, resting on `norm_sub_le_boxRadius` for `rad` and on the two
branch theorems for the terms.

The queried point `x` carries no hypotheses at all — not feasibility, not
nonnegativity, not membership in the box. Every one of them turned out to be
unread, inherited from `suboptimality_bound` (whose `x` need not be feasible)
and from `norm_sub_le_boxRadius` (whose radius is measured from wherever `x`
is). Only `x'` must lie in the feasible box. That is worth stating plainly,
because it is what makes the certificate usable mid-solve: `kkt-report` can be
called on an iterate that is still infeasible — a plateau exit, an OSQP
boundary point, a point outside the propagated box — and the published bound is
valid anyway. The `feasible?` flag the report carries is for the human reading
the plan, not for the arithmetic of the bound. -/
theorem kkt_bound_correct
    (f : Vec n → ℝ) (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (grad : Vec n) (y : Fin m → ℝ) (r : Vec n)
    (σ : ℝ) (hσ : 0 < σ)
    (sconv : ∀ x' : Vec n,
      f x' ≥ f x + (inner (𝕜 := ℝ) grad (x' - x)) + σ / 2 * ‖x' - x‖ ^ 2)
    (hy : ∀ i, 0 ≤ y i)
    (hr : r = grad - (EuclideanSpace.equiv (Fin n) ℝ).symm (fun j => transposeMulVec A y j))
    (u : Fin n → ℝ) (hu : ValidBounds A c u) :
    ∀ x' : Vec n, (∀ j, 0 ≤ x' j) → (∀ ℓ, 0 ≤ slack A c x' ℓ) →
      f x - f x' ≤ (∑ i, y i * slack A c x i)
        + min (‖r‖ * boxRadius u x) (‖r‖ ^ 2 / (2 * σ)) := by
  intro x' hx' hx'f
  -- geometry branch: the abstract ‖x − x'‖ term, then the computed radius on top of it
  have hgeo := suboptimality_bound f A c x grad y r
    (subgrad_of_strongConvex f x grad σ hσ.le sconv) hy hr x' hx'f
  have hrad : ‖x - x'‖ ≤ boxRadius u x :=
    norm_sub_le_boxRadius A c u hu x x' hx' hx'f
  have hgeo' : f x - f x' ≤ (∑ i, y i * slack A c x i) + ‖r‖ * boxRadius u x := by
    have : ‖r‖ * ‖x - x'‖ ≤ ‖r‖ * boxRadius u x :=
      mul_le_mul_of_nonneg_left hrad (norm_nonneg r)
    linarith
  -- curvature branch
  have hcvx := suboptimality_bound_curvature f A c x grad y r σ hσ sconv hy hr x' hx'f
  -- the `min` is whichever of the two the code selected; both are valid
  rcases min_cases (‖r‖ * boxRadius u x) (‖r‖ ^ 2 / (2 * σ)) with ⟨h, _⟩ | ⟨h, _⟩ <;>
    rw [h] <;> linarith

end SolverCertificate
