import SolverCertificate.SuboptimalityBound

/-!
# `column-bounds` propagation is sound, the one-sided case (solver.scm)

`column-bounds` (and `column-upper-bounds`, its wrapper that asks for no floors) produces per-variable upper bounds `uⱼ` claimed valid
at EVERY feasible point, by interval propagation over the hard rows: for a
row `c + Σᵢ aᵢxᵢ ≥ 0` and a variable `j` with `aⱼ < 0`,

    xⱼ ≤ (c + Σ_{i≠j, aᵢ>0} aᵢ·uᵢ) / (−aⱼ)

"because the NEGATIVE terms only shrink the left side and every variable
carries an x ≥ 0 barrier, so dropping them is sound." These bounds feed
`feasible-box-radius`, which feeds `dist-geometry = ‖r‖·D` — so an unsound
propagation step would silently shrink `D` and underreport the certified
gap. This file proves the step.

The iteration itself (12 rounds, stop when nothing moves) is proved here too
(`runRounds_sound`), on top of two per-step facts:

* `propagation_step_sound` — one application of the rule, at one row and one
  negative-coefficient variable, yields a genuine upper bound on that
  variable at every feasible point. Stated with the code's exact reading:
  only the POSITIVE-coefficient variables need prior bounds (`hub`), the
  variable `j` itself and every other negative-coefficient variable need
  nothing. The code's `pos` sum includes `j`'s own entry only when
  `a j > 0`, which cannot happen here (`a j < 0`), matching the "this
  variable's own positive contribution is not in pos" comment.
* `bounds_update_sound` — writing `min (u j) b` into a valid bound vector,
  for `b` any genuine upper bound on `x j`, keeps the vector valid. So
  validity is invariant round to round, and the seed vector (`+inf`, or a
  caller-supplied bound the matrix cannot know) only needs to be valid
  itself.

Finiteness discipline: the code works in floats where `+inf` is a value and
`pos < +inf` guards the update. Here everything is a plain real — a bound
that "is `+inf`" is simply a variable the hypotheses don't mention. `hub`
therefore only quantifies over positive-coefficient positions, which is
exactly the set the guard requires to be finite.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- `u` is a valid bound vector for row system `(A, c)`: at every feasible
nonneg point, every coordinate is below its bound. -/
def ValidBounds (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ) (u : Fin n → ℝ) : Prop :=
  ∀ x : Vec n, (∀ j, 0 ≤ x j) → (∀ ℓ, 0 ≤ slack A c x ℓ) → ∀ j, x j ≤ u j

