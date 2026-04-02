# Proportional Governance: Labor-Derived Expression Power and Delegation on Goblins

Commune/federation governance expressed as object-capability actors using Heart of Spritely patterns. Fully decentralized: no central registry, no global identity system. Expression power is your share of labor in a scope -- your claim capacity in each scope's account-store. The capacity/incapacity equations ensure that every citizen has voice, regardless of ability.

Core insight: your governance treemap IS a picture of how you've distributed your labor across scopes. No manual allocation. No conviction voting. No central registry. No separate political mechanism. Economic participation and political expression are the same data. Your voice in each scope is your claim capacity there -- per-scope, locally computed.

---

## Three Patterns Compose Into Governance

| Governance primitive | Goblins pattern | Heart of Spritely reference |
|---|---|---|
| **Stance** (endorse a position) | Sealer endorsement -- citizen seals their position with their authority | SS3.3.3 sealers/unsealers |
| **Delegation** (represent me) | Revocable proxy pair + facet attenuation for mandate | SS3.3.4 revocation and accountability |
| **Expression power** | Derived from observer labor events + account claim capacity (contribution + solidarity), per-scope, snapshotted per ballot; direct stance overrides delegation | Composition of SS3.2.2 + existing `^account-store` infrastructure |

---

## Core Mechanism: Labor-Derived Expression Power

Your expression weight in a scope is your **share of labor** in that scope -- your claim capacity as computed by the account system. It is per-scope, not globally normalized. A person who works in three scopes has full voice in all three, proportional to their contribution in each.

### How it works

Each scope has an `^account-store` (already implemented in `account.scm`) that tracks per-agent:

- **`gross-contribution-credited`** -- total labor hours from `work` events recorded in the scope's observer
- **`contribution-capacity-factor`** (CCF) -- 0 to 1, reflecting the agent's physical/mental capacity to contribute labor (1 = full capacity, 0 = fully incapacitated due to age, disability, illness, infancy, etc.)

The account system computes per agent:

```
contribution_claim    = (gross_contribution / total_social_svc) * available_pool
solidarity_supplement = (1 - CCF) * (welfare_fund / sum_unmet_capacity)
total_claim_capacity  = contribution_claim + solidarity_supplement
```

An agent's **expression weight in scope X** = their `total_claim_capacity` in scope X. This is a per-scope value. There is no global normalization -- your voice in each scope reflects your participation in that scope independently.

### The treemap

```
Alice
|-- watershed-commune: 142        <-- most of her labor is here
|-- tech-coop: 87                 <-- significant contribution
+-- agroecology-school: 31        <-- some recent work
```

This is not a configuration UI. It is a **mirror of Alice's observed economic life**. The areas are proportional to her claim capacity (labor contribution + solidarity) in each scope.

### Properties

- **No manual allocation.** Expression power comes from what you do, not what you declare.
- **No gaming.** You can't pile expression into a scope before a vote. You'd have to actually work there.
- **Participation is not penalized.** Working in three scopes doesn't dilute your voice in any of them. Your work in watershed is your work in watershed, regardless of what you also do elsewhere.
- **Intensity is real.** Having weight 142 in watershed vs. 31 in agroecology reflects real economic commitment.
- **Free association is continuous.** Start working in a new scope and your expression there grows. Stop contributing and it shrinks. No discrete membership transitions.
- **Equity within each scope.** The capacity/incapacity equations ensure every citizen in a scope has voice, including those who cannot work (via solidarity supplement).

---

## The Capacity/Incapacity Bridge

The account system's capacity/incapacity equations are what make labor-derived expression just, not merely meritocratic. Without them, expression power would exclude anyone who cannot work. With them, every citizen has voice.

### The equations (from `account.scm`)

**Welfare allocation rate** (self-correcting):

```
welfare_rate = sum_unmet_capacity / (sum_met_capacity + sum_unmet_capacity)
```

