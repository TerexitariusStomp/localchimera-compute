# OCapN Governance: Stance, Delegation, and Liquid Democracy on Goblins

Commune/federation governance expressed as object-capability actors using Heart of Spritely patterns. No new Goblins primitives required — this is a composition of existing patterns: `spawn-logged-revocable-proxy-pair` for delegation+revocation, sealers for endorsement, `^faceted-validator` for mandate constraints, `^cell` for revocation switches, bcom for state transitions.

---

## Three Patterns Compose Into Governance

| Governance primitive | Goblins pattern | Heart of Spritely reference |
|---|---|---|
| **Stance** (vote yes/no) | Sealer endorsement — citizen seals their position with their authority | §3.3.3 sealers/unsealers |
| **Delegation** (represent me in parent) | Revocable proxy pair + facet attenuation for mandate | §3.3.4 revocation and accountability |
| **Liquid democracy** (transitive vote delegation) | Delegation graph snapshotted per ballot; direct stance overrides delegation; weight computed at tally from frozen snapshot | Novel composition of §3.2.2 + hashmap |

---

## Indexes

### Citizen Index
All persons residing within free-association. Managed by the Universal Commune as the guarantor of universal membership. Establishes the fundamental unit of political personality — the human being as such, prior to any particular association.

```
ID → Citizen
```

### Membership Index
All persons/communes residing within free-association. No double counting across communes. Records the actual associative choices of citizens — which communes they belong to, which federations those communes belong to.

```
Citizen → Commune
Commune → Commune
```

### Commune Citizen Shares
Derived from Membership Index by recursively counting citizens in commune (reducing commune hierarchy into citizens). Used to determine the weight of each citizen in commune-level decisions. Also used for calculating equitable distribution of sacrifice and benefit across all individuals.

```
Commune → { citizen: proportion ... }
```

### Commune Shares
Derived from Membership Index by recursively counting citizens in communes, from bottom-up, retaining commune abstraction. Used for determining voting weights in federation assemblies where communes vote as units.

```
Commune → { member-commune: proportion, member-citizen: proportion ... }
```

---

## Federation Attributes

Federations form along whatever spatio-temporal attributes create actual metabolic interdependence:

- **Spatial:** Watersheds, climate zones, transport corridors, radiation belts (space settlements)
- **Temporal:** Generational cohorts managing long-term waste, shift-based communities (24/7 infrastructure), seasonal migration patterns
- **Functional:** Supply chains (grain network federation), practice communities (agroecology schools), infrastructure grids (internet backbone)
- **Cultural:** Language areas, religious communities, indigenous nations (these have spatio-temporal dimensions too — territory, pilgrimage cycles, harvest festivals)
- **Emergency Response:** Fire seasons, flood plains, pandemic zones

---

## Actor Design

### 1. `^citizen-voice` — The political capability a citizen holds

**Pattern:** Sealer (endorsement) + `^cell` (delegation pointer)

```scheme
(define-actor (^citizen-voice bcom citizen-id my-sealer delegation-cell)
  (methods
    ;; Seal my stance with MY authority — only I can produce this endorsement
    ;; A direct stance ALWAYS overrides delegation for that specific ballot.
    ;; If Alice has delegated to Bob but casts her own stance on ballot X,
    ;; her weight counts under her direct stance — not Bob's — for ballot X only.
    ;; The delegation relationship is unaffected for all other ballots.
    [(stance proposal-id position)
     (endorse (list 'stance proposal-id position citizen-id) my-sealer)]

    ;; Delegate my vote to another citizen (revocable)
    ;; Takes effect on the NEXT ballot opened after delegation.
    ;; Does not affect any currently open ballots.
    [(delegate target-citizen-id)
     ($ delegation-cell 'set target-citizen-id)]

    ;; Revoke my delegation — I vote directly again
    ;; Takes effect on the NEXT ballot opened after revocation.
    ;; Does not retroactively change weight on open ballots.
    [(revoke-delegation)
     ($ delegation-cell 'set #f)]

    [(delegated-to) ($ delegation-cell 'get)]
    [(citizen-id) citizen-id]))
```

**Why sealer, not just recording a symbol?** The ballot verifies the stance was produced by *this citizen's* sealer — "if you don't have it, you can't use it." The ballot never checks WHO called; it checks WHAT they hold (the sealed bundle). This is the ACL-to-capability shift: identity doesn't matter, endorsement does.

### 2. `^ballot` — A proposal open for voting

