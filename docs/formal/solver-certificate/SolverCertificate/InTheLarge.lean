-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.Emphasis
import Mathlib.Analysis.InnerProductSpace.PiL2
import Mathlib.Analysis.SpecialFunctions.Sqrt
import Mathlib.Algebra.Order.BigOperators.Ring.Finset
import Mathlib.Tactic.Linarith
import Mathlib.Tactic.Positivity
import Mathlib.Analysis.Convex.Strong

/-!
# Strategyproofness in the large
(docs/planning/truth-telling.md — "budgets and pulls govern large n";
solver.scm's strongly convex objective; emphasis.scm `emphasis-masses`)

The planner's objective is strongly convex (StrongConvexityModulus.lean
gives the modulus `m`), and a citizen's hand enters it *linearly* as the
weight vector `w` — the demand fold's twin. Two facts, each proved here,
make one person's report small in a large table:

* `argmin_lipschitz` — the minimiser of `g(x) + ⟨w, x⟩` moves at most
  `‖w − w'‖ / m` when the weights move from `w` to `w'`. Proved from the
  quadratic-growth form of strong convexity at a minimiser, and that form
  is itself proved from Mathlib's `StrongConvexOn` in
  `growth_of_strongConvexOn` (a linear term leaves the modulus alone, and
  minimality along the segment to any `y` yields the growth), so
  `argmin_lipschitz_of_strongConvexOn` needs only `m`-strong convexity of
  `g` and that `xs w` minimises `g + ⟨w, ·⟩`. What remains outside this
  file is the step from `strong_convexity_modulus_lower_bound`'s curvature
  bound on the quadratic form to `StrongConvexOn` for the barrier objective
  (the second-order characterisation, which wants `C²` on the domain).
* `weights_deviation_le` — whatever hand a citizen writes instead of their
  own, the twin moves by at most `2·W·v_p` in ℓ¹, hence in ℓ² (`hand_conserved`:
  a hand is one hand, and both the old and the new are).

Together (`deviation_gain_le`): a deviation by `p` gains at most
`L · (2·W·v_p) / m` for an `L`-Lipschitz utility — and
`epsilon_dominant_in_the_large`: for every `ε > 0` there is a voice below
which no deviation gains `ε`. This is Azevedo–Budish's "strategyproof in
the large" for this objective, from lemmas we own, with an explicit `ε`.
Read the other way it is the doc's honesty about a table of four: with
`v_p` a quarter of the table, the bound is not small, and trust is the
cheapest currency there.
-/

set_option linter.unusedSectionVars false

namespace SolverCertificate

open Finset

/-! ### 1. The argmin of a strongly convex objective is Lipschitz in a linear parameter -/

variable {E : Type*} [NormedAddCommGroup E] [InnerProductSpace ℝ E]

