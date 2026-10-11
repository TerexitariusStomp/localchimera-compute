;;; module/playnet/doors/planner/roster.scm — the roster: scopes added, forgotten, moved and re-stood, a person's home, the worlds a scope starts from, and the wiring that arrives after the spawn
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner roster)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors skills) #:select (declare-skill! lower-resource! revoke-skill!))
  #:use-module ((playnet doors slots) #:select (move-slot-criteria!))
  #:use-module ((playnet knowledge dsl world) #:select (world-agents world-recipes world-resources world-spatials world-specs))
  #:use-module ((playnet knowledge worlds presets) #:select (adopt-preset! preset-list))
  #:use-module ((playnet observation practice) #:select (join-by-id))
  #:use-module ((playnet pools labour-fold) #:select (skill-specs-for-agent))
  #:use-module ((playnet scope live) #:select (scope-labour?))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure success))
  #:use-module ((playnet vf aggregation containment) #:select (containment-chain))
  #:use-module ((playnet vf facts person-facts) #:select (dwelling-id location-share-key means-prefix need-prefix person-place-id person-place-prefix position-prefix))
  #:use-module ((playnet vf schemas) #:select (agent-relationship-id economic-resource-conforms-to economic-resource-id economic-resource-onhand-quantity intent-id measure-has-numerical-value spatial-thing-contained-in spatial-thing-id spatial-thing-name))
  #:use-module ((srfi srfi-1) #:select (any append-map filter-map fold take-while))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-roster-doors))

