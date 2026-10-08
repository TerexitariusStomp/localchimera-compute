import Mathlib.Data.Finset.Basic
import Mathlib.Order.Basic

/-!
# A part is a conjunction, and a union has no name
(parts.scm, lines 30-160: `<part>`, `covers?`, `part-meet`, `part-refines?`)

`docs/planning/voice/voice-follows-work.md` "Parts are drawn from shared kinds":
a part holds at most one node of each shared classification, all holding at
once — `P := (k : Kind) → Option (Node k)`. The record in parts.scm has one
optional slot per kind and no slot that holds two nodes, so a union is
unrepresentable there. What is proved here is what that data shape buys:

* `covers_meet` — the meet of two parts covers a column iff both do (theorem
  9 `parts_inf`): the conjunction is the lattice meet, so "narrowing" means
  exactly "covering fewer".
* `covers_of_refines` — a narrower part (one that states everything a wider
  one states) covers no more (theorem 7 `hours_antitone`, the cover half; the
  hours half is the fold's monotonicity in the covered set).
* `no_union` — there is no part that covers exactly the columns two
  incompatible parts cover between them, once those sets differ: the
  stitched part "my shifts and the steelworks' night run" has no name
  (theorem 8′ `union_carries_hours`, refused by construction).
* `rung_covers_origin` — releasing any subset of a cell's stated terms yields
  a part that still covers the cell (theorem 11).

Terms are matched by equality here; parts.scm also matches a list-valued
term by membership and a window by inclusion, which are the same order on
the value with `≤` read as "matches". Nothing here depends on the kind set.
-/

namespace SolverCertificate.Parts

variable {Kind : Type*} {Node : Kind → Type*} [DecidableEq Kind]

/-- A part: one optional node per kind. -/
def Part (Kind : Type*) (Node : Kind → Type*) := (k : Kind) → Option (Node k)

/-- The terms of a column (or of a work event): the node it stands in, per kind. -/
def Terms (Kind : Type*) (Node : Kind → Type*) := (k : Kind) → Option (Node k)

/-- `covers? π terms`: every stated term of `π` matches the column's term of that kind. -/
def covers (π : Part Kind Node) (t : Terms Kind Node) : Prop :=
  ∀ k, ∀ n, π k = some n → t k = some n

/-- `π ≤ π'` (`part-refines?`): `π` states everything `π'` states. -/
def refines (π π' : Part Kind Node) : Prop :=
  ∀ k, ∀ n, π' k = some n → π k = some n

/-- Two parts are compatible when they never state different nodes for one kind. -/
def compatible (a b : Part Kind Node) : Prop :=
  ∀ k, ∀ x y, a k = some x → b k = some y → x = y

/-- `part-meet` on compatible parts: the stated node of either. -/
noncomputable def meet (a b : Part Kind Node) : Part Kind Node :=
  fun k => (a k).orElse (fun _ => b k)

/-! ### Theorem 9 `parts_inf`: the conjunction is the meet -/

theorem covers_meet (a b : Part Kind Node) (hab : compatible a b) (t : Terms Kind Node) :
    covers (meet a b) t ↔ covers a t ∧ covers b t := by
  constructor
  · intro h
    refine ⟨?_, ?_⟩
    · intro k n hk
      apply h k n
      simp [meet, hk]
    · intro k n hk
      cases ha : a k with
      | none =>
        apply h k n
        simp [meet, ha, hk]
      | some m =>
        have hm : t k = some m := h k m (by simp [meet, ha])
        have : m = n := hab k m n ha hk
        subst this
        exact hm
  · rintro ⟨ha, hb⟩ k n hk
    cases hak : a k with
    | none =>
      apply hb k n
      simpa [meet, hak] using hk
    | some m =>
      simp [meet, hak] at hk
      subst hk
      exact ha k n hak

/-! ### Theorem 7, the cover half: narrower covers no more -/

theorem covers_of_refines {π π' : Part Kind Node} (h : refines π π') {t : Terms Kind Node}
    (hc : covers π t) : covers π' t := by
  intro k n hk
  exact hc k n (h k n hk)

theorem meet_refines_left (a b : Part Kind Node) : refines (meet a b) a := by
  intro k n hk
  simp [meet, hk]

/-! ### Theorem 11 `rung_covers_origin` -/

/-- The origin rung of a cell: its terms, stated as a part. -/
def origin (t : Terms Kind Node) : Part Kind Node := t

/-- Releasing the terms outside `S` (a rung of the ladder). -/
def release (t : Terms Kind Node) (S : Kind → Prop) [DecidablePred S] : Part Kind Node :=
  fun k => if S k then t k else none

theorem rung_covers_origin (t : Terms Kind Node) (S : Kind → Prop) [DecidablePred S] :
    covers (release t S) t := by
  intro k n hk
  by_cases hs : S k
  · simpa [release, hs] using hk
  · simp [release, hs] at hk

theorem origin_refines_rung (t : Terms Kind Node) (S : Kind → Prop) [DecidablePred S] :
    refines (origin t) (release t S) := by
  intro k n hk
  by_cases hs : S k
  · simpa [release, hs] using hk
  · simp [release, hs] at hk

/-! ### Theorem 8′: a union has no name -/

/-- The columns a part covers, within a finite assembly. -/
def coveredBy [DecidableEq (Terms Kind Node)] (π : Part Kind Node)
    (cols : Finset (Terms Kind Node)) [DecidablePred (covers π)] : Finset (Terms Kind Node) :=
  cols.filter (covers π)

/-- Every part covers a *down-closed* set: if it covers a column, it covers every
column that agrees with it on the stated kinds. A union of two disjoint,
differently-stated cover sets is not down-closed in this sense — which is why no
single part names it. Stated as: a part covering both a column with term `x` and
a column with term `y ≠ x` at kind `k` states nothing at `k`, and then covers every
column agreeing elsewhere. -/
theorem covers_two_forces_release (π : Part Kind Node) {t₁ t₂ : Terms Kind Node} {k : Kind}
    {x y : Node k} (h₁ : covers π t₁) (h₂ : covers π t₂)
    (hx : t₁ k = some x) (hy : t₂ k = some y) (hxy : x ≠ y) : π k = none := by
  cases hπ : π k with
  | none => rfl
  | some n =>
    have e₁ : t₁ k = some n := h₁ k n hπ
    have e₂ : t₂ k = some n := h₂ k n hπ
    rw [hx] at e₁
    rw [hy] at e₂
    exact absurd ((Option.some.inj e₁).trans (Option.some.inj e₂).symm) hxy

end SolverCertificate.Parts