When all citizens are at full capacity (CCF=1 for all): `welfare_rate = 0`. The entire pool is distributed by contribution.
When all citizens are fully incapacitated (CCF=0 for all): `welfare_rate = 1`. The entire pool is distributed by solidarity.
The system continuously adjusts between these poles.

**Per-citizen expression**:

```
available_pool = claimable_pool * (1 - welfare_rate)
welfare_fund   = claimable_pool * welfare_rate

contribution_claim    = (my_gross_contribution / total_social_svc) * available_pool
solidarity_supplement = (1 - my_CCF) * (welfare_fund / sum_unmet_capacity)
my_expression_weight  = contribution_claim + solidarity_supplement
```

### How incapacity resolves

| Scenario | CCF | Expression source |
|---|---|---|
| Healthy adult, active worker | 1.0 | Entirely from labor contribution |
| Partial disability, recovering from illness | 0.5 | Half contribution + half solidarity |
| Severe disability, advanced age | 0.0 | Entirely from solidarity supplement |
| Infant / young child | 0.0 | Entirely from solidarity, in the scope providing care |

The "zero labor" edge case resolves cleanly: a fully incapacitated citizen has zero `contribution_claim` but maximum `solidarity_supplement`. Their expression power exists and is grounded in a real relationship -- the community that provides their care. They have voice in the scope that supports them.

### What CCF captures and how it is set

CCF reflects **physical and mental capacity** -- disability, illness, age, infancy. It is not about choice or effort. A healthy person who chooses not to work has CCF=1 (full capacity, zero contribution, therefore zero expression from contribution and zero solidarity supplement). A person who cannot work due to disability has CCF=0 (zero capacity, full solidarity supplement).

CCF is **community knowledge, not bureaucratic assessment**. In a commune, everyone knows the baby is a baby, the elder has dementia, someone broke their leg. The scope's governance updates a member's CCF when life circumstances change -- a `set-ccf` method gated behind the governance seal. The people who provide care are the people who know the need. No central disability registry.

The planning layer reads the same CCF for resource matching (how much labor can this person provide?). The governance layer inherits it for expression weight. One number, two uses.

---

## Sybil Resistance Without a Central Registry

There is no global identity system. Sybil resistance emerges from the structure of per-scope expression and social CCF assessment.

**Within a scope, sybil attacks gain nothing.** If you split your labor across two fake identities, each gets half the claim capacity. Your total expression is unchanged -- the account system distributes by share of labor, not by headcount.

**The attack vector is fake solidarity.** Creating a fake incapacitated identity (CCF=0) to extract a solidarity supplement. This requires a governance decision within the scope to set that identity's CCF -- the commune must recognize someone as disabled, elderly, or an infant. You cannot self-declare incapacity; the community that provides care is the community that verifies need.

**Cross-scope identity is handled by introduction, not registry.** OCapN petnames and introduction chains let scopes know that Alice-in-watershed and Alice-in-techcoop are the same person -- when that matters (e.g., for assembling the treemap). But governance never requires this knowledge: expression is per-scope, and each scope's account-store is self-contained.

| Threat | Defense |
|---|---|
| Split labor across fake identities within a scope | Gains nothing -- share of labor is unchanged |
| Fake incapacitated identity for solidarity | Requires social vouching for CCF -- commune knows its members |
| Same person in multiple scopes | Not a problem -- expression is per-scope, no global normalization |

---

## The Expression Treemap

The natural UI is a treemap -- nested rectangles where area = expression weight in each scope. It is a read-only visualization of observer/account data.

- **Outer rectangles** = scope expression weights (derived from labor + solidarity)
- **Inner rectangles** = delegation splits within each scope (the only thing the citizen configures)

A citizen's entire political-economic engagement is visible at a glance: where they work, how much, and who carries their voice.

---

## Indexes

There is no central citizen registry. Identity is relational: scopes know their members through their account-stores. A citizen exists in the system by having an account in at least one scope and holding their own `^citizen-voice` (sealer).

### Scope Expression Weight

Replaces Commune Citizen Shares. A scope's weight = sum of claim capacities of all citizens in that scope.

