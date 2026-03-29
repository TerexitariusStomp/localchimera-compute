# The Self-Improving Loop

_A system that reasons about itself, in itself, using itself._

---

## The insight

xorg already has every piece needed for a self-reflective, self-improving system. They just haven't been wired together:

| Piece | What it does | Where it lives |
|-------|-------------|----------------|
| miniKanren | Relational logic queries | `module/xorg/kanren.scm` |
| Hyperarcs | Knowledge representation as S-expressions | `module/xorg/hyperarc.scm` |
| Knowledge queries | Transitive closure with proof traces | `module/xorg/knowledge.scm` |
| Metacircular evaluator | Evaluates S-expressions | `module/xorg/evaluator.scm` |
| Goblins actors | Governed state transitions | `module/xorg/actors.scm` |
| `bcom` | The system becomes its new version | Goblins primitive |
| Hoot/WASM | All of the above runs in the browser | `browser/repl.scm` |

Each piece is an S-expression. Each piece can be queried, transformed, and rewritten by the other pieces. The system is homoiconic all the way down — the representation the evaluator consumes is the same representation the knowledge base stores is the same representation miniKanren reasons over.

## The loop

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│  Observe ──→ Reason ──→ Propose ──→ Govern ──→ Apply
│     ↑                                          │    │
│     └──────────────────────────────────────────┘    │
│                                                     │
│  The knowledge base updates to reflect the new      │
│  state. The loop continues. The reasoning engine    │
│  itself is subject to the same loop.                │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Observe

Read the system's own state as S-expressions. The org's bindings, the knowledge base's facts, the log's history — all are already alists and tagged lists. There is no translation step. The observation IS the data.

```scheme
($ org 'snapshot)
;; => ((greeting . "hello") (deploy . "my-cap") ...)
```

### Reason

Query the knowledge base using miniKanren. Relational queries find connections, transitive dependencies, and proof-traced inference chains.

```scheme
(run* (q) (transitive-o system-kb 'push-to-main 'kernel q))
;; => (((push-to-main → github-actions) (github-actions → guix-deploy) (guix-deploy → kernel)))
;; The proof trace shows HOW the conclusion was reached.
```

### Propose

Generate S-expressions representing changes. A proposal is not free text — it is a valid expression in the same language the evaluator understands.

```scheme
(define proposal
  '(modify! 'max-connections 128))
```

### Govern

The proposal passes through Goblins governance. It is logged (who proposed it, when, with what authority). It can be attenuated (read-only facets cannot propose mutations). It can be revoked (cut the proxy, the proposer loses access).

```scheme
;; The proposal is evaluated through a governed proxy
($ governed-org 'modify! 'max-connections 128)
;; ^logger records: user=alice, method=modify!, args=(max-connections 128), snapshot=...
```

### Apply

`bcom` — the actor becomes its new version. The state transition is atomic (vat turn). If anything fails, the entire turn rolls back. The system is now in a new state.

### Loop

The knowledge base observes the new state. New facts are derived. The cycle continues.

## Why this is different

### Skills as S-expressions, not markdown

Currently, the project's self-knowledge lives in markdown files consumed by an external AI (Claude Code). This works, but it is opaque to the system itself. The system cannot query its own documentation. It cannot reason about its own structure. It cannot propose changes to its own skills.

If skills are S-expression knowledge bases — hyperarc facts queryable by miniKanren — then:

- The system can answer "what does the deploy layer control?" by running a query, not by parsing markdown.
- The system can answer "what depends on the evaluator?" by computing transitive closure, with a proof trace showing the chain.
- The system can detect inconsistencies: "this fact says X depends on Y, but Y was removed."
- The system can propose new facts: "if we add module Z that depends on the evaluator, here is the updated dependency graph."

### The reasoning engine is subject to the loop

miniKanren itself is an S-expression (~219 lines of Scheme). It lives in the same knowledge base it queries. The evaluator that runs miniKanren is also an S-expression. So:

