-- SPDX-License-Identifier: AGPL-3.0-or-later
import Mathlib.Analysis.InnerProductSpace.Basic
import Mathlib.Analysis.Normed.Module.FiniteDimension
import Mathlib.Analysis.SpecificLimits.Basic
import Mathlib.Topology.Algebra.InfiniteSum.Real
import Mathlib.Topology.Sequences

/-!
# The averaged iteration, with leaps and rescalings (admm-link.scm, federation-crossing.scm)

The federated solve steps each good with one map: the over-relaxed ADMM step of
the exchange problem (`crossing-step`, `exchange-step!`), which is the
Douglas–Rachford operator relaxed by `α ∈ (0, 2)`. Eckstein & Bertsekas (1992)
give its shape, and this file takes that shape as its setting:

    T x = (1 − θ)·x + θ·N x,      N nonexpansive,  θ = α/2 ∈ (0, 1).

Around that step the code composes three additions, and each one is a theorem
here about the same `T`:

* `#:damping η` takes the fraction `η ∈ (0, 1]` of each step. The damped step
  is the averaged operator of weight `η·θ` over the same `N`
  (`averaged_damped`), so every statement below holds for it as it stands.
* Anderson's extrapolation replaces a step by a LEAP. A run whose leaps are
  finitely many is plain from some step on, and its residual tends to zero
  (`eventually_plain_residual_tendsto_zero`); in finite dimension its iterates
  converge to a fixed point (`eventually_plain_tendsto_fixed`). A run whose
  leaps are gated by the residual they land on — the `i`-th leap lands at a
  residual of at most `c i`, with `c → 0` — has its residual tend to zero
  however many leaps it takes (`gated_leaps_residual_tendsto_zero`).
* A rescaling of ρ changes `N`. Finitely many rescalings leave a run that is
  plain under its final ρ from some step on, which is the hypothesis of
  `eventually_plain_residual_tendsto_zero` read with the final operator.

Local solves of a fixed accuracy are steps with an error; errors whose norms
sum keep the residual tending to zero (`inexact_residual_tendsto_zero`).

The engine of every statement is the Fejér inequality `averaged_fejer`: a step
brings the iterate closer to every fixed point by a multiple of the squared
residual. The residual `‖T x − x‖` is what the crossings measure (`prim`, `dual`,
the calm count), so "the residual tends to zero" reads in the code as "the
stopping test is met".
-/

namespace SolverCertificate.AveragedIteration

open Filter Topology

variable {E : Type*} [NormedAddCommGroup E] [InnerProductSpace ℝ E]

/-- A map that brings no two points further apart. -/
def Nonexpansive (N : E → E) : Prop := ∀ x y, ‖N x - N y‖ ≤ ‖x - y‖

/-- The `θ`-averaged operator over `N`: `T x = (1 − θ)·x + θ·N x`. With
`θ = α/2` and `N` the reflected Douglas–Rachford map this is `crossing-step`. -/
def averaged (θ : ℝ) (N : E → E) (x : E) : E := (1 - θ) • x + θ • N x

/-- The fixed-point residual `‖T x − x‖`: how far one step moves `x`. -/
noncomputable def residual (θ : ℝ) (N : E → E) (x : E) : ℝ := ‖averaged θ N x - x‖

theorem residual_nonneg (θ : ℝ) (N : E → E) (x : E) : 0 ≤ residual θ N x := norm_nonneg _

/-- A step moves `x` by `θ` times what `N` moves it. -/
theorem averaged_sub_self (θ : ℝ) (N : E → E) (x : E) :
    averaged θ N x - x = θ • (N x - x) := by
  simp only [averaged]
  module

/-- `T` and `N` have the same fixed points. -/
theorem averaged_fixed_iff {θ : ℝ} (hθ : θ ≠ 0) (N : E → E) (p : E) :
    averaged θ N p = p ↔ N p = p := by
  rw [← sub_eq_zero, averaged_sub_self, smul_eq_zero, sub_eq_zero]
  simp [hθ]