```
Scope -> sum(total_claim_capacity(citizen, scope) for all citizens)
```

Computed from the scope's own account-store. Local to each scope.

### Federation Weight

A commune's weight within a federation = its scope expression weight. This reflects the total economic activity (labor + solidarity) within the commune. More economically active scopes have proportionally more weight in federation decisions.

---

## Actor Design

### 1. `^citizen-voice` -- The endorsement capability

**Pattern:** Sealer endorsement. Self-sovereign.

A citizen holds their own voice. It is spawned when they are introduced to their first scope -- or they spawn it themselves. No central entity creates it. The sealer IS the identity: the ballot verifies the seal, not who called. "If you don't have it, you can't use it."

```scheme
(define-actor (^citizen-voice bcom citizen-id my-sealer)
  (methods
    ;; Seal my stance with MY authority
    [(stance proposal-id position)
     (endorse (list 'stance proposal-id position citizen-id) my-sealer)]

    [(citizen-id) citizen-id]))
```

### 2. `^delegation-map` -- Per-scope voice delegation

**Pattern:** `^cell` with fractional entries. New actor, one per (citizen, scope) pair.

Delegation is the only thing the citizen actively configures. Expression weight is derived; delegation distributes it.

```scheme
(define-actor (^delegation-map bcom citizen-id scope-id delegates)
  ;; delegates: hashmap of delegate-id -> fraction (sum <= 1.0)
  ;; Remainder (1.0 - sum) = direct expression (citizen must cast to use)

  (methods

    ;; --- Delegate within this scope ---
    ((delegate delegate-id fraction)
     ;; Add or update a delegate's fraction.
     ;; Total delegated fractions must not exceed 1.0.
     (let* ((new-delegates (hashmap-set delegates delegate-id fraction))
            (total (hashmap-fold (lambda (_k v acc) (+ v acc)) 0 new-delegates)))
       (when (> total 1)
         (error "Delegation fractions exceed 1.0" citizen-id scope-id))
       (bcom (^delegation-map bcom citizen-id scope-id new-delegates))))

    ;; --- Revoke a delegate ---
    ((revoke delegate-id)
     (bcom (^delegation-map bcom citizen-id scope-id
             (hashmap-delete delegates delegate-id))))

    ;; --- Read ---
    ((delegates) delegates)
    ((direct-fraction)
     (- 1 (hashmap-fold (lambda (_k v acc) (+ v acc)) 0 delegates)))

    ;; --- Snapshot for ballot ---
    ((snapshot)
     ;; Returns frozen copy of delegation map.
     delegates)))
```

### 3. `^ballot` -- Expression-weighted tally

**Pattern:** Encapsulated coordination. Updated to read expression weights from account data.

```scheme
(define-actor (^ballot bcom proposal-id scope-id description
                       stances              ;; alist: citizen-id -> sealed-stance
                       status               ;; 'open | 'closed
                       citizen-registry     ;; hashmap: citizen-id -> sealed?-actor
                       expression-snapshot)  ;; hashmap: citizen-id ->
                                             ;;   (claim-capacity, delegation-map)
                                             ;; FROZEN at ballot open time
  (methods
    [(cast citizen-id sealed-stance)
     ;; Verify endorsement via citizen-registry (unchanged).
     (let ((sealed? (hashmap-ref citizen-registry citizen-id #f)))
       (unless (and sealed? ($ sealed? sealed-stance))
         (error "Invalid stance endorsement"))
       (bcom (^ballot bcom proposal-id scope-id description
                      (alist-set stances citizen-id sealed-stance)
                      status citizen-registry expression-snapshot)))]

    [(tally)
     ;; Walk the FROZEN expression-snapshot.
     ;;
     ;; For each citizen in the snapshot:
     ;;   weight = their claim capacity in THIS scope (from account-store)
     ;;   delegation-map = their delegate fractions within this scope
     ;;
     ;; Weight computation:
     ;;   - If citizen cast a direct stance:
     ;;       their weight = full claim capacity (override reclaims delegation)
     ;;       delegates receive nothing from this citizen for this ballot
     ;;   - If citizen did NOT cast and has delegates:
     ;;       each delegate receives (claim-capacity * delegate-fraction)
     ;;       direct fraction is unexercised (abstention)
     ;;   - Transitive: a delegate's total weight = own claim capacity +
     ;;       sum of received fractions from delegating citizens
     ;;
     ;; Example: Alice claim-capacity=142 in watershed, delegates 0.40 to Bob
     ;;   Alice casts:     Alice weight = 142, Bob gets nothing from Alice
     ;;   Alice abstains:  Bob gets 142*0.40=56.8, Alice direct 142*0.60=85.2 unexercised
     ...]

    [(close) (bcom (^ballot ... 'closed ...))]
    [(result) ...]))
```