**Pattern:** Encapsulated coordination (Heart of Spritely §3.3.5 guest-post-with-review)

```scheme
(define-actor (^ballot bcom proposal-id description
                       stances              ;; alist: citizen-id → sealed-stance
                       status               ;; 'open | 'closed
                       citizen-registry     ;; hashmap: citizen-id → sealed?-actor
                       delegation-snapshot)  ;; hashmap: citizen-id → target-id | #f
                                             ;; FROZEN at ballot open time
  (methods
    [(cast citizen-id sealed-stance)
     ;; Verify endorsement: look up this citizen's sealed? actor
     (let ((sealed? (hashmap-ref citizen-registry citizen-id #f)))
       (unless (and sealed? ($ sealed? sealed-stance))
         (error "Invalid stance endorsement"))
       ;; A citizen may re-cast to change their stance while ballot is open.
       ;; Latest cast wins (replaces prior entry in stances alist).
       (bcom (^ballot bcom proposal-id description
                      (alist-set stances citizen-id sealed-stance)
                      status citizen-registry delegation-snapshot)))]

    [(tally)
     ;; Walk the FROZEN delegation-snapshot to compute effective weights.
     ;; Key rule: direct stance overrides delegation.
     ;;
     ;; For each citizen in the snapshot:
     ;;   - If they cast a direct stance → their weight = 1 (own vote only)
     ;;     Their weight does NOT flow to their delegatee for this ballot.
     ;;   - If they did NOT cast and have a delegatee → weight flows to delegatee
     ;;   - Transitive: weight accumulates along delegation chains
     ;;     until reaching someone who cast a stance (or chain terminates)
     ;;
     ;; Example: Alice → Bob → Carol (delegation chain in snapshot)
     ;;   All three cast:    Alice=1, Bob=1, Carol=1 (no flow)
     ;;   Only Carol cast:   Carol=3 (carries Alice + Bob)
     ;;   Alice+Carol cast:  Alice=1, Carol=2 (carries Bob, not Alice)
     ;;   Only Bob cast:     Bob=2 (carries Alice), Carol's weight=1 but uncast
     ...]

    [(close) (bcom (^ballot ... 'closed ...))]
    [(result) ...]))
```

The ballot captures a **delegation snapshot** — a frozen copy of the delegation graph at the moment the ballot is opened. This separates two distinct citizen acts:

| | **Stance override** | **Delegation revocation** |
|---|---|---|
| **What it means** | "I disagree on *this issue*" | "I no longer trust *this person*" |
| **Scope** | Single ballot | Ongoing relationship |
| **Mechanism** | Cast own stance; weight stops flowing to delegatee for this ballot | `($ delegation-cell 'set #f)` on `^citizen-voice` |
| **When it takes effect** | Immediately on this ballot's tally | Next ballot opened after revocation |

**Why snapshot?** If delegation changes affected open ballots, a delegate couldn't reason about the weight they carry. Worse, strategic last-minute revocations become a weapon — revoke right before tally to swing the result. The snapshot eliminates this: delegates know their weight from the moment the ballot opens, and citizens who disagree on substance use the direct override, not the delegation sledgehammer.

**Why direct override?** A citizen who delegated broadly but cares about one specific issue should be able to engage without disrupting their delegation relationship. Override is surgical (this ballot); revocation is structural (all future ballots).

Citizens receive a **faceted view** of the ballot — they can call `cast` but not `tally` or `close`. The commune holds the full ballot. Same read/write split as `spawn-post-and-editor` (§3.3.1): citizens get the "post" facet, the commune gets the "editor" facet.

### 3. `spawn-mandate-delegation` — Revocable representation in parent

**Pattern:** `spawn-logged-revocable-proxy-pair` (§3.3.4) + `^name-predicate` mandate check

The key actor for "a commune issues a revocable capability so a delegate can represent it within its parent federation."

```scheme
(define (spawn-mandate-delegation delegator-name target mandate log)
  "Wrap TARGET in a logged, revocable proxy constrained by MANDATE.
   MANDATE is a ^name-predicate actor (e.g., (set (stance))) or procedure.
   Returns (values proxy revoked?)."
  (define revoked? (spawn ^cell #f))
  (define (^mandate-proxy bcom)
    (lambda args
      ;; 1. Revocation check
      (when ($ revoked? 'get)
        (error "Delegation revoked for" delegator-name))
      ;; 2. Mandate check (attenuation)
      (let ((method-name (car args)))
        (unless (if (procedure? mandate)
                    (mandate method-name)
                    ($ mandate method-name))
          (error "Action outside mandate:" method-name delegator-name)))
      ;; 3. Accountability
      ($ log 'append-to-log delegator-name target args)
      ;; 4. Forward
      (apply $ target args)))
  (values (spawn ^mandate-proxy) revoked?))
```