/-- The residual is zero exactly at the fixed points. -/
theorem residual_eq_zero_iff {θ : ℝ} (hθ : θ ≠ 0) (N : E → E) (p : E) :
    residual θ N p = 0 ↔ N p = p := by
  rw [residual, norm_eq_zero, sub_eq_zero, averaged_fixed_iff hθ]

/-- The squared norm of a weighted mean: the weighted mean of the squared norms
less `θ(1 − θ)` times the squared distance between the two points. -/
theorem norm_sq_weighted_mean (θ : ℝ) (a b : E) :
    ‖(1 - θ) • a + θ • b‖ ^ 2 =
      (1 - θ) * ‖a‖ ^ 2 + θ * ‖b‖ ^ 2 - θ * (1 - θ) * ‖a - b‖ ^ 2 := by
  rw [norm_add_sq_real, norm_sub_sq_real, norm_smul, norm_smul, real_inner_smul_left,
    real_inner_smul_right, mul_pow, mul_pow, Real.norm_eq_abs, Real.norm_eq_abs, sq_abs, sq_abs]
  ring

/-- **The Fejér inequality.** One step of an averaged operator brings `x`
closer to every fixed point `p`, by `(1 − θ)/θ` times the squared residual. -/
theorem averaged_fejer {θ : ℝ} (hθ0 : 0 < θ) (_hθ1 : θ < 1) {N : E → E} (hN : Nonexpansive N)
    {p : E} (hp : N p = p) (x : E) :
    ‖averaged θ N x - p‖ ^ 2 ≤ ‖x - p‖ ^ 2 - (1 - θ) / θ * ‖averaged θ N x - x‖ ^ 2 := by
  have h1 : averaged θ N x - p = (1 - θ) • (x - p) + θ • (N x - p) := by
    simp only [averaged]
    module
  have h2 : ‖N x - p‖ ^ 2 ≤ ‖x - p‖ ^ 2 := by
    have := hN x p
    rw [hp] at this
    exact pow_le_pow_left₀ (norm_nonneg _) this 2
  have h3 : ‖averaged θ N x - x‖ ^ 2 = θ ^ 2 * ‖(x - p) - (N x - p)‖ ^ 2 := by
    rw [averaged_sub_self, norm_smul, mul_pow, Real.norm_eq_abs, sq_abs]
    congr 2
    rw [← norm_neg]
    congr 1
    abel
  have h4 : (1 - θ) / θ * (θ ^ 2 * ‖(x - p) - (N x - p)‖ ^ 2) =
      θ * (1 - θ) * ‖(x - p) - (N x - p)‖ ^ 2 := by
    field_simp
  rw [h1, norm_sq_weighted_mean, h3, h4]
  have := mul_le_mul_of_nonneg_left h2 hθ0.le
  linarith

/-- **Damping keeps the shape.** Taking the fraction `η` of a step of the
`θ`-averaged operator is a step of the `(η·θ)`-averaged operator over the same
`N`: `exchange-step!`'s `#:damping`. -/
theorem averaged_damped (θ η : ℝ) (N : E → E) (x : E) :
    x + η • (averaged θ N x - x) = averaged (η * θ) N x := by
  simp only [averaged]
  module

/-- The damped weight `η·θ` lies in `(0, 1)` for `η ∈ (0, 1]`, `θ ∈ (0, 1)`. -/
theorem damped_weight_mem {θ η : ℝ} (hθ0 : 0 < θ) (hθ1 : θ < 1) (hη0 : 0 < η) (hη1 : η ≤ 1) :
    0 < η * θ ∧ η * θ < 1 :=
  ⟨mul_pos hη0 hθ0, by nlinarith⟩

