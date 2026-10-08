import Mathlib.Algebra.BigOperators.Group.Finset.Basic
import Mathlib.Algebra.BigOperators.Field
import Mathlib.Algebra.Order.Field.Basic
import Mathlib.Data.Finset.Update
import Mathlib.Data.Real.Basic
import Mathlib.Tactic.Ring

/-!
# The emphasis law is one hand, however it is written
(emphasis.scm, lines 26-54; demand-fold.scm `%cells-of` / `%apply-need`)

`emphasis-masses` turns a citizen's stated attachments into the plan's weight
on each of their rows:

    mass(owner, key) = W · voice(owner) · raw(owner, key) / Σ_k raw(owner, k)

and the demand fold's twin cell is the sum of those masses over every owner
(playnet.typ §Desire as harmony: `w_d = Σ_p v_p · x̂_p(d)`). Four properties
are what the mechanism in `docs/planning/truth-telling.md` (stage 2) rests on,
and they are proved here rather than pinned by example:

* `hand_conserved` — an owner's masses sum to `W · voice`: a hand is one
  hand, whatever numbers were written on it.
* `rescale_invariant` — scaling every raw of one owner by `c > 0` moves no
  mass: writing 100/200 is the same statement as 1/2.
* `coalition_linear` — mass is linear in voice, so an owner split into two
  AIDs carrying the same hand and voices `v₁ + v₂` lays exactly the mass
  the one owner did: splitting yourself buys nothing, pooling costs nothing.
* `apply_reread_agree` — replacing ONE owner's hand and re-summing that
  owner alone equals re-reading the whole twin. This is the identity the
  fold's incremental apply (`%apply-need`: the changed hand from the event,
  every other from the store) relies on for commit-order independence.
* `twin_partition` / `twin_overlap` — the fold sums the twins of the scopes
  below it; that is the twin of the whole exactly when every owner has ONE
  home (a function from owners to homes), and when two parts share owners it
  overcounts by exactly the twin of the owners they share. This is the
  statement `twin_union`'s disjointness hypothesis is discharged by, given a
  home function: `route-home` writes a person's facts at their one home, and
  `communes-overlap` (at the solve's entry) and `records-held-twice` (the
  auditor) refuse a need, an agent or a resource held by two scopes, so the
  hypothesis is checked wherever the solve is asked (docs/planning/
  federation-identity-and-folds.md).

An owner whose raws sum to zero states nothing and contributes nothing
(`(when (and (number? raw) (> raw 0)) …)`); the `share` below is `0` there.
-/

namespace SolverCertificate

open Finset

variable {ι σ : Type*} [DecidableEq σ]

/-- The share of an owner's attention on `k`: their raw on `k` over the sum of
their raws across the keys `K`; zero when they stated nothing at all. -/
noncomputable def share (K : Finset ι) (h : ι → ℝ) (k : ι) : ℝ :=
  if 0 < ∑ j ∈ K, h j then h k / ∑ j ∈ K, h j else 0

/-- `emphasis-masses`' one line: scale × voice × share. -/
noncomputable def mass (W v : ℝ) (K : Finset ι) (h : ι → ℝ) (k : ι) : ℝ :=
  W * v * share K h k