**Usage:**

```scheme
;; Commune A is a member of Federation F.
;; It holds `federation-voice` — its capability to act within F.
;; It wants delegate D to represent it, but ONLY for voting.

(define mandate (spawn ^name-predicate '(set (stance))))
(define-values (delegate-proxy revoked?)
  (spawn-mandate-delegation "commune-a" federation-voice mandate commune-log))

;; Hand delegate-proxy to Delegate D
;; D can do: ($ delegate-proxy 'stance ballot-id 'yes)  ;; ok
;; D cannot: ($ delegate-proxy 'admit-commune ...)       ;; mandate violation
;; Commune recalls D: ($ revoked? 'set #t)               ;; instant
```

**Term limits:** Add a `term-expiry` `^cell`. The proxy checks `(> (current-time) ($ term-expiry 'get))` alongside the revocation check. Maximum term: 2 years before requiring re-election. No individual may serve more than 4 years in any 8-year period at the same federation level.

**Delegate chains (sub-delegation):** A delegate holding a mandate-proxy may sub-delegate by wrapping their own proxy in another `spawn-mandate-delegation`. This produces a proxy-of-proxy chain where each layer independently enforces its mandate and revocation.

```scheme
;; Bob holds delegate-proxy for Commune-A (mandate: stance only).
;; Bob sub-delegates to Carol for a specific ballot.

(define carol-mandate
  (lambda args
    (match args
      (('stance "water-rights" _) #t)   ;; Carol can vote on water-rights only
      (_ #f))))

(define-values (carol-proxy carol-revoked?)
  (spawn-mandate-delegation "bob→carol" bob-proxy carol-mandate bob-log))

;; Call path: Carol → carol-proxy → bob-proxy → federation-voice
;;
;; ($ carol-proxy 'stance "water-rights" 'yes)
;;   1. carol-proxy checks carol-revoked?         → ok
;;   2. carol-proxy checks carol-mandate           → 'stance "water-rights" ✓
;;   3. carol-proxy logs to bob-log                → "bob→carol forwarded (stance water-rights yes)"
;;   4. carol-proxy forwards to bob-proxy
;;   5. bob-proxy checks bob-revoked?              → ok
;;   6. bob-proxy checks bob-mandate               → 'stance ✓
;;   7. bob-proxy logs to commune-log              → "commune-a forwarded (stance water-rights yes)"
;;   8. bob-proxy forwards to federation-voice     → vote cast
```

Three properties hold structurally — no new primitives needed:

| Property | How it holds |
|---|---|
| **Mandate can only narrow** | Carol's mandate is checked *before* Bob's. Carol can restrict further but never bypass Bob's `(stance)`-only constraint. If Carol's mandate allowed `'admit-commune`, it would still fail at Bob's layer. Attenuation composes: the effective mandate is always the intersection. |
| **Revocation cascades** | If Commune-A revokes Bob (`($ bob-revoked? 'set #t)`), Carol's next call through `carol-proxy` reaches `bob-proxy`, which checks `bob-revoked?` and raises an error. Carol's proxy is structurally dead without anyone touching `carol-revoked?`. Bob can also independently revoke Carol without affecting his own proxy. |
| **Accountability traces the full chain** | Each proxy layer writes to its own log. The commune sees Bob's actions in `commune-log`. Bob sees Carol's actions in `bob-log`. The full chain is recoverable by joining logs: `carol-proxy → bob-log`, `bob-proxy → commune-log`. |

**Depth limit:** Maximum sub-delegation depth of 2 (delegate → sub-delegate). Enforced by adding a `depth` parameter to `spawn-mandate-delegation`:

```scheme
(define (spawn-mandate-delegation delegator-name target mandate log
                                  #:max-depth 2 #:current-depth 0)
  (when (>= current-depth max-depth)
    (error "Sub-delegation depth limit exceeded" delegator-name))
  ;; ... existing proxy body, but sub-delegation increments depth:
  ;; The proxy exposes a 'sub-delegate method that calls
  ;; spawn-mandate-delegation with (+ current-depth 1)
  ...)
```

