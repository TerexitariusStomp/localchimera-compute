-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.BoxBounds

/-!
# Floors tighten the bound, and the box stays valid (solver.scm `column-bounds`)

`BoxBounds.lean` proves the one-sided propagation: an upper bound on a column
that a row draws on, from the upper bounds of the columns that feed the row,
the draw columns' own terms dropped because `x ≥ 0`. The scope's give-bound
(`give-bound`, the most a scope can give of a good that crosses) reads walls
built from that bound, and a wall that drops what its draw columns MUST take
is loose by exactly their floors: a reproduction floor holds a consumer of the
good at a minimum, and what the row pays it is not there to give.

`column-bounds` carries a lower bound `l` beside the upper bound `u`. For a
row `c + Σᵢ aᵢxᵢ ≥ 0` and a column `j`, the BUDGET of `j` charges every other
column at its worst for the row:

    B_j = c + Σ_{i≠j, aᵢ>0} aᵢ·uᵢ + Σ_{i≠j, aᵢ<0} aᵢ·lᵢ

and the row reads both ways from the one budget:

    aⱼ < 0   →   xⱼ ≤  B_j / (−aⱼ)         (the upper bound, now net of floors)
    aⱼ > 0   →   xⱼ ≥ −B_j /   aⱼ          (a lower bound — a floor is the
                                            one-column row, B_j = c)

* `row_budget` — the budget is non-negative at every feasible point:
  `0 ≤ B_j + aⱼ·xⱼ`, from `uᵢ` valid above on the feeders and `lᵢ` valid below
  on the drawers.
* `upperRule_sound` / `lowerRule_sound` — each reading is a sound write
  rule into a box `(l, u)` valid at every feasible nonneg point.
* `runBoxWrites_sound` — validity of the box is a loop invariant: a block of
  writes of either kind, each reading the box the last left, at any round
  count, leaves it valid. The seed `(0, +inf)` (or what the caller supplies)
  only has to be valid itself.

With `l = 0` the budget is `BoxBounds`' and the upper reading is its step
(`budget_zero`), so a caller that asks for no floors reads the old bound.

What the theorems speak of is a program whose every column is nonnegative, with
a seed box valid for it. `give-bound` applies them to the program of the
scope's walls with the good's crossing column held at 0 (the seed `u = 0` there)
and every row that holds a crossing column at a negative coefficient dropped:
that is the sub-program the bounds are about. A crossing column goes below
nothing in the whole program, and the dropped rows are the ones in which that
would break `l = 0`; a dropped row only widens the feasible set, so every bound
read off the rest stays valid on it. The code writes an upper bound only while
`c + Σ feeders ≥ 0`: skipping a write loses tightness and never validity, which
is why the rules above carry no such guard. Soundness holds at any round count;
the stopping rule ("nothing moved") decides only when to quit.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- What column `i` costs the row at its worst: a feeder (`aᵢ > 0`) at its upper
bound, a drawer (`aᵢ < 0`) at its lower bound, a column the row does not hold
nothing. -/
noncomputable def worst (a : ℝ) (l u : ℝ) : ℝ := if 0 < a then a * u else if a < 0 then a * l else 0

