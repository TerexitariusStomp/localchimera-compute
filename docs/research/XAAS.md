# playnet as a Service

_Computable organizations, hosted. AI as a first-class organizational citizen._

---

## Part 1: The Organizational Offering

### The Problem

Organizations today are opaque machines. Their rules live in people's heads, in scattered
policy documents nobody reads, in email threads that scroll past the retention window.
Governance is narrative — someone tells you how things work, and you believe them or you
don't. History is whatever the last person remembers. Accountability is a social contract
enforced by social pressure.

When you ask "who authorized this?" you get a name and a shrug. When you ask "what were
the rules three months ago?" you get silence. When you ask "can we try a different
governance model?" you get a committee and a six-month timeline.

The problem is not that organizations are poorly run. The problem is that they are not
_computable_. You cannot inspect them, replay them, fork them, or reason about them
formally. They exist as informal consensus in the minds of their members, and when that
consensus breaks, there is no ground truth to fall back on.

playnet makes organizations computable.

---

### What You Get

A live Scheme interpreter where the org IS the evaluator. Rules are live code — not
configuration files, not YAML, not smart contracts compiled to an opaque VM. They are
Scheme expressions sitting in the same expression-space as the data they govern. History
is an immutable log of attributed, cryptographically signed S-expressions. State is an
environment — a set of bindings from names to values, inspectable at any time.

```scheme
;; Create a governed org with three governance domains
(define-values (org gov-seal infra-seal member-seal)
  (make-governed-org "my-cooperative"))

;; Enter the REPL — you're inside the org now
(enter! org)

play[genesis]> (define greeting "welcome to the cooperative")
play[genesis]> (modify! 'budget 50000)
play[genesis]> (show-history)
=> Version 0 [genesis] : (quote initial) (parent: 0)
   Version 1 [genesis] : (define greeting "welcome to the cooperative") (parent: 0)
   Version 2 [genesis] : (modify! (quote budget) 50000) (parent: 1)
```

Everything is an S-expression. The org's rules, its state, its history, the expressions
that produced each state transition — all the same representation. There is no gap between
the org and its description. This is what homoiconicity gives you at the organizational
level: the org can inspect itself, reason about itself, and transform itself using the same
language it's built in.

The evaluator is metacircular — a Scheme interpreter written in Scheme. This means
`enact!` can install an arbitrary validator function that changes how all future expressions
are evaluated. The validator has access to the full environment before and after every
change. It must accept its own installation to take effect. You are not configuring an
organization. You are metaprogramming the interpreter that _is_ the organization, and
the interpreter must consent.

---

### The Three Properties

#### 1. Auditable

Every state-changing expression creates a history entry:

```
(version  expressor-id  expression  parent-version  snapshot  signature)
```

- **Who**: the expressor identity that authored it
- **What**: the original S-expression
- **Where**: the parent version — which state it was evaluated against
- **Proof**: an Ed25519 signature over the entry, verifiable by anyone with the public key

```scheme
;; Verify any history entry
(verify-history-entry entry expressor-public-key)  ;; => #t or #f
```

History is not a log — it's a tree. Rollback creates branches. The org can diverge from
any prior state, and the abandoned branch remains in history. Every path is preserved.

#### 2. Transformable

The org is self-modifying. `enact!` installs a new validator — changing the rules by which
all future expressions are judged. `rollback!` restores any prior state. `modify!` traverses
expression-space. The org's evolution is a path through the space of all reachable
organizational states, and because every step is a signed S-expression, the entire path
is replayable, inspectable, and forkable.

```scheme
;; Install a new governance rule — must pass the current validator to take effect
play[genesis]> (enact!
                 (lambda (expressor name value pre post)
                   (or (not (eq? name 'budget))
                       (> (assoc-ref post 'budget) 0)))
                 gov-seal)

;; Rollback to any prior state
play[genesis]> (rollback! 2 gov-seal)
```

#### 3. Composable