**Visibility rule:** The originating commune must be able to discover the full delegation chain. Each proxy records its delegator-name and target in a queryable chain:

```scheme
;; Commune queries the chain:
;; ($ bob-proxy 'delegation-chain)
;; → ("commune-a" → "bob")
;;
;; ($ carol-proxy 'delegation-chain)
;; → ("bob→carol" → "commune-a" → "bob")
;;
;; This is read-only introspection — it cannot be used to bypass mandates.
```

**Recall at any depth:** The commune can revoke any layer and everything below it dies. Bob can revoke Carol specifically. Carol cannot revoke Bob. Authority flows downward only — the originator always retains ultimate control.

**Binding instructions (mandat imperatif):** For richer mandates than method-name filtering, the mandate can be a full predicate over the argument list:

```scheme
;; "vote yes on proposal-X, abstain on all others"
(lambda args
  (match args
    (('stance "proposal-X" pos) (eq? pos 'yes))
    (('stance _ pos) (eq? pos 'abstain))
    (_ #f)))
```

### 4. `^commune` — The base-level governed association

**Pattern:** `make-governed-org` 4-seal extension

```scheme
;; 4-seal pattern (extending the 3-seal from org.scm)
gov-seal       ;; governance decisions (open/close ballots, admit/remove members)
planning-seal  ;; economic planning operations
member-seal    ;; member-facing (cast stance, delegate)
delegate-seal  ;; federation representation operations
```

**Rights:**
- Decisions: for all Commune Members on matters internal to the commune
- Immediately-Revoke: Members, Participants, Communes, Commune-Agents, Delegates
- Communicate: Publish all doings and shortcomings
- Withdraw: from any intermediate federation (subject to obligation settlement)

**Key methods:**
- `admit-citizen` / `remove-citizen` — membership management (requires gov-seal)
- `open-ballot` / `close-ballot` — governance (requires gov-seal)
- `delegate-to-federation` — issues a `spawn-mandate-delegation` (requires delegate-seal)
- Standard `^org` methods for commune state

**Responsibilities:**
- To electorate: Publication of proceedings
- To federation: Abide by federation decisions on matters within delegated authority
- To external-constituency: Consider interests of affected non-members

### 5. `^federation` — Communes federated by attribute

**Pattern:** Recursive — structurally identical to `^commune` but members are communes. Weighted voting by citizen count.

```scheme
(define-actor (^federation bcom name attribute
                           member-communes    ;; hashmap: commune-id → (commune-ref . citizen-count)
                           ballots log-ref)
  (methods
    [(admit-commune commune-id commune-ref citizen-count) ...]
    [(remove-commune commune-id) ...]   ;; revokes all delegation proxies
    [(receive-stance commune-id sealed-stance)
     ;; Verify stance endorsed with commune's delegate-seal
     ;; Weight = citizen-count from member-communes hashmap
     ...]
    [(open-ballot proposal-id desc) ...]
    [(obligations commune-id) ...]))     ;; outstanding obligations
```

**Withdrawal:** A commune can withdraw, but: (1) incurred obligations remain until the planning process settles them, (2) the federation's authority over the commune ceases for future matters, (3) metabolic consequences become visible in the planner. Maps to: revoke the commune's federation-voice proxy, keep obligation records until a new plan voids them.

### 6. `^universal-commune` — The inescapable registry

**Pattern:** Encapsulated state, no withdrawal method

```scheme
(define-actor (^universal-commune bcom
                                  citizen-index     ;; hashmap: id → citizen-data
                                  membership-index  ;; hashmap: citizen-id → commune-id
                                  commune-index)    ;; hashmap: commune-id → commune-ref
  (methods
    [(register-citizen id data) ...]        ;; cannot be removed
    [(assign-membership citizen-id commune-id)
     ;; Enforces: each citizen in exactly one commune (no double counting)
     ...]
    [(transfer-membership citizen-id new-commune-id) ...]
    [(citizens-of commune-id) ...]          ;; source of truth for weight verification
    [(total-citizens) ...]))
```

There is no `remove-citizen` method. No `withdraw` method. The universal commune is the expression of inescapable mutual interdependence as inhabitants of a single planet. Freedom of association operates *within* this frame, not against it.

The Universal Commune maintains no standing army, no permanent bureaucracy, and no power of taxation. Its responsibilities: management of the Citizen Index, coordination of planetary-scale interdependencies (atmospheric carbon, ocean health, outer space, pandemic response).

