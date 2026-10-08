;;; federation-result.scm — federation-result as an actor (coinductive shape)
;;;
;;; Layer 0 landed ^plan-actor to make plans lazily traversable. This
;;; file takes the same move a level up: the federation-result itself
;;; can be an actor. Inline alist = inductive encoding (fields as data);
;;; actor = coinductive encoding (fields as observations). Same API
;;; local ($) and remote (<-).
;;;
;;; This is ADDITIVE — the existing substrate keeps producing and
;;; consuming alists. ^federation-result is for new callers who want
;;; the uniform-access property (especially across vats). The fr-*
;;; accessor family lets any consumer deal with either shape without
;;; caring which one came in.
;;;
;;; See docs/kan-comp/KAN.md for the underlying principle (every
;;; boundary is a place to flip from data to codata).
;;;
;;; Included into (playnet planner) umbrella; shares its imports.

;;; ── ^federation-result actor ──────────────────────────────────────────────
;;;
;;; Stores field values; exposes them as methods. Lazy fields
;;; (retraction-candidates, which may be a promise) are forced on
;;; access via force-or-self so consumers always see a materialised
;;; value. The plan field may be inline OR a ^plan-actor ref; 'plan
;;; returns it as-stored, 'plan-ref returns only if it's a ref.

(define-module (playnet deprecated planner relational federation-result)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet deprecated planner algorithms flow-graph)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib facet)
  #:use-module (playnet deprecated planner relational plan-walk)
  #:use-module (goblins actor-lib on)
  #:export (^federation-result spawn-federation-result federation-result->actor fr-get
            fr-scope fr-coherence fr-harmony fr-deficits fr-surpluses fr-residual
            fr-retraction-candidates fr-plan fr-plan-ref actor->federation-result
            *federation-result-methods-summary* *federation-result-methods-readable*
            ^federation-tree spawn-federation-tree ^federation-tree-async
            spawn-federation-tree-async spawn-federation-result-facet))

(define (^federation-result bcom
                            scope
                            coherence
                            harmony
                            deficits
                            surpluses
                            plan
                            retraction-candidates
                            residual)
  (methods
   ((scope)                  scope)
   ((coherence)              coherence)
   ((harmony)                harmony)
   ((deficits)               deficits)
   ((surpluses)              surpluses)
   ((plan)                   plan)
   ((plan-ref)               (and (live-refr? plan) plan))
   ((retraction-candidates)  (force-or-self retraction-candidates))
   ((residual)               residual)
   ((as-alist)
    ;; Reconstruct the classic alist shape. harmony is included only
    ;; when non-#f, matching the existing convention in
    ;; relational-plan->federation-result.
    (let ((base `((scope . ,scope)
                  (plan . ,plan)
                  (deficits . ,deficits)
                  (surpluses . ,surpluses)
                  (retraction-candidates . ,retraction-candidates)
                  (residual . ,residual)
                  (coherence . ,coherence))))
      (if harmony
          (cons `(harmony . ,harmony) base)
          base)))))


;;; ── Constructor (kwargs) ──────────────────────────────────────────────────

;; scope->debug-name lives in plan-walk.scm (loaded earlier in the
;; planner umbrella). Shared by all actors that want a refr-name label
;; derived from their scope-id.