- The system can query the structure of its own reasoning engine.
- The system can propose extensions to miniKanren (new relations, new search strategies).
- Those extensions are governed by the same actor mechanisms — logged, revocable, attributed.
- The extended reasoning engine then has new capabilities for the next cycle.

This is not a fixed AI querying a static database. It is a reasoning system that can improve its own reasoning, governed by the same capability security that governs everything else.

### miniKanren unification IS pattern matching

There is no separate "pattern matching engine" and "query engine." miniKanren's unification is both. When you write:

```scheme
(run* (q)
  (fresh (arc)
    (hyperarc-o system-kb arc)
    (== (node-ref arc 'type) 'layer)
    (== (node-ref arc 'name) q)))
```

You are simultaneously:
1. Pattern matching over the knowledge base (finding hyperarcs of type 'layer)
2. Extracting values (binding `q` to the layer name)
3. Doing so relationally (the query can run "backwards" — given a name, find what type it is)

This bidirectionality is fundamental. The same query that answers "what layers exist?" can answer "is X a layer?" and "what is the type of X?" — just by changing which variables are bound and which are free.

### Proof traces are accountability

`transitive-o` in `knowledge.scm` returns proof traces — the chain of hyperarcs traversed to reach a conclusion. This is the knowledge layer's equivalent of `^logger`. Every inference has a trail.

```scheme
(run* (proof) (transitive-o system-kb 'browser 'kernel proof))
;; => (((browser depends-on evaluator)
;;     (evaluator depends-on actors)
;;     (actors depends-on goblins)
;;     (goblins deployed-by guix)
;;     (guix controls kernel)))
```

You can audit WHY the system believes the browser depends on the kernel. The proof is an S-expression. It can be logged, queried, and governed like any other data.

### Object capability security from the lambda calculus

The security model is not bolted on. It emerges from the computational substrate:

- **A Goblins actor reference is a closure.** You can call it (send a message) but you cannot inspect its internals. This is lambda calculus — a function hides its free variables.
- **Attenuation is partial application.** `^facet` exposes a subset of methods. This is equivalent to wrapping a function to restrict its interface.
- **Revocation is a conditional.** A `^cell` flip turns a proxy from forwarding to rejecting. This is `(if revoked? (error) (forward))`.
- **`bcom` is continuation-passing.** The actor becomes a new function. The old function is unreachable (garbage collected). State transitions are function replacements.

The lambda calculus provides unforgeable references (closures), information hiding (lexical scope), and safe composition (function application) — exactly the properties needed for object capability security. Goblins makes these properties explicit and distributed.

## What this enables

### Self-describing system

The system can tell you about itself:

```scheme
play> (query! 'what-depends-on 'evaluator)
;; browser/repl.scm — compiles evaluator to WASM
;; server/server.scm — uses evaluator for org eval
;; tests/test-gplay.scm — test suite

play> (query! 'what-can-change 'push-to-main)
;; bootloader, kernel, users, packages, services, SSH keys
;; (proof: push-to-main → github-actions → guix-deploy → ...)
```

### Self-diagnosing system

The system can detect problems in its own structure:

```scheme
play> (query! 'inconsistencies)
;; WARNING: knowledge.scm imports kanren.scm but kanren.scm
;;          was modified without updating knowledge.scm tests
;; WARNING: deploy/guix/users.scm has user "sapient-os" but
;;          no corresponding home directory activation in machines.scm
```

### Self-extending system

The system can extend its own capabilities:

```scheme
play> (define new-relation
        '(define (authored-by-o kb artifact author)
           (fresh (arc)
             (hyperarc-o kb arc)
             (== (node-ref arc 'type) 'authorship)
             (== (node-ref arc 'artifact) artifact)
             (== (node-ref arc 'author) author))))

play> (propose! 'extend-knowledge new-relation)
;; Logged: user=alice, proposal=extend-knowledge, code=...
;; Governed: requires gov-proxy authority
;; Applied: knowledge module now has authored-by-o
```

### Mesh-distributed reasoning

Because Goblins actors work over OCapN, and OCapN works over Reticulum, the knowledge base can be distributed:

- A sensor node on LoRa holds facts about soil moisture.
- The server holds facts about planting schedules.
- A browser client queries across both: "what fields need watering?"
- miniKanren's interleaving search handles the distributed query.
- The proof trace crosses network boundaries, with each hop authenticated by OCapN.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Browser (Hoot/WASM)                            │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │ system-kb │→│ kanren    │→│ evaluator     │  │
│  │ (hyperarc │  │ (queries) │  │ (evaluate    │  │
│  │  facts)   │  │           │  │  proposals)  │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
│       ↕              ↕              ↕           │
│  ┌──────────────────────────────────────────┐   │
│  │  ^org + ^logger + proxy pairs            │   │
│  │  (governed state, accountability, revoke)│   │
│  └──────────────────────────────────────────┘   │
│       ↕ OCapN (WebSocket / Reticulum)           │
├─────────────────────────────────────────────────┤
│  Server (Guix System)                           │
│                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │ system-kb │→│ kanren    │→│ Guile eval    │  │
│  │ (extended │  │ (full     │  │ (native, no  │  │
│  │  facts)   │  │  power)   │  │  restrictions│  │
│  └──────────┘  └──────────┘  └──────────────┘  │
│       ↕                                         │
│  Guix System (the OS is a Scheme expression)    │
│  Shepherd (services are Scheme expressions)     │
│  Reticulum (mesh transport)                     │
└─────────────────────────────────────────────────┘
```

## First concrete step

Create `module/xorg/system-kb.scm` — a knowledge base representing xorg's own structure as hyperarc facts, queryable via miniKanren in the browser REPL.

This is the seed. Once the system can reason about itself, the loop begins.

## The deeper point

A traditional system has code, documentation, and configuration as separate artifacts maintained by separate processes (developers, writers, operators). They drift apart. The documentation lies. The configuration surprises.

In xorg, if the system's self-knowledge is the same data structure the system operates on, then:

- The knowledge cannot lie — it IS the state, not a description of the state.
- Queries are computations — asking "what depends on X?" runs a program, not a search engine.
- Changes are governed — modifying self-knowledge goes through the same `bcom` + `^logger` + proxy mechanism as any other state change.
- The loop is intrinsic — the system doesn't need an external process to update its self-model. The self-model IS the system.

This is what homoiconicity actually means. Not "code is data" as a party trick. But: the system and its self-description are the same substance, subject to the same laws, governed by the same mechanisms. The gap between the map and the territory closes to zero.

---

## Bidirectional transpilation: markdown ↔ S-expressions

### The insight

miniKanren is bidirectional by nature. A relation that maps S-expressions to markdown can run backwards — given markdown, recover the S-expressions. You don't write a parser and a printer. You write one relation that does both.

```scheme
;; One relation, two directions:
(run* (md)   (markdown-o my-sexp md))       ;; S-expression → markdown
(run* (sexp) (markdown-o sexp "# Title"))   ;; markdown → S-expression
```

This is not a trick. It is the natural consequence of relational programming. Unification does not distinguish "input" from "output" — it finds consistent bindings in any direction.

### What this means for the project

**1. Skills become queryable.**

Right now, skills are markdown consumed by Claude Code but opaque to the system. With bidirectional transpilation:

- Read a markdown skill → `markdown-o` extracts S-expression knowledge facts → load into `system-kb`
- Modify the knowledge base → `markdown-o` generates updated markdown → the skill file is rewritten
- The system can answer: "what does the `/deploy` skill say about SSH keys?" — by querying the extracted facts, not by parsing text

**2. Documentation IS the knowledge base.**

`SELF-IMPROVING-LOOP.md` and `system-kb.scm` would not be separate artifacts. The markdown is a _view_ of the S-expressions. Edit either one; the other updates via the relation.

```scheme
;; These produce the same knowledge base:
(run* (kb)  (skill->kb-o "deploy.md" kb))    ;; extract facts from markdown
(run* (md)  (skill->kb-o md *system-kb*))     ;; generate markdown from facts
```

**3. The self-improving loop extends to prose.**

The system can reason about its own documentation the same way it reasons about its own code — because they are the same substance viewed through different relations.

A miniKanren query over the system KB can find an inconsistency (e.g., "the deploy skill says EFI boot but the knowledge base says BIOS"). The fix is a `bcom` on the knowledge base. The relation regenerates the markdown. The documentation corrects itself.

**4. Human-readable AND machine-queryable.**

Markdown is the human projection. S-expressions are the machine projection. miniKanren unification is the bridge. Neither is "source" — they are two views of the same relational program.

### The `markdown-o` relation

`markdown-o` maps between a markdown AST (as tagged S-expressions) and markdown strings:

| Markdown | S-expression |
|----------|-------------|
| `# Title` | `(heading 1 "Title")` |
| `## Section` | `(heading 2 "Section")` |
| `- item` | `(bullet "item")` |
| `- **bold** text` | `(bullet (bold "bold") " text")` |
| `` `code` `` | `(code "code")` |
| Code block | `(code-block "scheme" "(+ 1 2)")` |
| `\| a \| b \|` | `(table ((a b) ...))` |
| Paragraph | `(paragraph "text")` |
| `[text](url)` | `(link "text" "url")` |

A markdown document is a list of these elements:

```scheme
(define my-doc
  (list (heading 1 "Deploy")
        (paragraph "Push to main triggers guix deploy.")
        (heading 2 "Key files")
        (table '(("File" "Purpose")
                 ("machines.scm" "OS declaration")
                 ("deploy.sh" "Wrapper script")))))

;; Render to markdown string:
(run* (md) (markdown-o my-doc md))

;; Parse markdown string back to S-expressions:
(run* (doc) (markdown-o doc markdown-string))
```

### `skill-kb-o`: skills as knowledge

Building on `markdown-o`, `skill-kb-o` maps between a skill's markdown structure and hyperarc facts:

```scheme
(define (skill-kb-o skill-name md-doc kb-facts)
  "Bidirectional relation between a skill's markdown and knowledge base facts."
  (fresh (sections)
    (markdown-o md-doc sections)
    ;; Heading "Key files" + table → file-of hyperarcs
    ;; Heading "Dependencies" + bullets → depends-on hyperarcs
    ;; Heading "Provides" + bullets → provides hyperarcs
    ;; The structure of the markdown IS the structure of the knowledge
    (sections->facts-o skill-name sections kb-facts)))
```

### The unified architecture

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│   Markdown skills ←──── markdown-o ────→ S-expression AST│
│         ↕                                       ↕        │
│   Human reads/writes              skill-kb-o extracts    │
│                                           ↕              │
│                                    system-kb (hyperarcs) │
│                                           ↕              │
│                              miniKanren queries          │
│                              (depends-on-o, etc.)        │
│                                           ↕              │
│                              Self-improving loop         │
│                              (observe → reason →         │
│                               propose → govern → apply)  │
│                                                          │
└──────────────────────────────────────────────────────────┘

Edit the markdown → facts update → queries reflect the change.
Edit the facts → markdown regenerates → documentation updates.
All in one vat turn. All governed.
```

### Why this works in the browser

`kanren.scm` is already Hoot/WASM compatible. `markdown-o` would be pure miniKanren — no IO, no mutation, just unification over strings and tagged lists. It compiles to WASM and runs in the browser REPL.

A user edits markdown in the REPL. The relation extracts facts. The knowledge base updates. miniKanren queries reflect the change. All in one vat turn. All governed by Goblins actors — logged, revocable, attributed.

The browser becomes a self-reflective environment where documentation, code, and knowledge are three projections of the same relational program.
