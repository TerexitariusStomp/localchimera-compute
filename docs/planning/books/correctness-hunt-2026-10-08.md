# Found by running: the correctness hunt of 2026-10-08

`beyond-valueflows.md` §4.4 lists defects that were *read*, with the note "each needs a
test before it is treated as established". This hunt put them, and others the reading
never reached, to the test: the compiler over every live module, the suites that were red,
and seeded property tests over the planner, the books and the credit ledger. What it
found stands here with its evidence, its cause, what was done and what remains.

Status words: **fixed** (a test that failed before passes now), **held back** (the change
is made and withdrawn on purpose, with the reason), **open** (confirmed by running, not
yet changed), **not reproduced** (tried, and the code does the right thing).

Everything below reproduces from the repository: the sweep is `tools/lint/compile-warnings.sh`
(`make lint-compile`, part of `make test`), the findings that stay open have a script in
`tools/probes/`, and the laws that held are the suites `tests/*/test-property-*.scm`.

---

## 1. What the compiler found

Compiling every module outside `deprecated/` with `-Wunbound-variable -Warity-mismatch
-Wformat` reported 281 "possibly unbound" names and 4 wrong-argument-count calls. Most
unbound names sit in include-fragments (`solve/engine/robust.scm`, `comms/*.scm`, the
farm seeders): a file with no `define-module` is read inside another module's namespace,
where its names are bound, so it is no finding. The rest were calls that raise on first
use. A suite reached none of them.

| # | Where | Defect | Effect | Status |
|---|---|---|---|---|
| 1 | `gateway/terminal.scm` | the reader called `read!`, which nothing defines; `bytevector-copy` took three arguments | every read raised, was taken for end-of-file, and the session closed before relaying a byte | fixed |
| 2 | `gateway/terminal.scm` | the reader thread was made inside the spawn turn and inherited its `current-syscaller` | each send failed: "Can't use transactormap-set! on merged transactormap" | fixed |
| 3 | `identity/seat.scm`, `identity/oobi-host.scm` | `hashmap-size`, which `(goblins utils hashmap)` does not export | `member-count` and the OOBI host's `count` raised | fixed |
| 4 | `planner/knowledge/dsl/recipe-library.scm` | `hashmap-delete` (the export is `hashmap-remove`) | `remove-recipe` raised | fixed |
| 5 | `lang/system-kb.scm` | `delete-duplicates` with no srfi-1 import | `query-layers` raised | fixed |
| 6 | `interface/backends/scope.scm` | ten accessors and `record-and-monitor` named, none imported (the umbrella module used to supply them) | the `resources` and `events` commands and the `record-event` door raised; the gateway imports this module | fixed |
| 7 | `planner/ddmrp/buffers.scm` | `standard-profile` built a profile with 7 of 14 fields; `compute-min-max-buffer` called the zone-level function with 3 of 6 arguments | the shorthand profile and the min/max bounds raised | fixed |
| 8 | `planner/knowledge/recipes/berlin-flotte.scm` | `bt-cargo-bike-resource` called with `#:lender` and `#:window`, keywords it has no slot for | `flotte-berlin-resources` raised on every call | fixed |
| 9 | `planner/knowledge/recipes/federation.scm` | `generate-id` unbound | `seed-federation-inventory` raised on its first item | fixed |
| 10 | `goblins/ocapn/netlayer/reticulum.scm` | `let-values` with no srfi-11 import, in the setup that opens the bridge's sockets itself | latent: the gateway hands the netlayer its sockets, so production never took the path (its log holds no unbound-variable line) | fixed |

Each has a test that failed before: `test-terminal-session`, `test-scope-handler`,
`test-berlin-flotte`, `test-federation-seed`, `test-netlayer-reticulum-bindings`, and
checks added to `test-ddmrp-advanced`, `test-recipe-library`, `test-knowledge` and
`test-signup-with-icp`.

