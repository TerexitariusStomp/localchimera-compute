import Mathlib.Analysis.SpecialFunctions.Log.Deriv
import Mathlib.Analysis.Calculus.Deriv.Mul
import Mathlib.Analysis.Calculus.Deriv.Inv

/-!
# The φ′ column of `*kind-spec*` really is the derivative of the φ column
(tension-kinds.scm, lines 38-75)

`hasGradientAt_csrObjective` proves that `csr-grad`'s LOOP computes ∇f — but
only on the hypothesis that each kind's `φ′` is the derivative of that kind's
`φ`. That hypothesis is discharged here, kind by kind, for the shipped table.

`*kind-spec*` is a literal table of three expressions per kind — value, grad,
curv — written next to each other and maintained by hand. Nothing in Scheme
checks that column 3 is the derivative of column 2; a sign slip or a stale
edit to one column would produce a solver that descends a direction that is
not its gradient, converging to something that is not a minimum of the
objective it reports. These are the five checks that the columns agree.

Each kind's φ is GUARDED (`(if (> s 1e-12) … 1e12)`, `(if (< s D) … 0.0)`),
so the derivative claim is made where the guard's condition holds strictly —
the region is open, the function agrees with its smooth branch on a
neighbourhood, and `Filter.EventuallyEq` transports the derivative. On the
inactive side each φ is locally constant and φ′ is `0.0`, which agrees
trivially; only the boundary itself (`s = D`, `s = 1e-12`) is excluded, and
that is honest — at `s = D` the `des`/`held` φ is continuous but the table's
one-sided derivatives are what they are.
-/

namespace SolverCertificate

/-! ### `bar` (code 0): the swept log barrier, φ = −t·log s -/

/-- `bar`'s φ, guard included. -/
noncomputable def barPhi (t s : ℝ) : ℝ := if 1e-12 < s then -t * Real.log s else 1e12

/-- The open region a guard `1e-12 < s` cuts out is a neighbourhood of any of
its points — the fact that lets every guarded φ below be differentiated. -/
theorem eventually_guard {a s : ℝ} (hs : a < s) : ∀ᶠ u in nhds s, a < u :=
  eventually_gt_nhds hs

/-- **`bar`'s φ′ is right**: `d/ds (−t·log s) = −t/s`. -/
theorem hasDerivAt_barPhi (t s : ℝ) (hs : 1e-12 < s) :
    HasDerivAt (barPhi t) (-(t / s)) s := by
  have hne : s ≠ 0 := by positivity
  have h0 := (Real.hasDerivAt_log hne).const_mul (-t)
  have hval : -t * s⁻¹ = -(t / s) := by field_simp
  rw [hval] at h0
  have heq : barPhi t =ᶠ[nhds s] fun u => -t * Real.log u := by
    filter_upwards [eventually_guard hs] with u hu
    simp [barPhi, hu]
  exact h0.congr_of_eventuallyEq heq

/-! ### `frag` (code 3): the same barrier at a fixed governance weight -/

/-- `frag`'s φ. Identical in shape to `bar` with `w` in place of the swept `t`,
which is the point of the kind: it persists at the optimum. -/
noncomputable def fragPhi (w s : ℝ) : ℝ := if 1e-12 < s then -w * Real.log s else 1e12

/-- **`frag`'s φ′ is right**: `d/ds (−w·log s) = −w/s`. -/
theorem hasDerivAt_fragPhi (w s : ℝ) (hs : 1e-12 < s) :
    HasDerivAt (fragPhi w) (-(w / s)) s :=
  hasDerivAt_barPhi w s hs

/-! ### `qc` (code 2): the two-sided quadratic -/

/-- `qc`'s φ — unguarded, the one kind that is smooth everywhere. -/
noncomputable def qcPhi (w s : ℝ) : ℝ := w * s * s

/-- **`qc`'s φ′ is right**: `d/ds (w·s²) = 2·w·s`. -/
theorem hasDerivAt_qcPhi (w s : ℝ) : HasDerivAt (qcPhi w) (2 * w * s) s := by
  have h : HasDerivAt (qcPhi w) (w * 1 * s + w * s * 1) s :=
    ((hasDerivAt_id s).const_mul w).mul (hasDerivAt_id s)
  convert h using 1
  ring

/-! ### `des` (code 1): the bounded desire, φ = w·((D−s)/D)² -/

/-- `des`'s φ, guard included: a wholly unmet want costs `w` and no more, and
above satiation it costs nothing. -/
noncomputable def desPhi (D w s : ℝ) : ℝ := if s < D then w * ((D - s) / D) ^ 2 else 0