/-- **One propagation step is sound.** At any feasible nonneg `x`, a row `ℓ`
with `A ℓ j < 0` bounds `x j` by the row's budget over `−A ℓ j`, where the
budget charges only the positive-coefficient variables at their known
bounds. Negative-coefficient terms (including `j`'s own) are dropped — sound
because they are `≤ 0` on `x ≥ 0`. -/
theorem propagation_step_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (x : Vec n) (hx : ∀ j, 0 ≤ x j) (hfeas : ∀ ℓ, 0 ≤ slack A c x ℓ)
    (ℓ : Fin m) (j : Fin n) (haj : A ℓ j < 0)
    (u : Fin n → ℝ)
    (hub : ∀ i, 0 < A ℓ i → x i ≤ u i) :
    x j ≤ (c ℓ + ∑ i ∈ Finset.univ.filter (fun i => 0 < A ℓ i), A ℓ i * u i) / (-(A ℓ j)) := by
  -- Sketch: from 0 ≤ slack = c ℓ + Σᵢ A ℓ i * x i, split the sum into
  -- positive-coefficient, negative-coefficient (∋ j), and zero parts.
  -- Positive part ≤ Σ_{aᵢ>0} aᵢuᵢ (hub, aᵢ > 0); negative part other than j
  -- is ≤ 0 (hx); so 0 ≤ c ℓ + Σ_pos aᵢuᵢ + A ℓ j * x j. Rearrange with
  -- le_div_iff (−A ℓ j > 0).
  have hden : (0:ℝ) < -(A ℓ j) := by linarith
  rw [le_div_iff₀ hden]
  have hrow := hfeas ℓ
  simp only [slack] at hrow
  have hsplit : ∑ i, A ℓ i * x i
      = (∑ i ∈ Finset.univ.filter (fun i => 0 < A ℓ i), A ℓ i * x i)
        + (∑ i ∈ Finset.univ.filter (fun i => ¬ 0 < A ℓ i), A ℓ i * x i) :=
    (Finset.sum_filter_add_sum_filter_not _ _ _).symm
  have hpos : (∑ i ∈ Finset.univ.filter (fun i => 0 < A ℓ i), A ℓ i * x i)
      ≤ ∑ i ∈ Finset.univ.filter (fun i => 0 < A ℓ i), A ℓ i * u i := by
    refine Finset.sum_le_sum ?_
    intro i hi
    have hi' : 0 < A ℓ i := (Finset.mem_filter.mp hi).2
    exact mul_le_mul_of_nonneg_left (hub i hi') hi'.le
  have hjmem : j ∈ Finset.univ.filter (fun i => ¬ 0 < A ℓ i) :=
    Finset.mem_filter.mpr ⟨Finset.mem_univ _, by linarith⟩
  have hneg : (∑ i ∈ Finset.univ.filter (fun i => ¬ 0 < A ℓ i), A ℓ i * x i)
      ≤ A ℓ j * x j := by
    have hsplit2 := Finset.add_sum_erase _ (fun i => A ℓ i * x i) hjmem
    have hrest : (∑ i ∈ (Finset.univ.filter (fun i => ¬ 0 < A ℓ i)).erase j, A ℓ i * x i) ≤ 0 := by
      refine Finset.sum_nonpos ?_
      intro i hi
      have hi' : ¬ 0 < A ℓ i := (Finset.mem_filter.mp (Finset.mem_of_mem_erase hi)).2
      exact mul_nonpos_of_nonpos_of_nonneg (not_lt.mp hi') (hx i)
    linarith
  nlinarith

/-- **The update keeps validity.** Any genuine upper bound `b` on coordinate
`j` may be folded into a valid bound vector by `min`; this is the write the
propagation loop performs (`when (< b (vector-ref u j)) (vector-set! ...)`),
so validity is a loop invariant and holds at every round count. -/
theorem bounds_update_sound
    (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (u : Fin n → ℝ) (hu : ValidBounds A c u)
    (j : Fin n) (b : ℝ)
    (hb : ∀ x : Vec n, (∀ i, 0 ≤ x i) → (∀ ℓ, 0 ≤ slack A c x ℓ) → x j ≤ b) :
    ValidBounds A c (Function.update u j (min (u j) b)) := by
  -- Sketch: intro x hx hfeas i; by_cases i = j: update at j gives
  -- min (u j) b, and x j ≤ both; elsewhere update is u i.
  intro x hx hfeas i
  by_cases hij : i = j
  · subst hij
    simp only [Function.update_self]
    exact le_min (hu x hx hfeas i) (hb x hx hfeas)
  · rw [Function.update_of_ne hij]
    exact hu x hx hfeas i

/-! ## The loop, not just the step

The code runs 12 rounds, each round sweeping rows and variables and writing
`min` into `u` as it goes. Two things about that shape matter and are easy to
get wrong in a paper argument:

* a round's writes are *sequential* — the code reads `u` mid-round, so a
  later write's `pos` sum is computed against the PARTIALLY updated vector,
  not the vector the round started with;
* nothing distinguishes "round boundaries" mathematically — a round is just a
  block of writes.

So the honest object is a single write that *reads the current vector*, and
the loop is a list of those, iterated. `ValidBounds` is the invariant, and it
holds not merely between rounds but at every intermediate write — which is
exactly what licenses the mid-round reads. -/

/-- One write of the propagation loop: fold a candidate bound `b` into
coordinate `j` by `min`, leaving every other coordinate alone. -/
def boundsWrite (u : Fin n → ℝ) (j : Fin n) (b : ℝ) : Fin n → ℝ :=
  Function.update u j (min (u j) b)

/-- A write *rule*: it inspects the current bound vector and returns the
coordinate to write and the value to write there. The dependence on the
current vector is the point — this is what "the code reads `u` mid-round"
means. -/
def SoundWrite (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (w : (Fin n → ℝ) → Fin n × ℝ) : Prop :=
  ∀ u : Fin n → ℝ, ValidBounds A c u →
    ∀ x : Vec n, (∀ i, 0 ≤ x i) → (∀ ℓ, 0 ≤ slack A c x ℓ) → x (w u).1 ≤ (w u).2

/-- A block of writes, performed left to right, each reading the vector left
by its predecessors. One round of the code's sweep is such a block. -/
def runWrites (ws : List ((Fin n → ℝ) → Fin n × ℝ)) (u : Fin n → ℝ) : Fin n → ℝ :=
  ws.foldl (fun v w => boundsWrite v (w v).1 (w v).2) u

/-- **The propagation rule is a sound write rule.** For a row `ℓ` and a
variable `j` with `A ℓ j < 0`, "compute the row's budget at the current
bounds and divide by `−A ℓ j`" is a legitimate write: the `hub` premise of
`propagation_step_sound` is supplied by validity of the very vector being
read. -/
theorem propagationWrite_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (ℓ : Fin m) (j : Fin n) (haj : A ℓ j < 0) :
    SoundWrite A c (fun u =>
      (j, (c ℓ + ∑ i ∈ Finset.univ.filter (fun i => 0 < A ℓ i), A ℓ i * u i) / (-(A ℓ j)))) := by
  intro u hu x hx hfeas
  exact propagation_step_sound A c x hx hfeas ℓ j haj u (fun i _ => hu x hx hfeas i)

/-- **Validity is preserved by a whole block of writes** — and, because the
induction threads the invariant through `foldl`, by every prefix of it too.
This is the mid-round guarantee: each write reads a vector already known
valid. -/
theorem runWrites_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (ws : List ((Fin n → ℝ) → Fin n × ℝ)) (hws : ∀ w ∈ ws, SoundWrite A c w)
    (u : Fin n → ℝ) (hu : ValidBounds A c u) :
    ValidBounds A c (runWrites ws u) := by
  induction ws generalizing u with
  | nil => exact hu
  | cons w ws ih =>
    exact ih (fun w' hw' => hws w' (List.mem_cons_of_mem _ hw')) _
      (bounds_update_sound A c u hu (w u).1 (w u).2 (hws w (List.mem_cons_self ..) u hu))

/-- **The loop, at any round count.** Running the same block of writes `N`
times over — the code's `12` — keeps a valid bound vector valid. The seed
only has to be valid itself (`+inf` trivially is), and no round count is
privileged: stopping early, stopping late, or stopping when nothing moves all
land on a valid vector. -/
theorem runRounds_sound (A : Matrix (Fin m) (Fin n) ℝ) (c : Fin m → ℝ)
    (ws : List ((Fin n → ℝ) → Fin n × ℝ)) (hws : ∀ w ∈ ws, SoundWrite A c w)
    (N : ℕ) (u : Fin n → ℝ) (hu : ValidBounds A c u) :
    ValidBounds A c ((runWrites ws)^[N] u) := by
  induction N generalizing u with
  | zero => exact hu
  | succ N ih =>
    rw [Function.iterate_succ_apply]
    exact ih _ (runWrites_sound A c ws hws u hu)

/-! ### Bounds only fall

solver.scm `column-bounds`: "Iterating this until nothing moves is ordinary interval
propagation; it is monotone (bounds only fall) so it terminates". Soundness
above holds at any round count; monotonicity is the separate fact that makes
the code's *stopping rule* legitimate — the sequence of vectors is antitone, so
"nothing moved this round" is a fixpoint and not a coincidence, and stopping
early only costs tightness. Neither direction needs the writes to be sound:
this is about `min`, not about the rows. -/

/-- A single write never raises a bound. -/
theorem boundsWrite_le (u : Fin n → ℝ) (j : Fin n) (b : ℝ) (i : Fin n) :
    boundsWrite u j b i ≤ u i := by
  by_cases hij : i = j
  · subst hij
    simp only [boundsWrite, Function.update_self]
    exact min_le_left _ _
  · simp only [boundsWrite, Function.update_of_ne hij, le_refl]

/-- A whole block of writes never raises a bound. -/
theorem runWrites_le (ws : List ((Fin n → ℝ) → Fin n × ℝ)) (u : Fin n → ℝ) (i : Fin n) :
    runWrites ws u i ≤ u i := by
  induction ws generalizing u with
  | nil => exact le_rfl
  | cons w ws ih => exact le_trans (ih _) (boundsWrite_le u (w u).1 (w u).2 i)

/-- **The round sequence is antitone.** Each further round can only lower every
coordinate, so the iteration is monotone in the code's sense and its
"stop when nothing moves" exit is a genuine fixpoint test. -/
theorem runRounds_antitone (ws : List ((Fin n → ℝ) → Fin n × ℝ))
    (N : ℕ) (u : Fin n → ℝ) (i : Fin n) :
    (runWrites ws)^[N + 1] u i ≤ (runWrites ws)^[N] u i := by
  rw [Function.iterate_succ_apply']
  exact runWrites_le ws _ i

end SolverCertificate