The snapshot is built at ballot-open time by reading claim capacities from the scope's account-store and delegation maps for each citizen. Frozen for the ballot's lifetime.

### 4. `^plan-expression` -- Preference over plans

**Pattern:** Weighted distribution over alternatives. New actor.

When the planning layer produces multiple feasible plans, citizens express preferences by distributing their expression weight across them.

```scheme
(define-actor (^plan-expression bcom scope-id plan-ids
                                distributions        ;; hashmap: citizen-id -> weight-map
                                status               ;; 'open | 'closed
                                citizen-registry
                                expression-snapshot)
  ;; weight-map: hashmap of plan-id -> fraction (must sum to <= 1.0)
  ;; Unallocated fraction = indifference / abstention on remaining plans.

  (methods
    [(express citizen-id sealed-expression)
     ;; sealed-expression contains: citizen-id + plan-id -> weight map
     ;; Verify endorsement. Weights must sum to <= 1.0.
     ;; Each plan's received weight = citizen's expression-weight * plan-fraction.
     ...]

    [(aggregate)
     ;; For each plan: sum of (expression-weight * plan-fraction) across all citizens
     ;; (including delegated expression flowing through delegates).
     ;; Returns plan-ids ranked by total expression-weighted support.
     ...]

    [(close) ...]))
```

Your total expression across plans is bounded by your claim capacity in the scope. Caring about everything equally = spreading thin. Strong preference = concentrated weight.

Delegation composes: if Alice delegates to Bob within this scope, Bob distributes his received claim capacity across plans on her behalf. If Alice overrides on this ballot, she distributes her full claim capacity herself.

### 5. `spawn-mandate-delegation` -- Revocable representation

**Pattern:** `spawn-logged-revocable-proxy-pair` + `^name-predicate` mandate check. **Preserved exactly.**

Mandate delegation is about **capability attenuation and accountability**: who can act on behalf of a commune in a federation, and what actions are within their mandate. It is a different mechanism from voice delegation.

```scheme
(define (spawn-mandate-delegation delegator-name target mandate log
                                  #:max-depth 2 #:current-depth 0)
  (when (>= current-depth max-depth)
    (error "Sub-delegation depth limit exceeded" delegator-name))
  (define revoked? (spawn ^cell #f))
  (define (^mandate-proxy bcom)
    (lambda args
      (when ($ revoked? 'get)
        (error "Delegation revoked for" delegator-name))
      (let ((method-name (car args)))
        (unless (if (procedure? mandate)
                    (mandate method-name)
                    ($ mandate method-name))
          (error "Action outside mandate:" method-name delegator-name)))
      ($ log 'append-to-log delegator-name target args)
      (apply $ target args)))
  (values (spawn ^mandate-proxy) revoked?))
```

All properties hold: mandate can only narrow (attenuation composes as intersection), revocation cascades, accountability traces the full chain, depth limit of 2, visibility rule, binding instructions (mandat imperatif).

Sub-delegation, term limits, depth limits, and visibility rules are unchanged. See the original governance spec (`GOVERNANCE-OCAP.md`) for the full sub-delegation protocol.

### 6. `^commune` -- The base-level governed association