/-- **`des`'s φ′ is right**: `d/ds w·((D−s)/D)² = −2w(D−s)/D²`. -/
theorem hasDerivAt_desPhi (D w s : ℝ) (hD : 0 < D) (hs : s < D) :
    HasDerivAt (desPhi D w) (-2 * w * (D - s) / (D * D)) s := by
  have hDne : D ≠ 0 := ne_of_gt hD
  have hinner : HasDerivAt (fun u : ℝ => (D - u) / D) (-1 / D) s := by
    simpa using (((hasDerivAt_id s).const_sub D).div_const D)
  have h := (hinner.mul hinner).const_mul w
  have hval : w * (-1 / D * ((D - s) / D) + (D - s) / D * (-1 / D))
      = -2 * w * (D - s) / (D * D) := by
    field_simp
    ring
  rw [hval] at h
  have heq : desPhi D w =ᶠ[nhds s] fun u => w * ((D - u) / D * ((D - u) / D)) := by
    filter_upwards [eventually_lt_nhds hs] with u hu
    simp [desPhi, hu, pow_two]
  exact h.congr_of_eventuallyEq heq

/-! ### `held` (code 4): the desire that does not abandon, φ = w(D−s)²/(D·s) -/

/-- `held`'s φ, both guards included. -/
noncomputable def heldPhi (D w s : ℝ) : ℝ :=
  if s < D then (if 1e-12 < s then w * (D - s) ^ 2 / (D * s) else 1e12) else 0

/-- **`held`'s φ′ is right**: `d/ds w(D−s)²/(D·s) = −w(D²−s²)/(D·s²)`.

This is the one entry where the algebra is not obvious by eye —
`(D−s)²/s` differentiates to `(D−s)(−s−D)/s²`, and the `(D−s)(D+s) = D²−s²`
contraction is what puts the table's compact form there. -/
theorem hasDerivAt_heldPhi (D w s : ℝ) (hD : 0 < D) (hs0 : 1e-12 < s) (hsD : s < D) :
    HasDerivAt (heldPhi D w) (-(w * (D * D - s * s) / (D * s * s))) s := by
  have hDne : D ≠ 0 := ne_of_gt hD
  have hsne : s ≠ 0 := by positivity
  have hsub := (hasDerivAt_id s).const_sub D
  have hnum := (hsub.mul hsub).const_mul w
  have hden : HasDerivAt (fun u : ℝ => D * u) D s := by
    simpa using (hasDerivAt_id s).const_mul D
  have hdne : D * s ≠ 0 := mul_ne_zero hDne hsne
  have h := hnum.div hden hdne
  simp only [id_eq, Pi.mul_apply] at h
  have hval : (w * (-1 * (D - s) + (D - s) * -1) * (D * s)
      - w * ((D - s) * (D - s)) * D) / (D * s) ^ 2
      = -(w * (D * D - s * s) / (D * s * s)) := by
    field_simp
    ring
  rw [hval] at h
  have heq : heldPhi D w =ᶠ[nhds s] fun u => w * ((D - u) * (D - u)) / (D * u) := by
    filter_upwards [eventually_lt_nhds hsD, eventually_guard hs0] with u hu hu0
    simp [heldPhi, hu, hu0, pow_two]
  exact h.congr_of_eventuallyEq heq

/-! ### `cap` (code 5): the want whose ask is a wall, φ = w/(1+s) -/

/-- `cap`'s φ (tension-kinds.scm): the ask never appears — the value is
`w/(1+s)`, convex, decreasing, bounded, so a want on a good nobody makes is
unmet rather than infeasible; the ask enters only as a wall the engine emits
beside it (docs/planning/quantity-as-a-cap.md). No guard: `1 + s > 0` on the
whole domain the engine feeds it (`s ≥ 0`). -/
noncomputable def capPhi (w s : ℝ) : ℝ := w / (1 + s)

/-- The table's φ′ column, `−w/(1+s)²`, is the derivative of `capPhi`. -/
theorem hasDerivAt_capPhi (w s : ℝ) (hs : -1 < s) :
    HasDerivAt (capPhi w) (-(w / (1 + s) ^ 2)) s := by
  have h1 : (1 + s) ≠ 0 := by linarith
  have h := ((hasDerivAt_id s).const_add 1).inv h1
  have h' := h.const_mul w
  refine h'.congr_deriv ?_
  simp [pow_two]
  field_simp

/-!
### Second derivatives: the φ″ column is the derivative of the φ′ column

`strong_convexity_modulus_lower_bound` reads its curvature weights straight
off the table's third column, and `CsrCurvature.lean` turns those weights
into the directional second derivative `strongConvexOn_univ_of_line_deriv2`
consumes — so the third column being the derivative of the second is the
last hand-maintained identity in the chain. Same guarded style as above:
each claim is made where the guard holds strictly.
-/

