;;; knowledge.scm — Relational query layer over hyperarc knowledge bases
;;; Uses miniKanren (xorg kanren) for unification-based pattern matching
;;; and proof-traced transitive closure.
;;; Hoot/WASM compatible.

(define-module (xorg knowledge)
  #:use-module (xorg kanren)
  #:use-module (xorg hyperarc)
  #:use-module (srfi srfi-1)
  #:export (;; Structural destructuring relations
            node-o hyperarc-o metagraph-o
            ;; Knowledge base relation
            kb-o
            ;; Navigation
            arcs-of-o arc-nodes-o directed-arc-o
            ;; Cross-arc queries
            related-by-o shared-node-o
            ;; Pattern matching (via unification)
            node-value-matches-o node-meta-has-o
            ;; Transitive closure with proof traces
            transitive-o
            ;; Proof trace utilities
            proof-steps proof-length))

;;; ── Structural destructuring relations ─────────────────────────────────────
;;; These relate a tagged S-expression to its components via unification.
;;; Because the data is plain lists, miniKanren unifies against structure directly.

(define (node-o node nid value meta)
  "Destructure a node into its components."
  (== node `(node (id . ,nid) (value . ,value) (meta . ,meta))))

(define (hyperarc-o arc aid meta nodes)
  "Destructure a hyperarc into its components."
  (== arc `(hyperarc (id . ,aid) (meta . ,meta) (nodes . ,nodes))))

(define (metagraph-o mg mgid meta arcs)
  "Destructure a metagraph into its components."
  (== mg `(metagraph (id . ,mgid) (meta . ,meta) (arcs . ,arcs))))

;;; ── Knowledge base relation ────────────────────────────────────────────────

(define (kb-o kb name mg)
  "Relate a knowledge base to one of its named metagraphs."
  (fresh (entries)
    (== kb (cons 'kb entries))
    (membero (cons name mg) entries)))

;;; ── Navigation relations ───────────────────────────────────────────────────

(define (arcs-of-o mg arc)
  "Relate a metagraph to one of its hyperarcs."
  (fresh (mgid meta arcs)
    (metagraph-o mg mgid meta arcs)
    (membero arc arcs)))

(define (arc-nodes-o arc node)
  "Relate a hyperarc to one of its nodes."
  (fresh (aid meta nodes)
    (hyperarc-o arc aid meta nodes)
    (membero node nodes)))

(define (directed-arc-o arc from-node to-node)
  "In a directed hyperarc, from-node is the head (first) and to-node is in the tail."
  (fresh (aid meta nodes rest)
    (hyperarc-o arc aid meta nodes)
    (== nodes (cons from-node rest))
    (membero to-node rest)))

;;; ── Cross-arc / cross-metagraph queries ────────────────────────────────────

(define (related-by-o kb domain-name node1 node2)
  "node1 and node2 appear in the same hyperarc within a named metagraph."
  (fresh (mg arc)
    (kb-o kb domain-name mg)
    (arcs-of-o mg arc)
    (arc-nodes-o arc node1)
    (arc-nodes-o arc node2)))

(define (shared-node-o kb domain1 domain2 shared-value)
  "A node value appears in both domain1 and domain2 metagraphs."
  (fresh (mg1 mg2 arc1 arc2 n1 n2 id1 id2 m1 m2)
    (kb-o kb domain1 mg1)
    (kb-o kb domain2 mg2)
    (arcs-of-o mg1 arc1)
    (arcs-of-o mg2 arc2)
    (arc-nodes-o arc1 n1)
    (arc-nodes-o arc2 n2)
    (node-o n1 id1 shared-value m1)
    (node-o n2 id2 shared-value m2)))

;;; ── Pattern matching via unification ───────────────────────────────────────
;;; No separate pattern layer — querying with partially-specified terms
;;; containing logic variables performs the match via miniKanren unification.

(define (node-value-matches-o kb node pattern)
  "Find nodes whose value unifies with pattern.
   Pattern can contain logic variables for partial matching."
  (fresh (name mg arc nid nmeta)
    (kb-o kb name mg)
    (arcs-of-o mg arc)
    (arc-nodes-o arc node)
    (node-o node nid pattern nmeta)))

(define (node-meta-has-o kb node key val)
  "Find nodes that have (key . val) in their meta alist."
  (fresh (name mg arc nid nval meta)
    (kb-o kb name mg)
    (arcs-of-o mg arc)
    (arc-nodes-o arc node)
    (node-o node nid nval meta)
    (membero (cons key val) meta)))

;;; ── Transitive closure with proof traces ───────────────────────────────────
;;; Depth-bounded to prevent divergence. The bound is a concrete Scheme number
;;; checked at goal-construction time, so it doesn't interfere with search.

(define *default-max-depth* 10)

(define (transitive-o kb domain-name start-value end-value trace)
  "Transitive closure over hyperarcs sharing node values.
   start-value and end-value are node values (not full node S-expressions).
   trace is the list of node values visited: (start mid1 ... end).
   Two nodes are linked if they co-occur in the same hyperarc."
  (transitive-step kb domain-name start-value end-value trace *default-max-depth*))

(define (transitive-step kb domain-name start-val end-val trace depth)
  (if (= depth 0)
      fail
      (conde
       ;; Base case: start and end in the same directed hyperarc (head -> tail)
       ((fresh (mg arc n1 n2 id1 id2 m1 m2)
          (kb-o kb domain-name mg)
          (arcs-of-o mg arc)
          (directed-arc-o arc n1 n2)
          (node-o n1 id1 start-val m1)
          (node-o n2 id2 end-val m2)
          (== trace (list start-val end-val))))
       ;; Inductive case: follow a directed edge then recurse
       ((fresh (mg arc n1 n2 id1 id2 m1 m2 mid-val rest-trace)
          (kb-o kb domain-name mg)
          (arcs-of-o mg arc)
          (directed-arc-o arc n1 n2)
          (node-o n1 id1 start-val m1)
          (node-o n2 id2 mid-val m2)
          (transitive-step kb domain-name mid-val end-val rest-trace (- depth 1))
          (== trace (cons start-val rest-trace)))))))

;;; ── Proof trace utilities (pure Scheme) ────────────────────────────────────

(define (proof-steps trace)
  "The trace is already a list of node values — return it directly."
  trace)

(define (proof-length trace)
  "Number of edges (steps) in a proof trace."
  (if (null? trace) 0 (- (length trace) 1)))
