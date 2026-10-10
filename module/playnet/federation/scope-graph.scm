;;; federation/scope-graph.scm — in-memory scope topology
;;;
;;; A `^scope-graph` is the gateway-wide view of "which scopes exist,
;;; what kind are they, who is whose parent". Three maps:
;;;
;;;   kind-map     : aid → symbol ('commune | 'federation | 'universal-commune)
;;;   parents-map  : aid → hashmap[parent-aid → source]  (source = 'local | 'remote)
;;;   children-map : aid → hashmap[child-aid → #t]       (reverse index)
;;;
;;; Hydrated at gateway boot from the restored scopes, each spawned with
;;; the parents its own membership credentials name. Mutated reactively
;;; by `scope.scm` callsites (after admit-commune, remove-commune, and
;;; durable spawn) via `(<- (current-scope-graph) 'note-* …)` calls.
;;; Remote scopes feed in via `^remote-scope-poller` with `#:source 'remote`.
;;;
;;; Primary consumer: `^uc-curator` polls `(orphans)` to compute the
;;; Universal Commune's derived member set.
;;;
;;; Not durable. The graph is rehydratable from disk + ACDC queries on
;;; every boot, so a transient in-memory hashmap suffices.

(define-module (playnet federation scope-graph)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet utils boot-cell)
  #:use-module ((playnet scope actor) #:select (scope-spawned))   ;; load: the graph listens for every spawn
  #:use-module (srfi srfi-1)
  #:export (^scope-graph
            aggregating-parent
            current-scope-graph
            current-graph-vat
            in-graph-vat))

;;; Set by the gateway at boot; read from EVERY thread and vat turn —
;;; scope.scm's reactive hooks, the IPEX handlers, the notification
;;; poller, the solve-time demand fold. A BOOT CELL (utils/boot-cell.scm),
;;; NOT a parameter: a parameter set on the boot thread is invisible to
;;; vat threads and fibers — exactly where the readers run — so the
;;; hooks no-opped "gracefully" and the graph stayed silently empty on
;;; every live gateway. When unset (unit tests that don't wire a
;;; graph), the hooks still no-op gracefully.
(define current-scope-graph (make-boot-cell))

;;; The vat the graph (and all scope refs registered with it) lives in.
;;; Threads/fibers that aren't already in a vat — notably the KERIA
;;; notification poller — wrap Goblins calls in `(in-graph-vat …)` to
;;; enter the right vat for a turn. Same cell, same reason. Unset →
;;; in-graph-vat passes the thunk through (unit-test convenience; no
;;; vat needed for mock refs).
(define current-graph-vat (make-boot-cell))

(define (in-graph-vat thunk)
  "Run THUNK inside (current-graph-vat) if bound; otherwise call directly.
   Use this around any `$` or `<-` against the scope-graph from a
   non-vat thread."
  (let ((v (current-graph-vat)))
    (if v (with-vat v (thunk)) (thunk))))