/-- The fold's twin cell on `k`: every owner's mass on it, summed
(`%cells-of`'s `sum-cells` over the emphasis rows). -/
noncomputable def twin (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) (O : Finset σ)
    (K : Finset ι) (k : ι) : ℝ :=
  ∑ o ∈ O, mass W (v o) K (f o) k

/-! ### 1. A hand is one hand -/

theorem sum_share_eq_one {K : Finset ι} {h : ι → ℝ} (hpos : 0 < ∑ j ∈ K, h j) :
    ∑ k ∈ K, share K h k = 1 := by
  simp only [share, hpos, ite_true]
  rw [← Finset.sum_div, div_self hpos.ne']

/-- An owner's masses sum to `W · voice` whenever they stated anything. -/
theorem hand_conserved (W v : ℝ) {K : Finset ι} {h : ι → ℝ}
    (hpos : 0 < ∑ j ∈ K, h j) :
    ∑ k ∈ K, mass W v K h k = W * v := by
  simp only [mass]
  rw [← Finset.mul_sum, sum_share_eq_one hpos, mul_one]

/-! ### 2. The numbers written do not matter, only their ratios -/

theorem share_rescale {K : Finset ι} {h : ι → ℝ} {c : ℝ} (hc : 0 < c) (k : ι) :
    share K (fun j => c * h j) k = share K h k := by
  unfold share
  rw [← Finset.mul_sum]
  by_cases hpos : 0 < ∑ j ∈ K, h j
  · have : 0 < c * ∑ j ∈ K, h j := mul_pos hc hpos
    simp only [hpos, this, ite_true]
    exact mul_div_mul_left (h k) _ hc.ne'
  · have : ¬ 0 < c * ∑ j ∈ K, h j := by
      intro hlt
      exact hpos (pos_of_mul_pos_right hlt hc.le)
    simp [hpos, this]

/-- Scaling every raw of one owner by `c > 0` leaves every mass unchanged. -/
theorem rescale_invariant (W v : ℝ) {K : Finset ι} {h : ι → ℝ} {c : ℝ} (hc : 0 < c)
    (k : ι) :
    mass W v K (fun j => c * h j) k = mass W v K h k := by
  simp only [mass, share_rescale hc]

/-! ### 3. Splitting yourself buys nothing -/

/-- Mass is linear in voice: two AIDs with the same hand and voices `v₁`, `v₂`
lay together exactly the mass one AID with voice `v₁ + v₂` lays. -/
theorem coalition_linear (W v₁ v₂ : ℝ) (K : Finset ι) (h : ι → ℝ) (k : ι) :
    mass W (v₁ + v₂) K h k = mass W v₁ K h k + mass W v₂ K h k := by
  simp only [mass]; ring

/-- The twin over a coalition is the sum of the twins over its disjoint parts:
the fold's `sum-cells` is a sum, however the rows are grouped. -/
theorem twin_union (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {O₁ O₂ : Finset σ}
    (hd : Disjoint O₁ O₂) (K : Finset ι) (k : ι) :
    twin W v f (O₁ ∪ O₂) K k = twin W v f O₁ K k + twin W v f O₂ K k := by
  simp only [twin]
  exact Finset.sum_union hd

/-! ### 4. The incremental apply reads what a full re-read reads -/

/-- Replacing owner `o`'s hand by `h'` and re-summing `o` alone equals
re-reading the whole twin: `%apply-need`'s one-hand replacement is exact,
whatever order the other hands were committed in. -/
theorem apply_reread_agree (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {O : Finset σ}
    {o : σ} (ho : o ∈ O) (h' : ι → ℝ) (K : Finset ι) (k : ι) :
    twin W v (Function.update f o h') O K k
      = twin W v f O K k - mass W (v o) K (f o) k + mass W (v o) K h' k := by
  simp only [twin]
  rw [← Finset.add_sum_erase O _ ho, ← Finset.add_sum_erase O (fun x => mass W (v x) K (f x) k) ho]
  have hrest : ∑ x ∈ O.erase o, mass W (v x) K (Function.update f o h' x) k
      = ∑ x ∈ O.erase o, mass W (v x) K (f x) k := by
    refine Finset.sum_congr rfl fun x hx => ?_
    rw [Function.update_of_ne (Finset.ne_of_mem_erase hx)]
  rw [hrest, Function.update_self]
  ring

/-! ### 5. One home each: the sum over scopes is the twin of the whole -/

variable {τ : Type*}

omit [DecidableEq σ] in
/-- Owners with one home each (`home : σ → τ`, a function): the twin of the
whole is the sum, over the homes, of the twin of the owners at that home. The
fold above the homes is a plain sum and nothing is counted twice, because no
owner is in two fibres. -/
theorem twin_partition (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) (home : σ → τ)
    [DecidableEq τ] {O : Finset σ} {S : Finset τ} (hS : ∀ o ∈ O, home o ∈ S)
    (K : Finset ι) (k : ι) :
    twin W v f O K k = ∑ s ∈ S, twin W v f (O.filter fun o => home o = s) K k := by
  simp only [twin]
  exact (Finset.sum_fiberwise_of_maps_to hS _).symm

/-- When two parts share owners, summing their twins overcounts: the sum is the
twin of the union plus the twin of the owners in BOTH — a person declared
through two scopes is counted twice, and the excess is exactly their mass. -/
theorem twin_overlap (W : ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) (O₁ O₂ : Finset σ)
    (K : Finset ι) (k : ι) :
    twin W v f O₁ K k + twin W v f O₂ K k
      = twin W v f (O₁ ∪ O₂) K k + twin W v f (O₁ ∩ O₂) K k := by
  simp only [twin]
  exact (Finset.sum_union_inter).symm

end SolverCertificate
