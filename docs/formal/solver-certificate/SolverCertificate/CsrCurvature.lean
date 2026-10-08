import SolverCertificate.ModulusToStrongConvex

/-!
# The CSR sum's directional second derivative IS the φ″ quadratic form

The last identity between the shipped table and ε-dominance. The solver's
objective is a CSR sum `g y = Σᵢ φᵢ(cᵢ + ⟪aᵢ, y⟫)` — finitely many scalar
kinds composed with affine rows. `strong_convexity_modulus_lower_bound`
bounds the quadratic form `Σᵢ φ″ᵢ·⟪aᵢ,v⟫²`;
`strongConvexOn_univ_of_line_deriv2` consumes the directional second
derivative `deriv (deriv (t ↦ g(x+t•v)))`. This file proves the two are the
same number (`csr_line_deriv2`), and glues the chain shut
(`strongConvexOn_of_phi_table`, `argmin_lipschitz_of_phi_table`): from the
φ/φ′/φ″ columns' derivative facts (TensionKinds.lean) and the quadratic-form
bound, ε-dominance follows with NO analytic hypothesis left — what remains
is the numeric modulus itself, `m ≤ Σᵢ φ″ᵢ(…)·⟪aᵢ,v⟫²/‖v‖²`, which is
exactly the number `strong-convexity-modulus` computes and the display
reports.

Honest scope: the scalar hypotheses here take each kind's derivative facts
GLOBALLY along ℝ (`∀ r`), where the guarded kinds hold them on their open
regions only (`s > 1e-12`, `s < D`). On the central path the iterate stays
strictly inside every guard — that is what the barriers are for — so the
global-hypothesis form is the right interface for the smooth branch the
solver actually runs on; restricting the identity to the guarded region
verbatim would add bookkeeping about open sets, not truth.
-/

namespace SolverCertificate

open Set

variable {E : Type*} [NormedAddCommGroup E] [InnerProductSpace ℝ E]
variable {ι : Type*} [Fintype ι]

/-- One CSR row's argument along the line `t ↦ x + t•v` is affine in `t`. -/
private theorem line_arg (c : ℝ) (a x v : E) (t : ℝ) :
    c + inner ℝ a (x + t • v) = (c + inner ℝ a x) + t * inner ℝ a v := by
  rw [inner_add_right, real_inner_smul_right]; ring

/-- …and its derivative in `t` is the constant `⟪a, v⟫`. -/
private theorem hasDerivAt_line_arg (c : ℝ) (a x v : E) (t : ℝ) :
    HasDerivAt (fun s : ℝ => c + inner ℝ a (x + s • v)) (inner ℝ a v) t := by
  have h : HasDerivAt (fun s : ℝ => (c + inner ℝ a x) + s * inner ℝ a v)
      (inner ℝ a v) t := by
    have h0 := ((hasDerivAt_id t).mul_const (inner ℝ a v)).const_add (c + inner ℝ a x)
    exact h0.congr_deriv (by simp)
  exact h.congr_of_eventuallyEq (Filter.Eventually.of_forall fun s => line_arg c a x v s)