Organizations can hold references to other organizations. Goblins' OCapN (Object
Capability Network) enables direct actor references across processes and machines via
Unix domain sockets or network transport. An org can federate with other orgs — passing
attenuated capabilities across boundaries.

```scheme
;; On the roadmap: orgs communicating via OCapN
;; Org A passes an attenuated service capability to Org B
;; Org B can start a service but not stop it — the capability IS the boundary
```

_Note: Full cross-org composition via OCapN is on the roadmap. The infrastructure
(Goblins OCapN, Unix domain socket netlayer) exists. The org-level wiring is next._

---

### The Governance Model

A governed org has three domains, each protected by a cryptographic sealer:

| Domain             | Sealer        | Governs                 | Examples                                |
| ------------------ | ------------- | ----------------------- | --------------------------------------- |
| **Governance**     | `gov-seal`    | `validator`, `rollback` | Constitutional amendments, rule changes |
| **Infrastructure** | `infra-seal`  | `infra-*` names         | Deployments, services, servers          |
| **Membership**     | `member-seal` | `member-*` names        | Expressors, roles, admissions           |

Ungoverned names (anything not matching the three domain patterns) are freely modifiable
by any expressor. This is deliberate — experimentation should be frictionless, and
governance should only apply where it matters.

The validator checks **possession**, not identity. Authorization is proved by endorsing
a value with the appropriate sealer:

```scheme
;; Governed: requires infra-seal endorsement
(modify! 'infra-deploy (endorse deploy-cap infra-seal))

;; Ungoverned: anyone can set this
(modify! 'proposal "fund the community garden")
```

This is the ACL-to-capability shift. There are no access control lists, no role-based
permission checks, no identity lookups. If you hold the sealer, you have authority. If
you don't, you don't. The sealer is an unforgeable Goblins actor reference — a
cryptographic capability object that cannot be guessed, forged, or stolen without
physical access to the runtime.

```scheme
;; Under the hood: the faceted validator
(define validator
  (spawn ^faceted-validator
    (list (make-facet (name-set-predicate '(validator rollback)) sealed-gov?)
          (make-facet (name-prefix-predicate "infra-")           sealed-infra?)
          (make-facet (name-prefix-predicate "member-")          sealed-member?))))
```

The validator is itself a Goblins actor — fully serializable, persistent across restarts.
The governance model survives `guix deploy --roll-back`. It survives server migration.
It survives everything, because it's part of the actor graph.

---

### What "Computable" Means in Practice

**"What was the state of this org 3 months ago?"** — you get an exact answer. Every
history entry carries a snapshot of the org's full state (bindings, validator) at the
moment it was created. `rollback!` doesn't replay from scratch — it restores directly.

**"Who authorized this deployment?"** — the history entry is signed with the authorizer's
Ed25519 keypair. The signature is verifiable by anyone with the public key. The validator
recorded which endorsement was required. The full chain is: who held the seal, what they
endorsed, which validator approved it, and what the org looked like before and after.

**"Can we try a different governance model?"** — fork the org. Rollback to a prior state,
enact a different validator, explore. The original branch remains in history. You can
compare outcomes.

**"What if we replayed history with different rules?"** — history entries are S-expressions.
You can re-evaluate them against a different validator. The org's past is not a log — it's
source code.

**"Can the org describe itself?"** — yes. `(show-history)`, `(show-expressors)`, inspecting
bindings — all from within the same REPL. Meta-play is Scheme over Scheme. There is no
separate admin interface.

---

### Use Cases

#### Cooperatives and Communes

Democratic governance with real accountability. Every vote is a signed expression. Every
budget change is attributed. Every rule change requires the governance seal. Members can
inspect the full history — not meeting minutes, but the actual expressions that produced
each state transition.

```scheme
;; A cooperative budget vote
(defexpressor 'alice (generate-key-pair))
(defexpressor 'bob (generate-key-pair))

(as alice-seal (modify! 'proposal-garden "allocate 5000 to community garden"))
(as bob-seal (modify! 'vote-bob-garden "yes"))
(as alice-seal (modify! 'vote-alice-garden "yes"))

;; The validator could require quorum before modifying 'budget
(as treasurer-seal
  (modify! 'budget (- (lookup 'budget) 5000)))
```

