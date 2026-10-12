;;; module/playnet/doors/planner/slots.scm — slots: what a scope asks for and offers, the matches between them, the kinds it ratifies and audits, and the household's split
;;;
;;; A fragment of the planner service (playnet doors service): a procedure from
;;; the service's context to the doors it serves, composed into every service by
;;; doors/service.scm. `with-planner-ctx` binds the context's fields under their
;;; own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §12). What this fragment alone reads and
;;; writes is defined here, above its doors.

(define-module (playnet doors planner slots)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors family local) #:select (family-members-of-json family-needs-of-json))
  #:use-module ((playnet doors family solve) #:select (family-bills family-externalities family-split))
  #:use-module ((playnet doors plan-wire) #:select (solve-part))
  #:use-module ((playnet doors planner solve-cache) #:select (externality-history-ref last-solve-ref met-of-scope))
  #:use-module ((playnet doors record-rows) #:select (agent-skills))
  #:use-module ((playnet doors slots) #:select (cat-terms need-slot-row ratified-kinds-ref ratified-kinds-set! slots-at-reply window->arcs))
  #:use-module ((playnet economy demand-fold) #:select (%demand-key-parts %need-cells %needs-of-plan-store federation-home-of))
  #:use-module ((playnet economy means-fold) #:select (capacity-cells))
  #:use-module ((playnet matching affinity) #:select (chain-index match-pool))
  #:use-module ((playnet matching filter-rule) #:select (context criteria-ref priority-for rule-passes?))
  #:use-module ((playnet matching spatial) #:select (haversine-distance))
  #:use-module ((playnet solve engine) #:select (spec-owner))
  #:use-module ((playnet solve externality) #:select (moved-summary))
  #:use-module ((playnet utils clock) #:select (iso-now))
  #:use-module ((playnet utils envelope) #:select (catch-as-failure success))
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet vf aggregation fold-node) #:select (sum-cells))
  #:use-module ((playnet vf facts audit) #:select (audit-draw audit-rate audit-verdict conduit-verdict observed-of))
  #:use-module ((playnet vf facts availability) #:select (availability-windows-overlap?))
  #:use-module ((playnet vf facts person-facts) #:select (means-id? means-prefix need-id? need-prefix))
  #:use-module ((playnet vf facts tension-terms) #:select (kind-string->symbol tension-kind-of without-tension-terms))
  #:use-module ((playnet vf formulas actions) #:select (creating-actions))
  #:use-module ((playnet vf formulas flows) #:select (row-action row-quantity row-spec))
  #:use-module ((playnet vf schemas) #:select (agent-relationship-object economic-resource-availability-window economic-resource-classified-as economic-resource-conforms-to economic-resource-current-location economic-resource-id economic-resource-image economic-resource-name economic-resource-note economic-resource-onhand-quantity economic-resource-primary-accountable intent-availability-window intent-effort-quantity intent-finished intent-id intent-receiver intent-resource-classified-as intent-resource-conforms-to intent-resource-quantity measure-has-numerical-value measure-has-unit resource-specification-id resource-specification-resource-classified-as spatial-thing-lat spatial-thing-long))
  #:use-module ((srfi srfi-1) #:select (any append-map count filter-map find))
  #:use-module (playnet doors planner ctx)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (planner-slots-doors))

