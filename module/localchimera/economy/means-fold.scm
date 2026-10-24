;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; economy/means-fold.scm — the scope tree's standing capacity → what a solve may draw
;;;
;;; The labour pool's twin, over means (docs/planning/federation/means-pool-uc-allocation.md,
;;; patchwork-scopes-containment.md §2.1 / work-plan step 3). `fold-node.scm`
;;; names this aggregate in its own header — "capacity: service facts summed by
;;; cell (same monoid as demand)" — and this file is that column: labour, demand
;;; and taxonomy each have a standing fold node, and with this one capacity
;;; aggregates for ALLOCATION, where `global-total-social-svc` (account.scm)
;;; sums it flat for the dividend — an accounting read, not this one.
;;;
;;;   monoid   service capacities summed by (spec ⇥ place) — keyed-sum
;;;   writes   capacity-changed: re-derive this scope's OWN facts
;;;   reads    capacity-facts: the ((spec place cap) …) shape `svc-eco-caps`
;;;            and `commune-socialized-caps` already consume
;;;
;;; ── What rises is a total, never an inventory ───────────────────────────────
;;; A scope hands up how much `Svc|spec` stands available per place — nothing
;;; about which machine, whose grant, or what condition it is in. Two lathes in
;;; one workshop rise as one number, exactly as ten people wanting a loaf rise
;;; as demand for ten. Refederation stays two exact messages (fold-node.scm).
;;;
;;; ── The place in the key is the SPAN, not the location ─────────────────────
;;; The cell a capacity rises under is where its pool is constituted: the
;;; scope's live span declaration when one exists (`live-span-of`), else the
;;; holding place — the same rule the pool-builder itself reads (*span-of*,
;;; planner.scm), so the fold and the solve cannot disagree about where a means
;;; serves. Location stays a fact on the record; only the key follows the
;;; declaration.
;;;
;;; ── What counts, in this slice ──────────────────────────────────────────────
;;; TIME-RATE holdings — `40 hours/day` of a lathe, `200 seat-hours/week` — the
;;; shape a standing service has. The value summed is the rate normalised to
;;; unit-hours per day (`holding-capacity` over a 24 h day), so two rates with
;;; different denominators sum honestly. Time BUDGETS (`200 hours`, no
;;; denominator) are one bar over a window, not a standing per-day flow, and
;;; count-denominated durables (`3 each` of oven) render service only through a
;;; recipe's `use` — both enter the fold when the planner's own denomination
;;; work gives them a standing per-day reading; folding them as rates today
;;; would state a number the solve would not honour.
;;;
;;; Reads socialization.scm (live-span-of) and follows demand-fold.scm's idioms.

;; The cell key is the pair (spec . place) — `sum-by-key` hashes by equal?, so
;; nothing needs encoding into a string and back (the tab-joined key in
;; demand-fold earns its keep by carrying a 4-part window; a 2-part key does
;; not). One day of standing service is the normalisation every rate sums in.
(define-module (localchimera economy means-fold)
  #:use-module (localchimera solve federation-solve)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera economy socialization)
  #:use-module (localchimera vf aggregation containment)
  #:use-module (localchimera vf formulas capacity)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module (localchimera utils units)
  #:use-module (goblins)
  #:export (%hours-per-day %service-rate %pool-place %capacity-cell capacity-cells
            scope-own-capacity means-monoid capacity-facts means-reads means-writes
            ^means-pool scope-subtree-capacity wire-means-node! means-refold-listener
            common-span-defaults means-withholding withholding-snapshot capacity-bars))

(define %hours-per-day 24.0)

