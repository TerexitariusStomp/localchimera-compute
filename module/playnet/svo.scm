;;; svo.scm — SVO Lens grammar as miniKanren relations
;;;
;;; A directed graph where nodes are entities (subjects and objects)
;;; and edges are verbs.  Every proposition is an edge:
;;;
;;;   S ──[V]──▶ O
;;;
;;; Alienation is when two edges from different subjects converge
;;; on the same node — one creates it, another governs it:
;;;
;;;   S1 ──[creates]──▶ product
;;;                        ▲
;;;   S2 ──[owns]──────────┘       (governance)
;;;
;;; Free association replaces convergence with a chain:
;;;
;;;   S1 ──[creates]──▶ artifact
;;;                        ▲
;;;   S2 ──[recognizes]────┘       (free-link)
;;;
;;; Fact shapes:
;;;   (node NID NAME KIND)                          ;; subject or object
;;;   (edge EID FROM-NID VERB TO-NID)               ;; the proposition IS the edge
;;;   (nominalization NID EID VERB NOUN-NID)         ;; Op. B1: verb→noun-node
;;;   (passivization PID EID ALIENATING?)            ;; Op. B2: subject obscured
;;;   (governance GID CREATION-EID GOV-EID)          ;; Op. C: two edges linked
;;;   (exchange XID PROD-EID1 PROD-EID2 XFER-EID)   ;; commodity exchange network
;;;   (free-link FID EID1 EID2)                      ;; recognition/offering
;;;   (mode LABEL)                                   ;; economic grammar label
;;;   (mode-has LABEL OP-TYPE)                       ;; which operations characterize it
;;;   (inversion IID ALIENATED-EID FREE-EID KIND)    ;; inversion step
;;;
;;; Hoot/WASM compatible.

(define-module (playnet svo)
  #:use-module (playnet kanren)
  #:use-module (playnet knowledge)
  #:export (;; Core relations
            node-o edge-o
            nominalization-o passivization-o
            governance-o exchange-o free-link-o
            mode-o mode-has-o
            inversion-o
            ;; Four-fold alienation
            alienation-o reified-o
            reciprocal-alienation-o
            private-property-o
            self-commodification-o fetishism-o
            ;; Free association
            free-association-o
            inversion-step-o full-inversion-o
            ;; Graph traversal
            path-o
            ;; Example fact sets
            *slavery-facts*
            *wage-labor-facts*
            *theology-facts*
            *commodity-exchange-facts*
            *free-association-facts*))


;;; ── Core relations ───────────────────────────────────────────────────────────
;;; One per fact tag.  Each wraps in-list-o for bidirectional unification.

(define (node-o facts nid name kind)
  (in-list-o `(node ,nid ,name ,kind) facts))

(define (edge-o facts eid from verb to)
  (in-list-o `(edge ,eid ,from ,verb ,to) facts))

(define (nominalization-o facts nid eid verb noun-nid)
  (in-list-o `(nominalization ,nid ,eid ,verb ,noun-nid) facts))

(define (passivization-o facts pid eid alienating?)
  (in-list-o `(passivization ,pid ,eid ,alienating?) facts))

(define (governance-o facts gid creation-eid gov-eid)
  (in-list-o `(governance ,gid ,creation-eid ,gov-eid) facts))

(define (exchange-o facts xid prod-eid1 prod-eid2 xfer-eid)
  (in-list-o `(exchange ,xid ,prod-eid1 ,prod-eid2 ,xfer-eid) facts))

(define (free-link-o facts fid eid1 eid2)
  (in-list-o `(free-link ,fid ,eid1 ,eid2) facts))

(define (mode-o facts label)
  (in-list-o `(mode ,label) facts))

(define (mode-has-o facts label op-type)
  (in-list-o `(mode-has ,label ,op-type) facts))

(define (inversion-o facts iid alienated-eid free-eid kind)
  (in-list-o `(inversion ,iid ,alienated-eid ,free-eid ,kind) facts))


