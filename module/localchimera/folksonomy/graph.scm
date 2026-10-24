;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; folksonomy/graph.scm — The classification folksonomy as a weighted DAG.
;;;
;;; The structural twin of pools/availability-pool.scm. Where the labour
;;; pool folds each agent's availability-window into a per-scope <labour-pool>
;;; and propagates it up the federation tree, the folksonomy folds each AID's
;;; *structure edges* (broader → narrower over flat term-ids) into a per-scope
;;; <folksonomy> and propagates THAT up the same tree. A scope's taxonomy is
;;; the aggregate of its members' cuts, exactly as a scope's labour is the
;;; aggregate of its members' hours.
;;;
;;; The one difference from the labour pool: labour needs no dedup ("one
;;; agent, one availability, one entry"), but many AIDs assert the SAME
;;; (broader → narrower) edge — so the fold is *weighted*. Each distinct edge
;;; carries a COUNT and the SET of AIDs who asserted it (the doc's `{n, by}`).
;;; `pool-add`'s bare cons becomes `bump` keyed by the edge.
;;;
;;; Term-ids are FLAT and parent-independent (`term:grain`, never
;;; `food/grain`): identity is decoupled from filing, which is what lets the
;;; aggregate hold competing nestings of one term. See docs/planning/identity/folksonomy.md.

(define-module (localchimera folksonomy graph)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:export (make-folksonomy folksonomy?
            folksonomy-edges folksonomy-by-aid folksonomy-terms
            edge-broader edge-narrower edge-count edge-by
            folksonomy-set-aid folksonomy-drop-aid folksonomy-merge
            build-folksonomy
            folksonomy-children folksonomy-parents
            folksonomy-edge-count folksonomy-term-label
            folksonomy-template template->doc
            paths->seed-doc categories->seed-doc category-term?
            make-taxonomy-doc parse-taxonomy-doc))


;;; ── Weighted edge (the aggregate's unit) ────────────────────────────────────
;;; A distinct (broader → narrower) nesting and who/how-many asserted it.
;;; Stored as an alist so it round-trips through serdes untouched.

(define (make-edge broader narrower count by)
  `((broader . ,broader) (narrower . ,narrower) (count . ,count) (by . ,by)))

(define (edge-broader e)  (assq-ref e 'broader))
(define (edge-narrower e) (assq-ref e 'narrower))
(define (edge-count e)    (or (assq-ref e 'count) 0))
(define (edge-by e)       (or (assq-ref e 'by) '()))

(define (assq-ref alist key)
  (let ((p (assq key alist))) (if p (cdr p) #f)))

;; Flat term-ids never contain a tab, so it is a collision-free key separator.
(define (edge-key broader narrower) (string-append broader "\t" narrower))


;;; ── The aggregate ───────────────────────────────────────────────────────────
;;; edges   : hashmap edge-key → weighted edge          (the weighted DAG)
;;; by-aid  : hashmap aid → list of edge-keys it asserts (so ONE aid re-folds)
;;; terms   : hashmap term-id → label                    (the nodes' names)
;;;
;;; The by-aid index mirrors <labour-pool>'s `by-agent`: it is what makes an
;;; incremental `set-aid` (clear that AID's edges, re-add) cheap, exactly like
;;; the pool's `agent-changed`.

(define-record-type <folksonomy>
  (%make-folksonomy edges by-aid terms by-broader by-narrower)
  folksonomy?
  (edges       folksonomy-edges)
  (by-aid      folksonomy-by-aid)
  (terms       folksonomy-terms)
  ;; adjacency indexes: term-id → edge-keys where it is the broader / narrower.
  ;; Maintained incrementally (O(1) per edge created/destroyed, like by-aid), so
  ;; folksonomy-children/parents AND template extraction are index lookups, never
  ;; a scan of every edge. The analogue of the labour pool's by-cell index.
  (by-broader  folksonomy-by-broader)
  (by-narrower folksonomy-by-narrower))

(define (make-folksonomy)
  (%make-folksonomy (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

;; adjacency index helpers: id → list of edge-keys.
(define (adj-add adj id key) (hashmap-set adj id (cons key (hashmap-ref adj id '()))))
(define (adj-del adj id key)
  (let ((v (delete key (hashmap-ref adj id '()))))
    (if (null? v) (hashmap-remove adj id) (hashmap-set adj id v))))


;;; ── Drop one AID's whole contribution ───────────────────────────────────────
;;; Decrement the count and remove the AID from `by` on every edge it asserted;
;;; drop the edge entirely once no one asserts it. Mirrors the `cleared` fold
;;; at the head of the pool actor's `agent-changed`.

(define (folksonomy-drop-aid fk aid)
  (let ((keys (hashmap-ref (folksonomy-by-aid fk) aid '())))
    (if (null? keys)
        fk
        (let loop ((ks keys)
                   (edges (folksonomy-edges fk))
                   (byb   (folksonomy-by-broader fk))
                   (byn   (folksonomy-by-narrower fk)))
          (if (null? ks)
              (%make-folksonomy edges
                                (hashmap-remove (folksonomy-by-aid fk) aid)
                                (folksonomy-terms fk) byb byn)
              (let* ((k (car ks)) (e (hashmap-ref edges k #f)))
                (if (not e)
                    (loop (cdr ks) edges byb byn)
                    (let ((by* (delete aid (edge-by e)))
                          (n*  (max 0 (- (edge-count e) 1))))
                      (if (or (zero? n*) (null? by*))
                          ;; DESTROY: no one asserts it → drop edge + de-index
                          (loop (cdr ks) (hashmap-remove edges k)
                                (adj-del byb (edge-broader e) k)
                                (adj-del byn (edge-narrower e) k))
                          ;; decrement, edge stays (indexes unchanged)
                          (loop (cdr ks)
                                (hashmap-set edges k
                                  (make-edge (edge-broader e) (edge-narrower e) n* by*))
                                byb byn))))))))))


;;; ── Add one AID's contribution ──────────────────────────────────────────────

(define (merge-terms terms term-alist)
  "Fold (id . label) pairs into the term-label map. Latest non-empty label
   wins — labels are themselves folksonomic (a later slice votes on them)."
  (fold (lambda (pair t)
          (let ((id (car pair)) (label (cdr pair)))
            (if (and (string? label) (not (string-null? label)))
                (hashmap-set t id label)
                t)))
        terms term-alist))

(define (folksonomy-set-aid fk aid edges-list term-alist)
  "Re-fold AID's entire structure edge-set. EDGES-LIST is a list of
   (broader . narrower) pairs; TERM-ALIST a list of (id . label). Clears the
   AID's prior edges first, so republishing a smaller set drops the removed
   ones — the twin of the pool actor's clear-then-rebuild `agent-changed`."
  (let ((cleared (folksonomy-drop-aid fk aid)))
    (let loop ((prs   edges-list)
               (edges (folksonomy-edges cleared))
               (byb   (folksonomy-by-broader cleared))
               (byn   (folksonomy-by-narrower cleared)))
      (if (null? prs)
          (let ((new-keys (map (lambda (pr) (edge-key (car pr) (cdr pr))) edges-list)))
            (%make-folksonomy
             edges
             (if (null? new-keys)
                 (folksonomy-by-aid cleared)
                 (hashmap-set (folksonomy-by-aid cleared) aid
                              (delete-duplicates new-keys)))
             (merge-terms (folksonomy-terms cleared) term-alist)
             byb byn))
          (let* ((pr (car prs)) (b (car pr)) (n (cdr pr))
                 (k (edge-key b n)) (e (hashmap-ref edges k #f)))
            (cond
             ((not e)                          ; CREATE: new edge → index it
              (loop (cdr prs)
                    (hashmap-set edges k (make-edge b n 1 (list aid)))
                    (adj-add byb b k) (adj-add byn n k)))
             ((member aid (edge-by e))         ; idempotent per AID
              (loop (cdr prs) edges byb byn))
             (else                             ; another asserter (already indexed)
              (loop (cdr prs)
                    (hashmap-set edges k
                      (make-edge b n (+ 1 (edge-count e)) (cons aid (edge-by e))))
                    byb byn))))))))


;;; ── Merge: the taxonomy's ⊕ in the federation fold ───────────────────────────
;;; Two scopes' graphs combined into one. An edge's weight IS the set of AIDs
;;; asserting it, so the merge re-asserts every AID of B into A — one AID at a
;;; time, through the same `folksonomy-set-aid` an incremental publish uses.
;;; That makes it idempotent (an AID present in both is set once, not counted
;;; twice — a member of two federations does not get a louder voice; and where
;;; the two hold different documents the greater stands, below), and it
;;; keeps every index (by-aid, by-broader, by-narrower) correct by construction
;;; rather than by a parallel merge that could drift from set-aid's rules.
;;; See vf/aggregation/fold-node.scm for why a parent recombines rather than banks.

(define (aid-keys-beat? new old)
  "Whether one AID's edge-key set NEW stands over OLD when two graphs hold
   different documents for them: the greater in a total order on the sorted
   keys, so the choice is the same whichever graph is on which side."
  (let ((n (sort (map object->string new) string<?))
        (o (sort (map object->string old) string<?)))
    (let loop ((n n) (o o))
      (cond ((null? n) #f)
            ((null? o) #t)
            ((string<? (car n) (car o)) #f)
            ((string<? (car o) (car n)) #t)
            (else (loop (cdr n) (cdr o)))))))

;; Where the same AID stands in both graphs with different documents (a person
;; who published through two scopes), the document that stands is the greater in
;; a total order, never "the right operand": the merge is then commutative and
;; associative as well as idempotent, whichever order a parent combines its
;; children in.
(define (folksonomy-merge a b)
  (let ((b-edges (folksonomy-edges b))
        (a-by-aid (folksonomy-by-aid a))
        (b-terms (hashmap-fold (lambda (id label acc) (cons (cons id label) acc))
                               '() (folksonomy-terms b))))
    (hashmap-fold
     (lambda (aid keys acc)
       (let ((standing (hashmap-ref a-by-aid aid #f)))
         (if (and standing (not (aid-keys-beat? keys standing)))
             acc                                   ; A's document for this AID stands
             (folksonomy-set-aid
              acc aid
              (filter-map (lambda (k)
                            (let ((e (hashmap-ref b-edges k #f)))
                              (and e (cons (edge-broader e) (edge-narrower e)))))
                          keys)
              b-terms))))
     a (folksonomy-by-aid b))))


;;; ── Build from many AIDs ─────────────────────────────────────────────────────
;;; The twin of build-pool-from-agents: fold every member's doc into one graph.

(define (build-folksonomy aid+docs)
  "AID+DOCS: list of (aid . taxonomy-doc). Returns the aggregate <folksonomy>."
  (fold (lambda (pair fk)
          (let* ((aid (car pair))
                 (parsed (parse-taxonomy-doc (cdr pair))))
            (folksonomy-set-aid fk aid
                                (assq-ref parsed 'structure)
                                (assq-ref parsed 'terms))))
        (make-folksonomy) aid+docs))

(define (make-taxonomy-doc terms structure)
  "The taxonomy-<aid>.scm doc shape — the inverse of parse-taxonomy-doc, and the
   single source of the format for every producer (template->doc, paths->seed-doc,
   the browser's publish wire). TERMS: ((id . _) (label . _))…; STRUCTURE:
   ((broader . _) (narrower . _))…"
  (list (cons 'terms terms) (cons 'structure structure)))

(define (parse-taxonomy-doc doc)
  "Parse a taxonomy-<aid>.scm doc into ((terms . ((id . label)...))
   (structure . ((broader . narrower)...))). Tolerant of missing sections."
  (let* ((terms-sec  (or (assq-ref doc 'terms) '()))
         (struct-sec (or (assq-ref doc 'structure) '()))
         (terms  (map (lambda (t)
                        (cons (or (assq-ref t 'id) "")
                              (or (assq-ref t 'label) "")))
                      terms-sec))
         (edges  (filter-map
                  (lambda (e)
                    (let ((b (assq-ref e 'broader)) (n (assq-ref e 'narrower)))
                      (and (string? b) (string? n) (cons b n))))
                  struct-sec)))
    `((terms . ,terms) (structure . ,edges))))


;;; ── Read the aggregate ───────────────────────────────────────────────────────

(define (edges-at fk index term-id)
  (filter-map (lambda (k) (hashmap-ref (folksonomy-edges fk) k #f))
              (hashmap-ref (index fk) term-id '())))

(define (folksonomy-children fk term-id)
  "Weighted edges whose broader is TERM-ID (its candidate narrowings). O(1)+kids."
  (edges-at fk folksonomy-by-broader term-id))

(define (folksonomy-parents fk term-id)
  "Weighted edges whose narrower is TERM-ID (its competing nestings). O(1)+parents."
  (edges-at fk folksonomy-by-narrower term-id))

(define (folksonomy-edge-count fk broader narrower)
  (let ((e (hashmap-ref (folksonomy-edges fk) (edge-key broader narrower) #f)))
    (if e (edge-count e) 0)))

(define (folksonomy-term-label fk term-id)
  "Best-known label for TERM-ID; falls back to the id's last :-segment."
  (or (hashmap-ref (folksonomy-terms fk) term-id #f)
      (last-segment term-id)))

(define (last-segment id)
  (let ((parts (string-split id #\:)))
    (if (null? parts) id (last parts))))


;;; ── Extract a template (one legible cut of the DAG) ──────────────────────────
;;; The query, and the twin of pool-query: the aggregate is the many-parented
;;; DAG; a template is a spanning tree picking each term's MOST-asserted parent,
;;; with the winning counts riding along ("847 nest Grain under Food").
;;;
;;; LENS is an optional predicate aid→bool. The effective weight of an edge is
;;; the number of asserters who pass the lens, so "my friends' cut" /
;;; "this scope's cut" is just a different weighting of the same DAG — the CF
;;; control the doc wants, for free. Reading the aggregate AT a given scope is
;;; itself the coarsest lens; LENS refines within it.

(define* (folksonomy-template fk #:key (lens #f) (root-label "all"))
  (let* ((eff (lambda (e)
                (if lens (length (filter lens (edge-by e))) (edge-count e))))
         ;; every term mentioned as a broader, a narrower, or a named term —
         ;; read straight off the persistent adjacency indexes (no edge scan).
         (keys-of (lambda (idx) (hashmap-fold (lambda (k _v acc) (cons k acc))
                                              '() (idx fk))))
         (term-ids (delete-duplicates
                    (append (keys-of folksonomy-by-broader)
                            (keys-of folksonomy-by-narrower)
                            (keys-of folksonomy-terms))))
         ;; chosen : term → (broader-id . winning-weight), argmax over its
         ;; incoming edges (folksonomy-parents, an index lookup); ties break on
         ;; the smaller broader-id.
         (chosen (make-hash-table)))
    (for-each
     (lambda (t)
       (let ((best (fold (lambda (e b)
                           (let ((w (eff e)) (bid (edge-broader e)))
                             (cond ((<= w 0) b)
                                   ((not b) (cons bid w))
                                   ((> w (cdr b)) (cons bid w))
                                   ((and (= w (cdr b)) (string<? bid (car b)))
                                    (cons bid w))
                                   (else b))))
                         #f (folksonomy-parents fk t))))
         (when best (hash-set! chosen t best))))
     term-ids)
    (define (node t in-count path)           ; assemble t's subtree; guard cycles
      (if (member t path)
          #f
          (let ((cs (filter-map
                     (lambda (e)
                       (let* ((c (edge-narrower e)) (ch (hash-ref chosen c #f)))
                         ;; keep a child only where t is ITS chosen parent
                         (and ch (equal? (car ch) t)
                              (node c (cdr ch) (cons t path)))))
                     (folksonomy-children fk t))))
            `((id . ,t) (label . ,(folksonomy-term-label fk t))
              (count . ,in-count) (children . ,(sort-children cs))))))
    (let ((roots (filter (lambda (t) (not (hash-ref chosen t #f))) term-ids)))
      `((id . "all") (label . ,root-label) (count . 0)
        (children . ,(sort-children
                      (filter-map (lambda (t) (node t 0 '())) roots)))))))

(define (sort-children nodes)
  "Most-asserted first, then alphabetical — a stable, legible order."
  (sort nodes
        (lambda (a b)
          (let ((ca (or (assq-ref a 'count) 0)) (cb (or (assq-ref b 'count) 0)))
            (if (= ca cb)
                (string<? (or (assq-ref a 'label) "") (or (assq-ref b 'label) ""))
                (> ca cb))))))


;;; ── Adopt: the inverse of extraction (template → doc) ────────────────────────
;;; The loop the whole design turns on — "using is voting" — is doc → template
;;; (fold) and back, template → doc (adopt). This is the back arrow: the tree
;;; you SEE becomes the structure edges you'd ASSERT, in the exact
;;; taxonomy-<aid>.scm shape sync-taxonomy takes. So adopt-then-tweak-then-
;;; republish is one round trip through the SAME format, no separate "adopt"
;;; data path. Round-trips cleanly with parse-taxonomy-doc.

(define (template->doc tree)
  "Flatten a {id,label,children} template into a taxonomy doc
   ((terms (id . label)…) (structure (broader . narrower)…)). The synthetic
   \"all\" root contributes no term and no edge — its children are top-level."
  (let ((terms '()) (edges '()))
    (let walk ((n tree) (parent #f))
      (let ((id (assq-ref n 'id)))
        (unless (equal? id "all")
          (set! terms (cons `((id . ,id)
                              (label . ,(or (assq-ref n 'label) (last-segment id))))
                            terms))
          (when (and parent (not (equal? parent "all")))
            (set! edges (cons `((broader . ,parent) (narrower . ,id)) edges))))
        (for-each (lambda (c) (walk c id)) (or (assq-ref n 'children) '()))))
    (make-taxonomy-doc (reverse terms) (reverse edges))))


;;; ── Seed: bootstrap a first cut from legacy slash-path categories ────────────
;;; The doc's open question #5 — "what single structure contribution seeds a
;;; fresh commons?" — answered by the data already present: the dial's retiring
;;; `uri.split("/")` slash-paths. This is the ONE place slashes are honored, to
;;; migrate that stopgap onto real structure edges, then retire. Each path
;;; SEGMENT becomes a FLAT term-id (its own parent-independent identity);
;;; consecutive segments become broader→narrower edges. So "Food/Grain" and
;;; "Staples/Grain" both yield the one flat term "Grain" with TWO parents —
;;; competing nestings, exactly what the aggregate holds. (Membership stays
;;; coherent because a thing's own path-tags expand to the same flat segments.)

;; Mirrors the dial's NON_CATEGORY denylist (app.html __dialIngest): the
;; control-plane / config / flag tags that borrowed classifiedAs and must never
;; enter the folksonomy. Single-sourced here so the SEED can't pollute the graph
;; (the browser only ever sees the already-built template, not raw categories).
(define %non-category-prefixes '("tag:plan:" "tag:buffer:" "vf:allergen-free:"))
(define %non-category-exact
  '("communal" "individually-claimable" "individual claimable"
    "stationary" "isPrimary"))

(define (category-term? c)
  "True when C is a genuine classification, not a smuggled signal/flag tag."
  (and (string? c) (not (string-null? c))
       (not (member c %non-category-exact))
       (not (any (lambda (p) (string-prefix? p c)) %non-category-prefixes))))

(define (categories->seed-doc category-strings)
  "Filter CATEGORY-STRINGS to genuine categories, then bootstrap a seed doc.
   The gateway's entry point for seeding a scope's folksonomy from its specs'
   resource-classified-as at boot."
  (paths->seed-doc (filter category-term? category-strings)))

(define (paths->seed-doc category-strings)
  "A taxonomy doc (terms + structure) bootstrapped from slash-encoded CATEGORY
   strings. Flat segment term-ids; consecutive segments → broader edges."
  (let ((terms '()) (edges '()))
    (for-each
     (lambda (s)
       (let ((segs (filter (lambda (x) (not (string-null? x)))
                           (string-split s #\/))))
         (let loop ((prev #f) (ss segs))
           (unless (null? ss)
             (let ((seg (car ss)))
               (set! terms (cons `((id . ,seg) (label . ,seg)) terms))
               (when prev
                 (set! edges (cons `((broader . ,prev) (narrower . ,seg)) edges)))
               (loop seg (cdr ss)))))))
     category-strings)
    (make-taxonomy-doc (delete-duplicates (reverse terms))
                       (delete-duplicates (reverse edges)))))
