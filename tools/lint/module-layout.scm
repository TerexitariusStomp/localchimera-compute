;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module-layout.scm — where each directory of module/localchimera/ stands, as data.
;;;
;;; Read by tools/lint/module-map.scm; the reasoning is docs/planning/
;;; codebase-layout.md (§2 the ranks, §3–§4 every file), on the principle of
;;; codebase-organization.md §4: a directory is a layer of the ValueFlows model
;;; or a domain built on those layers, and a file imports from its own directory
;;; and from ranks below it. The three rank-4 directories stand beside each
;;; other: none imports another.
;;;
;;; The table names the tree as it stands; every file of codebase-layout.md §9
;;; has reached its directory, and a `file` form names only what is not a
;;; library module.
;;;
;;;   (stays NAME RANK WHAT)   a directory of module/localchimera/ and its rank. RANK
;;;       #f leaves it out of the layer rule. A nested name ("keri/first-person")
;;;       stands at its own rank; otherwise a file's rank is its first
;;;       directory's.
;;;   (from OLD NEW)   every file under module/localchimera/OLD/ today belongs under
;;;       NEW, at the same relative path; NEW "" drops the prefix. The longest
;;;       OLD that holds the file wins.
;;;   (file PATH NEW)   the one file module/localchimera/PATH.scm belongs in NEW.
;;;       NEW #f: the file goes (a shim, an alias, a tool), and is not linted.
;;;   (tier PATH RANK WHAT)   the file stands in its directory at a rank of its
;;;       own: a family's vocabulary, which lower layers state, beside the
;;;       machinery that reads higher ones.
;;;
;;; A file in a directory no form names is reported by `make lint-layers`. A
;;; `file` form wins over a `from` form.

