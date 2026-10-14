;;; module/playnet/doors/planner/solve-cache.scm — one service's solve cache: the last plan of each scope, what warms and qualifies it, and what a landed plan sets in motion.
;;;
;;; One <solve-cache> per ^planner-service (doors/service.scm), held in its
;;; context (doors/planner/ctx.scm). Every scope-keyed table lives here, so two
;;; services in one process that both know a "Granary" never read each other's
;;; warm start, stale mark or last plan. A reader the cache is handed at
;;; construction answers for the service's roster: the scope's plan-store (the
;;; durable row), its observer (the plan's claims land there) and the places its
;;; own spatial store holds (its own slack cells). Outside a service (unit worlds
;;; with no roster) each read falls back to a process-local table, the same grace
;;; every door extends to a mock.

(define-module (playnet doors planner solve-cache)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet doors plan-wire) #:select (plan-results->dial-plan solve-part))
  #:use-module ((playnet doors service provenance-trace) #:select (make-pull-of))
  #:use-module ((playnet observation account) #:select (claim-fulfillments claim-commitment fulfillment-remaining))
  #:use-module ((playnet observation states) #:select (fulfillment-state-commitment-id))
  #:use-module ((playnet scope live) #:select (held-commitment plan->rows plan-map-flows plan-without-person-time))
  #:use-module ((playnet solve engine) #:select (key-spec spec-base))
  #:use-module ((playnet solve ingest) #:select (stock-vocabulary resource-window-hours))
  #:use-module ((playnet solve externality) #:select (marginal-rows note-solve))
  #:use-module ((playnet utils clock) #:select ((now . clock-now) instant->unix iso-now))
  #:use-module ((playnet vf formulas actions) #:select (creating-actions))
  #:use-module ((playnet vf formulas flows) #:select (row-action row-id row-place row-quantity row-run row-spec row-when))
  #:use-module ((playnet vf schemas) #:select (commitment-id))
  #:use-module ((playnet vf serdes) #:select (vf-deserialize vf-serialize))
  #:use-module ((srfi srfi-1) #:select (find fold filter))
  #:use-module (srfi srfi-9)
  #:export (make-solve-cache solve-cache?
            solve-cache-on-cached set-solve-cache-on-cached!
            solve->stored stored->solve
            last-solve-ref last-solve-at-ref last-solve-set!
            externality-history-ref externality-history-set! note-externalities!
            met-of-scope spec-met
            means-caps-of means-cap-rows set-means-cap!
            solve-vocabulary-of solve-at-of warm-x-of decided-of mark-solve-stale! solve-stale?
            planned-material planned-runs planned-rows planned-row-id hold-row! row-left
            cache-solve! plan-claims!
            scope-own-slack scope-own-plan-time))

;; THE LAST SOLVE, per scope: (cons demand solve-alist). A solve / plan /
;; materialize lands it; build-snapshot reads it so the dial shows the REAL
;; coverage of the most recent solve. It lives in the scope's OWN plan-store
;; (a "solve:last" meta row — persisted, so a restart draws the last plan),
;; reached through STORE-OF: a scope's result is written by its own descent
;; leaf into its own store and read from there, so "each scope touches only
;; its slice" holds down to storage, not only in the routing.
(define-record-type <solve-cache>
  (%make-solve-cache store-of observer-of own-places-of home-of on-cached
                     last-solve-fallback solve-read externality-fallback met-memo means-caps
                     warm-x decided stale-solves solve-at solve-vocab)
  solve-cache?
  (store-of      solve-cache-store-of)        ; scope-id → its plan-store, or #f
  (observer-of   solve-cache-observer-of)     ; scope-id → its observer, or #f
  (own-places-of solve-cache-own-places-of)   ; scope-id → the ids of its own places, or #f when unknown
  (home-of       solve-cache-home-of)         ; person id → the id of the scope they are at home in, or #f
  (on-cached     solve-cache-on-cached set-solve-cache-on-cached!)   ; scope-id → …, what a landed plan sets in motion
  (last-solve-fallback solve-cache-last-solve-fallback)   ; scope-id → (demand . plan), for a store that cannot hold the row
  (solve-read    solve-cache-solve-read)      ; scope-id → (stored . plan): the read kept per stored value
  (externality-fallback solve-cache-externality-fallback)
  (met-memo      solve-cache-met-memo)        ; scope-root → (cached-solve . its dial plan)
  (means-caps    solve-cache-means-caps)      ; scope-root → ((spec . (located-good . cap)) …)
  (warm-x        solve-cache-warm-x)          ; scope-id → the last solve's x
  (decided       solve-cache-decided)         ; scope-id → the discrete state the last search left
  (stale-solves  solve-cache-stale-solves)    ; scope-id → #t while a re-solve is due
  (solve-at      solve-cache-solve-at)        ; scope-id → unix seconds, hydrated from the durable row on first ask
  (solve-vocab   solve-cache-solve-vocab))    ; scope-id → the goods the last solve read stock against

