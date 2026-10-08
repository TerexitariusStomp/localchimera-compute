import Mathlib.Analysis.Convex.Deriv
import SolverCertificate.InTheLarge

/-!
# Curvature along every line ⇒ `StrongConvexOn` (the modulus → growth bridge)

`InTheLarge.lean`'s chain — quadratic growth at the argmin, the
`(1/m)`-Lipschitz argmin, `deviation_gain_le`, ε-dominance — consumes
Mathlib's `StrongConvexOn Set.univ m g`. `StrongConvexityModulus.lean` bounds
the objective's Hessian quadratic form: `m·‖v‖² ≤ vᵀH(x)v`. This file is the
bridge between the two, in the form the modulus bound actually arrives:
`vᵀH(x)v` IS the second derivative of `g` along the line `t ↦ x + t•v`, so
the hypothesis taken here is exactly that — for every base point and
direction, the line restriction is twice differentiable and its second
derivative is at least `m‖v‖²` — and the conclusion is `StrongConvexOn`.

Route: `strongConvexOn_iff_convex` reduces to convexity of
`g − m/2·‖·‖²`; along a line the subtracted quadratic expands to a
polynomial in `t` (`norm_add_sq_real`) whose second derivative is exactly
`m‖v‖²`, so the difference's line restrictions have nonnegative second
derivative (`convexOn_univ_of_deriv2_nonneg`); and a function whose every
line restriction is convex is convex (`convexOn_univ_of_forall_line`,
proved here — the elementary bridge Mathlib states only in the composition
direction, `ConvexOn.comp_affineMap`).

What remains unformalised after this file: discharging the line-curvature
hypothesis for the CONCRETE barrier objective — identifying `Σᵢ φ″ᵢ⟪aᵢ,v⟫²`
(the form `strong_convexity_modulus_lower_bound` bounds) with
`deriv (deriv (t ↦ g(x+t•v)))` for the CSR sum of `TensionKinds.lean`'s
φ's, plus their twice-differentiability along lines. That is a statement
about five explicit scalar functions, not about convex analysis; the
analysis half of the link is closed here.
-/

namespace SolverCertificate

open Set

variable {E : Type*} [NormedAddCommGroup E] [InnerProductSpace ℝ E]

/-- A function whose restriction to EVERY line is convex is convex: evaluate
the line through `x` and `y` at `0`, `1`, and `b`. The converse direction is
Mathlib's `ConvexOn.comp_affineMap`; this one is stated only through the
segment definition, so it is proved by hand. -/
theorem convexOn_univ_of_forall_line (f : E → ℝ)
    (hline : ∀ x v : E, ConvexOn ℝ Set.univ fun t : ℝ => f (x + t • v)) :
    ConvexOn ℝ Set.univ f := by
  refine ⟨convex_univ, fun x _ y _ a b ha hb hab => ?_⟩
  have h := (hline x (y - x)).2 (mem_univ (0 : ℝ)) (mem_univ (1 : ℝ)) ha hb hab
  simp only [smul_eq_mul, mul_zero, mul_one, zero_add, zero_smul, add_zero, one_smul] at h
  have hpt : x + b • (y - x) = a • x + b • y := by
    have : a = 1 - b := by linarith
    subst this
    module
  rw [hpt] at h
  simpa [smul_eq_mul] using h
/-- The quadratic `t ↦ m/2·‖x + t•v‖²` along a line, as the polynomial it
is, with its first derivative. -/
private theorem hasDerivAt_half_norm_line (m : ℝ) (x v : E) (t : ℝ) :
    HasDerivAt (fun t : ℝ => m / 2 * ‖x + t • v‖ ^ 2)
      (m * inner ℝ x v + m * ‖v‖ ^ 2 * t) t := by
  have hexp : (fun t : ℝ => m / 2 * ‖x + t • v‖ ^ 2)
      = fun t : ℝ => m / 2 * ‖x‖ ^ 2
          + ((m * inner ℝ x v) * t + (m / 2 * ‖v‖ ^ 2) * (t * t)) := by
    funext s
    rw [norm_add_sq_real, real_inner_smul_right, norm_smul]
    simp [Real.norm_eq_abs, mul_pow, sq_abs]
    ring
  rw [hexp]
  have h := (((hasDerivAt_id t).const_mul (m * inner ℝ x v)).add
      (((hasDerivAt_id t).mul (hasDerivAt_id t)).const_mul (m / 2 * ‖v‖ ^ 2))).const_add
      (m / 2 * ‖x‖ ^ 2)
  have he : m * inner ℝ x v * 1 + m / 2 * ‖v‖ ^ 2 * (1 * t + t * 1)
      = m * inner ℝ x v + m * ‖v‖ ^ 2 * t := by ring
  exact he ▸ h