;; a holding's standing service in unit-hours/day, or #f when it is not a
;; TIME-rate (`hours/day`, `seat-hours/week` — a rate whose numerator is time;
;; the substance of the rate itself is 'rate, so the numerator is what is
;; asked). The one place the slice's what-counts rule lives.
(define (%service-rate r)
  (let* ((m (economic-resource-onhand-quantity r))
         (q (and m (measure-has-numerical-value m)))
         (u (and m (measure-has-unit m))))
    (and q (> q 0) u (unit-rate? u)
         (let ((parts (unit-rate-parts u)))
           (and parts (eq? 'time (unit->substance (car parts)))))
         (holding-capacity q m r %hours-per-day))))

;; where a holding's pool stands: the declared span, else the holding place
;; (the location walk is socialization.scm's %socialization-place-of — the
;; oven inherits the flat's place).
(define (%pool-place r span-of resources)
  (or (and span-of (assoc-ref span-of (economic-resource-id r)))
      (%socialization-place-of resources r)))

;; a resource's standing service fact — ((spec . place) . unit-hours/day) — or #f.
(define (%capacity-cell r span-of resources)
  (let ((spec (economic-resource-conforms-to r))
        (cap  (%service-rate r))
        (place (%pool-place r span-of resources)))
    (and spec cap place (cons (cons spec place) cap))))

(define* (capacity-cells resources #:key (span-of '()) (durable? #f))
  "The (((spec . place) . unit-hours/day) …) cells RESOURCES contribute — the
   pure core of a scope's own capacity, testable without a vat.

   DURABLE? (spec → bool), when given, admits COUNT-denominated holdings too:
   `3 each` of a durable renders 3 × 24 unit-hours per day (`holding-capacity`'s
   stock reading — three ovens over a day are seventy-two oven-hours). The
   signal is injected because the recipe store already carries it — a spec
   some recipe `use`s IS a durable, a spec only ever consumed is not — so the
   fold states no second opinion about what renders service. Absent, the
   time-rate-only slice stands unchanged."
  (sum-cells
   (filter-map
    (lambda (r)
      (or (%capacity-cell r span-of resources)
          (and durable?
               (let* ((spec (economic-resource-conforms-to r))
                      (m (economic-resource-onhand-quantity r))
                      (q (and m (measure-has-numerical-value m)))
                      (place (%pool-place r span-of resources)))
                 (and spec q (> q 0) (durable? spec) place
                      (cons (cons spec place)
                            (holding-capacity q m r %hours-per-day)))))))
    resources)))

(define* (scope-own-capacity scope-root #:key (span-of '()))
  "One scope's OWN contribution to the means fold: the standing service its
   observer's resources render, summed per (spec, span-place). A total, with no
   machine's id and no owner's name in it."
  (capacity-cells ($ ($ scope-root 'observer) 'all-resources) #:span-of span-of))

(define means-monoid keyed-sum-monoid)

(define (capacity-facts total)
  "TOTAL as ((spec place cap) …) — the fact shape `svc-eco-caps` projects onto a
   solve's periods and `commune-socialized-caps` already emits, so a consumer
   needs no third form."
  (map (lambda (cell) (list (caar cell) (cdar cell) (cdr cell))) total))

(define means-reads
  `((capacity-facts . ,(lambda (total) (capacity-facts total)))
    (cells          . ,(lambda (total) total))))

(define means-writes
  `(;; re-derive this scope's own facts — the seed, and the repair. Resources
    ;; change rarely next to needs, so the full re-read is the whole write path.
    (capacity-changed . ,(lambda (own scope-root span-of)
                           (scope-own-capacity scope-root #:span-of span-of)))))

;; A scope's capacity aggregate: its OWN standing service, its members' totals
;; keyed beside it — the ^labour-pool / ^demand-node sibling, over means.
(define ^means-pool
  (fold-aggregate means-monoid means-reads means-writes #:prefix "means"))

;; ── the pull: the same fold, as its definition ──────────────────────────────

(define* (scope-subtree-capacity scope #:key (span-of '()))
  "The capacity a solve rooted at SCOPE may draw on, read straight off the live
   tree — the fact shape, whole subtree, one walk. What a node's standing total
   MEANS, and how one is seeded or repaired."
  (capacity-facts
   (fold-tree-total means-monoid scope
                    (lambda (root) (scope-own-capacity root #:span-of span-of)))))

;;; ── wiring a scope into the fold ────────────────────────────────────────────

(define* (wire-means-node! scope-root node
                           #:key (span-of '()) (parent #f) (scope-id #f)
                                 (schedule #f))
  "Wire a scope's means node into the federation fold: seed OWN from the
   observer now, hand the TOTAL to PARENT keyed by SCOPE-ID (so refederation is
   a drop and a delivery), coalesce bursts via SCHEDULE. Re-seeding after a
   resource change is the caller's `($ node 'capacity-changed scope-root
   span-of)` — resources arrive through ingest and custody events, which the
   holder of those wires re-fires; nothing here polls."
  (when schedule ($ node 'set-schedule schedule))
  ($ node 'capacity-changed scope-root span-of)
  (wire-fold-parent! node parent scope-id))

;; the composable refold trigger for the observer's SINGLE on-event slot
;; (observer.scm: set-callback shadows — the gateway's ACDC emission may
;; already live there, so the HOOKING is the caller's, where composition is
;; possible; this is only the listener). Any event that touched a resource
;; refolds this scope's own capacity.
(define (means-refold-listener node scope-root span-of)
  (lambda (event affected)
    (when (pair? affected)
      ($ node 'capacity-changed scope-root span-of))))

;; ── The default span flips with the property form (patchwork §4a) ───────────
;;
;; An OFFERED means defaults to its holding place — the conservative reading
;; that respects an absent owner. A COMMON means has no local owner to respect:
;; defaulting it to the holding place is local capture of exactly the property
;; that belongs to everyone. Its default is the WIDEST span — the root of the
;; containment tree its holding place stands in — narrowed only by a live
;; UC-issued declaration (which, appended before these defaults, wins the
;; assoc lookup) or by willingness and physics at placement.
(define* (common-span-defaults resources spatials rights-of)
  "((resource-id . root-place) …) for the COMMON time-rate holdings in
   RESOURCES — the widest-span default. RIGHTS-OF marks which are common;
   append AFTER a declarations view so declarations win the lookup."
  (let* ((by-id   (let ((h (make-hash-table)))
                    (for-each (lambda (s) (hash-set! h (spatial-thing-id s) s)) spatials)
                    h))
         (resolve (lambda (id) (hash-ref by-id id #f)))
         (root-of (lambda (place)
                    (let ((chain (and=> (resolve place)
                                        (lambda (p) (containment-chain p
                                                      #:parent-of spatial-thing-contained-in
                                                      #:resolve resolve)))))
                      (if (and chain (pair? chain))
                          (spatial-thing-id (last chain))
                          place)))))
    (filter-map
     (lambda (r)
       (and (eq? 'common (rights-of (economic-resource-id r)))
            (%service-rate r)
            (let ((place (%socialization-place-of resources r)))
              (and place (cons (economic-resource-id r) (root-of place))))))
     resources)))

;; ── Withholding: reach − span, the readable figure (step 5) ──────────────────
;;
;; Once span is declared rather than inferred, the gap between what a means
;; COULD serve and what its pool DOES serve is a number — the quantifiable form
;; the withheld-recognition pattern requires, and a sharper trigger for the
;; redistribution mandate than a custody threshold (patchwork doc §2.3).

(define* (means-withholding resources spatials
                            #:key (span-of '()) (reach-of #f))
  "The withheld service among RESOURCES: for each time-rate holding whose REACH
   is not covered by its pool, one record

     (spec span-place reach-place unit-hours/day)

   — the hours that could serve within reach and pool somewhere narrower.

   REACH-OF (resource-id → place or #f) is the physics — how far this means
   could actually serve, movability and transport priced by whoever answers —
   and it is INJECTED like every judgment here (home-of, place-scope-of): the
   fold does not invent reach, so a means nobody has stated a reach for yields
   no figure rather than a guessed one. SPATIALS carry the containment tree the
   coverage test walks: reach is COVERED when the pool stands at the reach
   place itself or at an ancestor of it (a town-spanning pool covers every
   workshop in the town). A disjoint span withholds its whole rate — pooling a
   means away from where it could serve is the case the figure exists to show."
  (let* ((by-id   (let ((h (make-hash-table)))
                    (for-each (lambda (s) (hash-set! h (spatial-thing-id s) s)) spatials)
                    h))
         (resolve (lambda (id) (hash-ref by-id id #f)))
         (covers? (lambda (span-place reach-place)
                    (or (equal? span-place reach-place)
                        (let ((reach (resolve reach-place)))
                          (and reach
                               (member span-place
                                       (map spatial-thing-id
                                            (containment-chain reach
                                              #:parent-of spatial-thing-contained-in
                                              #:resolve resolve)))
                               #t))))))
    (filter-map
     (lambda (r)
       (let* ((spec  (economic-resource-conforms-to r))
              (cap   (%service-rate r))
              (span  (%pool-place r span-of resources))
              (reach (and reach-of (reach-of (economic-resource-id r)))))
         (and spec cap span reach
              (not (covers? span reach))
              (list spec span reach cap))))
     resources)))

;; ── The wheel's read: withholding records → fragility controls ───────────────
;;
;; The fragility face renders one `kind:withheld` sector per record — the
;; figure (unit-hours/day) as the level, span→reach as the hover detail. One
;; canonical converter, so the gateway's fragility push and any
;; snapshot emitter serialize the same alist shape the wheel's rented sector
;; already reads (service.scm rented-controls).
(define (withholding-snapshot records)
  "The fragility face's control alists from MEANS-WITHHOLDING records: one
   `kind:withheld` control per (spec span reach unit-hours/day) — the withheld
   hours as `current`, the whole rate as `tip`, slack at the wall (the whole
   rate pools out of reach), span/reach carried for the hover detail."
  (map (lambda (rec)
         (let ((spec (car rec)) (span (cadr rec))
               (reach (caddr rec)) (cap (cadddr rec)))
           `((spec . ,spec) (kind . "withheld")
             (control . ,spec) (group . "withheld")
             (unit . "unit-hours/day") (w . 1)
             (span . ,span) (reach . ,reach)
             (current . ,cap) (tip . ,cap) (s . 1e-3)
             (source . "pooled narrower than its reach — hours that could serve wider (means-withholding)"))))
       records))

;; ── The fold feeds the consensus row (the glue the two builds share) ─────────
;;
;; allocate-means-consensus (solve/federation-solve.scm) takes one TOTAL per
;; means-spec — the commons' bar. That total is exactly what the means fold
;; already carries: a node's capacity-facts, summed over places. So the bar the
;; federation allocates is the bar the scopes' own standing declarations
;; constituted, span-keyed and consent-gated on the way up — no second census.
(define (capacity-bars facts)
  "((spec . total-unit-hours/day) …) from the ((spec place cap) …) fact shape —
   a fold total or `scope-subtree-capacity` read, collapsed to the per-spec
   bars the consensus row takes."
  (sum-cells (map (lambda (f) (cons (car f) (caddr f))) facts)))
