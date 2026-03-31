# The SVO Grammar

A directed graph where nodes are entities and edges are verbs.
Every meaningful human action is an edge:

```
S ──[V]──▶ O
```

Subject acts. Object results. The verb is the living relation between them.

Alienation is what happens when that link is severed. There are exactly
four ways to sever it. Each is a structural pattern in the graph, and
each is computable.

## The Graph

Two kinds of facts. Everything else is derived.

```scheme
(node NID NAME KIND)              ;; an entity: subject, object, commodity, projected
(edge EID FROM-NID VERB TO-NID)   ;; a proposition: someone does something to something
```

Nodes are things that exist. Edges are things that happen. A subject is a
node that appears in the FROM position. An object is a node that appears
in the TO position. The same node can be both — and when a subject is
forced into the TO position of a governance edge, that is species-being
alienation.

## Syntactic Operations

Three operations transform edges. None is inherently alienating. They
become alienating only in combination with governance.

### Externalization (the condition of creation)

```
S ──[creates]──▶ O
```

The subject acts and produces an object. This is baseline. The object is
recognized as an expression of the subject's capacity. No alienation here.

### Nominalization (verb becomes noun-node)

```scheme
(nominalization NID EID VERB NOUN-NID)
```

A living verb is turned into a static noun-node in the graph. "To work"
becomes "labor-power." "To conceive" becomes "virtue." The edge is still
there, but now a new node exists — a reified token of the action — that
can be measured, managed, bought, sold. Nominalization is neutral on its
own. It becomes alienating when the noun-node is governed by another.

### Passivization (subject obscured)

```scheme
(passivization PID EID ALIENATING?)
```

The subject is hidden. "The worker creates value" becomes "Value is created."
The edge still exists in the graph, but the FROM position is demoted.
Passivization can be alienating (obscures a power relation) or non-alienating
(describes a genuine collective). The boolean marks which.

### Reification

An edge is reified when it has been nominalized or alienatingly passivized.
This is detected, not declared:

```scheme
(reified-o facts eid)  ;; true when nominalization or passivization holds for eid
```

## Governance

```scheme
(governance GID CREATION-EID GOV-EID)
```

The structural operation that produces alienation. Links two edges: a
creation edge and a governance edge. The creation edge is the subject's
productive act. The governance edge is another subject's act of control
over what was produced.

Governance alone gives `from-product`. Combined with reification, it gives
`from-activity`. When the governance edge targets the subject itself, it
gives `from-species-being`. When it is reciprocal, it gives `from-others`.

## The Four-Fold Alienation

One relation. Four dimensions. Each severs a different link in the triad.

```scheme
(alienation-o facts dim s e gov-eid)
```

### from-product (S─O)

Another subject's edge converges on the same object node as yours.
You create it; they govern it.

```
S1 ──[creates]──▶ product
                      ▲
S2 ──[owns]───────────┘       (governance links the two edges)
```

This is the base case. All other dimensions build on or parallel it.

### from-activity (S─V)

Your production edge is reified — the verb has been nominalized into a
noun-node, or passivized away. Entails `from-product`: if your verb is
alien, your product is already alien.

```
S1 ──[works]──▶ product       (edge is reified: "works" → "labor-power")
                    ▲
S2 ──[owns]─────────┘
```

### from-species-being (S─S)

The governance edge targets you. You appear in the TO position — you are
treated as a thing in the graph. Not just your product, not just your verb,
but you yourself are what is governed.

```
S1 ──[labors]──▶ product
        ▲
S2 ──[owns]──── S1             (S1 is the object of the governance edge)
```

### from-others (S─S1)

Reciprocal `from-product`. You govern another subject's product, and they
govern yours. Subjects relate through governed objects instead of directly.

```
S1 ──[creates]──▶ O1      S2 ──[creates]──▶ O2
                    ▲                           ▲
S2 ──[buys]─────────┘      S1 ──[buys]──────────┘
```

This is the structure underlying commodity exchange. Each subject is
simultaneously alienated from their own product and governing the other's.

### Recursive structure

`from-activity` calls `from-product` internally — it entails the base case.
`from-others` calls `from-product` for both sides — mutual entailment.
`from-species-being` is structurally independent: it checks whether S
appears as the target of a governance edge. They are four dimensions of
one pattern, not four independent checks.

### Historical fingerprints

Each mode of production lights up a distinct combination:

