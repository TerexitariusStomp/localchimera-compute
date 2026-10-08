import SolverCertificate.SuboptimalityBound

/-!
# `retract-feasible` is sound (solver.scm §2, lines 318-334)

`retract-feasible` blends an infeasible (or partially infeasible) point `x`
toward a strictly-interior `anchor` by the least amount that restores every
hard slack to `≥ 0`. If this were wrong — an off-by-one in the `max` over
violated constraints, a sign error in the per-constraint root — the plan
handed back would silently still be infeasible, the exact failure shape
`tests/planner/test-property-solver-invariants.scm` caught for `solve-osqp`
on `frag`-carrying programs (there: a different bug, same *shape* of bug —
code that looks like it enforces a limit but doesn't).

Scope: BOTH directions, about the threshold the code actually computes.
Soundness — for any blend fraction `t` past `θ`, the result is feasible — is
the safety-critical half (a bug here ships a broken "fix"). The docstring's
"LEAST" claim (minimality — `θ` is not overly conservative) is the other
half, and it is proved: `retract_feasible_tight` per constraint, and
`retract_feasible_correct` for the folded `θ`, which pins the computed
threshold from both sides at once. `retractTheta` is the fold itself
(`(max theta (/ vx (- vx va)))` over the violated constraints), so the
theorems speak about the computed quantity rather than an axiomatized stand-in;
`retract_feasible_sound` still takes `θ` and its bound hypothesis abstractly,
and `retractTheta_spec` discharges that hypothesis for the fold.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- `slack` is affine: its value at a convex combination is the same convex
combination of its values at the endpoints. The one fact `retract-feasible`'s
whole argument rests on — every hard slack being affine along the segment
is exactly why a single scalar blend can clear every constraint at once. -/
theorem slack_affine (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (t : ℝ) (ℓ : Fin m) :
    slack A c ((1 - t) • x + t • anchor) ℓ =
      (1 - t) * slack A c x ℓ + t * slack A c anchor ℓ := by
  simp only [slack]
  have key : ∀ j : Fin n,
      A ℓ j * ((1 - t) • x + t • anchor) j
        = (1 - t) * (A ℓ j * x j) + t * (A ℓ j * anchor j) := by
    intro j
    simp only [PiLp.add_apply, PiLp.smul_apply, smul_eq_mul]
    ring
  simp only [key, Finset.sum_add_distrib, ← Finset.mul_sum]
  ring

/-- **`retract-feasible` is sound.** Given `anchor` strictly interior
(`ha`) and `θ` an upper bound on every violated constraint's exact root
(`hθ` — this is what `retract-feasible`'s `max` fold computes), every blend
fraction `t ∈ [θ, 1]` restores full feasibility. `retract-feasible` itself
uses `t = min 1 (1.01 * θ)` — a small numerical overshoot past the exact
root; that exact blend is instantiated in `retract_feasible_overshoot`
below, which needs no hypotheses beyond the interior anchor. -/
theorem retract_feasible_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (ha : ∀ ℓ, 0 < slack A c anchor ℓ)
    (θ t : ℝ) (ht0 : 0 ≤ t) (htle1 : t ≤ 1) (hθt : θ ≤ t)
    (hθ : ∀ ℓ, slack A c x ℓ < 0 →
      θ ≥ (slack A c x ℓ) / (slack A c x ℓ - slack A c anchor ℓ)) :
    ∀ ℓ, 0 ≤ slack A c ((1 - t) • x + t • anchor) ℓ := by
  intro ℓ
  rw [slack_affine]
  have hva := ha ℓ
  rcases le_or_gt 0 (slack A c x ℓ) with h | h
  · -- constraint `ℓ` was already satisfied: both blended terms are nonnegative
    have h1 : 0 ≤ (1 - t) * slack A c x ℓ := mul_nonneg (by linarith) h
    have h2 : 0 ≤ t * slack A c anchor ℓ := mul_nonneg ht0 hva.le
    linarith
  · -- constraint `ℓ` was violated: `t ≥ θ ≥ vx / (vx - va)`, and `vx - va < 0`,
    -- so multiplying through by the negative denominator gives `t * (vx - va) ≤ vx`
    have hd : slack A c x ℓ - slack A c anchor ℓ < 0 := by linarith
    have h2 := (hθ ℓ h).trans hθt
    rw [div_le_iff_of_neg hd] at h2
    nlinarith

/-- **`retract-feasible`'s θ is tight** — the "LEAST" half of the docstring's
claim. Per violated constraint: any blend fraction strictly below that
constraint's exact root leaves its slack strictly negative. Minimality of
the folded `θ = max_ℓ root_ℓ` follows: any `t < θ` sits below the root of
the constraint achieving the max, so that constraint is still violated.
Together with `retract_feasible_sound` this pins θ from both sides: the
blend `retract-feasible` picks is neither too little nor (up to its
deliberate 1.01 float overshoot) more than needed. -/
theorem retract_feasible_tight
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (ℓ : Fin m)
    (hx : slack A c x ℓ < 0) (ha : 0 < slack A c anchor ℓ)
    (t : ℝ)
    (ht : t < (slack A c x ℓ) / (slack A c x ℓ - slack A c anchor ℓ)) :
    slack A c ((1 - t) • x + t • anchor) ℓ < 0 := by
  rw [slack_affine]
  -- the denominator `vx - va` is strictly negative, so clearing the division in `ht`
  -- reverses the inequality: `vx < t * (vx - va)`, i.e. `(1-t)*vx + t*va < 0`.
  have hd : slack A c x ℓ - slack A c anchor ℓ < 0 := by linarith
  rw [lt_div_iff_of_neg hd] at ht
  nlinarith

/-- The folded threshold itself: `(max theta (/ vx (- vx va)))` folded over
the violated constraints, starting at `0` — `retract-feasible`'s exact
computation, as a definition instead of a reading. -/
noncomputable def retractTheta (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) : ℝ :=
  Finset.univ.fold max 0 (fun ℓ =>
    if slack A c x ℓ < 0
    then slack A c x ℓ / (slack A c x ℓ - slack A c anchor ℓ)
    else 0)

/-- **The fold satisfies both jaws at once.** `θ := retractTheta` is
nonnegative and dominates every violated constraint's root — exactly the
`hθ` hypothesis `retract_feasible_sound` takes. So the sound and tight
halves apply to the very quantity `retract-feasible` computes, with no
per-constraint bookkeeping left to the reader. -/
theorem retractTheta_spec (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) :
    0 ≤ retractTheta A c x anchor ∧
    ∀ ℓ, slack A c x ℓ < 0 →
      retractTheta A c x anchor ≥
        (slack A c x ℓ) / (slack A c x ℓ - slack A c anchor ℓ) := by
  -- Sketch: Finset.le_fold_max gives both — 0 ≤ fold from the base, and
  -- f ℓ ≤ fold for each ℓ; under the violation hypothesis the `if` selects
  -- the root.
  refine ⟨(Finset.le_fold_max _).mpr (Or.inl le_rfl), fun ℓ hℓ => ?_⟩
  exact (Finset.le_fold_max _).mpr (Or.inr ⟨ℓ, Finset.mem_univ _, by simp [hℓ]⟩)

/-- **The threshold always fits inside the segment.** Every violated
constraint's root `vx / (vx − va)` has `vx < 0` (violated) and `va > 0`
(`ha`: the anchor is strictly interior — the precondition `retract-feasible`
already documents), so numerator and denominator are both negative and
`|vx| < |vx| + va = |vx − va|`: every root lies in `(0, 1)`. The fold's base
is `0`, so `θ < 1` outright. Blending never needs to travel past the anchor,
and the `min 1 (…)` clamp in the code can never bite in a way that matters. -/
theorem retractTheta_lt_one (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (ha : ∀ ℓ, 0 < slack A c anchor ℓ) :
    retractTheta A c x anchor < 1 := by
  refine (Finset.fold_max_lt _).mpr ⟨zero_lt_one, ?_⟩
  intro ℓ _
  by_cases hv : slack A c x ℓ < 0
  · simp only [hv, ite_true]
    have hva := ha ℓ
    have hd : slack A c x ℓ - slack A c anchor ℓ < 0 := by linarith
    rw [div_lt_iff_of_neg hd]
    linarith
  · simpa only [hv, ite_false] using zero_lt_one

/-- **`retract-feasible`, end to end.** For `θ` THE folded threshold: every
blend `t ∈ [θ, 1]` is feasible (soundness), and every `t ∈ [0, θ)` is not —
some constraint is still violated (minimality). One statement, both halves,
about the computed quantity. -/
theorem retract_feasible_correct
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (ha : ∀ ℓ, 0 < slack A c anchor ℓ)
    (t : ℝ) (ht0 : 0 ≤ t) (htle1 : t ≤ 1) :
    (retractTheta A c x anchor ≤ t →
      ∀ ℓ, 0 ≤ slack A c ((1 - t) • x + t • anchor) ℓ) ∧
    (t < retractTheta A c x anchor →
      ∃ ℓ, slack A c ((1 - t) • x + t • anchor) ℓ < 0) := by
  -- Sketch: first half is retract_feasible_sound with retractTheta_spec.2.
  -- Second half: t < fold max means ¬(fold ≤ t); Finset.fold_max_le
  -- (an iff: fold max b f s ≤ c ↔ b ≤ c ∧ ∀ i ∈ s, f i ≤ c) then gives —
  -- since 0 ≤ t holds — some ℓ with f ℓ > t; f ℓ > t ≥ 0 forces the if's
  -- violated branch (the else is 0 ≤ t), so slack A c x ℓ < 0 and t < the
  -- root: retract_feasible_tight closes it.
  refine ⟨fun hθt ℓ => retract_feasible_sound A c x anchor ha _ t ht0 htle1 hθt
    (retractTheta_spec A c x anchor).2 ℓ, fun htθ => ?_⟩
  rw [retractTheta, Finset.lt_fold_max] at htθ
  rcases htθ with h0 | ⟨ℓ, _, hfℓ⟩
  · exact absurd h0 (not_lt.mpr ht0)
  · by_cases hv : slack A c x ℓ < 0
    · simp only [hv, ite_true] at hfℓ
      exact ⟨ℓ, retract_feasible_tight A c x anchor ℓ hv (ha ℓ) t hfℓ⟩
    · simp only [hv, ite_false] at hfℓ
      exact absurd hfℓ (not_lt.mpr ht0)

/-- **The blend `retract-feasible` actually picks.** The code does not use
`θ`; it uses `t = min 1 (1.01 * θ)`, deliberately overshooting the exact root
by 1% to absorb float error. That blend is feasible.

No side conditions beyond `ha` — and in particular the `min`'s clamp is safe,
which is worth spelling out since it is the one place the overshoot could
have gone wrong. By `retractTheta_lt_one` the interior anchor forces `θ < 1`,
so both branches of `min 1 (1.01 * θ)` land at or above `θ`: if `1.01 * θ ≤ 1`
the blend is `1.01 * θ ≥ θ`, and if `1.01 * θ > 1` the clamp returns `1 > θ`.
Either way `retract_feasible_sound` applies. The 1% overshoot can never push
the blend past the anchor, and clamping at the anchor can never fall short. -/
theorem retract_feasible_overshoot
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x anchor : Vec n) (ha : ∀ ℓ, 0 < slack A c anchor ℓ) :
    ∀ ℓ, 0 ≤ slack A c
      ((1 - min 1 (1.01 * retractTheta A c x anchor)) • x
        + (min 1 (1.01 * retractTheta A c x anchor)) • anchor) ℓ := by
  have hspec := retractTheta_spec A c x anchor
  have hθ0 : 0 ≤ retractTheta A c x anchor := hspec.1
  have hθ1 : retractTheta A c x anchor ≤ 1 := (retractTheta_lt_one A c x anchor ha).le
  refine retract_feasible_sound A c x anchor ha _ _ ?_ (min_le_left _ _) ?_ hspec.2
  · exact le_min zero_le_one (by linarith)
  · exact le_min hθ1 (by linarith)

end SolverCertificate