**Pattern:** `make-governed-org` 4-seal extension. Updated for labor-derived membership.

```scheme
;; 4-seal pattern
gov-seal       ;; governance decisions (open/close ballots, exclude members)
planning-seal  ;; economic planning operations
member-seal    ;; member-facing (cast stance, delegate within scope)
delegate-seal  ;; federation representation operations
```

**Rights:**
- Decisions: for all members on matters internal to the commune
- Immediately-Revoke: Members, Participants, Communes, Commune-Agents, Delegates
- Communicate: Publish all doings and shortcomings
- Withdraw: from any intermediate federation (subject to obligation settlement)

**Membership** is no longer discrete. A citizen is a "member" of a commune if they have nonzero expression weight there -- meaning they have contributed labor or receive solidarity in that scope. There is no `admit-citizen` / `remove-citizen` pair.

The commune retains the right to **exclude**: a governance decision can mark a citizen as excluded, preventing their expression weight from counting in ballots. Exclusion is a deliberate governance act (requires ballot), distinct from the organic flow of labor and solidarity.

### 7. `^federation` -- Communes federated by attribute

**Pattern:** Recursive. Structurally identical to `^commune` but members are communes.

```scheme
(define-actor (^federation bcom name attribute
                           member-communes    ;; hashmap: commune-id -> commune-ref
                           ballots log-ref)
  (methods
    [(admit-commune commune-id commune-ref) ...]
    [(remove-commune commune-id) ...]
    [(receive-stance commune-id sealed-stance)
     ;; Weight = scope expression weight of commune-id
     ;; (sum of all citizen expression weights in that scope)
     ...]
    [(open-ballot proposal-id desc) ...]
    [(obligations commune-id) ...]))
```

**Federation attributes** (unchanged): Federations form along spatio-temporal attributes of metabolic interdependence -- spatial (watersheds, climate zones), temporal (generational cohorts, shift-based), functional (supply chains, infrastructure grids), cultural (language areas, indigenous nations), emergency response (fire seasons, flood plains).

A scope with no children and no parent federation can join the root federation directly. A single person operating as their own scope is a valid leaf -- the recursion bottoms out at individual humans.

### 8. The root federation -- Planetary interdependence without a registry

There is no `^universal-commune` actor with a citizen registry. The "universal commune" is simply the **root of the federation tree** -- a `^federation` like any other, whose members are the highest-level federations and standalone scopes, weighted by their total claim capacities.

Inescapable interdependence is structural, not registral: every scope federates upward, and the federation tree has a single root. You can't opt out of planetary interdependence -- not because a registry holds your name, but because the metabolic reality of shared atmosphere, shared oceans, shared electromagnetic spectrum creates federation whether or not you register.

Individual citizens do not vote at the root level. They vote in their scopes, which aggregate into federations, which aggregate upward. Expression power flows through the recursive federation structure all the way to the top. No special actors, no special rules, no central authority.

### 9. `^affected-interest-voice` -- Non-member standing

**Pattern:** Attenuated facet. **Preserved exactly.**

```scheme
(define (spawn-affected-interest-voice ballot-ref group-name)
  (facet ballot-ref 'cast-advisory 'view-stances 'view-result))
```

Affected groups can speak but cannot decide. Material affect is determined by tracing metabolic consequences through the planning network.

---

## Delegation: Two Mechanisms, Two Purposes

### Voice delegation (per-scope, citizen-configured)

The only thing a citizen manually configures. Within each scope where they have expression weight, they may delegate portions to other citizens.

- **Who delegates:** Citizen -> citizen, within a scope
- **Mechanism:** `^delegation-map` actor (fractional entries, sum <= 1.0)
- **Weight:** Expression-weight * delegate-fraction
- **Override:** Direct stance on a ballot reclaims full expression weight for that ballot
- **Revocation:** Remove delegate from map; takes effect next ballot (per snapshot rule)
- **Transitivity:** A delegate who receives expression from multiple citizens carries the sum

### Mandate delegation (federation representation)

A commune issuing a revocable capability so a delegate can act on its behalf in a federation.

