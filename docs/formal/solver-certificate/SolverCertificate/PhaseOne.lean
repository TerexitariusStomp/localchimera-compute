import SolverCertificate.SuboptimalityBound

/-!
# Phase-I is sound — and exactly how sound (solver.scm §2, lines 380-458)

`phase1-decide` augments the program with ONE slack `s` added to every hard
row (`augment-phase1`) and minimizes `s` over the augmented interior; the
verdict then reads the optimum `s*` against a relative threshold
(`infeasible-by?`). The textbook two-phase claim is an iff — "s* = 0 iff
feasible" — and the implementation deliberately does NOT claim it: an
interior-point phase-I computes an infimum over STRICTLY interior points,
which a pinned variable (empty interior, perfectly feasible) keeps from
being attained. What the code actually relies on is four one-sided margins,
and those are what this file proves:

* `phase1_init_interior` — the starting point the code builds,
  `s₀ = max 0 (−minₗ slack) + 1`, is strictly interior for the augmented
  program (every augmented slack ≥ 1). Phase-I always has somewhere to
  start.
* `phase1_point_sound` — an augmented point with `s ≤ 0` exhibits
  feasibility of the original program. (Why a small s* lets `ensure-feasible`
  proceed.)
* `phase1_infeasibility_sound` — if EVERY augmented point has `s ≥ sbar > 0`,
  the original program is infeasible. Contrapositive of: a feasible `x`
  gives the augmented point `(x, 0)`. This is the direction
  `signal-infeasible!` publishes — s* is a certified lower bound on the
  uniform relaxation any plan needs.
* `phase1_feasible_inf_zero` — a feasible program admits strictly-interior
  augmented points at EVERY `s = ε > 0`, so the strict-interior infimum of
  `s` is 0 even when (pins) it is not attained. This is the exact fact the
  `*infeas-tol*` threshold discussion is about: s* hovering at the numeric
  floor is what feasibility LOOKS LIKE through an interior-point phase-I,
  and only an s* above the program's own scale is evidence of anything.

Together with `phase1_relaxed_sound` (an augmented point at `s ≤ ε` proves
ε-relaxed feasibility — every slack ≥ −ε), these bracket the verdict from
both sides without ever claiming the crisp iff the implementation doesn't
have.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- The augmented slack: the same rows, with one shared relaxation `s` added
to every one — `augment-phase1`'s dense extra column, written semantically. -/
def augSlack (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (x : Vec n) (s : ℝ) (ℓ : Fin m) : ℝ :=
  slack A c x ℓ + s

/-- **Phase-I can always start.** The code's initialization
`s₀ = max 0 (−minₗ slack(x₀)) + 1` puts every augmented slack at `≥ 1`:
strictly interior regardless of how infeasible `x₀` is. Stated with the min
as a hypothesis (`hmin`) rather than recomputed, matching `bar-slacks-min`. -/
theorem phase1_init_interior
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x₀ : Vec n) (smin : ℝ) (hmin : ∀ ℓ, smin ≤ slack A c x₀ ℓ) :
    ∀ ℓ, 1 ≤ augSlack A c x₀ (max 0 (-smin) + 1) ℓ := by
  -- Sketch: augSlack = slack + max 0 (−smin) + 1 ≥ smin + max 0 (−smin) + 1
  -- ≥ smin + (−smin) + 1 = 1 when smin < 0, and ≥ smin + 0 + 1 ≥ 1 when
  -- smin ≥ 0. le_max_left/le_max_right + linarith.
  intro ℓ
  simp only [augSlack]
  linarith [le_max_left (0:ℝ) (-smin), le_max_right (0:ℝ) (-smin), hmin ℓ]

/-- **A nonpositive relaxation exhibits feasibility.** -/
theorem phase1_point_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (s : ℝ) (hs : s ≤ 0)
    (hfeas : ∀ ℓ, 0 ≤ augSlack A c x s ℓ) :
    ∀ ℓ, 0 ≤ slack A c x ℓ := by
  simp only [augSlack] at hfeas
  exact fun ℓ => by linarith [hfeas ℓ]

/-- **A positive lower bound on the relaxation certifies infeasibility.**
If every augmented-feasible `(x, s)` needs `s ≥ sbar` and `sbar > 0`, no feasible
plan exists: `s*` is a real, certified shortfall, in the units of the
breached rows — the quantity `infeasibility-report` publishes. -/
theorem phase1_infeasibility_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (sbar : ℝ) (hsbar : 0 < sbar)
    (hlb : ∀ (x : Vec n) (s : ℝ), (∀ ℓ, 0 ≤ augSlack A c x s ℓ) → sbar ≤ s) :
    ¬ ∃ x : Vec n, ∀ ℓ, 0 ≤ slack A c x ℓ := by
  -- Sketch: a feasible x gives augSlack A c x 0 ℓ = slack + 0 ≥ 0, so
  -- hlb forces sbar ≤ 0, contradicting hsbar.
  rintro ⟨x, hx⟩
  linarith [hlb x 0 fun ℓ => by simpa [augSlack] using hx ℓ]

/-- **Feasibility looks like s* → 0, not s* = 0.** A feasible program has a
strictly interior augmented point at every positive relaxation — even when
(a pinned variable) NO interior point exists at `s = 0`. So an
interior-point phase-I on a feasible program drives `s` to its numerical
floor and no further, and the verdict threshold must sit above that floor:
the content of the `*infeas-tol*` comment block. -/
theorem phase1_feasible_inf_zero
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (hx : ∀ ℓ, 0 ≤ slack A c x ℓ) :
    ∀ ε : ℝ, 0 < ε → ∀ ℓ, 0 < augSlack A c x ε ℓ := by
  intro ε hε ℓ
  simp only [augSlack]
  linarith [hx ℓ]

/-- **A small relaxation proves nearly-feasible.** The other jaw of the
threshold: accepting a point at `s ≤ ε` concedes at most `ε` on every hard
row, uniformly — which is what makes reading `s*` against `program-scale`
a bounded concession rather than a hope. -/
theorem phase1_relaxed_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (s ε : ℝ) (hsε : s ≤ ε)
    (hfeas : ∀ ℓ, 0 ≤ augSlack A c x s ℓ) :
    ∀ ℓ, -ε ≤ slack A c x ℓ := by
  simp only [augSlack] at hfeas
  exact fun ℓ => by linarith [hfeas ℓ]

end SolverCertificate