(layout

 ;; ── rank 0: the substrate ──
 (stays "utils" 0 "the one clock, records, store utilities, units, hex, JSON, catch, paths, the operator, the endorsement sealers")
 (stays "keri" 0 "KERI and ACDC: CESR, SAID, inception, key state, Signify, the KERIA bridge, the credential store, and the First Person profile")
 (stays "keri/first-person" 0 "the First Person profile: PHC/VRC credentials, the predicates, the personhood policy, sybil detection")
 (stays "crypto" 0 "Shamir and recovery shares")
 (stays "mqtt" 0 "MQTT publish and subscribe")
 (stays "lang" 0 "miniKanren, Wisp, markdown, the evaluator, the knowledge base, provenance")
 (stays "tools" 0 "the s-expression zipper, structural edit and index, as a library")

 ;; ── rank 1: the vocabulary ──
 (stays "vf" 1 "the ValueFlows vocabulary and what localchimera states in it: the records of all_vf.TTL, the action table and the serdes that stores them (vf/), facts (vf/facts/), formulas (vf/formulas/), the records beside the core (vf/beyond/), the two trees (vf/aggregation/)")
 (stays "credentials" 1 "the localchimera credential schemas by family: registry, delegation, membership, keys, voting, work, recomposition, commitments, custody, declarations, audit")
 (stays "wire" 1 "rows, replies, the snapshot")
 (stays "social" 1 "lenses and relationship kinds")
 (stays "protocol" 1 "the seam, shapes, dispatch, MCP")

 ;; ── rank 2 ──
 (stays "identity" 2 "a person's standing: seat, devices, the published key log, cards, contact points, reach, forget, the key log in hand, the personhood audit")
 (stays "keys" 2 "what a scope holds in KERI: its key event log store, the KERIA store, the bran and its custodians, witnesses and their publishers, IPEX exchange, the peers")
 (stays "algorithms" 2 "pure arithmetic over records, read by the books, the solve and the doors: SNLT rollup, signals, propagation, option premium, tracking, the credit arithmetic, deferred acceptance, pulls")
 (stays "legal" 2 "the vocabulary of law (rules, crossings, reform), its registry and its gate, the roles in a body")

 ;; ── rank 3 ──
 (stays "knowledge" 3 "what is known: the authoring language, catalogues, recipes, worlds, law data")

 ;; ── rank 4: beside each other ──
 (stays "solve" 4 "the function from knowledge and observation to a plan: compiler, engine, solver, the native kernel, and what the solve is given beyond the recipes")
 (stays "plan" 4 "what will be: the plan store, what its commitments are, how the offer becomes a rota, recurrence and the schedule book")
 (stays "observation" 4 "what was: the observer, the event log, accounts, and the bridge from events to credentials")

 ;; ── rank 5 ──
 (stays "scope" 5 "one scope: the stores (agents, processes, places), the live loop from books to solve to commitments, the ballot store and the demand registry, the scope's own policy, and the scope actor as fragments (keys, capabilities, membership, custody, recovery)")
 (stays "personhood" 5 "how a person is recognised: enrollment, the vouching ceremony, the witness relay, work witnessed by peers, the body ceremony and its desk, the scope's issuance fragment")
 (stays "matching" 5 "asks to offers")
 (stays "folksonomy" 5 "classification")
 (stays "indexes" 5 "the membership index")
 (stays "execution" 5 "execution alerts, the scope's reactive execution, and capacity-managed execution")
 (stays "ddmrp" 5 "the buffer planner (DDMRP), a family beside the ValueFlows core: its records, buffer algorithms, the three buffer stores and the execution monitors")
 (tier "ddmrp/records" 1 "the family's vocabulary: nine record types a recipe or a specification may state")
 (tier "solve/world" 3 "the world the solve is given, one context held as a value: the lattice, its tables and its calendar; the plan lands its accepted commitments on the same lattice")
 (tier "solve/periods" 3 "what a period of the world is in wall-clock time, over the world's calendar: read by the solve and by the plan that pins into it")
 (tier "doors/protocol" 1 "the door declarations: what a caller reaches, as data every rank reads, from the dispatch check an actor runs at spawn to the lints and the emitters")
 (tier "knowledge/dsl/findings" 1 "what a lint says, in one shape: spoken by the law lint, the ValueFlows lint and a body's standing, read by a report, a gate, a door")
 (tier "ai/conform" 1 "the conform loop over any completion: a reply read, checked and asked again with its faults; the model is passed in")

 ;; ── rank 6 ──
 (stays "pools" 6 "what rises through the scope tree: the folds of readings, voice, credit, labour, desire, and the labour pool the labour fold stands on")
 (stays "federation" 6 "several scopes together: crossings, peers, the tree's labour matching, the transport between scopes; and the structure of scopes: communes, recomposition, the scope graph, lineage, invariants, the Universal Commune, the pollers, bootstrap, the auditors, the rebuild from credentials; IPEX policy over the graph and the KERIA notification stream")
 (stays "economy" 6 "the economy's reading of the solve: socialization, means, demand, debts, recipe standing, guardianship")
 (stays "voice" 6 "ballots, expressions, delegation, the voice signer, the voice snapshot, affected interest, the index oracle")

 ;; ── rank 7: what a caller reaches, and the channels ──
 (stays "machine" 7 "the machine-resource port: specs, registry, bindings, executors, hrea events, receipts, replay, settlement, payouts")
 (stays "doors" 7 "what a caller reaches: the lobby and the session, the planner's reads, the identity doors, the governance doors as fragments, the door declarations, HTTP and MCP")
 (stays "gateway" 7 "the gateway's services: presence, mailboxes, terminal, the LLM service, the HTTP listener, evidence, allotment, the corpus service")
 (stays "interface" 7 "the chat channels: Matrix, Telegram, email, the browser, the router")
 (stays "notify" 7 "notifications: recipients, the registry, rendering, the router")
 (stays "push" 7 "web push: the adapter, VAPID, subscriptions, templates")
 (stays "bridge" 7 "MQTT: the signal publisher, the codec")
 (stays "ai" 7 "the LLM bridge, the key pool, conform, embeddings, TEE attestation")
 (stays "monero" 7 "the wallet, payouts, top-ups, the poller, the policy")
 (stays "fleet" 7 "the fleet: providers, the keeper, the reconciler, the CDN")
 (stays "org" 7 "the organisation's actors, the Play Store listing")
 (stays "dev" 7 "the development scope: its recipes, ledger, plan and Radicle issues")

 ;; ── rank 8: the composition root ──
 (stays "boot" 8 "the composition root: one module per vat the gateway starts, and the operator REPL's prelude")

 ;; ── unranked ──
 (stays "test" #f "the harness library")

 ;; ── not library modules ──
 (file "delegates" "doors")                     ; the adapter seams the doors open
 (file "utils/repl-client" #f)            ; a tool: tools/ of the repository
 (file "utils/ts-emit" #f)                ; a tool: tools/ of the repository
 )