#### DAOs That Are Actually Governable

Smart contracts are write-once, opaque, and expensive to modify. An playnet is a live
interpreter — rules can be debated, tested, enacted, and rolled back. Governance is
Scheme, not Solidity. The audit trail is richer than a blockchain (full state snapshots,
not just transaction receipts). And you can fork the org to experiment without risking
real assets.

#### Federated Communities

Multiple orgs on the same machine communicate via OCapN over Unix domain sockets. A host
org can spawn tenant orgs as Shepherd services, passing attenuated capabilities — one
tenant gets read-only access to the knowledge base, another gets deployment rights for
their own infrastructure slice.

#### Research Organizations

Track hypotheses, decisions, and funding allocations as attributed expressions. The
knowledge base (hyperarc metagraphs + miniKanren queries) provides relational queries
over structured knowledge. Every fact is signed and versioned.

#### Open Source Foundations

Governance decisions, maintainer elections, fund disbursements — all computable. The org's
constitution is a validator function. Amending it requires the governance seal and
self-acceptance by the current rules.

---

### The Deployment Story

One command gives you a Guix System machine on Hetzner with your org running as a
persistent Goblins actor:

```bash
GUIX_HETZNER_API_TOKEN=<token> guix deploy -L deploy/guix deploy/guix/machines.scm
```

What this does:

1. Creates the Hetzner server via API (cx22: 2 vCPU, 4GB RAM, 40GB disk)
2. Boots into rescue mode, formats disk, installs minimal Guix
3. Reboots and applies the full operating-system config
4. On subsequent runs: reconfigures the running system in place

The OS declaration is Scheme. The service definition is Scheme. The org running on it is
Scheme. It's Scheme all the way down.

```scheme
;; The machine definition
(machine
  (operating-system
    (make-hetzner-system
      #:hostname "coop-1"
      #:certbot-email "ops@my-coop.org"
      #:certbot-domains '("coop-1.my-coop.org")
      #:extra-services
      (list (service playnet-service-type
              (playnet-configuration
                (name "host")
                (entry-point "/etc/playnet/host-entry.scm")
                (socket-path "/run/playnet/host.sock"))))))
  (environment hetzner-environment-type)
  (configuration
    (hetzner-configuration
      (server-type "cx22")
      (location "nbg1")
      (ssh-key "~/.ssh/id_ed25519"))))
```

Each org runs as a Shepherd service — isolated, logged, restartable:

```bash
herd start playnet-host      # start the org
herd stop playnet-host       # stop it
herd status               # see all services
herd log playnet-host        # view logs
```

SSH into the machine to live-hack via Geiser (Emacs REPL integration). Connect to
the running Goblins vat, evaluate expressions in the live org, inspect state — all
from your editor.

Rollback the entire machine:

```bash
guix deploy --roll-back deploy/guix/machines.scm
```

This rolls back the OS, the services, everything. The org's Goblins persistence store
(Bloblin) maintains its own versioned state on top of this. Two layers of rollback —
infrastructure and organizational — both in Scheme.

---

### The Persistence Story

Orgs persist via Goblins' Bloblin store. The entire actor graph serializes — bindings,
validator (as actor refs, not closures), history with signatures, expressor store (public
keys, sealer actors), output capability. On restart, everything comes back including
governance and capabilities.

```scheme
;; Persistent org — state survives process restarts
(define store (make-bloblin-store "./my-org.db"))
(define-values (org gov infra member)
  (make-governed-org-persistent "my-org" store))

;; ... use the org ...
;; process dies, machine reboots, whatever
;; on restart:
(define-values (org2 ...) (restore-governed-org store))
;; validator still works, sealers still seal, history verifies
```

No external database. No ORM. No migration files. The persistence layer is the actor
system itself. What you see in the REPL is exactly what's on disk.

---

### The Knowledge Layer

