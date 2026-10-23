;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/availability-pool.scm — Labour pool from agent availability.
;;;
;;; Availability lives on the agent, not in scopes. An agent has one
;;; body, one availability-window, one set of skills. Scopes are the
;;; communication medium through which availability propagates upward
;;; through the federation hierarchy toward the Universal Commune.
;;;
;;; The pool at any scope is a query: walk the membership graph,
;;; collect the agents reachable through the subtree, read each
;;; agent's availability-window + skills (EconomicResources), and
;;; project into the spatial index. One person is written at one home
;;; (doors/service.scm `home-scope-of`), so an entry arrives once; the
;;; merge below is a join for the record that arrives twice all the same,
;;; and a person's hours are counted once however many skills they hold.
;;;
;;; This is NOT the observer. The observer tracks custodied resources
;;; and work events. The labour pool reads agent availability and
;;; skill inventory to answer "who can work where/when on what?"

(define-module (playnet pools availability-pool)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet vf facts availability)
                #:select (window-weekly-hours window-hours-on-dates))
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet matching schemas)
  #:use-module (playnet matching spatial)
  #:use-module (playnet vf facts availability)
  #:use-module ((playnet vf facts agent-time) #:select (agent-schedulable-window agent-away-dates away-count reserve-hours))
  #:use-module ((playnet solve ingest) #:select (*default-agent-hours*))
  #:export (make-labour-pool labour-pool?
            pool-entries pool-by-agent
            pool-add pool-remove pool-merge
            pool-query pool-free pool-total-hours pool-agent-hours pool-withdraw-agent entry-hours-on
            build-pool-from-agents
            make-entry entry-agent entry-skill entry-window entry-hours entry-cell entry-place entry-away
            resolve-cell
            *location-resolver*))


;;; ── Location resolution ─────────────────────────────────────────────────────

