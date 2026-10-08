;;; module-layout.scm — where each planner directory stands, as data.
;;;
;;; Read by tools/module-map.scm; the reasoning is docs/planning/
;;; codebase-organization.md §4. A directory is a layer of the ValueFlows model
;;; or a domain built on those layers, and a file imports from its own directory
;;; and from ranks below it. The three rank-3 directories stand beside each
;;; other: none imports another.
;;;
;;;   (stays NAME RANK WHAT)   a directory of module/playnet/planner/ and its
;;;       rank. RANK #f leaves it out of the layer rule.
;;;   (directory NAME RANK WHAT FILE …)   FILE is a path under
;;;       module/playnet/planner/ without ".scm"; it belongs in NAME. For a
;;;       file whose directory does not say what it is.
;;;
;;;   (tier FILE RANK WHAT)   FILE stands in its directory at a rank of its own.
;;;       For a family with two tiers: a vocabulary that lower layers state, and
;;;       the machinery that reads higher ones.
;;;
;;; A planner file in a directory no form names is reported by `make lint-layers`.

(layout

 (stays "vf" 0 "the ValueFlows vocabulary and its persistence: the records of all_vf.TTL, the action table, and the serdes that stores them")
 (stays "facts" 0 "what a person, a place or a means states, and how a part of the economy is named and selected: tags, time, places, labels, boundaries, a credential's validity, keys and selectors")
 (stays "formulas" 0 "pure arithmetic and dynamics read on both sides: cadence, capacity, periods, cascades, shocks, fragility, skill and stock dynamics, tension terms")
 (stays "beyond" 0 "what playnet says that the vocabulary does not, as records: recurring schedules, the planning scenario, the lot. A thing leaves for vf/ when its route into the core holds")
 (stays "aggregation" 0 "the two trees everything is folded over: scope and containment")
 (stays "algorithms" 1 "pure arithmetic over records, read by the books, the solve and the doors: SNLT rollup, signals, propagation, option premium, tracking, the credit arithmetic, deferred acceptance, pulls")
 (stays "legal" 1 "the vocabulary of law (rules, crossings, reform), its registry and its gate")
 (stays "knowledge" 2 "what is known: the authoring language, catalogues, recipes, worlds, law data")
 (stays "solve" 3 "the function from knowledge and observation to a plan: compiler, engine, solver, the native kernel, and what the solve is given beyond the recipes (response curves, externality, inspection)")
 (stays "plan" 3 "what will be: the plan store, what its commitments are, how the offer becomes a rota, recurrence and the schedule book")
 (stays "observation" 3 "what was: the observer, the event log, accounts")
 (stays "scope" 4 "one scope: the actor that holds the stores (agents, processes, places), and the live loop from books to solve to commitments")
 (stays "matching" 4 "asks to offers")
 (stays "folksonomy" 4 "classification")
 (stays "indexes" 4 "the membership index and the VF query facade")
 (stays "execution" 4 "execution alerts, the scope's reactive execution, and capacity-managed execution")
 (stays "ddmrp" 4 "the buffer planner (DDMRP), a family beside the ValueFlows core: its records, buffer algorithms, the three buffer stores and the execution monitors")
 (tier "ddmrp/records" 0 "the family's vocabulary: nine record types a recipe or a specification may state")
 (stays "pools" 5 "what rises through the scope tree: the folds of readings, voice, credit, labour, desire, and the labour pool the labour fold stands on")
 (stays "federation" 5 "several scopes solving together: crossings, peers, the tree's labour matching (rising plans up, the deployment back down), the registry of scopes and the transport between them")
 (stays "doors" 6 "what a caller reaches: the service facade and every read shaped for a face")
 (stays "comms" 6 "communications derived from the plan, built and awaiting integration")
 (stays "bridge" 6 "MQTT: the signal publisher, the topic observer, the codec")
 (stays "dev" 6 "the development scope: its recipes, ledger, plan and Radicle issues")

 (stays "bench" #f "benchmarks"))
