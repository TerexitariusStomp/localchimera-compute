-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.CsrCurvature

/-!
# The guard region: the smooth-branch scope, made a theorem

`CsrCurvature.lean` closes the chain from the φ″ table to ε-dominance with
scalar hypotheses taken GLOBALLY along ℝ, and its docstring names the
residue: the shipped kinds are guarded (`s > 1e-12`, `s < D`), smooth only
on open intervals, and "the solve never leaves the smooth branch" was an
engine invariant, not a theorem. This file dissolves that residue.

The guard region `R := {y | ∀ i, cᵢ + ⟪aᵢ, y⟫ ∈ Iᵢ}` — the affine preimage
of the kinds' open guard intervals — is OPEN and CONVEX
(`guardRegion_open`, `guardRegion_convex`). The whole chain is rebuilt ON
the region: a function whose every chord restriction is convex on the unit
interval is convex on a convex set (`convexOn_of_forall_segment`), line
curvature on the region gives `StrongConvexOn R`
(`strongConvexOn_of_line_deriv2_on`), strong convexity gives quadratic
growth at a region-minimiser along segments that never leave `R`
(`growth_of_strongConvexOn_region`), and two growth readings give the
`(1/m)`-Lipschitz argmin (`argmin_lipschitz_on`).

The caveat-killer is `minimizer_interior`: the guarded objective agrees
with the smooth one on `R` and some interior point beats every exterior
value (the `1e12` sentinel dominating the feasible box — a per-solve fact
the engine's fraction-to-boundary discipline maintains), so a GLOBAL
minimiser of the guarded objective lies in `R` and minimises the smooth
objective there. Composed (`argmin_lipschitz_guarded`,
`argmin_lipschitz_of_phi_table_guarded`): the φ/φ′/φ″ facts on their guard
intervals ONLY, the quadratic-form bound on the region only, the sentinel
witness — and the guarded solve's argmin is `(1/m)`-Lipschitz in the tilt.
Nothing about the smooth branch remains outside Lean; what remains is the
numeric modulus and the per-solve sentinel witness, both runtime numbers.
-/

set_option linter.unusedSectionVars false

namespace SolverCertificate

open Set

variable {E : Type*} [NormedAddCommGroup E] [InnerProductSpace ℝ E]

/-! ### 1. Convexity from chord restrictions, on a region -/

/-- A function whose restriction to EVERY chord of a convex set is convex on
the unit interval is convex on the set — the region version of
`convexOn_univ_of_forall_line`. -/
theorem convexOn_of_forall_segment {f : E → ℝ} {R : Set E} (hR : Convex ℝ R)
    (hline : ∀ x ∈ R, ∀ y ∈ R,
      ConvexOn ℝ (Icc (0:ℝ) 1) fun t : ℝ => f (x + t • (y - x))) :
    ConvexOn ℝ R f := by
  refine ⟨hR, fun x hx y hy a b ha hb hab => ?_⟩
  have h := (hline x hx y hy).2 (left_mem_Icc.mpr zero_le_one)
    (right_mem_Icc.mpr zero_le_one) ha hb hab
  simp only [smul_eq_mul, mul_zero, mul_one, zero_add, zero_smul, add_zero, one_smul] at h
  have hpt : x + b • (y - x) = a • x + b • y := by
    have : a = 1 - b := by linarith
    subst this
    module
  rw [hpt] at h
  simpa [smul_eq_mul] using h

/-- The quadratic `t ↦ m/2·‖x + t•v‖²` along a line, with its derivative
(`ModulusToStrongConvex.lean`'s private lemma, restated). -/
private theorem hasDerivAt_half_norm_line' (m : ℝ) (x v : E) (t : ℝ) :
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

/-! ### 2. Line curvature on the region ⇒ strong convexity on the region -/

/-- The region version of `strongConvexOn_univ_of_line_deriv2`: every
derivative fact is asked only WHERE THE LINE POINT LIES IN `R` — the shape
in which guarded kinds can deliver them. -/
theorem strongConvexOn_of_line_deriv2_on (g : E → ℝ) (m : ℝ) {R : Set E}
    (hR : Convex ℝ R)
    (hd1 : ∀ x v : E, ∀ t : ℝ, x + t • v ∈ R →
      DifferentiableAt ℝ (fun s : ℝ => g (x + s • v)) t)
    (hd2 : ∀ x v : E, ∀ t : ℝ, x + t • v ∈ R →
      DifferentiableAt ℝ (deriv fun s : ℝ => g (x + s • v)) t)
    (hcurv : ∀ x v : E, ∀ t : ℝ, x + t • v ∈ R →
      m * ‖v‖ ^ 2 ≤ deriv (deriv fun s : ℝ => g (x + s • v)) t) :
    StrongConvexOn R m g := by
  rw [strongConvexOn_iff_convex]
  apply convexOn_of_forall_segment hR
  intro x hx y hy
  have key : ConvexOn ℝ (Icc (0:ℝ) 1)
      fun t : ℝ => g (x + t • (y - x)) - m / 2 * ‖x + t • (y - x)‖ ^ 2 := by
    set v := y - x with hv
    have hmem : ∀ t ∈ Icc (0:ℝ) 1, x + t • v ∈ R := by
      intro t ht
      have h := hR hx hy (show (0:ℝ) ≤ 1 - t by linarith [ht.2]) ht.1
        (show (1 - t) + t = 1 by ring)
      have he : (1 - t) • x + t • y = x + t • v := by rw [hv]; module
      rwa [he] at h
    have hq : ∀ t : ℝ, HasDerivAt (fun s : ℝ => m / 2 * ‖x + s • v‖ ^ 2)
        (m * inner ℝ x v + m * ‖v‖ ^ 2 * t) t := hasDerivAt_half_norm_line' m x v
    have hlin : ∀ t : ℝ, HasDerivAt (fun s : ℝ => m * inner ℝ x v + m * ‖v‖ ^ 2 * s)
        (m * ‖v‖ ^ 2) t := by
      intro t
      have h := ((hasDerivAt_id t).const_mul (m * ‖v‖ ^ 2)).const_add (m * inner ℝ x v)
      exact h.congr_deriv (mul_one _)
    have hF' : ∀ t : ℝ, x + t • v ∈ R →
        HasDerivAt (fun s : ℝ => g (x + s • v) - m / 2 * ‖x + s • v‖ ^ 2)
          (deriv (fun s : ℝ => g (x + s • v)) t - (m * inner ℝ x v + m * ‖v‖ ^ 2 * t)) t :=
      fun t htm => ((hd1 x v t htm).hasDerivAt).sub (hq t)
    have hev : ∀ t ∈ Ioo (0:ℝ) 1,
        (deriv fun s : ℝ => g (x + s • v) - m / 2 * ‖x + s • v‖ ^ 2) =ᶠ[nhds t]
          fun s : ℝ => deriv (fun r : ℝ => g (x + r • v)) s
            - (m * inner ℝ x v + m * ‖v‖ ^ 2 * s) := by
      intro t ht
      refine Filter.eventuallyEq_of_mem (Ioo_mem_nhds ht.1 ht.2) fun s hs => ?_
      exact (hF' s (hmem s (Ioo_subset_Icc_self hs))).deriv
    have hD' : ∀ t : ℝ, x + t • v ∈ R →
        HasDerivAt (fun s : ℝ => deriv (fun r : ℝ => g (x + r • v)) s
            - (m * inner ℝ x v + m * ‖v‖ ^ 2 * s))
          (deriv (deriv fun s : ℝ => g (x + s • v)) t - m * ‖v‖ ^ 2) t :=
      fun t htm => ((hd2 x v t htm).hasDerivAt).sub (hlin t)
    refine convexOn_of_deriv2_nonneg (convex_Icc 0 1) ?_ ?_ ?_ ?_
    · intro t ht
      exact ((hF' t (hmem t ht)).differentiableAt.continuousAt).continuousWithinAt
    · rw [interior_Icc]
      intro t ht
      exact ((hF' t (hmem t (Ioo_subset_Icc_self ht))).differentiableAt).differentiableWithinAt
    · rw [interior_Icc]
      intro t ht
      exact (((hev t ht).differentiableAt_iff).mpr
        (hD' t (hmem t (Ioo_subset_Icc_self ht))).differentiableAt).differentiableWithinAt
    · rw [interior_Icc]
      intro t ht
      have hit : (deriv^[2] fun s : ℝ => g (x + s • v) - m / 2 * ‖x + s • v‖ ^ 2)
          = deriv (deriv fun s : ℝ => g (x + s • v) - m / 2 * ‖x + s • v‖ ^ 2) := by
        simp [Function.iterate_succ]
      rw [hit, (hev t ht).deriv_eq, (hD' t (hmem t (Ioo_subset_Icc_self ht))).deriv]
      have := hcurv x v t (hmem t (Ioo_subset_Icc_self ht))
      linarith
  exact key

/-! ### 3. Growth and the Lipschitz argmin, on the region -/

/-- Quadratic growth at a region-minimiser: the segment from the minimiser
to any point of the region never leaves it, so the univ proof transfers. -/
theorem growth_of_strongConvexOn_region (g : E → ℝ) {m : ℝ} (hm : 0 < m) {R : Set E}
    (hg : StrongConvexOn R m g) (w xstar : E) (hxR : xstar ∈ R)
    (hmin : ∀ y ∈ R, g xstar + inner ℝ w xstar ≤ g y + inner ℝ w y)
    {y : E} (hy : y ∈ R) :
    g xstar + inner ℝ w xstar + m / 2 * ‖y - xstar‖ ^ 2 ≤ g y + inner ℝ w y := by
  have hseg : ∀ a : ℝ, 0 < a → a ≤ 1 →
      g xstar + inner ℝ w xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2)
        ≤ g y + inner ℝ w y := by
    intro a ha ha1
    have hb : 0 ≤ 1 - a := by linarith
    have hconv := hg.2 hy hxR ha.le hb (by ring)
    simp only [smul_eq_mul] at hconv
    have hlin : inner ℝ w (a • y + (1 - a) • xstar)
        = a * inner ℝ w y + (1 - a) * inner ℝ w xstar := by
      rw [inner_add_right, inner_smul_right, inner_smul_right]
    have hmemseg : a • y + (1 - a) • xstar ∈ R := hg.1 hy hxR ha.le hb (by ring)
    have hm' := hmin _ hmemseg
    rw [hlin] at hm'
    have hmul : a * (g xstar + inner ℝ w xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2))
        ≤ a * (g y + inner ℝ w y) := by nlinarith [hconv, hm']
    exact le_of_mul_le_mul_left hmul ha
  set c := m / 2 * ‖y - xstar‖ ^ 2 with hc
  have hc0 : 0 ≤ c := by positivity
  have hd0 : 0 ≤ g y + inner ℝ w y - (g xstar + inner ℝ w xstar) := by linarith [hmin y hy]
  by_contra hlt
  push Not at hlt
  set d := g y + inner ℝ w y - (g xstar + inner ℝ w xstar) with hd
  have hdc : d < c := by linarith
  have hcpos : 0 < c := lt_of_le_of_lt hd0 hdc
  have ha : 0 < (c - d) / (2 * c) := by positivity
  have ha1 : (c - d) / (2 * c) ≤ 1 := by
    rw [div_le_one (by positivity)]; linarith
  have h := hseg _ ha ha1
  have : (1 - (c - d) / (2 * c)) * c = (c + d) / 2 := by field_simp; ring
  rw [this] at h
  linarith

/-- The Cauchy–Schwarz step of `argmin_lipschitz`, from the two growth
readings alone. -/
private theorem lipschitz_of_growth_pair {m : ℝ} (hm : 0 < m) (gx gy : ℝ)
    (w w' x₁ x₂ : E)
    (h1 : gx + inner ℝ w x₁ + m / 2 * ‖x₂ - x₁‖ ^ 2 ≤ gy + inner ℝ w x₂)
    (h2 : gy + inner ℝ w' x₂ + m / 2 * ‖x₁ - x₂‖ ^ 2 ≤ gx + inner ℝ w' x₁) :
    ‖x₁ - x₂‖ ≤ (1 / m) * ‖w - w'‖ := by
  have hd : ‖x₂ - x₁‖ = ‖x₁ - x₂‖ := norm_sub_rev _ _
  rw [hd] at h1
  have hkey : m * ‖x₁ - x₂‖ ^ 2 ≤ inner ℝ (w - w') (x₂ - x₁) := by
    rw [inner_sub_left, inner_sub_right, inner_sub_right]
    linarith
  have hcs := real_inner_le_norm (w - w') (x₂ - x₁)
  rw [norm_sub_rev x₂ x₁] at hcs
  have hmd : m * ‖x₁ - x₂‖ ^ 2 ≤ ‖w - w'‖ * ‖x₁ - x₂‖ := hkey.trans hcs
  rcases (norm_nonneg (x₁ - x₂)).lt_or_eq with hpos | hzero
  · have hstep : m * ‖x₁ - x₂‖ ≤ ‖w - w'‖ := by
      have h' : (m * ‖x₁ - x₂‖) * ‖x₁ - x₂‖ ≤ ‖w - w'‖ * ‖x₁ - x₂‖ := by
        nlinarith [hmd]
      exact le_of_mul_le_mul_right h' hpos
    rw [div_mul_eq_mul_div, one_mul, le_div_iff₀ hm]
    linarith
  · rw [← hzero]; positivity

/-- The `(1/m)`-Lipschitz argmin, entirely on the region: minimisers OVER
`R`, growth read twice. -/
theorem argmin_lipschitz_on (g : E → ℝ) {m : ℝ} (hm : 0 < m) {R : Set E}
    (hg : StrongConvexOn R m g) (xs : E → E) (hxsR : ∀ w, xs w ∈ R)
    (hxs : ∀ w : E, ∀ y ∈ R, g (xs w) + inner ℝ w (xs w) ≤ g y + inner ℝ w y)
    (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ :=
  lipschitz_of_growth_pair hm (g (xs w)) (g (xs w')) w w' (xs w) (xs w')
    (growth_of_strongConvexOn_region g hm hg w (xs w) (hxsR w) (hxs w) (hxsR w'))
    (growth_of_strongConvexOn_region g hm hg w' (xs w') (hxsR w') (hxs w') (hxsR w))

/-! ### 4. The caveat-killer: a guarded minimiser lives inside the guards -/

/-- The guarded objective agrees with the smooth one on the region, and some
interior point beats every exterior value (the sentinel `1e12` dominating
the feasible box). Then a GLOBAL minimiser of the guarded objective lies in
the region and minimises the smooth objective there — the
fraction-to-boundary invariant, as a two-line theorem. -/
theorem minimizer_interior {F f : E → ℝ} {R : Set E}
    (hin : ∀ y ∈ R, F y = f y)
    (hwit : ∃ y0 ∈ R, ∀ y, y ∉ R → F y0 < F y)
    {xstar : E} (hmin : ∀ y, F xstar ≤ F y) :
    xstar ∈ R ∧ ∀ y ∈ R, f xstar ≤ f y := by
  obtain ⟨y0, hy0, hlt⟩ := hwit
  have hxR : xstar ∈ R := by
    by_contra hx
    exact absurd (hmin y0) (not_le.mpr (hlt xstar hx))
  exact ⟨hxR, fun y hy => by rw [← hin xstar hxR, ← hin y hy]; exact hmin y⟩

/-- Composition: strong convexity on the region + guarded global minimisers
with a sentinel witness ⇒ the `(1/m)`-Lipschitz argmin. -/
theorem argmin_lipschitz_guarded (g : E → ℝ) {m : ℝ} (hm : 0 < m) {R : Set E}
    (hg : StrongConvexOn R m g) (G : E → E → ℝ) (xs : E → E)
    (hin : ∀ w : E, ∀ y ∈ R, G w y = g y + inner ℝ w y)
    (hwit : ∀ w : E, ∃ y0 ∈ R, ∀ y, y ∉ R → G w y0 < G w y)
    (hmin : ∀ w y, G w (xs w) ≤ G w y) (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ := by
  have h : ∀ ww : E, xs ww ∈ R ∧ ∀ y ∈ R,
      g (xs ww) + inner ℝ ww (xs ww) ≤ g y + inner ℝ ww y := fun ww =>
    minimizer_interior (f := fun y => g y + inner ℝ ww y) (hin ww) (hwit ww) (hmin ww)
  exact argmin_lipschitz_on g hm hg xs (fun ww => (h ww).1) (fun ww => (h ww).2) w w'

/-! ### 5. The guard region of a φ-table, and the chain from the table -/

variable {ι : Type*} [Fintype ι]

/-- Where every kind's argument satisfies its guard: the affine preimage of
the open guard intervals. -/
def guardRegion (c : ι → ℝ) (a : ι → E) (I : ι → Set ℝ) : Set E :=
  ⋂ i, (fun y => c i + inner ℝ (a i) y) ⁻¹' I i

theorem mem_guardRegion {c : ι → ℝ} {a : ι → E} {I : ι → Set ℝ} {y : E} :
    y ∈ guardRegion c a I ↔ ∀ i, c i + inner ℝ (a i) y ∈ I i := by
  simp [guardRegion]

/-- Convex guards make a convex region: the affine image of a convex
combination is the convex combination of the images. -/
theorem guardRegion_convex (c : ι → ℝ) (a : ι → E) (I : ι → Set ℝ)
    (hIc : ∀ i, Convex ℝ (I i)) : Convex ℝ (guardRegion c a I) := by
  intro x hx y hy p q hp hq hpq
  rw [mem_guardRegion] at hx hy ⊢
  intro i
  have harg : c i + inner ℝ (a i) (p • x + q • y)
      = p * (c i + inner ℝ (a i) x) + q * (c i + inner ℝ (a i) y) := by
    rw [inner_add_right, real_inner_smul_right, real_inner_smul_right]
    linear_combination (-(c i)) * hpq
  rw [harg]
  simpa [smul_eq_mul] using hIc i (hx i) (hy i) hp hq hpq

/-- Open guards make an open region: finitely many continuous preimages. -/
theorem guardRegion_open (c : ι → ℝ) (a : ι → E) (I : ι → Set ℝ)
    (hIo : ∀ i, IsOpen (I i)) : IsOpen (guardRegion c a I) :=
  isOpen_iInter_of_finite fun i =>
    (hIo i).preimage (continuous_const.add (continuous_const.inner continuous_id))

/-- One CSR row's argument along a line is affine in the parameter
(`CsrCurvature.lean`'s private lemma, restated). -/
private theorem line_arg' (c : ℝ) (a x v : E) (t : ℝ) :
    c + inner ℝ a (x + t • v) = (c + inner ℝ a x) + t * inner ℝ a v := by
  rw [inner_add_right, real_inner_smul_right]; ring

private theorem hasDerivAt_line_arg' (c : ℝ) (a x v : E) (t : ℝ) :
    HasDerivAt (fun s : ℝ => c + inner ℝ a (x + s • v)) (inner ℝ a v) t := by
  have h : HasDerivAt (fun s : ℝ => (c + inner ℝ a x) + s * inner ℝ a v)
      (inner ℝ a v) t := by
    have h0 := ((hasDerivAt_id t).mul_const (inner ℝ a v)).const_add (c + inner ℝ a x)
    exact h0.congr_deriv (by simp)
  exact h.congr_of_eventuallyEq (Filter.Eventually.of_forall fun s => line_arg' c a x v s)

private theorem hasDerivAt_sum'' {A : ι → ℝ → ℝ} {A' : ι → ℝ} {t : ℝ}
    (h : ∀ i, HasDerivAt (A i) (A' i) t) :
    HasDerivAt (fun y : ℝ => ∑ i, A i y) (∑ i, A' i) t :=
  (HasDerivAt.sum fun i _ => h i).congr_of_eventuallyEq
    (Filter.Eventually.of_forall fun y => by simp)

/-- **Strong convexity on the guard region, from guarded table facts**: each
kind's φ′/φ″ derivative facts are asked only on ITS OWN guard interval, and
the quadratic-form bound only on the region. -/
theorem strongConvexOn_of_phi_table_on (c : ι → ℝ) (a : ι → E) (I : ι → Set ℝ)
    (hIo : ∀ i, IsOpen (I i)) (hIc : ∀ i, Convex ℝ (I i))
    (φ φ' φ'' : ι → ℝ → ℝ) (m : ℝ)
    (h1 : ∀ i, ∀ r ∈ I i, HasDerivAt (φ i) (φ' i r) r)
    (h2 : ∀ i, ∀ r ∈ I i, HasDerivAt (φ' i) (φ'' i r) r)
    (hquad : ∀ y ∈ guardRegion c a I, ∀ v : E,
      m * ‖v‖ ^ 2 ≤ ∑ i, φ'' i (c i + inner ℝ (a i) y) * inner ℝ (a i) v ^ 2) :
    StrongConvexOn (guardRegion c a I) m
      fun y => ∑ i, φ i (c i + inner ℝ (a i) y) := by
  have hline1 : ∀ (x v : E) (t : ℝ), x + t • v ∈ guardRegion c a I →
      HasDerivAt (fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v)))
        (∑ i, φ' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v) t := by
    intro x v t ht
    rw [mem_guardRegion] at ht
    exact hasDerivAt_sum'' fun i =>
      (h1 i _ (ht i)).comp t (hasDerivAt_line_arg' (c i) (a i) x v t)
  have hline2 : ∀ (x v : E) (t : ℝ), x + t • v ∈ guardRegion c a I →
      HasDerivAt
        (fun s : ℝ => ∑ i, φ' i (c i + inner ℝ (a i) (x + s • v)) * inner ℝ (a i) v)
        (∑ i, φ'' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v * inner ℝ (a i) v)
        t := by
    intro x v t ht
    rw [mem_guardRegion] at ht
    exact hasDerivAt_sum'' fun i =>
      ((h2 i _ (ht i)).comp t (hasDerivAt_line_arg' (c i) (a i) x v t)).mul_const _
  have hT : ∀ x v : E, IsOpen {s : ℝ | x + s • v ∈ guardRegion c a I} :=
    fun x v => (guardRegion_open c a I hIo).preimage
      (continuous_const.add (continuous_id.smul continuous_const))
  have hev : ∀ (x v : E) (t : ℝ), x + t • v ∈ guardRegion c a I →
      (deriv fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v))) =ᶠ[nhds t]
        fun s : ℝ => ∑ i, φ' i (c i + inner ℝ (a i) (x + s • v)) * inner ℝ (a i) v := by
    intro x v t ht
    refine Filter.eventuallyEq_of_mem ((hT x v).mem_nhds ht) fun s hs => ?_
    exact (hline1 x v s hs).deriv
  apply strongConvexOn_of_line_deriv2_on _ m (guardRegion_convex c a I hIc)
  · exact fun x v t ht => (hline1 x v t ht).differentiableAt
  · intro x v t ht
    exact ((hev x v t ht).differentiableAt_iff).mpr (hline2 x v t ht).differentiableAt
  · intro x v t ht
    have heq : deriv (deriv fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v))) t
        = ∑ i, φ'' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v ^ 2 := by
      rw [(hev x v t ht).deriv_eq, (hline2 x v t ht).deriv]
      exact Finset.sum_congr rfl fun i _ => by ring
    rw [heq]
    exact hquad _ ht v

/-- **The chain, shut on the guard region**: guarded table facts, the
quadratic-form bound on the region, the sentinel witness per solve — and
the guarded solve's argmin is `(1/m)`-Lipschitz in the tilt. What remains
is numeric: the modulus, and the witness that some interior point beats the
sentinel. -/
theorem argmin_lipschitz_of_phi_table_guarded (c : ι → ℝ) (a : ι → E) (I : ι → Set ℝ)
    (hIo : ∀ i, IsOpen (I i)) (hIc : ∀ i, Convex ℝ (I i))
    (φ φ' φ'' : ι → ℝ → ℝ) {m : ℝ} (hm : 0 < m)
    (h1 : ∀ i, ∀ r ∈ I i, HasDerivAt (φ i) (φ' i r) r)
    (h2 : ∀ i, ∀ r ∈ I i, HasDerivAt (φ' i) (φ'' i r) r)
    (hquad : ∀ y ∈ guardRegion c a I, ∀ v : E,
      m * ‖v‖ ^ 2 ≤ ∑ i, φ'' i (c i + inner ℝ (a i) y) * inner ℝ (a i) v ^ 2)
    (G : E → E → ℝ) (xs : E → E)
    (hin : ∀ w : E, ∀ y ∈ guardRegion c a I,
      G w y = (∑ i, φ i (c i + inner ℝ (a i) y)) + inner ℝ w y)
    (hwit : ∀ w : E, ∃ y0 ∈ guardRegion c a I,
      ∀ y, y ∉ guardRegion c a I → G w y0 < G w y)
    (hmin : ∀ w y, G w (xs w) ≤ G w y) (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ :=
  argmin_lipschitz_guarded _ hm
    (strongConvexOn_of_phi_table_on c a I hIo hIc φ φ' φ'' m h1 h2 hquad)
    G xs hin hwit hmin w w'

end SolverCertificate
