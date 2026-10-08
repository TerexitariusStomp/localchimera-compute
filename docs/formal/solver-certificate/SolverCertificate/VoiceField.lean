import Mathlib.Algebra.BigOperators.Group.Finset.Basic
import Mathlib.Algebra.BigOperators.Field
import Mathlib.Algebra.Order.Field.Basic
import Mathlib.Algebra.Order.BigOperators.Group.Finset
import Mathlib.Data.Real.Basic
import Mathlib.Tactic.Ring
import Mathlib.Tactic.Positivity
import SolverCertificate.Emphasis

/-!
# The voice field is bounded, and a statement about what leaves nothing
(voice-field.scm: `hand-portions`, `stance-masses`, `pushes-of`,
`raw-on-columns`, `centred-stances`, `warp`; engine.scm: the labform hook)

`docs/planning/voice/voice-in-lean.md`, file 1. The objects, as the Scheme has
them:

    h p π       validated hours of person `p` in part `π`'s cell
    share p π   h p π / Σ_q h q π                      (Emphasis.share)
    push π      Σ_p a p π · share p π                  a p π ∈ [−1, 1]
    raw c       Σ_{π covers c} push π
    stance c    clamp(raw c − ref c, −1, 1)
    warp w c    w c · (1 − τ · stance c)                0 ≤ τ < 1

What is proved:

* `abs_push_le_one` (theorem 2) — a part's push lies in [−1, 1] whenever every
  portion does: the shares sum to one, so the push is a convex combination of
  the portions.
* `person_push_le` (theorem 1) — one person's contribution to a column's raw
  is at most Σ_{π covers c} |a p π| · share p π.
* `warp_mem` (theorem 3) — `(1 − τ)·w ≤ warp ≤ (1 + τ)·w`, and `0 < warp` when
  `0 < w`: every column stays felt, no direction becomes costless.
