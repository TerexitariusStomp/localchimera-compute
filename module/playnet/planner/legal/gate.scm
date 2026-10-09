;;; legal/gate.scm — the bridge: build the planner's `#:legal-forbids?`
;;; predicate from a scope's REAL stores + a ^legal-registry actor.
;;;
;;; This is where the legal layer GELS with the planner (legal-crossings.md §6):
;;;
;;;   recipe-store ─flows-for-process→ <recipe-flow>s
;;;     → legal/crossings.scm  recipe-crossings   (derived from the flows ∪ declared by tag)
;;;   spatial-thing-store ─resolve-chain→ the jurisdiction path
;;;     → legal-context (an arc-capable context)
;;;   ^legal-registry ─forbids?→ a possibility-tension
;;;     → the planner's `runnable` guard prunes the column.
;;;
;;; Pass the result as `plan-scope #:legal-forbids?`. Nothing is hand-listed:
;;; the crossings come off the REAL recipe records, the path off the REAL
;;; contained-in tree, the demand off the REAL rule registry.
;;;
;;; Run:  guile -L . module/playnet/planner/legal/gate.scm   (self-test)

(define-module (playnet planner legal gate)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner facts located) #:select (place-of))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet planner aggregation containment)
  #:use-module ((playnet planner facts places) #:select (place-parent-of place-extra-ref))
  #:use-module ((playnet planner legal policy) #:select (*legal-policy-defaults*))
  #:export (legal-cell-place legal-proc-flows process-crossings store-crossings make-legal-gate
            legal-asset-fields legal-agent-fields legal-assets-at legal-agents-of spatial-path-reader
            legal-licence-skill legal-bill->decoration make-legal-decorate
            %uncertain-forbid-profile)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet planner legal crossings)
  #:use-module (playnet planner legal registry-actor))


