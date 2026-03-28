# Atomicity Boundary: Vat-Local Compilation vs. Distributed Linking

    ## The Core Tension

    Goblins' transactionality is **per-vat**. The fold/unfold/monoid patterns assume you can compose operations atomically. This creates a fundamental boundary in the system's architecture:

    ## Within One Vat (One Scope) — Atomic Compilation

    A single turn can:
    - **Fold** events (Observer: `event × state → state`)
    - **Unfold** demands (Dependent Demand: `seed → tree of processes`)
    - **Merge** results (PlanStore monoidal composition)

    All atomically. If any step fails, the entire turn rolls back. The compiler pipeline metaphor holds perfectly:

    Demands (source)
      → Classify (lexing)
      → Explode via recipes (parsing/elaboration)
      → Net against inventory (type-checking/constraint solving)
      → Schedule processes (code generation)
      → Emit signals (output)

    The netter is the symbol table. Backtracking is the constraint solver's search. The plan is the compiled program.

    ## Across Vats (Federation) — Eventual Consistency

    Across vats, you lose atomicity and gain eventual consistency via promises (`<-`). The compiler pipeline becomes a **distributed build system**:

    - Each scope **compiles independently** (its own vat, its own turn, its own atomic guarantees)
    - `foldScopes` chains these compilations bottom-up via promises
    - **Lateral matching is the linker** — it resolves cross-scope surplus↔deficit references after all scopes have compiled
    - The `StoreRegistry` is the **symbol table for the linker** — qualified references (`scopeId::recordId`) are the link-time addresses

    ## Implications

    | Property | Intra-Vat (Scope) | Inter-Vat (Federation) |
    |----------|-------------------|----------------------|
    | **Consistency** | Strong (transactional) | Eventual (promise-based) |
    | **Composition** | Synchronous `$` | Asynchronous `<-` |
    | **Failure mode** | Atomic rollback | Partial progress + retry |
    | **Identity element** | Empty PlanStore | Empty actor |
    | **Fold direction** | Sequential within turn | Bottom-up via promise chain |
    | **Metaphor** | Compiler | Distributed build system |

    ## Design Consequence

    The planning algorithm is structured so that **all constraint-sensitive operations happen within a single vat** (netting, backtracking, buffer guards, conflict resolution), while **federation-level operations are
    tolerance-safe** (lateral matching is greedy and idempotent, sacrifice analysis is advisory, conservation signals are append-only).

    This is not a limitation — it's the correct architecture. Economic planning within an organization *should* be atomic (you can't half-commit to a production schedule). Coordination between organizations *should* be
    eventually consistent (you negotiate, you don't dictate).

    The main agent can write this to disk when it's ready.