/-- Row `r`'s budget for column `j`: its constant and every OTHER column's worst. -/
noncomputable def budget (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (l u : Fin n → ℝ) (r : Fin m) (j : Fin n) : ℝ :=
  c r + ∑ i ∈ Finset.univ.erase j, worst (A r i) (l i) (u i)

/-- `(l, u)` brackets every coordinate at every feasible nonneg point. -/
def ValidBox (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (l u : Fin n → ℝ) : Prop :=
  ∀ x : Vec n, (∀ j, 0 ≤ x j) → (∀ r, 0 ≤ slack A c x r) → ∀ j, l j ≤ x j ∧ x j ≤ u j

/-- **The budget is non-negative.** At any feasible nonneg `x` in the box, the
budget of column `j` plus its own term is at least nothing: every other column
costs the row no more than its worst. -/
theorem row_budget (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (l u : Fin n → ℝ)
    (x : Vec n) (hfeas : ∀ r, 0 ≤ slack A c x r)
    (hbox : ∀ i, l i ≤ x i ∧ x i ≤ u i) (r : Fin m) (j : Fin n) :
    0 ≤ budget A c l u r j + A r j * x j := by
  have hrow := hfeas r
  simp only [slack] at hrow
  have hrest : ∑ i ∈ Finset.univ.erase j, A r i * x i
      ≤ ∑ i ∈ Finset.univ.erase j, worst (A r i) (l i) (u i) := by
    refine Finset.sum_le_sum fun i _ => ?_
    unfold worst
    split_ifs with h1 h2
    · exact mul_le_mul_of_nonneg_left (hbox i).2 h1.le
    · exact mul_le_mul_of_nonpos_left (hbox i).1 h2.le
    · have : A r i = 0 := le_antisymm (not_lt.mp h1) (not_lt.mp h2)
      simp [this]
  have hsplit := Finset.add_sum_erase Finset.univ (fun i => A r i * x i) (Finset.mem_univ j)
  unfold budget
  linarith

/-- The upper reading: a drawer's bound, net of what the other drawers must take. -/
theorem upper_reading (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (l u : Fin n → ℝ)
    (x : Vec n) (hfeas : ∀ r, 0 ≤ slack A c x r) (hbox : ∀ i, l i ≤ x i ∧ x i ≤ u i)
    (r : Fin m) (j : Fin n) (hneg : A r j < 0) :
    x j ≤ budget A c l u r j / (-(A r j)) := by
  have hden : (0 : ℝ) < -(A r j) := by linarith
  rw [le_div_iff₀ hden]
  have := row_budget A c l u x hfeas hbox r j
  linarith

/-- The lower reading: a feeder cannot fall below what the row's other terms leave
it to carry. A floor is the case of a row with the one column, `budget = c`. -/
theorem lower_reading (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (l u : Fin n → ℝ)
    (x : Vec n) (hfeas : ∀ r, 0 ≤ slack A c x r) (hbox : ∀ i, l i ≤ x i ∧ x i ≤ u i)
    (r : Fin m) (j : Fin n) (hpos : 0 < A r j) :
    -(budget A c l u r j) / A r j ≤ x j := by
  rw [div_le_iff₀ hpos]
  have := row_budget A c l u x hfeas hbox r j
  linarith

/-- With the lower bounds at the barrier (`l = 0`) the budget of a drawer is
`BoxBounds`' sum over the feeders, and the upper reading is its step. -/
theorem budget_zero (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (u : Fin n → ℝ)
    (r : Fin m) (j : Fin n) (hneg : A r j < 0) :
    budget A c (fun _ => 0) u r j
      = c r + ∑ i ∈ Finset.univ.filter (fun i => 0 < A r i), A r i * u i := by
  unfold budget
  congr 1
  have hj : j ∉ Finset.univ.filter (fun i => 0 < A r i) := by
    simp only [Finset.mem_filter, Finset.mem_univ, true_and, not_lt]; exact hneg.le
  rw [Finset.sum_filter]
  have hall : ∑ i, (if 0 < A r i then A r i * u i else 0)
      = ∑ i ∈ Finset.univ.erase j, (if 0 < A r i then A r i * u i else 0) := by
    rw [← Finset.add_sum_erase Finset.univ _ (Finset.mem_univ j)]
    have : ¬ (0 < A r j) := not_lt.mpr hneg.le
    simp [this]
  rw [hall]
  refine Finset.sum_congr rfl fun i _ => ?_
  unfold worst
  by_cases h1 : 0 < A r i
  · simp [h1]
  · by_cases h2 : A r i < 0 <;> simp [h1, h2]

/-! ### The loop, with both sides -/

/-- One write into the box: tighten an upper bound by `min` or a lower bound by `max`. -/
inductive BoxWrite (n : ℕ)
  | up (j : Fin n) (b : ℝ)
  | lo (j : Fin n) (b : ℝ)

/-- The box after a write. -/
def applyWrite (s : (Fin n → ℝ) × (Fin n → ℝ)) : BoxWrite n → (Fin n → ℝ) × (Fin n → ℝ)
  | .up j b => (s.1, Function.update s.2 j (min (s.2 j) b))
  | .lo j b => (Function.update s.1 j (max (s.1 j) b), s.2)

/-- A write rule reads the current box and names a write; it is sound when what it
names holds at every feasible nonneg point, whenever the box it read was valid. -/
def SoundBoxWrite (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (w : (Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n) : Prop :=
  ∀ l u, ValidBox A c l u → ∀ x : Vec n, (∀ j, 0 ≤ x j) → (∀ r, 0 ≤ slack A c x r) →
    match w (l, u) with
    | .up j b => x j ≤ b
    | .lo j b => b ≤ x j

/-- A block of writes, left to right, each reading the box its predecessors left. -/
def runBoxWrites (ws : List ((Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n))
    (s : (Fin n → ℝ) × (Fin n → ℝ)) : (Fin n → ℝ) × (Fin n → ℝ) :=
  ws.foldl (fun s w => applyWrite s (w s)) s

/-- **A sound write keeps the box valid.** -/
theorem applyWrite_valid (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (w : (Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n) (hw : SoundBoxWrite A c w)
    (l u : Fin n → ℝ) (hv : ValidBox A c l u) :
    ValidBox A c (applyWrite (l, u) (w (l, u))).1 (applyWrite (l, u) (w (l, u))).2 := by
  intro x hx hfeas i
  have hsound := hw l u hv x hx hfeas
  cases hwl : w (l, u) with
  | up j b =>
    rw [hwl] at hsound
    simp only [applyWrite]
    refine ⟨(hv x hx hfeas i).1, ?_⟩
    by_cases hij : i = j
    · subst hij; simp only [Function.update_self]; exact le_min (hv x hx hfeas i).2 hsound
    · rw [Function.update_of_ne hij]; exact (hv x hx hfeas i).2
  | lo j b =>
    rw [hwl] at hsound
    simp only [applyWrite]
    refine ⟨?_, (hv x hx hfeas i).2⟩
    by_cases hij : i = j
    · subst hij; simp only [Function.update_self]; exact max_le (hv x hx hfeas i).1 hsound
    · rw [Function.update_of_ne hij]; exact (hv x hx hfeas i).1

/-- **Validity is preserved by a whole block of writes of either side.** -/
theorem runBoxWrites_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (ws : List ((Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n)) (hws : ∀ w ∈ ws, SoundBoxWrite A c w)
    (s : (Fin n → ℝ) × (Fin n → ℝ)) (hs : ValidBox A c s.1 s.2) :
    ValidBox A c (runBoxWrites ws s).1 (runBoxWrites ws s).2 := by
  induction ws generalizing s with
  | nil => exact hs
  | cons w ws ih =>
    exact ih (fun w' hw' => hws w' (List.mem_cons_of_mem _ hw')) _
      (applyWrite_valid A c w (hws w (List.mem_cons_self ..)) s.1 s.2 hs)

/-- **The loop, at any round count.** -/
theorem runBoxRounds_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (ws : List ((Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n)) (hws : ∀ w ∈ ws, SoundBoxWrite A c w)
    (N : ℕ) (s : (Fin n → ℝ) × (Fin n → ℝ)) (hs : ValidBox A c s.1 s.2) :
    ValidBox A c ((runBoxWrites ws)^[N] s).1 ((runBoxWrites ws)^[N] s).2 := by
  induction N generalizing s with
  | zero => exact hs
  | succ N ih =>
    rw [Function.iterate_succ_apply]
    exact ih _ (runBoxWrites_sound A c ws hws s hs)

/-- The code's upper rule: row `r`, a drawer `j`, the budget over `−aⱼ`. -/
noncomputable def upperRule (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (r : Fin m) (j : Fin n) :
    (Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n :=
  fun s => .up j (budget A c s.1 s.2 r j / (-(A r j)))

/-- The code's lower rule: row `r`, a feeder `j`, minus the budget over `aⱼ`. -/
noncomputable def lowerRule (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (r : Fin m) (j : Fin n) :
    (Fin n → ℝ) × (Fin n → ℝ) → BoxWrite n :=
  fun s => .lo j (-(budget A c s.1 s.2 r j) / A r j)

theorem upperRule_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (r : Fin m) (j : Fin n)
    (hneg : A r j < 0) : SoundBoxWrite A c (upperRule A c r j) := by
  intro l u hv x hx hfeas
  simp only [upperRule]
  exact upper_reading A c l u x hfeas (hv x hx hfeas) r j hneg

theorem lowerRule_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (r : Fin m) (j : Fin n)
    (hpos : 0 < A r j) : SoundBoxWrite A c (lowerRule A c r j) := by
  intro l u hv x hx hfeas
  simp only [lowerRule]
  exact lower_reading A c l u x hfeas (hv x hx hfeas) r j hpos

end SolverCertificate
