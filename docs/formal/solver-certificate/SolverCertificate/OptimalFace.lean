import SolverCertificate.SuboptimalityBound

/-!
# `optimal-face-dimension` is sound (solver.scm §3, lines 673-792)

`optimal-face-dimension` exhibits directions `d` claimed to leave the
objective flat — `∇f·d = 0` (no first-order change) and `aᵢ·d = 0` for every
curvature-carrying row (none to second order either) — from two structural
families, and counts them: free columns contribute `|F| − 1` (when the
restricted gradient binds), an interchangeable group of size `g` contributes
`g − 1`, and the counts ADD because the families have disjoint support.

This file certifies exactly those claims, over the same abstraction as
`StrongConvexityModulus.lean` (a curved row is just its dense vector
`a i : Vec n`):

* `IsFlatDir` — the membership predicate the exhibited directions claim.
* `axis_flat` — a free-column axis direction (pivoted against the one
  gradient-binding condition) is genuinely flat.
* `swap_flat` — an interchangeable-column difference `e_j − e_k₀` is
  genuinely flat.
* `face_directions_independent` — the combined family is linearly
  independent, so the counts add: the flat cone contains a subspace of
  dimension ≥ `(|F| − 1) + (|G| − 1)`. This is the docstring's safe
  direction made precise: the reported dimension is a LOWER bound —
  "0 means none found, never the optimum is unique."

Both cases of the free-column count are covered: the gradient-binding one
(`g0 p ≠ 0` on the pivot), where the `− 1` in `|F| − 1` earns its keep, and
the non-binding one (`axis_flat_nonbinding` / `axes_independent`), where plain
axes `e j` are already flat and `F` contributes `|F|`. Groups compose:
`face_directions_independent_multi` handles any finite family of pairwise
disjoint interchangeable groups, so the reported dimension
`(|F| − 1) + Σᵢ (|G i| − 1)` is certified as a whole and not only one group at
a time. All of it runs through one lemma, `linearIndependent_of_owned_coord`:
every direction owns the column it is named after.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n nt : ℕ}

/-- A direction that changes the objective neither to first order
(`⟪g0, d⟫ = 0`) nor — through any curvature-carrying row — to second order
(`⟪a i, d⟫ = 0` for every `i`). -/
def IsFlatDir (g0 : Vec n) (a : Fin nt → Vec n) (d : Vec n) : Prop :=
  (inner (𝕜 := ℝ) g0 d) = 0 ∧ ∀ i, (inner (𝕜 := ℝ) (a i) d) = 0

/-- The pivoted axis direction for free column `j`: move along `j`, trading
against pivot `p` to stay orthogonal to the gradient. -/
noncomputable def axisDir (g0 : Vec n) (p j : Fin n) : Vec n :=
  EuclideanSpace.single j (1 : ℝ) - (g0 j / g0 p) • EuclideanSpace.single p 1

/-- The interchange direction between columns `j` and `k₀`. -/
noncomputable def swapDir (j k₀ : Fin n) : Vec n :=
  EuclideanSpace.single j (1 : ℝ) - EuclideanSpace.single k₀ 1

/-- Free-column axes are flat: no curved row touches `F`, and the pivot trade
cancels the gradient exactly. -/
theorem axis_flat (g0 : Vec n) (a : Fin nt → Vec n)
    (F : Finset (Fin n)) (hfree : ∀ i, ∀ j ∈ F, a i j = 0)
    (p : Fin n) (hp : p ∈ F) (hgp : g0 p ≠ 0)
    (j : Fin n) (hj : j ∈ F) :
    IsFlatDir g0 a (axisDir g0 p j) := by
  refine ⟨?_, fun i => ?_⟩ <;>
    simp only [axisDir, inner_sub_right, real_inner_smul_right,
      EuclideanSpace.inner_single_right, starRingEnd_apply, star_trivial]
  · -- the pivot trade cancels the gradient exactly
    field_simp
    ring
  · -- no curved row touches `F`, and both `j` and `p` lie in `F`
    rw [hfree i j hj, hfree i p hp]
    ring

