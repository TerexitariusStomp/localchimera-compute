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
;;;   - The account record still caches `gross-contribution-credited`
;;;     (eagerly updated by credit-from-event) and `claimed-capacity`
;;;     (unused for balance; retained for schema stability). The
;;;     authoritative values come from the observer's event log.
;;;
;;; STATE: observer-ref (near actor) + accounts hashmap (agent-id -> <account>).
;;; No pool hashmap — pool is a derived query over observer resources.

(define-module (playnet planner observation account)
  #:use-module (goblins)
  #:use-module (playnet planner algorithms elastic)   ; the credit identity's arithmetic over cells
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 match)
  #:use-module (playnet planner vf serdes)
  #:use-module (playnet planner vf schemas)
  #:use-module ((playnet planner formulas flows) #:select (make-work-event))
  #:use-module (playnet planner observation states)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet utils store-utils)
  #:use-module ((playnet utils keyed-id) #:select (keyed-id))
  #:use-module ((playnet utils units) #:select (%placeholder-unit %effort-unit))
  #:use-module (playnet planner algorithms rollup)
  #:use-module (playnet planner facts rail)
  #:re-export (claimable-specs declare-claimable! spec-claimable? spec-rail publish-rails! declare-rail!
               publish-social-portion! declare-social-portion! spec-social-portion)
  #:export (*individually-claimable* resource-individually-claimable?
            claim-cid claim-commitment claim-cid-terms open-claim-for fulfillment-remaining
            event-classified-individually-claimable? account->list list->account
            resource-in-pool? compute-pool-value
            with-elastic ^account-store sum-across-scopes
            household-social-free-time household-consumer-voice
            universal-credit-balance account-store-env
            set-person-substrate! person-aid?))



;; Assumes schemas.scm and store-utils.scm are loaded.


;; =========================================================================
;; Classification constants
;; =========================================================================

(define *individually-claimable* "individually-claimable")  ; the legacy tag, kept for import normalisation

;; ── the rail a good is on is read off the recipes — (playnet planner facts rail) ──
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