| Mode               | from-product | from-activity | from-species-being | from-others |
|--------------------|:---:|:---:|:---:|:---:|
| Slavery            | x   |     | x   |     |
| Wage labor         | x   | x   |     |     |
| Theology           | x   | x   | x   |     |
| Commodity exchange | x   | x   |     | x   |
| Free association   |     |     |     |     |

This table is not declared. It is *computed* by running:

```scheme
(run* (dim) (fresh (e g) (alienation-o *slavery-facts* dim 'slave e g)))
;; => (from-product from-species-being)
```

## Exchange and Fetishism

When `from-others` holds for both subjects and an exchange edge links
their objects, the graph exhibits commodity fetishism: objects appear to
relate to each other, hiding the subjects' productive relations.

```scheme
(exchange XID PROD-EID1 PROD-EID2 XFER-EID)
```

```
tailor ──[sews]──▶ coat ──[exchanges-for]──▶ linen ◀──[weaves]── weaver
                     ▲                                     ▲
weaver ──[buys]──────┘                                     │
tailor ──[buys]────────────────────────────────────────────┘
```

The fetish edge (`coat ──[exchanges-for]──▶ linen`) is where value appears
as a property of things rather than a social relation between producers.
Two concrete verbs (`sews`, `weaves`) are nominalized into one abstract
noun-node (`labor`), making qualitatively different activities appear
commensurable.

```scheme
(fetishism-o facts xid s1 s2 o1 o2)
;; => (coat appears-to-exchange-with linen hiding (tailor weaver))
```

## Free Association

The negation of governance. Subjects relate through recognition and
offering, not ownership and control. The SVO link stays intact.

```scheme
(free-link FID EID1 EID2)
```

```
S1 ──[creates]──▶ artifact
                      ▲
S2 ──[recognizes]─────┘       (free-link, not governance)
```

No edge is reified. No subject appears as an object. No governance tuple
exists. The relation `alienation-o` returns `()`.

### Inversion

Every alienated structure has a free-association inversion. The inversion
is a relation between an alienated edge and its free form:

```scheme
(inversion IID ALIENATED-EID FREE-EID KIND)
;; KIND: projection-to-reclamation | noun-to-verb | governance-to-recognition
```

The theology example: God commands humanity (alienated). The inversion:
the community recognizes that these virtues were always its own, and
practices them directly. Virtue transforms from a noun (a static thing
possessed by an external authority) to a verb (a living action practiced
by a community).

## Implementation

All of this is in `module/playnet/svo.scm`, using `(playnet kanren)` for
miniKanren and `(playnet knowledge)` for `in-list-o`. The same search
engine that plans material flows (recipes, demands, allocation) reasons
about the social relations those flows are embedded in.

### Fact shapes (complete)

```scheme
(node NID NAME KIND)                          ;; entity
(edge EID FROM-NID VERB TO-NID)               ;; proposition
(nominalization NID EID VERB NOUN-NID)         ;; verb → noun-node
(passivization PID EID ALIENATING?)            ;; subject obscured
(governance GID CREATION-EID GOV-EID)          ;; two edges linked
(exchange XID PROD-EID1 PROD-EID2 XFER-EID)   ;; commodity exchange
(free-link FID EID1 EID2)                      ;; recognition/offering
(mode LABEL)                                   ;; economic grammar label
(mode-has LABEL OP-TYPE)                       ;; characterizing operations
(inversion IID ALIENATED-EID FREE-EID KIND)    ;; inversion step
```

### Relations (complete)

**Core** (one per fact tag, bidirectional via `in-list-o`):
`node-o`, `edge-o`, `nominalization-o`, `passivization-o`, `governance-o`,
`exchange-o`, `free-link-o`, `mode-o`, `mode-has-o`, `inversion-o`

**Four-fold alienation:**
`alienation-o` — the single recursive relation, parameterized by dimension

**Derived:**
`reified-o` — nominalization or alienating passivization
`reciprocal-alienation-o` — symmetric from-product with cross-governance
`fetishism-o` — reciprocal alienation + exchange edge

**Free association:**
`free-association-o` — subjects linked by free-link, not governance
`inversion-step-o`, `full-inversion-o` — alienated ↔ free structure

**Graph traversal:**
`path-o` — walk edges from node to node via transitive closure

### Example fact sets

`*slavery-facts*` — master/slave, governance + species-being
`*wage-labor-facts*` — worker/capitalist, governance + reification
`*theology-facts*` — humanity/god, governance + species-being + inversion
`*commodity-exchange-facts*` — tailor/weaver, reciprocal governance + fetishism
`*free-association-facts*` — members/collective, recognition + offering
