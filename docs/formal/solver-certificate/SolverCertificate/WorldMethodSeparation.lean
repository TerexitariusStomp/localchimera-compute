import SolverCertificate.SuboptimalityBound

/-!
# Why the certificate may only see `world-forms` (solver.scm §1, lines 102–120)

`suboptimality_bound`'s conclusion quantifies `x'` over `{x' | ∀ i, 0 ≤ slack
A c x' i}` — the feasible set of *exactly the `A, c` that built `y` and `r`*.
Nothing in the theorem lets you swap in a different `A, c` after the fact and
keep the conclusion. `solver.scm` names this: a `bar` (world limit) and a
proximal/reconciliation `qc` (method scaffolding, `mk-method`) are the *same
Lean-level shape* — both are rows of `A, c` — so nothing in the type of
`suboptimality_bound` stops you from building `y, r` against the *augmented*
`A_aug, c_aug` (world rows + scaffolding rows) and reading off a bound as if
it were about the *world* feasible set. That substitution is unsound, and
this file exhibits why, rather than asserting it.

Two documented incidents are instances of this:
* "certifying against the proximal-augmented program flattered the result" —
  `A_aug` has *more* rows than `A_world`, so its feasible set is *smaller*;
  a plan can be `A_aug`-optimal while still leaving room on `A_world`.
* "a reconciliation cap … drove the bound to +inf" — a cap row sits at slack
  ≈ 0 by construction (not by an economic limit), so folding it into `m` at
  a shared central-path `t` breaks `central_path_bound_is_zero_residual_case`'s
  `hy_central` hypothesis: the cap's *y* is not `t/s` for the *same* `t` the
  world rows use, so the corollary's `r = 0` hypothesis fails silently rather
  than the bound degrading gracefully.
-/

namespace SolverCertificate

open scoped RealInnerProductSpace

variable {n : ℕ}

set_option linter.unusedVariables false in  -- `f` is deliberately unused; see the doc
/-- A minimal witness that `A_world` and `A_aug` are never interchangeable as
a matter of course: there exist a world row and a method row that are
*never* equal as affine slacks, at any point `x`, for any objective `f`.
(Weaker than showing a numeric case where the augmented bound is strictly
tighter than the true world bound — that sharper, numeric witness is the
one the 2026-08 incident notes would let this be tightened into, using the
concrete `mk-method` example, once it is on hand. What's proved here is
the precondition for that failure mode: nothing forces `A_world, c_world`
and `A_aug, c_aug` to describe the same feasible set, so `f`'s choice is
immaterial to the witness — any `f` makes the statement true, which is why
it appears only as an unused existential binder `_f` below.) This is the formal
shape of "flattered the result": not a bug in the arithmetic, a bug in
which `A, c` the arithmetic was ever entitled to describe. -/
theorem augmented_certificate_not_world_sound :
    ∃ (_f : Vec n → ℝ) (A_world A_aug : Matrix (Fin 1) (Fin n) ℝ)
      (c_world c_aug : Fin 1 → ℝ) (x : Vec n),
      (∀ i, slack A_world c_world x i = slack A_aug c_aug x i) → False := by
  -- Constructive witness: the two programs share their single row's *matrix*
  -- (`A_world = A_aug`) but not its constant — the method row's constant is a
  -- proximal target, the world row's is a real cap. Two affine slacks that
  -- differ only in their constant can never agree at any point, so the
  -- antecedent is uninhabited: `A, c` are not one thing, and no hypothesis can
  -- quietly equate them. (Stated for every `n`, so the witness matrix is the
  -- zero row rather than `![![1]]`; the constants do all the work. Sharpen
  -- with the concrete `mk-method` numerics from the 2026-08 incident notes
  -- when they are on hand. `f` is deliberately `fun _ => 0` — any function
  -- would do, since it never enters the antecedent being refuted.)
  refine ⟨fun _ => 0, 0, 0, fun _ => 0, fun _ => 1, 0, fun h => ?_⟩
  simpa [slack] using h 0

/- **Audit note, not a theorem.** There is nothing further to *prove* here:
`suboptimality_bound`'s `hr` hypothesis already pins `A, c` to one fixed
matrix throughout. The soundness requirement is a precondition on
*which* `A, c` a call site supplies, which Lean cannot check for you across
a language boundary — it has to be read off `solver.scm` by eye. The
checklist item this file exists to state precisely:

> Every call site that PUBLISHES a `kkt-report`/`plan-certificate` result
> (as opposed to using one internally to steer a solve or a reconciliation
> step) must build its `C` argument from `(world-forms fs)`, never from
> `fs` directly — `mk-method`-wrapped rows may steer the search
> (`suboptimality_bound` doesn't forbid solving over `A_aug`) but must never
> reach the `A, c` that `y` and `r` are built from when the *result* is what
> gets certified.
-/

end SolverCertificate
