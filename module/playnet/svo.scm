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
;;;   (governance GID CREATION-EID GOV-EID)          ;; Op. C: two edges linked (not all alienating!)
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
            self-commodification-o
            surplus-o fetishism-o
            ;; Hegel
            constitutes-o bildung-o
            reproduces-domination-o
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
   production edge E, and governance edge GOV-EID.
   Uses private-property-o — not all governance is alienating."
  (conde
    ;; S─O: base.  S's product is private property of another.
    ((== dim 'from-product)
     (fresh (s2 o)
       (private-property-o facts s s2 o e gov-eid)))

    ;; S─V: the living verb is reified into a noun-node or
    ;; passivized away.  Entails from-product.
    ((== dim 'from-activity)
     (alienation-o facts 'from-product s e gov-eid)
     (reified-o facts e))

    ;; S─S direct (slavery): S IS the governed object.
    ;; S appears in the TO position — treated as a thing.
    ((== dim 'from-species-being)
     (fresh (gid s2 v1 v2 o)
       (edge-o facts e s v1 o)
       (edge-o facts gov-eid s2 v2 s)
       (governance-o facts gid e gov-eid)))

    ;; S─S mediated (wage labor): S's self-commodified capacity
    ;; is private property of another.  The worker objectifies
    ;; their own species-being via nominalization.
    ((== dim 'from-species-being)
     (fresh (s2 com-eid nom-obj gov2)
       (self-commodification-o facts s e com-eid nom-obj)
       (private-property-o facts s s2 nom-obj com-eid gov2)))

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
  "Symmetric alienation: S1's product is S2's private property,
   and S2's product is S1's private property."
  (private-property-o facts s1 s2 o1 e1 g1-eid)
  (private-property-o facts s2 s1 o2 e2 g2-eid))

(define (private-property-o facts s1 s2 obj use-eid gov-eid)
  "Private property as a social relation between S1 and S2,
   mediated through OBJ.  S1 produces/uses OBJ, S2 governs it.
   Not all governance is alienating — only governance that creates
   exclusion, where the producer's use is conditioned on the
   governor's terms."
  (fresh (gid v1 v2)
    (edge-o facts use-eid s1 v1 obj)
    (edge-o facts gov-eid s2 v2 obj)
    (governance-o facts gid use-eid gov-eid)))

(define (self-commodification-o facts s prod-eid com-eid nom-obj)
  "S nominalizes their own production verb into NOM-OBJ,
   which they then put up for exchange as a commodity.
   The slave IS property; the wage worker PRODUCES a commodity
   from their own living capacity."
  (fresh (nid verb v1 o v2)
    (edge-o facts prod-eid s v1 o)                    ;; S's living verb
    (nominalization-o facts nid prod-eid verb nom-obj) ;; verb → commodity
    (edge-o facts com-eid s v2 nom-obj)))              ;; S offers it

(define (surplus-o facts s s2 product prod-eid com-eid)
  "The structural form of surplus extraction: S's living verb
   produces PRODUCT governed by S2, AND S's self-commodified
   capacity is also governed by S2.  The double private-property
   — over both product and capacity — is the form of exploitation."
  (fresh (nom-obj gov-prod gov-cap)
    (self-commodification-o facts s prod-eid com-eid nom-obj)
    (private-property-o facts s s2 product prod-eid gov-prod)
    (private-property-o facts s s2 nom-obj com-eid gov-cap)))

(define (fetishism-o facts xid s1 s2 o1 o2)
  "Commodity fetishism: exchange of objects that have taken
   the form of private property.  Objects appear to relate
   to each other, hiding the productive relations."
  (fresh (e1 e2 g1 g2 xfer-eid s1b s2b)
    (private-property-o facts s1 s1b o1 e1 g1)
    (private-property-o facts s2 s2b o2 e2 g2)
    (exchange-o facts xid e1 e2 xfer-eid)))


;;; ── Hegel ────────────────────────────────────────────────────────────────────
;;; The producing subject constitutes both social positions, produces
;;; the infrastructure of their own domination, and through formative
;;; labor discovers the capacity to overcome the relation.
;;;
;;; Three relations, universal across modes:
;;;   constitutes-o            S produces both positions (self-loop + other)
;;;   reproduces-domination-o  S produces infrastructure governed by S2 + constitutes
;;;   bildung-o                self-loop inverts to formative activity

(define (constitutes-o facts s s2 self-eid other-eid gov-eid)
  "S constitutes both social positions: produces S (self-loop,
   governed) and produces S2.  The laboring subject produces
   the entire relation — including their own subordination."
  (fresh (gid v1 v2)
    (edge-o facts self-eid s v1 s)
    (edge-o facts other-eid s v2 s2)
    (governance-o facts gid self-eid gov-eid)))

(define (bildung-o facts s self-eid bildung-eid kind)
  "S's governed self-production (self-loop) inverts to formative
   activity.  The same capacity that reproduces subordination
   becomes the seed of emancipation."
  (fresh (iid v1 o)
    (edge-o facts self-eid s _ s)
    (edge-o facts bildung-eid s v1 o)
    (inversion-o facts iid self-eid bildung-eid kind)))

(define (reproduces-domination-o facts s s2 infrastructure)
  "The governed produce the governance: S produces INFRASTRUCTURE
   which is private property of S2, and S constitutes both positions
   under S2's governance.  The circle of domination.
   Works across modes — slavery (dominion), wage labor (means)."
  (fresh (infra-eid gov-eid self-eid other-eid gov-self)
    (private-property-o facts s s2 infrastructure infra-eid gov-eid)
    (constitutes-o facts s s2 self-eid other-eid gov-self)))


;;; ── Free association ─────────────────────────────────────────────────────────

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

;;; Slavery — Hegel's lord and bondsman (Phenomenology §178-196)
;;; The slave's labor produces the social relation itself:
;;; the slave produces themselves as slave AND the master as master.
;;; Through that same labor — Bildung — the slave discovers formative
;;; capacity, which is the seed of the dialectical reversal.
;;;
;;; Alienated form:
;;;
;;;   slave ──[labors]──▶ product         (production)
;;;         ──[produces]──▶ dominion      (the governed produce the governance)
;;;         ──[produces]──▶ master        (constitutes mastery)
;;;         ──[produces]──▶ slave         (continuation in servitude)
;;;                            ▲
;;;   master ──[owns]──────────┘          (direct ownership of the person)
;;;          ──[owns]──▶ product          (governance of product)
;;;          ──[owns]──▶ dominion         (governs what slave built)
;;;          ──[consumes]──▶ product      (non-formative: dependence)
;;;
;;; Bildung (the reversal):
;;;
;;;   slave ──[shapes]──▶ world           (formative labor)
;;;   Servitude → formation.  The same productive capacity,
;;;   redirected from self-enslavement to self-formation.

(define *slavery-facts*
  '(;; Nodes
    (node slave "The Slave" subject)
    (node master "The Master" subject)
    (node product "Product" object)
    (node dominion "Means of Domination" object) ;; plantation, estate, infrastructure
    (node world "The Shaped World" object)       ;; Bildung

    ;; Mode
    (mode slavery)
    (mode-has slavery governance)

    ;; ── Production ──
    ;; slave ──[labors]──▶ product
    (edge e1 slave labors product)

    ;; ── Governance ──
    ;; master ──[owns]──▶ product   (from-product: converges on same node)
    (edge e2 master owns product)
    (governance g1 e1 e2)

    ;; master ──[owns]──▶ slave   (from-species-being: S IS the object)
    (edge e3 master owns slave)
    (governance g2 e1 e3)

    ;; master ──[owns]──▶ dominion
    (edge e-md master owns dominion)

    ;; ── The governed produce the governance ──
    ;; The slave builds the plantation, the estate, the infrastructure
    ;; of the master's power.  Not through selling themselves (that's
    ;; wage labor), but through continued servitude: the slave's labor
    ;; produces the material basis of domination that sustains their
    ;; own domination.
    (edge e-pd slave produces dominion)
    (governance g-pd e-pd e-md)

    ;; ── Hegel: the slave produces both positions ──────────────
    ;; The slave's labor produces the social relation itself.

    ;; slave ──[produces]──▶ master   (recognition constitutes mastery)
    (edge e4 slave produces master)

    ;; slave ──[produces]──▶ slave    (continuation in servitude)
    ;; Self-loop: not self-commodification but continued servitude.
    ;; Governed by direct ownership of the person (e3) —
    ;; which is sustained by the dominion the slave themselves produce.
    (edge e5 slave produces slave)
    (governance g3 e5 e3)

    ;; master ──[consumes]──▶ product   (non-formative: deepens dependence)
    ;; The master doesn't labor — their identity depends on the slave.
    (edge e6 master consumes product)

    ;; ── Bildung: the dialectical reversal ─────────────────────
    ;; Through labor on things, the slave shapes the world and
    ;; discovers formative capacity — the seed of emancipation.
    ;; The same self-productive power that constitutes servitude (e5)
    ;; becomes formative self-creation (e-f1).

    ;; slave ──[shapes]──▶ world   (formative labor)
    (edge e-f1 slave shapes world)
    (inversion i1 e5 e-f1 servitude-to-formation)))


;;; Wage Labor — Self-commodification + Exchange + Private Property
;;; The worker is formally free (no direct from-species-being), but
;;; nominalizes their own verb into labor-power — a commodity exchanged
;;; for wages.  Mediated from-species-being: the self-commodified
;;; capacity is private property.  The slave IS property; the wage
;;; worker PRODUCES a commodity from their own living capacity.
;;;
;;; First negation (alienated form):
;;;
;;;   worker ──[labors]──▶ product          (living verb)
;;;          ──[sells]───▶ labor-power      (self-commodification)
;;;          ──[produces]──▶ capitalist     (surplus constitutes capital)
;;;          ──[produces]──▶ worker         (self-loop: reproduces position)
;;;          ──[produces]──▶ means          (the governed produce the governance)
;;;                            ▲
;;;   capitalist ──[buys]──────┘            (governance: private property)
;;;              ──[owns]──▶ product        (governance: product too)
;;;              ──[owns]──▶ means          (monopoly — governs e-pm AND e-hw)
;;;
;;;   labor-power ──[exchanges-for]──▶ wage
;;;
;;; Bildung: worker ──[organizes]──▶ solidarity  (seed of emancipation)
;;;
;;; Negation of the negation (emancipated form):
;;;
;;;   producer-a ──[creates]──▶ product     (living verb restored)
;;;   producer-b ──[recognizes]──▶ product  (recognition, not ownership)
;;;   producer-a ──[offers]──▶ effort       (contribution, not commodity)
;;;   producer-b ──[recognizes]──▶ effort   (mutual recognition)
;;;   associates ──[steward]──▶ means       (commons, not monopoly)

(define *wage-labor-facts*
  '(;; Nodes
    (node worker "The Worker" subject)
    (node capitalist "The Capitalist" subject)
    (node product "Product" object)
    (node labor-power "Labor-Power" commodity)  ;; the nominalized verb as commodity
    (node wage "Wage" commodity)
    (node means "Means of Production" object)
    ;; Emancipated subjects
    (node producer-a "Producer A" subject)
    (node producer-b "Producer B" subject)
    (node associates "The Association" subject)
    (node effort "Living Activity" object)     ;; the un-commodified verb
    (node solidarity "Collective Capacity" object) ;; Bildung

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

    ;; capitalist ──[owns]──▶ means   (monopoly: the "doubly free" worker)
    (edge e-mp capitalist owns means)

    ;; ── The governed produce the governance ──
    ;; Workers produce the means of production themselves —
    ;; factories, tools, infrastructure — which become private
    ;; property and thus the very governance that compels them
    ;; to sell labor-power.
    (edge e-pm worker produces means)
    (governance g-pm e-pm e-mp)

    ;; ── Reification ──
    ;; "Workers labor" → "Value is created"
    (passivization pa1 e1 #t)

    ;; ── Hegel: the worker produces both positions ────────────
    ;; "The capitalist process of production... produces and
    ;; reproduces the capital-relation itself; on the one side
    ;; the capitalist, on the other the wage-labourer."
    ;; (Capital I, Ch. 23)

    ;; worker ──[produces]──▶ capitalist   (surplus constitutes capital)
    (edge e-hc worker produces capitalist)

    ;; worker ──[produces]──▶ worker       (self-loop)
    ;; Not just individual reproduction: the proletariat reproduces
    ;; the property relations (g-pm: means as private property)
    ;; that impel them to become workers.  The governed produce
    ;; the governance.  The self-loop is governed by e-mp —
    ;; which is itself produced by e-pm — which is itself governed
    ;; by e-mp.  The circle closes.
    (edge e-hw worker produces worker)
    (governance g-hw e-hw e-mp)

    ;; ── Bildung: organizational capacity ──────────────────────
    ;; Through collective labor, the working class develops the
    ;; capacity for self-organization — the seed of emancipation.
    ;; The same self-reproductive power that reproduces servitude
    ;; becomes collective organizing capacity.

    ;; worker ──[organizes]──▶ solidarity   (formative labor)
    (edge e-b1 worker organizes solidarity)
    (inversion i-hw e-hw e-b1 reproduction-to-organization)

    ;; ── Negation of the negation ──────────────────────────────
    ;; The split in private-property-o (s1 uses, s2 governs) is
    ;; overcome.  Not a return to individual property but a new
    ;; form: associated producers collectively produce and
    ;; collectively govern.
    ;;
    ;;   governance → recognition
    ;;   commodity  → contribution
    ;;   monopoly   → commons
    ;;   nominalization dissolved — the verb stays living.

    ;; producer-a ──[creates]──▶ product   (living verb restored)
    (edge e-f1 producer-a creates product)
    (inversion i1 e3 e-f1 governance-to-creation)

    ;; producer-b ──[recognizes]──▶ product   (recognition, not ownership)
    (edge e-f2 producer-b recognizes product)
    (free-link f1 e-f1 e-f2)

    ;; producer-a ──[offers]──▶ effort   (freely given, not sold)
    ;; No nominalization — the verb stays living.
    (edge e-f3 producer-a offers effort)
    (inversion i2 e-lp e-f3 commodity-to-contribution)
    (free-link f2 e-f2 e-f3)

    ;; producer-b ──[recognizes]──▶ effort   (mutual recognition)
    (edge e-f4 producer-b recognizes effort)
    (free-link f3 e-f3 e-f4)

    ;; associates ──[steward]──▶ means   (commons, not monopoly)
    (edge e-f5 associates steward means)
    (inversion i3 e-mp e-f5 monopoly-to-commons)
    (free-link f4 e-f4 e-f5)

    ;; Bildung → commons: organizational capacity is what enables
    ;; the associated producers to collectively steward the means.
    (free-link f-b e-b1 e-f5)))


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
;;; Private property in slavery: "what does the slave produce for the master?"
;;; (run* (q)
;;;   (fresh (s1 s2 obj e g)
;;;     (private-property-o *slavery-facts* s1 s2 obj e g)
;;;     (== q obj)))
;;; => (product dominion)   ;; the slave produces both — including the
;;;                         ;; infrastructure that sustains domination.
;;;
;;; ── Unified Hegelian queries (work across all modes) ──
;;;
;;; "The governed produce the governance — who, for whom, through what?"
;;; (run* (q)
;;;   (fresh (s2 infra)
;;;     (reproduces-domination-o *slavery-facts* 'slave s2 infra)
;;;     (== q `(slave produces ,infra for ,s2))))
;;; => ((slave produces dominion for master))
;;;
;;; (run* (q)
;;;   (fresh (s2 infra)
;;;     (reproduces-domination-o *wage-labor-facts* 'worker s2 infra)
;;;     (== q `(worker produces ,infra for ,s2))))
;;; => ((worker produces means for capitalist))
;;;
;;; Same relation, same structure, different content.
;;;
;;; Bildung: "what is the seed of emancipation?"
;;; (run* (q)
;;;   (fresh (se be kind)
;;;     (bildung-o *slavery-facts* 'slave se be kind)
;;;     (== q kind)))
;;; => (servitude-to-formation)
;;;
;;; (run* (q)
;;;   (fresh (se be kind)
;;;     (bildung-o *wage-labor-facts* 'worker se be kind)
;;;     (== q kind)))
;;; => (reproduction-to-organization)
;;;
;;; (run* (dim) (fresh (e g) (alienation-o *wage-labor-facts* dim 'worker e g)))
;;; => (from-product from-activity from-species-being)
;;; No from-species-being/direct (worker is "free"), but mediated:
;;; the worker's self-commodified capacity is private property.
;;;
;;; Self-commodification: "what does the worker commodify?"
;;; (run* (q) (fresh (pe ce) (self-commodification-o *wage-labor-facts* 'worker pe ce q)))
;;; => (labor-power)
;;;
;;; Private property as social relation: "who governs whose product?"
;;; (run* (q)
;;;   (fresh (s1 s2 obj e g)
;;;     (private-property-o *wage-labor-facts* s1 s2 obj e g)
;;;     (== q `(,s1 produces ,obj governed-by ,s2))))
;;; => ((worker produces labor-power governed-by capitalist)
;;;     (worker produces product governed-by capitalist)
;;;     (worker produces means governed-by capitalist))
;;; The third result is the deepest: the governed produce the governance.
;;;
;;; Surplus extraction: double governance over product AND capacity
;;; (run* (q)
;;;   (fresh (s2 product pe ce)
;;;     (surplus-o *wage-labor-facts* 'worker s2 product pe ce)
;;;     (== q `(,s2 extracts-surplus from worker))))
;;; => ((capitalist extracts-surplus from worker))
;;;
;;; Hegel: "what does the worker produce?" (parallel to slave)
;;; (run* (q)
;;;   (fresh (eid verb to)
;;;     (edge-o *wage-labor-facts* eid 'worker verb to)
;;;     (== q `(,verb ,to))))
;;; => ((labors product) (sells labor-power) (produces means)
;;;     (produces capitalist) (produces worker) (organizes solidarity))
;;; The worker produces everything — the product, the means, both
;;; social positions, and the organizational capacity for emancipation.
;;;
;;; The full dialectical arc:
;;; (run* (q)
;;;   (fresh (iid a-eid f-eid kind)
;;;     (inversion-o *wage-labor-facts* iid a-eid f-eid kind)
;;;     (== q kind)))
;;; => (governance-to-creation commodity-to-contribution
;;;     monopoly-to-commons reproduction-to-organization)
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
;;; => ((worker labors) (capitalist owns)
;;;     (producer-a creates) (producer-b recognizes))
;;; Both the alienated and emancipated forms visible in one query.
;;;
;;; Slavery vs Wage Labor — the structural transition:
;;;   slavery:    master ──[owns]──▶ slave         (subject IS property)
;;;   wage-labor: worker ──[sells]──▶ labor-power  (subject PRODUCES a commodity)
;;; Both have from-species-being, but the mechanism differs:
;;;   slavery:    direct — S in the TO position of a governance edge
;;;   wage-labor: mediated — S's self-commodified capacity is private property
;;; Not all governance is alienating.  Free-links = mutual recognition.
;;; Governance = subordination.  Private property = governance that excludes.
;;;
;;; Negation of the negation — "what replaces each alienated edge?"
;;; (run* (q)
;;;   (fresh (iid a-eid f-eid kind)
;;;     (inversion-o *wage-labor-facts* iid a-eid f-eid kind)
;;;     (== q kind)))
;;; => (governance-to-creation commodity-to-contribution monopoly-to-commons)
;;;
;;; Full inversion — map all alienated edges to their free counterparts:
;;; (run* (q)
;;;   (fresh (free-eids)
;;;     (full-inversion-o *wage-labor-facts* '(e3 e-lp e-mp) free-eids)
;;;     (== q free-eids)))
;;; => ((e-f1 e-f3 e-f5))
;;;
;;; Free association within the wage-labor facts (the emancipated edges):
;;; (run* (q)
;;;   (fresh (eid1 eid2 s1 s2)
;;;     (free-association-o *wage-labor-facts* eid1 eid2 s1 s2)
;;;     (== q `(,s1 recognizes ,s2))))
;;; => ((producer-a recognizes producer-b) ...)