* `what_statement_cancels` (theorem 5a) — a raw of the form `Σ_g into c g · μ g`
  (a statement laid on every way of each good in proportion to how much of
  the column's hours go into it) is exactly removed by centring: with `λ = μ`
  the centred stance is zero on every column.
* `felt_equals_clock` (theorem 5c) — at the worked mix, for any `λ` solving the
  normal equations, Σ_c worked c · into c g · stance c = 0 for every good `g`
  while no clamp binds: a good's felt hours equal its clock hours.
-/

namespace SolverCertificate.VoiceField

open Finset

variable {σ P ι γ : Type*} [DecidableEq σ] [DecidableEq P]

/-! ### The push of a part -/

/-- `pushes-of`: portions weighed by shares of the part's hours. -/
noncomputable def push (S : Finset σ) (h : σ → ℝ) (a : σ → ℝ) : ℝ :=
  ∑ p ∈ S, a p * share S h p

theorem share_nonneg (S : Finset σ) (h : σ → ℝ) (hh : ∀ p, 0 ≤ h p) (p : σ) :
    0 ≤ share S h p := by
  unfold share
  split_ifs with hs
  · exact div_nonneg (hh p) hs.le
  · exact le_rfl

theorem share_sum_le_one (S : Finset σ) (h : σ → ℝ) (hh : ∀ p, 0 ≤ h p) :
    ∑ p ∈ S, share S h p ≤ 1 := by
  unfold share
  split_ifs with hs
  · rw [← Finset.sum_div, div_le_one hs]
  · simp

/-- Theorem 2 `abs_push_le_one`. -/
theorem abs_push_le_one (S : Finset σ) (h : σ → ℝ) (a : σ → ℝ)
    (hh : ∀ p, 0 ≤ h p) (ha : ∀ p, |a p| ≤ 1) : |push S h a| ≤ 1 := by
  unfold push
  calc |∑ p ∈ S, a p * share S h p|
      ≤ ∑ p ∈ S, |a p * share S h p| := Finset.abs_sum_le_sum_abs _ _
    _ = ∑ p ∈ S, |a p| * share S h p := by
        refine Finset.sum_congr rfl fun p _ => ?_
        rw [abs_mul, abs_of_nonneg (share_nonneg S h hh p)]
    _ ≤ ∑ p ∈ S, 1 * share S h p := by
        refine Finset.sum_le_sum fun p _ => ?_
        exact mul_le_mul_of_nonneg_right (ha p) (share_nonneg S h hh p)
    _ = ∑ p ∈ S, share S h p := by simp
    _ ≤ 1 := share_sum_le_one S h hh

/-! ### One person on one column -/

/-- Theorem 1 `person_push_le`: a person's contribution to a column's raw,
summed over the parts covering it. -/
theorem person_push_le (Π : Finset P) (a : P → ℝ) (s : P → ℝ) (hs : ∀ π, 0 ≤ s π) :
    |∑ π ∈ Π, a π * s π| ≤ ∑ π ∈ Π, |a π| * s π := by
  calc |∑ π ∈ Π, a π * s π|
      ≤ ∑ π ∈ Π, |a π * s π| := Finset.abs_sum_le_sum_abs _ _
    _ = ∑ π ∈ Π, |a π| * s π := by
        refine Finset.sum_congr rfl fun π _ => ?_
        rw [abs_mul, abs_of_nonneg (hs π)]

/-! ### The warp is bounded -/

/-- `stance`: the clamp to [−1, 1]. -/
noncomputable def stance (x : ℝ) : ℝ := max (-1) (min 1 x)

/-- `warp`. -/
noncomputable def warp (τ w x : ℝ) : ℝ := w * (1 - τ * stance x)

theorem stance_mem (x : ℝ) : -1 ≤ stance x ∧ stance x ≤ 1 := by
  unfold stance
  constructor
  · exact le_max_left _ _
  · exact max_le (by norm_num) (min_le_left _ _)

/-- Theorem 3 `warp_mem`. -/
theorem warp_mem (τ w x : ℝ) (hτ0 : 0 ≤ τ) (hτ1 : τ < 1) (hw : 0 < w) :
    (1 - τ) * w ≤ warp τ w x ∧ warp τ w x ≤ (1 + τ) * w ∧ 0 < warp τ w x := by
  obtain ⟨hlo, hhi⟩ := stance_mem x
  unfold warp
  have h1 : τ * stance x ≤ τ := by nlinarith
  have h2 : -τ ≤ τ * stance x := by nlinarith
  refine ⟨?_, ?_, ?_⟩
  · nlinarith
  · nlinarith
  · have : 0 < 1 - τ * stance x := by linarith
    positivity

/-! ### Centring: a statement about goods leaves nothing -/

/-- The centred stance before the clamp: `raw c − Σ_g into c g · λ g`. -/
noncomputable def centred (G : Finset γ) (raw : ι → ℝ) (into : ι → γ → ℝ) (lam : γ → ℝ) (c : ι) : ℝ :=
  raw c - ∑ g ∈ G, into c g * lam g

/-- Theorem 5a `what_statement_cancels`: a raw that lies in the span of the
goods — "less of this good" laid on every column in proportion to how much of
it goes into the good — is removed exactly, with `λ = μ`. -/
theorem what_statement_cancels (G : Finset γ) (into : ι → γ → ℝ) (μ : γ → ℝ) (c : ι) :
    centred G (fun c => ∑ g ∈ G, into c g * μ g) into μ c = 0 := by
  simp [centred]

/-- The normal equations: `λ` leaves every good's felt hours at its clock hours. -/
def normal (C : Finset ι) (G : Finset γ) (worked : ι → ℝ) (raw : ι → ℝ) (into : ι → γ → ℝ)
    (lam : γ → ℝ) : Prop :=
  ∀ g ∈ G, ∑ c ∈ C, worked c * into c g * centred G raw into lam c = 0

/-- Theorem 5c `felt_equals_clock`: while no clamp binds, the hours-weighed
stance into every good sums to zero — the field leaves each good's cost at the
worked mix where κ put it and moves only the choice among its ways. -/
theorem felt_equals_clock (C : Finset ι) (G : Finset γ) (worked raw : ι → ℝ)
    (into : ι → γ → ℝ) (lam : γ → ℝ) (hn : normal C G worked raw into lam)
    (unclamped : ∀ c ∈ C, stance (centred G raw into lam c) = centred G raw into lam c) :
    ∀ g ∈ G, ∑ c ∈ C, worked c * into c g * stance (centred G raw into lam c) = 0 := by
  intro g hg
  rw [← hn g hg]
  refine Finset.sum_congr rfl fun c hc => ?_
  rw [unclamped c hc]

/-- Theorem 5′ `mean_dilutes` (refused rule): under a SUM a faint stance on a
broad part adds its own amount; under a mean it would halve a strong narrow
one. Stated as the sum's Lipschitz property (theorem 5 `stance_lipschitz`):
adding one covering part of push `ε` moves the raw by exactly `ε`. -/
theorem stance_lipschitz (Π : Finset P) (push : P → ℝ) (π₀ : P) (hπ : π₀ ∉ Π) :
    (∑ π ∈ insert π₀ Π, push π) - (∑ π ∈ Π, push π) = push π₀ := by
  rw [Finset.sum_insert hπ]
  ring

end SolverCertificate.VoiceField