;;; A scope that spawns (scope/actor.scm `spawn-scope`) is noted here with its
;;; KERIA alias, which the IPEX grant handler reads back (`get-aid-name`) to
;;; sign admit/spurn under the right local identity. Set at load: the actor's
;;; `scope-spawned` cell is the one it tells, and this module, which stands
;;; above the actor, is the one that listens. Unset graph: nothing to note.
(scope-spawned
 (lambda (aid kind ref aid-name)
   (let ((g (current-scope-graph)))
     (when g (<- g 'note-spawn aid kind '() #:ref ref #:aid-name aid-name)))))

;;; The reparent sink: (proc child parents-after) fired on every edge change
;;; the note-* hooks record — an admission's membership ACDC, a removal, a
;;; dissolution. One per process, like the cells above (the graph is
;;; gateway-wide), set through the actor's `set-on-reparent`. This is the
;;; whole bridge from the credential graph to any derived tree: the gateway
;;; points it at the planner's move-scope!, and the aggregation tree becomes
;;; a projection of the memberships. Unset → the hooks change nothing.
;;; Installing it replays every edge the graph holds, so a sink set after
;;; boot hydration sees the whole tree.
(define %on-reparent #f)

;;; THE parent a derived single-parent tree hangs a scope under when its
;;; membership credentials name several: the smallest AID in string order.
;;; A rule of the AIDs alone, so every consumer and every boot picks the
;;; same one whatever order the edges arrived in; the sink receives the
;;; parents already in this order. `resolve-multi-merge-ratifier`
;;; (universal-commune.scm) chooses among shared parents by this rule. #f with no parents.
(define (parents-in-order parents) (sort parents string<?))
(define (aggregating-parent parents)
  (and (pair? parents) (car (parents-in-order parents))))

(define* (^scope-graph bcom
                       #:optional
                       (kind-map      (hashmap))
                       (parents-map   (hashmap))
                       (children-map  (hashmap))
                       ;; refs-map     : aid → scope-ref         (local scopes only)
                       ;; aid-names-map: aid → KERIA aid-name    (local scopes only)
                       ;; Both populated by `note-spawn` and used by the IPEX
                       ;; grant handler to locate the right acdc-store and
                       ;; sign admit/spurn under the correct local AID.
                       (refs-map      (hashmap))
                       (aid-names-map (hashmap)))

  ;; ── Local helpers ──────────────────────────────────────────────────────
  ;; A "set" is encoded as a hashmap with #t values; this lets us reuse
  ;; the persistent-hashmap data structure for membership checks and
  ;; copy-on-write updates instead of pulling in another collection type.

  (define (parents-of aid)
    (hashmap-ref parents-map aid (hashmap)))

  (define (children-of aid)
    (hashmap-ref children-map aid (hashmap)))

  (define (hashmap->list hm)
    (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() hm))

  (define (hashmap-keys hm)
    (hashmap-fold (lambda (k _v acc) (cons k acc)) '() hm))

  ;; Tell the reparent sink CHILD's parent set is now what NP says. The sink
  ;; is how a consumer keeps a derived single-parent tree (the planner's
  ;; aggregation tree) projected off this credential graph — fired on every
  ;; edge change, after the maps are computed, never trusted to not throw.
  (define (fire-reparent! np child)
    (when %on-reparent
      (catch #t
        (lambda ()
          (%on-reparent child (parents-in-order
                               (hashmap-keys (hashmap-ref np child (hashmap))))))
        (lambda _ #f))))

  (define (hashmap-empty? hm)
    ;; `hashmap-size` isn't in (goblins utils hashmap); fold short-circuits
    ;; to #f on the first entry, leaves the seed #t otherwise.
    (hashmap-fold (lambda (_k _v _acc) #f) #t hm))

  ;; Add a parent link in both directions. Returns updated maps.
  (define (link! child parent source)
    (let* ((old-parents (parents-of child))
           (old-children (children-of parent))
           (new-parents  (hashmap-set parents-map child
                                      (hashmap-set old-parents parent source)))
           (new-children (hashmap-set children-map parent
                                      (hashmap-set old-children child #t))))
      (values new-parents new-children)))

  ;; Remove a parent link in both directions. If the child's parent-set
  ;; becomes empty we remove the entire entry rather than leave an
  ;; empty hashmap behind — keeps `(orphans)` cheap (absent-key check
  ;; instead of size check) and makes serialisation cleaner.
  (define (unlink! child parent)
    (let* ((old-parents  (parents-of child))
           (old-children (children-of parent))
           (without-p    (hashmap-remove old-parents parent))
           (without-c    (hashmap-remove old-children child))
           (new-parents  (if (hashmap-empty? without-p)
                             (hashmap-remove parents-map child)
                             (hashmap-set parents-map child without-p)))
           (new-children (if (hashmap-empty? without-c)
                             (hashmap-remove children-map parent)
                             (hashmap-set children-map parent without-c))))
      (values new-parents new-children)))

  (define* (rebuild new-kind new-parents new-children
                    #:optional
                    (new-refs      refs-map)
                    (new-aid-names aid-names-map))
    (^scope-graph bcom new-kind new-parents new-children
                  new-refs new-aid-names))

  (methods

    ;; ── orphans ───────────────────────────────────────────────────────────
    ;; List of AIDs that (a) have no parents recorded AND (b) are not the
    ;; UC itself. These are exactly the scopes the UC curator should admit.
    ((orphans)
     (hashmap-fold
      (lambda (aid kind acc)
        (cond
         ((eq? kind 'universal-commune) acc)       ; UC excludes itself
         ((hashmap-ref parents-map aid #f) acc)    ; has parents → not orphan
         (else (cons aid acc))))
      '() kind-map))

    ;; ── get-kind ──────────────────────────────────────────────────────────
    ((get-kind aid)
     (hashmap-ref kind-map aid #f))

    ;; ── get-parents ───────────────────────────────────────────────────────
    ;; Returns list of (parent-aid . source). Empty list when absent.
    ((get-parents aid)
     (hashmap->list (parents-of aid)))

    ;; ── get-children ──────────────────────────────────────────────────────
    ;; Returns list of child AIDs.
    ((get-children aid)
     (hashmap-keys (children-of aid)))

    ;; ── find-by-kind ──────────────────────────────────────────────────────
    ;; Filter all known scopes by kind. Used by gateway boot to locate
    ;; the existing UC, if any.
    ((find-by-kind k)
     (hashmap-fold
      (lambda (aid kind acc)
        (if (eq? kind k) (cons aid acc) acc))
      '() kind-map))

    ;; ── note-spawn ────────────────────────────────────────────────────────
    ;; Idempotent: re-noting a known AID overwrites kind and appends
    ;; (deduped) parents. Spawn-time parents may be empty; subsequent
    ;; `note-parent-link` calls add edges as federation membership is
    ;; granted. Parents named here reach the reparent sink like any other
    ;; edge: boot hydration spawns each restored scope with the parents its
    ;; credentials name, and the derived tree stands from the first turn.
    ;;
    ;; Trailing args are treated as keyword args (#:ref ref #:aid-name name)
    ;; for backward-compatibility with callers passing just (aid kind parents).
    ;; When provided, the ref + aid-name go into refs-map / aid-names-map so
    ;; the IPEX grant handler can look up "which local scope owns this AID."
    ((note-spawn aid kind parents . opts)
     (let* ((new-kind (hashmap-set kind-map aid kind))
            (kw-ref   (lambda (k default)
                        (let loop ((xs opts))
                          (cond ((or (null? xs) (null? (cdr xs))) default)
                                ((eq? (car xs) k) (cadr xs))
                                (else (loop (cddr xs)))))))
            (ref      (kw-ref #:ref #f))
            (aid-name (kw-ref #:aid-name #f))
            (new-refs (if ref (hashmap-set refs-map aid ref) refs-map))
            (new-aid-names (if aid-name
                               (hashmap-set aid-names-map aid aid-name)
                               aid-names-map)))
       (let loop ((ps parents) (np parents-map) (nc children-map))
         (cond
          ((null? ps)
           (when (pair? parents) (fire-reparent! np aid))
           (bcom (rebuild new-kind np nc new-refs new-aid-names) 'ok))
          (else
           (let* ((parent (car ps))
                  (np2    (hashmap-set np aid
                                       (hashmap-set
                                        (hashmap-ref np aid (hashmap))
                                        parent 'local)))
                  (nc2    (hashmap-set nc parent
                                       (hashmap-set
                                        (hashmap-ref nc parent (hashmap))
                                        aid #t))))
             (loop (cdr ps) np2 nc2)))))))

    ;; ── register-ref / find-ref / get-aid-name / has-aid? ─────────────────
    ;; Holder-AID → scope-ref / KERIA-aid-name lookup. Populated by
    ;; `note-spawn`'s #:ref and #:aid-name kwargs (preferred path), or
    ;; directly via `register-ref` when a scope is bound after spawn.

    ((register-ref aid ref aid-name)
     (let ((nr (if ref (hashmap-set refs-map aid ref) refs-map))
           (nn (if aid-name (hashmap-set aid-names-map aid aid-name)
                   aid-names-map)))
       (bcom (rebuild kind-map parents-map children-map nr nn) 'ok)))

    ((find-ref aid)        (hashmap-ref refs-map aid #f))
    ((get-aid-name aid)    (hashmap-ref aid-names-map aid #f))
    ((has-aid? aid)        (and (hashmap-ref kind-map aid #f) #t))

    ;; ── note-parent-link ──────────────────────────────────────────────────
    ;; Called from scope.scm `admit-commune` (federation issued a
    ;; membership ACDC) and from the remote poller after ACDC
    ;; verification. Source defaults to 'local; the poller overrides.
    ((note-parent-link child parent)
     (call-with-values (lambda () (link! child parent 'local))
       (lambda (np nc)
         (fire-reparent! np child)
         (bcom (rebuild kind-map np nc) 'ok))))

    ((note-parent-link-with-source child parent source)
     (call-with-values (lambda () (link! child parent source))
       (lambda (np nc)
         (fire-reparent! np child)
         (bcom (rebuild kind-map np nc) 'ok))))

    ;; the reparent sink (see %on-reparent above): the one bridge from this
    ;; credential graph to a derived tree. Every scope with parents is
    ;; replayed through the new sink, so the edges recorded before it was
    ;; installed (boot hydration) project too.
    ((set-on-reparent proc)
     (set! %on-reparent proc)
     (hashmap-fold (lambda (child _ acc) (fire-reparent! parents-map child) acc)
                   #f parents-map)
     'ok)

    ;; ── note-unlink ───────────────────────────────────────────────────────
    ;; Called from scope.scm `remove-commune`. If the child's parent set
    ;; becomes empty it returns to orphan status — the curator's next
    ;; tick will re-admit it to the UC.
    ((note-unlink child parent)
     (call-with-values (lambda () (unlink! child parent))
       (lambda (np nc)
         (fire-reparent! np child)
         (bcom (rebuild kind-map np nc) 'ok))))

    ;; ── note-decompose ────────────────────────────────────────────────────
    ;; A scope was split/dissolved. Drop it from all three maps; sever
    ;; every edge it participated in. The caller is responsible for
    ;; emitting `note-spawn` events for each successor (those flow
    ;; through the normal spawn path).
    ((note-decompose aid)
     (let* ((parents (parents-of aid))
            (children (children-of aid))
            ;; Remove this aid from every parent's children list.
            (nc1 (hashmap-fold
                  (lambda (parent _ nc)
                    (let* ((siblings (hashmap-ref nc parent (hashmap)))
                           (without  (hashmap-remove siblings aid)))
                      (if (hashmap-empty? without)
                          (hashmap-remove nc parent)
                          (hashmap-set nc parent without))))
                  children-map parents))
            ;; Remove this aid from every child's parents list. Children
            ;; whose only parent was `aid` become orphans, which is the
            ;; correct semantics for a dissolved federation.
            (np1 (hashmap-fold
                  (lambda (child _ np)
                    (let* ((parents-of-child (hashmap-ref np child (hashmap)))
                           (without          (hashmap-remove parents-of-child aid)))
                      (if (hashmap-empty? without)
                          (hashmap-remove np child)
                          (hashmap-set np child without))))
                  parents-map children))
            ;; Finally, drop the aid itself.
            (np2 (hashmap-remove np1 aid))
            (nc2 (hashmap-remove nc1 aid))
            (nk  (hashmap-remove kind-map aid))
            (nr  (hashmap-remove refs-map aid))
            (nn  (hashmap-remove aid-names-map aid)))
       ;; every child of the dissolved scope changed parents — tell the sink
       (hashmap-fold (lambda (child _ acc) (fire-reparent! np2 child) acc)
                     #f children)
       (bcom (rebuild nk np2 nc2 nr nn) 'ok)))

    ;; ── snapshot ──────────────────────────────────────────────────────────
    ;; Returns a serialisable snapshot for diagnostics / the /scopes
    ;; endpoint. Caller treats it read-only.
    ((snapshot)
     (list (cons 'kind-map     (hashmap->list kind-map))
           (cons 'parents-map  (hashmap->list parents-map))
           (cons 'children-map (hashmap->list children-map))))

    ;; ── all-aids ──────────────────────────────────────────────────────────
    ;; Just the AID list. Used by /scopes endpoint when consumer only
    ;; wants names.
    ((all-aids)
     (hashmap-keys kind-map))

    ;; ── count ─────────────────────────────────────────────────────────────
    ((count)
     (hashmap-fold (lambda (_k _v acc) (+ acc 1)) 0 kind-map))))