/-- An averaged operator is nonexpansive. -/
theorem averaged_nonexpansive {θ : ℝ} (hθ0 : 0 ≤ θ) (hθ1 : θ ≤ 1) {N : E → E}
    (hN : Nonexpansive N) : Nonexpansive (averaged θ N) := by
  intro x y
  have h1 : averaged θ N x - averaged θ N y = (1 - θ) • (x - y) + θ • (N x - N y) := by
    simp only [averaged]
    module
  rw [h1]
  refine (norm_add_le _ _).trans ?_
  rw [norm_smul, norm_smul, Real.norm_eq_abs, Real.norm_eq_abs, abs_of_nonneg hθ0,
    abs_of_nonneg (by linarith : (0 : ℝ) ≤ 1 - θ)]
  have := mul_le_mul_of_nonneg_left (hN x y) hθ0
  nlinarith [norm_nonneg (x - y)]

/-- The distance to a fixed point does not grow along a step. -/
theorem averaged_dist_fixed_le {θ : ℝ} (hθ0 : 0 ≤ θ) (hθ1 : θ ≤ 1) {N : E → E}
    (hN : Nonexpansive N) {p : E} (hp : N p = p) (x : E) :
    ‖averaged θ N x - p‖ ≤ ‖x - p‖ := by
  have h := averaged_nonexpansive hθ0 hθ1 hN x p
  have hTp : averaged θ N p = p := by
    rw [← sub_eq_zero, averaged_sub_self, hp, sub_self, smul_zero]
  rwa [hTp] at h

/-- **A plain step does not raise the residual.** -/
theorem residual_antitone {θ : ℝ} (hθ0 : 0 ≤ θ) (hθ1 : θ ≤ 1) {N : E → E}
    (hN : Nonexpansive N) (x : E) :
    residual θ N (averaged θ N x) ≤ residual θ N x :=
  averaged_nonexpansive hθ0 hθ1 hN (averaged θ N x) x

/-! ### The plain iteration -/

section Plain

variable {θ : ℝ} {N : E → E} {p : E} {x : ℕ → E}

/-- Along the plain iteration the squared residuals, weighted by `(1 − θ)/θ`,
telescope against the squared distance to a fixed point. -/
theorem residual_sq_partial_sum_le (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) (hx : ∀ k, x (k + 1) = averaged θ N (x k)) (n : ℕ) :
    ∑ k ∈ Finset.range n, (1 - θ) / θ * residual θ N (x k) ^ 2 ≤
      ‖x 0 - p‖ ^ 2 - ‖x n - p‖ ^ 2 := by
  induction n with
  | zero => simp
  | succ n ih =>
    rw [Finset.sum_range_succ]
    have h := averaged_fejer hθ0 hθ1 hN hp (x n)
    rw [← hx n] at h
    have hr : residual θ N (x n) = ‖x (n + 1) - x n‖ := by rw [residual, hx n]
    rw [hr]
    linarith

/-- **The squared residuals of the plain iteration sum.** -/
theorem residual_sq_summable (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) (hx : ∀ k, x (k + 1) = averaged θ N (x k)) :
    Summable fun k => residual θ N (x k) ^ 2 := by
  have hκ : 0 < (1 - θ) / θ := div_pos (by linarith) hθ0
  refine summable_of_sum_range_le (c := ‖x 0 - p‖ ^ 2 / ((1 - θ) / θ))
    (fun k => sq_nonneg _) fun n => ?_
  rw [le_div_iff₀ hκ, mul_comm, Finset.mul_sum]
  have := residual_sq_partial_sum_le hθ0 hθ1 hN hp hx n
  have h0 : 0 ≤ ‖x n - p‖ ^ 2 := sq_nonneg _
  linarith

/-- A nonnegative sequence whose squares tend to zero tends to zero. -/
theorem tendsto_zero_of_sq_tendsto_zero {r : ℕ → ℝ} (h0 : ∀ k, 0 ≤ r k)
    (h : Tendsto (fun k => r k ^ 2) atTop (𝓝 0)) : Tendsto r atTop (𝓝 0) := by
  have h2 := (Real.continuous_sqrt.tendsto 0).comp h
  rw [Real.sqrt_zero] at h2
  refine h2.congr fun k => ?_
  simp [Function.comp, Real.sqrt_sq (h0 k)]