(define (claim-cid-terms cid)
  "(spec claimant place when) off a claim commitment id, or #f for any other id."
  (let ((parts (string-split cid #\|)))
    (and (= 5 (length parts)) (equal? "claim" (car parts))
         (let ((p (list-ref parts 3)) (w (list-ref parts 4)))
           (list (cadr parts) (caddr parts)
                 (and (not (string-null? p)) p) (and (not (string-null? w)) w))))))

(define* (claim-commitment spec claimant qty scope-id #:key (place #f) (when-iso #f) (unit %placeholder-unit))
  "The plan's claim row as a `transfer` commitment: SPEC to CLAIMANT, QTY at PLACE, WHEN-ISO."
  (make-commitment
   #:id (claim-cid spec claimant place when-iso) #:action 'transfer #:resource-conforms-to spec
   #:resource-quantity (make-measure qty unit) #:receiver claimant #:has-point-in-time when-iso
   #:at-location place #:in-scope-of (list scope-id)))

(define (fulfillment-remaining fs)
  (- (measure-has-numerical-value (fulfillment-state-total-committed fs))
     (measure-has-numerical-value (fulfillment-state-total-fulfilled fs))))

(define* (open-claim-for observer-ref spec claimant #:key (place #f) (at-least 0))
  "The plan's open claim commitment of SPEC for CLAIMANT with AT-LEAST remaining —
   at PLACE when one is named — as its fulfillment state, or #f."
  (find (lambda (fs)
          (let ((t (claim-cid-terms (fulfillment-state-commitment-id fs))))
            (and t (equal? (car t) spec) (equal? (cadr t) claimant)
                 (or (not place) (equal? (caddr t) place))
                 (>= (fulfillment-remaining fs) (- at-least 1e-9)))))
        ($ observer-ref 'open-fulfillments)))


;; =========================================================================
;; Record <-> list serialization
;; =========================================================================

(define (account->list a) (vf-serialize a))
(define (list->account lst) (vf-deserialize lst))


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

(define* (resource-in-pool? resource accounts #:optional (store #f))
  "A resource is in the claimable pool iff it is individually-claimable
   AND its primary-accountable is NOT a citizen with an account in this
   scope. Once a citizen claims a resource, primary-accountable moves to
   them and the resource exits the pool — it is personal holding now."
  (and (resource-individually-claimable? resource store)
       (not (hashmap-ref accounts
                         (economic-resource-primary-accountable resource)
                         #f))))

(define (compute-pool-value observer-ref recipe-store-ref accounts)
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
              (filter (lambda (r) (resource-in-pool? r accounts recipe-store-ref))
                      ($ observer-ref 'inventory)))
    (hash-fold (lambda (spec qty acc)
                 (let ((snlt (crystallized-snlt-for-spec recipe-store-ref spec))
                       (left (max 0 (- qty (spec-social-portion spec recipe-store-ref)))))
                   (if (= snlt +inf.0) acc (+ acc (* left snlt)))))
               0 per-spec)))

(define* (with-elastic observer-ref recipe-store-ref accounts aid level k)
  "Call K on this store's own cells for AID at federation LEVEL (#f:
   scope-local). 0 when AID holds no account here."
  (if (not (hashmap-ref accounts aid #f)) 0
      (k (own-credit-cells observer-ref recipe-store-ref accounts) aid level)))


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

(define-actor (^account-store bcom observer-ref recipe-store-ref accounts on-work
                              #:optional (listeners '()))
  ;; observer-ref:      near ref to this scope's ^observer (same vat)
  ;; recipe-store-ref:  near ref to this scope's ^recipe-store (for SNLT)
  ;; accounts:          hashmap of agent-id -> <account>
  ;; on-work:           (lambda (event) → unit) or #f
  ;;                    Called after a work event is credited.
  ;;                    The closure encapsulates ACDC emission — planner
  ;;                    stays oblivious to credential schemas.
  ;; listeners:         additive change listeners, (lambda () → unit) each —
  ;;                    fired after ANY account mutation (the credit fold
  ;;                    hears its writers here). Not serialized; re-added
  ;;                    after restore, like on-work.

  #:portrait
  (lambda () (list observer-ref recipe-store-ref
                   (serialize-hashmap accounts account->list)))

  #:version 5

  #:restore
  (lambda (version obs rs sa)
    ;; on-work isn't serializable; restore with #f, gateway re-binds via
    ;; set-on-work after recovery (mirrors plan-store.set-on-commitment).
    ;; v5 dropped the gross-contribution-credited cache field — gross is
    ;; now derived from the observer via the Validation Gate (§III.1).
    ;; Legacy portraits (v3/v4) are migrated by dropping that 2nd field.
    (define (legacy->account lst)
      (match lst
        ((aid _gross claimed ccf) (make-account aid claimed ccf))))
    (case version
      ((3 4) (spawn ^account-store obs rs
                    (deserialize-hashmap sa legacy->account) #f))
      ((5)   (spawn ^account-store obs rs
                    (deserialize-hashmap sa list->account) #f))
      (else (error "Unknown ^account-store version" version))))

  (methods

    ;; --- Account management ---

    ((ensure-account agent-id)
     (if (hashmap-ref accounts agent-id #f)
         agent-id
         (let ((acct (make-account agent-id 0 1)))
           (bcom (^account-store bcom observer-ref recipe-store-ref
                   (hashmap-set accounts agent-id acct) on-work listeners)
                 agent-id))))

    ((get-account agent-id)
     (hashmap-ref accounts agent-id #f))

    ((all-accounts)
     (hashmap-values accounts))
    ;; this scope's credit cells, stated by the store (own-credit-cells)
    ((credit-cells) (own-credit-cells observer-ref recipe-store-ref accounts))

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
         (let* ((agent-id (or (economic-event-provider event)
                              (economic-event-receiver event)))
                (qty (and (economic-event-effort-quantity event)
                          (measure-has-numerical-value
                            (economic-event-effort-quantity event))))
                (existing (hashmap-ref accounts agent-id #f))
                (new-accounts (if existing accounts
                                  (hashmap-set accounts agent-id
                                    (make-account agent-id 0 1)))))
           (when on-work (on-work event))
           (fire-listeners! listeners)
           (bcom (^account-store bcom observer-ref recipe-store-ref
                   new-accounts on-work listeners)
                 qty))))

    ((credit-from-event-silent event)
     ;; Recovery path: identical to credit-from-event but skips the
     ;; on-work callback (avoids ACDC re-emission during replay).
     (if (not (eq? (economic-event-action event) 'work))
         #f
         (let* ((agent-id (or (economic-event-provider event)
                              (economic-event-receiver event)))
                (qty (and (economic-event-effort-quantity event)
                          (measure-has-numerical-value
                            (economic-event-effort-quantity event))))
                (existing (hashmap-ref accounts agent-id #f))
                (new-accounts (if existing accounts
                                  (hashmap-set accounts agent-id
                                    (make-account agent-id 0 1)))))
           (bcom (^account-store bcom observer-ref recipe-store-ref
                   new-accounts on-work listeners)
                 qty))))

    ((set-on-work proc)
     ;; Late-bind the emission callback (post-recovery, post-restore).
     (bcom (^account-store bcom observer-ref recipe-store-ref accounts proc
                           listeners)))

    ;; additive: a listener joins, nothing it was beside is displaced
    ((add-change-listener proc)
     (bcom (^account-store bcom observer-ref recipe-store-ref accounts on-work
                           (cons proc listeners))))

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
            (evid (generate-id "boot-ev-"))
            (qty  (make-measure svc-amount %effort-unit)))
       ($ observer-ref 'register-intent
          (make-intent #:id iid #:action 'work #:resource-conforms-to "spec-labor" #:effort-quantity qty
                       #:provider agent-id))
       ($ observer-ref 'record-event
          (make-work-event #:id evid #:resource-spec "spec-labor" #:provider agent-id
                           #:effort-qty svc-amount #:effort-unit %effort-unit #:satisfies iid
                           #:timestamp #f #:note #f))
       (let ((existing (hashmap-ref accounts agent-id #f)))
         (bcom (^account-store bcom observer-ref recipe-store-ref
                 (if existing accounts
                     (hashmap-set accounts agent-id
                       (make-account agent-id 0 1)))
                 on-work listeners)))))

    ((set-ccf agent-id new-ccf)
     ;; Set the contribution-capacity-factor for an agent.
     ;; Governance layer is responsible for authorizing this call
     ;; (typically gated by a capability held behind the gov-seal).
     (when (or (< new-ccf 0) (> new-ccf 1))
       (error "CCF must be in [0, 1]" agent-id new-ccf))
     (let* ((existing (hashmap-ref accounts agent-id #f))
            (acct (or existing (make-account agent-id 0 1)))
            (updated (make-account agent-id
                                   (account-claimed-capacity acct)
                                   new-ccf)))
       (fire-listeners! listeners)
       (bcom (^account-store bcom observer-ref recipe-store-ref
               (hashmap-set accounts agent-id updated) on-work listeners))))

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
                 ;; commitment of ample quantity admits nothing (claim-cid-terms reads
                 ;; a claim id alone). With plan-claims! the only minter of claim ids,
                 ;; and a claim recipe built only for a good on the individual rail
                 ;; (live.scm claim-recipes), "rights reach a person only through the
                 ;; plan's claim" holds by construction here.
                 (terms (or (and fs (claim-cid-terms fulfills))
                            (error (if fs
                                       "a claim fulfils the plan's claim commitment alone"
                                       "the plan holds no such claim; state the want and the plan answers")
                                   claimant-aid resource-id fulfills)))
                 ;; the claimant is READ OFF the plan's word, never stated: the
                 ;; transfer's receiver, the lot it lands in and the account debited
                 ;; are all the one name the claim id carries. CLAIMANT-AID is the
                 ;; caller's confirmation of who it speaks for.
                 (claimant (cadr terms))
                 (eff-balance (effective-balance (credit-cells scope-roots) claimant (current-social-free-time) level))
                 (acct (or (hashmap-ref accounts claimant #f)
                           (make-account claimant 0 1))))
            (unless (equal? (car terms) (economic-resource-conforms-to resource))
              (error "the plan's claim names another good"
                     fulfills (economic-resource-conforms-to resource)))
            (unless (equal? claimant claimant-aid)
              (error "the plan's claim names another citizen" fulfills claimant claimant-aid))
            (when (> qty (+ (fulfillment-remaining fs) 1e-9))
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
                     (make-economic-event
                       #:id (generate-id "claim-")
                       #:action 'transfer
                       #:resource-inventoried-as resource-id
                       ;; the claimant's share lands in a resource made to hold it
                       #:to-resource-inventoried-as to-resource-id
                       #:resource-conforms-to (economic-resource-conforms-to resource)
                       #:resource-classified-as (economic-resource-classified-as resource)
                       #:provider provider #:receiver claimant-aid
                       #:resource-quantity (make-measure qty unit)
                       #:effort-quantity (make-measure labor-cost %effort-unit)
                       #:has-point-in-time (or when* #f)   ; WHEN wanted
                       #:to-location (or at-loc #f)        ; WHERE to
                       #:fulfills fulfills                  ; the planned claim
                       #:in-scope-of '()
                       ;; the rail this transfer ran on, as provenance on the event:
                       ;; ledger-claimed and the claim ACDC read it back
                       #:distribution-mode 'individual-claimable)))
              ($ observer-ref 'record-event event)
              (let* ((updated (make-account
                                claimant
                                (+ (account-claimed-capacity acct) labor-cost)
                                (account-contribution-capacity-factor acct))))
                (fire-listeners! listeners)
                (bcom (^account-store bcom observer-ref recipe-store-ref
                        (hashmap-set accounts claimant updated) on-work
                        listeners)
                      #t))))))))

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
     (filter (lambda (r) (resource-in-pool? r accounts recipe-store-ref))
             ($ observer-ref 'inventory)))

    ((embodied-labor-in-pool)
     ;; Total embodied labor in pool resources (hours). Excludes
     ;; resources already claimed by citizens.
     (compute-pool-value observer-ref recipe-store-ref accounts))

    ((total-claim-capacity agent-id . maybe-level)
     ;; Contribution by ability over this scope's own pool (no subtraction
     ;; of what's already been claimed; no citizenship share — the scope-
     ;; local read is the base model, f = 0). Optional LEVEL filters to
     ;; credits in plans confirmed at LEVEL. 0 if agent has no account.
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref accounts agent-id level
                     (lambda (cells aid lv) (total-claim-capacity cells aid 0 lv)))))

    ((effective-balance agent-id . maybe-level)
     ;; ELASTIC purchasing power (canonical for claim checks).
     ;; = total_claim_capacity − claimed_so_far, clamped to ≥ 0.
     ;; Optional LEVEL stratifies by federation plan-confirmation; LEVEL=#f
     ;; (default) is scope-local. At parent scopes the answer is
     ;; informational — actual claims still execute against leaves.
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref accounts agent-id level
                     (lambda (cells aid lv) (effective-balance cells aid 0 lv)))))

    ((citizen-ability agent-id . maybe-level)
     ;; r_p: validated hours scaled to full capacity (elastic.scm) — the
     ;; per-scope term the async federation sum reads
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (with-elastic observer-ref recipe-store-ref accounts agent-id level ability-contribution)))

    ((ability-norm . maybe-level)
     ;; Σ r over this scope's account holders
     (let ((level (and (pair? maybe-level) (car maybe-level))))
       (ability-norm (own-credit-cells observer-ref recipe-store-ref accounts) level)))

    ((effective-price spec-id qty . maybe-level)
     ;; Display-only elastic price (Option B). Returns qty × SNLT ×
     ;; (total-svc / pool) — inflates when pool is scarce relative to
     ;; labor. Internally claims still use raw SNLT × qty; this is a
     ;; UI signal for congestion, not a validation cost.
     ;; Returns +inf.0 if pool is empty or spec has no recipe.
     (let* ((level     (and (pair? maybe-level) (car maybe-level)))
            (pool      (compute-pool-value observer-ref recipe-store-ref accounts))
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

    ((sum-met-capacity)                 ; Σ CCF over this scope's accounts — a fact about capacity, no rule reads it
     (hashmap-fold (lambda (_k a acc) (+ acc (account-contribution-capacity-factor a))) 0 accounts))

    ((sum-unmet-capacity)               ; Σ (1 − CCF)
     (hashmap-fold (lambda (_k a acc) (+ acc (- 1 (account-contribution-capacity-factor a)))) 0 accounts))

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
     ;; Claimed-capacity for aid in THIS scope (0 if no account).
     (let ((a (hashmap-ref accounts agent-id #f)))
       (if a (account-claimed-capacity a) 0)))

    ((citizen-unmet agent-id)
     ;; (1 - CCF) for aid in THIS scope (0 if no account).
     ;; For global sum-unmet, citizens active in N scopes contribute
     ;; N times — multi-counting is the Phase-2 pragmatic aggregation.
     (let ((a (hashmap-ref accounts agent-id #f)))
       (if a (- 1 (account-contribution-capacity-factor a)) 0)))))


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
;; capacity and unmet per ACCOUNT; a citizen cell per account holder who is
;; a person; the pool and the scope's total once.
(define (own-credit-cells observer-ref recipe-store-ref accounts)
  (let* ((accts (hashmap-values accounts))
         (levels (or (false-if-exception ($ observer-ref 'validation-levels)) '()))
         (workers (map car (or (false-if-exception ($ observer-ref 'hours-by economic-event-provider)) '())))
         (aids (delete-duplicates (append (map account-agent-id accts) workers)))
         (gross (lambda (aid . l) ($ observer-ref 'validated-gross aid (and (pair? l) (car l))))))
    (credit-combine
     '()
     (append
      (append-map
       (lambda (aid)
         (let ((a (hashmap-ref accounts aid #f)))
           (append
            (list (cons (cons 'gross aid) (gross aid)))
            (map (lambda (l) (cons (cons 'gross-at (cons aid l)) (gross aid l))) levels)
            ;; a citizen is a witnessed person, account or none — a worker who
            ;; has never claimed is one; contribution by ability reads on citizens
            (if (person-aid? aid) (list (cons (cons 'citizen aid) 1)) '())
            (if a
                (let ((ccf (account-contribution-capacity-factor a)))
                  (list (cons (cons 'claimed aid) (account-claimed-capacity a))
                        (cons (cons 'ccf aid) ccf)
                        (cons (cons 'unmet aid) (- 1 ccf))))
                '()))))
       aids)
      (map (lambda (l) (cons (cons 'svc-at l) ($ observer-ref 'validated-gross #f l))) levels)
      (list (cons '(pool . *) (compute-pool-value observer-ref recipe-store-ref accounts))
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