(define (planner-slots-doors ctx)
  (with-planner-ctx ctx

    (declared-doors planner

      ;; the scope ratifies SPEC as KIND — "floor" (a right), "held" (a need
      ;; never zeroed) — recorded with the ratifier's AID; "des" withdraws the
      ;; grant (a want needs none). Who may ratify is the scope's own rite; this
      ;; door names who did.
      ((ratify-kind scope-id agent-id spec kind)
       (scoped scope-id
         (lambda (root)
(let* ((k (kind-string->symbol kind))
                      (rest (filter (lambda (g) (not (equal? (car g) spec)))
                                    (ratified-kinds-ref root))))
                 (ratified-kinds-set!
                  root
                  (if (eq? k 'des)
                      rest
                      (cons (cons spec `((kind . ,k) (by . ,agent-id) (at . ,(iso-now))))
                            rest)))
                 `((spec . ,spec) (kind . ,(symbol->string k)))))))

      ;; ── stage 3: needs are facts — the audit of a ratified kind ────────────
      ;; A held or floor row is checkable ex post: what the observer saw its
      ;; citizen take of the spec since the grant, against what they declared.
      ;; Each row is examined with Becker's probability π = gain/consequence
      ;; (audit.scm): the gain the meter read for the spec, the consequence
      ;; the scope's factor K times that (opts `consequence-factor`, default
      ;; 1 ⇒ every row examined). A padded verdict withdraws the grant through
      ;; the one ratification door; every verdict is recorded beside the
      ;; grants as plan-store meta "audits", the auditor named by AID.
      ((audit-kinds scope-id agent-id #:optional (options #f))
       (scoped scope-id
         (lambda (root)
(let* ((o      (or options '()))
                      (k      (let ((v (assq-ref o 'consequence-factor))) (if (and (number? v) (> v 0)) v 1)))
                      (tol    (let ((v (assq-ref o 'tolerance))) (if (number? v) v 0.25)))
                      (today  (substring (iso-now) 0 10))
                      (obs    ($ root 'observer))
                      (ps     ($ root 'plan-store))
                      (grants (ratified-kinds-ref root))
                      (moved  (assq-ref (moved-summary (externality-history-ref cache scope-id)) 'specs))
                      (gain-of (lambda (spec)
                                 (let ((r (find (lambda (r) (equal? (assq-ref r 'spec) spec)) moved)))
                                   (and r (assq-ref r 'mean-moved)))))
                      (rows   (filter (lambda (i)
                                        (and (string? (intent-id i)) (need-id? (intent-id i))
                                             (not (intent-finished i)) (intent-receiver i)
                                             (assoc (intent-resource-conforms-to i) grants)
                                             (memq (tension-kind-of (intent-resource-classified-as i)) '(held floor))))
                                      ($ ps 'all-intents)))
                      (findings
                       (filter-map
                        (lambda (i)
                          (let* ((spec (intent-resource-conforms-to i)) (who (intent-receiver i))
                                 (g    (assoc-ref grants spec))
                                 (gain (gain-of spec))
                                 (pi   (audit-rate gain (and gain (* k gain))))
                                 (m    (or (intent-resource-quantity i) (intent-effort-quantity i)))
                                 (declared (or (and m (measure-has-numerical-value m)) 0)))
                            (and (< (audit-draw spec who today) pi)
                                 (let* ((observed (observed-of (person-events who) spec who
                                                               #:since (assq-ref g 'at)))
                                        (verdict  (audit-verdict declared observed #:tolerance tol)))
                                   `((spec . ,spec) (who . ,who) (kind . ,(symbol->string (assq-ref g 'kind)))
                                     (declared . ,(exact->inexact declared)) (observed . ,(exact->inexact observed))
                                     (verdict . ,(symbol->string verdict)) (rate . ,pi)
                                     (by . ,agent-id) (at . ,(iso-now)))))))
                        rows)))
                 ;; a padded row withdraws its grant — the same door that gave it
                 (for-each (lambda (f)
                             (when (equal? (assq-ref f 'verdict) "padded")
                               (ratified-kinds-set! root (filter (lambda (g) (not (equal? (car g) (assq-ref f 'spec))))
                                                                (ratified-kinds-ref root)))))
                           findings)
                 ;; the WANTS' pass — the cap rule leaves quantities nothing to
                 ;; buy, so the one residue is the conduit: a citizen's own good
                 ;; delivered well above what they took (pad-and-gift). Read off
                 ;; the same solve the burn-meter prices and the same events the
                 ;; kinds' pass reads; recorded, never acted on mechanically —
                 ;; a conduit is the table's conversation, not a withdrawal.
                 (let* ((cached (last-solve-ref cache scope-id))
                        (mat    (and cached (solve-part cached 'material)))
                        (conduits
                         (if (not (pair? mat)) '()
                             (filter-map
                              (lambda (m)
                                (let* ((g (row-spec m))
                                       (o (and (string? g) (memq (row-action m) creating-actions) (spec-owner g))))
                                  (and o
                                       (let* ((spec (car o)) (who (cdr o))
                                              (delivered (abs (or (row-quantity m) 0)))
                                              (consumed  (observed-of (person-events who) spec who))
                                              (v (conduit-verdict delivered consumed #:tolerance tol)))
                                         (and (eq? v 'conduit)
                                              `((spec . ,spec) (who . ,who) (kind . "conduit")
                                                (declared . ,(exact->inexact delivered))
                                                (observed . ,(exact->inexact consumed))
                                                (verdict . "conduit") (rate . 1.0)
                                                (by . ,agent-id) (at . ,(iso-now))))))))
                              mat))))
                   (set! findings (append findings conduits)))
                 ($ ps 'set-meta "audits"
                    (list (cons 'findings (append findings
                                                  (or (and=> ($ ps 'get-meta "audits") (lambda (r) (assq-ref r 'findings))) '())))))
                 `((examined . ,(length findings))
                            (padded . ,(count (lambda (f) (equal? (assq-ref f 'verdict) "padded")) findings))
                            (findings . ,findings))))))

      ((audits scope-id)
       (scoped scope-id
         (lambda (root)
`((findings . ,(or (and=> ($ ($ root 'plan-store) 'get-meta "audits")
                                                  (lambda (r) (assq-ref r 'findings)))
                                           '()))))))

      ((ratified-kinds scope-id)
       (scoped scope-id
         (lambda (root)
                `((grants . ,(map (lambda (g)
                                    `((spec . ,(car g))
                                      (kind . ,(symbol->string (assq-ref (cdr g) 'kind)))
                                      (by . ,(assq-ref (cdr g) 'by))
                                      (at . ,(assq-ref (cdr g) 'at))))
                                  (ratified-kinds-ref root)))))))

      ;; ── Our: the fold's reading at a scope ─────────────────────────────────
      ;; A need is declared once, by a person (`need:AID:SPEC`). What a scope
      ;; holds is the SUM — the ^demand-node's cells, (spec place from until
      ;; kind) → qty, with no one's name in them — and capacity the same way,
      ;; the ^means-pool's (spec . place) → unit-hours/day. This is what the share
      ;; bar's "Our Needs / Our Offers" lists: the scope's want as one fact per
      ;; cell, never the roster behind it. HOME-SCOPE-ID is where AGENT-ID's own
      ;; leaf lives, so each cell carries `mine` — the asker's share of the sum
      ;; — while every other contribution stays folded.
      ((our-slots scope-id home-scope-id agent-id)
       (scoped scope-id
         (lambda (root)
(let* ((dn    (node-of scope-id nodes-demand))
                      (mn    (node-of scope-id nodes-means))
                      (cells (or (and dn (false-if-exception ($ dn 'cells))) '()))
                      (caps  (or (and mn (false-if-exception ($ mn 'cells))) '()))
                      ;; the asker's own needs are read where they are written: their home
                      (home  (roster-ref (or (home-scope-of agent-id) home-scope-id)))
                      (home-of (and home (federation-home-of home)))
                      (nprefix (need-prefix agent-id))
                      (mprefix (means-prefix agent-id))
                      (own-needs (if home (%needs-of-plan-store ($ home 'plan-store)) '()))
                      (mine-cells
                       (sum-cells
                        (append-map (lambda (i) (%need-cells i home-of))
                                    (filter (lambda (i) (string-prefix? nprefix (intent-id i)))
                                            own-needs))))
                      (mine-caps
                       (if home
                           (capacity-cells
                            (filter (lambda (r) (string-prefix? mprefix (economic-resource-id r)))
                                    ($ ($ home 'observer) 'all-resources)))
                           '()))
                      ;; the unit a spec is asked in, read off the leaves this
                      ;; service can see (the scope's own and the asker's home);
                      ;; a cell is a quantity, the unit is the spec's
                      (mq (lambda (m acc) (if m (acc m) #f)))
                      (units (make-hash-table))
                      (_ (for-each
                          (lambda (i)
                            (let ((u (mq (or (intent-resource-quantity i) (intent-effort-quantity i))
                                         measure-has-unit)))
                              (when u (hash-set! units (intent-resource-conforms-to i) u))))
                          (append own-needs (%needs-of-plan-store ($ root 'plan-store)))))
                      (needs
                       (filter-map
                        (lambda (c)
                          (let ((p (%demand-key-parts (car c))))
                            (and (not (list-ref p 5))          ; the Σw·q twin is a weight, not a want
                                 `((spec    . ,(list-ref p 0))
                                   (where   . ,(list-ref p 1))
                                   (from    . ,(list-ref p 2))
                                   (until   . ,(list-ref p 3))
                                   (tension . ,(symbol->string (list-ref p 4)))
                                   (qty     . ,(cdr c))
                                   (unit    . ,(hash-ref units (list-ref p 0) %count-unit))
                                   (mine    . ,(or (assoc-ref mine-cells (car c)) 0))))))
                        cells))
                      (means
                       (map (lambda (c)
                              `((spec  . ,(caar c))
                                (where . ,(cdar c))
                                (qty   . ,(cdr c))
                                (unit  . "hours/day")
                                (mine  . ,(or (assoc-ref mine-caps (car c)) 0))))
                            caps)))
                 `((needs . ,needs) (means . ,means))))))

      ;; the SCOPE's slot pool, for the map: every citizen's standing needs (the
      ;; need markers and hull tints), and the means the commune holds by grant
      ;; — both LIVE. The needs are the plan-store's intents; the means are the
      ;; custody projection pool-of derives off the store right now, so a grant
      ;; issued a moment ago is a 🏠 a moment ago and a recalled one is gone.
      ;; What a solve alone can say — how occupied each slot came out, `drawn`
      ;; — is joined in from the last solve by id (0 for a slot no solve has
      ;; seen yet); the allocation waits for the solve, the pool never does.
      ;; A merely DECLARED private means never appears here: what the commons
      ;; sees is what stands in the commons (my-slots stays the owner's view).
      ((slots-at scope-id)
       (with-scope scope-id
         (lambda (root)
           (let ((cached (last-solve-ref cache scope-id)))
             (slots-at-reply root
                             #:met-of (met-of-scope cache root scope-id)
                             #:solved (or (and cached (assq-ref (cdr cached) 'socialized-slots)) '())
                             #:pool (and pool-of (pool-of root scope-id)))))))

      ;; the ring's read: every standing need in the scope scored against every
      ;; declared means, by classification affinity (matching/affinity.scm) over
      ;; TREE — the folksonomy template the lobby resolved through the caller's
      ;; lens, so "what matches" is read through the same cut the spine shows.
      ;; Unlike slots-at (custody: what stands IN the commons), this reads ALL
      ;; declared means: matching is introduction, not provision — it tells two
      ;; people they should talk, it moves nothing. A slot's terms are its own
      ;; cats ∪ its spec's catalog classification (cat-terms expands the legacy
      ;; slash-paths into the template's flat segment ids); the time dimension
      ;; scores over the REAL availability-windows with the machinery matching/
      ;; availability.scm already has.
      ;; the family face: a household purse split across its members' needs by
      ;; harmony ((playnet doors family solve) — the same solve the planner test
      ;; pins). NEEDS-JSON is the dial's list of {person,what,cost,want,level};
      ;; the family is the scope where the person is still known, so the rows
      ;; come back keyed per member. No AID and no scope: the purse and the needs
      ;; are the face's own statement, the solve is a fresh world.
      ;; MEMBERS-JSON, when given, is the household's own consumer voice (§The
      ;; credit identity, family-voice-of): each declared member's capacity to
      ;; labour and hours contributed this week. Absent (the pre-existing
      ;; 4-arg call) or empty, every owner reads as an equal citizen — the
      ;; solve is unchanged from before.
      ((family-split needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
       (catch-as-failure
         (lambda ()
           (success (family-split (family-needs-of-json needs-json) purse
                                  #:weighted? weighted? #:labour-h labour-h
                                  #:members (family-members-of-json members-json)
                                  #:per-citizen-hours per-citizen-hours)))))

      ;; the same face asked backwards: what the week would take — euros and
      ;; hours beyond the purse and the hours on hand — for rights, then needs,
      ;; then wants held as walls (family-bills, docs/planning/socialization/three-bills.md).
      ((family-bills needs-json purse labour-h weighted? eur-per-hour #:optional (members-json "[]") (per-citizen-hours 40.0))
       (catch-as-failure
         (lambda ()
           (success (family-bills (family-needs-of-json needs-json) purse
                                  #:weighted? weighted? #:labour-h labour-h #:eur-per-hour eur-per-hour
                                  #:members (family-members-of-json members-json)
                                  #:per-citizen-hours per-citizen-hours)))))

      ;; the same face's externality display: beside each held/des row, the euros
      ;; the OTHER members would have received had the row not been asked — the
      ;; table's instrument, shown before any mechanism charges for a declaration.
      ((family-externalities needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
       (catch-as-failure
         (lambda ()
           (success (family-externalities (family-needs-of-json needs-json) purse
                                          #:weighted? weighted? #:labour-h labour-h
                                          #:members (family-members-of-json members-json)
                                          #:per-citizen-hours per-citizen-hours)))))

      ((match-slots scope-id tree)
       (scoped scope-id
         (lambda (root)
(let* ((ps  ($ root 'plan-store))
                      (obs ($ root 'observer))
                      (rs  ($ root 'recipe-store))
                      (spec-cats
                       (let ((t (make-hash-table)))
                         (for-each
                          (lambda (s)
                            (hash-set! t (resource-specification-id s)
                                       (or (resource-specification-resource-classified-as s)
                                           '())))
                          (or (false-if-exception ($ rs 'all-resource-specs)) '()))
                         t))
                      (windows (make-hash-table))    ; row id → availability-window
                      (mq (lambda (m acc) (if m (acc m) #f)))
                      (row-cats (lambda (own spec)
                                  (cat-terms (or own '())
                                             (hash-ref spec-cats (or spec "") '()))))
                      (needs
                       (filter-map
                        (lambda (i)
                          (and (need-id? (intent-id i))
                               (not (intent-finished i))
                               (begin
                                 (hash-set! windows (intent-id i)
                                            (intent-availability-window i))
                                 (cons (cons 'cats
                                             (row-cats (without-tension-terms (intent-resource-classified-as i))
                                                       (intent-resource-conforms-to i)))
                                       (need-slot-row i root #:met-of (met-of-scope cache root scope-id))))))
                        ($ ps 'all-intents)))
                      (means
                       (filter-map
                        (lambda (r)
                          (let ((q (or (mq (economic-resource-onhand-quantity r)
                                           measure-has-numerical-value) 0)))
                            (and (means-id? (economic-resource-id r))
                                 (> q 0)
                                 (begin
                                   (hash-set! windows (economic-resource-id r)
                                              (economic-resource-availability-window r))
                                   `((id    . ,(economic-resource-id r))
                                     (spec  . ,(economic-resource-conforms-to r))
                                     (name  . ,(or (economic-resource-name r)
                                                   (economic-resource-conforms-to r)))
                                     (emoji . ,(economic-resource-image r))
                                     (note  . ,(economic-resource-note r))
                                     (owner . ,(economic-resource-primary-accountable r))
                                     (qty   . ,q)
                                     (unit  . ,(or (mq (economic-resource-onhand-quantity r)
                                                       measure-has-unit) %count-unit))
                                     (where . ,(economic-resource-current-location r))
                                     (cats  . ,(row-cats (economic-resource-classified-as r)
                                                         (economic-resource-conforms-to r)))
                                     (criteria . ,(means-criteria scope-id root r))
                                     (arcs  . ,(window->arcs
                                                (economic-resource-availability-window r))))))))
                        ($ obs 'inventory)))
                      ;; both windowed → do they overlap; one unwindowed → unknown
                      ;; (0.5 abstains softly, exactly the prototype's rule)
                      (time-score
                       (lambda (n c)
                         (let ((wn (hash-ref windows (assq-ref n 'id) #f))
                               (wc (hash-ref windows (assq-ref c 'id) #f)))
                           `((time . ,(if (and wn wc)
                                          (if (catch #t
                                                (lambda ()
                                                  (availability-windows-overlap? wn wc))
                                                (lambda _ #t))
                                              1.0 0)
                                          0.5))))))
                      ;; the eligibility rules, BILATERALLY: the need's rule over
                      ;; the offer's side and the offer's over the need's; a lock
                      ;; either way is a zero on the `eligible` dimension, which
                      ;; compose-scores treats as a veto. Divisibility rides the
                      ;; same veto: an offer smaller than the need's smallest
                      ;; useful piece is not a match. The context a rule reads
                      ;; about the OTHER side: who they are; how I know them
                      ;; (the `knows` reading: my contact book's groups and my
                      ;; signed vouches, the same reading the steward gate asks;
                      ;; an agent-relationship I am the subject of recognizes
                      ;; them too; unknown denies a min-recognition clause); the
                      ;; scope; the
                      ;; skills they declared; how far their place is from mine
                      ;; (both places resolved through the scope's spatial
                      ;; things; unknown when either has no coordinates).
                      (as  ($ root 'agent-store))
                      (sts ($ root 'spatial-thing-store))
                      (knows? (lambda (me other)
                                (and me other
                                     (any (lambda (r) (equal? (agent-relationship-object r) other))
                                          (or (false-if-exception ($ as 'relationships-as-subject me)) '())))))
                      (latlon (lambda (place)
                                (let ((st (and (string? place) (not (string-null? place))
                                               (false-if-exception ($ sts 'get-location place)))))
                                  (and st (spatial-thing-lat st) (spatial-thing-long st)
                                       (cons (spatial-thing-lat st) (spatial-thing-long st))))))
                      (km-between (lambda (a b)
                                    (let ((p (latlon a)) (q (latlon b)))
                                      (and p q (haversine-distance (car p) (cdr p) (car q) (cdr q))))))
                      (side (lambda (me other my-place their-place)
                              (context #:aid other
                                       #:recognition (and (knows? me other) 1.0)
                                       #:knows (and knows-of me other
                                                    (false-if-exception (knows-of me other)))
                                       #:scopes (list scope-id)
                                       #:skills (and other (agent-skills obs other))
                                       #:distance-km (km-between my-place their-place))))
                      (eligible
                       (lambda (n c)
                         (let* ((cn (assq-ref n 'criteria)) (cc (assq-ref c 'criteria))
                                (need-min (criteria-ref cn 'min-atomic-size))
                                (ok (and (rule-passes? (criteria-ref cn 'filter-rule)
                                                       (side (assq-ref n 'who) (assq-ref c 'owner)
                                                             (assq-ref n 'where) (assq-ref c 'where)))
                                         (rule-passes? (criteria-ref cc 'filter-rule)
                                                       (side (assq-ref c 'owner) (assq-ref n 'who)
                                                             (assq-ref c 'where) (assq-ref n 'where)))
                                         (or (not (number? need-min))
                                             (>= (or (assq-ref c 'qty) 0) need-min)))))
                           `((eligible . ,(if ok #f 0))
                             ;; ⭐ the offer's priority for THIS need's person
                             ;; (its distribution, else its flat priority) —
                             ;; a dimension that abstains when it has no say
                             (priority . ,(priority-for cc (assq-ref n 'who)))))))
                      (matches (match-pool (chain-index tree) needs means
                                           #:threshold 0.5 #:limit 20
                                           #:extra (lambda (n c)
                                                     (append (time-score n c) (eligible n c))))))
                 `((needs . ,needs)
                            (means . ,means)
                            (matches . ,matches)))))))))