- **Who delegates:** Commune -> human delegate
- **Mechanism:** Revocable proxy pair actor (`spawn-mandate-delegation`)
- **Weight:** The commune's scope expression weight
- **Mandate:** Constrained by `^name-predicate` or procedure
- **Accountability:** `^logger` records every forwarded call
- **Revocation:** `^cell` flip on revoked?; immediate

| | Voice delegation | Mandate delegation |
|---|---|---|
| **Question** | "Who exercises my voice within this scope?" | "Who can act for us, and what can they do?" |
| **Derived from** | Labor-derived expression (automatic) | Governance decision (deliberate) |
| **Revocation timing** | Next ballot (snapshot rule) | Immediate (trust concern) |

---

## Liquid Democracy in the Labor-Derived Model

The delegation graph within each scope is a weighted graph. Each citizen's delegation map sums to <= 1.0, with the remainder being direct expression.

**Example:**
```
Alice's claim capacity in watershed: 142 (from labor + solidarity)
Alice's delegation map in watershed:
  to-Bob:   0.40
  to-Carol: 0.10
  direct:   0.50 (remainder)

Effective weights:
  Alice direct:  142 * 0.50 = 71
  -> Bob:        142 * 0.40 = 56.8
  -> Carol:      142 * 0.10 = 14.2
```

**Snapshot at ballot open:** Claim capacities and delegation maps are frozen for the ballot's lifetime. Changes to labor contribution or delegation after snapshot affect only future ballots.

**Direct override reclaims everything:**
```
Snapshot: Alice capacity=142, delegates 0.40 to Bob, 0.10 to Carol

Case 1 -- Alice does not cast:
  Bob weight += 56.8, Carol weight += 14.2
  Alice direct (71) unexercised

Case 2 -- Alice casts directly:
  Alice weight = 142 (full claim capacity, override reclaims delegated portions)
  Bob and Carol receive nothing from Alice for this ballot
```

**Why override reclaims full weight:** "I care enough about this issue to engage personally." The override is surgical (this ballot only); the delegation relationship is unaffected for future ballots.

**Cycle prevention:** On every `delegate` call, walk the delegation graph from the target to check for cycles. Reject if the delegator would appear in the chain.

---

## Vat Topology

Each scope = one Goblins vat (following `scope-root.scm`):

- **Each commune** = one vat. Observer, account-store, delegation-maps, ballots, logger are near references. Intra-commune operations are synchronous + transactional.
- **Each federation** = one vat. Commune-to-federation is cross-vat via `<-` (async). Delegation proxies live in the commune's vat; delegates hold far references via OCapN.
- **Root federation** = one vat, structurally identical to any other federation.

No special topology. No central vat holding global state. Expression weight computation happens **within each scope's vat** (account-store is local). The treemap is assembled client-side by querying each scope where the citizen has an account.

---

## Recall Procedure

5% petition threshold -> 30-day vote -> simple majority removes delegate.

Maps to a **two-phase ballot**:

1. **Petition phase:** A ballot where `cast` counts toward a threshold. When `(>= (length stances) (* 0.05 scope-expression-weight))`, auto-transition to voting phase. Threshold measured against expression weight.

2. **Voting phase:** Standard `^ballot` with a 30-day deadline. Simple majority (expression-weighted) on the tally removes the delegate by flipping `($ revoked? 'set #t)` on their proxy.

---

## Planning-Based Dispute Resolution

When a commune alleges a federation decision exceeds authority:

1. Delegates convene with their communes' `^scope-root` refs (PlanStores) and binding instructions (mandates)
2. They **merge PlanStores** -- the existing `plan-for-region` operation, treating the disputed matter as an unmet demand
3. The planner produces feasible resolutions -- plans that satisfy metabolic constraints and respect priority rankings
4. Delegates return resolutions to communes (cross-vat `<-` messages)
5. Communes deliberate internally via `^plan-expression` (citizens distribute expression across feasible plans) or standard `^ballot` (yes/no on a single resolution)
6. If no resolution achieves sufficient support: communes may propose modifications (repeat from step 2) or withdraw from the disputed aspect of cooperation

