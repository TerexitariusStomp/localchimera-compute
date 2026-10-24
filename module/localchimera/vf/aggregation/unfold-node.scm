;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf/aggregation/unfold-node.scm — the fold's dual: one router for the descent.
;;;
;;; Everything the federation sends DOWN the scope tree is the same shape:
;;;
;;;     value  →  (own-part, child-id → child-part)
;;;
;;; the exact dual of fold-node.scm's `total = own ⊕ Σ children's totals`. A
;;; value enters at the root (a deployment of commitments, a round's shadow
;;; prices, disclosed budgets) and each node keeps its own part and hands every
;;; child exactly the child's slice. What differs between descents is only how
;;; a value SPLITS, so the tree lives here once and each descent is three small
;;; things: a SPLIT, a table of READS over the own-part, and a table of WRITES
;;; over the value.
;;;
;;; ── The split is where attenuation lives ───────────────────────────────────
;;;
;;; An edge carries exactly the child's slice, so identity SHEDS on the way
;;; down as it accumulates on the way up: a commitment naming a worker travels
;;; only along the path to the leaf it lands in, and an intermediate scope
;;; holds only what lands in its subtree. Restricting what reaches where is
;;; not a policy laid over the descent — it is what the split IS.
;;;
;;; ── The section law ties the two nodes together ────────────────────────────
;;;
;;; A split must be a SECTION of the corresponding fold's combine: re-folding
;;; the parts reconstructs the value,
;;;
;;;     own ⊕ part₁ ⊕ … ⊕ partₙ  =  value
;;;
;;; (`split-refold` computes the left side). Nothing is lost in routing and
;;; nothing is duplicated — the descent's twin of the fold's pull/push
;;; agreement, and just as testable.
;;;
;;; ── Children are REFS here, kept keyed ─────────────────────────────────────
;;;
;;; The fold pushes to ONE parent and keeps child VALUES; the descent pushes
;;; to MANY children and keeps child REFS — keyed, for the same reason: a
;;; departing subtree is dropped exactly (`drop-child`), and a refederation is
;;; again two messages (`unfold-node-reparent!`) plus a redeploy from whatever
;;; root's routing now covers the mover. What a dropped child was receiving
;;; falls back into its old parent's own-part — the router never invents a
;;; destination.
;;;
;;; ── Coalescing, mirrored ───────────────────────────────────────────────────
;;;
;;; A burst of values at the root would fan out once per write per level. With
;;; a schedule bound, a node parks the LATEST value and descends once — N
;;; writes cost N local splits at the root and ONE propagation per edge. The
;;; local sink still fires every time; only the fan-out is coalesced.
;;; (`make-fold-coalescer` serves both directions — a schedule is a schedule.)
;;;
;;; ── The pull is still the definition ───────────────────────────────────────
;;;
;;; A leaf's share is the split applied along the path from the root — so a
;;; node can `unfold-node-rebuild!` by asking its parent for `child-share` of
;;; its own id, and the standing state and the walk cannot disagree: there is
;;; only one split.

(define-module (localchimera vf aggregation unfold-node)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera utils hashmap)      ; hashmap-keys — children, kept keyed
  #:use-module (localchimera vf aggregation scope-tree)
  #:use-module (localchimera vf aggregation fold-node)
  #:export (make-split split-empty split-route
            route-by-key table-child-of split-refold
            ^unfold-node unfold-aggregate spawn-unfold-node
            unfold-node-reparent! unfold-node-rebuild!
            wire-unfold-parent!))

;;; ── splits ─────────────────────────────────────────────────────────────────

(define (make-split empty route) (cons empty route))
(define (split-empty s) (car s))
(define (split-route s) (cdr s))

(define (%parts split value child-ids)
  "Route VALUE over CHILD-IDS: (own . ((child-id . part) …)). A route is free
   to omit a child; readers default the missing part to the split's empty."
  ((split-route split) value child-ids))

(define (%part-of split parts id)
  (let ((p (assoc id (cdr parts))))
    (if p (cdr p) (split-empty split))))

(define* (route-by-key key-of child-of #:key (empty '()))
  "The split MOST descents are: a LIST of items (commitments, keyed cells —
   an alist is a list of pairs), each routed to the child that claims its key.

     KEY-OF    item → routing key (a plan id, a scope id, a cell's key)
     CHILD-OF  (key child-ids) → the child to hand it to, or #f for none

   An item no child claims stays in the own-part — the router never invents a
   destination — which is exactly what makes the section law hold: partition,
   then re-append, is the identity on the multiset."
  (make-split
   empty
   (lambda (value child-ids)
     (let loop ((items value) (own '()) (parts '()))
       (if (null? items)
           (cons (reverse own)
                 (map (lambda (id) (cons id (reverse (assoc-ref-or parts id '()))))
                      child-ids))
           (let* ((item (car items))
                  (dest (child-of (key-of item) child-ids)))
             (if (and dest (member dest child-ids))
                 (loop (cdr items) own
                       (acons dest (cons item (assoc-ref-or parts dest '())) parts))
                 (loop (cdr items) (cons item own) parts))))))))

;; alist-ref with a default, over an alist that may bind a key repeatedly —
;; the FIRST binding wins, which is why the router above conses the newest
;; accumulation to the front.
(define (assoc-ref-or alist key default)
  (let ((p (assoc key alist))) (if p (cdr p) default)))

(define (table-child-of table)
  "A CHILD-OF from a membership TABLE ((child-id . (key …)) …): the child
   whose key-list contains the key. The table is the caller's claim about the
   tree's shape — typically read off the same walk that seeds a fold — and
   updating it on refederation is part of the reparent, exactly as re-keying
   is on the fold side."
  (lambda (key child-ids)
    (let loop ((rows table))
      (cond ((null? rows) #f)
            ((and (member (caar rows) child-ids)
                  (member key (cdar rows)))
             (caar rows))
            (else (loop (cdr rows)))))))

(define (split-refold monoid split value child-ids)
  "The section law's left side: split VALUE, then re-fold own ⊕ parts with the
   corresponding fold MONOID. A lawful split satisfies

     (split-refold m s v ids)  ≡  v      (as the monoid's own equality)

   — for `route-by-key` over `list-monoid` that is multiset equality, and over
   `keyed-sum-monoid` it is equality of summed cells."
  (let ((parts (%parts split value child-ids)))
    (fold (monoid-combine monoid) (car parts) (map cdr (cdr parts)))))

;;; ── the node ───────────────────────────────────────────────────────────────

(define* (^unfold-node bcom split id value children callbacks
                       #:optional (reads '()) (writes '()))
  "A scope's place in a federation descent.

     SPLIT     how a value routes (empty . (value child-ids → own+parts))
     ID        this scope's key at its parent (what it asks `child-share` for)
     VALUE     the share this node has received
     CHILDREN  child-id → child NODE REF, kept keyed so a departing subtree is
               dropped exactly
     CALLBACKS `on-update` (a sink), `parent` (for the pull), late-bindable
     READS     method → (own-part . args) → value  — the domain's questions
     WRITES    method → (value . args) → new value — a transform, then descend

   Tree methods — unfold-value, unfold-own, child-share, set-value, add-child,
   drop-child, set-parent, set-id, set-split, set-on-update, set-schedule,
   flush — are
   named apart so a descent may call its reads anything."
  ;; the parked cell outlives each behaviour: slot 0 the value waiting to
  ;; descend, slot 1 the callbacks, slot 2 the children — 1 and 2 refreshed on
  ;; every behaviour change so a flush parked before a child arrived still
  ;; reaches the children that exist when it fires.
  (let ((parked (agg-ref callbacks 'parked)))
    (when parked
      (vector-set! parked 1 callbacks)
      (vector-set! parked 2 children)))
  (define (parts-for kids) (%parts split value (hashmap-keys kids)))
  (define (again value* children* callbacks*)
    (^unfold-node bcom split id value* children* callbacks* reads writes))
  (define (fan-out! v kids)
    (let ((parts (%parts split v (hashmap-keys kids))))
      (hashmap-fold (lambda (cid ref _acc)
                      ($ ref 'set-value (%part-of split parts cid))
                      #f)
                    #f kids)))
  ;; every new value tells the sink and hands each child ITS slice — never the
  ;; whole. The fan-out is coalesced when a schedule is bound.
  (define (descend! v kids)
    (let ((sched (agg-ref callbacks 'schedule))
          (parked (agg-ref callbacks 'parked)))
      (cond
       ((not (and sched parked)) (fan-out! v kids))
       ((vector-ref parked 0) (vector-set! parked 0 (cons v #t)))   ; in flight
       (else
        (vector-set! parked 0 (cons v #t))
        (sched (lambda ()
                 (let ((pv   (vector-ref parked 0))
                       (kids (or (vector-ref parked 2) kids)))
                   (vector-set! parked 0 #f)
                   (when pv (fan-out! (car pv) kids)))))))))
  (define* (changed value* children* #:optional (reply #f))
    (fire-update! callbacks value*)
    (descend! value* children*)
    (bcom (again value* children* callbacks) (if reply (reply value*) value*)))
  (lambda (msg . args)
    (case msg
      ;; ── the tree ──
      ((unfold-value) value)
      ((unfold-id)     id)
      ((unfold-parent) (agg-ref callbacks 'parent))
      ((unfold-own)   (car (parts-for children)))
      ((child-share)  (%part-of split (parts-for children) (car args)))
      ((set-value)    (changed (car args) children))
      ;; a child arrives and is handed its slice at once, so it is correct
      ;; from the moment of wiring; both arms are idempotent in the child.
      ((add-child)
       (let ((kids (hashmap-set children (car args) (cadr args))))
         ($ (cadr args) 'set-value (%part-of split (parts-for kids) (car args)))
         (bcom (again value kids callbacks))))
      ((drop-child)   (bcom (again value (hashmap-remove children (car args))
                                    callbacks)))
      ((set-parent)
       (let ((id* (if (pair? (cdr args)) (cadr args) id)))
         (bcom (^unfold-node bcom split id* value children
                             (set-callback callbacks 'parent (car args))
                             reads writes))))
      ((set-id)        (bcom (^unfold-node bcom split (car args) value children
                                           callbacks reads writes)))
      ;; routing is re-bindable, exactly as the parent is: a refederation's
      ;; other half is every ancestor whose table named the mover re-binding
      ;; its split, then a redeploy routing along the new tree.
      ((set-split)     (bcom (^unfold-node bcom (car args) id value children
                                           callbacks reads writes)))
      ((set-on-update) (bcom (again value children
                                    (set-callback callbacks 'on-update (car args)))))
      ((set-schedule)
       (bcom (again value children
                    (set-callback (set-callback callbacks 'schedule (car args))
                                  'parked (make-vector 3 #f)))))
      ((flush)
       (let* ((parked (agg-ref callbacks 'parked))
              (pv (and parked (vector-ref parked 0))))
         (when pv
           (vector-set! parked 0 #f)
           (fan-out! (car pv) children))
         (and pv #t)))
      ;; ── the descent ──
      (else
       (let ((r (assq msg reads)) (w (assq msg writes)))
         (cond (r (apply (cdr r) (car (parts-for children)) args))
               (w (changed (apply (cdr w) value args) children))
               (else (error "unfold-node: no method" msg))))))))

(define %unfold-node-seq 0)
(define* (%fresh-id #:optional (prefix "unfold"))
  (set! %unfold-node-seq (+ %unfold-node-seq 1))
  (string-append prefix "-" (number->string %unfold-node-seq)))

;;; ── a descent, as three small things ───────────────────────────────────────

(define* (unfold-aggregate split reads writes #:key (prefix "unfold"))
  "A descent's constructor, from its SPLIT, READS and WRITES — the dual of
   `fold-aggregate`, spawned the same way:

     (define ^deployment (unfold-aggregate deployment-split reads writes))"
  (lambda* (bcom value callbacks #:optional (id #f))
    (^unfold-node bcom split (or id (%fresh-id prefix))
                  value (hashmap) callbacks reads writes)))

(define* (spawn-unfold-node split #:key (id #f) (value #f) (parent #f)
                            (on-update #f) (reads '()) (writes '()))
  "Spawn a node for SPLIT. VALUE defaults to the split's empty — a node that
   has received nothing yet."
  (spawn ^unfold-node split (or id (%fresh-id))
         (if (eq? value #f) (split-empty split) value)
         (hashmap)
         (let* ((cb '())
                (cb (if parent (set-callback cb 'parent parent) cb))
                (cb (if on-update (set-callback cb 'on-update on-update) cb)))
           cb)
         reads writes))

;;; ── wiring, refederation, and the pull ─────────────────────────────────────

;; The parent handoff every descent shares: name the node at its parent, then
;; let the parent deliver the node's current slice, so the child is correct
;; from the moment of wiring rather than from the first deploy after it.
(define (wire-unfold-parent! node parent scope-id)
  (when scope-id ($ node 'set-id scope-id))
  (when parent
    ($ node 'set-parent parent scope-id)
    ($ parent 'add-child scope-id node)))

(define* (unfold-node-reparent! node id #:key (from #f) (to #f))
  "Move NODE (keyed ID) from parent FROM to parent TO: the old parent DROPS the
   child — what it was receiving falls back into the old parent's own-part —
   and the new one delivers the child's slice of ITS share at once. The routing
   tables behind each parent's split say who covers the mover; updating them is
   the reparent's other half, exactly as re-keying is on the fold side."
  (when from ($ from 'drop-child id))
  ($ node 'set-parent to id)
  (when to ($ to 'add-child id node)))

(define (unfold-node-rebuild! node)
  "Re-seed NODE from its parent's current share — the pull read as an
   operation. Lands on exactly the value the pushes would have delivered,
   because there is only one split. #f when the node has no parent."
  (let ((parent ($ node 'unfold-parent)))
    (and parent
         (begin ($ node 'set-value ($ parent 'child-share ($ node 'unfold-id)))
                #t))))