(define* (spawn-federation-result
          #:key (scope #f)
                (coherence 1)
                (harmony #f)
                (deficits '())
                (surpluses '())
                (plan '())
                (retraction-candidates '())
                (residual 0))
  "Spawn a ^federation-result with named fields. Must be called inside
   a vat turn. Uses spawn-named so refr-name returns the scope label
   — appears in sever logs, error traces, and any debug output."
  (spawn-named (scope->debug-name scope)
               ^federation-result
               scope
               coherence
               harmony
               deficits
               surpluses
               plan
               retraction-candidates
               residual))


;;; ── Constructor (from alist) ──────────────────────────────────────────────
;;;
;;; Round-trips with as-alist: for any alist a produced by the existing
;;; substrate, (fr-as-alist (federation-result->actor a)) recovers the
;;; same fields (harmony inclusion matches input). Unknown keys in the
;;; input alist are dropped — ^federation-result only models the
;;; documented federation-result shape.

(define (federation-result->actor result)
  "Spawn a ^federation-result carrying RESULT's values. RESULT is an
   alist in the classic federation-result shape. Missing keys fall
   back to field defaults."
  (spawn-federation-result
    #:scope                 (assq-ref result 'scope)
    #:coherence             (or (assq-ref result 'coherence) 1)
    #:harmony               (assq-ref result 'harmony)
    #:deficits              (or (assq-ref result 'deficits) '())
    #:surpluses             (or (assq-ref result 'surpluses) '())
    #:plan                  (or (assq-ref result 'plan)
                                (assq-ref result 'plan-ref)
                                '())
    #:retraction-candidates (or (assq-ref result 'retraction-candidates)
                                '())
    #:residual              (or (assq-ref result 'residual) 0)))


;;; ── Dual-shape accessors: work on either alist or actor ref ──────────────
;;;
;;; The coinductive-boundary pattern shows up here as one decision:
;;; "if r is a ref, ask it; else read the alist." That's one helper,
;;; not six copy-pasted branches. Field-specific accessors wrap it
;;; for discoverability (named accessors grep nicely; macros don't).
;;;
;;; Near-only — uses `$` on refs. For cross-vat access, use `<-`
;;; directly on the ref (a `-vow` variant could be added if needed).

(define (fr-get r field)
  "Dual-shape field access: method call on refs, assq-ref on alists.
   Returns whatever the underlying source has for FIELD (#f if absent)."
  (if (live-refr? r) ($ r field) (assq-ref r field)))

(define (fr-scope r)     (fr-get r 'scope))
(define (fr-coherence r) (fr-get r 'coherence))
(define (fr-harmony r)   (fr-get r 'harmony))
(define (fr-deficits r)  (or (fr-get r 'deficits)  '()))
(define (fr-surpluses r) (or (fr-get r 'surpluses) '()))
(define (fr-residual r)  (or (fr-get r 'residual)  0))

(define (fr-retraction-candidates r)
  "Always returns a materialised list. Handles promises via
   force-or-self; actor-backed refs force internally, so the helper
   only needs to force in the alist-with-promise case."
  (if (live-refr? r)
      ($ r 'retraction-candidates)
      (force-or-self (assq-ref r 'retraction-candidates))))

(define (fr-plan r)
  "Return the inline plan content whatever the shape: inline alist,
   ^plan-actor ref, or legacy plan-ref field. Near-only."
  (let ((p (or (fr-get r 'plan)
               (and (not (live-refr? r)) (assq-ref r 'plan-ref)))))
    (cond
     ((not p) #f)
     ((live-refr? p) ($ p 'full))
     (else p))))

(define (fr-plan-ref r)
  "Return the ^plan-actor ref if the plan field holds one, else #f.
   Covers the actor shape (method returns #f if plan is inline) and
   both the unified alist (plan holds the ref) and legacy alist
   (separate plan-ref field)."
  (cond
   ((live-refr? r) ($ r 'plan-ref))
   (else
    (let ((p (or (assq-ref r 'plan)
                 (assq-ref r 'plan-ref))))
      (and p (live-refr? p) p)))))


;;; ── Round-trip helper ────────────────────────────────────────────────────

(define (actor->federation-result ref)
  "Return the federation-result alist stored in REF."
  ($ ref 'as-alist))


;;; ── Facets (capability attenuation) ──────────────────────────────────────
;;;
;;; Named presets for common attenuation patterns when handing a
;;; federation-result to a coordinator or external peer. Mirror the
;;; plan-actor facet design — methods-as-capabilities.
;;;
;;;   *federation-result-methods-summary* — what a parent federation
;;;       needs to aggregate (scalars + small lists). Omits 'plan and
;;;       'plan-ref so the plan itself isn't exposed.
;;;
;;;   *federation-result-methods-readable* — summary + 'plan and
;;;       'plan-ref for plan inspection. Consumer can traverse the
;;;       plan structure (possibly through a plan-ref facet of its
;;;       own for layered attenuation).

(define *federation-result-methods-summary*
  '(scope coherence harmony deficits surpluses residual retraction-candidates))

(define *federation-result-methods-readable*
  '(scope coherence harmony deficits surpluses residual retraction-candidates
    plan plan-ref as-alist))

;;; ── ^federation-tree — parent-level fractal composition ─────────────────
;;;
;;; A federation-tree is a parent scope whose "content" is its list of
;;; child federation-result (or federation-tree) refs. It implements
;;; the same method surface as ^federation-result — scope, coherence,
;;; harmony, deficits, surpluses, residual, retraction-candidates,
;;; plan, plan-ref, as-alist — but computes those values by
;;; aggregating over children on demand.
;;;
;;; The fractal property: since ^federation-tree and ^federation-result
;;; expose the same methods, a tree can itself be a child of another
;;; tree. Parents compose children uniformly regardless of whether
;;; each child is a leaf scope or another sub-federation. A parent
;;; never needs special logic for "is my child a leaf or another tree?"
;;;
;;; Deficits are tagged with the child's scope (like evaluate-state's
;;; collect-child-defs does for the sync federation substrate), so
;;; grandparents see per-child attribution all the way down.
;;;
;;; Sync-only for v1: uses $ on each child, which only works for near
;;; refs (local actors). Cross-vat children require async aggregation
;;; (methods returning vows). That's a reasonable next step once we
;;; actually federate across OCapN — for now, trees hold local refs.
;;;
;;; Additive to the existing substrate. evaluate-state / collect-child-*
;;; stay exactly as they are; ^federation-tree is a PARALLEL shape for
;;; callers who want the fractal actor pattern.

(define (^federation-tree bcom scope-id child-refs)
  (methods
   ((scope) scope-id)
   ((children) child-refs)
   ((subresult child-scope-id)
    (find (lambda (c) (equal? ($ c 'scope) child-scope-id))
          child-refs))
   ((deficits)
    ;; Tag each child's deficits with (child . cid) so grandparents
    ;; can attribute multi-level shortfalls back to the right scope.
    (append-map
      (lambda (c)
        (let ((cid ($ c 'scope)))
          (map (lambda (d)
                 (cons (cons 'child cid) d))
               ($ c 'deficits))))
      child-refs))
   ((surpluses)
    (append-map (lambda (c) ($ c 'surpluses)) child-refs))
   ((residual)
    (fold (lambda (c a) (+ a (or ($ c 'residual) 0))) 0 child-refs))
   ((coherence)
    (inexact-unless-int
      (cond
       ((null? child-refs) 1)
       (else
        (let ((cohs (filter-map
                      (lambda (c) ($ c 'coherence))
                      child-refs)))
          (if (null? cohs) 1
              (/ (apply + cohs) (length cohs))))))))
   ((harmony)
    ;; Sum `total` across children's harmony alists; preserve per-child
    ;; as a nested list for introspection. Returns #f if no child has
    ;; a harmony field.
    (let ((per-child (filter-map
                       (lambda (c)
                         (let ((h ($ c 'harmony)))
                           (and h (cons ($ c 'scope) h))))
                       child-refs)))
      (and (pair? per-child)
           `((total . ,(fold (lambda (pc a)
                               (+ a (or (assq-ref (cdr pc) 'total) 0)))
                             0 per-child))
             (per-child . ,per-child)))))
   ((retraction-candidates)
    (append-map
      (lambda (c) ($ c 'retraction-candidates))
      child-refs))
   ((plan)
    ;; The "plan" at a parent is an alist of child plans — same shape
    ;; as evaluate-state's `child-plans` in the sync federation. Each
    ;; entry is (child-scope . child-plan). Since children are always
    ;; ^federation-result or ^federation-tree refs (both implement
    ;; the `plan` method), this is a direct mapping — no defensive
    ;; catch needed. Fractal by construction: a child tree's `plan`
    ;; is itself an alist of its grandchildren.
    (map (lambda (c) (cons ($ c 'scope) ($ c 'plan))) child-refs))
   ((plan-ref) #f)
   ((as-alist)
    `((scope . ,scope-id)
      (plan . ,(map (lambda (c) (cons ($ c 'scope) ($ c 'plan))) child-refs))
      (deficits . ,(append-map
                     (lambda (c)
                       (let ((cid ($ c 'scope)))
                         (map (lambda (d) (cons (cons 'child cid) d))
                              ($ c 'deficits))))
                     child-refs))
      (surpluses . ,(append-map (lambda (c) ($ c 'surpluses)) child-refs))
      (retraction-candidates
        . ,(append-map (lambda (c) ($ c 'retraction-candidates))
                       child-refs))
      (residual . ,(fold (lambda (c a) (+ a (or ($ c 'residual) 0)))
                         0 child-refs))
      (coherence . ,(inexact-unless-int
                      (cond
                       ((null? child-refs) 1)
                       (else
                        (let ((cohs (filter-map
                                      (lambda (c) ($ c 'coherence))
                                      child-refs)))
                          (if (null? cohs) 1
                              (/ (apply + cohs) (length cohs))))))))))))


;;; Constructor (kwargs).

(define* (spawn-federation-tree #:key (scope #f) (children '()))
  "Spawn a ^federation-tree with SCOPE-ID and CHILDREN (list of refs).
   Must be called inside a vat turn. Uses spawn-named so the tree's
   refr-name is the scope label (visible in sever logs and debug)."
  (spawn-named (scope->debug-name scope)
               ^federation-tree scope children))


;;; ── ^federation-tree-async — cross-vat / OCapN-ready variant ─────────────
;;;
;;; Same method surface as ^federation-result, but works with children
;;; that may be near OR far. Aggregation methods return VOWS because
;;; `<-` is used uniformly — even for near children, this means one
;;; turn of indirection, but the API is uniform regardless of locality.
;;;
;;; Uses Goblins' actor-lib primitives to keep the implementation
;;; compact:
;;;   - `all-of*` (joiners) for parallel collection across children
;;;   - `let-on` (on) for concurrent multi-field fetch per child
;;;   - `<-` uniformly (Goblins flattens chains; near calls still work
;;;     correctly, just via a turn)
;;;
;;; The sync `^federation-tree` is still the right choice when all
;;; children are known to be near — it's direct-call fast. Use this
;;; async variant when children might be remote (OCapN federation).

(define (^federation-tree-async bcom scope-id child-refs)
  ;; Shared internal collectors — used both by methods and (as-alist).
  ;; Each is built atop `let-on` (one concurrent binding), which is
  ;; syntactic sugar for `(on vow handler #:promise? #t)` — so every
  ;; collector is a single binding + a pure reduction.
  (define (collect-residual)
    (let-on ((rs (all-of* (map (lambda (c) (<- c 'residual)) child-refs))))
      (fold + 0 rs)))
  (define (collect-coherence)
    (let-on ((cs (all-of* (map (lambda (c) (<- c 'coherence)) child-refs))))
      (inexact-unless-int
        (if (null? cs) 1 (/ (apply + cs) (length cs))))))
  (define (collect-surpluses)
    (let-on ((xss (all-of* (map (lambda (c) (<- c 'surpluses)) child-refs))))
      (apply append xss)))
  (define (collect-retraction-candidates)
    (let-on ((xss (all-of* (map (lambda (c) (<- c 'retraction-candidates))
                                child-refs))))
      (apply append xss)))
  (define (collect-deficits)
    ;; Inner let-on (per-child): fetch scope + deficits concurrently,
    ;; tag each deficit with (child . cid). Outer let-on: gather all
    ;; per-child lists and flatten.
    (let-on ((xss (all-of*
                   (map (lambda (c)
                          (let-on ((cid (<- c 'scope))
                                   (ds  (<- c 'deficits)))
                            (map (lambda (d) (cons (cons 'child cid) d)) ds)))
                        child-refs))))
      (apply append xss)))
  (define (collect-harmony)
    (let-on ((entries (all-of*
                       (map (lambda (c)
                              (let-on ((cid (<- c 'scope))
                                       (h (<- c 'harmony)))
                                (and h (cons cid h))))
                            child-refs))))
      (let ((per-child (filter identity entries)))
        (and (pair? per-child)
             `((total . ,(fold (lambda (pc a)
                                 (+ a (or (assq-ref (cdr pc) 'total) 0)))
                               0 per-child))
               (per-child . ,per-child))))))
  (define (collect-plan)
    (all-of*
      (map (lambda (c)
             (let-on ((cid (<- c 'scope))
                      (p (<- c 'plan)))
               (cons cid p)))
           child-refs)))

  (methods
   ((scope) scope-id)
   ((children) child-refs)
   ((subresult child-id)
    ;; Needs all child scopes to find the match — returns a vow.
    (let-on ((scopes (all-of* (map (lambda (c) (<- c 'scope)) child-refs))))
      (let loop ((cs child-refs) (ss scopes))
        (cond
         ((null? cs) #f)
         ((equal? (car ss) child-id) (car cs))
         (else (loop (cdr cs) (cdr ss)))))))
   ((residual)               (collect-residual))
   ((coherence)              (collect-coherence))
   ((deficits)               (collect-deficits))
   ((surpluses)              (collect-surpluses))
   ((retraction-candidates)  (collect-retraction-candidates))
   ((harmony)                (collect-harmony))
   ((plan)                   (collect-plan))
   ((plan-ref)               #f)
   ((as-alist)
    ;; Fetch everything concurrently via let-on, compose the alist.
    (let-on ((p     (collect-plan))
             (defs  (collect-deficits))
             (surps (collect-surpluses))
             (resid (collect-residual))
             (coh   (collect-coherence))
             (cands (collect-retraction-candidates))
             (harm  (collect-harmony)))
      (let ((base `((scope . ,scope-id)
                    (plan . ,p)
                    (deficits . ,defs)
                    (surpluses . ,surps)
                    (retraction-candidates . ,cands)
                    (residual . ,resid)
                    (coherence . ,coh))))
        (if harm (cons `(harmony . ,harm) base) base))))))


(define* (spawn-federation-tree-async #:key (scope #f) (children '()))
  "Spawn an ^federation-tree-async that works over OCapN. Children
   can be near or far refs; methods return vows uniformly. Use this
   when children might live on remote peers; use spawn-federation-tree
   when all children are known near (faster, sync returns)."
  (spawn-named (scope->debug-name scope)
               ^federation-tree-async scope children))


(define* (spawn-federation-result-facet result-ref
                                        #:optional
                                        (methods
                                         *federation-result-methods-summary*))
  "Attenuated view of RESULT-REF exposing only METHODS. Default is
   the summary set — parent-aggregation fields, no plan structure.
   Use *federation-result-methods-readable* to also expose the plan.
   Use a custom list for bespoke authority.

   Pattern for layered attenuation:
     (spawn-federation-result-facet
       (spawn-federation-result #:plan (spawn-plan-facet raw-plan)
                                ...)
       *federation-result-methods-readable*)
   — here the plan field itself is already an attenuated ref, so
   consumers who see 'plan get a restricted plan-ref."
  (apply facet result-ref methods))