/-- **Curvature along every line ⇒ strong convexity.** The hypotheses are
the line restrictions' twice-differentiability and the directional
curvature bound `m‖v‖² ≤ (d²/dt²) g(x+t•v)` — the shape in which
`strong_convexity_modulus_lower_bound` delivers the objective's curvature
(`vᵀH(x)v` is that second derivative). -/
theorem strongConvexOn_univ_of_line_deriv2 (g : E → ℝ) (m : ℝ)
    (hd1 : ∀ x v : E, Differentiable ℝ fun t : ℝ => g (x + t • v))
    (hd2 : ∀ x v : E, Differentiable ℝ (deriv fun t : ℝ => g (x + t • v)))
    (hcurv : ∀ x v : E, ∀ t : ℝ,
      m * ‖v‖ ^ 2 ≤ deriv (deriv fun s : ℝ => g (x + s • v)) t) :
    StrongConvexOn Set.univ m g := by
  rw [strongConvexOn_iff_convex]
  apply convexOn_univ_of_forall_line
  intro x v
  have hq : ∀ t : ℝ, HasDerivAt (fun s : ℝ => m / 2 * ‖x + s • v‖ ^ 2)
      (m * inner ℝ x v + m * ‖v‖ ^ 2 * t) t := hasDerivAt_half_norm_line m x v
  -- the line restriction's first derivative, via HasDerivAt.sub
  have hF' : ∀ t : ℝ, HasDerivAt (fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2)
      (deriv (fun s : ℝ => g (x + s • v)) t - (m * inner ℝ x v + m * ‖v‖ ^ 2 * t)) t :=
    fun t => (((hd1 x v) t).hasDerivAt).sub (hq t)
  have hF1 : Differentiable ℝ fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2 :=
    fun t => (hF' t).differentiableAt
  have hdF : deriv (fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2)
      = fun t : ℝ => deriv (fun s : ℝ => g (x + s • v)) t
          - (m * inner ℝ x v + m * ‖v‖ ^ 2 * t) := funext fun t => (hF' t).deriv
  -- the linear part of the first derivative, with its own derivative
  have hlin : ∀ t : ℝ, HasDerivAt (fun s : ℝ => m * inner ℝ x v + m * ‖v‖ ^ 2 * s)
      (m * ‖v‖ ^ 2) t := by
    intro t
    have h := ((hasDerivAt_id t).const_mul (m * ‖v‖ ^ 2)).const_add (m * inner ℝ x v)
    exact h.congr_deriv (mul_one _)
  have hF2 : Differentiable ℝ (deriv fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2) := by
    rw [hdF]
    exact (hd2 x v).sub fun t => (hlin t).differentiableAt
  refine convexOn_univ_of_deriv2_nonneg hF1 hF2 fun t => ?_
  have hit : (deriv^[2] fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2)
      = deriv (deriv fun t : ℝ => g (x + t • v) - m / 2 * ‖x + t • v‖ ^ 2) := by
    simp [Function.iterate_succ]
  have hd2' : ∀ u : ℝ, HasDerivAt (fun s : ℝ => deriv (fun r : ℝ => g (x + r • v)) s
      - (m * inner ℝ x v + m * ‖v‖ ^ 2 * s))
      (deriv (deriv fun r : ℝ => g (x + r • v)) u - m * ‖v‖ ^ 2) u :=
    fun u => (((hd2 x v) u).hasDerivAt).sub (hlin u)
  rw [hit, hdF, (hd2' t).deriv]
  have := hcurv x v t
  linarith

/-- The whole in-the-large chain, consumable from the curvature bound: the
argmin under a linear tilt moves at most `(1/m)`-Lipschitz in the tilt. -/
theorem argmin_lipschitz_of_line_deriv2 (g : E → ℝ) {m : ℝ} (hm : 0 < m)
    (hd1 : ∀ x v : E, Differentiable ℝ fun t : ℝ => g (x + t • v))
    (hd2 : ∀ x v : E, Differentiable ℝ (deriv fun t : ℝ => g (x + t • v)))
    (hcurv : ∀ x v : E, ∀ t : ℝ,
      m * ‖v‖ ^ 2 ≤ deriv (deriv fun s : ℝ => g (x + s • v)) t)
    (xs : E → E)
    (hxs : ∀ w y, g (xs w) + inner ℝ w (xs w) ≤ g y + inner ℝ w y) (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ :=
  argmin_lipschitz_of_strongConvexOn g hm
    (strongConvexOn_univ_of_line_deriv2 g m hd1 hd2 hcurv) xs hxs w w'

end SolverCertificate