(define *location-resolver* (make-parameter #f))

(define (resolve-cell agent)
  "H3 cell for an agent's primary location, or *remote-h3-index*."
  (let ((loc (agent-primary-location agent))
        (resolve (*location-resolver*)))
    (cond ((not loc) *remote-h3-index*)
          ((not resolve) *remote-h3-index*)
          (else (or (resolve loc) *remote-h3-index*)))))


;;; ── Pool entry (agent × skill projection) ───────────────────────────────────
;;; Not a VF type — a lightweight projection of (agent, skill, window,
;;; cell, hours) for spatial indexing. Derived from Agent's own fields; HOURS is
;;; the window's week (window-weekly-hours), the one date-free measure it has.

(define* (make-entry agent-id skill-spec-id window cell hours #:optional (place #f) (away '()))
  ;; PLACE is the agent's own primary location — the key the located solve
  ;; files labour under. CELL is its H3 resolution for spatial queries. An
  ;; entry carries both so a world rebuilt from entries stands where the
  ;; person stands; absent, the agent is placeless (remote). AWAY is the
  ;; agent's own declared dates (agent-away-dates): carried here because a
  ;; windowless entry has no window to net them from, and entry-hours-on
  ;; still owes the query the dates it asked about.
  `((agent . ,agent-id) (skill . ,skill-spec-id)
    (window . ,window) (cell . ,cell) (hours . ,hours) (away . ,away)
    ,@(if place `((place . ,place)) '())))
(define (entry-place e) (assq-ref e 'place))

(define (entry-agent e) (assq-ref e 'agent))
(define (entry-skill e) (assq-ref e 'skill))
(define (entry-window e) (assq-ref e 'window))
(define (entry-cell e) (assq-ref e 'cell))
(define (entry-hours e) (assq-ref e 'hours))
(define (entry-away e) (or (assq-ref e 'away) '()))
(define (entry-key e) (cons (entry-agent e) (entry-skill e)))

(define (assq-ref alist key)
  (let ((p (assq key alist))) (if p (cdr p) #f)))


;;; ── Labour pool ─────────────────────────────────────────────────────────────

(define-record-type <labour-pool>
  (%make-pool entries by-agent)
  labour-pool?
  (entries  pool-entries)
  (by-agent pool-by-agent))

(define (make-labour-pool)
  (%make-pool '() (hashmap)))


;;; ── Add / Remove ────────────────────────────────────────────────────────────

(define (pool-add pool entry)
  (let* ((aid (entry-agent entry))
         (by-a (pool-by-agent pool)))
    (%make-pool (cons entry (pool-entries pool))
                (hashmap-set by-a aid
                             (cons entry (hashmap-ref by-a aid '()))))))

(define (pool-remove pool agent-id skill)
  (let* ((match? (lambda (e) (and (equal? (entry-agent e) agent-id)
                                  (equal? (entry-skill e) skill))))
         (by-a (pool-by-agent pool)))
    (%make-pool (filter (lambda (e) (not (match? e))) (pool-entries pool))
                (hashmap-set by-a agent-id
                             (filter (lambda (e) (not (match? e)))
                                     (hashmap-ref by-a agent-id '()))))))


;;; ── Merge: the pool's ⊕ in the federation fold ──────────────────────────────
;;; Two scopes' pools combined into one. An agent has ONE body, so (agent,
;;; skill) identifies an entry and the merge is a union, not a sum: B's entry
;;; wins where both have one, which makes the merge idempotent (merging a pool
;;; with itself changes nothing) and order-independent for the disjoint member
;;; sets a real federation has. That is what lets a parent recombine its
;;; children's totals on every read without drift — see aggregation/fold-node.

;; The fold's combine over labour. Keyed by (agent . skill): a person appears
;; once per skill in the total. The tree combines children in hashmap order,
;; so the merge must be COMMUTATIVE — a collision on a key (the same person
;; declared in two scopes) resolves by the entries themselves, never by which
;; side arrived: the entry with MORE hours stands (a person's fuller
;; declaration), and equal hours resolve by what else the entries carry — window,
;; cell, place, away dates — printed and compared, so the choice is a total
;; order — identical entries are one entry. What the
;; resolution does NOT do is add the hours: a person active in two communes
;; has one week, and the union keeps one reading of it; deployment
;; (uc-matching) books each body once per time bucket and spends one hour
;; budget across its skills. Which reading is right when two scopes disagree is the same
;; question docs/planning/federation/capacity-combine-across-scopes.md asks of CCF.
(define (entry-order-key e)
  "Everything an entry carries beside its hours, as one string to order by."
  (object->string (list (entry-window e) (entry-cell e) (entry-place e) (entry-away e))))
(define (entry-beats? x y)
  ;; a TOTAL order: more hours first, and where hours tie, the entry whose
  ;; remaining content prints first — so the merge keeps the same one of two
  ;; arrivals whichever came first
  (let ((hx (entry-hours x)) (hy (entry-hours y)))
    (or (> hx hy)
        (and (= hx hy)
             (string<? (entry-order-key x) (entry-order-key y))))))
(define (pool-merge a b)
  (fold (lambda (e pool)
          (let ((prior (find (lambda (p) (equal? (entry-key p) (entry-key e)))
                             (hashmap-ref (pool-by-agent pool) (entry-agent e) '()))))
            (if (and prior (not (entry-beats? e prior)))
                pool                                         ; the standing entry wins
                (pool-add (pool-remove pool (entry-agent e) (entry-skill e)) e))))
        a (pool-entries b)))


;;; ── Build from agents + skills ──────────────────────────────────────────────

(define* (build-pool-from-agents agents #:key skills-for-agent)
  "Build the pool from a list of VF Agent records.
   SKILLS-FOR-AGENT: (agent-id → (skill-spec-id ...)) — typically
   backed by the observer's agents-with-skill index.
   Each agent's availability-window is read directly from the agent
   record — the single source of truth."
  (fold (lambda (agent pool)
          (let* ((aid (agent-id agent))
                 (aw  (agent-schedulable-window agent))
                 (cell (resolve-cell agent))
                 ;; a week, kept inside what the body leaves of it — no window
                 ;; at all reads the same flat default as the roster's own
                 ;; fallback (labour-fold's refold-agent), not a bare zero
                 (hours (reserve-hours agent 7 (if aw (window-weekly-hours aw) (* 7 *default-agent-hours*))))
                 (away (agent-away-dates agent))
                 (skills (if skills-for-agent
                             (skills-for-agent aid)
                             '())))
            (if (zero? hours) pool
                (fold (lambda (sk pool)
                        (pool-add pool (make-entry aid sk aw cell hours #f away)))
                      pool skills))))
        (make-labour-pool)
        agents))


;;; ── Query ───────────────────────────────────────────────────────────────────

(define* (pool-query pool #:key skill cell radius time-window)
  "Query pool entries matching criteria."
  (filter (lambda (e)
            (and (or (not skill)
                     (equal? (entry-skill e) skill))
                 (or (not cell)
                     (let ((ec (entry-cell e)))
                       (or (equal? ec *remote-h3-index*)
                           (equal? ec cell)
                           (and radius
                                (member ec
                                        (get-cells-in-radius cell radius))))))
                 (or (not time-window)
                     (let ((ew (entry-window e)))
                       (or (not ew)
                           (availability-windows-overlap?
                            time-window ew))))))
          (pool-entries pool)))

(define (entry-hours-on e dates)
  "The hours entry E offers on DATES — its window read against them; an entry
   with no window offers its week's hours spread evenly, a working day each
   day, less whichever of DATES the agent declared away (§2c) — there is no
   window to net those from, so entry-away carries them here instead. This
   is the reading a demand with dates is met by; `entry-hours` alone is the
   week."
  (let ((w (entry-window e)))
    (if w (window-hours-on-dates w dates)
        (* (/ (entry-hours e) 7)
           (- (length dates) (away-count (entry-away e) dates))))))

(define* (fullest-per-agent entries #:optional (dates '()))
  "ENTRIES as a hashmap agent → hours: a person at their fullest entry, since
   each (agent, skill) entry carries the same body's whole week (or, with DATES,
   the hours that body offers on them) and a body works it once."
  (fold (lambda (e best)
          (let ((h (if (null? dates) (entry-hours e) (entry-hours-on e dates))))
            (hashmap-set best (entry-agent e) (max h (hashmap-ref best (entry-agent e) 0)))))
        (hashmap) entries))

(define (pool-total-hours pool . query-args)
  ;; hours a WEEK — a person's hours counted ONCE however many skills they hold.
  ;; Of the entries a query matches, a person stands at their fullest.
  (hashmap-fold (lambda (_aid hours acc) (+ hours acc))
                0
                (fullest-per-agent (apply pool-query pool query-args))))

(define* (pool-agent-hours pool aid #:optional (dates '()))
  "The hours AID offers: their fullest entry's week, or its reading on DATES."
  (hashmap-ref (fullest-per-agent (hashmap-ref (pool-by-agent pool) aid '()) dates) aid 0))

(define (pool-withdraw-agent pool aid)
  "POOL without any entry of AID's, whatever the skill."
  (fold (lambda (e p) (pool-remove p (entry-agent e) (entry-skill e)))
        pool
        (hashmap-ref (pool-by-agent pool) aid '())))

;;; ── Subtract deployed → residual ────────────────────────────────────────────

(define (pool-free pool commitments)
  "Subtract deployed agents. COMMITMENTS is a list of VF Commitments."
  (fold (lambda (cmt p)
          (pool-remove p
                       (commitment-provider cmt)
                       (commitment-resource-conforms-to cmt)))
        pool commitments))
