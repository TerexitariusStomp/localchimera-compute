# Federation Implementations: Comparison

Playnet has two federation planners. This document captures the
differences, overlaps, and gaps so future maintainers can decide which
to use and what to unify.

## TL;DR

| | `plan-federation.scm` | `federation.scm` |
|---|---|---|
| **Style** | Imperative, hashmap-based | Relational, lazy stream-based |
| **Substrate** | `hashmap` + stateful netter | Pure functional, miniKanren cstate |
| **Entry point** | `plan-federation` | `plan-federation-o` |
| **Status** | Production path | Experimental / incomplete |
| **Real callers** | 5 test files | 1 internal wrapper, no real tests |
| **Full DDMRP pipeline** | Yes (plan-for-unit, multi-pass) | No (one-pass `plan-o`) |
| **Priority convention** | Both priority-fn and weight-fn | Both priority-fn and weight-fn |
| **Cross-scope retraction** | Deficit-driven matching | Candidate-driven iteration |
| **Harmony integration** | Yes (exact loss at selection) | Yes (expected loss, re-sorted per step) |

**Which should you use?** `plan-federation.scm` for real planning work.
`federation.scm` is an in-progress reimplementation that hasn't been
wired into the full pipeline yet.

## Architecture differences

### Topology

**`plan-federation.scm`** has a flat view. `retract-across-scopes`
iterates the full hashmap of all scopes and all their candidates, then
applies explicit eligibility checks (same-scope exclusion, parent-child
exclusion). This is because any scope might contribute candidates for
any deficit anywhere in the hierarchy.

**`federation.scm`** has a hierarchical view. At each level of the
recursion, it only works with the children of the current scope.
Retraction candidates and deficits come from the children of this
parent — they're siblings by construction, so parent-child exclusion
is implicit in the level structure.

Neither is better; they're answering slightly different questions:
- `plan-federation.scm`: "Across the whole federation, who can help whom?"
- `federation.scm`: "At this level, which of my children should give
  up what for the others?"

### Matching algorithm

**`plan-federation.scm` (deficit-driven):**
```
sort candidates by expected loss
sort deficits by urgency
for each deficit (most urgent first):
  find best eligible candidate (smallest exact loss for this transfer)
  match, update, continue
```

**`federation.scm` (candidate-driven):**
```
sort candidates by expected loss given current deficits
for each candidate (smallest loss first):
  retract it
  re-run lateral matching globally
  if residual dropped: keep, re-sort remaining, continue
  else: try next candidate
```

Both produce sensible results, but with different failure modes:
- plan-federation.scm can leave a deficit unmatched if no eligible
  candidate exists for its specific spec
- federation.scm depends on lateral matching being the final arbiter —
  it just tries retractions and trusts the global residual metric

### Retraction side effects

**`plan-federation.scm`** calls `netter-retract` on the actual netter
state to reclaim allocated resources. The netter is a persistent
substrate (pure state monad, but threaded imperatively through the
hashmap).

**`federation.scm`** has no netter at all. Retraction is purely a
bookkeeping move within the federation result alist: the candidate is
removed from `retraction-candidates` and added to `surpluses`. The
underlying miniKanren search has already produced its plan; retraction
is a post-hoc adjustment.

This is a fundamental architectural difference, not a bug — federation.scm
operates on reified plans, plan-federation.scm on live stores.

## Protocol misalignments

Both produce "federation result" alists, but the key names differ:

| Concept | `plan-federation.scm` | `federation.scm` |
|---|---|---|
| Deficit list | `deficit-signals` | `deficits` |
| Surplus list | `surplus-signals` | `surpluses` |
| Match source scope | `from-scope` | `from` |
| Match target scope | `to-scope` | `to` |
| Spec identifier | `spec-id` | `spec` |
| Quantity | `quantity` | `qty` |

These aren't correctness bugs but they're a real trap for any code that
consumes both. Consumers have to know which implementation produced a
given result. **Recommendation**: normalize on one set of keys.
`spec-id`/`quantity` is more verbose but clearer; `spec`/`qty` is
already used by the internal signal helpers.

Other alist fields are consistent:
- `scope`, `plan`, `residual`, `retractions`, `retraction-candidates`,
  `lateral-matches`, `harmony` (when weight-fn is used)

## Harmony integration status (post-port)

Both now support the full harmony pipeline:

| Feature | `plan-federation.scm` | `federation.scm` |
|---|---|---|
| `#:weight-fn` parameter | ✓ | ✓ |
| Per-scope harmony in result | ✓ (via `aggregate-federation-harmony`) | ✓ (via child harmony aggregation in `evaluate-state`) |
| Harmony-guided retraction sort | ✓ (exact loss per deficit) | ✓ (expected loss given current deficits) |
| Harmony-aware candidate selection | ✓ (per-deficit re-pick) | ✓ (re-sort between steps) |
| Rich retraction records | ✓ (from-scope, to-scope, quantity) | ✓ (now, via `enrich-retraction-record`) |
| Lateral matching parent/child exclusion | ✓ (explicit) | ✓ (implicit via level structure) |

## Remaining gaps

### Gap 1: `match-at-level` uses upper-bound, not expected loss

`federation.scm`'s `match-at-level` (lateral matching within a parent)
uses simple first-match greedy. It doesn't benefit from harmony
awareness the way retraction does. This is probably fine — lateral
matching is just moving existing surpluses, not creating them, so
there's no "loss" to minimize.

`plan-federation.scm`'s `match-laterally` is similarly simple.
**No action needed.**

### Gap 2: federation.scm has no full DDMRP integration

`plan-federation.scm` is used with `plan-for-unit.scm` which runs the
full multi-pass DDMRP pipeline (buffer evaluation, TOY-gated primary
demand, derived replenishment, retry, supply phase). The result for
each scope contains netter state, signals, etc.

`federation.scm` uses `plan-o` from `plan-relation.scm` directly, which
is a single relational search without the multi-pass structure. A
plan from `federation.scm` lacks the buffer-aware scheduling that
`plan-federation.scm` gets for free.

**Action**: eventually wire `plan-for-unit` into `leaf-stream`, so
`federation.scm` can drive real multi-pass planning. Large change;
deferred.

### Gap 3: key naming mismatch

See table above. **Recommended fix**: add a translation layer or
normalize to one convention. Deferred — touching this would break
either all current tests or all internal helpers.

### Gap 4: scoring for "no matching deficit" is soft

In `expected-retraction-loss` (federation.scm), candidates with no
matching deficit get a huge sentinel value (`1e18 + weight`) so they
sort last. This is a hack. A cleaner solution: filter out candidates
with no matching deficit before sorting. Minor — doesn't affect
correctness since the loop would skip them anyway.

## Recommendations

1. **For new features**: implement in `plan-federation.scm` first, then
   port to `federation.scm`. Today's order of work should reflect that
   plan-federation.scm is the production path.

2. **For correctness fixes**: apply to both. I just did the exact-loss
   retraction port to keep them aligned.

3. **For architectural refactoring**: pick one implementation and
   delete the other, eventually. The current situation is a transitional
   duplication.

4. **For protocol normalization**: adopt consistent key names across
   both (probably `spec-id` and `quantity` since they're more explicit).
   Do this as a single sweep with test updates.

5. **For the DDMRP integration gap**: if `federation.scm` is meant to
   replace `plan-federation.scm`, it needs access to `plan-for-unit`'s
   multi-pass pipeline. This is the biggest blocker to making the
   relational version the production path.