/-- For `f_w(x) = g(x) + ⟨w, x⟩` with quadratic growth `m/2·‖y − x*‖²` at its
minimiser `x* = xs w` (what `m`-strong convexity gives at an argmin), the
minimiser is `(1/m)`-Lipschitz in `w`. -/
theorem argmin_lipschitz (g : E → ℝ) {m : ℝ} (hm : 0 < m) (xs : E → E)
    (hgrowth : ∀ w y, g (xs w) + inner ℝ w (xs w) + m / 2 * ‖y - xs w‖ ^ 2 ≤ g y + inner ℝ w y)
    (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ := by
  have h1 := hgrowth w (xs w')
  have h2 := hgrowth w' (xs w)
  have hd : ‖xs w' - xs w‖ = ‖xs w - xs w'‖ := norm_sub_rev _ _
  rw [hd] at h1
  have hkey : m * ‖xs w - xs w'‖ ^ 2 ≤ inner ℝ (w - w') (xs w' - xs w) := by
    rw [inner_sub_left, inner_sub_right, inner_sub_right]
    linarith
  have hcs := real_inner_le_norm (w - w') (xs w' - xs w)
  rw [hd] at hcs
  have hmd : m * ‖xs w - xs w'‖ ^ 2 ≤ ‖w - w'‖ * ‖xs w - xs w'‖ := hkey.trans hcs
  rcases (norm_nonneg (xs w - xs w')).lt_or_eq with hpos | hzero
  · have : m * ‖xs w - xs w'‖ ≤ ‖w - w'‖ := by
      have h' : (m * ‖xs w - xs w'‖) * ‖xs w - xs w'‖ ≤ ‖w - w'‖ * ‖xs w - xs w'‖ := by
        nlinarith [hmd]
      exact le_of_mul_le_mul_right h' hpos
    rw [div_mul_eq_mul_div, one_mul, le_div_iff₀ hm]
    linarith
  · rw [← hzero]; positivity

/-- **Strong convexity gives quadratic growth at a minimiser.** If `g` is
`m`-strongly convex (Mathlib's `StrongConvexOn`, on the whole space) and `x*`
minimises `h = g + ⟨w, ·⟩`, then `h x* + m/2·‖y − x*‖² ≤ h y` for every `y`.
The linear term does not change the modulus; minimality along the segment
from `x*` toward `y` at every parameter `a ∈ (0, 1]` gives
`h x* + (1 − a)·m/2·‖y − x*‖² ≤ h y`, and `a` can be taken as small as the
gap demands. -/
theorem growth_of_strongConvexOn (g : E → ℝ) {m : ℝ} (hm : 0 < m)
    (hg : StrongConvexOn Set.univ m g) (w xstar : E)
    (hmin : ∀ y, g xstar + inner ℝ w xstar ≤ g y + inner ℝ w y) (y : E) :
    g xstar + inner ℝ w xstar + m / 2 * ‖y - xstar‖ ^ 2 ≤ g y + inner ℝ w y := by
  -- the segment inequality, for every a ∈ (0, 1]
  have hseg : ∀ a : ℝ, 0 < a → a ≤ 1 →
      g xstar + inner ℝ w xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2) ≤ g y + inner ℝ w y := by
    intro a ha ha1
    have hb : 0 ≤ 1 - a := by linarith
    have hconv := hg.2 (Set.mem_univ y) (Set.mem_univ xstar) ha.le hb (by ring)
    simp only [smul_eq_mul] at hconv
    have hlin : inner ℝ w (a • y + (1 - a) • xstar) = a * inner ℝ w y + (1 - a) * inner ℝ w xstar := by
      rw [inner_add_right, inner_smul_right, inner_smul_right]
    have hm' := hmin (a • y + (1 - a) • xstar)
    rw [hlin] at hm'
    -- a·h x* ≤ a·h y − a(1−a)·(m/2)D, then divide by a
    have hmul : a * (g xstar + inner ℝ w xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2))
        ≤ a * (g y + inner ℝ w y) := by nlinarith [hconv, hm']
    exact le_of_mul_le_mul_left hmul ha
  -- pass to a → 0: the gap d = h y − h x* is ≥ (1 − a)·c for every a; if d < c pick a with (1−a)c > d
  set c := m / 2 * ‖y - xstar‖ ^ 2 with hc
  have hc0 : 0 ≤ c := by positivity
  have hd0 : 0 ≤ g y + inner ℝ w y - (g xstar + inner ℝ w xstar) := by linarith [hmin y]
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

/-- `argmin_lipschitz` with its growth hypothesis discharged: `m`-strong
convexity of `g` and `xs w` minimising `g + ⟨w, ·⟩` suffice. -/
theorem argmin_lipschitz_of_strongConvexOn (g : E → ℝ) {m : ℝ} (hm : 0 < m)
    (hg : StrongConvexOn Set.univ m g) (xs : E → E)
    (hxs : ∀ w y, g (xs w) + inner ℝ w (xs w) ≤ g y + inner ℝ w y) (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ :=
  argmin_lipschitz g hm xs (fun w y => growth_of_strongConvexOn g hm hg w (xs w) (hxs w) y) w w'

/-- An `L`-Lipschitz utility gains at most `L/m · ‖w' − w‖` from moving the
weights, given a `(1/m)`-Lipschitz argmin. -/
theorem gain_le_of_lipschitz (u : E → ℝ) {L : ℝ} (hL0 : 0 ≤ L)
    (hL : ∀ x y, u x - u y ≤ L * ‖x - y‖) (xs : E → E) {m : ℝ}
    (hLip : ∀ w w', ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖) (w w' : E) :
    u (xs w') - u (xs w) ≤ L * ((1 / m) * ‖w' - w‖) :=
  (hL _ _).trans (mul_le_mul_of_nonneg_left (hLip w' w) hL0)

/-! ### 2. One hand moves the twin by at most twice itself -/

variable {ι σ : Type*} [Fintype ι] [DecidableEq σ]

/-- The Euclidean norm is at most the ℓ¹ norm. -/
theorem euclid_norm_le_sum_abs (x : EuclideanSpace ℝ ι) : ‖x‖ ≤ ∑ i, |x i| := by
  rw [EuclideanSpace.norm_eq]
  have h1 : ∑ i, ‖x i‖ ^ 2 ≤ (∑ i, ‖x i‖) ^ 2 :=
    Finset.sum_sq_le_sq_sum_of_nonneg fun i _ => norm_nonneg _
  have h2 : ∑ i, ‖x i‖ = ∑ i, |x i| := Finset.sum_congr rfl fun i _ => Real.norm_eq_abs _
  calc √(∑ i, ‖x i‖ ^ 2) ≤ √((∑ i, ‖x i‖) ^ 2) := Real.sqrt_le_sqrt h1
    _ = ∑ i, ‖x i‖ := Real.sqrt_sq (Finset.sum_nonneg fun i _ => norm_nonneg _)
    _ = ∑ i, |x i| := h2

theorem share_nonneg {K : Finset ι} {h : ι → ℝ} (hh : ∀ k ∈ K, 0 ≤ h k) {k : ι}
    (hk : k ∈ K) : 0 ≤ share K h k := by
  unfold share
  split_ifs with hpos
  · exact div_nonneg (hh k hk) hpos.le
  · exact le_rfl

theorem mass_nonneg {W v : ℝ} (hW : 0 ≤ W) (hv : 0 ≤ v) {K : Finset ι} {h : ι → ℝ}
    (hh : ∀ k ∈ K, 0 ≤ h k) {k : ι} (hk : k ∈ K) : 0 ≤ mass W v K h k :=
  mul_nonneg (mul_nonneg hW hv) (share_nonneg hh hk)

/-- A hand's masses sum to at most `W·v` — exactly `W·v` when something was
stated (`hand_conserved`), zero when nothing was. -/
theorem sum_mass_le {W v : ℝ} (hW : 0 ≤ W) (hv : 0 ≤ v) {K : Finset ι} {h : ι → ℝ} :
    ∑ k ∈ K, mass W v K h k ≤ W * v := by
  by_cases hpos : 0 < ∑ j ∈ K, h j
  · exact (hand_conserved W v hpos).le
  · have : ∀ k ∈ K, mass W v K h k = 0 := fun k _ => by
      simp [mass, share, hpos]
    rw [Finset.sum_eq_zero this]
    exact mul_nonneg hW hv

/-- The twin over every key as a Euclidean weight vector: what the
solver's objective reads. -/
noncomputable def weights (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) (O : Finset σ) :
    EuclideanSpace ℝ ι :=
  WithLp.toLp 2 (fun k => twin W v f O Finset.univ k)

/-- Replacing `p`'s hand `f p` by any `h'` moves the weight vector by at
most `2·W·v_p`: the old hand and the new are each one hand. -/
theorem weights_deviation_le (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {O : Finset σ}
    {p : σ} (hp : p ∈ O) (h' : ι → ℝ) (hW : 0 ≤ W) (hv : 0 ≤ v p)
    (hf : ∀ k, 0 ≤ f p k) (hh' : ∀ k, 0 ≤ h' k) :
    ‖weights W v (Function.update f p h') O - weights W v f O‖ ≤ 2 * W * v p := by
  refine (euclid_norm_le_sum_abs _).trans ?_
  have hpt : ∀ k, (weights W v (Function.update f p h') O - weights W v f O) k
      = mass W (v p) Finset.univ h' k - mass W (v p) Finset.univ (f p) k := by
    intro k
    simp only [weights, PiLp.sub_apply]
    rw [apply_reread_agree W v f hp h' Finset.univ k]
    ring
  have hbound : ∀ k, |mass W (v p) Finset.univ h' k - mass W (v p) Finset.univ (f p) k|
      ≤ mass W (v p) Finset.univ h' k + mass W (v p) Finset.univ (f p) k := by
    intro k
    have a := mass_nonneg hW hv (fun k _ => hh' k) (Finset.mem_univ k)
    have b := mass_nonneg hW hv (fun k _ => hf k) (Finset.mem_univ k)
    rw [abs_le]; constructor <;> linarith
  calc ∑ k, |(weights W v (Function.update f p h') O - weights W v f O) k|
      = ∑ k, |mass W (v p) Finset.univ h' k - mass W (v p) Finset.univ (f p) k| :=
        Finset.sum_congr rfl fun k _ => by rw [hpt k]
    _ ≤ ∑ k, (mass W (v p) Finset.univ h' k + mass W (v p) Finset.univ (f p) k) :=
        Finset.sum_le_sum fun k _ => hbound k
    _ = ∑ k, mass W (v p) Finset.univ h' k + ∑ k, mass W (v p) Finset.univ (f p) k :=
        Finset.sum_add_distrib
    _ ≤ W * v p + W * v p := add_le_add (sum_mass_le hW hv) (sum_mass_le hW hv)
    _ = 2 * W * v p := by ring

/-! ### 3. In the large, no lie is worth much -/

/-- **A deviation's gain is bounded by the deviator's own voice.** With the
solver's argmin `(1/m)`-Lipschitz in the weights and an `L`-Lipschitz
utility, any hand `p` writes instead of their own gains at most
`L · (2·W·v_p) / m`. -/
theorem deviation_gain_le (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {O : Finset σ}
    {p : σ} (hp : p ∈ O) (h' : ι → ℝ) (hW : 0 ≤ W) (hv : 0 ≤ v p)
    (hf : ∀ k, 0 ≤ f p k) (hh' : ∀ k, 0 ≤ h' k)
    (u : EuclideanSpace ℝ ι → ℝ) {L : ℝ} (hL0 : 0 ≤ L)
    (hL : ∀ x y, u x - u y ≤ L * ‖x - y‖)
    (xs : EuclideanSpace ℝ ι → EuclideanSpace ℝ ι) {m : ℝ} (hm : 0 < m)
    (hLip : ∀ w w', ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖) :
    u (xs (weights W v (Function.update f p h') O)) - u (xs (weights W v f O))
      ≤ L * ((1 / m) * (2 * W * v p)) := by
  refine (gain_le_of_lipschitz u hL0 hL xs hLip _ _).trans ?_
  apply mul_le_mul_of_nonneg_left _ hL0
  apply mul_le_mul_of_nonneg_left _ (by positivity)
  exact weights_deviation_le W v f hp h' hW hv hf hh'

/-- `deviation_gain_le` from the objective itself: `g` `m`-strongly convex and
`xs` its argmin map, no Lipschitz hypothesis on `xs`. -/
theorem deviation_gain_le_of_strongConvexOn (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {O : Finset σ}
    {p : σ} (hp : p ∈ O) (h' : ι → ℝ) (hW : 0 ≤ W) (hv : 0 ≤ v p)
    (hf : ∀ k, 0 ≤ f p k) (hh' : ∀ k, 0 ≤ h' k)
    (u : EuclideanSpace ℝ ι → ℝ) {L : ℝ} (hL0 : 0 ≤ L)
    (hL : ∀ x y, u x - u y ≤ L * ‖x - y‖)
    (g : EuclideanSpace ℝ ι → ℝ) {m : ℝ} (hm : 0 < m) (hg : StrongConvexOn Set.univ m g)
    (xs : EuclideanSpace ℝ ι → EuclideanSpace ℝ ι)
    (hxs : ∀ w y, g (xs w) + inner ℝ w (xs w) ≤ g y + inner ℝ w y) :
    u (xs (weights W v (Function.update f p h') O)) - u (xs (weights W v f O))
      ≤ L * ((1 / m) * (2 * W * v p)) :=
  deviation_gain_le W v f hp h' hW hv hf hh' u hL0 hL xs hm
    (argmin_lipschitz_of_strongConvexOn g hm hg xs hxs)

/-- **ε-dominance in the large.** For every `ε > 0` there is a voice `δ`
below which no deviation by `p` gains more than `ε`. -/
theorem epsilon_dominant_in_the_large (W : ℝ) (hWpos : 0 < W) {L : ℝ} (hLpos : 0 < L)
    {m : ℝ} (hm : 0 < m) (ε : ℝ) (hε : 0 < ε) :
    ∃ δ > 0, ∀ (v : σ → ℝ) (f : σ → ι → ℝ) (O : Finset σ) (p : σ), p ∈ O → v p ≤ δ →
      0 ≤ v p → (∀ k, 0 ≤ f p k) →
      ∀ (h' : ι → ℝ), (∀ k, 0 ≤ h' k) →
      ∀ (u : EuclideanSpace ℝ ι → ℝ), (∀ x y, u x - u y ≤ L * ‖x - y‖) →
      ∀ (xs : EuclideanSpace ℝ ι → EuclideanSpace ℝ ι),
        (∀ w w', ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖) →
        u (xs (weights W v (Function.update f p h') O)) - u (xs (weights W v f O)) ≤ ε := by
  refine ⟨ε * m / (2 * L * W), by positivity, ?_⟩
  intro v f O p hp hδ hv hf h' hh' u hL xs hLip
  refine (deviation_gain_le W v f hp h' hWpos.le hv hf hh' u hLpos.le hL xs hm hLip).trans ?_
  have : L * ((1 / m) * (2 * W * v p)) = (2 * L * W / m) * v p := by
    field_simp
  rw [this]
  calc (2 * L * W / m) * v p ≤ (2 * L * W / m) * (ε * m / (2 * L * W)) :=
        mul_le_mul_of_nonneg_left hδ (by positivity)
    _ = ε := by field_simp

/-- `epsilon_dominant_in_the_large` from the objective itself: the argmin's
Lipschitz bound is derived from `m`-strong convexity of `g`. -/
theorem epsilon_dominant_in_the_large_of_strongConvexOn (W : ℝ) (hWpos : 0 < W) {L : ℝ}
    (hLpos : 0 < L) (g : EuclideanSpace ℝ ι → ℝ) {m : ℝ} (hm : 0 < m)
    (hg : StrongConvexOn Set.univ m g)
    (xs : EuclideanSpace ℝ ι → EuclideanSpace ℝ ι)
    (hxs : ∀ w y, g (xs w) + inner ℝ w (xs w) ≤ g y + inner ℝ w y)
    (ε : ℝ) (hε : 0 < ε) :
    ∃ δ > 0, ∀ (v : σ → ℝ) (f : σ → ι → ℝ) (O : Finset σ) (p : σ), p ∈ O → v p ≤ δ →
      0 ≤ v p → (∀ k, 0 ≤ f p k) →
      ∀ (h' : ι → ℝ), (∀ k, 0 ≤ h' k) →
      ∀ (u : EuclideanSpace ℝ ι → ℝ), (∀ x y, u x - u y ≤ L * ‖x - y‖) →
        u (xs (weights W v (Function.update f p h') O)) - u (xs (weights W v f O)) ≤ ε := by
  obtain ⟨δ, hδ, hall⟩ := epsilon_dominant_in_the_large (σ := σ) (ι := ι) W hWpos hLpos hm ε hε
  exact ⟨δ, hδ, fun v f O p hp hvδ hv hf h' hh' u hL =>
    hall v f O p hp hvδ hv hf h' hh' u hL xs (argmin_lipschitz_of_strongConvexOn g hm hg xs hxs)⟩

/-! ### 4. Rigor audit (2026-09): what the linear-tilt model silently assumed

`argmin_lipschitz` and everything built on it models a citizen's rewrite as
an ADDITIVE LINEAR perturbation `⟨w, x⟩` of the objective, `x` ranging over
the SAME space the weights live in. The engine's actual perturbation is not
that: a desire or cap term is `w_d · Φ_d(x)` for a *nonlinear* `Φ_d` (a
squared gap, a `1/(1+s/c)` cap curve) composed with the true decision
vector — linear IN `w`, but `Φ` is not the identity on `x`. Section 4
proves the honest general statement and names the extra factor the
identity-`Φ` model hid: the term map's own Lipschitz constant. Section 5
answers the companion question (the certificate measures an ε-KKT point,
never an exact one): how far a solved-to-tolerance point can sit from the
true optimum, in the same currency (`m`-strong convexity) already paying
for the radius above — closing the gap between every exactness hypothesis
in `QuantityAsCap.lean`/`CrossCell.lean` and what a real solve delivers. -/

variable {F : Type*} [NormedAddCommGroup F] [InnerProductSpace ℝ F]

/-- **Quadratic growth at a minimiser, for the objective as a whole** — no
`g + linear` split assumed. `argmin_lipschitz`'s growth hypothesis is the
special case `F = g + ⟨w, ·⟩`; this is what actually licenses it, and it is
what a reweighted nonlinear term needs instead. -/
theorem growth_of_strongConvexOn_general (F' : E → ℝ) {m : ℝ} (hm : 0 < m)
    (hF : StrongConvexOn Set.univ m F') (xstar : E)
    (hmin : ∀ y, F' xstar ≤ F' y) (y : E) :
    F' xstar + m / 2 * ‖y - xstar‖ ^ 2 ≤ F' y := by
  have hseg : ∀ a : ℝ, 0 < a → a ≤ 1 →
      F' xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2) ≤ F' y := by
    intro a ha ha1
    have hb : 0 ≤ 1 - a := by linarith
    have hconv := hF.2 (Set.mem_univ y) (Set.mem_univ xstar) ha.le hb (by ring)
    simp only [smul_eq_mul] at hconv
    have hm' := hmin (a • y + (1 - a) • xstar)
    have hmul : a * (F' xstar + (1 - a) * (m / 2 * ‖y - xstar‖ ^ 2)) ≤ a * F' y := by
      nlinarith [hconv, hm']
    exact le_of_mul_le_mul_left hmul ha
  set c := m / 2 * ‖y - xstar‖ ^ 2 with hc
  have hc0 : 0 ≤ c := by positivity
  have hd0 : 0 ≤ F' y - F' xstar := by linarith [hmin y]
  by_contra hlt
  push Not at hlt
  set d := F' y - F' xstar with hd
  have hdc : d < c := by linarith
  have hcpos : 0 < c := lt_of_le_of_lt hd0 hdc
  have ha : 0 < (c - d) / (2 * c) := by positivity
  have ha1 : (c - d) / (2 * c) ≤ 1 := by rw [div_le_one (by positivity)]; linarith
  have h := hseg _ ha ha1
  have heq : (1 - (c - d) / (2 * c)) * c = (c + d) / 2 := by field_simp; ring
  rw [heq] at h
  linarith

/-- **The honest honesty-radius: a reweighted nonlinear term is
`(Lphi/m)`-Lipschitz, not `(1/m)`-Lipschitz.** The real perturbed objective
is `h x + ⟪w, Φ x⟫` for a term map `Φ` (the demand fold's per-dimension
pulls) that need not be the identity; if `Φ` is `Lphi`-Lipschitz and the
tilted objective stays `m`-strongly convex for every weight in play, the
argmin moves at most `Lphi/m` per unit of weight change — `argmin_lipschitz`
is the special case `Φ = id`, `Lphi = 1`. -/
theorem argmin_lipschitz_weighted_term
    (h : E → ℝ) (Φ : E → F) {Lphi : ℝ} (hLphi0 : 0 ≤ Lphi)
    (hLphi : ∀ x y : E, ‖Φ x - Φ y‖ ≤ Lphi * ‖x - y‖)
    (xs : F → E) {m : ℝ} (hm : 0 < m)
    (hFw : ∀ w : F, StrongConvexOn Set.univ m (fun x => h x + inner ℝ w (Φ x)))
    (hxs : ∀ w : F, ∀ y : E, h (xs w) + inner ℝ w (Φ (xs w)) ≤ h y + inner ℝ w (Φ y))
    (w w' : F) :
    ‖xs w - xs w'‖ ≤ (Lphi / m) * ‖w - w'‖ := by
  have g1 := growth_of_strongConvexOn_general (fun x => h x + inner ℝ w (Φ x)) hm
    (hFw w) (xs w) (hxs w) (xs w')
  have g2 := growth_of_strongConvexOn_general (fun x => h x + inner ℝ w' (Φ x)) hm
    (hFw w') (xs w') (hxs w') (xs w)
  have hd : ‖xs w' - xs w‖ = ‖xs w - xs w'‖ := norm_sub_rev _ _
  rw [hd] at g1
  have hkey : m * ‖xs w - xs w'‖ ^ 2 ≤
      inner ℝ (w - w') (Φ (xs w') - Φ (xs w)) := by
    have hcomb : inner ℝ w (Φ (xs w')) - inner ℝ w (Φ (xs w))
          + (inner ℝ w' (Φ (xs w)) - inner ℝ w' (Φ (xs w')))
        = inner ℝ (w - w') (Φ (xs w') - Φ (xs w)) := by
      rw [inner_sub_left, inner_sub_right, inner_sub_right]; ring
    rw [← hcomb]; linarith
  have hcs : inner ℝ (w - w') (Φ (xs w') - Φ (xs w))
      ≤ ‖w - w'‖ * ‖Φ (xs w') - Φ (xs w)‖ := real_inner_le_norm _ _
  have hlip : ‖Φ (xs w') - Φ (xs w)‖ ≤ Lphi * ‖xs w - xs w'‖ := by
    have := hLphi (xs w') (xs w); rwa [hd] at this
  have hmd : m * ‖xs w - xs w'‖ ^ 2 ≤ ‖w - w'‖ * (Lphi * ‖xs w - xs w'‖) :=
    hkey.trans (hcs.trans (mul_le_mul_of_nonneg_left hlip (norm_nonneg _)))
  rcases (norm_nonneg (xs w - xs w')).lt_or_eq with hpos | hzero
  · have h' : (m * ‖xs w - xs w'‖) * ‖xs w - xs w'‖
        ≤ (Lphi * ‖w - w'‖) * ‖xs w - xs w'‖ := by nlinarith [hmd]
    have hle : m * ‖xs w - xs w'‖ ≤ Lphi * ‖w - w'‖ := le_of_mul_le_mul_right h' hpos
    rw [div_mul_eq_mul_div, le_div_iff₀ hm]; linarith
  · rw [← hzero]; positivity

/-! ### 5. How far a solved-to-tolerance point sits from the true optimum -/

/-- **The certified point's distance from the exact optimum.** If `x` is
within value-gap `G` of an `m`-strongly convex objective's minimum, it sits
within `√(2G/m)` of the true minimiser — the argument-space reading of
the certificate's own value-space gap. -/
theorem dist_from_optimum_of_gap (F' : E → ℝ) {m : ℝ} (hm : 0 < m)
    (hF : StrongConvexOn Set.univ m F') (xstar : E) (hmin : ∀ y, F' xstar ≤ F' y)
    (x : E) {G : ℝ} (hG : F' x - F' xstar ≤ G) :
    ‖x - xstar‖ ≤ Real.sqrt (2 * G / m) := by
  have hgrowth := growth_of_strongConvexOn_general F' hm hF xstar hmin x
  have h3 : ‖x - xstar‖ ^ 2 ≤ 2 * G / m := by rw [le_div_iff₀ hm]; linarith
  calc ‖x - xstar‖ = Real.sqrt (‖x - xstar‖ ^ 2) := (Real.sqrt_sq (norm_nonneg _)).symm
    _ ≤ Real.sqrt (2 * G / m) := Real.sqrt_le_sqrt h3

/-- **The certificate's own `dist-curvature` bound, transported to argument
space.** `suboptimality_bound_curvature` (`DistCurvature.lean`) bounds the
VALUE gap by `‖r‖²/(2σ)`; feeding that `G` in gives the argument-space
distance in its simplest form, `‖r‖/σ` — exactly the residual any
dominance or inertness claim proved for the exact program picks up when
run against a real, ε-KKT solve. This is the same apparatus that sizes
the honesty radius, read once more: `σ` sizes how far the plan may be
pushed by a lie, and, composed here, how far the CERTIFICATE's own
optimality tolerance may already have pushed it before anyone lied. -/
theorem dist_from_optimum_of_curvature_gap (F' : E → ℝ) {σ : ℝ} (hσ : 0 < σ)
    (hF : StrongConvexOn Set.univ σ F') (xstar : E) (hmin : ∀ y, F' xstar ≤ F' y)
    (x : E) {r : ℝ} (hr0 : 0 ≤ r) (hG : F' x - F' xstar ≤ r ^ 2 / (2 * σ)) :
    ‖x - xstar‖ ≤ r / σ := by
  have h := dist_from_optimum_of_gap F' hσ hF xstar hmin x hG
  have heq : 2 * (r ^ 2 / (2 * σ)) / σ = (r / σ) ^ 2 := by field_simp
  rw [heq, Real.sqrt_sq (by positivity)] at h
  exact h

end SolverCertificate