;;; ── Four-fold alienation ──────────────────────────────────────────────────────
;;; Marx's insight: alienation is not one thing but four dimensions of the
;;; same recursive structure.  Each severs a different link in the SVO triad.
;;;
;;;   from-product       S─O   another governs what S produced
;;;   from-activity      S─V   S's verb is reified (entails from-product)
;;;   from-species-being S─S   S itself is the object of governance
;;;   from-others        S─S1  reciprocal governance mediates S-S1 relations
;;;
;;; One relation, one query: "what dimensions of alienation hold here?"
;;;
;;;   (run* (dim) (fresh (e g) (alienation-o facts dim 'worker e g)))

(define (alienation-o facts dim s e gov-eid)
  "The four-fold alienation of Marx, as recursive structure.
   DIM unifies with each dimension that holds for subject S,
   production edge E, and governance edge GOV-EID."
  (conde
    ;; S─O: base.  Two edges converge on the same object node —
    ;; one creates it, another governs it.
    ((== dim 'from-product)
     (fresh (gid s2 v1 v2 o)
       (edge-o facts e s v1 o)
       (edge-o facts gov-eid s2 v2 o)
       (governance-o facts gid e gov-eid)))

    ;; S─V: the living verb is reified into a noun-node or
    ;; passivized away.  Entails from-product.
    ((== dim 'from-activity)
     (alienation-o facts 'from-product s e gov-eid)
     (reified-o facts e))

    ;; S─S: the subject IS the object of the governance edge.
    ;; S appears in the TO position — treated as a thing.
    ((== dim 'from-species-being)
     (fresh (gid s2 v1 v2 o)
       (edge-o facts e s v1 o)            ;; S is the producing subject
       (edge-o facts gov-eid s2 v2 s)     ;; and S is governed as object
       (governance-o facts gid e gov-eid)))

    ;; S─S1: subjects relate through governed objects, not directly.
    ;; Reciprocal from-product — S governs another subject's product too.
    ((== dim 'from-others)
     (fresh (s2 o2 e2 g2-eid gid2 v3 v4)
       (alienation-o facts 'from-product s e gov-eid)
       (edge-o facts e2 s2 v3 o2)
       (edge-o facts g2-eid s v4 o2)
       (governance-o facts gid2 e2 g2-eid)))))

(define (reified-o facts eid)
  "True when edge EID has undergone reification —
   either nominalization or alienating passivization."
  (conde
    ((fresh (nid verb noun-nid)
       (nominalization-o facts nid eid verb noun-nid)))
    ((fresh (pid)
       (passivization-o facts pid eid #t)))))

(define (reciprocal-alienation-o facts s1 s2 o1 o2 e1 e2 g1-eid g2-eid)
  "Symmetric four-fold: both S1 and S2 alienated from-product,
   with cross-governance.  Derived from alienation-o."
  (fresh (v1 v2 v3 v4)
    (alienation-o facts 'from-product s1 e1 g1-eid)
    (alienation-o facts 'from-product s2 e2 g2-eid)
    ;; Cross-governance: S2 governs S1's object, S1 governs S2's object
    (edge-o facts e1 s1 v1 o1)
    (edge-o facts g1-eid s2 v2 o1)
    (edge-o facts e2 s2 v3 o2)
    (edge-o facts g2-eid s1 v4 o2)))

(define (private-property-o facts eid gov-eid obj)
  "OBJ has taken the form of private property:
   produced by one subject, governed by another."
  (fresh (gid s1 s2 v1 v2)
    (edge-o facts eid s1 v1 obj)
    (edge-o facts gov-eid s2 v2 obj)
    (governance-o facts gid eid gov-eid)))

(define (self-commodification-o facts s prod-eid com-eid nom-obj)
  "S nominalizes their own production verb into NOM-OBJ,
   which they then put up for exchange as a commodity.
   The slave IS property; the wage worker PRODUCES a commodity
   from their own living capacity."
  (fresh (nid verb v1 o v2)
    (edge-o facts prod-eid s v1 o)                    ;; S's living verb
    (nominalization-o facts nid prod-eid verb nom-obj) ;; verb → commodity
    (edge-o facts com-eid s v2 nom-obj)))              ;; S offers it

(define (fetishism-o facts xid s1 s2 o1 o2)
  "Commodity fetishism: exchange of objects that have taken
   the form of private property.  Objects appear to relate
   to each other, hiding the productive relations."
  (fresh (e1 e2 g1 g2 xfer-eid v1 v2)
    (private-property-o facts e1 g1 o1)
    (private-property-o facts e2 g2 o2)
    (edge-o facts e1 s1 v1 o1)
    (edge-o facts e2 s2 v2 o2)
    (exchange-o facts xid e1 e2 xfer-eid)))

(define (free-association-o facts eid1 eid2 s1 s2)
  "True when S1 and S2 relate through recognition/offering.
   Positive encoding via free-link — no negation needed."
  (fresh (fid v1 o1 v2 o2)
    (free-link-o facts fid eid1 eid2)
    (edge-o facts eid1 s1 v1 o1)
    (edge-o facts eid2 s2 v2 o2)))

(define (inversion-step-o facts alienated-eid free-eid kind)
  "Relate one alienated edge to its free-association form."
  (fresh (iid)
    (inversion-o facts iid alienated-eid free-eid kind)))

(define (full-inversion-o facts alienated-eids free-eids)
  "Relate a list of alienated edges to their inversions."
  (conde
    ((== alienated-eids '()) (== free-eids '()))
    ((fresh (a-eid f-eid a-rest f-rest kind)
       (== alienated-eids (cons a-eid a-rest))
       (== free-eids (cons f-eid f-rest))
       (inversion-step-o facts a-eid f-eid kind)
       (full-inversion-o facts a-rest f-rest)))))


;;; ── Graph traversal ──────────────────────────────────────────────────────────

(define (path-o facts start end trace)
  "Walk edges from START node to END node.
   TRACE is the list of (verb . target) pairs along the path.
   Uses transitive-o from (playnet knowledge) over the edge relation."
  (transitive-o
    (lambda (from to)
      (fresh (eid verb)
        (edge-o facts eid from verb to)))
    start end trace))


;;; ── Example fact sets ────────────────────────────────────────────────────────

;;; Slavery — Total alienating governance (Op. C)
;;; The master owns the slave's capacity to act and its products.

(define *slavery-facts*
  '(;; Nodes
    (node slave "The Slave" subject)
    (node master "The Master" subject)
    (node product "Product" object)

    ;; Mode
    (mode slavery)
    (mode-has slavery governance)

    ;; slave ──[labors]──▶ product
    (edge e1 slave labors product)

    ;; master ──[owns]──▶ product   (from-product: converges on same node)
    (edge e2 master owns product)
    (governance g1 e1 e2)

    ;; master ──[owns]──▶ slave   (from-species-being: S IS the object)
    (edge e3 master owns slave)
    (governance g2 e1 e3)))


;;; Wage Labor — Self-commodification + Exchange + Governance
;;; The worker is formally free (no from-species-being), but nominalizes
;;; their own verb into labor-power — a commodity exchanged for wages.
;;; The slave IS property; the wage worker PRODUCES a commodity from
;;; their own living capacity.
;;;
;;;   worker ──[labors]──▶ product          (living verb)
;;;          ──[sells]───▶ labor-power      (self-commodification)
;;;                            ▲
;;;   capitalist ──[buys]──────┘            (governance: private property)
;;;              ──[owns]──▶ product        (governance: product too)
;;;
;;;   labor-power ──[exchanges-for]──▶ wage

(define *wage-labor-facts*
  '(;; Nodes
    (node worker "The Worker" subject)
    (node capitalist "The Capitalist" subject)
    (node product "Product" object)
    (node labor-power "Labor-Power" commodity)  ;; the nominalized verb as commodity
    (node wage "Wage" commodity)

    ;; Mode
    (mode wage-labor)
    (mode-has wage-labor nominalization)
    (mode-has wage-labor governance)
    (mode-has wage-labor exchange)

    ;; ── Living verb ──
    ;; worker ──[labors]──▶ product
    (edge e1 worker labors product)

    ;; ── Self-commodification ──
    ;; Nominalization: "labors" → labor-power (verb becomes commodity)
    (nominalization n1 e1 labors labor-power)

    ;; worker ──[sells]──▶ labor-power   (the capacity, not the labor itself)
    (edge e-lp worker sells labor-power)

    ;; ── Exchange: labor-power for wage ──
    ;; capitalist ──[pays]──▶ wage
    (edge e-w capitalist pays wage)

    ;; labor-power ──[exchanges-for]──▶ wage
    (edge e-xfer labor-power exchanges-for wage)
    (exchange x1 e-lp e-w e-xfer)

    ;; ── Governance ──
    ;; capitalist ──[buys]──▶ labor-power   (labor-power as private property)
    (edge e2 capitalist buys labor-power)
    (governance g-lp e-lp e2)

    ;; capitalist ──[owns]──▶ product   (product as private property)
    (edge e3 capitalist owns product)
    (governance g1 e1 e3)

    ;; ── Reification ──
    ;; "Workers labor" → "Value is created"
    (passivization pa1 e1 #t)))


;;; Theology — Projection + Governance + Free-Association Inversion
;;; Humanity projects its virtues onto God, who then commands humanity.
;;; The inversion: recognize virtues as one's own, practice them directly.

(define *theology-facts*
  '(;; Nodes
    (node humanity "Humanity" subject)
    (node god "God" projected)
    (node virtues "Virtues" object)
    (node virtue "Virtue" object)           ;; nominalized form
    (node wisdom "Wisdom" object)
    (node support "Support" object)
    (node we "We" subject)
    (node community "The Community" subject)
    (node member-a "Member A" subject)
    (node member-b "Member B" subject)

    ;; Mode
    (mode theology)
    (mode-has theology nominalization)
    (mode-has theology governance)

    ;; humanity ──[conceives]──▶ virtues   (externalization)
    (edge e1 humanity conceives virtues)

    ;; Nominalization: "conceives" → virtue (static noun-node)
    (nominalization n1 e1 conceives virtue)

    ;; humanity ──[projects]──▶ god
    (edge e2 humanity projects god)

    ;; god ──[possesses]──▶ virtues   (from-product: converges on virtues)
    (edge e3a god possesses virtues)
    (governance g1 e1 e3a)

    ;; god ──[commands]──▶ humanity   (from-species-being: S IS the object)
    (edge e3 god commands humanity)
    (governance g2 e1 e3)

    ;; ── Free-association inversion ──

    ;; we ──[recognize]──▶ virtues   (reclamation)
    (edge e4 we recognize virtues)
    (inversion i1 e3 e4 projection-to-reclamation)

    ;; community ──[practices]──▶ virtues   (noun back to verb)
    (edge e5 community practices virtues)
    (inversion i2 e3 e5 noun-to-verb)
    (free-link f1 e4 e5)

    ;; member-a ──[recognizes]──▶ wisdom
    (edge e6 member-a recognizes wisdom)
    (free-link f2 e5 e6)

    ;; member-b ──[offers]──▶ support
    (edge e7 member-b offers support)
    (free-link f3 e6 e7)))


;;; Commodity Exchange — Reciprocal alienation + fetishism
;;; Two producers each alienate their product to the other.
;;; The exchange edge (O1 ──▶ O2) makes objects appear to relate
;;; to each other, hiding the social relations of production.
;;;
;;;   tailor ──[sews]──────▶ coat ──[exchanges-for]──▶ linen
;;;                            ▲                          ▲
;;;   weaver ──[buys]──────────┘                          │
;;;   tailor ──[buys]─────────────────────────────────────┘
;;;   weaver ──[weaves]────▶ linen
;;;
;;; The fetish: "20 yards of linen = 1 coat" appears as a property
;;; of the things themselves, not of the labor that produced them.

(define *commodity-exchange-facts*
  '(;; Nodes
    (node tailor "The Tailor" subject)
    (node weaver "The Weaver" subject)
    (node coat "Coat" commodity)
    (node linen "Linen" commodity)

    ;; Mode
    (mode commodity-exchange)
    (mode-has commodity-exchange nominalization)
    (mode-has commodity-exchange governance)
    (mode-has commodity-exchange exchange)

    ;; tailor ──[sews]──▶ coat   (production)
    (edge e1 tailor sews coat)

    ;; weaver ──[weaves]──▶ linen   (production)
    (edge e2 weaver weaves linen)

    ;; Nominalization: living verbs → abstract "labor"
    (nominalization n1 e1 sews labor)
    (nominalization n2 e2 weaves labor)
    (node labor "Abstract Labor" object)

    ;; coat ──[exchanges-for]──▶ linen   (the fetish edge: objects relating)
    (edge e-xfer coat exchanges-for linen)

    ;; weaver ──[buys]──▶ coat   (S2 governs S1's product)
    (edge e3 weaver buys coat)
    (governance g1 e1 e3)

    ;; tailor ──[buys]──▶ linen   (S1 governs S2's product)
    (edge e4 tailor buys linen)
    (governance g2 e2 e4)

    ;; Exchange: links the two production edges + the transfer edge
    (exchange x1 e1 e2 e-xfer)

    ;; Alienating passivization: "The tailor sews" → "The coat is made"
    (passivization pa1 e1 #t)
    (passivization pa2 e2 #t)))


;;; Free Association — Recognition and offering, no governance
;;; Value flows based on present evaluation of actions.
;;; The SVO link stays intact — every edge is a living verb.

(define *free-association-facts*
  '(;; Nodes
    (node member-a "Member A" subject)
    (node member-b "Member B" subject)
    (node member-c "Member C" subject)
    (node collective "The Collective" subject)
    (node artifact "Artifact" object)
    (node support "Support" object)
    (node process "Process" object)

    ;; Mode
    (mode free-association)

    ;; member-a ──[creates]──▶ artifact
    (edge e1 member-a creates artifact)

    ;; member-b ──[recognizes]──▶ artifact
    (edge e2 member-b recognizes artifact)
    (free-link f1 e1 e2)

    ;; member-b ──[offers]──▶ support
    (edge e3 member-b offers support)
    (free-link f2 e2 e3)

    ;; member-c ──[recognizes]──▶ support
    (edge e4 member-c recognizes support)
    (free-link f3 e3 e4)

    ;; collective ──[develops]──▶ process
    (edge e5 collective develops process)
    (free-link f4 e4 e5)))


;;; ── Demo queries ─────────────────────────────────────────────────────────────
;;;
;;; The four-fold alienation — one query reveals each mode's structure:
;;;
;;; (run* (dim) (fresh (e g) (alienation-o *slavery-facts* dim 'slave e g)))
;;; => (from-product from-species-being)
;;;
;;; (run* (dim) (fresh (e g) (alienation-o *wage-labor-facts* dim 'worker e g)))
;;; => (from-product from-activity)   ;; no from-species-being — worker is "free"
;;;
;;; Self-commodification: "what does the worker commodify?"
;;; (run* (q) (fresh (pe ce) (self-commodification-o *wage-labor-facts* 'worker pe ce q)))
;;; => (labor-power)
;;;
;;; Private property: "what takes the form of private property?"
;;; (run* (q) (fresh (e g) (private-property-o *wage-labor-facts* e g q)))
;;; => (labor-power product)   ;; both the reified capacity AND the product
;;;
;;; (run* (dim) (fresh (e g) (alienation-o *theology-facts* dim 'humanity e g)))
;;; => (from-product from-species-being)
;;;
;;; (run* (dim) (fresh (e g) (alienation-o *commodity-exchange-facts* dim 'tailor e g)))
;;; => (from-product from-activity from-others)
;;;
;;; Backward: "Given from-species-being, who is the subject?"
;;; (run* (q) (fresh (e g) (alienation-o *slavery-facts* 'from-species-being q e g)))
;;; => (slave)
;;;
;;; Commodity fetishism (builds on from-others):
;;; (run* (q)
;;;   (fresh (xid s1 s2 o1 o2)
;;;     (fetishism-o *commodity-exchange-facts* xid s1 s2 o1 o2)
;;;     (== q `(,o1 appears-to-exchange-with ,o2 hiding (,s1 ,s2)))))
;;; => ((coat appears-to-exchange-with linen hiding (tailor weaver)))
;;;
;;; "All edges out of worker"
;;; (run* (q)
;;;   (fresh (eid verb to)
;;;     (edge-o *wage-labor-facts* eid 'worker verb to)
;;;     (== q `(,verb ,to))))
;;; => ((labors product) (sells labor-power))
;;;
;;; "All edges into product — who converges?"
;;; (run* (q)
;;;   (fresh (eid from verb)
;;;     (edge-o *wage-labor-facts* eid from verb 'product)
;;;     (== q `(,from ,verb))))
;;; => ((worker labors) (capitalist owns))
;;;
;;; Slavery vs Wage Labor — the structural transition:
;;;   slavery:    master ──[owns]──▶ slave         (subject IS property)
;;;   wage-labor: worker ──[sells]──▶ labor-power  (subject PRODUCES a commodity)
;;; Same alienation-from-product, but the mechanism flips:
;;; governance over the person → governance over the self-commodified verb.
