-- SPDX-License-Identifier: AGPL-3.0-or-later
import SolverCertificate.Emphasis
import Mathlib.Algebra.BigOperators.Group.Finset.Basic
import Mathlib.Algebra.Order.BigOperators.Group.Finset
import Mathlib.Data.Fintype.BigOperators
import Mathlib.Tactic.Linarith

/-!
# What a lie can buy, and what it cannot
(docs/planning/truth-telling.md; externality.scm `withdrawal-displacement`;
service.scm `note-externalities!` — the burn-meter)

The planner is a welfare maximiser without payments: it takes every
citizen's stated weights and chooses the plan that maximises their sum.
Truth-telling is *not* a dominant strategy of such a rule on a rich domain
(Gibbard–Satterthwaite, Hurwicz, Green–Laffont), and this file does not
pretend otherwise. What it proves is the shape of the residual:

* `gain_le_others_loss` — a deviation by `p` gains `p` at most what it
  costs everyone else, at the true utilities. Welfare-maximisation alone.
* `others_loss_le_vcg` / `gain_le_externality` — and that loss is at most
  the VCG reading of the lie: what the others would have had with `p`
  absent, minus what they have under the lie. This is the number
  `withdrawal-displacement` displays and the burn-meter records for the
  *manipulated* outcome. The display is therefore a certified bound on
  manipulation, not merely a deterrent.
* `groves_truthful` — charge that reading and truth becomes dominant
  (Groves). One more line on the same proof; the design records why it is
  not charged.
* `twin_dependent_invariant`, `rescale_no_gain`, `split_no_gain` — a rule
  that reads only the demand fold's twin (the planner does) cannot be
  moved by rewriting one hand's magnitudes, or by one person appearing as
  two AIDs with their voice divided: Emphasis.lean's identities lifted to
  utilities.
-/

set_option linter.unusedSectionVars false

namespace SolverCertificate

open Finset

/-! ### An abstract mechanism -/

/-- A direct mechanism over agents `σ`, outcomes `X`, reports `M`. `U j m`
is the utility over outcomes that agent `j`'s report `m` *encodes*; `alloc`
picks an outcome; `hmax` says it maximises the encoded welfare. -/
structure Mechanism (σ X M : Type*) [Fintype σ] where
  U : σ → M → X → ℝ
  alloc : (σ → M) → X
  hmax : ∀ (m : σ → M) (x : X), ∑ j, U j (m j) x ≤ ∑ j, U j (m j) (alloc m)

variable {σ X M : Type*} [Fintype σ] [DecidableEq σ]

/-- Everyone but `p`. -/
abbrev others (p : σ) : Finset σ := Finset.univ.erase p

theorem sum_split (p : σ) (g : σ → ℝ) :
    ∑ j, g j = g p + ∑ j ∈ others p, g j :=
  (Finset.add_sum_erase Finset.univ g (Finset.mem_univ p)).symm

/-! ### 1. What a lie can buy is bounded by what it costs the others -/

/-- A deviation by `p` (from a truthful profile `rep`, `U j (rep j) = u j`)
gains `p` at most the others' loss, both at true utilities. -/
theorem gain_le_others_loss (mech : Mechanism σ X M) (u : σ → X → ℝ)
    (rep : σ → M) (hrep : ∀ j, mech.U j (rep j) = u j) (p : σ) (mp : M) :
    u p (mech.alloc (Function.update rep p mp)) - u p (mech.alloc rep)
      ≤ ∑ j ∈ others p, (u j (mech.alloc rep)
                          - u j (mech.alloc (Function.update rep p mp))) := by
  have h := mech.hmax rep (mech.alloc (Function.update rep p mp))
  simp only [hrep] at h
  rw [sum_split p, sum_split p (fun j => u j (mech.alloc rep))] at h
  rw [Finset.sum_sub_distrib]
  linarith

/-- The others' loss under `p`'s lie is at most the VCG reading of the lie:
what they would have had with `p` absent (`x_minus`, any maximiser of
their own welfare), minus what they have under the lie. -/
theorem others_loss_le_vcg (u : σ → X → ℝ) (p : σ) (x_minus x_truth x_lie : X)
    (hmax_others : ∀ x, ∑ j ∈ others p, u j x ≤ ∑ j ∈ others p, u j x_minus) :
    ∑ j ∈ others p, (u j x_truth - u j x_lie)
      ≤ ∑ j ∈ others p, u j x_minus - ∑ j ∈ others p, u j x_lie := by
  rw [Finset.sum_sub_distrib]
  linarith [hmax_others x_truth]