(define* (make-solve-cache #:key (store-of (lambda (sid) #f)) (observer-of (lambda (sid) #f))
                           (own-places-of (lambda (sid) #f)) (home-of (lambda (aid) #f)))
  "A cache over one service's roster: STORE-OF, OBSERVER-OF and OWN-PLACES-OF
   answer for a scope the service knows, #f otherwise; HOME-OF names the scope
   a person is at home in, #f for one with no home."
  (%make-solve-cache store-of observer-of own-places-of home-of #f
                     (make-hash-table) (make-hash-table) (make-hash-table) (make-hash-table) (make-hash-table)
                     (make-hash-table) (make-hash-table) (make-hash-table) (make-hash-table) (make-hash-table)))

(define (store-of cache sid) ((solve-cache-store-of cache) sid))

;; The store holds a plan's flows as the records they are, in the serialized form
;; every stored VF record takes (vf/serdes.scm); a row written before the flows
;; were records reads back as the row it is. The read is kept per stored value, so
;; a plan read twice is one plan.
(define (solve->stored v)
  (cons (car v) (plan-map-flows (lambda (part f) (vf-serialize f)) (cdr v))))
(define (stored->solve cache scope-id stored)
  (let* ((tbl (solve-cache-solve-read cache))
         (seen (hash-ref tbl scope-id #f)))
    (if (and seen (eq? (car seen) stored)) (cdr seen)
        (let ((v (cons (car stored) (plan-map-flows (lambda (part f) (vf-deserialize f)) (cdr stored)))))
          (hash-set! tbl scope-id (cons stored v))
          v))))
(define (last-solve-ref cache scope-id)
  (let ((ps (and scope-id (store-of cache scope-id))))
    (or (and ps
             (false-if-exception
              (let* ((row ($ ps 'get-meta "solve:last"))
                     (stored (and row (assq-ref row 'solve))))
                (and (pair? stored) (stored->solve cache scope-id stored)))))
        (hash-ref (solve-cache-last-solve-fallback cache) scope-id #f))))
;; the solve's OWN unix-seconds rides in the same durable row as the plan,
;; so a restart can tell a durable plan is FRESH without re-solving to find
;; out — solve-at (below) is in-process only, and reading #f from it after
;; every restart used to read as "never solved", sweeping the whole roster
;; on every boot even when the durable plan was minutes old (found live).
(define (last-solve-at-ref cache scope-id)
  (let ((ps (and scope-id (store-of cache scope-id))))
    (and ps (false-if-exception
             (let ((row ($ ps 'get-meta "solve:last")))
               (and row (assq-ref row 'at)))))))
(define (last-solve-set! cache scope-id v at)
  (let ((ps (store-of cache scope-id)))
    (unless (and ps (false-if-exception
                     (begin ($ ps 'set-meta "solve:last"
                                (list (cons 'solve (solve->stored v)) (cons 'at at)))
                            #t)))
      (hash-set! (solve-cache-last-solve-fallback cache) scope-id v))))

;; ── the burn-meter: the externality display, persisted per solve ───────────
;; The same door discipline as the solve cache above: the scope's own
;; plan-store meta when it can hold the row, the fallback table when it cannot
;; (mocks, minimal roots). What accumulates is stage 0's data — the moved-
;; distribution that sizes a voice budget, and the scope's measured VCG bill
;; (solve/externality.scm, truth-telling.md).
(define (externality-history-ref cache scope-id)
  (let ((ps (and scope-id (store-of cache scope-id))))
    (or (and ps (false-if-exception
                 (let ((row ($ ps 'get-meta "externality:history")))
                   (and row (assq-ref row 'history)))))
        (hash-ref (solve-cache-externality-fallback cache) scope-id '()))))
(define (externality-history-set! cache scope-id hist)
  (let ((ps (store-of cache scope-id)))
    (unless (and ps (false-if-exception
                     (begin ($ ps 'set-meta "externality:history"
                               (list (cons 'history hist))) #t)))
      (hash-set! (solve-cache-externality-fallback cache) scope-id hist))))
(define (note-externalities! cache scope-id alist)
  "One solve landed: price the demand it RAN ON at its own duals and keep
   the display. Both come off the alist — `demand`, the fold's wants keyed
   \"spec#place@t\" (plan-commune-scope), and the duals — so a landing that
   carries no prices (the federated descent) notes nothing. The display's
   unit is the SPEC, so asks sum per spec across places and periods. Never
   the reason a solve fails — a noting error is reported and dropped."
  (catch #t
    (lambda ()
      (let ((asks '()))
        (for-each (lambda (d)
                    ;; the display's unit is the SCOPE's spec: a citizen's
                    ;; own good ("spec~aid") folds onto it
                    (let ((spec (spec-base (key-spec (car d)))) (q (cdr d)))
                      (when (number? q)
                        (let ((row (assoc spec asks)))
                          (if row (set-cdr! row (+ (cdr row) q))
                              (set! asks (cons (cons spec q) asks)))))))
                  (or (assq-ref alist 'demand) '()))
        (let ((rows (marginal-rows asks (make-pull-of alist))))
          (when (pair? rows)
            (externality-history-set!
             cache scope-id
             (note-solve (externality-history-ref cache scope-id) rows #:at (iso-now)))))))
    (lambda (key . args)
      (format (current-error-port) "note-externalities! ~a: ~a ~a~%" scope-id key args))))

;; how MET a spec is, as of the scope's last solve: produced/target from the
;; cached plan (0..1), or #f when no solve has run — the communal tier of a
;; need's "how it's met", on the row itself so the drawer needs no second read.
;; A need's row reads how far it is met through this: the last solve of SCOPE-ID.
(define (met-of-scope cache scope-root scope-id)
  (lambda (spec) (spec-met cache scope-root scope-id spec)))

(define (spec-met cache scope-root scope-id spec)
  ;; keyed by the scope's own root object, not its id string: two different
  ;; ^planner-service instances can name a scope the same thing (every test's
  ;; "Granary"), and a bare scope-id key would let one instance's cached plan
  ;; answer another's spec-met before it has ever solved
  (let* ((memos (solve-cache-met-memo cache))
         (cached (and scope-id (last-solve-ref cache scope-id)))
         (memo (and cached (hash-ref memos scope-root #f)))
         ;; the projection once per solve, not once per row
         (plan (and cached
                    (if (and memo (eq? (car memo) cached)) (cdr memo)
                        (let ((p (plan-results->dial-plan scope-root (car cached) (cdr cached))))
                          (hash-set! memos scope-root (cons cached p))
                          p))))
         (row (and plan (find (lambda (n) (equal? (assq-ref n 'id) spec))
                              (or (assq-ref plan 'needs) '())))))
    (and row (assq-ref row 'met))))

;; The UC means allocations, landed: scope-root → ((spec . (located-good . cap)) …),
;; written by the `means-plan` verb (the consensus row run live) and MERGED into
;; every subsequent solve's #:eco-caps — so a scope's next plan is bounded by
;; what the federation allocated it, warm-started from what it held before.
;; Keyed by the scope's own root, not its id string, for the reason spec-met gives.
(define (means-cap-rows cache root)
  "((spec . (located-good . cap)) …) the federation allocated ROOT."
  (hash-ref (solve-cache-means-caps cache) root '()))
(define (means-caps-of cache root)
  (map cdr (means-cap-rows cache root)))
(define (set-means-cap! cache root spec cap-pair)
  (hash-set! (solve-cache-means-caps cache) root
             (cons (cons spec cap-pair)
                   (filter (lambda (e) (not (equal? spec (car e))))
                           (means-cap-rows cache root)))))

;; ── warm starts and freshness, beside the cache they qualify ───────────────
;; The solution vector is the NEXT solve's warm start and nothing else: popped
;; off the alist here into an in-process table (a restart cold-starts, which
;; is the honest default), so what the callers see, the wire carries and the
;; plan-store persists stays lean. The stale mark is the snapshot's
;; while-revalidating answer: an accept re-solves on a LATER vat turn, and
;; until that solve lands the cached plan describes the world before the
;; decision — the wire says so instead of showing it as current. The
;; timestamp is what the time tick reads.
(define (solve-vocabulary-of cache scope-id)
  "The vocabulary the scope's last plan was solved with: a confirmation reads a holding
   as that plan did. A scope not solved in this process reads the standing recipes'."
  (or (hash-ref (solve-cache-solve-vocab cache) scope-id #f) (stock-vocabulary)))
;; solve-at IN-PROCESS, but its answer for a restored scope is the durable
;; timestamp beside the durable plan — hydrated once, then cached like any
;; other read. A cold #f here used to read as "never solved" and swept the
;; whole roster on every boot; the durable row already knew better.
(define (solve-at-of cache scope-id)
  (or (hash-ref (solve-cache-solve-at cache) scope-id #f)
      (let ((at (last-solve-at-ref cache scope-id)))
        (when at (hash-set! (solve-cache-solve-at cache) scope-id at))
        at)))
(define (warm-x-of cache scope-id) (hash-ref (solve-cache-warm-x cache) scope-id #f))
(define (decided-of cache scope-id) (hash-ref (solve-cache-decided cache) scope-id #f))
(define (mark-solve-stale! cache scope-id) (hash-set! (solve-cache-stale-solves cache) scope-id #t))
(define (solve-stale? cache scope-id) (hash-ref (solve-cache-stale-solves cache) scope-id #f))
(define (planned-material cache scope-id)
  "The material rows of the scope's last plan: every produce, consume, pickup, dropoff
   and use it expects, each a Commitment, or none before a first solve."
  (solve-part (last-solve-ref cache scope-id) 'material))
(define (planned-runs cache scope-id)
  "The runs the scope's last plan names: ((run . recipe-process) …), each run a Process of
   its own that its relocation rows are the inputs and outputs of."
  (solve-part (last-solve-ref cache scope-id) 'runs))
(define (planned-rows cache scope-id action spec place when-iso proc)
  "The material rows of the scope's last plan that are the row ACTION SPEC at PLACE
   of PROC (at WHEN-ISO when one is named). What a confirmation may record is what
   the plan states."
  (filter (lambda (m)
            (and (equal? (format #f "~a" (row-action m)) action)
                 (equal? (row-spec m) spec)
                 (equal? (or (row-place m) "") (or place ""))       ; the wire spells an absent value ""
                 (equal? (or (row-run m) "") (or proc ""))
                 (or (not when-iso) (equal? when-iso "") (equal? (format #f "~a" (row-when m)) when-iso))))
          (planned-material cache scope-id)))
(define (hold-row! obs scope-id m)
  "Register the plan's row M as the commitment it is, under the plan's own row id: a
   row the plan states again moves its target and keeps what was confirmed."
  ($ obs 'register-commitment (held-commitment m scope-id)))
;; the record-flow door names one of its arguments `row-id` (the protocol declares it);
;; under that name the door reads a row's id by this one
(define planned-row-id row-id)
(define (row-left obs m)
  "What the events fulfilling plan row M have not yet met of it."
  (fulfillment-remaining ($ obs 'get-fulfillment (row-id m))))
(define (cache-solve! cache scope-id demand alist)
  "A plan landed for SCOPE-ID, solved for DEMAND: keep it, warm the next solve
   from it, stand its claims, note its externalities, and tell the service.
   Answers the plan as it leaves the process."
  (let* ((xrow  (assq 'x alist))
         (alist (if xrow (assq-remove! (list-copy alist) 'x) alist))
         (alist (plan-with-own-time cache scope-id alist)))
    (when (and scope-id (list? demand))
      ;; a plan that is NOT a plan warms nothing: a certificate that refused
      ;; the point (feasible? #f — phase-I's exterior start handed back) would
      ;; start the next solve where this one could not get in, and it
      ;; stayed out (found live: steps=0, the same program solving cold in
      ;; 25 steps). The standing warm start stands until a plan replaces it.
      (when (and xrow
                 (let ((c (assq-ref alist 'certificate)))
                   (not (and (list? c) (eq? #f (assq-ref c 'feasible?))))))
        (hash-set! (solve-cache-warm-x cache) scope-id (cdr xrow)))
      ;; the discrete state the search left seeds the next search (solve/discrete.scm)
      (let ((d (assq-ref alist 'decided)))
        (if d (hash-set! (solve-cache-decided cache) scope-id d)
            (hash-remove! (solve-cache-decided cache) scope-id)))
      (let ((now (instant->unix (clock-now))))
        (hash-set! (solve-cache-solve-at cache) scope-id now)
        (hash-set! (solve-cache-solve-vocab cache) scope-id (stock-vocabulary))
        (hash-remove! (solve-cache-stale-solves cache) scope-id)
        (last-solve-set! cache scope-id (cons demand alist) now))
      (plan-claims! cache scope-id alist)          ; the plan's claims stand as the commitments a claim fulfils
      (note-externalities! cache scope-id alist)   ; the burn-meter hears it too
      ;; the slack fold hears every solve that lands (set by the service)
      (let ((hear (solve-cache-on-cached cache))) (when hear (hear scope-id))))
    ;; what a door replies with: the plan as it leaves the process
    (plan->rows alist)))

;; ── the plan's claims, minted as the commitments a claim fulfils ────────────
;; Each `claims` row of a landed plan (claimant, spec, quantity, place, period)
;; is registered on the scope's observer as a `transfer` commitment
;; (account.scm claim-commitment); the ledger records a claim event only against
;; one, for no more than remains on it. Rows the new plan no longer states are
;; retired while still open, so a stale plan's word admits nothing; a partly
;; confirmed row the plan restates keeps what was confirmed (the observer reads
;; fulfilment off the events, so a row stated again moves its target only).
;; Outside a service (mocks, unit worlds) there is no observer to mint on, and
;; the plan's rows are read from the alist alone. A row's silence is not a
;; statement: a solve that carries no `claims` key (a federated row states
;; materials and crossings only) says nothing about claims, so the standing
;; commitments stay; a plan that states `claims '()` retires them.
(define (plan-claims! cache scope-id alist)
  (let ((obs ((solve-cache-observer-of cache) scope-id)))
    (when (and obs (assq 'claims alist))
      (let* ((rows (or (assq-ref alist 'claims) '()))
             (fresh (map (lambda (r)
                           (claim-commitment (row-spec r) (assq-ref r 'claimant)
                                             (row-quantity r) scope-id
                                             #:place (row-place r)
                                             #:when-iso (let ((p (assq-ref r 'period))) (and p (format #f "~a" p)))))
                         rows))
             (keep  (map commitment-id fresh)))
        (for-each (lambda (fs)
                    (let ((cid (fulfillment-state-commitment-id fs)))
                      (unless (member cid keep) ($ obs 'retire-commitment cid))))
                  (claim-fulfillments obs))
        ;; every row the plan states is registered: a row it restates moves the
        ;; commitment's target, and what was confirmed is read off the events, so a
        ;; restated or withdrawn-and-restated row keeps its confirmations
        (for-each (lambda (c) ($ obs 'register-commitment c)) fresh)))))

;; one scope's OWN slack cells off its cached solve — (want . place) and
;; (met . place), the per-place sums location-slacks takes the ratio of. Own
;; means the places the scope's own store holds: a scope's solve answers for
;; the demand of its whole subtree, so its cached rows also name its members'
;; places, and those places' cells are the members' to state (the parent adds
;; what its children climb with, and would otherwise hold them twice).
(define (scope-own-slack cache scope-id)
  (let ((cached (last-solve-ref cache scope-id))
        (own ((solve-cache-own-places-of cache) scope-id)))
    (define (own? place) (or (not own) (member place own)))
    (if (not cached) '()
        (let ((want (make-hash-table)) (met (make-hash-table)))
          (for-each (lambda (d)
                      (when (and (list? d) (>= (length d) 4) (string? (list-ref d 1)) (own? (list-ref d 1)))
                        (let ((place (list-ref d 1)) (q (or (list-ref d 3) 0)))
                          (hash-set! want place (+ (hash-ref want place 0) q)))))
                    (car cached))
          (for-each (lambda (m)
                      (when (memq (row-action m) creating-actions)
                        (let ((place (row-place m)) (q (or (row-quantity m) 0)))
                          (when (and (string? place) (own? place))
                            (hash-set! met place (+ (hash-ref met place 0) q))))))
                    (solve-part cached 'material))
          (append (hash-map->list (lambda (p q) (cons (cons 'want p) q)) want)
                  (hash-map->list (lambda (p q) (cons (cons 'met p) q)) met))))))

;; the plan's time, counted where the people are at home. The solve states each
;; person's planned and offered hours (solve/report.scm by-person); a person is
;; counted once, at the scope they are at home in (the home rule, one home per
;; person: doors/service.scm home-scope-of), so a plan that places a visitor, or
;; a parent's plan that places its children's people, leaves them to their own
;; scope. What the plan then carries is two nameless sums, (plan-time (planned
;; . P) (offered . O)), and the names stay inside the solve. A plan with no
;; per-person block says nothing of time and is returned as it came.
(define (plan-with-own-time cache scope-id alist)
  (let* ((social (assq-ref alist 'social))
         (by-person (and (pair? social) (assq 'by-person social))))
    (if (not by-person)
        alist
        (let* ((home-of (solve-cache-home-of cache))
               (mine (filter (lambda (r) (equal? (home-of (car r)) scope-id)) (cdr by-person))))
          (acons 'plan-time
                 `((planned . ,(fold + 0.0 (map cadr mine))) (offered . ,(fold + 0.0 (map caddr mine))))
                 (plan-without-person-time alist))))))

;; one scope's OWN plan-time cells off its cached solve — (planned . *) and
;; (offered . *), the hours its plan places on the people at home here and the
;; time they have, summed nameless (the keyed sum of pools/free-time-fold.scm).
;; #f when the plan states no time (a federated row carries materials and
;; crossings only): a row's silence is not a statement, so the cells the scope
;; already holds stand.
(define (scope-own-plan-time cache scope-id)
  (let* ((cached (last-solve-ref cache scope-id))
         (time (and cached (assq-ref (cdr cached) 'plan-time))))
    (and time
         (list (cons '(planned . *) (assq-ref time 'planned))
               (cons '(offered . *) (assq-ref time 'offered))))))
