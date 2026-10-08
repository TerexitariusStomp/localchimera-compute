import Mathlib.Algebra.Order.Field.Basic
import Mathlib.Data.Real.Basic
import Mathlib.Order.MinMax
import Mathlib.Tactic.NormNum
import Mathlib.Tactic.Linarith
import Mathlib.Tactic.Push

/-!
# Quantity as a cap: what strategyproofness forces, and what stays chosen
(docs/planning/quantity-as-a-cap.md, THE INVESTIGATION)

The two-agent micro-model that settles the doc's flagged claim without
leaning on remembered theorems. One divisible good; an agent's true peak is
`t`, their report `q`, and their utility for an allocation `s` is
`min s t` — satiated, free disposal, no resale: units beyond the peak are
worth nothing. A rule `f q qj` answers the agent's own report and the
other's, and is *capped*: nobody is delivered beyond their ask.

What is proved:

* `level_rule_strategyproof` — every rule `min q (L qj)`, the report
  entering ONLY as a cap and the level `L` arbitrary in the other's report,
  is strategyproof. `L` can encode any weights or priority, so this is the
  whole weighted water-filling FAMILY at once: **the sacrifice pattern is
  chosen, not forced.**
* `forced_flatness` — strategyproofness + the cap force the allocation to
  be constant in the report above any rationed report: **flat where a lie
  would live is not one design among several; it is what honesty means.**
* `sp_monotone` — monotonicity in the own report is NOT an extra axiom: it
  follows from strategyproofness + the cap (the deviation that proves it is
  UNDERreporting — a rule that punished a bigger ask would reward asking
  small).
* `sp_rule_is_level_rule` — the representation, from strategyproofness +
  the cap ALONE: every such rule is either never-rationed (`f q = q`, the
  level-`∞` member) or exactly `min q ℓ` for one level `ℓ`. Nothing beyond
  SP and the cap was needed — the doc may state the boundary as: *forced =
  the min-with-a-level SHAPE; chosen = the level.*