**The gate.** `make lint-compile` runs the sweep and refuses a wrong argument count or an
unbound name in a module. It takes about three minutes on four cores. The ten modules that
do not compile in the test environment are listed by the script (a missing `libgcrypt`
for `push/adapter` and `push/vapid`, `(mosquitto client)`, `(hoot ffi)`, a Hoot-only
import, two data emitters that read an environment variable): their warnings were never
reached, and the push code in particular has no suite that loads it.

## 2. What the suites found

### 2.1 The governed dials and the voice field never reached a live solve (fixed)

`plan-scope` hands the engine `#:pref-bound #:emp-rho #:kappa #:want-as-cap
#:stock-draw-hours` (the dials governance registers) and `#:voice-tau #:voice-pushes
#:voice-hours #:scope-path` (the voice field). The single deterministic assembly in
`%plan-from-records` set them after it ingested. The robust assembly, which every live
scope takes (a bioregion's futures, or the single "deterministic" future), set none.
A dial a scope's governance stated, and the voice a stance carried, changed nothing in a
live plan; `voice-displacement` compared two equal solves.

*Evidence.* `tests/scope/test-solve-settings-reach-every-path.scm` passes a distinctive
value for each through `plan-scope->alist` and reads the engine's globals: all seven
checks failed before the change and pass after.

*Change.* `apply-solve-settings!` (engine.scm) is the one write; `%plan-from-records` and
`robust-assemble` both call it after their ingest. It stands after the globals it writes.

### 2.2 The world a scenario ingests (fixed in part, held back in part)

`ingest-records!` reads 43 keywords; the robust assembly forwards 39 of them to a
scenario (`%world-keywords`). The four it dropped, found by diffing the two lists:

| Keyword | Status |
|---|---|
| `#:live-avail` (the registry's reservations) | forwarded: a registered resource ingests at what is free of its reservations |
| `#:refine-periods?` | forwarded |
| `#:skill-dynamics` | **held back**: forwarding it moves the plans of `test-dev-world` and `test-dev-ledger` |
| `#:composition` | **held back**: forwarding it moves the plans of `reaction-network-test` and `test-bread-seed` |

Both held-back keywords switch on an engine mode no live solve has run (practice laws
carried as state from period to period; the chemistry's element rows). Each is a
decision of its own; `%held-back-world-keywords` (robust.scm) names them and the test
holds `%world-keywords` plus that list to every keyword `ingest-records!` reads.

### 2.3 `scope-replica` was a person-door nobody had classified (fixed)

`test-person-doors` refuses a planner door that takes a person and sits in none of
`person-write-doors`, `person-read-doors`, `scope-subject-doors`. `scope-replica` (the
scope's books copied to the asking member's device) joined the protocol unclassified.
It is now a scope-subject door. `with-person` admits any holder of personhood, as for
every door in that list; it asks no membership of the scope named.

### 2.4 Ten suites were red, and each was stale; none hid a plan defect

| Suite | What it had fallen behind |
|---|---|
| `test-owned-delivery`, `test-claim-means` | The scope's people eat first. A scope with a baker, Ada and Ben has three `eat~bread` processes taking about 1.56 bread each ahead of any stated want, so 24 loaves ration as 19.3. The water-filling is exact over the remainder; the checks said 14 / 10 and 12 / 12. Now stated as properties over the bake less what is eaten. |
| `test-live-wiring` | Embodied labour is the identity the recipes define. The mill makes 0.17 bran beside each flour, so its labour is shared by mass: flour = (0.3 + 1.2 × 0.5) / 1.17 = 0.769, bread = 0.5 + 0.75 × 0.769 = 1.077, which is what the plan reports. The checks held 0.9 and 1.4 from an older fixture. |
| `test-live-wiring`, `test-willingness-service`, `test-planner-service-socialized` | Mocks answered "no method" to hooks the wiring has grown (`set-on-agent`, `add-intent-listener`, `skills-of`, `fold-by`, `open-fulfillments`, `hours-by`, `hours-on`, an account store). `^mock` now answers an empty reading for those; any other unknown message still raises. |
| `test-world-door` | The scan read the datum `(reset!)` of a `case` clause in `admm-link.scm` as a call, and held a layering entry (`ingest-records!` assigning `*mode-recipes*`) the engine outgrew: it declares through the door now. |
| `test-adjustment` | Counted `adjustment-event` callers in two files; `doors/slots.scm` took one. |
| `test-earth-durability` | A literal count of seeded resources (4); the farm seeder lays 5. Now: what is seeded survives a restore. |
| `test-branch-and-bound` | Compared the search and the enumeration to 1e-6; both solve each configuration's continuous program to the solver's own tolerance (~1e-3). |
| `test-stone-paper-siting` | Required a range at which the HDPE plan is cheaper; the model has the compost plan at or below it everywhere (168.7 h vs 168.5 h at the near range, a tie the test itself declines to claim). Now: the compost plan's margin widens with range. |
| `zz-festival-scale`, `federation-gateways-driver` | Scripts that take an argument (an attendee count; two state directories). Quarantined with that reason. |

## 3. What the probes found

Four findings stand open. Each is confirmed by a script that prints the evidence.

### 3.1 A held good is read as a skill — `tools/probes/held-good-skill.scm`

`vf-agent-skills` (solve/engine.scm) takes every resource an agent holds with a positive
on-hand quantity as one of their skills. A work flow asking for skill WATER is met by a
person whose only link to water is a stock of it:

```
A person holds a stock of WATER and no skill; the work in the recipe asks for skill WATER.
  met 1.000, labour by provider (("ann" . 4.045…))
The same recipe asking for a skill she does not hold, and holds no such good:
  met 0.000, labour by provider ()
A person holding the skill resource itself:
  met 1.000, labour by provider (("ann" . 4.045…))
```

Reach: a recipe names a good as its work skill only by mistake, so the plan is wrong where
a recipe is. The error runs the other way too: a person's skills list carries every good
they hold, which the matching of labour reads. The doc's P5 (`confirmed-flow-stock-defects.md`)
named it; this is its test. *Direction of a fix:* a resource confers a skill only where its
specification is a skill specification. Nothing in the engine's reading names the class
today (the observer's `skills-of` returns every resource too), so the first step is to
say what marks one.

*Closed 2026-10-09, VF-native.* What marks a skill is its specification being WORKED: the
spec states a unit of effort (`defaultUnitOfEffort`, the field VF gives a worked spec,
which the `skill*` shorthand writes), or some recipe flow draws it under the action table's
labour action (`work`). `formulas/actions.scm` `labour-specs` / `labour?` is the one reading;
the solver (`vf-agent-skills`), the roster (`pools/labour-fold`), the holders table
(`doors/service`) and the socialization view (`labour-specs-of`) all take it, and nothing
reads a resource's id. A declared skill declares its spec as worked where the store has
none (`declare-skill!`, `facts/person-facts skill-spec`); an offer of time declares the
generic one (`generic-labour-spec`). `tests/scope/test-held-good-is-not-a-skill.scm`
holds it; the probe is gone. One consequence stated there: a recipe that WORKS water makes
water labour, and a woman holding water then works it — the recipe's own word, as before.
Two more readings the full gate asked for: a spec standing in a `satisfied-by` relation (a
composite skill and its parts) is a skill (`test-skill-matching`, `test-skill-e2e`), and a
resource classified `credential` is one the law may ask of a person — "a licence IS a
skill" (legal/gate.scm) — so the solver admits it beside the worked specs
(`test-food-distribution`). The roster reads labour alone. A skill declared after a
scope's wiring is labour at the next refold because the fold asks the store each time
(`test-labour-pool-live`, `test-move-scope`).

### 3.2 Free carries admit a circulation — `tools/probes/movable-circulation.scm`

Seeded worlds with `#:movable` goods and every pair of places neighbours, planned and then
enacted in the order emitted:

```
seed 1: 23 rows planned, 9 served, 14 left unserved; largest carry 38654.2 units (demand 3)
seed 5: 66 rows planned, 14 served, 52 left unserved; largest carry 40434.1 units (demand 6)
seed 6: 14 rows planned, 6 served, 8 left unserved; largest carry 26271.8 units (demand 7)
```

A carry costs nothing in the program, so the solve is indifferent to sending q units
P0→P1 and q back; its answer lands on large q. Each such row is a pickup the books refuse
to drop off ("the cargo has not been picked up"). Raising `#:tau` changes none of it (0.5, 5 and 50 gave
the same violations in the same worlds); why the carry is free to the program is not yet
read out of the engine. Without movable goods the same fuzz is clean:
`test-property-enact` plans and enacts ten worlds and every row is served.

Reach: `#:movable` reaches a live solve only through the operator doors `plan`, `solve` and
`materialize`, which nothing calls; a live scope moves goods through mode recipes whose
labour prices a circulation out. The fixtures and the doors carry the exposure.
*Direction of a fix:* cancel opposing flows of one good between one pair of cells when
`plan->material` reads the plan (a cheap, exact post-pass), or give a free carry a cost
no larger than the solver's tolerance can see.

### 3.3 The claimable set is wider than the goods it means — `tools/probes/claimable-by-products.sh`

`claimable-specs`, in a scope whose people eat, is:

```
goods:     ambient-heat bread co2 faeces gold h2o-g skill-bake urea
per-person nutrient pools: 42      (energy|ada, protein|baker, …)
```

The rail reads a good as individually claimable when some process makes it and none uses
it up. The people's metabolism makes that true of its by-products, of each person's
nutrient pools, and of a held skill resource nothing consumes (`skill-bake`). A claim still
needs a claim commitment the plan mints for a stated want, and the pool holds no stock of
them, so no credit should move; the set is a wider list than the goods it is for, and a face
that offers "what you may claim" from it offers `faeces`. *Direction of a fix:* the rail
excludes the outputs of `eat~` processes and any spec whose classification is skill or
nutrient pool.

### 3.4 Two settings are read from a standing nothing produces — grep

`standing-settings` (doors/service.scm:2196) reads `admit?` and `proc-frag` off
`(standing root sid)`; `gather` (2162) reads `admit?` the same way, and two more sites read
`proc-frag` (3249, 3996). The
standing the gateway injects is `scope-standing` (economy/recipe-standing.scm), which
returns `responses` and `observed` and nothing else. No other reader in the repository
produces either key:

```
$ grep -rn "(cons 'admit?\|'admit? \.\|(admit? \. " module server --include=*.scm
$ grep -n "admit?\|proc-frag" module/playnet/economy/recipe-standing.scm
```

(both print nothing). The three reads are dead in production: the recipe-admission gate and the
per-process fragility limits they feed are never set from a standing. *Direction of a
fix:* produce them from the standing, or delete the reads.

*Read again, 2026-10-09.* The grep above left `tests/` out. `tests/doors/test-means-gateway.scm`
injects a `standing` reader that carries both keys (`((proc-frag . ()) (admit? . ,(lambda (r) #f)))`),
and the suite's claim — a consensus hands a scope none of the bar — rests on `gather` reading
`admit?` off it. So the keys are the reader's interface, exercised by a reader the suite
supplies, not dead reads. They stay; the reader contract in `doors/service.scm` (the
`standing` line of the readers' doc) now names the two keys and says the production reader
carries neither. Finding closed as documented, not as deleted.

## 4. What did not reproduce

**P4, organizations as labour suppliers.** `confirmed-flow-stock-defects.md` P4 had a
window-less organization given 8 hours a day and taking 3.79 of a plan's hours.
`tools/probes/held-good-skill.scm`'s fixture, an organization with no stated hours beside
one person who holds the general skill, shows the organization supplying nothing: with
Ann alone the plan uses 4.05 h of Ann; with the organization added it uses 4.04 h of Ann
and none of the organization's; the organization alone meets 0. The documented case
may rest on the organization holding goods (which §3.1 reads as skills): an organization
in the fixture holds none. That is a reading, not a run; the case stays open until a
scope that seeds an organization with goods is planned and its provider hours read.

## 5. What held

Seeded random worlds, each law tried against the real solve and the real stores. A
failure is a world someone can build again.

| Suite | Worlds | The law |
|---|---|---|
| `test-property-plan` | 8 bread chains, 1–3 citizens, stock scarce against demand | twice the people, stock and demand is twice the bread and twice the hours; more stock never meets less (and less never more); the order agents, resources, processes and recipes arrive in changes neither bread nor hours; one future split into two identical half-probability futures is the same plan |
| `test-property-enact` | 10 worlds, 2–3 places, a chain of three recipes | the plan's material rows, enacted against a fresh observer in the order emitted and in reverse, are all served, and every good is held + produced − consumed |
| `test-property-credit` | 15 communes, 2–5 citizens, random hours and contribution factors | no drawable credit is negative at any free-time level; Σ drawable credit is the pool as it stands (f = 0, ¼, ½, 1); a claim the balance covers takes exactly its cost from the claimant and moves nobody else's, and Σ drawable credit is again the pool; a claim past the balance is refused |

The first metamorphic run scaled people, stock and demand and still reported violations
at twice the labour hours: the hours were capped at the people's availability, which did
not double. The law was wrong and the probe was corrected to scale the people. A law that
fails is first a claim to check.

## 6. How the hunt went wrong, and what it cost

Recorded so the next one is cheaper.

- A wrapper ending in `| grep` returned grep's status, so a failing suite looked green
  ("exit=0") for an hour. Run with the status kept (`> file; st=$?`).
- `guix shell --pure` strips the environment: probe parameters set outside never arrived.
  Pass them inline (`env VAR=… guile`).
- `--no-auto-compile` loads the stale object for an include-fragment (engine.scm includes
  robust.scm), so bisecting with files restored from git gave wrong answers until the
  runs freshened the cache and compiled, as the gate does.
- A thread started at module load deadlocks Guile's module loader, whatever it does.
- `make test` runs `lint-verbs` first; another session's untracked files can fail it and
  end the run before a test starts (`make -o lint-verbs test` runs the tests anyway).

## 7. Open, in the order the evidence recommends

1. ~~§3.1: a held good is a skill.~~ Closed 2026-10-09 (a skill is a worked spec).
2. ~~§3.4: produce `admit?` and `proc-frag` from the standing, or delete the reads.~~ Read
   again 2026-10-09: the keys are the `standing` reader's interface, exercised by
   `test-means-gateway`'s reader; documented in the reader contract, kept.
3. ~~§3.3: the rail's exclusions.~~ Closed 2026-10-09: `with-claims` reads what is made off
   the scope's own recipes and what is stocked less labour (`test-claim-means`). Still
   open until 2026-10-09 (`b43ffffb95`): `claimable-specs` reads through `spec-rail`, so
   the bar list (`facts/barred-specs.scm`) holds for the set as for each spec asked alone.
4. ~~§3.2: cancel opposing carries in `plan->material`.~~ Closed 2026-10-09: a carry's τ·km
   reaches the objective in every labour model (`carry-terms`) and opposing carries net
   (`net-carries`); `test-property-enact` plans movable worlds.
5. §2.2: the decision on `#:skill-dynamics` and `#:composition`. Measured 2026-10-09, each
   forwarded alone after the skill fix: `skill-dynamics` unplans test-dev-world's heavy want
   (38 of 40 hours) and changes test-dev-ledger's lead; `composition` leaves
   reaction-network-test's CO unmade (met falls from 1.0) and moves test-bread-seed's work
   per process. Each stays held; the comment on `%held-back-world-keywords` records it.
6. The coverage gaps of §1: the push modules, which no suite loads.
7. ~~A `use` row's hours under the spec's count unit (inventory F2).~~ Closed 2026-10-09
   (`360ace2b81`): readers moved first to `row-figure` (quantity, else effort), then the
   writer moved the hours to `effortQuantity`; the demo recording was regenerated.
