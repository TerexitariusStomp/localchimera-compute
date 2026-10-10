;;; compliance.scm — the SUPPLY side of the legal layer: what we HOLD, folded
;;; over the VF event log, reconciled against what the state DEMANDS.
;;; @defines compliance
;;;
;;; Design: docs/legal/legal-compliance-lifecycle.md. `legal/registry.scm`
;;; computes the DEMAND bill (what is required); this file answers "do we hold
;;; it?" — and it introduces NO new store. A permit / licence / registration is
;;; an ordinary <economic-resource> conforming to a <resource-specification>
;;; (the demand's spec), custodied by an <agent>; its lifecycle IS the observer's
;;; economic-event log; its status is a FOLD over that log (Technical appendix).
;;; The state is just one more <agent> — an external "authority" sink.
;;;
;;; Three folds, all reading the LIVE ^observer (no bespoke machinery):
;;;   holding-status  — does subject hold a VALID resource conforming to spec?
;;;   reconcile       — the demand bill ⋈ holdings → per-demand status
;;;   obligations     — the calendar: Commitments due to an authority, by cadence
;;;
;;; And one PLANNER bridge that needs no planner edit:
;;;   make-legal-decorate/observer — the #:legal-decorate closure, now aware of
;;;   custody: a required ENTITY permit not held ⟹ prune the column (a
;;;   possibility-tension), exactly as a missing competence already prunes via
;;;   the skill mechanism (skilled-worker-at?, legal/gate.scm).
;;;
;;; Time is passed in (an ISO-8601 string), never read from a clock, so every
;;; fold is pure and replayable. ISO-8601 dates compare correctly with string<=?
;;; (zero-padded lexical order = chronological order), so no epoch parsing.
;;;
;;; Run the demo:  guile -L module module/playnet/legal/compliance.scm

(define-module (playnet legal compliance)
  #:use-module (playnet legal gate)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:export (%cx-dir authority-class authority-agent? make-authority demand->spec-id
            demand-key bad-states resource-held-by? resource-onhand>0?
            resource-state-ok? %min-exp resource-expiration resource-unexpired-at?
            resource-valid-at? holding-status reconcile entry-status entry-gap?
            reconcile-gaps iso-date iso-minus-days make-obligation obligation-for
            demand-cadence bill->specs+cadence bill-obligations obligations
            make-legal-decorate/observer scope-legal-decorate
            compliance-demo)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond lot)
  #:use-module (playnet legal registry)
  #:use-module (playnet legal registry-actor)
  #:use-module ((playnet utils clock) #:select (now instant->civil))
  #:use-module (playnet legal policy)
  #:use-module ((playnet legal bodies) #:select (all-bodies scope-body-subject scope-body-at body-facts)))


;; deps: the demand vocabulary + fold, and its actor. The actor is still a
;; fragment, so it keeps the defined?-guarded load; the registry is a module.
;; where this file stands, on a host; a page has no files and reads the tree's own path
(define %cx-dir (cond-expand (guile (or (and=> (current-filename) (lambda (f) (dirname (dirname f)))) "module/playnet"))
                             (else "module/playnet")))
              ; agent/resource/commitment records
       ; the demand vocabulary + fold
 ; ^legal-registry, one per scope root
  ; today, on the one clock
         ; the commune's own tolerance, governed

