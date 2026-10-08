import Mathlib.Data.Real.Basic
import Mathlib.Tactic.Linarith
import Mathlib.Tactic.Positivity

/-!
# The audit inequality: quantities
(docs/planning/truth-telling.md, stage 3 — verification)

Neither the simplex (Emphasis.lean, Incentives.lean) nor the size of a
table (InTheLarge.lean) touches a padded *quantity*: `q` enters the
tension term's `D`, and a citizen who asks for more than they need is not
rewriting their hand. Stage 3 answers it the way Becker does: audit with
probability `π`, and a padding found costs `F`. Padding pays `g − π·F` in
expectation; truth is dominant exactly when `π·F ≥ g`.

The parameters are *derived*, not guessed: `g` is bounded above by the
burn-meter's largest reading (`gain_le_externality`) or by the table-size
bound (`deviation_gain_le`), so `audit_rate_suffices` says which `π`
closes the gap for a given consequence `F`.
-/

namespace SolverCertificate

/-- Expected payoff of padding by `g`, audited with probability `π` at
consequence `F`. -/
def paddingPayoff (g π F : ℝ) : ℝ := g - π * F

/-- Truth is (weakly) dominant iff the expected consequence covers the gain. -/
theorem truth_dominant_iff (g π F : ℝ) :
    paddingPayoff g π F ≤ 0 ↔ g ≤ π * F := by
  unfold paddingPayoff; constructor <;> intro h <;> linarith

/-- The Becker deterrent: `π·F ≥ g` makes padding worthless. -/
theorem truth_dominant_of (g π F : ℝ) (h : g ≤ π * F) :
    paddingPayoff g π F ≤ 0 :=
  (truth_dominant_iff g π F).mpr h

/-- A bound on the gain (`g ≤ g_max`) and a consequence `F > 0`: auditing
at rate `π ≥ g_max / F` deters every padding under the bound. -/
theorem audit_rate_suffices (g g_max π F : ℝ) (hg : g ≤ g_max) (hF : 0 < F)
    (hπ : g_max / F ≤ π) :
    paddingPayoff g π F ≤ 0 := by
  apply truth_dominant_of
  have : g_max ≤ π * F := by
    have := (div_le_iff₀ hF).mp hπ
    linarith
  linarith

/-- Read the other way: the consequence a fixed audit rate needs. -/
theorem consequence_suffices (g g_max π F : ℝ) (hg : g ≤ g_max) (hπ : 0 < π)
    (hF : g_max / π ≤ F) :
    paddingPayoff g π F ≤ 0 := by
  apply truth_dominant_of
  have := (div_le_iff₀ hπ).mp hF
  linarith

end SolverCertificate