* `proportional_manipulable` — the concrete counterexample the engine
  fixture (`test-owned-delivery`'s 15.4/19.6 split) instantiates: under the
  proportional rule `S·q/(q+qj)` with supply 24 against a report of 20, a
  peak-10 agent gets 8 truthfully and 10 by padding to 20.
* `padding_inert_above_level` — for a level rule, any report at or above
  the true peak yields exactly truth's utility: overstating is inert, not
  punished. The penalty structure is gone because the gradient is gone.

Everything is stated for one agent against an arbitrary other-report, which
is what "dominant strategy" quantifies over; two agents appear in the
proofs as the two deviations (pad up, shade down).
-/

namespace SolverCertificate
namespace QuantityAsCap

/-- Utility of an allocation `s` to a citizen whose true peak is `t`:
satiated with free disposal and no resale — units beyond the peak add
nothing. -/
def u (t s : ℝ) : ℝ := min s t

/-- A rule is capped: nobody is delivered beyond their own ask. -/
def Capped (f : ℝ → ℝ → ℝ) : Prop := ∀ q qj, f q qj ≤ q

/-- Strategyproof for the row's own citizen: against any other-report,
reporting the true peak is (weakly) best. -/
def SP (f : ℝ → ℝ → ℝ) : Prop := ∀ t qj q, u t (f q qj) ≤ u t (f t qj)

/-- The level-rule family: the own report enters ONLY as a cap; the level
`L` — any function of the other's report — carries every weight or
priority choice. -/
def levelRule (L : ℝ → ℝ) (q qj : ℝ) : ℝ := min q (L qj)

theorem level_rule_capped (L : ℝ → ℝ) : Capped (levelRule L) :=
  fun _ _ => min_le_left _ _

/-- CHOSEN: every member of the level-rule family is strategyproof,
whatever sacrifice pattern its level encodes. -/
theorem level_rule_strategyproof (L : ℝ → ℝ) : SP (levelRule L) := by
  intro t qj q
  simp only [u, levelRule]
  rw [min_eq_left (min_le_left t (L qj))]
  exact le_min (min_le_right _ _) ((min_le_left _ _).trans (min_le_right _ _))

/-- FORCED: under strategyproofness and the cap, the allocation is constant
in the own report above any rationed report — flat exactly where a padded
report would live. Deviation (a): if a bigger report won more, the peak-`q`
citizen pads. Deviation (b): if it won less, the peak-`q'` citizen shades
down to `q`. -/
theorem forced_flatness {f : ℝ → ℝ → ℝ} (hSP : SP f) (hcap : Capped f)
    {qj q : ℝ} (hration : f q qj < q) :
    ∀ q', q ≤ q' → f q' qj = f q qj := by
  intro q' hq
  by_contra hne
  rcases lt_or_gt_of_ne hne with hlt | hgt
  · -- f q' qj < f q qj: the peak-q' citizen gains by shading down to q
    have h := hSP q' qj q
    have ha : f q qj ≤ q' := (hcap q qj).trans hq
    rw [u, u, min_eq_left ha] at h
    exact absurd (h.trans (min_le_left _ _)) (not_le.mpr hlt)
  · -- f q' qj > f q qj: the peak-q citizen gains by padding to q'
    have h := hSP q qj q'
    rw [u, u, min_eq_left hration.le] at h
    exact absurd h (not_le.mpr (lt_min hgt hration))

/-- NOT an extra axiom: monotonicity in the own report follows from
strategyproofness + the cap in one line — the deviation that proves it is
UNDERreporting: were a larger report answered with less, the larger-peaked
citizen would shade down and keep the smaller report's answer whole. -/
theorem sp_monotone {f : ℝ → ℝ → ℝ} (hSP : SP f) (hcap : Capped f)
    (qj : ℝ) : Monotone (fun q => f q qj) := by
  intro q q' hq
  have h := hSP q' qj q
  rw [u, u, min_eq_left ((hcap q qj).trans hq), min_eq_left (hcap q' qj)] at h
  exact h

/-- THE BOUNDARY, exactly: strategyproofness + the cap alone force the
min-with-a-level SHAPE — every such rule is the never-rationed member
(`f q = q`, level ∞) or `min q ℓ` for one level `ℓ` (the constant the rule
answers on its rationed region). What stays free is the level itself: the
sacrifice pattern. No efficiency, anonymity, continuity or monotonicity
axiom was needed. -/
theorem sp_rule_is_level_rule {f : ℝ → ℝ → ℝ} (hSP : SP f) (hcap : Capped f)
    (qj : ℝ) :
    (∀ q, f q qj = q) ∨ (∃ ℓ, ∀ q, f q qj = min q ℓ) := by
  by_cases hall : ∀ q, f q qj = q
  · exact Or.inl hall
  · right
    push Not at hall
    obtain ⟨q0, hq0⟩ := hall
    have hration : f q0 qj < q0 := lt_of_le_of_ne (hcap q0 qj) hq0
    refine ⟨f q0 qj, fun q => ?_⟩
    rcases le_total q q0 with hle | hge
    · rcases lt_or_eq_of_le (hcap q qj) with hr | hfull
      · -- rationed at q ≤ q0: flatness carries q's answer up to q0
        have hflat := forced_flatness hSP hcap hr q0 hle
        rw [← hflat, min_eq_right (hflat.symm ▸ hr.le)]
      · -- full at q: monotonicity puts the level at or above q
        have hm : f q qj ≤ f q0 qj := sp_monotone hSP hcap qj hle
        rw [hfull] at hm
        rw [hfull, min_eq_left hm]
    · -- q above the rationed q0: flatness answers the level itself
      have hflat := forced_flatness hSP hcap hration q hge
      rw [hflat, min_eq_right (hration.le.trans hge)]

/-- The proportional rule — supply split in proportion to reports, the rule
our ask-relative tension implements (`test-owned-delivery`'s 15.4/19.6). -/
noncomputable def proportional (S q qj : ℝ) : ℝ := S * q / (q + qj)

/-- MANIPULABLE: with supply 24 against an honest report of 20, a peak-10
citizen is served 8 truthfully and 10 by padding to 20. The two-line
counterexample the engine fixture is. -/
theorem proportional_manipulable : ¬ SP (fun q qj => proportional 24 q qj) := by
  intro h
  have h10 := h 10 20 20
  have e1 : proportional 24 20 20 = 12 := by
    simp only [proportional]; norm_num
  have e2 : proportional 24 10 20 = 8 := by
    simp only [proportional]; norm_num
  simp only [u] at h10
  rw [e1, e2] at h10
  norm_num at h10

/-- Inert, not punished: under a level rule, any report at or above the true
peak yields exactly truth's utility — the allocation's sensitivity to the
report is zero everywhere a lie would pay, so no penalty structure is
needed to make truth optimal. -/
theorem padding_inert_above_level (L : ℝ → ℝ) {t q : ℝ} (qj : ℝ)
    (hq : t ≤ q) :
    u t (levelRule L q qj) = u t (levelRule L t qj) := by
  simp only [u, levelRule]
  rw [min_eq_left (min_le_left t (L qj)), min_assoc, min_comm (L qj) t,
      min_eq_right ((min_le_left t (L qj)).trans hq)]

/-- Weak monotonicity (Rochet 1987; Bikhchandani et al. 2006), the
two-type inequality: for types `t`, `t'` answered `x = f t qj`, `y = f t' qj`,
the type that was given `x` values x-over-y at least as much as the type
that was given `y` does. It is what strategyproofness at both types adds up
to, so it is NECESSARY for truth to be dominant — here, with `u = min`. -/
def WMON (f : ℝ → ℝ → ℝ) : Prop :=
  ∀ t t' qj, u t' (f t qj) - u t' (f t' qj) ≤ u t (f t qj) - u t (f t' qj)

/-- Strategyproofness ⇒ weak monotonicity: add truth's two inequalities.
The converse is NOT claimed: the sufficiency theorems (Saks–Yu 2005,
Bikhchandani et al. 2006) construct the PAYMENTS that implement a weakly
monotone rule — the Rochet potential, ∫ sensitivity — and a commons without
money has none to construct. Truth with zero payments is the stronger
condition, and on this domain it is exactly the level-rule shape
(`sp_rule_is_level_rule`): WMON ⟺ implementable with transfers; the
min-with-a-level shape ⟺ implementable without. -/
theorem sp_implies_wmon {f : ℝ → ℝ → ℝ} (hSP : SP f) : WMON f := by
  intro t t' qj
  have h1 := hSP t qj t'    -- truth at t beats reporting t'
  have h2 := hSP t' qj t    -- truth at t' beats reporting t
  linarith

/-! ### Rigor audit (2026-09): the wall is a swept barrier, not an exact `≤`

`Capped` models the ask's wall as an EXACT inequality; the engine enforces
it with `mk-bar`, a log barrier whose weight is swept toward zero but
FLOORED at `t_min` — so the true wall never fully forbids exceeding the
ask, only prices it. The question this raises: does that softness reopen
the manipulability the cap shape was built to close?

`softLevelRule_strategyproof` answers no, unconditionally, at the single
wall: for ANY slack function `ε` — even one that grows without bound, even
one that depends on the very report that earns it — a rule that lets the
own report exceed itself by `ε q` before the level cap applies is exactly
as strategyproof as the hard-capped one. The reason is structural, not
numerical: satiation (`u = min s t`) already discards anything the wall's
softness delivers past the citizen's own peak, and the level `L qj` — set
by the OTHER report alone, never this one — already discards anything the
softness delivers past the citizen's own ration. The softness has nowhere
left to pay out. So the one channel a swept wall COULD open — the level
itself drifting with the softened report, through the shared supply
clearing equation — is not a new incentive question at all: it is exactly
the `hfeas`/`hnw` exactness `CrossCell.lean` already prices, and closing
IT is `InTheLarge.lean`'s `dist_from_optimum_of_curvature_gap`: any
solved-to-tolerance point sits within `‖r‖/σ` of the exact one, in the
SAME σ the honesty radius already reports. There is no separate "wall
softness" epsilon to invent; the certificate's own gap is the whole of it. -/

/-- The soft-wall rule: the own report may exceed itself by a slack `ε q`
— ARBITRARY, possibly report-dependent, possibly unbounded — before the
level (set by the other report alone) caps it. -/
noncomputable def softLevelRule (L : ℝ → ℝ) (ε : ℝ → ℝ) (q qj : ℝ) : ℝ :=
  min (q + ε q) (L qj)

/-- **The swept wall's softness is free.** Whatever `ε` the barrier's floor
weight buys — any nonnegative function of the own report, however large or
however it varies — `softLevelRule` stays exactly strategyproof. Padding
gains nothing because satiation already caps the citizen's own utility at
their peak `t` regardless of how much slack the wall hands out past it;
shading gains nothing because the level `L qj`, reading only the OTHER
report, already caps the citizen's utility below whatever slack their own
smaller report bought. -/
theorem softLevelRule_strategyproof (L : ℝ → ℝ) (ε : ℝ → ℝ) (hε : ∀ q, 0 ≤ ε q) :
    SP (softLevelRule L ε) := by
  intro t qj q
  simp only [u, softLevelRule]
  rcases le_total (L qj) t with hL | hL
  · -- rationed: the level caps both the truthful and the deviant utility at L qj
    have hqside : min (min (q + ε q) (L qj)) t = min (q + ε q) (L qj) :=
      min_eq_left ((min_le_right _ _).trans hL)
    have htside : min (min (t + ε t) (L qj)) t = min (t + ε t) (L qj) :=
      min_eq_left ((min_le_right _ _).trans hL)
    rw [hqside, htside]
    calc min (q + ε q) (L qj) ≤ L qj := min_le_right _ _
      _ = min (t + ε t) (L qj) :=
        (min_eq_right (hL.trans (le_add_of_nonneg_right (hε t)))).symm
  · -- unrationed: satiation at the peak caps both sides at t
    have htfull : min (t + ε t) (L qj) ≥ t := le_min (le_add_of_nonneg_right (hε t)) hL
    rw [min_eq_right htfull]
    exact min_le_right _ _

end QuantityAsCap
end SolverCertificate