If withdrawal occurs, the planning process automatically adjusts -- the withdrawing commune's commitments become unmet demands, its expected receipts are redirected.

The planner is a pure function over merged data -- it produces options, not decisions. Decisions remain with citizens via their expression-weighted voice.

---

## Complete Scenario

1. Alice is introduced to the watershed commune by an existing member. The commune creates her account in its `^account-store`. Alice holds her own `^citizen-voice` (sealer).
2. Alice begins working -- `work` events with `effort-quantity` recorded in the watershed observer; account-store credits her `gross-contribution-credited`
3. As Alice works, her claim capacity in the watershed grows. Her expression treemap shows her weight there.
4. Alice is later introduced to the tech-coop and begins contributing there too. Her treemap now shows two scopes, weighted by labor contribution in each.
5. Alice delegates within the watershed: `($ delegation-map 'delegate "bob" 0.40)` -- Bob carries 40% of her watershed expression
6. Watershed commune opens a ballot on "increase bread production" -- snapshots claim capacities (from account-store) and delegation maps
7. Alice casts her stance: `($ alice-voice 'stance "bread-ballot" 'yes)` -> sealed endorsement; override reclaims her full claim capacity
8. The planner produces three feasible plans for water management. A `^plan-expression` opens.
9. Alice distributes: 0.60 to plan-A, 0.30 to plan-B, 0.10 abstains
10. Watershed commune also belongs to River-Federation
11. Watershed commune elects delegate Bob with mandate `(set (stance))`:
    ```scheme
    (spawn-mandate-delegation "watershed" federation-voice mandate log)
    ```
    -> gives `bob-proxy` to Bob
12. Bob casts the commune's stance in the federation ballot, weighted by the watershed's total expression weight:
    ```scheme
    ($ bob-proxy 'stance "dam-proposal" 'no)
    ```
    -> logged, mandate-checked, forwarded
13. Watershed commune recalls Bob: `($ revoked? 'set #t)` -> instant, Bob's proxy is dead
14. Alice's grandmother lives in the watershed commune. The commune's governance has set her CCF=0 (advanced dementia). She does no labor, but the solidarity supplement gives her expression weight in the watershed. Her daughter delegates on her behalf for most ballots; on the bread production ballot, her daughter overrides to cast grandmother's full weight directly.

---

## Open Questions

- **What counts as labor?** Only `work` events? Or also `deliver-service`, `use`, `cite`? Broader definitions capture more forms of contribution but may dilute the signal. Care work must be explicitly recorded as `work` events to count.
- **Care received as expression:** Does receiving care (as `receiver` in work events) contribute to expression in the caring scope? This would give care recipients additional voice beyond the solidarity supplement. Arguments for: it grounds voice in real relationships. Arguments against: it could be gamed.
- **Affected interest identification:** How do affected interest groups get identified? The planning network can trace metabolic consequences, but who initiates the tracing?
- **Delegation persistence:** If Alice stops working in a scope and her claim capacity drops to near-zero, do her delegation settings persist? Or are they automatically cleared?
- **CCF update governance:** CCF is set via scope governance (`set-ccf` behind the governance seal). Should this require a ballot, or can care providers update it directly? What about temporary incapacity (broken leg) vs. permanent (congenital disability) -- different update cadences?
- **Federation weight and productivity:** A scope's federation weight = sum of claim capacities = total economic activity. This means more economically active scopes have more federation voice. The solidarity mechanism ensures incapacitated members are counted, but scopes with more total labor still weigh more. Is this desirable? The alternative (bounding by citizen count) would reintroduce a centralized counting mechanism.
- **Cross-scope identity for treemap:** Governance doesn't need cross-scope identity, but the treemap (showing all your scopes) does. This relies on OCapN introduction chains -- the citizen holds references to their accounts in each scope. Is this sufficient, or does federated identity require more structure?
