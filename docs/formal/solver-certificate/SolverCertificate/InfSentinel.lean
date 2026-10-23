-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.BoxRadius

/-!
# `+inf.0` as a cap means "no cap" (solver.scm §3, lines 917-1010)

`BoxBounds.lean` and `BoxRadius.lean` work with `u : Fin n → ℝ`, and state
their finiteness discipline in a note: "`+inf` is not a real, so a bound that
'is `+inf`' is simply a variable the hypotheses don't mention." That is a
reading imposed on the code, not a theorem about it. The code genuinely stores
`+inf.0` in the cap vector (`(make-vector n +inf.0)`, solver.scm:929) and
genuinely branches on it in three places:

* `column-caps` — a row's budget is `+inf` as soon as ONE positive-coefficient
  column is uncapped, and the row then bounds nothing;
* `feasible-box-radius` — returns `+inf` on meeting an uncapped column, before
  summing anything;
* `box-bounded?` — scans for exactly that condition.

This file gives the sentinel a type. Caps live in `WithTop ℝ`, `⊤` is `+inf.0`,
and the three branches become theorems rather than conventions. The headline is
`capValid_of_top`: weakening any cap to `⊤` is always sound, which is the
precise sense in which `+inf` is the honest answer for a federated scope's
import column rather than a failure to compute one.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- A cap as the code stores it: a real, or `+inf.0`. -/
abbrev Cap := WithTop ℝ

/-- Validity for a cap vector that may contain `+inf.0`. -/
def CapValid (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (u : Fin n → Cap) : Prop :=
  ∀ x : Vec n, (∀ j, 0 ≤ x j) → (∀ ℓ, 0 ≤ slack A c x ℓ) → ∀ j, (x j : Cap) ≤ u j

/-- **`+inf.0` constrains nothing.** Raising any cap to `⊤` preserves validity —
so a vector that starts at all-`+inf` (the seed) is valid before a single row
has been read, and a column the propagation never bounds stays honestly
unbounded rather than silently acquiring one. -/
theorem capValid_of_top (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → Cap) (hu : CapValid A c u) (k : Fin n) :
    CapValid A c (Function.update u k ⊤) := by
  intro x hx hxf j
  by_cases hjk : j = k
  · subst hjk; simp
  · rw [Function.update_of_ne hjk]; exact hu x hx hxf j

/-- The all-`+inf` seed is valid: `(make-vector n +inf.0)`. -/
theorem capValid_top (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) :
    CapValid A c (fun _ => ⊤) := by
  intro x _ _ j; simp

/-- **The finite case is exactly `ValidBounds`.** When no cap is `+inf.0`, the
sentinel-carrying statement and the plain-real statement every other file uses
are the same statement — which is what licenses those files to ignore the
sentinel entirely. -/
theorem capValid_iff_validBounds (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (v : Fin n → ℝ) :
    CapValid A c (fun j => (v j : Cap)) ↔ ValidBounds A c v := by
  simp only [CapValid, ValidBounds, WithTop.coe_le_coe]

/-- **The radius's early exit is right.** `feasible-box-radius` returns `+inf`
the moment it meets an uncapped column, without summing the rest; the geometry
branch is live exactly when every column is capped. This is `box-bounded?`'s
scan (solver.scm:977-984) and the guard on `b-geo` (solver.scm:1263), as one
decidable condition. -/
theorem allCapped_iff (u : Fin n → Cap) :
    (∀ j, u j ≠ ⊤) ↔ ∃ v : Fin n → ℝ, ∀ j, u j = (v j : Cap) := by
  exact ⟨fun h => ⟨fun j => (u j).untop (h j), fun j => by simp⟩,
    fun ⟨v, hv⟩ j => hv j ▸ WithTop.coe_ne_top⟩

/-- **An uncapped positive column kills the row's budget.** `column-caps`
accumulates `+inf` for the whole row as soon as one positive-coefficient
column is uncapped (solver.scm:961-964), and writes nothing. That is not a
missed opportunity: `propagation_step_sound` needs a bound on EVERY
positive-coefficient column, so with one missing there is no bound to write. -/
theorem budget_top_of_uncapped (a : Fin n → ℝ) (u : Fin n → Cap)
    (k : Fin n) (hk : 0 < a k) (hu : u k = ⊤) :
    ¬ ∃ v : Fin n → ℝ, (∀ i, 0 < a i → u i = (v i : Cap)) := by
  rintro ⟨v, hv⟩
  exact WithTop.coe_ne_top (by rw [← hv k hk, hu])

end SolverCertificate