(define (planner-roster-doors ctx)
  (with-planner-ctx ctx
    ;; MOVING. What a person has written, at the scope FROM, is carried to TO and
    ;; withdrawn from FROM: the needs (the intents `need:AID:*`, with their
    ;; criteria), the means (`means:AID:*`, lowered where they were and raised
    ;; where they land), the held skills, and the agent record with its place in
    ;; the labour pool. Every step is idempotent and TO wins where it already
    ;; holds the same id, so a move interrupted is a move retried, and the same
    ;; sweep over every other scope is what gathers a person who was declared in
    ;; several before there was a home (`consolidate-person!`).
    ;; The means AID holds at scope SID that the scope is lent: a grant names the
    ;; commune that holds it and only that commune's resource view projects the
    ;; thing, so carrying one away strands the grant and the owner's signature is
    ;; what would re-issue it. A move keeps these where they are and says so.
    (define (lent-means-of aid sid)
      (let ((grants (if lent-of (or (false-if-exception (lent-of sid)) '()) '()))
            (root (roster-ref sid)))
        (if (or (null? grants) (not root))
            '()
            (filter-map
             (lambda (r)
               (and (string-prefix? (means-prefix aid) (economic-resource-id r))
                    (any (lambda (g)
                           (and (equal? (assq-ref g 'owner) aid)
                                (let ((rid (assq-ref g 'resource-id)))
                                  (if rid
                                      (equal? rid (economic-resource-id r))
                                      (equal? (assq-ref g 'spec) (economic-resource-conforms-to r))))))
                         grants)
                    (economic-resource-id r)))
             ($ ($ root 'observer) 'inventory)))))
    (define (migrate-person! aid from to)
      (let ((fr (roster-ref from)) (tr (roster-ref to)))
        (if (not (and fr tr (not (equal? from to)))) 0
            (let* ((fps ($ fr 'plan-store)) (tps ($ tr 'plan-store))
                   (fobs ($ fr 'observer)) (tobs ($ tr 'observer))
                   (fas ($ fr 'agent-store)) (tas ($ tr 'agent-store))
                   (fsts ($ fr 'spatial-thing-store)) (tsts ($ tr 'spatial-thing-store))
                   (iso (iso-now)))
              ;; the needs, with their criteria
              (define (carry-needs)
                (let ((needs (filter (lambda (i) (string-prefix? (need-prefix aid) (intent-id i)))
                                     ($ fps 'all-intents))))
                  (for-each (lambda (i)
                              (unless ($ tps 'get-intent (intent-id i)) ($ tps 'add-intent i))
                              (move-slot-criteria! fr tr (intent-id i))
                              ($ fps 'remove-intent (intent-id i)))
                            needs)
                  (length needs)))
              ;; the means, lowered where they were and raised where they land
              (define (carry-means)
                (let ((means (filter (lambda (r) (and (string-prefix? (means-prefix aid) (economic-resource-id r))
                                                      (> (or (and=> (economic-resource-onhand-quantity r)
                                                                    measure-has-numerical-value) 0) 0)
                                                      (not (member (economic-resource-id r) (lent-means-of aid from)))))
                                     ($ fobs 'inventory))))
                  (for-each (lambda (r)
                              (unless ($ tobs 'get-resource (economic-resource-id r)) ($ tobs 'record-resource r))
                              (lower-resource! fobs aid r "means moved")
                              (move-slot-criteria! fr tr (economic-resource-id r)))
                            means)
                  (length means)))
              ;; the held skills, whatever id they carry
              (define (carry-skills)
                (let ((skills (skill-specs-for-agent fobs aid (scope-labour? fr))))
                  (for-each (lambda (sp) (declare-skill! tr aid sp) (revoke-skill! fobs aid sp)) skills)
                  (length skills)))
              ;; the places the person named: copied, since a commune keeps the
              ;; geography its citizens gave it; their own `here` and `home` are
              ;; theirs, and leave with them
              (define (carry-places)
                (let ((mine (filter (lambda (l) (string-prefix? (person-place-prefix aid) (spatial-thing-id l)))
                                    ($ fsts 'all-locations)))
                      (own? (lambda (l) (member (spatial-thing-id l)
                                                (list (person-place-id aid "here") (person-place-id aid "home"))))))
                  (+ (fold (lambda (l n)
                             (if ($ tsts 'get-location (spatial-thing-id l)) n
                                 (begin ($ tsts 'add-location l) (+ n 1))))
                           0 mine)
                     (begin (for-each (lambda (l) ($ fsts 'remove-location (spatial-thing-id l)))
                                      (filter own? mine))
                            0))))
              ;; the dwelling the person lives in
              (define (carry-dwelling)
                (let ((r ($ fobs 'get-resource (dwelling-id aid))))
                  (if (and r (> (measure-has-numerical-value (economic-resource-onhand-quantity r)) 0))
                      (begin (unless ($ tobs 'get-resource (dwelling-id aid)) ($ tobs 'record-resource r))
                             (lower-resource! fobs aid r "dwelling moved")
                             1)
                      0)))
              ;; where the person is, now and expected
              (define (carry-positions)
                (let ((rows (filter (lambda (kv) (and (or (string-prefix? (position-prefix aid) (car kv))
                                                          (equal? (car kv) (location-share-key aid)))
                                                      (pair? (cdr kv))))
                                    ($ fps 'all-meta))))
                  (for-each (lambda (kv)
                              (unless (pair? (or ($ tps 'get-meta (car kv)) '()))
                                ($ tps 'set-meta (car kv) (cdr kv)))
                              ($ fps 'set-meta (car kv) '()))
                            rows)
                  (length rows)))
              ;; the relationships the person is a party to, whichever side: a
              ;; relationship is a fact between two people and follows whichever
              ;; of them moves. Carried BEFORE the agent record, whose removal
              ;; cascades them away at FROM; TO keeps a relationship it holds.
              (define (carry-relationships)
                (let ((rels (join-by-id agent-relationship-id
                                        (list ($ fas 'relationships-as-subject aid)
                                              ($ fas 'relationships-as-object aid)))))
                  (fold (lambda (rel n)
                          (if ($ tas 'get-relationship (agent-relationship-id rel))
                              n
                              (begin ($ tas 'add-relationship rel) (+ n 1))))
                        0 rels)))
              ;; the agent record, with its place in the labour pool
              (define (carry-agent)
                (let ((agent ($ fas 'get-agent aid)))
                  (if (not agent) 0
                      (begin
                        (unless ($ tas 'get-agent aid) ($ tas 'add-agent agent))
                        ($ tas 'update-agent aid (lambda (a) a))      ; the new scope's labour pool refolds
                        ($ fas 'remove-agent aid)                  ; the labour pool follows the removal
                        1))))
              (let ((n (+ (carry-needs) (carry-means) (carry-skills) (carry-places)
                          (carry-dwelling) (carry-positions) (carry-relationships) (carry-agent))))
                (means-changed! from) (means-changed! to)
                n)))))
    ;; everything of AID's held at a scope other than TARGET, carried to TARGET
    (define (consolidate-person! aid target)
      (fold (lambda (e n)
              (if (equal? (car e) target) n (+ n (migrate-person! aid (car e) target))))
            0 (roster-entries)))
    ;; A scope's GEOGRAPHIC path for the dial breadcrumb: the containment chain of its
    ;; deepest place (the farm), from just below the biosphere down to that place's PARENT
    ;; (region/city), excluding the biosphere root and the farm leaf itself — e.g. Berlin →
    ;; ((germany . "Germany") (berlin . "Berlin/Brandenburg")). '() when unplaced.
    (define (scope-geo-path root)
      (let ((locs (or (false-if-exception ($ ($ root 'spatial-thing-store) 'all-locations)) '())))
        (if (null? locs) '()
            (let* ((by-id (make-hash-table)))
              (for-each (lambda (l) (hash-set! by-id (spatial-thing-id l) l)) locs)
              ;; the climb is the shared one (vf/aggregation/containment.scm); what is
              ;; written here is only which part of the chain a breadcrumb wants —
              ;; the middle, from the deepest place up to but not including the
              ;; biosphere root.
              (let* ((resolve (lambda (id) (hash-ref by-id id #f)))
                     (chain-of (lambda (l) (containment-chain l #:parent-of spatial-thing-contained-in
                                                                #:resolve resolve)))
                     (depth   (lambda (l) (length (chain-of l))))
                     (deepest (fold (lambda (l best) (if (or (not best) (> (depth l) (depth best))) l best)) #f locs))
                     (as-seg  (lambda (x)
                                (list (cons 'id (spatial-thing-id x))
                                      (cons 'name (or (spatial-thing-name x) (spatial-thing-id x))))))
                     (ancestors (reverse
                                 (map as-seg
                                      (take-while (lambda (x) (not (equal? (spatial-thing-id x) "biosphere")))
                                                  (if deepest (chain-of deepest) '()))))))
                ;; a commune with no real geography above it — no ancestor at
                ;; all, or only biosphere itself — still gets a flat,
                ;; one-segment path naming its own place, the same "founding
                ;; commune with no geography" fallback scope.js's scopePathOf
                ;; already assumes for the breadcrumb; this is its twin for
                ;; the picker's own tree (crumb.js buildPickTree drops any
                ;; scope whose path is empty).
                (if (pair? ancestors) ancestors (list (as-seg deepest))))))))
    (declared-doors planner

      ((set-personhood-checker! p) (set! ph-ok? p) 'ok)

      ((set-witness-door! d) (set! witness-door d) 'ok)

      ;; the gateway registers the founding commune's economic root here,
      ;; keyed by its real scope-aid, after the UC block mints it. Mutates
      ;; scopes-hm in place (no bcom) so it doesn't reset ph-ok?.
      ((add-scope! id root) (roster-add! id root) 'ok)

      ;; a throwaway/demo scope's way out — see roster-forget!
      ((forget-scope! id) (roster-forget! id) 'ok)

      ;; the time tick (gateway fiber, or any caller): re-stand standing terms,
      ;; then re-solve what has fallen behind the clock — optional max-age in
      ;; seconds, default one hour
      ;; the vat the solve queue lands on — the gateway's own planner vat.
      ;; Handed in once at boot; from then on every solve door answers a
      ;; promise and the vat stays free while a program runs.
      ((set-solve-vat! vat) (set! solve-vat vat) #t)

      ;; a declaration owner's door onto the tick: THUNK re-lays its standing
      ;; terms (idempotent), and every resolve-stale! runs it before the walk
      ((re-stand! thunk) (set! re-stand (cons thunk re-stand)) 'ok)

      ;; ── refederation: one verb, two exact messages per aggregate ──
      ;; Move scope ID under NEW-PARENT (a scope-id, or #f for directly under
      ;; the UC). Each fold node is dropped at its old parent and its total
      ;; delivered to the new one (fold-node-reparent!); each descent node the
      ;; same on the way down (unfold-node-reparent!) — no rebuild, nothing to
      ;; replay. The routing tables need no touch: both splits climb
      ;; %scope-parent, so updating it IS the re-keying.
      ((move-scope! id new-parent)
       (catch-as-failure
         (lambda ()
           (hash-set! declared-parent id new-parent)
           (let ((p (rehang-scope! id)))
             (success `((moved . ,id) (parent . ,(or p 'uc))))))))

      ;; the standing demand and means reads — the other two folds' totals
      ;; the scope a person's facts are written at, whichever scope they connect
      ;; through (home-scope-of above), or #f for a person nowhere yet
      ((home-of aid) (home-scope-of aid))

      ;; a person's home moves: TO becomes the home, and everything of theirs held
      ;; anywhere else is carried there. Safe to ask again — the second asking
      ;; finds nothing left to carry. With no TO, the home they have gathers what
      ;; was declared in other scopes before there was a home.
      ((move-home aid to-scope-id)
       (catch-as-failure
         (lambda ()
           (let ((old (home-scope-of aid)))
             (unless (roster-ref to-scope-id) (error "scope not found" to-scope-id))
             (adopt-home! to-scope-id aid)
             (when (and old (not (equal? old to-scope-id))) (set-home-row! old aid #f))
             (let ((carried (consolidate-person! aid to-scope-id)))
               (success `((home . ,to-scope-id) (carried . ,carried)
                          ;; lent means stay with their grants (see `lent-means-of`)
                          (kept . ,(append-map (lambda (e) (if (equal? (car e) to-scope-id) '() (lent-means-of aid (car e))))
                                               (roster-entries))))))))))

      ;; a commune's planner root, for the governance service's per-scope reads
      ;; (voice-in): the same roster the scope-list walks
      ((scope-root-ref scope-id) (roster-ref scope-id))

      ((scope-list)
       (map (lambda (e) `((id . ,(car e)) (name . ,($ (cdr e) 'name))
                          (path . ,(scope-geo-path (cdr e))))) (roster-entries)))

      ;; ── the ValueFlows lint, as a door: what this scope would refuse ────────
      ;; RECORDS-JSON is an array of records (kind, action, spec, qty, unit, arcs);
      ;; the reply is the findings as JSON. The specs and units are the scope's
      ;; recipe store's, so a spec the scope does not know is a finding here and
      ;; a fact the app's passes quote back to a model (knowledge/vf-lint.scm).
      ;; ── the worlds a scope can start from (knowledge/presets.scm) ──
      ((presets) (preset-list))

      ((adopt-preset! scope-id preset-id)
       (scoped scope-id
         (lambda (root)
           (let ((w (adopt-preset! root preset-id scope-id)))
             `((preset . ,preset-id)
               (specs . ,(length (world-specs w))) (recipes . ,(length (world-recipes w)))
               (places . ,(length (world-spatials w))) (agents . ,(length (world-agents w)))
               (resources . ,(length (world-resources w)))))))))))