/-- **The residual of the plain iteration tends to zero**, whenever the
operator has a fixed point. -/
theorem residual_tendsto_zero (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) (hx : ∀ k, x (k + 1) = averaged θ N (x k)) :
    Tendsto (fun k => residual θ N (x k)) atTop (𝓝 0) :=
  tendsto_zero_of_sq_tendsto_zero (fun k => residual_nonneg θ N (x k))
    (residual_sq_summable hθ0 hθ1 hN hp hx).tendsto_atTop_zero

end Plain

/-! ### Finitely many leaps, finitely many rescalings -/

section EventuallyPlain

variable {θ : ℝ} {N : E → E} {p : E} {x : ℕ → E}

/-- **A run that is plain from some step on has its residual tend to zero.**
Whatever the first `K` steps were — Anderson leaps, steps under another ρ, a
restart from a snapshot — the run from `K` on is the plain iteration of the
final operator, started where those steps left it. -/
theorem eventually_plain_residual_tendsto_zero (hθ0 : 0 < θ) (hθ1 : θ < 1)
    (hN : Nonexpansive N) (hp : N p = p)
    (hx : ∃ K, ∀ k, K ≤ k → x (k + 1) = averaged θ N (x k)) :
    Tendsto (fun k => residual θ N (x k)) atTop (𝓝 0) := by
  obtain ⟨K, hK⟩ := hx
  have hy : ∀ k, x (k + K + 1) = averaged θ N (x (k + K)) := fun k =>
    hK (k + K) (Nat.le_add_left K k)
  have h := residual_tendsto_zero (x := fun k => x (k + K)) hθ0 hθ1 hN hp
    (fun k => by simpa [Nat.add_right_comm] using hy k)
  exact (tendsto_add_atTop_iff_nat (f := fun k => residual θ N (x k)) K).1 h

end EventuallyPlain

/-! ### Leaps gated by the residual they land on -/

section Gated

variable {θ : ℝ} {N : E → E} {p : E} {x : ℕ → E}

/-- How many of the steps `0, …, k − 1` were leaps. -/
def leapCount (leap : ℕ → Bool) : ℕ → ℕ
  | 0 => 0
  | k + 1 => leapCount leap k + if leap k then 1 else 0

theorem leapCount_mono (leap : ℕ → Bool) : Monotone (leapCount leap) :=
  monotone_nat_of_le_succ fun k => by simp [leapCount]