;;; ─── authorities : the state is an external <agent> sink ─────────────────
;;; An authority (county health dept, FinCEN, customs) is an ordinary <agent>
;;; tagged "authority" in classified-as — outside the Markov blanket, like
;;; nature and markets. A holding's issuer / an obligation's receiver is one.
(define authority-class "authority")
(define (authority-agent? a)
  (and (agent? a)
       (let ((c (agent-classified-as a))) (and (list? c) (member authority-class c) #t))))
(define* (make-authority id name #:optional (extra-class '()))
  (make-agent #:id id #:type 'organization #:name name
              #:classified-as (cons authority-class extra-class)))

;;; ─── the join key : demand-name IS the spec id ───────────────────────────
;;; A person `obtain`'s skill id is its demand-name (legal/gate.scm
;;; `legal-licence-skill`); we extend the same identity to entity `obtain`s, so
;;; a required credential and the <resource-specification> that satisfies it
;;; share one id. Jurisdiction lives on the FIRING RULE, not the demand, so the
;;; reconciliation key carries the rule's label as provenance.
(define (demand->spec-id d) (demand-name d))
(define (demand-key jurisdiction d subject)
  (list jurisdiction (demand-name d) subject))

;;; ─── validity of ONE held resource, as-of a time ─────────────────────────
;;; A resource satisfies a demand at `as-of` iff it is in the subject's hands,
;;; non-empty, in a usable state, and unexpired. Expiry lives on the batch
;;; (batches-for-resource → <batch-lot-record> with an ISO expiration-date), like
;;; any lot-controlled good; #f expiration ⟹ never expires.
(define bad-states '("expired" "revoked" "suspended" "void" "cancelled"))
(define (resource-held-by? r subject holder-field)
  (case holder-field
    ((primary-accountable) (equal? subject (economic-resource-primary-accountable r)))
    ((custodian-scope)     (equal? subject (economic-resource-custodian-scope r)))
    ((either)              (or (equal? subject (economic-resource-primary-accountable r))
                              (equal? subject (economic-resource-custodian-scope r))))
    ((any)                 #t)   ; held by anyone — scope-agnostic presence check
    (else                  (equal? subject (economic-resource-primary-accountable r)))))

(define (resource-onhand>0? r)
  (let ((m (economic-resource-onhand-quantity r)))
    (or (not m)                                   ; a permit may carry no quantity — treat as present
        (> (measure-has-numerical-value m) 0))))

(define (resource-state-ok? r)
  (let ((s (economic-resource-state r)))
    (or (not s) (not (member (if (symbol? s) (symbol->string s) s) bad-states)))))

;; earliest expiration for a resource: merge the observer's batch index with the
;; resource's own `lot` (seed-resource sets the lot but does not index it), so a
;; seeded permit and an event-tracked lot both surface. #f ⟹ never expires.
(define (%min-exp e acc)
  (cond ((not e) acc) ((not acc) e) ((string<? e acc) e) (else acc)))
(define (resource-expiration observer r)
  (let* ((rid (economic-resource-id r))
         (indexed ($ observer 'batches-for-resource rid))
         (lot (economic-resource-lot r))
         (from-index (fold (lambda (b acc) (%min-exp (batch-lot-record-expiration-date b) acc))
                           #f (if (pair? indexed) indexed '())))
         (from-lot (and lot (batch-lot-record? lot) (batch-lot-record-expiration-date lot))))
    (%min-exp from-lot from-index)))

(define (resource-unexpired-at? observer r as-of)
  (let ((e (resource-expiration observer r)))
    (or (not e) (not as-of) (string<=? as-of e))))   ; as-of ≤ expiry ⟹ still valid

(define* (resource-valid-at? observer r subject as-of
                             #:key (holder-field 'primary-accountable))
  (and (resource-held-by? r subject holder-field)
       (resource-onhand>0? r)
       (resource-state-ok? r)
       (resource-unexpired-at? observer r as-of)))

;;; ─── holding-status : the core fold (a query over ^observer) ─────────────
;;; → 'satisfied | 'expired | 'missing  (never a stored field).
;;;   satisfied : ≥1 held resource conforming to spec is valid at `as-of`
;;;   expired   : held one(s), but every one is expired/void  (renewal work)
;;;   missing   : hold none                                    (application work)
(define* (holding-status observer subject spec-id as-of
                         #:key (holder-field 'primary-accountable))
  (let* ((all  ($ observer 'conforming-resources spec-id))
         (mine (filter (lambda (r) (resource-held-by? r subject holder-field)) all)))
    (cond
     ((any (lambda (r) (resource-valid-at? observer r subject as-of
                                            #:holder-field holder-field)) mine)
      'satisfied)
     ((pair? mine) 'expired)
     (else 'missing))))

;;; ─── reconcile : the demand bill ⋈ holdings ──────────────────────────────
;;; Take (bill hits) from legal-demands and the live observer; return one entry
;;; per binding demand: (key kind demand-name status). A `forbid` a sure rule
;;; imposes is 'forbidden (no holding helps); one only an uncertain rule imposes
;;; is 'doubted — the same line the solve draws between a prune and a tension
;;; (legal/registry.scm `bill-stance`). `obtain` demands are looked up; `pay`/`tell` are
;;; obligations (§ obligations), not holdings, so they report 'obligation.
;;;   subject-of : (demand kind) → the agent id expected to hold it. A person
;;;   obtain rides a named practitioner; an entity obtain rides the adapter/scope.
;;;   A `grant` is looked up like a permit, and one not held is `unclaimed` — an
;;;   offer standing open, never a gap. An `obtain` that names what it comes
;;;   `after` is `blocked` while that forerunner is not satisfied: the authority
;;;   will not issue it yet, so the work is the forerunner's.
(define* (reconcile bill hits observer as-of
                    #:key (subject-of (lambda (d kind) 'scope))
                          (holder-field 'primary-accountable))
  (define (rule-for d)                       ; the firing rule that emitted d (for jurisdiction)
    (find (lambda (r) (any (lambda (rd) (demand=? rd d)) (legal-rule-demands r))) hits))
  (define (juris d) (let ((r (rule-for d))) (if r (or (legal-rule-label r) 'unknown) 'unknown)))
  (define (entry kind d status)
    (let ((subj (subject-of d kind)))
      (list (demand-key (juris d) d subj) kind (demand-name d) status)))
  (define (held kind d)
    (holding-status observer (subject-of d kind) (demand->spec-id d) as-of #:holder-field holder-field))
  (define (obtain-entry kind d) (entry kind d (held kind d)))
  (let* ((obtains (append (map (lambda (d) (obtain-entry 'obtain-entity d)) (bill-ref bill 'obtain-entity))
                          (map (lambda (d) (obtain-entry 'obtain-person d)) (bill-ref bill 'obtain-person))))
         (status-of (lambda (name)           ; a forerunner's status, by its name; absent ⇒ #f
                      (let ((e (find (lambda (e) (equal? (list-ref e 2) name)) obtains)))
                        (and e (entry-status e)))))
         (ordered (map (lambda (e)
                         (let* ((d (find (lambda (d) (equal? (demand-name d) (list-ref e 2)))
                                         (append (bill-ref bill 'obtain-entity) (bill-ref bill 'obtain-person))))
                                (after (and d (demand-after d))))
                           (if (and after (eq? (entry-status e) 'missing)
                                    (not (eq? (status-of after) 'satisfied)))
                               (list (car e) (cadr e) (caddr e) 'blocked)
                               e)))
                       obtains)))
    (append
     (map (lambda (d) (entry 'forbid d (if (forbid-sure? d hits) 'forbidden 'doubted)))
          (bill-ref bill 'forbid))
     ordered
     (map (lambda (d) (entry 'pay d 'obligation)) (bill-ref bill 'pay))
     (map (lambda (d) (entry 'tell d 'obligation)) (bill-ref bill 'tell))
     (map (lambda (d) (entry 'grant d (let ((s (held 'grant d))) (if (eq? s 'missing) 'unclaimed s))))
          (bill-ref bill 'grant)))))

;; a reconciliation entry has a gap iff it stops the activity: missing / expired /
;; forbidden / blocked. A doubted prohibition asks for a steward's reading and
;; stops nothing; an unclaimed grant is an offer, not a gap.
(define (entry-status e) (list-ref e 3))
(define (entry-gap? e) (memq (entry-status e) '(missing expired forbidden blocked)))
(define (reconcile-gaps entries) (filter entry-gap? entries))

;;; ─── obligations : the calendar = Commitments due to an authority ─────────
;;; No new calendar object. An obligation is a <commitment> whose receiver is an
;;; authority <agent> and whose `due` a cadence sets from the grant's expiry.
;;; Cadence (read from the demand `per` detail, extended with temporal kinds):
;;;   'one-time           → no future obligation
;;;   ('renew-before . Δ) → due = expiration − Δ days
;;;   ('every . period)   → recurring (we emit the NEXT, from `since`)
;;;   'each-event         → coupled to the PLAN (emitted per planned instance)
;;;   'on-change          → event-triggered, not dated here
(define (iso-date s) (and s (>= (string-length s) 10) (substring s 0 10)))
;; subtract Δ days from an ISO date, calendar-naively (good enough for a due-by
;; reminder; the exact date is the authority's, this is our lead-time flag).
(define (iso-minus-days iso days)
  (let* ((d (iso-date iso)))
    (and d
         (let ((y (string->number (substring d 0 4)))
               (m (string->number (substring d 5 7)))
               (day (string->number (substring d 8 10))))
           (let loop ((y y) (m m) (day (- day days)))
             (if (>= day 1)
                 (format #f "~4,'0d-~2,'0d-~2,'0d" y m day)
                 (let* ((pm (if (= m 1) 12 (- m 1)))
                        (py (if (= m 1) (- y 1) y))
                        (dim (vector-ref #(31 28 31 30 31 30 31 31 30 31 30 31) (- pm 1))))
                   (loop py pm (+ day dim)))))))))

;; keyword wrapper over the 27-field <commitment> — fill only what an obligation
;; needs; everything else #f. This IS a VF commitment (schemas.scm), disk-clean.
(define* (make-obligation #:key id action spec provider receiver due (note #f))
  (make-commitment #:id id #:action action #:note note #:resource-conforms-to spec
                   #:provider provider #:receiver receiver #:due due))

;; obligations-for : one held resource + its demand → 0..1 future <commitment>.
;;   cadence   : as above (from the demand's `per`, or passed)
;;   authority : the receiver agent id
;;   kind      : the demand's kind (obtain/pay/tell) — the periodic-filing action
;;               is derived from it via demand-kind->vf-action (legal/registry.scm,
;;               the single source of truth), so `pay` transfers and `tell`
;;               delivers a service. Absent ⇒ the caller's #:action default.
;; Renewal lowers to `modify` (a lifecycle action on the held credential), NOT to
;; obtain's fresh `produce` — see demand-kind->vf-action's note.
;; A `grant` recurs the other way round: the AUTHORITY provides and we receive,
;; the same transfer as a levy with the two parties swapped.
(define* (obligation-for spec-id cadence expiration provider* authority*
                         #:key (kind #f) (action 'deliver-service))
  (define grant? (eq? kind 'grant))
  (define provider  (if grant? authority* provider*))
  (define authority (if grant? provider* authority*))
  (match cadence
    (('renew-before . dd)
     (let ((due (and expiration (iso-minus-days expiration dd))))
       (and due (make-obligation #:id (string-append "ob:renew:" spec-id)
                                 #:action 'modify #:spec spec-id
                                 #:provider provider #:receiver authority #:due due
                                 #:note "renew before expiry"))))
    (('every . _period)
     ;; recurring levy/disclosure — the NEXT one is due at expiration (period end).
     (and expiration (make-obligation #:id (string-append "ob:file:" spec-id)
                                      #:action (or (and kind (demand-kind->vf-action kind)) action)
                                      #:spec spec-id
                                      #:provider provider #:receiver authority
                                      #:due (iso-date expiration) #:note "periodic filing")))
    (_ #f)))

;;; ─── the bill IS the calendar : cadence off the firing rule ──────────────
;;; A demand's own `renew` says how often it comes round (legal/registry.scm), so
;;; the calendar needs no hand-written list of specs: fold the bill, keep the
;;; demands that recur, and pair each with its cadence. Falls back to `per` for
;;; rules written before `renew` existed, which is where the temporal `per`
;;; values ('renew-before . d) / ('every . p) were being smuggled.
(define (demand-cadence d)
  (or (demand-renew d)
      (let ((p (demand-ref d 'per))) (and (pair? p) p))))

(define (bill->specs+cadence bill)
  "→ ((spec-id . cadence) …) for every demand in BILL that recurs."
  (filter-map (lambda (d) (let ((c (demand-cadence d)))
                            (and c (cons (demand->spec-id d) c))))
              (append-map cdr bill)))

;;; the whole calendar for a folded bill, in one call — the caller hands the bill
;;; it already computed rather than re-deriving anything.
(define* (bill-obligations bill observer subject authority now horizon
                           #:key (holder-field 'primary-accountable))
  (obligations observer subject (bill->specs+cadence bill) authority now horizon
               #:holder-field holder-field))

;; obligations : scan a subject's holdings of the given (spec . cadence) demands,
;; emit the due <commitment>s within [now, horizon], sorted by due.
(define* (obligations observer subject specs+cadence authority now horizon
                      #:key (holder-field 'primary-accountable))
  (define (within? due) (and due (string<=? now due) (string<=? due horizon)))
  (sort
   (filter-map
    (lambda (sc)
      (match sc
        ((spec-id . cadence)
         (let* ((mine (filter (lambda (r) (resource-held-by? r subject holder-field))
                              ($ observer 'conforming-resources spec-id)))
                (exp  (and (pair? mine) (resource-expiration observer (car mine))))
                (ob   (obligation-for spec-id cadence exp subject authority)))
           (and ob (within? (commitment-due ob)) ob)))))
    specs+cadence)
   (lambda (a b) (string<? (commitment-due a) (commitment-due b)))))

;;; ─── the planner bridge : custody-aware #:legal-decorate ─────────────────
;;; Custody is now just a PARAMETER of legal-gate's `make-legal-decorate`: we hand
;;; it a `held?` predicate that folds into the SAME bill pass (no second
;;; derivation). An entity permit not in the subject's custody prunes the column,
;;; exactly as a forbid does — an un-held facility permit becomes a possibility-
;;; tension, just like an un-held competence already is, with no planner edit.
;;;   subject-at : (proc-id cell) → the agent expected to hold entity permits there
;;;   (the scope/adapter operating that cell).
;;; Needs legal/gate.scm loaded (make-legal-decorate).
;;; Whose permit? SUBJECT-AT names the holder expected at (proc, cell); with it
;;; the permit must be accountable to that agent (HOLDER-FIELD, default
;;; primary-accountable). Without it — the plain case, one commune's own stores —
;;; a permit counts as held when any conforming resource stands in the observer
;;; (`'any`): the stores ARE the custody, and there is no one else to name.
;;; SUBJECT-FOR names the holder by (proc cell spec) — a scope whose bodies
;;; (legal/bodies.scm) hold its permits answers per demand; it stands in for
;;; SUBJECT-AT when given.
(define* (make-legal-decorate/observer
          #:key recipe-store spatial-thing-store registry observer
                (act #f) (as-of #f) (subject-at #f)
                (subject-for (and subject-at (lambda (p c s) (subject-at p c))))
                (holder-field (if subject-for 'primary-accountable 'any))
                (agent-store #f) (actor-for #f) (soft-profile %uncertain-forbid-profile))
  (make-legal-decorate
   #:recipe-store recipe-store #:spatial-thing-store spatial-thing-store
   #:registry registry #:act act
   ;; the same observer that answers custody puts the activity's THINGS in front
   ;; of the law (asset-has); an agent store puts their holders there (agent-has);
   ;; the body the scope stands behind at the cell is the ACTOR (actor-has).
   #:observer observer #:agent-store agent-store #:soft-profile soft-profile
   #:actor-for actor-for
   ;; ONE date: the day that decides whether a permit is still valid is the day
   ;; that decides whether a rule is still in force
   #:as-of as-of
   #:held? (lambda (proc-id cell spec)
             (let ((subject (and subject-for (subject-for proc-id cell spec))))
               (eq? 'satisfied (holding-status observer subject spec as-of
                                               ;; a body answers for the demand, or nobody does
                                               #:holder-field (if subject holder-field 'any)))))))

;;; ─── the scope's law, default-on at the solve door ─────────────────────
;;; A scope root carries its `^legal-registry` beside its other governance
;;; registries (scope-root.scm: seeded from the PLAYNET_LAW_PACKS folder at
;;; spawn, persisted with the root; register!/repeal act on it and survive a
;;; restart like every other governance act). Under no rules this is #f and
;;; the solve is byte-identical.
;;;
;;; With rules, the decorate is `make-legal-decorate/observer` over the root's
;;; OWN stores: recipe-store (crossings), spatial-thing-store (the jurisdiction
;;; path), observer (custody of permits AND the activity's things, for
;;; `asset-has`), agent-store (their holders, for `agent-has`). Same default-on
;;; reasoning as composition: a scope that had to remember a keyword would get no
;;; law and no warning.
;;; The registry is read the way accepts.scm reads a root's parts: a root that
;;; cannot name one (a mocked root, a minimal one) stands under no law — the
;;; empty case, not an error.
;;;
;;; Custody at this door: the root's bodies (legal/bodies.scm) answer for the
;;; demands they hold or the doors they open (`scope-body-subject`); a demand
;;; no body answers for is `make-legal-decorate/observer`'s plain case, a permit
;;; standing in the root's own stores being the root's permit. Expiry is read
;;; against today on the one clock (playnet utils clock): an expired permit is
;;; not a permit.
(define* (scope-legal-decorate root #:key (registry #f)
                               (as-of (iso-date (instant->civil (now))))
                               ;; the scope's OWN tolerance for legally-uncertain
                               ;; activity, off its plan-store's governed row —
                               ;; explicit keyword > the commune's row > the default
                               (soft-profile
                                (legal-policy (false-if-exception ($ root 'plan-store))
                                              'uncertain-forbid)))
  (define registry* (or registry (false-if-exception ($ root 'legal-registry))))
  (define agent-store (false-if-exception ($ root 'agent-store)))
  (define observer (false-if-exception ($ root 'observer)))
  (define bodies (or (and agent-store (false-if-exception (all-bodies agent-store))) '()))
  (define path-of (and (pair? bodies) (spatial-path-reader ($ root 'spatial-thing-store))))
  (define recipe-store ($ root 'recipe-store))
  (define resolve-spec (lambda (id) ($ recipe-store 'get-resource-spec id)))
  ;; the body the scope stands behind at a cell, and what can be counted of it
  (define actor-for
    (and (pair? bodies)
         (let ((at (scope-body-at bodies #:path-of path-of)))
           (lambda (cell)
             (let ((b (at cell)))
               (if b (body-facts agent-store observer b #:resolve-spec resolve-spec
                                 #:since (and as-of (iso-minus-days as-of 365)))
                   (values #f #f)))))))
  (and registry* (pair? ($ registry* 'rules))
       (make-legal-decorate/observer
        #:recipe-store recipe-store
        #:spatial-thing-store ($ root 'spatial-thing-store)
        #:registry registry*
        #:observer observer
        #:agent-store agent-store
        #:actor-for actor-for
        #:subject-for (and (pair? bodies)
                           (scope-body-subject agent-store observer bodies #:path-of path-of))
        #:as-of as-of
        #:soft-profile soft-profile)))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (compliance-demo)
  (format #t "~%compliance.scm — folds over the VF event log:~%")
  (format #t "  authority agent?  ~a~%" (authority-agent? (make-authority "auth:county" "County Health")))
  (format #t "  iso-minus-days 2027-03-01 −60 → ~a~%" (iso-minus-days "2027-03-01" 60))
  (format #t "  demand->spec-id  = demand-name (join key)~%")
  (format #t "  holding-status / reconcile / obligations read a LIVE ^observer.~%")
  (format #t "  make-legal-decorate/observer prunes on un-held entity permits — no planner edit.~%")
  (format #t "  see tests/observation/test-compliance.scm for the real-store path.~%"))

;; run as a program on a host; a page loads this as a library only
(cond-expand
 (guile
  (when (and (pair? (command-line))
             (string-suffix? "compliance.scm" (car (command-line))))
    (compliance-demo)))
 (else))
