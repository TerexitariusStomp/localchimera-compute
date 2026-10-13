;;; account.scm — Goblins actor for commune labor-credit accounting
;;;
;;; MODEL (post-universalization):
;;;
;;;   - Labor is universal-social: an hour worked in any scope produces
;;;     one hour of social credit, spendable at any scope that has
;;;     individually-claimable goods.
;;;
;;;   - Voice (governance) is per-scope: your weight in scope X's ballots
;;;     is your hours worked in scope X. This is NOT in account-store;
;;;     the governance layer reads it via `gross-contribution-credited`.
;;;
;;;   - A "claim" is a VF `transfer` event from the scope (as provider)
;;;     to a citizen (as receiver). Rights and custody move together.
;;;     The resource must be classified as `"individually-claimable"`.
;;;
;;;   - Credit balance is DERIVED from observer events:
;;;       balance = sum(work provider=aid effort)
;;;               - sum(transfer receiver=aid, classified individually-claimable, effort)
;;;
;;;   - The store holds no account. Who holds an account here is a reading:
;;;     the commune's members (its live membership credentials), the
;;;     claimants (the observer's claim events) and the workers (its work
;;;     events). A person's contribution-capacity factor is the commune's
;;;     latest assessment credential for them, else 1. Gross and claimed are
;;;     readings of the observer's event log (validated-gross, claim-effort).
;;;     Nothing here caches any of it: the credentials and the events are the
;;;     books, and this store is the arithmetic over them.
;;;
;;; STATE: observer-ref (near actor), recipe-store-ref, and the STANDING the
;;; scope hands over once it has an acdc-store (`set-standing`: a thunk
;;; answering the members, a procedure answering a person's factor), not
;;; serialized, re-bound after restore like on-work. No pool hashmap — pool
;;; is a derived query over observer resources.

(define-module (playnet observation account)
  #:use-module (goblins)
  #:use-module (playnet algorithms elastic)   ; the credit identity's arithmetic over cells
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (playnet vf serdes)
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf formulas flows) #:select (make-work-intent make-work-event make-transfer-event))
  #:use-module (playnet observation states)
  #:use-module ((playnet observation observer) #:select (target-reached? target-passed?))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils store-utils)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module ((playnet utils units) #:select (%placeholder-unit %effort-unit))
  #:use-module (playnet algorithms rollup)
  #:use-module (playnet vf facts rail)
  #:re-export (claimable-specs declare-claimable! spec-claimable? spec-rail publish-rails! declare-rail!
               publish-social-portion! declare-social-portion! spec-social-portion)
  #:export (*individually-claimable* resource-individually-claimable?
            claim-cid claim-commitment claim-terms claim-fulfillments open-claim-for fulfillment-remaining
            event-classified-individually-claimable?
            resource-in-pool? compute-pool-value account-holders
            with-elastic ^account-store sum-across-scopes
            household-social-free-time household-consumer-voice
            universal-credit-balance account-store-env
            set-person-substrate! person-aid?))



;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Classification constants
;; =========================================================================

(define *individually-claimable* "individually-claimable")  ; the legacy tag, kept for import normalisation