/-- After the first leap, the residual stands at or under the gate of the
latest leap: a leap lands there, and the plain steps that follow keep it. -/
theorem residual_le_gate (hθ0 : 0 ≤ θ) (hθ1 : θ ≤ 1) (hN : Nonexpansive N)
    {leap : ℕ → Bool} {c : ℕ → ℝ}
    (hplain : ∀ k, leap k = false → x (k + 1) = averaged θ N (x k))
    (hleap : ∀ k, leap k = true → residual θ N (x (k + 1)) ≤ c (leapCount leap k)) :
    ∀ k, 1 ≤ leapCount leap k → residual θ N (x k) ≤ c (leapCount leap k - 1) := by
  intro k
  induction k with
  | zero => intro h; simp [leapCount] at h
  | succ k ih =>
    intro h
    by_cases hl : leap k = true
    · have hc : leapCount leap (k + 1) - 1 = leapCount leap k := by simp [leapCount, hl]
      rw [hc]
      exact hleap k hl
    · have hl' : leap k = false := by simpa using hl
      have hc : leapCount leap (k + 1) = leapCount leap k := by simp [leapCount, hl']
      rw [hc] at h ⊢
      rw [hplain k hl']
      exact (residual_antitone hθ0 hθ1 hN (x k)).trans (ih h)

/-- **Gated leaps keep the residual tending to zero.** Every step is plain or a
leap; the `i`-th leap (counting from zero) lands at a residual of at most
`c i`; the gates `c` tend to zero. Then the residual of the run tends to zero,
whether its leaps are finitely many or go on for ever. -/
theorem gated_leaps_residual_tendsto_zero (hθ0 : 0 < θ) (hθ1 : θ < 1)
    (hN : Nonexpansive N) (hp : N p = p)
    {leap : ℕ → Bool} {c : ℕ → ℝ} (hc : Tendsto c atTop (𝓝 0))
    (hplain : ∀ k, leap k = false → x (k + 1) = averaged θ N (x k))
    (hleap : ∀ k, leap k = true → residual θ N (x (k + 1)) ≤ c (leapCount leap k)) :
    Tendsto (fun k => residual θ N (x k)) atTop (𝓝 0) := by
  by_cases hfin : ∃ K, ∀ k, K ≤ k → leap k = false
  · obtain ⟨K, hK⟩ := hfin
    exact eventually_plain_residual_tendsto_zero hθ0 hθ1 hN hp
      ⟨K, fun k hk => hplain k (hK k hk)⟩
  · push Not at hfin
    -- the count of leaps grows without bound
    have hunb : ∀ b, ∃ a, b ≤ leapCount leap a := by
      intro b
      induction b with
      | zero => exact ⟨0, Nat.zero_le _⟩
      | succ b ih =>
        obtain ⟨a, ha⟩ := ih
        obtain ⟨k, hk, hl⟩ := hfin a
        have hl' : leap k = true := by simpa using hl
        refine ⟨k + 1, ?_⟩
        have := leapCount_mono leap hk
        simp only [leapCount, hl', ite_true]
        omega
    have hcount : Tendsto (leapCount leap) atTop atTop :=
      tendsto_atTop_atTop_of_monotone (leapCount_mono leap) hunb
    have hpred : Tendsto (fun k => leapCount leap k - 1) atTop atTop :=
      (tendsto_sub_atTop_nat 1).comp hcount
    have hgate : Tendsto (fun k => c (leapCount leap k - 1)) atTop (𝓝 0) := hc.comp hpred
    have hev : ∀ᶠ k in atTop, residual θ N (x k) ≤ c (leapCount leap k - 1) := by
      filter_upwards [hcount.eventually_ge_atTop 1] with k hk
      exact residual_le_gate hθ0.le hθ1.le hN hplain hleap k hk
    exact tendsto_of_tendsto_of_tendsto_of_le_of_le' tendsto_const_nhds hgate
      (Eventually.of_forall fun k => residual_nonneg θ N (x k)) hev

end Gated

/-! ### Steps with an error -/

section Inexact

variable {θ : ℝ} {N : E → E} {p : E} {x : ℕ → E}

/-- **Errors whose norms sum keep the residual tending to zero.** Each step
lands `e k` away from the plain step — a local solve of finite accuracy, a
flow read from an older snapshot — and `Σ ‖e k‖` is finite. The run stays
within `‖x 0 − p‖ + Σ ‖e k‖` of every fixed point `p`, its squared residuals
sum, and its residual tends to zero. -/
theorem inexact_residual_tendsto_zero (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) {e : ℕ → E} (he : Summable fun k => ‖e k‖)
    (hx : ∀ k, x (k + 1) = averaged θ N (x k) + e k) :
    Tendsto (fun k => residual θ N (x k)) atTop (𝓝 0) := by
  set S : ℝ := ∑' k, ‖e k‖ with hS
  have hS0 : 0 ≤ S := tsum_nonneg fun k => norm_nonneg _
  have hεS : ∀ k, ‖e k‖ ≤ S := fun k => he.le_tsum k fun j _ => norm_nonneg _
  have hpart : ∀ n, ∑ k ∈ Finset.range n, ‖e k‖ ≤ S := fun n =>
    he.sum_le_tsum _ fun j _ => norm_nonneg _
  have hstep : ∀ k, ‖x (k + 1) - p‖ ≤ ‖averaged θ N (x k) - p‖ + ‖e k‖ := fun k => by
    have : x (k + 1) - p = (averaged θ N (x k) - p) + e k := by rw [hx k]; abel
    rw [this]
    exact norm_add_le _ _
  have hbound : ∀ n, ‖x n - p‖ ≤ ‖x 0 - p‖ + ∑ k ∈ Finset.range n, ‖e k‖ := by
    intro n
    induction n with
    | zero => simp
    | succ n ih =>
      rw [Finset.sum_range_succ]
      have := averaged_dist_fixed_le hθ0.le hθ1.le hN hp (x n)
      have := hstep n
      linarith
  set M : ℝ := ‖x 0 - p‖ + S with hM
  have hxM : ∀ n, ‖x n - p‖ ≤ M := fun n => (hbound n).trans (by have := hpart n; linarith)
  have hκ : 0 < (1 - θ) / θ := div_pos (by linarith) hθ0
  have hkey : ∀ k, (1 - θ) / θ * residual θ N (x k) ^ 2 ≤
      ‖x k - p‖ ^ 2 - ‖x (k + 1) - p‖ ^ 2 + (2 * M + S) * ‖e k‖ := by
    intro k
    have hfej := averaged_fejer hθ0 hθ1 hN hp (x k)
    have ht0 : 0 ≤ ‖averaged θ N (x k) - p‖ := norm_nonneg _
    have htM : ‖averaged θ N (x k) - p‖ ≤ M :=
      (averaged_dist_fixed_le hθ0.le hθ1.le hN hp (x k)).trans (hxM k)
    have hε0 : 0 ≤ ‖e k‖ := norm_nonneg _
    have hsq : ‖x (k + 1) - p‖ ^ 2 ≤ (‖averaged θ N (x k) - p‖ + ‖e k‖) ^ 2 :=
      pow_le_pow_left₀ (norm_nonneg _) (hstep k) 2
    have h1 : ‖averaged θ N (x k) - p‖ * ‖e k‖ ≤ M * ‖e k‖ :=
      mul_le_mul_of_nonneg_right htM hε0
    have h2 : ‖e k‖ * ‖e k‖ ≤ S * ‖e k‖ := mul_le_mul_of_nonneg_right (hεS k) hε0
    rw [residual]
    nlinarith
  have hsum : ∀ n, ∑ k ∈ Finset.range n, (1 - θ) / θ * residual θ N (x k) ^ 2 ≤
      ‖x 0 - p‖ ^ 2 - ‖x n - p‖ ^ 2 + (2 * M + S) * ∑ k ∈ Finset.range n, ‖e k‖ := by
    intro n
    induction n with
    | zero => simp
    | succ n ih =>
      rw [Finset.sum_range_succ, Finset.sum_range_succ]
      have := hkey n
      linarith
  have hMS : 0 ≤ 2 * M + S := by
    have : 0 ≤ ‖x 0 - p‖ := norm_nonneg _
    linarith
  have hsummable : Summable fun k => residual θ N (x k) ^ 2 := by
    refine summable_of_sum_range_le (c := (‖x 0 - p‖ ^ 2 + (2 * M + S) * S) / ((1 - θ) / θ))
      (fun k => sq_nonneg _) fun n => ?_
    rw [le_div_iff₀ hκ, mul_comm, Finset.mul_sum]
    have h1 := hsum n
    have h2 : 0 ≤ ‖x n - p‖ ^ 2 := sq_nonneg _
    have h3 := mul_le_mul_of_nonneg_left (hpart n) hMS
    linarith
  exact tendsto_zero_of_sq_tendsto_zero (fun k => residual_nonneg θ N (x k))
    hsummable.tendsto_atTop_zero

end Inexact

/-! ### The iterates converge, in finite dimension -/

section FiniteDim

variable {θ : ℝ} {N : E → E} {p : E} {x : ℕ → E}

/-- An averaged operator is continuous. -/
theorem averaged_continuous (hθ0 : 0 ≤ θ) (hθ1 : θ ≤ 1) (hN : Nonexpansive N) :
    Continuous (averaged θ N) := by
  have hL : LipschitzWith 1 (averaged θ N) :=
    LipschitzWith.of_dist_le_mul fun a b => by
      simpa [dist_eq_norm] using averaged_nonexpansive hθ0 hθ1 hN a b
  exact hL.continuous

variable [FiniteDimensional ℝ E]

/-- **The plain iteration converges to a fixed point.** -/
theorem plain_tendsto_fixed (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) (hx : ∀ k, x (k + 1) = averaged θ N (x k)) :
    ∃ q, N q = q ∧ Tendsto x atTop (𝓝 q) := by
  -- Fejér: the distance to any fixed point falls along the run
  have hfej : ∀ q, N q = q → Antitone fun k => ‖x k - q‖ := fun q hq =>
    antitone_nat_of_succ_le fun k => by
      rw [hx k]
      exact averaged_dist_fixed_le hθ0.le hθ1.le hN hq (x k)
  -- the run stays in a closed ball about p, which is compact
  have hball : ∀ k, x k ∈ Metric.closedBall p ‖x 0 - p‖ := fun k => by
    rw [Metric.mem_closedBall, dist_eq_norm]
    exact hfej p hp (Nat.zero_le k)
  obtain ⟨q, -, φ, hφ, hlim⟩ :=
    (isCompact_closedBall p ‖x 0 - p‖).tendsto_subseq hball
  -- the limit of the subsequence is a fixed point
  have hcont : Continuous fun y => residual θ N y :=
    ((averaged_continuous hθ0.le hθ1.le hN).sub continuous_id).norm
  have hres : Tendsto (fun k => residual θ N (x (φ k))) atTop (𝓝 0) :=
    (residual_tendsto_zero hθ0 hθ1 hN hp hx).comp hφ.tendsto_atTop
  have hq0 : residual θ N q = 0 :=
    tendsto_nhds_unique ((hcont.tendsto q).comp hlim) hres
  have hq : N q = q := (residual_eq_zero_iff hθ0.ne' N q).1 hq0
  refine ⟨q, hq, ?_⟩
  -- the distance to q falls, and falls to zero along the subsequence
  rw [Metric.tendsto_atTop]
  intro ε hε
  obtain ⟨k0, hk0⟩ := (Metric.tendsto_atTop.1 hlim) ε hε
  refine ⟨φ k0, fun n hn => ?_⟩
  have h1 := hk0 k0 le_rfl
  rw [dist_eq_norm] at h1 ⊢
  exact (hfej q hq hn).trans_lt h1

/-- **A run that is plain from some step on converges to a fixed point** of
its final operator: the statement for finitely many leaps and rescalings. -/
theorem eventually_plain_tendsto_fixed (hθ0 : 0 < θ) (hθ1 : θ < 1) (hN : Nonexpansive N)
    (hp : N p = p) (hx : ∃ K, ∀ k, K ≤ k → x (k + 1) = averaged θ N (x k)) :
    ∃ q, N q = q ∧ Tendsto x atTop (𝓝 q) := by
  obtain ⟨K, hK⟩ := hx
  obtain ⟨q, hq, hlim⟩ := plain_tendsto_fixed (x := fun k => x (k + K)) hθ0 hθ1 hN hp
    (fun k => by simpa [Nat.add_right_comm] using hK (k + K) (Nat.le_add_left K k))
  exact ⟨q, hq, (tendsto_add_atTop_iff_nat (f := x) K).1 hlim⟩

end FiniteDim

end SolverCertificate.AveragedIteration