/-- **The burn-meter bounds the lie.** A deviation gains at most the
externality of the *manipulated* outcome on the others — the number
`withdrawal-displacement` shows for that outcome. -/
theorem gain_le_externality (mech : Mechanism σ X M) (u : σ → X → ℝ)
    (rep : σ → M) (hrep : ∀ j, mech.U j (rep j) = u j) (p : σ) (mp : M)
    (x_minus : X)
    (hmax_others : ∀ x, ∑ j ∈ others p, u j x ≤ ∑ j ∈ others p, u j x_minus) :
    u p (mech.alloc (Function.update rep p mp)) - u p (mech.alloc rep)
      ≤ ∑ j ∈ others p, u j x_minus
        - ∑ j ∈ others p, u j (mech.alloc (Function.update rep p mp)) :=
  (gain_le_others_loss mech u rep hrep p mp).trans
    (others_loss_le_vcg u p x_minus _ _ hmax_others)

/-! ### 2. Charge the reading and truth is dominant (Groves) -/

/-- The Groves/Clarke transfer: what the others would have had without
`p`, minus what the reports say they have under `alloc m`. -/
noncomputable def grovesTransfer (mech : Mechanism σ X M) (p : σ) (x_minus : X)
    (m : σ → M) : ℝ :=
  ∑ j ∈ others p, mech.U j (m j) x_minus - ∑ j ∈ others p, mech.U j (m j) (mech.alloc m)

/-- Under the Groves transfer, reporting one's true utility is a dominant
strategy: against ANY reports of the others and ANY alternative report,
the quasilinear payoff of truth is at least as large. -/
theorem groves_truthful (mech : Mechanism σ X M) (p : σ) (x_minus : X)
    (u : X → ℝ) (truth : M) (htruth : mech.U p truth = u)
    (m_others : σ → M) (mp : M) :
    u (mech.alloc (Function.update m_others p mp))
        - grovesTransfer mech p x_minus (Function.update m_others p mp)
      ≤ u (mech.alloc (Function.update m_others p truth))
        - grovesTransfer mech p x_minus (Function.update m_others p truth) := by
  set mt := Function.update m_others p truth
  set ml := Function.update m_others p mp
  have h := mech.hmax mt (mech.alloc ml)
  rw [sum_split p, sum_split p (fun j => mech.U j (mt j) (mech.alloc mt))] at h
  have hp : mt p = truth := Function.update_self ..
  have hoth : ∀ j ∈ others p, mt j = ml j := fun j hj => by
    have hne : j ≠ p := Finset.ne_of_mem_erase hj
    simp only [mt, ml, Function.update_of_ne hne]
  have e1 : ∑ j ∈ others p, mech.U j (mt j) (mech.alloc ml)
      = ∑ j ∈ others p, mech.U j (ml j) (mech.alloc ml) :=
    Finset.sum_congr rfl fun j hj => by rw [hoth j hj]
  have e2 : ∑ j ∈ others p, mech.U j (mt j) (mech.alloc mt)
      = ∑ j ∈ others p, mech.U j (ml j) (mech.alloc mt) :=
    Finset.sum_congr rfl fun j hj => by rw [hoth j hj]
  have e3 : ∑ j ∈ others p, mech.U j (mt j) x_minus
      = ∑ j ∈ others p, mech.U j (ml j) x_minus :=
    Finset.sum_congr rfl fun j hj => by rw [hoth j hj]
  simp only [grovesTransfer]
  rw [hp, htruth] at h
  rw [e1, e2] at h
  rw [e3]
  linarith

/-! ### 3. A rule that reads only the twin cannot be moved by rewriting a hand -/

