    Complexity Analysis — Relational ValueFlows Planner

    Variables

    Symbol   Meaning                              Typical
    N        Total lifted planning facts           50–500
    D        Open demands per scope                1–20
    R        Recipes per spec                      1–5
    P        Processes per recipe chain             1–8
    I        Inventory resources per spec           1–5
    Q        Maximum quantity in a demand           1–10,000
    K        Depth bound (recursion limit)          5–10
    B        Branching factor (inputs per recipe)   1–3
    V        FD-constrained variables in state      1–50
    Dv       Max domain size of FD variable         1–10,000
    S        Substitution size                      1–100
    C        Children per federation scope          1–10
    H        Federation hierarchy depth             1–4
    M        Max federation steps per level         50
    Sp       Total specs in system                  5–100


    miniKanren core

    walk            O(S)           chain traversal through substitution
    unify           O(T·S)         T = term size, with occurs check
    mplus step      O(1)           swap on suspension — the interleaving
    bind step       O(1)           apply goal to stream head
    take n          O(n)           forces n stream steps
    run-plan n      bounded        n × search cost per answer
    run-plan*       unbounded      enumerates ALL valid plans


    CLP(FD) constraint engine

    ==              O(S + V)       unify + fd-narrow + fail-check + fire propagators
    rangeo          O(1)           create domain [lo..hi]
    +fd ground      O(1)           direct arithmetic
    +fd domains     O(Dv³)         enumerate valid triples — avoided by deferred labeling
    +fd deferred    O(1)           registers propagator, fires later when variable grounds
    *fd             same as +fd    triple enumeration or deferral
    <fd / <=fd      O(Dv)          single filter pass over domain
    labelfd         O(Dv) branches max-first: first branch is greedy answer
    propagator fire O(1) each      removed after firing — no cascades
    =/=             O(S)           prefix-S computation
    absento         O(T)           recursive term traversal
    numbero/symbolo O(1)           type tag check


    Allocation

    allocate-o (run-plan 1)      O(I)       max-first labeling takes maximum per resource
    allocate-o (run-plan*)       O(Q^I)     explores all valid allocation splits
    conservation-floor lookup    O(N)       scan for buffer-zone fact
    running-sum update           O(I)       alist set per resource per demand

    The allocation is the primary search bottleneck. DDMRP decoupling bounds I per scope
    (typically 1–5 resources per spec). Max-first labeling makes run-plan 1 essentially
    greedy — the CLP(FD) machinery is there for correctness (cross-demand exclusion via
    shared running sums), not for enumeration.


    Demand relation

    demand-o                     O(R · I · K)     typical for run-plan 1
    demand-o                     O(R · B^K · I · Q)  worst case for run-plan*
    after-allocation             O(1)             conde: satisfied / produce / unmet
    produce-branch               O(N + demand-o)  recipe lookup + *fd scale + recurse
    lasto                        O(P)             linear in chain length
    back-schedule-inputs         O(P · N)         ground fold over process chain
    solve-inputs-o               O(B · demand-o)  linear in consuming inputs

    The depth bound K (default 10) prevents infinite recursion. Cycle detection via visited
    list prevents revisiting specs. The branching factor B (consuming inputs per recipe)
    determines the tree shape — B=1 is linear, B=3 at depth 10 is 59,049 nodes worst case.
    In practice, SNE-sorted recipes and max-first allocation prune most branches immediately.


    Plan orchestration

    plan-o                       O(D · demand-o)  sequential conjunction
    prioritize-demands           O(D·log D)       sort by class + due date
    lift-planning-facts          O(Sp · P)        once at session start
    build-sne-index              O(Sp · R · P)    recursive with cycle guard

    The demand ordering is a heuristic — it biases run-plan 1 toward the socially preferred
    plan. run-plan* finds all plans regardless of order. The SNE index computation runs once
    during lifting and determines recipe exploration order for the entire session.


    Federation

    scope-stream (leaf)          = plan-o cost     lazy — computed on pull
    scope-stream (parent)        O(M · C · leaf)   M steps × C children
    search-stream per step       O(C · D²)         evaluate + match + advance
    match-at-level               O(defs · surps)   greedy scan
    advance-worst                O(D + stream-step) sort deficits + one pull
    recursive (H levels)         O(H · M · C · leaf) each level bounded

    The federation is lazy: pulling one answer from the root forces one pull from each child,
    cascading down H levels. Total work per root pull = O(H · C) stream steps. The M=50 bound
    at each level caps the residual reduction search. Well-decoupled hierarchies (DDMRP
    buffers at every scope boundary) converge in 3–5 steps.


    DDMRP relations

    zone-o (ground)              O(1)       4-branch conde, instant
    zone-o (domain)              O(Dv)      CLP(FD) inequality per branch
    nfp-o (ground)               O(1)       two arithmetic ops
    nfp-o (domain)               O(Dv²)     +fd and -fd with domains
    variability-factor-o         O(9)       9-element table — always constant
    location-descendant-or-equal-o  UNBOUNDED  no depth limit — relies on acyclic facts


    Trace relations

    produces-o                   O(N)       three in-list-o queries
    provenance-o                 O(K · N)   depth-bounded transitive closure
    destination-o                O(K · N)   depth-bounded transitive closure
    custody-level-o              O(levels)  linear scan


    What makes it tractable

    1. DDMRP decoupling bounds scope size. Each scope has O(10) resources, O(5) recipes,
       O(10) demands. The combinatorial explosion of B^K is bounded by the scope boundary.

    2. Max-first labeling makes run-plan 1 greedy. The CLP(FD) domain [0..Q] is explored
       largest-first, so the first branch found is the maximum-allocation plan. No enumeration
       needed for the common case.

    3. SNE sorting biases recipe exploration. Cheapest recipe is tried first. Interleaving
       eventually explores all recipes, but run-plan 1 finds the cheapest.

    4. Conservation floors are hard constraints, not search. The buffer protection is a domain
       bound (available = inventory - TOR), not a search branch. No extra search cost.

    5. Propagators fire at most once. No cascade. No re-firing loops. Each propagator is
       removed from the queue after firing.

    6. Federation streaming is lazy. No scope loads another scope's data. Each stream pull
       forces one miniKanren suspension — the minimum possible work.

    7. Depth bounds on recursion (K=10), federation steps (M=50), and trace depth (K=10)
       prevent all unbounded searches except location-descendant-or-equal-o (fix needed).


    Known issues

    1. location-descendant-or-equal-o has no depth bound. Cyclic location-parent facts would
       cause infinite recursion. Fix: add depth parameter (default 10), same pattern as
       provenance-o.

    2. +fd/*fd triple enumeration is O(Dv³). For large domains (Q=10,000), this is 10¹²
       operations. Mitigated by deferred labeling (propagator defers until variable is ground,
       then direct computation O(1)). But if three domain variables interact simultaneously
       without grounding, the triple enumeration triggers.

    3. run-plan* on allocation is O(Q^I). Complete enumeration of all valid allocation splits
       is exponential. This is inherent to the problem — there ARE Q^I valid allocations.
       Mitigated by DDMRP decoupling (I is small per scope).

    4. SNE index is O(Sp² · R · P) worst case for deeply nested recipe dependencies.
       Mitigated by cycle guard (each spec visited at most once per computation).
