;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; vf/aggregation/fold-node.scm — one aggregator for the whole federation fold.
;;;
;;; Everything the federation aggregates upward is the same shape:
;;;
;;;     total = own ⊕ Σ children's totals
;;;
;;; What differs between labour, taxonomy, demand and socialized capacity is
;;; only WHAT ⊕ is, what a scope's OWN contribution is made of, and what you
;;; can ask the total. So the tree lives here once and each aggregate is three
;;; small things: a MONOID, a table of READS over the total, and a table of
;;; WRITES over own.
;;;
;;;   labour     pools merged by (agent, skill)   reads: query, total-hours, …
;;;   taxonomy   graphs merged by asserting AID   reads: template, children, …
;;;   demand     quantities summed by cell        reads: the cells themselves
;;;   capacity   service facts summed by cell     (same monoid as demand)
;;;
;;; ── Why PUSH, and why children stay KEYED ──────────────────────────────────
;;;
;;; A scope forwards a TOTAL it computed itself; nothing reaches into a member's
;;; stores to read raw records. That is the aggregate's authority story (a parent
;;; never holds a child's plan-store). What a total DISCLOSES follows from what
;;; its reads must answer: demand and capacity answer "how much", so they cross
;;; as sums with no name in a key; labour answers "who can work where", so its
;;; pool crosses keyed by (agent, skill) — the roster the descent deploys;
;;; taxonomy crosses signed by asserting AID, because an assertion is testimony.
;;;
;;; The failure push has to survive is REFEDERATION. A commune leaves one
;;; federation for another; a merge constitutes a new parent (federation/
;;; universal-commune.scm, resolve-multi-merge-ratifier). If a parent MERGED each child's value
;;; into one aggregate on arrival, the departing child's contribution could
;;; never be found again — banked in a tree that no longer exists, dislodgeable
;;; only by a full rebuild. So a node keeps `child-id → that child's total`,
;;; KEYED, and combines only on read. Retraction is then deletion:
;;;
;;;   reparent := (old 'drop-child me) then (new 'child-changed me my-total)
;;;
;;; two messages, both exact, no reconciliation.
;;;
;;; ── Why a change does not cascade on every write ───────────────────────────
;;;
;;; A write recomputes this node and hands the parent a new total, which does
;;; the same, up to the root — so a BATCH of writes (a sync, a seed, a busy
;;; minute of people declaring needs) would re-fold every ancestor once per
;;; write. What each ancestor actually needs is the LAST total, once.
;;;
;;; So a node may be given a SCHEDULE callback: instead of forwarding upward
;;; inline, it parks the latest total and asks the schedule to flush it later.
;;; A second write while a flush is parked does not queue a second flush — it
;;; overwrites the parked value, so N writes cost N local re-folds and ONE
;;; propagation. The local sink still fires every time (a UI wants each change);
;;; it is only the climb that is coalesced. With no schedule bound the forward
;;; happens inline, which is the plain behaviour everything had before.
;;;
;;; ── Why the PULL is still here ─────────────────────────────────────────────
;;;
;;; `fold-tree-total` over a walked tree and a node's standing total are the
;;; same value, because they are the same monoid folded in a different order —
;;; which is what associativity and commutativity buy. So the pull is the
;;; fold's DEFINITION and the push its incremental evaluation: `rebuild!`
;;; re-seeds a node from the walk, and that is how a freshly-constituted root
;;; gets its first value. They cannot disagree; there is only one combine.

(define-module (localchimera vf aggregation fold-node)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera utils hashmap)      ; hashmap-values — children, kept keyed
  #:use-module (localchimera vf aggregation scope-tree)
  #:export (make-monoid monoid-empty monoid-combine
            merge-by-key sum-by-key sum-cells list-monoid keyed-monoid keyed-sum-monoid
            ^fold-node fold-aggregate spawn-fold-node
            fold-node-reparent! fold-node-rebuild!
            make-fold-coalescer fold-tree-total
            wire-fold-parent!))