/-- If the allocation factors through a summary `tw` of the profile, two
profiles with the same summary give every agent the same utility. -/
theorem twin_dependent_invariant {P T : Type*} (tw : P → T) (g : T → X)
    (u : σ → X → ℝ) (m m' : P) (h : tw m = tw m') (j : σ) :
    u j (g (tw m)) = u j (g (tw m')) := by rw [h]

variable {ι : Type*}

/-- The demand fold's twin as the summary a profile `(voices, hands)` is
read through: one weight per key. -/
noncomputable def twinOf (W : ℝ) (O : Finset σ) (K : Finset ι)
    (pr : (σ → ℝ) × (σ → ι → ℝ)) : ι → ℝ :=
  fun k => twin W pr.1 pr.2 O K k

/-- Rewriting one owner's hand by a positive factor leaves the twin as it
was (`apply_reread_agree` + `rescale_invariant`). -/
theorem twinOf_rescale (W : ℝ) (O : Finset σ) (K : Finset ι) (v : σ → ℝ)
    (f : σ → ι → ℝ) {p : σ} (hp : p ∈ O) {c : ℝ} (hc : 0 < c) :
    twinOf W O K (v, Function.update f p (fun j => c * f p j)) = twinOf W O K (v, f) := by
  funext k
  simp only [twinOf]
  rw [apply_reread_agree W v f hp _ K k, rescale_invariant W (v p) hc k]
  ring

/-- **No gain from rescaling.** For any allocation that reads the twin, a
citizen who writes their hand ×c states the same thing and gets the same
outcome — every agent's utility is unchanged. -/
theorem rescale_no_gain (W : ℝ) (O : Finset σ) (K : Finset ι) (g : (ι → ℝ) → X)
    (u : σ → X → ℝ) (v : σ → ℝ) (f : σ → ι → ℝ) {p : σ} (hp : p ∈ O) {c : ℝ}
    (hc : 0 < c) (j : σ) :
    u j (g (twinOf W O K (v, Function.update f p (fun i => c * f p i))))
      = u j (g (twinOf W O K (v, f))) :=
  twin_dependent_invariant (twinOf W O K) g u _ _ (twinOf_rescale W O K v f hp hc) j

/-- One person as two AIDs: `p₁` and `p₂` hold the same hand, and the voice
`p₁` alone carried (`v'`) is divided between them (`v`). The twin is the
same (`coalition_linear`, and a voice of zero lays no mass). -/
theorem twinOf_split (W : ℝ) (O : Finset σ) (K : Finset ι) (v v' : σ → ℝ)
    (f : σ → ι → ℝ) {p₁ p₂ : σ} (h₁ : p₁ ∈ O) (h₂ : p₂ ∈ O) (hne : p₁ ≠ p₂)
    (hsame : f p₂ = f p₁)
    (hv₁ : v' p₁ = v p₁ + v p₂) (hv₂ : v' p₂ = 0)
    (hrest : ∀ j, j ≠ p₁ → j ≠ p₂ → v' j = v j) :
    twinOf W O K (v, f) = twinOf W O K (v', f) := by
  funext k
  simp only [twinOf, twin]
  have h₂' : p₂ ∈ O.erase p₁ := Finset.mem_erase.mpr ⟨hne.symm, h₂⟩
  rw [← Finset.add_sum_erase O _ h₁, ← Finset.add_sum_erase (O.erase p₁) _ h₂',
      ← Finset.add_sum_erase O (fun o => mass W (v' o) K (f o) k) h₁,
      ← Finset.add_sum_erase (O.erase p₁) (fun o => mass W (v' o) K (f o) k) h₂']
  have hrest' : ∑ x ∈ (O.erase p₁).erase p₂, mass W (v x) K (f x) k
      = ∑ x ∈ (O.erase p₁).erase p₂, mass W (v' x) K (f x) k := by
    refine Finset.sum_congr rfl fun x hx => ?_
    have hx₂ : x ≠ p₂ := Finset.ne_of_mem_erase hx
    have hx₁ : x ≠ p₁ := Finset.ne_of_mem_erase (Finset.mem_of_mem_erase hx)
    rw [hrest x hx₁ hx₂]
  rw [hrest', hv₁, hv₂, hsame, coalition_linear]
  simp only [mass, zero_mul, mul_zero]
  ring

/-- **No gain from splitting.** For any allocation that reads the twin, one
person appearing as two AIDs with their voice divided gets exactly what
they got as one — every agent's utility is unchanged. -/
theorem split_no_gain (W : ℝ) (O : Finset σ) (K : Finset ι) (g : (ι → ℝ) → X)
    (u : σ → X → ℝ) (v v' : σ → ℝ) (f : σ → ι → ℝ) {p₁ p₂ : σ}
    (h₁ : p₁ ∈ O) (h₂ : p₂ ∈ O) (hne : p₁ ≠ p₂) (hsame : f p₂ = f p₁)
    (hv₁ : v' p₁ = v p₁ + v p₂) (hv₂ : v' p₂ = 0)
    (hrest : ∀ j, j ≠ p₁ → j ≠ p₂ → v' j = v j) (j : σ) :
    u j (g (twinOf W O K (v, f))) = u j (g (twinOf W O K (v', f))) :=
  twin_dependent_invariant (twinOf W O K) g u _ _
    (twinOf_split W O K v v' f h₁ h₂ hne hsame hv₁ hv₂ hrest) j

end SolverCertificate