Orgs can maintain structured knowledge using hyperarc metagraphs — a generalization of
hypergraphs where arcs can connect arbitrary sets of nodes, and metagraphs can contain
arcs over other arcs. Queries use miniKanren, a relational logic programming language
embedded in Scheme.

```scheme
;; Relational query: find all entities related to "alice" in the "members" domain
(run* (related)
  (related-by-o kb "members" alice-node related))

;; Transitive closure with proof trace
(run* (endpoint trace)
  (transitive-o kb "dependencies" "guile" endpoint trace))
;; => (("goblins" ("guile" "goblins"))
;;     ("playnet" ("guile" "goblins" "playnet")))
```

This is not a vector database. It's a logic programming engine over structured,
signed, versioned organizational knowledge. Every fact is an S-expression. Every
query is a relation. Proof traces tell you _how_ a conclusion was reached, not just
_that_ it was reached.

_Note: Full integration of the knowledge base into org bindings (so facts are
governed by the validator) is on the roadmap._

---

### The Stack

```
┌─────────────────────────────────────────────────────────────┐
│  AI / LLM  (external: Claude, Gemini, local model)          │
│  ↕ MCP capability actor (^mcp-server in Goblins)            │
├─────────────────────────────────────────────────────────────┤
│  Emacs + Geiser  (live REPL to running Goblins vat)         │
│  structural editing, evaluate-in-org, live inspection       │
├─────────────────────────────────────────────────────────────┤
│  playnet  (Guile Scheme + Spritely Goblins)                    │
│  the org IS the evaluator — rules, state, history           │
│  capability-secure, signed, persistent, composable          │
├─────────────────────────────────────────────────────────────┤
│  Shepherd  (Guix init/service manager)                      │
│  each playnet process is a Shepherd service                    │
├─────────────────────────────────────────────────────────────┤
│  Guix System  (OS declaration in Scheme)                    │
│  packages, services, users, bootloader — all records        │
├─────────────────────────────────────────────────────────────┤
│  Hetzner Cloud  (provisioned by guix deploy)                │
│  one command: create, install, configure, reconfigure       │
└─────────────────────────────────────────────────────────────┘
```

Every layer is Scheme. The capability graph covers organizational decisions _and_
computational substrate. The org can govern its own infrastructure.

---

---

## Part 2: AI-Play — AI as a First-Class Organizational Actor

### The Premise

Most AI systems are tools. They have no identity. No memory beyond the session. No ability
to take auditable actions with lasting consequences. They are prompt-in, text-out — a
function call with no attribution, no history, no accountability.

What if the AI weren't _using_ the system, but _in_ it?

In playnet, an AI expressor is an organizational citizen. It has its own cryptographic keypair,
its own sealer, its own history of signed actions. It is subject to the same validator as
every human expressor. Its capabilities are exactly what it was given — no more, no less.
And every action it takes is recorded, attributed, and reversible.

```scheme
;; Create an AI expressor with its own identity and limited capabilities
(define-values (ai-seal ai-public-key)
  (make-ai-expressor! org
    #:name 'claude-agent
    #:keypair (generate-key-pair)
    #:extra-bindings
    `((query-kb . ,kb-query-cap)
      (propose  . ,proposal-cap))))

;; The AI evaluates under its own authority — not the caller's
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'analysis "treasury trending 12% over budget"))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))

;; History shows: claude-agent modified 'analysis, signed with ai-public-key
;; The validator approved it (ungoverned name — free to modify)
;; The entry is verifiable by anyone
```

The AI isn't calling an API. It's expressing inside the org. The expression is evaluated
by the same metacircular interpreter that evaluates human expressions. It goes through the
same validator. It produces the same kind of history entry. The only difference is whose
key signed it.

---

### 1. Autonomous Governance Participation

The AI can propose, debate, and vote on organizational matters — with its votes recorded
alongside human members. Not as a gimmick, but as a capability-governed expressor bound
by the same validator.

```scheme
;; AI proposes a budget reallocation
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'proposal-q2
               "Reallocate 3000 from marketing to infrastructure.
                Rationale: server costs increased 40% after onboarding wave.
                Current marketing spend shows diminishing returns per
                the engagement metrics in last quarter's report."))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))