/-- Interchangeable-column swaps are flat: equal coefficients in every curved
row and equal gradient entries make `e_j − e_k₀` invisible to both. -/
theorem swap_flat (g0 : Vec n) (a : Fin nt → Vec n)
    (j k₀ : Fin n)
    (hrow : ∀ i, a i j = a i k₀) (hgrad : g0 j = g0 k₀) :
    IsFlatDir g0 a (swapDir j k₀) := by
  refine ⟨?_, fun i => ?_⟩ <;>
    simp only [swapDir, inner_sub_right, EuclideanSpace.inner_single_right, starRingEnd_apply,
      star_trivial]
  · rw [hgrad, sub_self]
  · rw [hrow i, sub_self]

/-- **Owned coordinates give independence.** If each member of a family holds
the value `1` at a coordinate it owns and `0` at every other member's owned
coordinate, the family is linearly independent. Every independence claim in
this file is an instance: the directions are built from `single`s, so each one
owns the column it is named after. -/
theorem linearIndependent_of_owned_coord {ι : Type*} [Fintype ι] [DecidableEq ι]
    (v : ι → Vec n) (own : ι → Fin n)
    (h1 : ∀ i, (v i).ofLp (own i) = 1)
    (h0 : ∀ i i', i ≠ i' → (v i).ofLp (own i') = 0) :
    LinearIndependent ℝ v := by
  classical
  rw [Fintype.linearIndependent_iff]
  intro g hg i
  have h := congrArg (fun w : Vec n => w.ofLp (own i)) hg
  simp only [WithLp.ofLp_sum, WithLp.ofLp_smul, Finset.sum_apply, Pi.smul_apply, smul_eq_mul,
    PiLp.zero_apply] at h
  rw [Finset.sum_eq_single i (fun i' _ hne => by rw [h0 i' i hne, mul_zero])
    (fun hi => absurd (Finset.mem_univ i) hi)] at h
  rwa [h1 i, mul_one] at h

/-- **The counts add.** Axes over `F \ {p}` and swaps over `G \ {k₀}` are
jointly linearly independent: each member owns a coordinate (`j` itself) no
other member touches — axes are supported in `F`, swaps in `G`, `F` and `G`
are disjoint, and the shared columns `p`, `k₀` are excluded from the index
sets. So the flat directions span a subspace of dimension exactly
`(|F| − 1) + (|G| − 1)` at least. -/
theorem face_directions_independent (g0 : Vec n)
    (F G : Finset (Fin n)) (hFG : Disjoint F G)
    (p : Fin n) (hp : p ∈ F) (k₀ : Fin n) (hk₀ : k₀ ∈ G) :
    LinearIndependent ℝ
      (fun jk : (↥(F.erase p) ⊕ ↥(G.erase k₀)) =>
        match jk with
        | .inl j => axisDir g0 p j.1
        | .inr k => swapDir k.1 k₀) := by
  -- Every direction owns the column it is named after: `axisDir g0 p j` is 1 at
  -- `j` with its only other support at `p`, and `swapDir k k₀` is 1 at `k` with
  -- its only other support at `k₀`. Both `p` and `k₀` are excluded from the index
  -- sets (erased, and out of the other set by disjointness), so every coefficient
  -- is read off directly by `linearIndependent_of_owned_coord`.
  classical
  have haxis : ∀ (j' m : Fin n), (axisDir g0 p j').ofLp m
      = (if m = j' then (1 : ℝ) else 0) - (g0.ofLp j' / g0.ofLp p) * (if m = p then 1 else 0) := by
    intro j' m; simp [axisDir]
  have hswap : ∀ (j' k' m : Fin n), (swapDir j' k').ofLp m
      = (if m = j' then (1 : ℝ) else 0) - (if m = k' then 1 else 0) := by
    intro j' k' m; simp [swapDir]
  have hFGne : ∀ u ∈ F, ∀ v ∈ G, u ≠ v := fun u hu v hv huv =>
    (Finset.disjoint_left.mp hFG hu) (huv ▸ hv)
  refine linearIndependent_of_owned_coord _
    (fun jk => match jk with | .inl j => j.1 | .inr k => k.1) ?_ ?_
  · rintro (j | k)
    · rw [haxis, ite_eq_left rfl, ite_eq_right (Finset.ne_of_mem_erase j.2)]; ring
    · rw [hswap, ite_eq_left rfl, ite_eq_right (Finset.ne_of_mem_erase k.2)]; ring
  · rintro (j | k) (j' | k') hidx
    · have hjj : (j' : Fin n) ≠ (j : Fin n) := fun he =>
        hidx (by rw [Sum.inl.injEq]; exact Subtype.ext he.symm)
      rw [haxis, ite_eq_right hjj, ite_eq_right (Finset.ne_of_mem_erase j'.2)]; ring
    · have hkG : (k' : Fin n) ∈ G := Finset.mem_of_mem_erase k'.2
      rw [haxis, ite_eq_right (fun he => hFGne _ (Finset.mem_of_mem_erase j.2) _ hkG he.symm),
        ite_eq_right (fun he => hFGne _ hp _ hkG he.symm)]
      ring
    · rw [hswap,
        ite_eq_right (hFGne _ (Finset.mem_of_mem_erase j'.2) _ (Finset.mem_of_mem_erase k.2)),
        ite_eq_right (hFGne _ (Finset.mem_of_mem_erase j'.2) _ hk₀)]
      ring
    · have hkk : (k' : Fin n) ≠ (k : Fin n) := fun he =>
        hidx (by rw [Sum.inr.injEq]; exact Subtype.ext he.symm)
      rw [hswap, ite_eq_right hkk, ite_eq_right (Finset.ne_of_mem_erase k'.2)]; ring

/-! ### The two cases the first pass left open

The header noted both: the non-binding case (`g0` flat on `F`, where plain
axes work and no pivot is spent) and the composition of SEVERAL
interchangeable groups (where the reported count is a sum over groups). The
code does both — `optimal-face-dimension` reports `|F| − 1` only when the
restricted gradient binds, and folds over every group it finds — so leaving
them out left the reported number partly uncertified. -/

/-- **The non-binding case.** When the gradient vanishes on the free columns
there is nothing to trade against: the plain axis `e j` is already flat, and
no pivot has to be spent. This is why the `− 1` in `|F| − 1` is charged only
in the binding case; here `F` contributes `|F|`. -/
theorem axis_flat_nonbinding (g0 : Vec n) (a : Fin nt → Vec n)
    (F : Finset (Fin n)) (hfree : ∀ i, ∀ j ∈ F, a i j = 0)
    (hg0 : ∀ j ∈ F, g0 j = 0)
    (j : Fin n) (hj : j ∈ F) :
    IsFlatDir g0 a (EuclideanSpace.single j (1 : ℝ)) := by
  refine ⟨?_, fun i => ?_⟩ <;>
    simp only [EuclideanSpace.inner_single_right, starRingEnd_apply, star_trivial]
  · rw [hg0 j hj]; ring
  · rw [hfree i j hj]; ring

/-- Plain axes over `F` are independent — the non-binding case's count, `|F|`
directions rather than `|F| − 1`. -/
theorem axes_independent (F : Finset (Fin n)) :
    LinearIndependent ℝ (fun j : ↥F => (EuclideanSpace.single j.1 (1 : ℝ) : Vec n)) := by
  classical
  refine linearIndependent_of_owned_coord _ (fun j => j.1) (fun j => by simp) ?_
  intro i i' hne
  have : (i : Fin n) ≠ (i' : Fin n) := fun he => hne (Subtype.ext he)
  simp [this]

/-- **Several groups compose.** Axes over `F \ {p}` together with the swaps of
every interchangeable group `G gi \ {k₀ gi}` are jointly independent, provided
the groups are pairwise disjoint and disjoint from `F`. So the dimensions add
across groups exactly as `optimal-face-dimension` adds its counts:
`(|F| − 1) + Σᵢ (|G i| − 1)`. The single-group statement
`face_directions_independent` is the `ng = 1` case.

The argument is the same ownership argument throughout — each direction owns
the column it is named after, its only other support being the excluded
representative (`p`, or `k₀ gi`) — which is why disjointness is the whole
hypothesis and no genuinely new idea appears at `ng > 1`. -/
theorem face_directions_independent_multi (g0 : Vec n)
    (F : Finset (Fin n)) (p : Fin n) (hp : p ∈ F)
    (ng : ℕ) (G : Fin ng → Finset (Fin n)) (k₀ : Fin ng → Fin n)
    (hk₀ : ∀ gi, k₀ gi ∈ G gi)
    (hFG : ∀ gi, Disjoint F (G gi))
    (hGG : ∀ gi gi', gi ≠ gi' → Disjoint (G gi) (G gi')) :
    LinearIndependent ℝ
      (fun jk : (↥(F.erase p) ⊕ (Σ gi : Fin ng, ↥((G gi).erase (k₀ gi)))) =>
        match jk with
        | .inl j => axisDir g0 p j.1
        | .inr k => swapDir k.2.1 (k₀ k.1)) := by
  classical
  -- coordinate formulas, as in the single-group proof
  have haxis : ∀ (j' : Fin n) (m : Fin n), (axisDir g0 p j').ofLp m
      = (if m = j' then (1 : ℝ) else 0) - (g0.ofLp j' / g0.ofLp p) * (if m = p then 1 else 0) := by
    intro j' m; simp [axisDir]
  have hswap : ∀ (j' k' : Fin n) (m : Fin n), (swapDir j' k').ofLp m
      = (if m = j' then (1 : ℝ) else 0) - (if m = k' then 1 else 0) := by
    intro j' k' m; simp [swapDir]
  -- `F` and every `G gi` are disjoint, and the groups are pairwise disjoint
  have hFGne : ∀ u ∈ F, ∀ gi, ∀ v ∈ G gi, u ≠ v := by
    intro u hu gi v hv huv
    exact (Finset.disjoint_left.mp (hFG gi) hu) (huv ▸ hv)
  have hGGne : ∀ gi gi', gi ≠ gi' → ∀ u ∈ G gi, ∀ v ∈ G gi', u ≠ v := by
    intro gi gi' hne u hu v hv huv
    exact (Finset.disjoint_left.mp (hGG gi gi' hne) hu) (huv ▸ hv)
  refine linearIndependent_of_owned_coord _
    (fun jk => match jk with | .inl j => j.1 | .inr k => k.2.1) ?_ ?_
  · -- each direction is `1` at the column it owns
    rintro (j | ⟨gi, k⟩)
    · rw [haxis, ite_eq_left rfl, ite_eq_right (Finset.ne_of_mem_erase j.2)]; ring
    · rw [hswap, ite_eq_left rfl, ite_eq_right (Finset.ne_of_mem_erase k.2)]; ring
  · -- and `0` at every other member's owned column
    rintro (j | ⟨gi, k⟩) (j' | ⟨gi', k'⟩) hne
    · -- axis at another axis's column
      have hjj : (j' : Fin n) ≠ (j : Fin n) := fun he =>
        hne (by rw [Sum.inl.injEq]; exact Subtype.ext he.symm)
      rw [haxis, ite_eq_right hjj, ite_eq_right (Finset.ne_of_mem_erase j'.2)]; ring
    · -- axis at a swap's column: supports of the axis lie in `F`, the column in `G gi'`
      have hkF : (k' : Fin n) ∈ G gi' := Finset.mem_of_mem_erase k'.2
      rw [haxis,
        ite_eq_right (fun he => hFGne _ (Finset.mem_of_mem_erase j.2) gi' _ hkF he.symm),
        ite_eq_right (fun he => hFGne _ hp gi' _ hkF he.symm)]
      ring
    · -- swap at an axis's column: symmetric to the previous case
      have hkG : (k : Fin n) ∈ G gi := Finset.mem_of_mem_erase k.2
      rw [hswap,
        ite_eq_right (hFGne _ (Finset.mem_of_mem_erase j'.2) gi _ hkG),
        ite_eq_right (hFGne _ (Finset.mem_of_mem_erase j'.2) gi _ (hk₀ gi))]
      ring
    · -- swap at another swap's column, within a group or across two groups
      have hk'G : (k' : Fin n) ∈ G gi' := Finset.mem_of_mem_erase k'.2
      by_cases hgg : gi = gi'
      · subst hgg
        have hkk : (k' : Fin n) ≠ (k : Fin n) := by
          intro he
          exact hne (by rw [Sum.inr.injEq]; exact Sigma.ext rfl (heq_of_eq (Subtype.ext he.symm)))
        rw [hswap, ite_eq_right hkk, ite_eq_right (Finset.ne_of_mem_erase k'.2)]; ring
      · rw [hswap,
          ite_eq_right (hGGne gi' gi (Ne.symm hgg) _ hk'G _ (Finset.mem_of_mem_erase k.2)),
          ite_eq_right (hGGne gi' gi (Ne.symm hgg) _ hk'G _ (hk₀ gi))]
        ring

end SolverCertificate