;; ── the rail a good is on is read off the recipes — (playnet vf facts rail) ──
;; The plan publishes the classification there (individual | communal | means)
;; and the pool, a claim's admissibility and the credit identity K read it.
(define* (resource-individually-claimable? resource #:optional (store #f))
  "True if the resource sits on the individual rail: some claim recipe
   consumes its spec for someone (spec-claimable?). STORE — this scope's
   own recipe-store — scopes the read so it can never be a different
   scope's answer."
  (and resource (spec-claimable? (economic-resource-conforms-to resource) store)))

(define (event-classified-individually-claimable? event)
  (and event (eq? (event-distribution-mode event) 'individual-claimable)))

;; ── the plan's claim, as the commitment every claim event fulfils ───────────
;; A claim is a transfer the PLAN planned: its `claims` row (claimant, spec,
;; quantity, place, when) is registered on the observer as a `transfer`
;; commitment under a deterministic key, and the ledger's `claim` records an
;; event only against such a commitment, for no more than remains on it. That
;; is the whole deduction discipline at one door: the solve's material balance
;; already nets what production consumes and what the reserve keeps before a
;; claim column can take anything, so a claim that fulfils the plan's own row
;; can only ever move the portion left for distribution. Nothing above this
;; door mints a claim of its own, and the door admits a transfer only against a
;; commitment that parses as a claim id and names the resource's own spec; the
;; claimant — the transfer's receiver, the lot it lands in, the account debited —
;; is read off that id (`claim` below), so no caller can name another.
(define (claim-cid spec claimant place when-iso)
  (keyed-id "claim" spec claimant place when-iso))

(define %claim-tag "claim")   ; the kind a claim commitment carries: what the observer's terms answer to

(define* (claim-commitment spec claimant qty scope-id #:key (place #f) (when-iso #f) (unit %placeholder-unit))
  "The plan's claim row as a `transfer` commitment: SPEC to CLAIMANT, QTY at PLACE, WHEN-ISO."
  (make-commitment
   #:id (claim-cid spec claimant place when-iso) #:action 'transfer #:resource-conforms-to spec
   #:resource-quantity (make-measure qty unit) #:receiver claimant #:has-point-in-time when-iso
   #:resource-classified-as (list %claim-tag)
   #:at-location place #:in-scope-of (list scope-id)))

(define (fulfillment-remaining fs)
  (- (measure-has-numerical-value (fulfillment-state-total-committed fs))
     (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))))

(define* (claim-fulfillments observer-ref #:key (spec #f) (receiver #f) (place #f) (open-only? #t))
  "The fulfillment states of the plan's claim commitments, as the observer holds them
   under the claim kind: of SPEC, for RECEIVER, at PLACE (a key left off matches any),
   the open ones unless OPEN-ONLY? is #f."
  ($ observer-ref 'fulfillments-for #:spec spec #:receiver receiver #:place place
     #:tag %claim-tag #:open-only? open-only?))

(define* (open-claim-for observer-ref spec claimant #:key (place #f) (at-least 0))
  "The plan's open claim commitment of SPEC for CLAIMANT with AT-LEAST remaining —
   at PLACE when one is named — as its fulfillment state, or #f."
  (find (lambda (fs) (target-reached? (fulfillment-remaining fs) at-least))
        (claim-fulfillments observer-ref #:spec spec #:receiver claimant #:place place)))

(define (claim-terms observer-ref cid)
  "The terms a claim commitment CID stands on, as the observer holds them, or #f for
   a commitment that is no claim (or none at all)."
  (let ((t ($ observer-ref 'commitment-terms cid)))
    (and t (member %claim-tag (assq-ref t 'tags)) t)))


;; =========================================================================
;; Derived property computations (pure functions on state)
;; =========================================================================

;; --- Validation Gate (§III.1) ---
;;
;; Raw work-event effort is NOT social labor. The observer owns the
;; gate: `'validated-gross` returns the sum of (effort × confirmed
;; fraction) across work events — scope-wide when called with no aid,
;; provider-filtered when called with one. We never cache — every read
;; is fresh, so corrections and new fulfillment propagate on next query.

;; The distribution arithmetic — contribution BY ABILITY and the citizenship
;; share — is elastic.scm's, over the cells this store states (credit-cells
;; below); the scope-local reads here run that one arithmetic on the store's
;; own cells, so a scope and the federation's fold answer from one law.


;; =========================================================================
;; Elastic pool-value — derived from observer resources via SNLT lookup
;; =========================================================================

;; ── who holds an account here: a reading ─────────────────────────────────────
;; The STANDING is what the scope hands the store once its credentials are
;; in reach: (members-of . ccf-of), a thunk answering the commune's members
;; and a procedure answering a person's assessed factor (credentials/
;; membership.scm `membership-holders`, `ccf-assessed`). Absent — a unit
;; test, a root with no scope above it — nobody is a member and every factor
;; is 1, which is the reading this file always gave an account it made itself.
(define (standing-members standing) (if standing ((car standing)) '()))
(define (standing-ccf standing aid) (if standing ((cdr standing) aid) 1))

(define (account-holders observer-ref standing)
  "The agents who hold an account here: the members, everyone who has
   claimed from the pool, and everyone whose work the observer holds."
  (delete-duplicates
   (append (standing-members standing)
           (or (false-if-exception ($ observer-ref 'claimants)) '())
           (map car (or (false-if-exception ($ observer-ref 'hours-by economic-event-provider)) '())))))

(define* (resource-in-pool? resource holder? #:optional (store #f))
  "A resource is in the claimable pool iff it is individually-claimable
   AND its primary-accountable is NOT a citizen with an account in this
   scope (HOLDER? : aid → bool). Once a citizen claims a resource,
   primary-accountable moves to them and the resource exits the pool — it
   is personal holding now."
  (and (resource-individually-claimable? resource store)
       (not (holder? (economic-resource-primary-accountable resource)))))

(define (compute-pool-value observer-ref recipe-store-ref holder?)
  "K = Σ qty × SNLT_crystallized over resources currently in the pool
   (playnet.typ [pool size]: a claim should cost what the good cost
   society, so the pool is valued in the same crystallized measure claims
   settle at — direct work PLUS embodied inputs, via the recipe rollup).
   Resources with no recipe are skipped (can't be priced without SNLT).
   Resources held by citizens (claimed) are excluded, and so is the portion
   of each spec the plan keeps back for its own processes and its reserve
   (rail.scm spec-social-portion): only what stands above it is distributable."
  (let ((per-spec (make-hash-table)))
    (for-each (lambda (r)
                (let ((spec (economic-resource-conforms-to r))
                      (qty  (measure-has-numerical-value (economic-resource-accounting-quantity r))))
                  (hash-set! per-spec spec (+ qty (hash-ref per-spec spec 0)))))
              (filter (lambda (r) (resource-in-pool? r holder? recipe-store-ref))
                      ($ observer-ref 'inventory)))
    (hash-fold (lambda (spec qty acc)
                 (let ((snlt (crystallized-snlt-for-spec recipe-store-ref spec))
                       (left (max 0 (- qty (spec-social-portion spec recipe-store-ref)))))
                   (if (= snlt +inf.0) acc (+ acc (* left snlt)))))
               0 per-spec)))

(define* (with-elastic observer-ref recipe-store-ref standing aid level k)
  "Call K on this store's own cells for AID at federation LEVEL (#f:
   scope-local). 0 when AID holds no account here."
  (let ((holders (account-holders observer-ref standing)))
    (if (not (member aid holders)) 0
        (k (own-credit-cells observer-ref recipe-store-ref standing holders) aid level))))


;; =========================================================================
;; ^account-store — persistent Goblins actor
;; =========================================================================

;; every account mutation tells the additive listeners; one that throws is
;; reported, never allowed to undo the mutation it heard about
(define (fire-listeners! listeners)
  (for-each (lambda (l)
              (catch #t (lambda () (l))
                (lambda args
                  (format (current-error-port)
                          "account listener error: ~a~%" args))))
            listeners))

(define-actor (^account-store bcom observer-ref recipe-store-ref on-work
                              #:optional (listeners '()) (standing #f))
  ;; observer-ref:      near ref to this scope's ^observer (same vat)
  ;; recipe-store-ref:  near ref to this scope's ^recipe-store (for SNLT)
  ;; standing:          (members-of . ccf-of) from the scope's credentials,
  ;;                    or #f (account-holders above); not serialized,
  ;;                    re-bound by the scope after restore like on-work
  ;; on-work:           (lambda (event) → unit) or #f
  ;;                    Called after a work event is credited.
  ;;                    The closure encapsulates ACDC emission — planner
  ;;                    stays oblivious to credential schemas.
  ;; listeners:         additive change listeners, (lambda () → unit) each —
  ;;                    fired after ANY account mutation (the credit fold
  ;;                    hears its writers here). Not serialized; re-added
  ;;                    after restore, like on-work.

  #:portrait
  (lambda () (list observer-ref recipe-store-ref))

  #:version 7

  #:restore
  (lambda (version obs rs . rest)
    ;; on-work and the standing aren't serializable; restore with neither,
    ;; the scope re-binds both (set-on-work, set-standing). v5 dropped the
    ;; gross-contribution-credited cache field, v6 the claimed-capacity
    ;; cache, v7 the accounts themselves: each is a reading now (the
    ;; observer's events, the scope's credentials). An older portrait is
    ;; read by dropping what it cached.
    (case version
      ((3 4 5 6 7) (spawn ^account-store obs rs #f))
      (else (error "Unknown ^account-store version" version))))

  (methods

    ;; --- The standing: the scope's credentials, read, never copied ---

    ((set-standing members-of ccf-of)
     ;; MEMBERS-OF: thunk → the commune's member aids; CCF-OF: aid → factor.
     ;; The scope hands these over once its acdc-store is in reach, and
     ;; again after a restore; a test hands over a fixed roster.
     (fire-listeners! listeners)
     (bcom (^account-store bcom observer-ref recipe-store-ref on-work listeners
                           (cons members-of ccf-of))))
    ;; the scope's credentials changed under the standing (a member admitted,
    ;; a factor assessed): the fold's listeners hear it
    ((standing-changed) (fire-listeners! listeners))

    ((holders) (account-holders observer-ref standing))
    ((holder? agent-id) (and (member agent-id (account-holders observer-ref standing)) #t))
    ((ccf-of agent-id) (standing-ccf standing agent-id))
    ;; this scope's credit cells, stated by the store (own-credit-cells)
    ((credit-cells) (own-credit-cells observer-ref recipe-store-ref standing))

    ;; --- Contributions ---

    ((credit-from-event event)
     ;; Validation Gate (§III.1): raw hours are NOT social labor. This
     ;; method ensures the provider has an account row (for CCF) and
     ;; fires the on-work callback. It does NOT write to the gross
     ;; cache — gross is computed at query time from observer
     ;; fulfillment-state. Returns the raw effort (for diagnostic
     ;; use by callers) or #f if not a work event.
     (if (not (eq? (economic-event-action event) 'work))
         #f
         (let ((qty (and (economic-event-effort-quantity event)
                         (measure-has-numerical-value
                           (economic-event-effort-quantity event)))))
           (when on-work (on-work event))
           (fire-listeners! listeners)
           qty)))

    ((credit-from-event-silent event)
     ;; Recovery path: identical to credit-from-event but skips the
     ;; on-work callback (avoids ACDC re-emission during replay).
     (if (not (eq? (economic-event-action event) 'work))
         #f
         (and (economic-event-effort-quantity event)
              (measure-has-numerical-value (economic-event-effort-quantity event)))))

    ((set-on-work proc)
     ;; Late-bind the emission callback (post-recovery, post-restore).
     (bcom (^account-store bcom observer-ref recipe-store-ref proc
                           listeners standing)))

    ;; additive: a listener joins, nothing it was beside is displaced
    ((add-change-listener proc)
     (bcom (^account-store bcom observer-ref recipe-store-ref on-work
                           (cons proc listeners) standing)))

    ((add-contribution agent-id svc-amount)
     ;; Bootstrap / test hook: credit SVC without a real production
     ;; process. Synthesizes a recipient-side intent + a work event
     ;; that satisfies it, so the Gate's single source of truth
     ;; (observer satisfaction-state) covers this path too. The
     ;; synthesized intent is NOT registered in any plan, so its
     ;; credit only counts at level=#f — fine for tests, but real
     ;; production credits flow through recorded work events whose
     ;; intents belong to a registered plan.
     (let* ((iid  (generate-id "boot-int-"))
            (evid (generate-id "boot-ev-")))
       ($ observer-ref 'register-intent
          (make-work-intent #:id iid #:skill "spec-labor" #:hours svc-amount #:provider agent-id))
       ($ observer-ref 'record-event
          (make-work-event #:id evid #:resource-spec "spec-labor" #:provider agent-id
                           #:effort-qty svc-amount #:effort-unit %effort-unit #:satisfies iid
                           #:timestamp #f #:note #f))
       (fire-listeners! listeners)
       #t))

    ;; --- Claim (VF transfer from scope to citizen) ---

    ;; OPTS after scope-roots: (level [at-location [when]]) — level stratifies
    ;; the validation; at-location / when ride onto the transfer event
    ;; (to-location, has-point-in-time) so the claim records WHERE the good
    ;; is to reach the citizen and WHEN they want it. All optional.
    ((claim resource-id qty claimant-aid labor-cost scope-roots . opts)
     ;; resource-id:  resource in this scope's observer to be claimed
     ;; qty:          quantity to claim (in resource's unit)
     ;; claimant-aid: the citizen the caller speaks for; the receiver itself
     ;;               is read off the claim commitment and must agree
     ;; labor-cost:   raw SNLT × qty, in hours (stored on the transfer
     ;;               event as effort-quantity — frozen history)
     ;; scope-roots:  list of scope-root refs constituting the federation
     ;;               for global elastic validation. Pass (list this-scope)
     ;;               for single-scope operation; pass the full federation
     ;;               list for universal-credit validation.
     ;;
     ;; Validation is against GLOBAL ELASTIC effective-balance:
     ;;   the pool by ability — pool × r_p / Σ r, r = gross / CCF, read on
     ;;   citizens (elastic.scm) — plus the citizenship share, less claimed.
     ;;   A race guard: the plan already ranked only affordable claims.
     ;;
     ;; The resource lives in THIS scope's observer, but the citizen's
     ;; purchasing power is summed from their activity across ALL scopes
     ;; in scope-roots. This realizes universal-social labor: you earn
     ;; credits anywhere, spend them anywhere.
     ;;
     ;; Records a `transfer` event via the local observer; the auto-created
     ;; destination resource is under the claimant's primary-accountable,
     ;; which is what removes the resource from the pool.
     (let ((resource ($ observer-ref 'get-resource resource-id)))
       (cond
         ((not resource)
          (error "Resource not found" resource-id))
         ((not (resource-individually-claimable? resource recipe-store-ref))
          (error "Resource not individually-claimable" resource-id))
         (else
          (let* ((level  (and (pair? opts) (car opts)))
                 (at-loc (and (pair? opts) (pair? (cdr opts)) (cadr opts)))
                 (when*  (and (pair? opts) (pair? (cdr opts)) (pair? (cddr opts))
                              (caddr opts)))
                 ;; the plan's claim commitment this transfer fulfils — the one
                 ;; word that admits a claim at all (claim-commitment above)
                 (fulfills (and (pair? opts) (>= (length opts) 4) (list-ref opts 3)))
                 (fs (and fulfills ($ observer-ref 'get-fulfillment fulfills)))
                 ;; the commitment is the PLAN's claim row: a held, count or work
                 ;; commitment of ample quantity admits nothing (a claim is the commitment
                 ;; the observer holds under the claim kind). With plan-claims! the only minter of claims,
                 ;; and a claim recipe built only for a good on the individual rail
                 ;; (live.scm claim-recipes), "rights reach a person only through the
                 ;; plan's claim" holds by construction here.
                 (terms (or (and fs (claim-terms observer-ref fulfills))
                            (error (if fs
                                       "a claim fulfils the plan's claim commitment alone"
                                       "the plan holds no such claim; state the want and the plan answers")
                                   claimant-aid resource-id fulfills)))
                 ;; the claimant is READ OFF the plan's word, never stated: the
                 ;; transfer's receiver, the lot it lands in and the account debited
                 ;; are all the one name the claim id carries. CLAIMANT-AID is the
                 ;; caller's confirmation of who it speaks for.
                 (claimant (assq-ref terms 'receiver))
                 (eff-balance (effective-balance (credit-cells scope-roots) claimant (current-social-free-time) level)))
            (unless (equal? (assq-ref terms 'spec) (economic-resource-conforms-to resource))
              (error "the plan's claim names another good"
                     fulfills (economic-resource-conforms-to resource)))
            (unless (equal? claimant claimant-aid)
              (error "the plan's claim names another citizen" fulfills claimant claimant-aid))
            (when (target-passed? qty (fulfillment-remaining fs))
              (error "the plan's claim has less remaining than asked"
                     fulfills (fulfillment-remaining fs) qty))
            (when (< eff-balance labor-cost)
              (error "Insufficient global effective balance"
                     claimant eff-balance labor-cost))
            (let* ((provider
                     (economic-resource-primary-accountable resource))
                   (unit
                     (measure-has-unit
                       (economic-resource-accounting-quantity resource)))
                   (to-resource-id
                     (string-append resource-id "-" claimant))
                   (event
                     (make-transfer-event
                       #:id (generate-id "claim-")
                       #:from resource-id
                       ;; the claimant's share lands in a resource made to hold it
                       #:to to-resource-id
                       #:spec (economic-resource-conforms-to resource)
                       #:tags (economic-resource-classified-as resource)
                       #:provider provider #:receiver claimant-aid
                       #:qty qty #:unit unit #:hours labor-cost
                       #:when (or when* #f)                ; WHEN wanted
                       #:to-location (or at-loc #f)        ; WHERE to
                       #:fulfills fulfills                  ; the planned claim
                       ;; the rail this transfer ran on, as provenance on the event:
                       ;; ledger-claimed and the claim ACDC read it back
                       #:distribution 'individual-claimable)))
              ($ observer-ref 'record-event event)
              ;; what the claimant has claimed is the events' sum (claim-effort),
              ;; and the event makes them a holder here (account-holders)
              (fire-listeners! listeners)
              #t))))))

    ;; --- Derived queries (event-sourced + elastic) ---

    ((credit-balance agent-id)
     ;; The observer is the ledger; we just forward. Gated by intent
     ;; satisfaction per §III.1 — raw hours without an associated
     ;; intent or process contribute 0.
     ($ observer-ref 'credit-balance agent-id))

    ((pool-resources)
     ;; Individually-claimable resources still held by the scope (not
     ;; yet claimed by a citizen). Returns a list of <economic-resource>
     ;; records.
     (let ((holders (account-holders observer-ref standing)))
       (filter (lambda (r) (resource-in-pool? r (lambda (a) (and (member a holders) #t)) recipe-store-ref))
               ($ observer-ref 'inventory))))

    ((embodied-labor-in-pool)
     ;; Total embodied labor in pool resources (hours). Excludes
     ;; resources already claimed by citizens.
     (let ((holders (account-holders observer-ref standing)))
       (compute-pool-value observer-ref recipe-store-ref (lambda (a) (and (member a holders) #t)))))

    ((total-claim-capacity agent-id . maybe-level)
     ;; Contribution by ability over this scope's own pool (no subtraction
     ;; of what's already been claimed; no citizenship share — the scope-
     ;; local read is the base model, f = 0). Optional LEVEL filters to
     ;; credits in plans confirmed at LEVEL. 0 if agent has no account.
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref standing agent-id level
                     (lambda (cells aid lv) (total-claim-capacity cells aid 0 lv)))))

    ((effective-balance agent-id . maybe-level)
     ;; ELASTIC purchasing power (canonical for claim checks).
     ;; = total_claim_capacity − claimed_so_far, clamped to ≥ 0.
     ;; Optional LEVEL stratifies by federation plan-confirmation; LEVEL=#f
     ;; (default) is scope-local. At parent scopes the answer is
     ;; informational — actual claims still execute against leaves.
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref standing agent-id level
                     (lambda (cells aid lv) (effective-balance cells aid 0 lv)))))

    ((citizen-ability agent-id . maybe-level)
     ;; r_p: validated hours scaled to full capacity (elastic.scm) — the
     ;; per-scope term the async federation sum reads
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref standing agent-id level ability-contribution)))

    ((ability-norm . maybe-level)
     ;; Σ r over this scope's account holders
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (ability-norm (own-credit-cells observer-ref recipe-store-ref standing) level)))

    ((effective-price spec-id qty . maybe-level)
     ;; Display-only elastic price (Option B). Returns qty × SNLT ×
     ;; (total-svc / pool) — inflates when pool is scarce relative to
     ;; labor. Internally claims still use raw SNLT × qty; this is a
     ;; UI signal for congestion, not a validation cost.
     ;; Returns +inf.0 if pool is empty or spec has no recipe.
     (let* ((level     (and (pair? maybe-level) (car maybe-level)))
            (pool      (let ((holders (account-holders observer-ref standing)))
                         (compute-pool-value observer-ref recipe-store-ref (lambda (a) (and (member a holders) #t)))))
            (total-svc ($ observer-ref 'validated-gross #f level))
            ;; same crystallized measure as the pool and the claim itself,
            ;; so the congestion ratio is dimensionally honest
            (snlt      (crystallized-snlt-for-spec recipe-store-ref spec-id)))
       (if (or (= pool 0) (= snlt +inf.0)) +inf.0
           (* qty snlt (/ total-svc pool)))))

    ;; --- Governance-relevant reads (for voice computation) ---

    ((total-social-svc . maybe-level)
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       ($ observer-ref 'validated-gross #f level)))

    ;; --- Primitives for global (federation-wide) aggregation ---
    ;; These expose per-scope contributions that top-level global-*
    ;; functions sum across scope-roots.

    ((sum-met-capacity)                 ; Σ CCF over this scope's account holders — a fact about capacity, no rule reads it
     (fold (lambda (a acc) (+ acc (standing-ccf standing a))) 0 (account-holders observer-ref standing)))

    ((sum-unmet-capacity)               ; Σ (1 − CCF)
     (fold (lambda (a acc) (+ acc (- 1 (standing-ccf standing a)))) 0 (account-holders observer-ref standing)))

    ;; the levels this scope's gate knows — the credit fold's stratified
    ;; cells are one per (citizen, level); read here so a walk over roots
    ;; needs the account store alone
    ((validation-levels) ($ observer-ref 'validation-levels))
    ((citizen-gross agent-id . maybe-level)
     ;; Validated social labor for aid in THIS scope. Feeds voice-share
     ;; (§III.2). Optional LEVEL filters to credits in plans confirmed
     ;; at LEVEL. The observer owns the gate.
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       ($ observer-ref 'validated-gross agent-id level)))

    ((citizen-claimed agent-id)
     ;; What aid has claimed in THIS scope: the sum of their individually-
     ;; claimable receipts, read off the observer's events.
     ($ observer-ref 'claim-effort agent-id))

    ((citizen-unmet agent-id)
     ;; (1 - CCF) for aid in THIS scope (0 if no account).
     ;; For global sum-unmet, citizens active in N scopes contribute
     ;; N times — multi-counting is the Phase-2 pragmatic aggregation.
     (if (member agent-id (account-holders observer-ref standing))
         (- 1 (standing-ccf standing agent-id))
         0))))


;; =========================================================================
;; Global aggregation — federation-wide elastic math
;; =========================================================================
;;
;; Scopes are branches of industry (metabolic coherence), not localities.
;; Purchasing power must be universal: your labor anywhere earns you a
;; share of the claimable stock everywhere.
;;
;; The cross-scope reads — the elastic equations, voice-share, consumer
;; voice — live with the credit fold (pools/credit-fold.scm) over the
;; cells each store states (credit-cells below); the arithmetic is
;; algorithms/elastic.scm's, read here to validate a claim.

;; ── one person, one dividend ────────────────────────────────────────────────
;; The citizenship dividend is an EQUAL share among persons, and N in social
;; free time counts persons — so what a "citizen" is decides whether a second
;; account is a second share. It is a witnessed person (the First-Person
;; personhood credential, keri/first-person/predicates.scm), never an account:
;; an account without personhood keeps every credit its own work earned
;; (contribution and solidarity are additive across accounts) and draws no
;; dividend. That is what makes consumer voice additive under an identity
;; split, the condition Incentives.lean's `split_no_gain` rests on
;; (truth-telling.md, finding 3). Governance wires the predicate here when
;; it wires the planner (socialization.scm socialized-plan-fn); absent a
;; substrate — unit tests, a commune before its first person — every
;; account holder is a person, the reading this file always had. Kept
;; boxed by set! (the silent-divergence rule), read at every count.
(define %person? #f)
(define (set-person-substrate! pred)
  "PRED : aid → bool, or #f to read every account holder as a person."
  (set! %person? pred))
(define (person-aid? aid)
  (or (not %person?) (and (%person? aid) #t)))



;; ── THE STORE STATES ITS OWN CELLS ───────────────────────────────────────────
;; Keyed sums the credit fold adds up the tree and every cross-scope read
;; computes from: one gross cell per WORKER (every provider of validated
;; work, account or none — so voice reads the same for a hand that holds no
;; account), stratified per level the observer's gate knows; claims,
;; capacity and unmet per ACCOUNT HOLDER (account-holders above); a citizen
;; cell per holder who is a person; the pool and the scope's total once.
(define* (own-credit-cells observer-ref recipe-store-ref standing
                           #:optional (aids (account-holders observer-ref standing)))
  (let* ((levels (or (false-if-exception ($ observer-ref 'validation-levels)) '()))
         (holder? (lambda (a) (and (member a aids) #t)))
         (gross (lambda (aid . l) ($ observer-ref 'validated-gross aid (and (pair? l) (car l))))))
    (credit-combine
     '()
     (append
      (append-map
       (lambda (aid)
         (let ((ccf (standing-ccf standing aid)))
           (append
            (list (cons (cons 'gross aid) (gross aid)))
            (map (lambda (l) (cons (cons 'gross-at (cons aid l)) (gross aid l))) levels)
            ;; a citizen is a witnessed person, account or none — a worker who
            ;; has never claimed is one; contribution by ability reads on citizens
            (if (person-aid? aid) (list (cons (cons 'citizen aid) 1)) '())
            (list (cons (cons 'claimed aid) ($ observer-ref 'claim-effort aid))
                  (cons (cons 'ccf aid) ccf)
                  (cons (cons 'unmet aid) (- 1 ccf))))))
       aids)
      (map (lambda (l) (cons (cons 'svc-at l) ($ observer-ref 'validated-gross #f l))) levels)
      (list (cons '(pool . *) (compute-pool-value observer-ref recipe-store-ref holder?))
            (cons '(svc . *) ($ observer-ref 'validated-gross #f)))))))

;; --- Household consumer voice: the same law, no scope tree ---
;;
;; `consumer-voice` above walks a scope tree of accounts and a priced pool —
;; machinery a family has none of (no credit-node, no observer, no priced
;; individually-claimable stock; playnet.typ line ~3425 names this the design
;; gap "most urgent to close": reproductive labour, including a child's, is
;; "not yet first-class"). The LAW is unchanged (playnet.typ §The credit
;; identity, and the governance reading at "Everyone — workers, children, the
;; elderly, the unable — carries weight"): contribution BY ABILITY (hours read
;; against the hours one's capacity could give), citizenship an equal share of
;; social free time. These two functions apply that SAME law — elastic.scm's
;; arithmetic over cells the members are stated as
;; verbatim — to a household's own declared members, with the pool normalised
;; to 1 so only the shares are wanted.

(define* (household-social-free-time members #:key (per-citizen-hours 40.0))
  "MEMBERS ((person capacity hours) …), HOURS the labour L_p a member
   contributed to the household's own reproduction this period. Social free
   time f = 1 − ΣL_p / (N·PER-CITIZEN-HOURS) — the same formula
   `global-social-free-time` reads off a scope tree, read here over a
   household's own members instead."
  (let* ((L  (fold (lambda (m a) (+ a (third m))) 0 members))
         (n  (length members))
         (nt (* n per-citizen-hours)))
    (if (<= nt 0) 0 (max 0 (min 1 (- 1 (/ L nt)))))))

(define* (household-consumer-voice members #:key (per-citizen-hours 40.0) (f #f))
  "MEMBERS ((person capacity hours) …): CAPACITY a_p ∈ [0,1] is the
   contribution-capacity factor (1 = full capacity to labour; a child's, an
   elder's, anyone's reduced capacity is lower), HOURS L_p the labour
   contributed to the household's own reproduction this period. Returns
   ((person . v_p^cons) …), Σ = 1 — the SAME law `consumer-voice` computes
   for a federation scope: contribution BY ABILITY (hours read against the
   hours the capacity could give), citizenship an equal share of social free
   time F (defaults to `household-social-free-time`). Built by stating the
   members as credit cells (elastic.scm) with the pool normalised to 1 and
   handing them to the one function (`consumer-voices-of`) a scope's credit
   fold reads, so a member who can contribute no
   hours at all — a small child, capacity 0 — is read as having given all
   they could and carries real voice, never zero, exactly as playnet.typ
   §Governance reads it: 'Everyone — workers, children, the elderly, the
   unable — carries weight in shaping what the federation produces.'"
  (let* ((g      (max 0 (min 1 (or f (household-social-free-time members #:per-citizen-hours per-citizen-hours)))))
         (cells  (cons '((pool . *) . 1)
                       (append-map (lambda (m)
                                     (list (cons (cons 'gross (first m)) (third m))
                                           (cons (cons 'ccf (first m)) (second m))
                                           (cons (cons 'citizen (first m)) 1)))
                                   members)))
         (voices (consumer-voices-of cells g)))
    ;; no capacity stands (nobody declared, or a horizon that reads as none): an
    ;; equal share each — no information is no penalty
    (if (null? voices)
        (map (lambda (m) (cons (first m) (/ 1 (length members)))) members)
        voices)))

;; --- Legacy aliases / raw aggregates ---

(define (universal-credit-balance agent-id scope-roots)
  "Sum raw credit-balance (gross − claimed) across all scopes.
   Diagnostic helper — raw, not elastic. For governance voice use
   voice-share. For claim authorization use global-effective-balance."
  (fold (lambda (scope acc)
          (+ acc ($ ($ scope 'account-store) 'credit-balance agent-id)))
        0 scope-roots))


;; =========================================================================
;; Persistence environment
;; =========================================================================

(define account-store-env
  (make-persistence-env
    `((((vf observation) ^account-store) ,^account-store))))