### 7. `^affected-interest-voice` — Non-member standing

**Pattern:** Attenuated facet (Heart of Spritely `^facet`)

When a commune's decision materially affects non-members, those affected get a strictly attenuated capability:

```scheme
(define (spawn-affected-interest-voice ballot-ref group-name)
  ;; Returns a facet that can submit advisory stances (non-binding)
  ;; Cannot participate in binding tally
  ;; Stances are recorded and visible to commune members during deliberation
  (facet ballot-ref 'cast-advisory 'view-stances 'view-result))
```

Follows `^restricted-editor` from §3.3.5: the affected group can speak but cannot decide. Material affect is determined by tracing metabolic consequences through the planning network: who will bear costs, who will receive benefits, whose conditions of existence will be altered.

Procedures for affected interest participation must include: (1) notice to affected parties, (2) opportunity to present evidence and argument, (3) consideration in the final decision, with reasons given for acceptance or rejection.

---

## Liquid Democracy — Transitive Delegation Chains

The delegation graph is a hashmap stored in the commune: `citizen-id → delegated-to-id | #f`.

**Delegation:**
```
Alice delegates to Bob:  graph[alice] = bob
Bob delegates to Carol:  graph[bob] = carol
Chain: Alice → Bob → Carol
```

**Snapshot at ballot open:** When a ballot opens, the current delegation graph is copied into the ballot as `delegation-snapshot`. This snapshot is frozen for the lifetime of that ballot. Changes to the live delegation graph (new delegations, revocations) affect only future ballots.

**Direct override pulls weight out of the chain:**
```
Snapshot: Alice → Bob → Carol

Case 1 — nobody overrides:
  Carol's weight = 3 (own + Bob + Alice)

Case 2 — Alice casts directly:
  Alice's weight = 1 (own vote, pulled out of chain)
  Carol's weight = 2 (own + Bob)

Case 3 — Bob casts directly:
  Bob's weight = 2 (own + Alice, since Alice still delegates to Bob in snapshot)
  Carol's weight = 1 (own only — Bob's direct cast breaks the chain at Bob)

Case 4 — everyone casts directly:
  Alice = 1, Bob = 1, Carol = 1 (all overrides, no flow)
```

**Revocation takes effect on next ballot:**
```
Live graph: Alice → Bob → Carol
Bob revokes delegation to Carol: live graph[bob] = #f

Any OPEN ballot still uses its snapshot (Alice → Bob → Carol)
NEXT ballot opened captures new snapshot: Alice → Bob (terminal), Carol (terminal)
  Bob's weight = 2 (own + Alice)
  Carol's weight = 1
```

**Cycle prevention:** On every `delegate` call, walk the chain from target to see if it reaches the delegator. Reject if cycle detected.

**Key properties:**
- The **delegation snapshot** is frozen per-ballot. Delegates know their weight from the moment a ballot opens — no strategic last-minute revocation.
- **Direct stance always overrides** delegation for that specific ballot. This is the mechanism for engaging on substance without disrupting the delegation relationship.
- **Delegation revocation** is a trust/relationship act that affects future ballots only. It is not a tool for influencing the outcome of an open vote.
- The tally is a single turn that reads the snapshot + stances atomically (Goblins transactional model).

---

## Two Kinds of Delegation (Separate By Design)

| | Liquid democracy (intra-commune) | Federation delegation (inter-scope) |
|---|---|---|
| **Who delegates** | Citizen → citizen | Commune → human delegate |
| **Mechanism** | Pointer in delegation-graph hashmap | Revocable proxy pair actor |
| **Weight** | Flows transitively, computed from frozen snapshot per ballot | Commune's citizen-count (fixed per cycle) |
| **Override** | Direct stance on a ballot pulls weight out of chain for that ballot | N/A — commune acts as unit |
| **Mandate** | None — full vote-weight transfer | Constrained by `^name-predicate` or procedure |
| **Accountability** | Graph is commune state (auditable) | `^logger` records every forwarded call |
| **Revocation** | `^cell` flip on delegation-cell; affects next ballot only | `^cell` flip on revoked?; immediate |
| **Overhead** | O(1) per delegation (hashmap entry) + O(n) snapshot at ballot open | O(1) per delegation (actor + cell + log) |

Different trust models, different mechanisms. Vote delegation is a lightweight graph operation within a single vat. Federation delegation is a heavyweight capability-mediated proxy across vats.