;;; a located cell is "place@period" — the jurisdiction is its place (located.scm)
(define (legal-cell-place cell) (if (string-index cell #\@) (place-of cell) cell))

;;; flat flow list for a process, from the recipe store (flows-for-process
;;; returns (inputs . outputs)).
(define (legal-proc-flows recipe-store proc-id)
  (let ((fp ($ recipe-store 'flows-for-process proc-id)))
    (cond ((pair? fp) (append (if (list? (car fp)) (car fp) '())
                              (if (list? (cdr fp)) (cdr fp) '())))
          (else '()))))

;;; ─── the things and the holders : what a guard may see of them ──────────
;;; A guard reads an asset or an agent as an alist of its VF RECORD FIELDS,
;;; under the schema's own names — no vocabulary of its own. The one derived
;;; entry is `contained-in`: the CLIMBED chain of container ids, nearest first
;;; (aggregation/containment.scm), the resource twin of `place-path`, so
;;; "inside a sealed container, however deep" is one `asset-has`. The resource's
;;; `current-location` is where its chain finally says it is (the engine's
;;; `resource-place` reading): a contained resource sits where its container sits.
(define (legal-asset-fields r resolve)
  (let* ((chain (containment-chain r #:parent-of economic-resource-contained-in
                                     #:resolve resolve))
         (place (containment-first r economic-resource-current-location
                                   #:parent-of economic-resource-contained-in
                                   #:resolve resolve)))
    `((id                 . ,(economic-resource-id r))
      (conforms-to        . ,(economic-resource-conforms-to r))
      (classified-as      . ,(or (economic-resource-classified-as r) '()))
      (contained-in       . ,(map economic-resource-id chain))
      (current-location   . ,place)
      (custodian-scope    . ,(economic-resource-custodian-scope r))
      (primary-accountable . ,(economic-resource-primary-accountable r))
      (rented?            . ,(resource-rented? r))   ; custody and rights apart
      (state              . ,(economic-resource-state r))
      (stage              . ,(economic-resource-stage r)))))

(define (legal-agent-fields ag)
  `((id               . ,(agent-id ag))
    (type             . ,(agent-type ag))
    (classified-as    . ,(or (agent-classified-as ag) '()))
    (primary-location . ,(agent-primary-location ag))))

;;; ── ONE climb, two sources ────────────────────────────────────────────────
;;; A scope's own `^spatial-thing-store` holds the places it is accountable for.
;;; The knowledge layer's shared tree (`knowledge/places.scm`) holds jurisdictions
;;; as knowledge — the world, the nations, whatever a context pack taught it.
;;; Where the scope's own climb ENDS, the shared one continues.
;;;
;;; This is a correctness guard, not a second source of truth. A missing place
;;; fails SILENTLY and in the dangerous direction: the climb stops short, the
;;; guard never sees the jurisdiction, and the law simply does not apply. It also
;;; keeps the two readers of the same law honest with each other —
;;; `knowledge/law-snapshot-build.scm` builds the law face's path with
;;; `place-parent-of` over the shared tree while this gate walks the store, and
;;; before the fall-through they could disagree about what a place stands under.
;;;
;;; Read once per place per solve: the decorate closure is built once per solve,
;;; so a memo living in it is exactly per-solve — a scope with many resources
;;; under many crossings asks once per place, not once per (process, cell,
;;; resource).
(define (shared-jurisdiction-tail id seen)
  "The shared tree's climb ABOVE ID, skipping anything already in SEEN."
  (let loop ((p (and id (place-parent-of id))) (acc '()) (seen seen))
    (if (or (not p) (member p seen))
        (reverse acc)
        (loop (place-parent-of p) (cons p acc) (cons p seen)))))

(define (one-path spatial-thing-store place)
  "PLACE's own containment chain, self first — the scope's store as far as it
   goes, then the shared jurisdiction tree. Where the store's last place names a
   parent the store does not hold (a person's own place, standing in a
   jurisdiction only the shared tree knows), the climb steps onto that parent
   and goes on from there."
  (let* ((chain ($ spatial-thing-store 'resolve-chain place))
         (own   (if (pair? chain) (map spatial-thing-id chain) (list place)))
         (step  (and (pair? chain)
                     (let ((up (spatial-thing-contained-in (last chain))))
                       (and up (not (member up own)) up))))
         (own   (if step (append own (list step)) own)))
    (append own (shared-jurisdiction-tail (last own) own))))

;;; ── the OTHER regimes a place stands in : `within` ────────────────────────
;;; `contained-in` is single-parent, and rightly: a place is physically inside
;;; exactly one thing. But a place STANDS IN several regimes at once that do not
;;; nest with each other — a commune can sit in three overlapping SAGE water
;;; perimeters, an AOC, and a biosphere reserve's transition zone, none of which
;;; contains any other. Each of those regimes IS a hierarchy of its own (a SAGE
;;; sits in a basin; a communal appellation sits in a regional one), so a flat
;;; tag cannot answer "is this in the Adour-Garonne basin?" without writing every
;;; ancestor onto every leaf — the denormalisation legal-crossings.md §0 exists
;;; to avoid.
;;;
;;; So a place may declare `(within . (id …))` among its extras: other places it
;;; also stands in. Each becomes ANOTHER ENDPOINT, climbed by the very same
;;; `contained-in` walk — and `<legal-context>` already unions endpoints, so
;;; `in-jurisdiction` reaches an ancestor of any regime with no new guard form,
;;; no new record field and no change to the fold. It is the same mechanism that
;;; already wraps a transport arc in both its jurisdictions' rules.
;;;
;;; The same door carries a cell that straddles a line — a parcel cut by a zone
;;; boundary is two endpoints, exactly as an arc is.
;;;
;;; The walk itself is `regime-endpoints` (legal/registry.scm), shared with the
;;; law face's fold; this gate hands it the scope's own climb.
(define (endpoints-for spatial-thing-store place)
  (regime-endpoints place (lambda (p) (one-path spatial-thing-store p))))

(define (spatial-path-reader spatial-thing-store)
  "place → the LIST of endpoint paths that place stands in, nearest first. The
   first is always its own containment chain; the rest are its `within` regimes."
  (let ((memo (make-hash-table)))
    (lambda (place)
      (or (hash-ref memo place)
          (let ((eps (endpoints-for spatial-thing-store place)))
            (hash-set! memo place eps)
            eps)))))

;;; the assets an activity touches at a cell: every resource the observer holds
;;; that conforms to one of the process's flow specs and sits at the cell's
;;; place — or anywhere under it, read off the spatial chain the jurisdiction
;;; path already walks. No observer ⇒ none, and every asset guard stays silent.
(define (legal-assets-at observer path-of flows place)
  (if (not observer) #f                 ; nobody looked: unknown, not none
      (let* ((specs   (delete-duplicates
                       (filter-map recipe-flow-resource-conforms-to flows)))
             (resolve (lambda (id) ($ observer 'get-resource id)))
             ;; a resource is under the cell when the cell's place appears in ANY
             ;; of the chains its own place stands in
             (under?  (lambda (p) (and p (any (lambda (pt) (member place pt)) (path-of p)) #t))))
        (filter-map
         (lambda (r)
           (and (member (economic-resource-conforms-to r) specs)
                (let ((fields (legal-asset-fields r resolve)))
                  (and (under? (assq-ref fields 'current-location)) fields))))
         ($ observer 'all-resources)))))

;;; the holders of those assets — each `custodian-scope` and
;;; `primary-accountable` the agent store can name. Holding is an agent's, never
;;; a thing's (schemas.scm), so these are the only agents an activity's things
;;; put in front of the law. No agent store ⇒ none.
(define (legal-agents-of agent-store assets)
  (if (not (and agent-store assets)) #f   ; nobody looked: unknown, not none
      (let ((ids (delete-duplicates
                  (append-map (lambda (a)
                                (filter string?
                                        (list (assq-ref a 'custodian-scope)
                                              (assq-ref a 'primary-accountable))))
                              assets))))
        (filter-map (lambda (id)
                      (let ((ag ($ agent-store 'get-agent id)))
                        (and ag (legal-agent-fields ag))))
                    ids))))

;;; the whole context for (proc-id, cell) from live stores — the ONE place the
;;; three gates below agree on what a guard sees. #f when the process trips no
;;; crossing: the law has nothing to say, and the things are not even looked
;;; up — an activity outside the law costs the solve nothing.
(define (legal-context-at recipe-store path-of observer agent-store
                          proc-id cell act)
  ;; ACT: the recipe's own `act:<kind>` tag when it carries one, else the
  ;; caller's default. Read exactly where crossings and the channel are read, so
  ;; one gate serves processes of different kinds instead of being told one act
  ;; for all of them.
  (let* ((resolve (lambda (id) ($ recipe-store 'get-resource-spec id)))
         (flows (legal-proc-flows recipe-store proc-id))
         (exchange-flows (lambda (id) ($ recipe-store 'flows-for-exchange id)))
         (crossings (recipe-crossings flows resolve #:exchange-flows exchange-flows))
         ;; a process that moves money, land or a dwelling may trip a crossing
         ;; through the THING at the cell — funds held for another, property
         ;; held — so its things are looked at even when its flows trip nothing
         (held-kind? (any (lambda (f)
                            (let* ((id (recipe-flow-resource-conforms-to f))
                                   (spec (and id (resolve id))))
                              (pair? (lset-intersection eq? '(money land dwelling)
                                                        (spec-kinds spec id)))))
                          flows)))
    (and (or (pair? crossings) held-kind?)
         (let* ((place (legal-cell-place cell))
                (paths (path-of place))
                (assets (legal-assets-at observer path-of flows place))
                (agents (legal-agents-of agent-store assets))
                (crossings (lset-union eq? crossings (asset-crossings assets resolve))))
           (and (pair? crossings)
                (legal-context #:crossings crossings #:place-path (car paths)
                               #:endpoints paths
                               #:act (or (recipe-act flows resolve) act)
                               #:channel (recipe-channel flows resolve recipe-store)
                               #:assets assets #:agents agents))))))

;;; The crossings ONE process trips, read off the store that holds it: its flows,
;;; its specs and its recipe's exchanges. The call for anyone who has a store and
;;; a process id and wants what the gate would see.
(define (process-crossings recipe-store proc-id)
  (recipe-crossings (legal-proc-flows recipe-store proc-id)
                    (lambda (id) ($ recipe-store 'get-resource-spec id))
                    #:exchange-flows (lambda (id) ($ recipe-store 'flows-for-exchange id))))

;;; Every crossing any recipe in the store trips. The other half of the coverage
;;; question (law/lint.scm `law-coverage`): a rule only fires when a recipe meets
;;; its crossing, so a scope can ask what its law says nothing about — instead of
;;; running a plan, seeing no demand, and being unable to tell permission from
;;; silence.
(define (store-crossings recipe-store)
  (delete-duplicates
   (append-map
    (lambda (r)
      (append-map (lambda (rp) (process-crossings recipe-store (recipe-process-id rp)))
                  ($ recipe-store 'get-process-chain (recipe-id r))))
    ($ recipe-store 'all-recipes))))

;;; → a predicate (proc-id, cell) → forbidden?, built from live stores.
;;; `observer` and `agent-store` are optional: with them, guards over the
;;; activity's things and their holders fire; without, only place and channel.
;;; The predicate is the DECORATION's first value, and deliberately not its own
;;; reading of the bill. There is one rule for "does this prune" —
;;; `legal-bill->decoration` — and both doors must give the same answer to the
;;; same law, or a scope's plan depends on which keyword its caller happened to
;;; pass. It matters most for confidence: a forbid the pack is only UNCERTAIN
;;; about is a strong soft cost, never a hard gate (legal-crossings.md §7), and
;;; before this the predicate pruned on it outright while the decoration priced
;;; it. `engine.scm` lowers a bare #:legal-forbids? into the same decorate slot,
;;; so the two were the same wire carrying two different laws.
(define* (make-legal-gate #:key recipe-store spatial-thing-store registry (act #f)
                          (observer #f) (agent-store #f) (as-of #f)
                          (soft-profile %uncertain-forbid-profile))
  (let ((dec (make-legal-decorate #:recipe-store recipe-store
                                  #:spatial-thing-store spatial-thing-store
                                  #:registry registry #:act act
                                  #:observer observer #:agent-store agent-store
                                  #:as-of as-of #:soft-profile soft-profile)))
    (lambda (proc-id cell)
      (call-with-values (lambda () (dec proc-id cell))
        (lambda (prune? cost skills frag bill) prune?)))))

;;; ── the elegant unification: the WHOLE bill as planner inputs (§6, §2.6) ──
;;; A licence's skill id (a person `obtain` IS a skill — gated by satisfied-by).
(define (legal-licence-skill d) (demand-name d))
;;; fold a bill+hits into the planner decoration (prune? cost skills). A `pay`
;;; is a labour-hour rent (the plan routes around it); a person `obtain` a skill
;;; requirement; a `forbid` a prune — UNLESS its rule is `uncertain`, then a
;;; soft cost, not a hard gate (confidence-aware, §7). `held-spec?` (a spec-id →
;;; #t | #f | `unknown`) folds CUSTODY into the same pass: an entity permit the
;;; scope is known not to hold prunes too, exactly as a forbid does — so
;;; compliance.scm needs no second derivation of the bill.
;;; The profile an UNCERTAIN prohibition rides as, when no caller and no scope
;;; names one. Its governed home is the plan-store's `legal-policy` row
;;; (legal/policy.scm) — a scope's own tolerance for legally-uncertain activity —
;;; and this is only the fallback that module states.
(define %uncertain-forbid-profile
  (assq-ref *legal-policy-defaults* 'uncertain-forbid))

(define* (legal-bill->decoration bill hits #:optional (held-spec? custody-unknown)
                                 #:key (soft-profile %uncertain-forbid-profile))
  (let* ((forbids (bill-ref bill 'forbid))
         (pays    (bill-ref bill 'pay))
         (tells   (bill-ref bill 'tell))
         (persons (bill-ref bill 'obtain-person))
         (ents    (bill-ref bill 'obtain-entity))
         ;; one reading of the bill (legal/registry.scm `bill-stance`): the prune
         ;; and the tension are what the stance says, read after derogations.
         (prune?  (eq? (bill-stance bill hits held-spec?) 'off))
         (soft-forbid? (eq? (bill-forbid bill hits) 'soft))
         ;; Confidence gates the prune for every kind of demand: a prohibition or
         ;; an unheld entity permit removes the column when a sure rule imposes
         ;; it, and prices or warns when only an uncertain rule does.
         (cost (+ (apply + (map demand-weight pays))     ; the levy — a labour-hour rent
                  (apply + (map demand-weight ents)))))  ; entity authorisation — compliance overhead
    ;; the uncertain ban leaves as a TENSION on this column, not a line of cost
    ;; …and the BILL rides out with it. A caller assembling "what this act needs
    ;; here" must not fold the law a second time to get it: two doors, one law is
    ;; how the gate and the decoration came to disagree about confidence.
    (values prune? cost (map legal-licence-skill persons)
            (and soft-forbid? soft-profile)
            ;; NAMES, not demand records. The engine is the numeric core and has
            ;; never known the legal vocabulary; handing it `<demand>`s would make
            ;; it import legal-registry to read its own inputs. A name is all a
            ;; requirement list needs, and it is already the join key everywhere.
            `((obtain-entity . ,(map demand-name ents))
              (obtain-person . ,(map demand-name persons))
              (pay           . ,(map demand-name pays))
              (tell          . ,(map demand-name tells))
              (forbid        . ,(map demand-name forbids))
              (unheld        . ,(map demand-name
                                     (filter (lambda (d) (eq? #f (held-spec? (demand-name d))))
                                             ents)))
              ;; permits nobody has checked the custody of: asked, priced, and
              ;; neither known held nor known missing
              (custody-unknown . ,(map demand-name
                                       (filter (lambda (d) (eq? 'unknown (held-spec? (demand-name d))))
                                               ents)))))))

;;; → the planner's #:legal-decorate, from live stores + a ^legal-registry.
;;; `held?` : (proc-id cell spec-id) → #t | #f | `unknown` — is that entity
;;; permit in custody here? With no observer nobody has looked, and the answer is
;;; `unknown`: the permit is priced and named (`custody-unknown`) and nothing is
;;; pruned for it. compliance.scm passes an observer-backed one, and a permit it
;;; finds missing prunes the column.
(define* (make-legal-decorate #:key recipe-store spatial-thing-store registry (act #f)
                              (held? (lambda (p c s) 'unknown))
                              (observer #f) (agent-store #f) (as-of #f)
                              ;; how much legally-uncertain activity this scope will
                              ;; carry — a dial the caller turns, not a constant
                              (soft-profile %uncertain-forbid-profile))
  (define path-of (spatial-path-reader spatial-thing-store))
  (lambda (proc-id cell)
    (let ((ctx (legal-context-at recipe-store path-of observer agent-store
                                 proc-id cell act)))
      (if (not ctx) (values #f 0.0 '() #f '())
          (let ((bh ($ registry 'demands ctx as-of)))   ; (bill hits)
            (legal-bill->decoration (car bh) (cadr bh)
                                    (lambda (spec) (held? proc-id cell spec))
                                    #:soft-profile soft-profile))))))