/-- `bar`'s φ′ as the table writes it, guard included. -/
noncomputable def barPhi' (t s : ℝ) : ℝ := if 1e-12 < s then -(t / s) else 0

/-- **`bar`'s φ″ is right**: `d/ds (−t/s) = t/s²`. -/
theorem hasDerivAt_barPhi' (t s : ℝ) (hs : 1e-12 < s) :
    HasDerivAt (barPhi' t) (t / s ^ 2) s := by
  have hne : s ≠ 0 := by positivity
  have h := ((hasDerivAt_inv hne).const_mul (-t))
  have hval : -t * -(s ^ 2)⁻¹ = t / s ^ 2 := by field_simp
  rw [hval] at h
  have heq : barPhi' t =ᶠ[nhds s] fun u => -t * u⁻¹ := by
    filter_upwards [eventually_guard hs] with u hu
    simp [barPhi', hu, div_eq_mul_inv]
  exact h.congr_of_eventuallyEq heq

/-- `frag`'s φ′ as the table writes it. -/
noncomputable def fragPhi' (w s : ℝ) : ℝ := if 1e-12 < s then -(w / s) else 0

/-- **`frag`'s φ″ is right**: `d/ds (−w/s) = w/s²`. -/
theorem hasDerivAt_fragPhi' (w s : ℝ) (hs : 1e-12 < s) :
    HasDerivAt (fragPhi' w) (w / s ^ 2) s :=
  hasDerivAt_barPhi' w s hs

/-- `qc`'s φ′ — smooth everywhere, like its φ. -/
noncomputable def qcPhi' (w s : ℝ) : ℝ := 2 * w * s

/-- **`qc`'s φ″ is right**: `d/ds (2ws) = 2w`. -/
theorem hasDerivAt_qcPhi' (w s : ℝ) : HasDerivAt (qcPhi' w) (2 * w) s := by
  have h := (hasDerivAt_id s).const_mul (2 * w)
  exact h.congr_deriv (mul_one _)

/-- `des`'s φ′ as the table writes it, guard included. -/
noncomputable def desPhi' (D w s : ℝ) : ℝ := if s < D then -2 * w * (D - s) / (D * D) else 0

/-- **`des`'s φ″ is right**: `d/ds (−2w(D−s)/D²) = 2w/D²`. -/
theorem hasDerivAt_desPhi' (D w s : ℝ) (hD : 0 < D) (hs : s < D) :
    HasDerivAt (desPhi' D w) (2 * w / (D * D)) s := by
  have hDne : D * D ≠ 0 := by positivity
  have h := (((hasDerivAt_id s).const_sub D).const_mul (-2 * w)).div_const (D * D)
  have hval : -2 * w * -1 / (D * D) = 2 * w / (D * D) := by ring
  rw [hval] at h
  have heq : desPhi' D w =ᶠ[nhds s] fun u => -2 * w * (D - u) / (D * D) := by
    filter_upwards [eventually_lt_nhds hs] with u hu
    simp [desPhi', hu]
  exact h.congr_of_eventuallyEq heq

/-- `held`'s φ′ as the table writes it, both guards included. -/
noncomputable def heldPhi' (D w s : ℝ) : ℝ :=
  if s < D then (if 1e-12 < s then -(w * (D * D - s * s) / (D * s * s)) else 0) else 0

/-- **`held`'s φ″ is right**: `d/ds (−w(D²−s²)/(D·s²)) = 2wD/s³`. The table's
compact third column drops the `1/D` against the numerator's `D²` the same
way the first derivative contracted `(D−s)(D+s)`. -/
theorem hasDerivAt_heldPhi' (D w s : ℝ) (hD : 0 < D) (hs0 : 1e-12 < s) (hsD : s < D) :
    HasDerivAt (heldPhi' D w) (2 * w * D / (s * s * s)) s := by
  have hDne : D ≠ 0 := ne_of_gt hD
  have hsne : s ≠ 0 := by positivity
  have hnum : HasDerivAt (fun u : ℝ => w * (D * D - u * u)) (-(w * (2 * s))) s := by
    have h := (((hasDerivAt_id s).mul (hasDerivAt_id s)).const_sub (D * D)).const_mul w
    exact h.congr_deriv (by simp only [id_eq]; ring)
  have hden : HasDerivAt (fun u : ℝ => D * (u * u)) (D * (2 * s)) s := by
    have h := ((hasDerivAt_id s).mul (hasDerivAt_id s)).const_mul D
    exact h.congr_deriv (by simp only [id_eq]; ring)
  have hdne : D * (s * s) ≠ 0 := by positivity
  have h := (hnum.div hden hdne).neg
  have hval : -((-(w * (2 * s)) * (D * (s * s)) - w * (D * D - s * s) * (D * (2 * s)))
      / (D * (s * s)) ^ 2) = 2 * w * D / (s * s * s) := by
    field_simp
    ring
  rw [hval] at h
  have heq : heldPhi' D w =ᶠ[nhds s] fun u => -(w * (D * D - u * u) / (D * (u * u))) := by
    filter_upwards [eventually_lt_nhds hsD, eventually_guard hs0] with u hu hu0
    have : D * u * u = D * (u * u) := by ring
    simp [heldPhi', hu, hu0, this]
  exact h.congr_of_eventuallyEq heq

/-- `cap`'s φ′ — no guard, like its φ (`1 + s > 0` on the engine's domain). -/
noncomputable def capPhi' (w s : ℝ) : ℝ := -(w / (1 + s) ^ 2)

/-- **`cap`'s φ″ is right**: `d/ds (−w/(1+s)²) = 2w/(1+s)³`. -/
theorem hasDerivAt_capPhi' (w s : ℝ) (hs : -1 < s) :
    HasDerivAt (capPhi' w) (2 * w / (1 + s) ^ 3) s := by
  have h1 : (1 + s) ≠ 0 := by linarith
  have hpow : HasDerivAt (fun u : ℝ => (1 + u) ^ 2) (2 * (1 + s)) s := by
    have h := ((hasDerivAt_id s).const_add 1).pow 2
    exact h.congr_deriv (by simp only [id_eq]; ring)
  have h := (hpow.inv (pow_ne_zero 2 h1)).const_mul (-w)
  have h' : HasDerivAt (fun u : ℝ => -w * ((1 + u) ^ 2)⁻¹) (2 * w / (1 + s) ^ 3) s :=
    h.congr_deriv (by field_simp; try ring)
  exact h'.congr_of_eventuallyEq
    (Filter.Eventually.of_forall fun u => by simp [capPhi', div_eq_mul_inv])

/-! ### `cap` with its reference scale (code 5's shipped form, φ = w/(1+s/c)) -/

/-- The shipped kind: `cap` reads its D slot as the spec's REFERENCE SCALE
`c` (a catalogue fact, never a report — engine `set-cap-scale!`), so
φ = w/(1+s/c) is scale-free. It is the c = 1 member reparameterised,
`capPhiC c w s = capPhi w (s/c)`, and both derivative columns follow by one
chain rule each — matching the table's grad `−w/(c·(1+s/c)²)` and curv
`2w/(c²·(1+s/c)³)` with D read as c. -/
noncomputable def capPhiC (c w s : ℝ) : ℝ := w / (1 + s / c)

theorem capPhiC_eq (c w s : ℝ) : capPhiC c w s = capPhi w (s / c) := rfl

theorem hasDerivAt_capPhiC (c w s : ℝ) (hc : 0 < c) (hs : -c < s) :
    HasDerivAt (capPhiC c w) (-(w / (1 + s / c) ^ 2) * (1 / c)) s := by
  have hin : HasDerivAt (fun r : ℝ => r / c) (1 / c) s := (hasDerivAt_id s).div_const c
  have hgt : (-1 : ℝ) < s / c := by
    rw [neg_lt, ← neg_div]
    exact (div_lt_one hc).mpr (by linarith)
  have h := (hasDerivAt_capPhi w (s / c) hgt).comp s hin
  exact h.congr_of_eventuallyEq
    (Filter.Eventually.of_forall fun r => by simp [capPhiC, capPhi, Function.comp])

noncomputable def capPhiC' (c w s : ℝ) : ℝ := -(w / (1 + s / c) ^ 2) * (1 / c)

theorem hasDerivAt_capPhiC' (c w s : ℝ) (hc : 0 < c) (hs : -c < s) :
    HasDerivAt (capPhiC' c w) (2 * w / (1 + s / c) ^ 3 * (1 / c) * (1 / c)) s := by
  have hin : HasDerivAt (fun r : ℝ => r / c) (1 / c) s := (hasDerivAt_id s).div_const c
  have hgt : (-1 : ℝ) < s / c := by
    rw [neg_lt, ← neg_div]
    exact (div_lt_one hc).mpr (by linarith)
  have houter : HasDerivAt (fun r : ℝ => capPhi' w r * (1 / c))
      (2 * w / (1 + s / c) ^ 3 * (1 / c)) (s / c) :=
    (hasDerivAt_capPhi' w (s / c) hgt).mul_const (1 / c)
  have h := houter.comp s hin
  exact h.congr_of_eventuallyEq
    (Filter.Eventually.of_forall fun r => by simp [capPhiC', capPhi', Function.comp])

end SolverCertificate