;;; ── monoids ────────────────────────────────────────────────────────────────

(define (make-monoid empty combine) (cons empty combine))
(define (monoid-empty m) (car m))
(define (monoid-combine m) (cdr m))

;; The keyed sum, which is what MOST of the federation's aggregates are: an
;; alist of (key . number) where the same key appearing twice means one pool of
;; that much. Ten people wanting a loaf in one place is demand for ten loaves
;; there; two members lending 20 and 12 hours of a lathe in one place is one
;; pool of 32. Order is by first appearance, so a solve reads stable keys.
(define (merge-by-key combine a b)
  "One cell per key over A then B: a key's first value stands, and a later
   value of the same key is COMBINE'd into it. The keyed sum is this with +;
   a keyed fold with any associative, commutative COMBINE is a monoid by the
   same construction, so a domain whose cells are records (a reading's count,
   sum, extrema and freshest value) folds up the tree exactly as a sum does."
  (let ((cells (make-hash-table)) (order '()))
    (for-each (lambda (p)
                (let ((cur (hash-ref cells (car p) #f)))
                  (if cur
                      (hash-set! cells (car p) (cons #t (combine (cdr cur) (cdr p))))
                      (begin (set! order (cons (car p) order))
                             (hash-set! cells (car p) (cons #t (cdr p)))))))
              (append a b))
    (map (lambda (k) (cons k (cdr (hash-ref cells k)))) (reverse order))))

(define (sum-by-key a b) (merge-by-key + a b))

(define (keyed-monoid combine) (make-monoid '() (lambda (a b) (merge-by-key combine a b))))
(define keyed-sum-monoid (keyed-monoid +))
(define list-monoid      (make-monoid '() append))

;; One list of cells, with its own duplicates pooled — the same combine read as
;; a normalisation rather than a merge. `(sum-by-key '() cells)` says the same
;; thing and reads like a mistake.
(define (sum-cells cells) (sum-by-key '() cells))

;;; ── the node ───────────────────────────────────────────────────────────────

(define* (^fold-node bcom monoid id own children callbacks
                     #:optional (reads '()) (writes '()))
  "A scope's place in the federation fold.

     MONOID    what a scope's value is combined WITH (empty . combine)
     ID        this scope's key at its parent
     OWN       what this scope contributes itself
     CHILDREN  child-id → that child's total, KEPT KEYED so a departing
               subtree is dropped exactly rather than subtracted
     CALLBACKS `on-update` (a sink) and `parent` (the node above), late-bindable
     READS     method → (total . args) → value      — the domain's questions
     WRITES    method → (own . args) → new own      — the domain's local refold
               (or (refold . reply) where reply is (new-total → value), for a
               write whose caller wants an answer rather than the total)

   The tree's own methods are named apart — fold-total, fold-own, child-totals,
   child-total, set-own, child-changed, drop-child, set-parent, set-id,
   set-on-update — so an aggregate is free to call its reads anything (the
   taxonomy really does want a `children`, and it means term children). An
   actor is a procedure, so dispatch falls through to the tables."
  ;; The parked cell is shared mutable state that OUTLIVES each behaviour: slot
  ;; 0 is the total waiting to climb, slot 1 the callbacks to climb through.
  ;; Slot 1 is refreshed on every rebuild because a flush parked before
  ;; `set-parent` would otherwise fire through the callbacks of a node that had
  ;; no parent yet — parking at seed time and gaining a parent afterwards is the
  ;; ordinary wiring order, not an edge case.
  (let ((parked (agg-ref callbacks 'parked)))
    (when parked (vector-set! parked 1 callbacks)))
  (define (total)
    (fold (monoid-combine monoid) own (hashmap-values children)))
  (define (again own* children* callbacks*)
    (^fold-node bcom monoid id own* children* callbacks* reads writes))
  ;; every change recomputes, tells the sink, and hands the parent this node's
  ;; new TOTAL — never the raw event that caused it. The climb upward is
  ;; coalesced when a schedule is bound (see the note above): the latest total
  ;; is parked, and a flush already in flight simply carries the newer value.
  (define (climb! t)
    (let ((sched (agg-ref callbacks 'schedule))
          (parked (agg-ref callbacks 'parked)))
      (cond
       ((not (and sched parked)) (forward-up! callbacks 'child-changed id t))
       ((vector-ref parked 0) (vector-set! parked 0 (cons t #t)))   ; already in flight
       (else
        (vector-set! parked 0 (cons t #t))
        (sched (lambda ()
                 (let ((v (vector-ref parked 0))
                       (cb (or (vector-ref parked 1) callbacks)))
                   (vector-set! parked 0 #f)
                   (when v (forward-up! cb 'child-changed id (car v))))))))))
  (define* (changed own* children* #:optional (reply #f))
    (let ((t (fold (monoid-combine monoid) own* (hashmap-values children*))))
      (fire-update! callbacks t)
      (climb! t)
      (bcom (again own* children* callbacks) (if reply (reply t) t))))
  (lambda (msg . args)
    (case msg
      ;; ── the tree ──
      ((fold-total)  (total))
      ((fold-own)    own)
      ((child-totals) children)
      ((child-total)  (hashmap-ref children (car args) (monoid-empty monoid)))
      ((set-own)      (changed (car args) children))
      ;; a member's total arrived, or a member left. Both are idempotent in the
      ;; member — the same total twice, or dropping an absent child, changes
      ;; nothing — which is what lets a node be re-seeded, replayed or
      ;; re-parented without drift.
      ((child-changed) (changed own (hashmap-set children (car args) (cadr args))))
      ((drop-child)    (changed own (hashmap-remove children (car args))))
      ((set-parent)
       ;; an optional second argument names this node at its new parent; a tree
       ;; wired without ids gets a distinct one per node so two children never
       ;; collide on #f
       (let ((id* (if (pair? (cdr args)) (cadr args) id)))
         (bcom (^fold-node bcom monoid id* own children
                           (set-callback callbacks 'parent (car args))
                           reads writes))))
      ((set-id)        (bcom (^fold-node bcom monoid (car args) own children
                                         callbacks reads writes)))
      ((set-on-update) (bcom (again own children
                                    (set-callback callbacks 'on-update (car args)))))
      ;; bind the coalescer: SCHEDULE is (thunk → ·), called at most once per
      ;; burst of writes. `flush` runs any parked climb now, for a caller that
      ;; wants the tree settled before it reads the root.
      ((set-schedule)
       (bcom (again own children
                    (set-callback (set-callback callbacks 'schedule (car args))
                                  'parked (make-vector 2 #f)))))
      ((flush)
       (let* ((parked (agg-ref callbacks 'parked))
              (v (and parked (vector-ref parked 0))))
         (when v
           (vector-set! parked 0 #f)
           (forward-up! callbacks 'child-changed id (car v)))
         (and v #t)))
      ;; ── the aggregate ──
      (else
       (let ((r (assq msg reads)) (w (assq msg writes)))
         (cond (r (apply (cdr r) (total) args))
               (w (let* ((spec  (cdr w))
                         (refold (if (pair? spec) (car spec) spec))
                         (reply  (and (pair? spec) (cdr spec))))
                    (changed (apply refold own args) children reply)))
               (else (error "fold-node: no method" msg))))))))

(define %fold-node-seq 0)
(define* (%fresh-id #:optional (prefix "fold"))
  (set! %fold-node-seq (+ %fold-node-seq 1))
  (string-append prefix "-" (number->string %fold-node-seq)))

;;; ── an aggregate, as three small things ────────────────────────────────────

(define* (fold-aggregate monoid reads writes #:key (prefix "fold"))
  "An aggregate's constructor, from its MONOID, READS and WRITES. The result is
   an actor constructor of the ordinary shape — (bcom own callbacks [id]) — so
   it is spawned like any other actor and nothing about the tree needs saying
   at each site:

     (define ^labour-pool (fold-aggregate labour-monoid labour-reads labour-writes))

   An unnamed node gets a distinct id, so a tree wired without scope ids still
   keys its children apart instead of collapsing them onto one."
  (lambda* (bcom own callbacks #:optional (id #f))
    (^fold-node bcom monoid (or id (%fresh-id prefix))
                own (hashmap) callbacks reads writes)))

(define* (spawn-fold-node monoid #:key (id #f) (own #f) (parent #f) (on-update #f)
                          (reads '()) (writes '()))
  "Spawn a node for MONOID. ID names it at its parent — defaulted to a distinct
   value so an unnamed tree still keys its children apart."
  (spawn ^fold-node monoid (or id (%fresh-id))
         (if (eq? own #f) (monoid-empty monoid) own)
         (hashmap)
         (let* ((cb '())
                (cb (if parent (set-callback cb 'parent parent) cb))
                (cb (if on-update (set-callback cb 'on-update on-update) cb)))
           cb)
         reads writes))

;;; ── the coalescer ──────────────────────────────────────────────────────────

(define (make-fold-coalescer)
  "A schedule to hand nodes (`set-schedule`) plus the DRAIN that runs what they
   parked. Every node in a tree can share one: a burst of writes anywhere in it
   parks at most one climb per node, and one drain settles the whole thing.

   Returns (values schedule drain!). Call drain! when a batch is done — at the
   end of a turn, before a solve reads the root, after a sync. Draining is
   itself a batch: a node's climb wakes its parent, which parks in turn, so the
   drain loops until the tree is quiet."
  (let ((queue '()))
    (values
     (lambda (thunk) (set! queue (cons thunk queue)))
     (lambda ()
       (let loop ((n 0))
         (let ((pending (reverse queue)))
           (set! queue '())
           (cond ((null? pending) n)
                 ((> n 64) n)                  ; a cycle would otherwise spin
                 (else (for-each (lambda (t) (t)) pending)
                       (loop (+ n 1))))))))))

;;; ── refederation, as two exact messages ────────────────────────────────────

(define* (fold-node-reparent! node id #:key (from #f) (to #f))
  "Move NODE (whose key is ID) from parent FROM to parent TO. The old parent
   DROPS the child — deletion, not subtraction, so nothing of the subtree is
   left behind — and the new one receives its total. Either may be #f (leaving
   the tree, or joining it from nowhere). This is the whole cost of a
   refederation: no rebuild, no reconciliation, nothing to replay."
  (when from ($ from 'drop-child id))
  ($ node 'set-parent to id)
  (when to ($ to 'child-changed id ($ node 'fold-total))))

;;; ── the pull: the same fold, as a definition ───────────────────────────────

(define (fold-tree-total monoid scope own-of)
  "The fold read straight off the live tree: SCOPE's own value combined with
   its members' recursively, one visit per scope. This is what a node's
   standing total MEANS — same monoid, different association order — so it is
   both the specification the push is checked against and the way a node is
   seeded. OWN-OF is (scope-root → value)."
  (fold (monoid-combine monoid) (monoid-empty monoid)
        (scope-subtree-values scope own-of)))

;; The parent handoff every wire shares (labour, demand, means): name the node
;; at its parent, then deliver the current total so the parent is correct from
;; the moment of wiring rather than from the first change after it.
(define (wire-fold-parent! node parent scope-id)
  (when scope-id ($ node 'set-id scope-id))
  (when parent
    ($ node 'set-parent parent (or scope-id ($ node 'fold-own)))
    ($ parent 'child-changed (or scope-id ($ node 'fold-own)) ($ node 'fold-total))))

(define (fold-node-rebuild! node monoid scope own-of)
  "Re-seed NODE's OWN value from the live tree beneath SCOPE. The escape hatch
   for a node that was never wired, a boot, or a subtree whose incremental path
   was interrupted — and it lands on exactly the value the increments would
   have, because there is only one combine."
  ($ node 'set-own (fold-tree-total monoid scope own-of)))