/-- `HasDerivAt.sum` in the lambda spelling (Mathlib's is stated on the
Pi-sum `∑ i, A i`, which is pointwise-equal but not syntactically the
function the statements here name). -/
private theorem hasDerivAt_sum' {A : ι → ℝ → ℝ} {A' : ι → ℝ} {t : ℝ}
    (h : ∀ i, HasDerivAt (A i) (A' i) t) :
    HasDerivAt (fun y : ℝ => ∑ i, A i y) (∑ i, A' i) t :=
  (HasDerivAt.sum fun i _ => h i).congr_of_eventuallyEq
    (Filter.Eventually.of_forall fun y => by simp)

/-- The CSR sum's FIRST derivative along a line: `csr-grad`'s loop, as the
chain rule over every row. -/
theorem csr_line_deriv (c : ι → ℝ) (a : ι → E) (φ φ' : ι → ℝ → ℝ)
    (h1 : ∀ i r, HasDerivAt (φ i) (φ' i r) r) (x v : E) (t : ℝ) :
    HasDerivAt (fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v)))
      (∑ i, φ' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v) t :=
  hasDerivAt_sum' fun i =>
    (h1 i _).comp t (hasDerivAt_line_arg (c i) (a i) x v t)

/-- **The identity**: the directional second derivative of the CSR sum is
the φ″ quadratic form — the exact number `strong_convexity_modulus_lower_bound`
bounds from below. -/
theorem csr_line_deriv2 (c : ι → ℝ) (a : ι → E) (φ φ' φ'' : ι → ℝ → ℝ)
    (h1 : ∀ i r, HasDerivAt (φ i) (φ' i r) r)
    (h2 : ∀ i r, HasDerivAt (φ' i) (φ'' i r) r) (x v : E) (t : ℝ) :
    deriv (deriv fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v))) t
      = ∑ i, φ'' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v ^ 2 := by
  have hdF : (deriv fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v)))
      = fun s : ℝ => ∑ i, φ' i (c i + inner ℝ (a i) (x + s • v)) * inner ℝ (a i) v :=
    funext fun s => (csr_line_deriv c a φ φ' h1 x v s).deriv
  have hG : HasDerivAt
      (fun s : ℝ => ∑ i, φ' i (c i + inner ℝ (a i) (x + s • v)) * inner ℝ (a i) v)
      (∑ i, φ'' i (c i + inner ℝ (a i) (x + t • v)) * inner ℝ (a i) v * inner ℝ (a i) v)
      t :=
    hasDerivAt_sum' fun i =>
      ((h2 i _).comp t (hasDerivAt_line_arg (c i) (a i) x v t)).mul_const _
  rw [hdF, hG.deriv]
  exact Finset.sum_congr rfl fun i _ => by ring

/-- **The chain, shut**: the φ/φ′/φ″ columns plus the quadratic-form bound
give strong convexity of the CSR objective — nothing analytic remains
between the table and `StrongConvexOn`. -/
theorem strongConvexOn_of_phi_table (c : ι → ℝ) (a : ι → E)
    (φ φ' φ'' : ι → ℝ → ℝ) (m : ℝ)
    (h1 : ∀ i r, HasDerivAt (φ i) (φ' i r) r)
    (h2 : ∀ i r, HasDerivAt (φ' i) (φ'' i r) r)
    (hquad : ∀ y v : E,
      m * ‖v‖ ^ 2 ≤ ∑ i, φ'' i (c i + inner ℝ (a i) y) * inner ℝ (a i) v ^ 2) :
    StrongConvexOn Set.univ m fun y => ∑ i, φ i (c i + inner ℝ (a i) y) := by
  apply strongConvexOn_univ_of_line_deriv2
  · exact fun x v s => (csr_line_deriv c a φ φ' h1 x v s).differentiableAt
  · intro x v
    have hdF : (deriv fun s : ℝ => ∑ i, φ i (c i + inner ℝ (a i) (x + s • v)))
        = fun s : ℝ => ∑ i, φ' i (c i + inner ℝ (a i) (x + s • v)) * inner ℝ (a i) v :=
      funext fun s => (csr_line_deriv c a φ φ' h1 x v s).deriv
    rw [hdF]
    exact fun s => (hasDerivAt_sum' fun i =>
      ((h2 i _).comp s (hasDerivAt_line_arg (c i) (a i) x v s)).mul_const _).differentiableAt
  · intro x v t
    rw [csr_line_deriv2 c a φ φ' φ'' h1 h2 x v t]
    exact hquad (x + t • v) v

/-- ε-dominance's Lipschitz-argmin step, straight from the table: what
remains between the shipped φ″ column and the deviation bound is one number,
the modulus `m` — the same number `strong-convexity-modulus` computes. -/
theorem argmin_lipschitz_of_phi_table (c : ι → ℝ) (a : ι → E)
    (φ φ' φ'' : ι → ℝ → ℝ) {m : ℝ} (hm : 0 < m)
    (h1 : ∀ i r, HasDerivAt (φ i) (φ' i r) r)
    (h2 : ∀ i r, HasDerivAt (φ' i) (φ'' i r) r)
    (hquad : ∀ y v : E,
      m * ‖v‖ ^ 2 ≤ ∑ i, φ'' i (c i + inner ℝ (a i) y) * inner ℝ (a i) v ^ 2)
    (xs : E → E)
    (hxs : ∀ w y, (∑ i, φ i (c i + inner ℝ (a i) (xs w))) + inner ℝ w (xs w)
        ≤ (∑ i, φ i (c i + inner ℝ (a i) y)) + inner ℝ w y)
    (w w' : E) :
    ‖xs w - xs w'‖ ≤ (1 / m) * ‖w - w'‖ :=
  argmin_lipschitz_of_strongConvexOn _ hm
    (strongConvexOn_of_phi_table c a φ φ' φ'' m h1 h2 hquad) xs hxs w w'

end SolverCertificate