```

The proposal is:

- Attributed to `claude-agent` in history
- Signed with the AI's Ed25519 keypair
- Subject to whatever validator is in effect
- Inspectable by any expressor via `(show-history)`
- Permanent — cannot be silently deleted or modified

If the org's validator requires quorum for budget changes, the AI's proposal is exactly
like a human's — it starts the process, it doesn't bypass it. The validator doesn't know
or care whether the expressor is human or AI. It checks endorsement, not identity.

---

### 2. Infrastructure Management with Attribution

playnet can govern its own infrastructure. A `^deploy-cap` is a Goblins actor pre-bound to a
specific deployment configuration, content-hashed at creation time, verified at deploy time.
When the AI is granted infrastructure capabilities, every action carries full provenance.

```scheme
;; Grant the AI an attenuated infrastructure capability
;; It can check service status but not stop services
(define ai-service-cap
  (attenuate-service-cap (org-vat org) nginx-cap 'status))

;; Grant deployment capability (requires infra-seal endorsement)
(with-vat (org-vat org)
  (evaluate '(modify! 'infra-deploy (endorse deploy infra))
            (org-ref org)
            `((deploy . ,deploy-cap) (infra . ,infra-seal))
            genesis-id))
```

When the AI deploys, the history entry records:

- **Who** authorized it (the AI's expressor ID)
- **What** was deployed (the expression, plus the content-hash of the config)
- **When** it happened (the version number in the history chain)
- **Under what rules** (the validator that approved the endorsement)
- **Proof** (Ed25519 signature, verifiable by anyone with the AI's public key)

And it's reversible:

```scheme
;; Roll back the deployment — requires governance seal
(with-vat (org-vat org)
  (evaluate '(rollback! prior-version gov)
            (org-ref org)
            `((prior-version . ,v) (gov . ,gov-seal))
            genesis-id))
```

Rollback restores the org's state to before the deployment. The deployment itself would
need to be rolled back at the infrastructure level (`guix deploy --roll-back`), but the
organizational authorization is cleanly unwound.

---

### 3. The Concrete Hetzner Example

Here's what AI-managed infrastructure looks like end to end:

**The AI notices a cost anomaly:**

```scheme
;; AI queries the org's infrastructure bindings
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'infra-cost-analysis
               "Hetzner invoice for March: EUR 47.20. Previous month: EUR 31.40.
                Delta: +50.3%. Root cause: cx22 -> cx32 upgrade on guix-2
                was authorized in v847 by alice but the workload metrics
                don't justify cx32. Recommending downgrade back to cx22."))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))
```

**The AI proposes a change:**

```scheme
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'proposal-downgrade-guix2
               "Downgrade guix-2 from cx32 to cx22.
                Estimated savings: EUR 15.80/month.
                Risk: none — peak CPU utilization was 12% last 30 days.
                Requires: infra-seal endorsement to modify deployment config."))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))
```

**A human reviews and approves:**

```scheme
play[alice]> (show-history)
;; ... sees the AI's analysis and proposal, attributed to claude-agent ...
;; Alice holds infra-seal, so she can authorize the change
play[alice]> (modify! 'infra-guix2-config
               (endorse updated-deploy-cap infra-seal))
```

**The AI executes (if permitted):**

If the validator grants the AI execution rights (via an attenuated deploy capability),
the AI can execute the deployment. If not, the AI's role stops at analysis and proposal.
Either way, the full chain is in the history: who analyzed, who proposed, who approved,
who executed.

**The AI reports:**

```scheme
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'infra-deploy-report-guix2
               "Deployment complete. guix-2 reconfigured to cx22.
                Verification: herd status shows all services running.
                Next action: monitor for 48 hours, alert if CPU > 80%."))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))
```

Every step is an S-expression in the org's history. Every step is signed. Every step
is reversible. The AI's analysis, the human's approval, the execution, the report —
all in the same auditable log, all governed by the same validator.

---

### 4. MCP as a Capability Actor

The Model Context Protocol (MCP) gives AI models access to tools. In playnet, tools are
capability actors — unforgeable, attenuatable, traceable through the Goblins actor system.

```scheme
;; Build an MCP server with specific tools
(define mcp
  (make-playnet-mcp-server (org-vat org) org
    #:allow-bindings? #t    ;; read current bindings
    #:allow-history?  #t    ;; read history
    #:allow-eval?     #f    ;; no arbitrary code execution
    #:allow-modify?   #t))  ;; can modify ungoverned names

;; Or build a custom MCP server with hand-picked tool capabilities
(define mcp
  (make-mcp-server (org-vat org)
    "query-kb"   kb-query-tool
    "propose"    proposal-tool
    "summarize"  summarize-tool))
```

Each `^tool-cap` is a Goblins actor with a handler, a name, a description, and a
read-only flag. The `^mcp-server` wraps a set of these tools. Both are `define-actor` —
fully persistent. The server can be attenuated: give the AI a version without dangerous
tools. The org's history shows exactly which tools the AI was given access to.

```scheme
;; List available tools
($ mcp 'list-tools)
;; => (((name . "playnet-bindings") (description . "List all current bindings...") (read-only . #t))
;;     ((name . "playnet-history") (description . "Show recent org history...") (read-only . #t))
;;     ((name . "playnet-modify") (description . "Set a binding in the org...") (read-only . #f)))

;; Call a tool
($ mcp 'call "playnet-history" '(("count" . 5)))
```

This is cleaner than external MCP because:

- The server IS a capability — unforgeable, attenuatable
- Every tool call goes through the Goblins actor system — traceable
- The org history records which tools the AI was given
- Tool access survives persistence (the actor refs serialize)

---

### 5. Self-Modifying Knowledge Base

The AI doesn't just query a vector database. It expresses facts into the org's knowledge
system — structured hyperarc metagraphs queryable via miniKanren.

```scheme
;; AI asserts a fact into the knowledge base
(with-vat (org-vat org)
  (evaluate '(as seal (modify! 'kb-ticket-1234
               '(hyperarc (id . ticket-1234-request)
                           (meta . ((source . "support-queue")
                                    (timestamp . "2026-03-27")))
                           (nodes . ((node (id . user-alice)
                                           (value . "alice")
                                           (meta . ((role . "requester"))))
                                     (node (id . feature-x)
                                           (value . "dark-mode")
                                           (meta . ((type . "feature-request")
                                                    (priority . "medium")))))))))
            (org-ref org)
            `((seal . ,ai-seal))
            genesis-id))
```

These facts are:

- **Signed** with the AI's keypair
- **Versioned** in the org's history
- **Governed** by the validator (if stored under a governed name prefix)
- **Queryable** via miniKanren relational queries

```scheme
;; Query: what has alice requested?
(run* (feature)
  (fresh (kb arc node1 node2 id1 id2 m1 m2)
    (related-by-o kb "requests" node1 node2)
    (node-o node1 id1 "alice" m1)
    (node-o node2 id2 feature m2)))
```

_Note: Full integration of the knowledge layer into org base-bindings (so `assert!` and
`query` are built-in forms governed by the validator) is on the roadmap._

---

### 6. Multi-Agent Coordination

Multiple AI expressors — different models, different roles — can operate within the same
org. Each has its own keypair, its own sealer, its own capability set.

```scheme
;; Create two AI expressors with different capabilities
(define-values (analyst-seal analyst-pk)
  (make-ai-expressor! org
    #:name 'analyst
    #:extra-bindings `((query-kb . ,kb-read-cap))))

(define-values (executor-seal executor-pk)
  (make-ai-expressor! org
    #:name 'executor
    #:extra-bindings `((deploy . ,attenuated-deploy-cap)
                       (service-status . ,status-only-cap))))
```

The analyst can read the knowledge base but can't deploy. The executor can deploy but
can't read the knowledge base. Their actions are independently signed and independently
verifiable. The history shows exactly which AI did what.

This enables patterns like:

- **Separation of concerns**: one AI analyzes, another executes
- **Review chains**: the executor's actions can be conditioned on the analyst's findings
- **Audit clarity**: when something goes wrong, the history shows the full chain of
  AI-to-AI interaction

_On the roadmap: quorum governance (M-of-N endorsement) would allow requiring that
both the analyst and a human approve before the executor can act. OCapN multi-agent
coordination across machines would allow AI expressors in different orgs to collaborate
via direct Goblins actor references._

---

### 7. Persistent Agency

The AI isn't reset each session. Its expressor identity persists across restarts via
Goblins' Bloblin persistence:

- **Memory of past actions**: the org's history contains every expression the AI has
  ever evaluated, signed with its key
- **Accumulated capabilities**: bindings stored under the AI's authority survive
  persistence
- **Identity continuity**: the AI's keypair, sealer, and expressor entry in the org's
  store all serialize and restore
- **A track record**: the validator can reference the AI's history of actions to make
  governance decisions

The AI's identity is not a prompt prefix. It's a cryptographic keypair registered in
the org's expressor store, with a sealer that proves authority and a history that proves
track record.

---

### Trust Without Centralization

You don't need to trust the AI. You can verify it.

Every action the AI takes is:

| Property        | Mechanism                                     |
| --------------- | --------------------------------------------- |
| **Attributed**  | Expressor ID in history entry                 |
| **Signed**      | Ed25519 signature, verifiable with public key |
| **Bounded**     | Capabilities govern what actions are possible |
| **Validated**   | Same `^faceted-validator` as human expressors |
| **Reversible**  | `rollback!` restores any prior state          |
| **Inspectable** | `(show-history)` from inside the org          |

The capability model means the AI cannot escalate its own privileges. It cannot access
governance seals it wasn't given. It cannot modify infrastructure names without the
infrastructure endorsement. It cannot forge another expressor's identity. The Goblins
actor system enforces these boundaries at the runtime level — not by policy, but by
the structure of the object graph.

```scheme
;; The AI cannot do this — it doesn't hold gov-seal:
(with-vat (org-vat org)
  (evaluate '(as ai-seal (enact! new-validator gov-seal))
            (org-ref org) `((ai-seal . ,ai-seal)) genesis-id))
;; => Error: validator rejected — gov-seal endorsement required
```

The AI can _propose_ a validator change. It cannot _enact_ one without the governance
seal. This is not a guardrail — it's a mathematical property of the capability system.
The seal is an unforgeable actor reference. You either have it or you don't.

---

### The Comparison

|                       | Traditional AI Integration               | playnet AI Expressor                                     |
| --------------------- | ---------------------------------------- | -------------------------------------------------------- |
| **Identity**          | Prompt injected into session             | Own Ed25519 keypair and sealer                           |
| **Actions**           | Ephemeral API calls                      | Signed, auditable, permanent history entries             |
| **Memory**            | None between sessions                    | Full history access + persistent state                   |
| **Self-modification** | Cannot modify its own constraints        | Can propose validator changes (subject to governance)    |
| **Infrastructure**    | Separate from infra, calls external APIs | Direct `^deploy-cap` and `^service-cap` actors           |
| **Accountability**    | Logs somewhere, maybe                    | Full attribution + cryptographic verification + rollback |
| **Capability scope**  | Whatever the API key allows              | Exactly the actor refs it was given — no more            |
| **Coordination**      | Ad hoc, no shared state                  | Multiple expressors in the same org, same history        |
| **Persistence**       | Stateless by default                     | Survives restarts — keypair, capabilities, history       |
| **Governance**        | None — or bolted-on RBAC                 | Same `^faceted-validator` as humans, same rules          |

---

### What's Missing — Honest Assessment

The architecture is sound. The core is built. But several pieces are needed to complete
the vision described above:

#### Built and Working

- `^org` actor (Goblins, Hoot-compatible, version 5) with metacircular evaluator
- `make-governed-org` with three governance domains (gov/infra/member sealers)
- Capability security via endorsement (`endorse`, `endorsed-with?`, `^faceted-validator`)
- Cryptographic signatures on history entries (Ed25519, `verify-history-entry`)
- AI as its own expressor (`make-ai-expressor!`, own keypair and sealer)
- MCP capability actor (`^mcp-server`, `^tool-cap`, `make-playnet-mcp-server`)
- Guix+Hetzner deployment (`guix deploy` with `hetzner-environment-type`)
- Shepherd service type for playnet processes (`playnet-service-type`)
- Persistence via Goblins Bloblin store
- Knowledge layer (hyperarc metagraphs + miniKanren queries)
- 225+ passing tests

#### On the Roadmap

| Missing Piece                              | What It Enables                                                                                                | Status                                                    |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| **Quorum governance (M-of-N sealer)**      | Requiring multiple endorsements for sensitive actions — e.g., 2-of-3 board members must approve budget changes | Designed, not yet implemented                             |
| **Knowledge base in org bindings**         | `(assert! fact)` and `(query pattern)` as built-in org forms, governed by the validator                        | Modules exist, wiring into base-bindings is next          |
| **OCapN multi-org composition**            | Orgs holding direct actor references to other orgs across Unix sockets or network                              | Goblins OCapN exists, org-level wiring is next            |
| **Host org tenant model**                  | Privileged org spawning and managing tenant orgs with attenuated capabilities                                  | Designed (`module/playnet/host.scm`), not yet implemented |
| **Guix deploy as org action (end-to-end)** | `^deploy-cap` wired into a governed org with full provenance chain                                             | `^deploy-cap` exists, end-to-end wiring is next           |
| **Shepherd-as-Goblins**                    | Service management via direct actor references instead of subprocess calls to `herd`                           | Waiting on Spritely (expected 2025)                       |
| **Per-expressor output routing**           | Each expressor's output goes to its own channel (terminal, log, audit stream)                                  | Lower priority — org-level output sufficient for now      |

None of these are research problems. They are engineering work on a foundation that
already exists and is tested. The core invariants — possession-based authorization,
attributed history, persistence-correct actors, cryptographic signatures — are all in
place and passing tests today.

---

### The Synthesis

playnet as a service is not an org-chart tool, not a project management app, not a voting
platform. It is the substrate beneath all of those — a computable interpreter in which
any organizational form can be expressed, enacted, inspected, and transformed.

Adding AI to this substrate doesn't bolt on a chatbot. It gives the AI the same status
as any other participant: an identity, a history, a bounded set of capabilities, and
accountability for its actions. The AI can be as powerful or as constrained as the org
decides — not by policy documents, but by the capabilities it holds.

The combination is something that doesn't exist yet:

- **For organizations**: a governance system that is actually computable — inspectable,
  replayable, forkable, provably auditable
- **For AI**: an operating environment where the AI has real agency _and_ real
  accountability — not a sandbox, not an API wrapper, but a first-class participant
  in a self-governing system
- **For the stack**: Scheme all the way down — from the organizational rules to the
  deployment infrastructure to the OS — one language, one paradigm, one capability graph

The org governs the AI. The AI participates in the org. The org governs its own
infrastructure. The infrastructure runs the org. It's turtles all the way down — but
the turtles are Scheme expressions, and they're all signed.

```scheme
;; The full picture:
(define-values (org gov infra member)
  (make-governed-org "my-commune"))

(define-values (ai-seal ai-pk)
  (make-ai-expressor! org
    #:name 'claude
    #:extra-bindings
    `((mcp . ,(make-playnet-mcp-server (org-vat org) org
                #:allow-history? #t
                #:allow-bindings? #t
                #:allow-modify? #t)))))

;; The AI can read the org, propose changes, modify ungoverned names.
;; It cannot touch governance, infrastructure, or membership
;; without the corresponding seal.
;; Every action is signed with ai-pk.
;; Every action is in the history.
;; Every action is reversible.

;; That's the offering.
```