Note the asymmetry in revocation timing: liquid democracy revocation is *deferred* (next ballot) because the snapshot separates relationship-trust from issue-disagreement. Federation delegation revocation is *immediate* because it concerns the capacity to act on behalf of the commune — a broken-trust delegate must be stopped from casting any further stances.

---

## Vat Topology

Each scope = one Goblins vat (following `scope-root.scm`):

- **Each commune** = one vat. All citizen-voices, ballots, delegation-graph, logger are near references. Intra-commune operations are synchronous + transactional (single turn = all-or-nothing).
- **Each federation** = one vat. Commune-to-federation is cross-vat via `<-` (async). Delegation proxies live in the commune's vat; delegates hold far references via OCapN.
- **Universal commune** = one vat. Far references to all commune vats.

---

## Recall Procedure

5% petition threshold → 30-day vote → simple majority removes delegate.

Maps to a **two-phase ballot**:

1. **Petition phase:** A special ballot where `cast` counts toward a threshold rather than a majority. When `(>= (length stances) (* 0.05 citizen-count))`, the ballot auto-transitions to voting phase. The petition ballot is a faceted view — any citizen can cast, but only the commune governance can read the petition count.

2. **Voting phase:** Standard `^ballot` with a 30-day deadline. Simple majority on the tally removes the delegate by flipping `($ revoked? 'set #t)` on their proxy.

This is the `^reviewer` pattern from §3.3.5: the petition is like the reviewer's `approve` — it doesn't directly remove the delegate, it triggers a process that may lead to removal.

---

## Planning-Based Dispute Resolution

When a commune alleges a federation decision exceeds authority:

1. Delegates convene with their communes' `^scope-root` refs (PlanStores) and binding instructions (mandates)
2. They **merge PlanStores** — the existing `plan-for-region` operation, treating the disputed matter as an unmet demand
3. The planner produces feasible resolutions — plans that satisfy metabolic constraints and respect priority rankings
4. Delegates return resolutions to communes (cross-vat `<-` messages)
5. Communes deliberate internally (standard `^ballot`) and either:
   - Reject all resolutions and propose modifications (repeat from step 2)
   - Withdraw from the disputed aspect of cooperation

If withdrawal occurs, the planning process automatically adjusts — the withdrawing commune's commitments become unmet demands to be satisfied by other means, its expected receipts are written off as supply to be redirected.

**Key capability insight:** The dispute resolution process requires no judge or arbiter actor. Each commune holds its own PlanStore capability; the federation holds a merge capability over member PlanStores. The planner is a pure function over the merged data — it produces options, not decisions. Decisions remain with the communes via their ballot mechanisms.

---

## Complete Scenario

1. Universal Commune registers citizen Alice → gets `alice-identity`
2. Alice requests membership in Commune-A → admitted, returns `alice-voice` (a `^citizen-voice`)
3. Commune-A opens a ballot on "increase bread production"
4. Alice casts her stance: `($ alice-voice 'stance "bread-ballot" 'yes)` → sealed endorsement submitted to ballot
5. Commune-A also belongs to Watershed-Federation
6. Commune-A elects delegate Bob with mandate `(set (stance))`:
   ```scheme
   (spawn-mandate-delegation "commune-a" federation-voice mandate log)
   ```
   → gives `bob-proxy` to Bob
7. Bob casts Commune-A's stance in the federation ballot:
   ```scheme
   ($ bob-proxy 'stance "water-rights" 'yes)
   ```
   → logged, mandate-checked, forwarded
8. Commune-A recalls Bob: `($ revoked? 'set #t)` → instant, Bob's proxy is dead

---

## Open Questions

- ~~**Ballot finality vs. delegation fluidity:**~~ Resolved — snapshot at ballot open, with direct stance override. These are two separate concerns: disagreeing on an issue (cast your own stance, pulling your weight out of the delegation chain for that ballot) vs. revoking trust in a delegate (affects future ballots only). See §2 `^ballot` and "Liquid Democracy" sections.
- **Cross-commune liquid delegation:** Can a citizen delegate their vote to a citizen in a *different* commune? The current design scopes delegation graphs per-commune. Cross-commune delegation would require the universal commune to mediate.
- ~~**Delegate chains in federations:**~~ Resolved — yes. Proxy-of-proxy with mandate intersection, cascading revocation, per-layer logging, depth limit of 2. See §3 "Delegate chains" above.
- **How do affected interest groups get identified?** The planning network can trace metabolic consequences, but who initiates the tracing? The commune? The federation? An automated planner query?
