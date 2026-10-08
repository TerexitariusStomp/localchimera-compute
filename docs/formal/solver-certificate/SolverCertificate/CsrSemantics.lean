import SolverCertificate.SuboptimalityBound

/-!
# The CSR arrays denote the matrix the theorems talk about (solver.scm §0, lines 134-195)

Every theorem in this development is stated over a dense `Matrix (Fin m) (Fin n) ℝ`.
The solver never builds one. It stores the program as CSR flat arrays

    csr = #(nt nnz ptr const kind D w idx val)

and reads row `ti` as the span `ptr[ti] … ptr[ti+1]` of `(idx, val)` pairs
(`flatten`, solver.scm:138). So every certified claim rests on an unstated
premise: that the sparse arrays denote the dense matrix. This file states and
proves that premise, which until now was the widest gap between the Lean and
the Scheme — not a hard theorem, but the one whose absence made all the others
conditional on a reading.

A row is modelled as the code's own `f-coeffs`: a LIST of `(column, coefficient)`
pairs. The CSR flat arrays are exactly the concatenation of those lists with
`ptr` recording the boundaries, so a list is the faithful model of one span and
nothing about the flattening is lost — `ptr` is bookkeeping for where a row
starts, not information about the row.

One consequence is worth stating because it is easy to get wrong in either
direction: a column may legitimately appear TWICE in a row's list, and the
dense coefficient is then the SUM of both entries. `denseCoeff` sums rather
than picks, and `sparseEval_eq_denseSum` holds with no injectivity hypothesis
on `idx`, so a caller that emits `((j . 2.0) (j . 3.0))` gets the same answer
as one that emits `((j . 5.0))`. The inner loops (`term-values`, `csr-grad`,
`csr-hv`) all accumulate with `+=`, so this matches the implementation exactly.
-/

namespace SolverCertificate

variable {n m : ℕ}

/-- One CSR row as the code stores it: the `(idx, val)` pairs of a single span
`ptr[ti] … ptr[ti+1]`, i.e. the form's `f-coeffs` list. -/
abbrev SparseRow (n : ℕ) := List (Fin n × ℝ)

/-- The dense coefficient of column `j` in a sparse row: the SUM over every
entry naming `j`. Summing (rather than picking the first) is what makes
repeated columns behave the way the `+=` inner loops behave. -/
def denseCoeff (row : SparseRow n) (j : Fin n) : ℝ :=
  (row.map (fun e => if e.1 = j then e.2 else 0)).sum

/-- The inner loop of `term-values` (solver.scm:160-165): walk the span,
accumulating `val[k] · x[idx[k]]`. -/
def sparseEval (row : SparseRow n) (x : Vec n) : ℝ :=
  (row.map (fun e => e.2 * x e.1)).sum

/-- **The sparse walk computes the dense row product.** `Σ_k val[k]·x[idx[k]]`
over a span equals `Σ_j aⱼ·xⱼ` over all columns of the densified row. No
hypothesis that `idx` is injective or sorted: duplicates add, which is what
`+=` does. -/
theorem sparseEval_eq_denseSum (row : SparseRow n) (x : Vec n) :
    sparseEval row x = ∑ j, denseCoeff row j * x j := by
  induction row with
  | nil => simp [sparseEval, denseCoeff]
  | cons e row ih =>
    have hsplit : ∀ j : Fin n,
        denseCoeff (e :: row) j * x j
          = (if e.1 = j then e.2 else 0) * x j + denseCoeff row j * x j := by
      intro j
      simp only [denseCoeff, List.map_cons, List.sum_cons]
      ring
    rw [sparseEval, List.map_cons, List.sum_cons, ← sparseEval, ih,
      Finset.sum_congr rfl (fun j _ => hsplit j), Finset.sum_add_distrib]
    congr 1
    simp [Finset.sum_ite_eq]

/-- The matrix the CSR arrays denote: row `i`, column `j` is the dense
coefficient of the `i`-th span. This is the `A` every other file quantifies
over. -/
def csrMatrix (rows : Fin m → SparseRow n) : Matrix (Fin m) (Fin n) ℝ :=
  fun i j => denseCoeff (rows i) j

/-- **`term-values` computes `slack`.** The vector `sv` the solver threads
through `csr-grad`, `bar-slacks-min`, `retract-feasible`, `kkt-report` and
phase-I is, entry by entry, the `slack A c x i` of the denoted matrix. Every
theorem stated about `slack` therefore applies to the array the code actually
holds. -/
theorem csr_termValue_eq_slack (rows : Fin m → SparseRow n) (const : Fin m → ℝ)
    (x : Vec n) (i : Fin m) :
    const i + sparseEval (rows i) x = slack (csrMatrix rows) const x i := by
  rw [slack, sparseEval_eq_denseSum]
  rfl

end SolverCertificate
