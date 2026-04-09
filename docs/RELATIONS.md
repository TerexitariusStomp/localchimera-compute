    Playnet as Social-Material Relational Planning

    The idea

    A commune needs bread. To get bread you need flour. To get flour you need wheat. The commune has 200kg of wheat at
    the farm, 50kg of flour at the mill, and a bakery with nothing in it.

    A traditional planner processes these demands one at a time: first check inventory, then pick a recipe, then
    schedule production, then repeat for the next demand. If it makes a bad choice early (say, using all the flour for
    one order when two orders need it), it has to do complicated backtracking to fix it.

    The relational planner asks a single question: "Is there ANY way to satisfy all these demands simultaneously?" It
    explores every possibility — every recipe, every allocation ordering — and finds all valid answers. Bad choices
    don't need special backtracking logic. They're just branches that don't lead anywhere, so they're quietly dropped.

    How it works (without jargon)

    The planner represents everything as plain lists — facts about the world:

        (recipe "recipe-bread" "Bread Production" "spec-bread")
        (chain  "recipe-bread" ("rp-mill" "rp-bake"))
        (flow   "rp-mill" input  "spec-wheat" 10 "kg" consume)
        (flow   "rp-mill" output "spec-flour"  8 "kg" produce)
        (flow   "rp-bake" input  "spec-flour"  8 "kg" consume)
        (flow   "rp-bake" output "spec-bread" 20 "each" produce)

    These are just data. No classes, no objects, no database tables. Plain lists that say what is true.

    A query is a list with blanks in it. If you ask:

        (recipe ___ ___ "spec-bread")

    the system fills in the blanks: ___ = "recipe-bread", ___ = "Bread Production". It finds every fact that matches
    the shape of your question. This operation — matching a pattern with blanks against a collection of facts — is
    called unification. It's the only operation the system needs.

    The same mechanism works in every direction:

    - "What recipe produces bread?" → fill in the blanks for recipe-id and name
    - "What does recipe-bread produce?" → fill in the blank for the output spec
    - "Is there a recipe that produces bread and is called Bread Production?" → yes or no

    One pattern, three questions. The system doesn't have separate functions for each direction. It has one relation
    that works whichever way you ask it.

    What "relational" means for planning

    The demand relation (demand-o) asks: "given this demand, what plan satisfies it?" A plan is a list describing what
    to do:

        (satisfied "spec-flour" 30 ...)       — fully covered by inventory
        (produce "spec-bread" "recipe-bread" 1 ...)  — make it using this recipe
        (purchase "spec-wheat" 50)            — buy it from outside

    When multiple recipes exist for the same thing, the system explores all of them as parallel possibilities. When
    inventory can be allocated in different ways, it tries each way. Every combination that works is a valid plan.

        (run-plan 1 ...)   → give me the first valid plan
        (run-plan 5 ...)   → give me up to five valid plans
        (run-plan* ...)    → give me ALL valid plans

    This is what makes it strictly better than the greedy planner for competing demands. If allocating flour to order A
    prevents order B from being satisfied, the greedy planner commits to A and emits a purchase signal for B. The
    relational planner finds the allocation that satisfies both — or proves that no such allocation exists.

    The allocation layer

    Inventory tracking (how much flour is left, what's already claimed) is imperative — it must read from real actor
    state and mutate allocation counts. This is the one part that isn't purely relational.

    The key property that makes it work: the allocation state is immutable. When the search branches to explore a
    different recipe, each branch gets its own copy of the allocation state automatically. A branch that claims 50kg
    of flour and then fails doesn't affect other branches — its claims simply vanish with it. No undo logic needed.
    The system's branching IS the backtracking.

    The bridge between the relational world (pattern matching over facts) and the allocation world (reading inventory
    counts, computing scale factors) uses a mechanism called projection: walk a placeholder to whatever concrete value
    it matched, then do arithmetic on it. This only appears at two points — computing how much to scale a recipe, and
    computing the schedule. Everything else is pure pattern matching.

    How social governance enters

    The facts don't exist in a vacuum. They live inside capability-secured actors:

    - You can only query a recipe store if someone granted you access to it
    - Within one planning scope, a plan is all-or-nothing (atomic)
    - Every action is logged: who proposed it, when, with what authority
    - Access can be attenuated (read-only view of the plan) or revoked
    - Capabilities are unforgeable references — you can't guess your way in

    The planner searches for plans that satisfy material demands given the social topology of who can access what, who
    has authority over which resources, and what capabilities have been granted. It doesn't bypass governance — it
    operates within it.

    Federation between scopes

    Different communes or cooperatives each run their own planner independently. They don't share a global plan. When
    one scope has surplus flour and another has a deficit, they exchange signals — not commands. Each scope decides
    independently how to respond.

    The buffer stocks at scope boundaries (DDMRP decoupling points) serve double duty: they make greedy local decisions
    nearly optimal (an engineering property), and they define sovereignty boundaries (a political property). The
    relational planner respects these: it stops at decoupling points, emits signals, and lets the neighboring scope
    plan its own response.

    The system's self-knowledge

    The system can reason about its own structure using the same fact-matching it uses for recipes. Facts like "the
    planner depends on the netter" and "the browser depends on the evaluator" are plain lists in the same format.
    The same query that answers "what raw materials does bread need?" also answers "what modules does the planner
    depend on?"

    When the commune decides to change a governance rule, the change is:
    1. Proposed as a plain list (an S-expression)
    2. Checked against existing rules by the same pattern matcher
    3. Authorized through the capability system
    4. Applied atomically (the actor becomes its new version)
    5. Visible to the knowledge base, which updates its facts

    The planning engine, the governance system, and the knowledge base are all subject to this loop. They all speak the
    same language: plain lists, matched by the same pattern-matching core.

    Why this is a communal computer

    A traditional ERP serves the firm. Its algorithms are opaque. Its data is siloed.

    Playnet serves the commune. The planning algorithms are relations — transparent, queryable from any direction. Any
    member can ask "why was this plan chosen?" and get the chain of facts that led to it. The allocation state is
    immutable and auditable. Federation between cooperatives is voluntary signal exchange, not central command.

    The architecture in six lines

        (recipe-o    facts rid name output)          ;; what can we make?
        (flow-o      facts pid dir spec qty unit act) ;; what goes in and out?
        (net-demand-o ctx spec qty remaining alloc)  ;; what's available?
        (demand-o    ctx spec qty due plan-term)     ;; what's the plan?
        (plan-o      ctx plan)                       ;; solve all demands
        (run-plan    n ns (plan) (plan-o ctx plan))  ;; find n valid plans

    Six relations. Facts as plain lists. Pattern matching as the only operation. Social agreements and material flows
    unified by the same mechanism. Every inference traceable. Every allocation reversible until committed.
