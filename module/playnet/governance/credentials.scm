;;; credentials.scm — ACDC schemas and constructors for governance state
;;;
;;; Phase-1: pure-data constructors. Each `make-*-credential` returns an
;;; alist representing the ACDC bundle:
;;;
;;;   ((said       . string)        ; deterministic blake3 SAID (CESR "E")
;;;    (schema     . symbol)        ; one of *playnet-schemas*
;;;    (issuer     . string)        ; AID of issuer
;;;    (holder     . string)        ; AID of holder (subject)
;;;    (claims     . alist)         ; schema-specific (ACDC `a` block)
;;;    (edges      . alist)         ; ACDC `e` block — see `make-edge`
;;;    (revoked?   . boolean))      ; live-mutable in ^acdc-store
;;;
;;; Edges follow ACDC §8: a chained reference from this credential to
;;; another by SAID, with an optional operator constraining the chain.
;;; Represented here as an alist of (edge-name . edge-spec) where
;;; edge-spec itself is an alist with keys:
;;;   n — SAID of the target credential (required)
;;;   o — operator symbol: 'I2I (Issuer-to-Issuee), 'NI2I, or #f
;;;   s — target schema identifier (optional; informational only)
;;; The SAID folds the edge block in, so any edge change changes the
;;; SAID — matching ACDC's invariant that `e` is SAID-covered.
;;;
;;; In Phase-2, ^acdc-store will translate these into actual ACDC IPEX
;;; flows over KERIA. The constructors here are the pure data layer.
;;;
;;; Mandate serialization: predicates aren't directly portable. We
;;; compile from a small DSL of specs:
;;;
;;;   (equal-position SYMBOL)
;;;       → predicate that returns #t iff the stance's position == SYMBOL
;;;   (any-of-position (SYMBOL …))
;;;       → predicate that returns #t iff position ∈ symbol-list
;;;   (min-distribution PLAN-ID FRACTION)
;;;       → predicate that returns #t iff distribution[PLAN-ID] ≥ FRACTION
;;;   opaque
;;;       → marker for predicates we couldn't introspect; recovers as #f
;;;         (liquid) with a warning
;;;
;;; A module of (playnet governance); the umbrella re-exports it.

(define-module (playnet governance credentials)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet governance sturdyref-credential) #:select (*schema-playnet-federation-sturdyref* *schema-playnet-federation-census*))
  #:use-module (playnet openvtc credentials)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri said-portable)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet utils clock)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri crypto-primitives)
  #:use-module (playnet keri citizen-sig)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:export (*schema-playnet-delegation* *schema-playnet-ccf-assessment*
            *schema-playnet-exclusion* *schema-playnet-federation-membership*
            *schema-playnet-membership* *schema-playnet-bran-share*
            *schema-playnet-stance*
            *schema-playnet-expression-stance* *schema-playnet-ballot-snapshot*
            *schema-playnet-tally-result* *schema-playnet-work-event*
            *schema-playnet-observation-event* *schema-playnet-commitment*
            *schema-playnet-scope-merger* *schema-playnet-scope-split*
            *schema-playnet-scope-rejoin* *schema-playnet-conflict-resolution*
            *schema-playnet-intent* *schema-playnet-agreement*
            *schema-playnet-external-index-observation*
            *schema-playnet-custody-attestation*
            *schema-playnet-ownership-attestation*
            make-ownership-attestation-credential
            *schema-playnet-custody-transfer-commitment* *schema-playnet-audit-pass*
            *schema-playnet-incoherence-alert*
            *schema-playnet-reversion-attestation*
            *schema-playnet-commitment-fulfillment*
            *schema-playnet-redistribution-mandate*
            *schema-playnet-span-declaration* *schema-playnet-hosting-willingness*
            *schema-playnet-regime-claim*
            *schema-playnet-contrary-observation* make-contrary-observation-credential
            *schema-playnet-recomposition-ratification*
            *schema-playnet-derived-state-snapshot*
            *schema-playnet-witness-assignment* *schema-playnet-skill*
            *schema-playnet-claim* *playnet-schemas* *claim-index-registry*
             *timestamp-claim-registry* compute-plan-said
            cred-signed-by-scope make-delegation-credential make-ccf-credential
            make-exclusion-credential make-federation-membership-credential
            make-membership-credential make-bran-share-credential
            make-federation-sturdyref-credential make-federation-census-credential make-stance-credential
            make-expression-stance-credential make-ballot-snapshot-credential
            make-tally-result-credential make-work-event-credential
            make-observation-event-credential make-scope-merger-credential
            make-scope-split-credential make-conflict-resolution-credential
            make-scope-rejoin-credential make-commitment-credential
            make-redistribution-mandate-credential
            make-recomposition-ratification-credential
            make-commitment-fulfillment-credential
            make-custody-attestation-credential %make-scope-self-declaration
            make-span-declaration-credential make-hosting-willingness-credential
            make-regime-claim-credential make-skill-credential
            make-claim-event-credential make-custody-transfer-commitment-credential
            make-agreement-credential
            make-external-index-observation-credential make-intent-credential
            make-audit-pass-credential make-incoherence-alert-credential
            make-reversion-attestation-credential
            make-derived-state-snapshot-credential compile-mandate-spec
            mandate-spec-of *predicate-spec-registry* register-mandate-predicate
            predicate->spec mandate make-witness-assignment-credential
            witness-assignments-for-federation count-witness-attestors
            audit-witness-quorum-independence)
  #:re-export (*schema-playnet-federation-sturdyref* *schema-playnet-federation-census*
               indexed-claims-for make-credential cred-with-signature credential-preimage-fields cred-said
               cred-schema cred-issuer cred-holder cred-claims cred-edges
               cred-signature cred-revoked? cred-claim cred-edge cred-with-revoked
               cred-recompute-said cred-said-consistent? make-edge edge-target
               edge-operator edge-schema edge-i2i-holds? blinding-nonce u-claim
               iso-utc-now timestamp-claim-for parse-time-value cred-timestamp
               *schema-playnet-personhood* *schema-playnet-relationship*
               *schema-playnet-contact-point* *schema-playnet-authorized-issuer*
               *schema-playnet-device-authorization*
               make-device-authorization-credential make-authorized-issuer-credential
               make-personhood-credential make-relationship-credential
               *contact-point-kinds* contact-point-kind? contact-point-identifying?
               make-contact-point-credential contact-point-binding-fields
               contact-point-acceptable?))

;; =========================================================================
;; Schema identifiers (stable strings)
;; =========================================================================

(define *schema-playnet-delegation*             "playnet-delegation/v1")
(define *schema-playnet-ccf-assessment*         "playnet-ccf-assessment/v1")
(define *schema-playnet-exclusion*              "playnet-exclusion/v1")
(define *schema-playnet-federation-membership*  "playnet-federation-membership/v1")
(define *schema-playnet-membership*             "playnet-membership/v1")
(define *schema-playnet-bran-share*             "playnet-bran-share/v1")
(define *schema-playnet-stance*                 "playnet-stance/v1")
(define *schema-playnet-expression-stance*      "playnet-expression-stance/v1")
(define *schema-playnet-ballot-snapshot*         "playnet-ballot-snapshot/v1")
(define *schema-playnet-tally-result*            "playnet-tally-result/v1")
(define *schema-playnet-work-event*              "playnet-work-event/v1")
(define *schema-playnet-observation-event*       "playnet-observation-event/v1")
(define *schema-playnet-commitment*              "playnet-commitment/v1")
(define *schema-playnet-scope-merger*            "playnet-scope-merger/v1")
(define *schema-playnet-scope-split*             "playnet-scope-split/v1")
(define *schema-playnet-scope-rejoin*            "playnet-scope-rejoin/v1")
(define *schema-playnet-conflict-resolution*     "playnet-conflict-resolution/v1")
(define *schema-playnet-intent*                  "playnet-intent/v1")
(define *schema-playnet-agreement*               "playnet-agreement/v1")
(define *schema-playnet-external-index-observation*
  "playnet-external-index-observation/v1")
(define *schema-playnet-custody-attestation*     "playnet-custody-attestation/v1")
(define *schema-playnet-ownership-attestation*   "playnet-ownership-attestation/v1")
(define *schema-playnet-custody-transfer-commitment*
  "playnet-custody-transfer-commitment/v1")
(define *schema-playnet-audit-pass*              "playnet-audit-pass/v1")
(define *schema-playnet-incoherence-alert*       "playnet-incoherence-alert/v1")
(define *schema-playnet-reversion-attestation*   "playnet-reversion-attestation/v1")
(define *schema-playnet-commitment-fulfillment*  "playnet-commitment-fulfillment/v1")
;; Voice-rule and weight-rule schemas removed in 2026-04 cleanup.
;; This protocol commits to labor-proportional aggregation at every
;; level (see
;; docs/governance/GOVERNANCE-PROPORTIONAL.md). Voice is universal
;; gross/total; federation aggregation is `commune-weight-async`
;; (labor-share, hardcoded). Pluralism at either layer would betray
;; the design center.
(define *schema-playnet-redistribution-mandate*
  "playnet-redistribution-mandate/v1")
;; Span declaration: how far a means' service POOLS is an allocation
;; decision, not a fact of where it sits (patchwork-scopes-containment.md
;; §2.3). The steward scope declares the pool's extent; the planner reads
;; it (*span-of*) in place of the holding place. Location is never touched,
;; so reach − span stays a readable withholding figure.
(define *schema-playnet-span-declaration*
  "playnet-span-declaration/v1")
;; Hosting willingness: the consent half of the means-pool (work-plan step 4).
;; A span declaration reaches into another scope's place only as far as that
;; scope has said it is willing and able to host — "we can run and maintain
;; this, up to here". The envelope is a CEILING, never a claim: the exact
;; consent shape labour already has, where uc-matching places only within an
;; agent's declared availability.
(define *schema-playnet-hosting-willingness*
  "playnet-hosting-willingness/v1")
;; Regime claim: statistics is LICENSED, and the licence is a witnessed fact
;; about a domain — thin tails AND a stable generating process — never a
;; property a report grants itself (docs/planning/solve/recipe-metabolism-barbell.md
;; principle 4). Anything else, ignorance included, is probability-free.
(define *schema-playnet-regime-claim*
  "playnet-regime-claim/v1")
;; A worker's word against a mapped figure: "I ran PROCESS and its ACTION on
;; SPEC read READING where the map says NOMINAL" — a contrary observation
;; (docs/planning/voice/feasibility-follows-the-map.md). Issued and held by
;; the observer, in their own name, on the witness of a work event of theirs
;; on that process; the solve reads it as the world as observed, in every
;; future (planner/solve/engine/robust.scm observed-shocks).
(define *schema-playnet-contrary-observation*
  "playnet-contrary-observation/v1")
(define *schema-playnet-recomposition-ratification*
  "playnet-recomposition-ratification/v1")
;; Scope-recognition: the single credential that materializes the
;; universality-of-contribution measure. A scope SCOPE-AID issues
;; (and self-holds) a recognition naming a target — either a plan
;; (`'plan`) or an intent (`'intent`). The observer's gate reads
;; the union of plan- and intent-level recognitions through one
;; predicate, so weighting (voice-share) and Credit validity
;; (validated-gross) share the same universality measure.
;; Binary by design — no per-credential weight (see L78–84 above);
;; aggregation stays labor-proportional.
;; §4.5: derived-state snapshot. An auditor scope periodically signs a
;; snapshot of derived numbers (voice shares, P_extract, …) plus edges
;; to the input ACDCs the snapshot was computed from. Verifiers see
;; "this snapshot is authenticated by reference to these inputs"
;; without forcing the inputs to be re-signed.
(define *schema-playnet-derived-state-snapshot* "playnet-derived-state-snapshot/v1")

;; Witness assignment: a federation issues this credential to a member
;; AID to attest that the member operates a specific KERIA witness on
;; the federation's behalf. The auditor uses the set of these to verify
;; that toad-many witnesses are run by ≥toad-many distinct members
;; (no single operator controls quorum). See
;; docs/governance/FEDERATION-WITNESSES.md for the design and the
;; bootstrap/recovery flows that read these credentials.
(define *schema-playnet-witness-assignment*
  "playnet-witness-assignment/v1")

;; Skill: the membership token for competence. A scope (or training
;; authority) issues this to a worker AID to attest "WORKER holds SKILL",
;; minted ONCE per (worker, skill) the first time the worker does work
;; conforming to that skill. It is immutable and derive-don't-store: the
;; accumulated hours are NOT carried here — they are summed on demand from
;; the worker's work-event log (observer `practiced-hours`). The credential
;; edges to its FOUNDING work event, anchoring provenance; the growing set
;; of work events is the derived index, not a field on this token.
(define *schema-playnet-skill* "playnet-skill/v1")

;; Claim: the CONSUMPTION mirror of the work-event ACDC. When a person draws
;; earned credit to receive an individually-claimable good (an EconomicEvent of
;; action `transfer`, effortQuantity = the labour-hours drawn), the scope attests
;; it. ledger-claimed sums these; credit-balance = gross (work-event ACDCs) −
;; claimed (claim ACDCs), so the WHOLE ledger — both halves — reconstructs from
;; the portable ACDC set, exactly as the contribution side does.
(define *schema-playnet-claim* "playnet-claim/v1")

(define *playnet-schemas*
  (list *schema-playnet-delegation*
        *schema-playnet-ccf-assessment*
        *schema-playnet-exclusion*
        *schema-playnet-federation-membership*
        *schema-playnet-membership*
        *schema-playnet-bran-share*
        *schema-playnet-federation-sturdyref*
        *schema-playnet-federation-census*
        *schema-playnet-stance*
        *schema-playnet-expression-stance*
        *schema-playnet-ballot-snapshot*
        *schema-playnet-tally-result*
        *schema-playnet-work-event*
        *schema-playnet-observation-event*
        *schema-playnet-commitment*
        *schema-playnet-scope-merger*
        *schema-playnet-scope-split*
        *schema-playnet-scope-rejoin*
        *schema-playnet-conflict-resolution*
        *schema-playnet-intent*
        *schema-playnet-agreement*
        *schema-playnet-external-index-observation*
        *schema-playnet-personhood*
        *schema-playnet-relationship*
        *schema-playnet-contact-point*
        *schema-playnet-authorized-issuer*
        *schema-playnet-device-authorization*
        *schema-playnet-custody-attestation*
        *schema-playnet-ownership-attestation*
        *schema-playnet-custody-transfer-commitment*
        *schema-playnet-audit-pass*
        *schema-playnet-incoherence-alert*
        *schema-playnet-reversion-attestation*
        *schema-playnet-derived-state-snapshot*
        *schema-playnet-commitment-fulfillment*
        *schema-playnet-redistribution-mandate*
        *schema-playnet-recomposition-ratification*
        *schema-playnet-witness-assignment*
        *schema-playnet-skill*
        *schema-playnet-claim*))

;; =========================================================================
;; Claim-index registry
;; =========================================================================
;;
;; Schemas declare which claims should be indexed by ^acdc-store for
;; O(1) lookup. Hot-path queries (commitment-id, proposal-id, fulfills)
;; get indexed; cold-path (recovery scans) use the existing by-schema /
;; by-issuer / by-holder which are O(n).

(define *claim-index-registry*
  ;; alist: schema-string → list of claim-key symbols to index
  `((,*schema-playnet-commitment*       . (commitment-id))
    (,*schema-playnet-work-event*       . (event-id fulfills))
    (,*schema-playnet-observation-event* . (event-id fulfills))
    (,*schema-playnet-stance*           . (domain proposal-id))
    (,*schema-playnet-expression-stance*      . (domain expression-id))
    (,*schema-playnet-ballot-snapshot*  . (domain proposal-id))
    (,*schema-playnet-tally-result*     . (domain proposal-id))
    (,*schema-playnet-scope-merger*     . (new-scope-aid))
    (,*schema-playnet-scope-split*      . (parent-scope-aid))
    (,*schema-playnet-scope-rejoin*     . (scope-aid))
    (,*schema-playnet-conflict-resolution* . (resource-id))

    (,*schema-playnet-contrary-observation* . (scope-id process action))
    (,*schema-playnet-ownership-attestation* . (resource-id))
    (,*schema-playnet-intent*           . (intent-id))
    (,*schema-playnet-agreement*        . (agreement-id proposal-id))
    (,*schema-playnet-external-index-observation* . (index-uri))
    ;; First-Person layer. PHC indexed by its ecosystem so
    ;; `holds-live-phc?` is O(1) given (ecosystem, holder). VRC's edge
    ;; to the issuer's PHC lives in the ACDC `e` block, not a claim —
    ;; verification walks edges structurally (see first-person.scm).
    (,*schema-playnet-personhood*          . (ecosystem-aid sponsor-aid))
    (,*schema-playnet-recomposition-ratification* . (proposal-type proposal-spec))
    ;; Witness assignment indexed by witness-aid — the auditor's hot
    ;; path is "who operates witness X?" Holder (member-aid) is already
    ;; available via the by-holder index that every credential gets.
    (,*schema-playnet-witness-assignment*  . (witness-aid))
    ;; Skill indexed by `skill` so "does holder X hold skill S?" (the
    ;; mint-once possession check + the lift) is O(1) given (skill, holder).
    (,*schema-playnet-skill*               . (skill))
    (,*schema-playnet-claim*               . (event-id))))

;; indexed-claims-for lives in (playnet keri acdc); this table is registered
;; there at load, beside the OpenVTC layer's own.
(register-claim-indexes! *claim-index-registry*)


;; =========================================================================
;; Timestamp-claim registry
;; =========================================================================
;;
;; Different schemas carry their observation time under different claim
;; keys. This registry lets the ACDC store answer timestamp-range
;; queries (needed to build rolling-window time-series over any
;; credential schema — e.g. S_t for a plan's tally-result stream,
;; or I_t for an external-index oracle's observations).
;;
;; Schemas not listed fall back to the 'timestamp claim, which is the
;; convention used by stance / expression-stance / work-event.

(define *timestamp-claim-registry*
  `((,*schema-playnet-stance*                . timestamp)
    (,*schema-playnet-expression-stance*           . timestamp)
    (,*schema-playnet-work-event*            . timestamp)
    (,*schema-playnet-tally-result*          . closed-at)
    (,*schema-playnet-ballot-snapshot*       . opened-at)
    (,*schema-playnet-ccf-assessment*        . assessed-at)
    (,*schema-playnet-exclusion*             . excluded-at)
    (,*schema-playnet-federation-membership* . admitted-at)
    (,*schema-playnet-membership*            . admitted-at)
    (,*schema-playnet-federation-sturdyref*  . registered-at)
    (,*schema-playnet-federation-census*     . told-at)
    (,*schema-playnet-scope-merger*          . merged-at)
    (,*schema-playnet-scope-split*           . split-at)
    (,*schema-playnet-scope-rejoin*          . rejoined-at)
    (,*schema-playnet-conflict-resolution*   . resolved-at)
    (,*schema-playnet-agreement*             . accepted-at)
    (,*schema-playnet-external-index-observation* . observed-at)
    (,*schema-playnet-personhood*                . enrolled-at)
    (,*schema-playnet-relationship*              . issued-at)
    (,*schema-playnet-contrary-observation*      . observed-at)
    (,*schema-playnet-recomposition-ratification* . ratified-at)
    (,*schema-playnet-witness-assignment*    . assigned-at)))

;; timestamp-claim-for / parse-time-value / cred-timestamp live in (playnet keri
;; acdc); this table is registered there at load, beside the OpenVTC layer's own.
(register-timestamp-claims! *timestamp-claim-registry*)


;; =========================================================================
;; Deterministic SAID — Blake3-256 of canonical content, CESR "E" code
;; =========================================================================
;;
;; KERI SAIDs are Blake3-256 digests CESR-encoded under code "E" (44
;; qb64 chars). `signify.scm` uses libblake3 for real KERI events; the
;; governance layer uses the same hash through `(playnet keri blake3)`
;; so that credentials issued by ^acdc-store and by a real KERIA
;; backend share a hash function — a foreign KERI verifier can check
;; either without knowing where it came from.
;;
;; libblake3.so is loaded lazily: `(playnet governance)` loads even
;; when the FFI library isn't present, but actually computing a SAID
;; requires the library. Tests run via `make test-governance`, which
;; enters a guix shell that includes the `blake3` package.

;; canonical-string / said-sort-pairs / compute-said now live in
;; (playnet keri said-portable) — imported by governance.scm and re-exported —
;; so the BROWSER derives byte-identical SAIDs. A citizen's KERI key is
;; client-side, so a citizen-issued ACDC can only be a conformant ACDC if the
;; citizen's own controller signs it; to sign without blind-signing, the client
;; must re-derive the SAID from the claims itself. Behaviour here is unchanged
;; (same canonicalization, same lazy-FFI blake3 default).

(define* (compute-plan-said scope-aid intent-ids #:optional (extra-claims '()))
  "Content-addressed plan-id: SAID over the scope-aid + the sorted
   intent set. Same intent set under the same scope produces the same
   SAID (convergence); any change to the intent membership produces
   a different SAID (no silent amendment of confirmed plans).

   EXTRA-CLAIMS lets callers fold in additional content (plan name,
   horizon, etc.) — anything in EXTRA-CLAIMS becomes part of the
   identity. Pass '() for the canonical \"plan = its intents\" form.

   Intent ordering is normalized via string<? sort so the same set
   produces the same SAID regardless of insertion order. The result
   is a CESR qb64 SAID (44 chars, prefix 'E'), drop-in usable
   anywhere a plan-id string is expected."
  (compute-said scope-aid scope-aid 'playnet-plan-v1
                `((intents . ,(sort intent-ids string<?))
                  ,@extra-claims)))



(define (cred-signed-by-scope cred scope-ref)
  "Provenance-sign CRED via SCOPE-REF's own `sign-said`. THE one primitive for
   'a credential signed by a scope you hold a reference to' — as opposed to the
   raw-keypair `#:signing-keypair` path, which is for signing INSIDE a scope
   actor where the keypair is in closure (you can't re-entrantly call your own
   sign-said in Goblins). Absorbs the guard: no-op when SCOPE-REF is #f or has
   no keypair (synthetic / test / degraded mode), so no call site repeats the
   check. Keypair never leaves the actor."
  (if (and scope-ref ($ scope-ref 'has-keypair?))
      (cred-with-signature cred ($ scope-ref 'sign-said (cred-said cred)))
      cred))



;; =========================================================================
;; Schema-specific constructors
;;
;; TWO DISCIPLINES every constructor here lives under, both SAID-load-
;; bearing (a SAID commits to the exact claims alist — #f entries
;; included, key order excluded; said-portable.scm):
;;
;;   1. EMISSION IS FROZEN. Most constructors emit every claim
;;      unconditionally, #f values included. Changing any existing
;;      field's emission (e.g. "cleaning up" #f fields to
;;      emit-when-set) silently re-SAIDs every credential ever minted
;;      by that constructor — durable stores then hold the old SAID, a
;;      re-mint gets a new one, and issue-idempotent duplicates instead
;;      of deduping. NEW fields are the one safe extension: append-only,
;;      emitted ONLY when set, so every prior credential keeps its SAID
;;      (the custody-attestation `kind` claim set the pattern;
;;      commitment's `resource-inventoried-as`/`triggered-by` follow it).
;;
;;   2. `(iso-utc-now)` DEFAULTS DEFEAT IDEMPOTENT RE-MINTING. Several
;;      constructors default a SAID-material timestamp to now — every
;;      call with the default is a fresh SAID, so "re-attesting the
;;      same fact" duplicates rather than dedups. A caller re-minting
;;      an existing fact MUST pass the fact's own timestamp explicitly
;;      (as acdc-bridge's attest-* and cast-signed already do).
;; =========================================================================

(define* (make-delegation-credential issuer-aid holder-aid franchise
                                     fraction mandate-spec
                                     #:key (mandate-text #f) (at #f))
  "Delegation: issuer (citizen) authorizes holder (delegate) to receive
   FRACTION of issuer's voice in FRANCHISE, optionally constrained by
   MANDATE-SPEC.

   franchise: 'federation OR (list 'scope SCOPE-ID-STRING)
   fraction:  rational/real in (0, 1]
   mandate-spec: #f (liquid) OR a spec — see compile-mandate-spec.
   mandate-text: optional human-readable gloss explaining the mandate
                 in plain language. Per democracy-on-keri.md §4.4: the
                 machine predicate (`mandate-spec`) drives tally-time
                 enforcement; the text travels alongside in the same
                 ACDC's claims so a recipient or auditor reading the
                 credential sees both forms — closer to the spirit of
                 ACDC's rule section + `l` (Legal Language) field
                 without yet introducing a separate rule block."
  (make-credential *schema-playnet-delegation*
                   issuer-aid
                   holder-aid
                   ;; AT (append-only, emit-when-set — SAID-stable for every
                   ;; delegation minted before it existed): the write's own
                   ;; timestamp. Without it the SAID was fully determined by
                   ;; (delegator, delegate, franchise, fraction, mandate), so
                   ;; RETURNING to a previously-used fraction rebuilt a SAID
                   ;; the supersede path had already revoked — the issue
                   ;; crashed the whole delegation write, and recovery's
                   ;; replay (non-revoked only) would have dropped the
                   ;; restored state even if it hadn't.
                   (let ((base (list (cons 'franchise    franchise)
                                     (cons 'fraction     fraction)
                                     (cons 'mandate      mandate-spec)
                                     (cons 'mandate-text mandate-text))))
                     (if at (append base (list (cons 'at at))) base))))

(define* (make-ccf-credential issuer-group-aid holder-aid commune
                              ccf assessed-at reason
                              #:key (signing-keypair #f) (multisig-signers #f))
  "Capacity assessment by a commune's governance group, for a citizen.
   The latest non-revoked CCF credential per (commune, holder) wins at
   recovery time."
  (make-credential *schema-playnet-ccf-assessment*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'ccf         ccf)
                         (cons 'assessed-at assessed-at)
                         (cons 'reason      reason))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-exclusion-credential issuer-group-aid holder-aid commune
                                    excluded-at
                                    #:key (signing-keypair #f) (multisig-signers #f))
  "Exclusion of a citizen from a commune. Revocation = reinstatement."
  (make-credential *schema-playnet-exclusion*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'excluded-at excluded-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-federation-membership-credential issuer-group-aid
                                                 commune-aid
                                                 federation
                                                 commune-id
                                                 admitted-at
                                                 #:key (edges '())
                                                 (signing-keypair #f) (multisig-signers #f))
  "Federation admits a commune as a member.
   EDGES: optional extra ACDC edges (used by Phase-6 recomposition
   ratification to attach a 'ratification edge to this credential)."
  (make-credential *schema-playnet-federation-membership*
                   issuer-group-aid
                   commune-aid
                   (list (cons 'federation  federation)
                         (cons 'commune-id  commune-id)
                         (cons 'admitted-at admitted-at))
                   edges
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-membership-credential issuer-group-aid holder-aid commune
                                     admitted-at
                                     #:key (signing-keypair #f) (multisig-signers #f))
  "Citizen is recognized as a member of commune. Issued on first account
   creation (work credit or CCF assessment)."
  (make-credential *schema-playnet-membership*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'admitted-at admitted-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))


(define* (make-bran-share-credential issuer-group-aid holder-aid
                                     share-index threshold total-shares
                                     share-data-hex
                                     #:key (subject-aid #f)
                                     (signing-keypair #f) (multisig-signers #f))
  "Shamir bran share: issuer = governance group, holder = member.
   share-data-hex is the hex-encoded share bytevector.

   SUBJECT-AID identifies which scope's bran this share is for. When
   #f (legacy bootstrap shares for the maintainer-governance bran),
   the claim is omitted. For autonomous-signer scope keys, it MUST be
   supplied so multiple scopes' shares don't collide in one store
   (see bran-custody.scm).

   SIGNING-KEYPAIR/MULTISIG-SIGNERS: the issuing governance group's own
   signature over this share — the same key material a share, once
   reconstituted, would let someone impersonate, so an unsigned share
   ACDC is a strictly weaker integrity guarantee than the credentials
   issued right alongside it in a bootstrap ceremony. #f leaves it
   unsigned (synthetic/test mode)."
  (let ((claims-base (list (cons 'share-index  share-index)
                           (cons 'threshold    threshold)
                           (cons 'total-shares total-shares)
                           (cons 'share-data   share-data-hex))))
    (make-credential *schema-playnet-bran-share*
                     issuer-group-aid
                     holder-aid
                     (if subject-aid
                         (append claims-base
                                 (list (cons 'subject-aid subject-aid)))
                         claims-base)
                     '()
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-federation-sturdyref-credential issuer-group-aid commune-aid
                                               commune-id sturdyref-uri
                                               netlayer registered-at
                                               #:key (signing-keypair #f) (multisig-signers #f))
  "Sturdyref for a remote commune in a federation: how it is reached. Enables
   recovery by re-resolving the sturdyref via mycapn enliven. The goods that
   cross are not said here: the commune tells what it deals in with its own
   census (`make-federation-census-credential`) and the roster is what at
   least two members deal in. The `crosses` claim is still emitted, empty — a
   constructor's emission is frozen, a SAID commits to it."
  (make-credential *schema-playnet-federation-sturdyref*
                   issuer-group-aid
                   commune-aid
                   (list (cons 'commune-id     commune-id)
                         (cons 'sturdyref-uri  sturdyref-uri)
                         (cons 'netlayer       netlayer)
                         (cons 'registered-at  registered-at)
                         (cons 'crosses        '()))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-federation-census-credential commune-aid federation-aid goods told-at
                                            #:key (kel #f) (units '()) (signing-keypair #f) (multisig-signers #f))
  "What a commune deals in, told to its federation: GOODS, the spec ids its
   records hold, make, consume and ask for (planner/federation/crossing-set.scm
   `commune-goods`). Issued by the COMMUNE — its records are its own to read —
   and held by the federation; the commune signs it. A good at least two
   members tell crosses between them. KEL, when the commune's key has rotated,
   is its key event log: the AID alone no longer says which key signed, and the
   log, inside what the SAID commits to, does. UNITS, ((good . unit) …), are the
   units the commune counts those goods in (their specifications' own): the
   federation's record of a crossing counts in the same."
  (make-credential *schema-playnet-federation-census*
                   commune-aid
                   federation-aid
                   (append (list (cons 'goods   (sort goods string<?))
                                 (cons 'told-at told-at))
                           (if (pair? units) (list (cons 'units (map (lambda (u) (list (car u) (cdr u))) units))) '())
                           (if kel (list (cons 'kel kel)) '()))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))



(define* (make-stance-credential citizen-aid governance-group-aid
                                 domain proposal-id position timestamp
                                 #:key (ballot-snapshot-said #f)
                                       (u 'auto))
  "Citizen's vote on a ballot proposal — KERI-signed, durable. DOMAIN
   tags the ballot kind ('policy, 'recomposition, …) so
   downstream consumers can filter without re-deriving from proposal-id.

   When BALLOT-SNAPSHOT-SAID is supplied, an `e`-block edge with NI2I
   operator is added pointing to the snapshot ACDC. This is the §4.9
   migration: SAID-claim references become formal ACDC edges so a
   verifier walking the property graph can resolve in either direction.
   The `proposal-id` claim is retained for backwards compatibility."
  (let ((edges (if ballot-snapshot-said
                   (list (cons 'ballot-snapshot
                               (make-edge ballot-snapshot-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-ballot-snapshot*)))
                   '())))
    ;; issuer = the CITIZEN (a vote is the citizen's own assertion);
    ;; issuee = the recording governance scope, the counter-party that tallies
    ;; it. A targeted ACDC with a real Target AID (ACDC §7.6).
    ;;
    ;; The citizen's KERI key is client-side, so this is only a *conformant*
    ;; ACDC when the client signs it — see `stance-signing-preimage` and the
    ;; signature-verifying `cast` path in service.scm. An unsigned stance is
    ;; honestly just an unsigned assertion; the orientation stays
    ;; citizen-issued either way so there is ONE shape, and recovery reads the
    ;; caster from the issuer.
    ;; U is the blinding nonce. Generated here when absent, but the
    ;; client-signed path MUST pass the one it signed over: `cast-signed`
    ;; rebuilds this credential to check the signature, and a fresh nonce
    ;; would change the SAID and fail every signature. It rides back from
    ;; the client in the echoed claims, exactly as `timestamp` does.
    (make-credential *schema-playnet-stance*
                     citizen-aid governance-group-aid
                     (append
                      (u-claim u)
                      (list (cons 'domain      domain)
                            (cons 'proposal-id proposal-id)
                            (cons 'position    position)
                            (cons 'timestamp   timestamp)))
                     edges)))

(define* (make-expression-stance-credential citizen-aid governance-group-aid
                                            domain expression-id distribution
                                            timestamp
                                            #:key (u 'auto))
  "Citizen's distribution across targets in an expression. DOMAIN tags what
   the targets are (e.g. 'plan, 'demand, 'resource, 'proposal-relevance).
   Same labor-proportional voice mechanism, any per-scope per-domain
   question. Issuer = the citizen (their own assertion); issuee = the
   recording scope (see make-stance-credential's note on signing).

   U: blinding nonce — see make-stance-credential. A distribution has a
   larger claim space than a position, but it is still enumerable for
   small target sets, so it gets the same treatment."
  (make-credential *schema-playnet-expression-stance*
                   citizen-aid governance-group-aid
                   (append
                    (u-claim u)
                    (list (cons 'domain        domain)
                          (cons 'expression-id expression-id)
                          (cons 'distribution  distribution)
                          (cons 'timestamp     timestamp)))))

(define* (make-ballot-snapshot-credential governance-group-aid
                                           domain proposal-id franchise
                                           snapshot-said opened-at
                                           #:key
                                           (description #f)
                                           (voice-snapshot-entries '())
                                           (citizen-registry-aids '()))
  "Governance group anchors the frozen voice-share weights at ballot open.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).
   voice-snapshot-entries: list of (citizen-id voice-share resolved-delegation)
                           where resolved-delegation is a list of
                           (delegate-aid fraction mandate-spec-or-#f).
                           Enough to reconstruct the ballot.
   citizen-registry-aids: list of citizen AIDs known to this ballot."
  (make-credential *schema-playnet-ballot-snapshot*
                   governance-group-aid governance-group-aid
                   (list (cons 'domain               domain)
                         (cons 'proposal-id           proposal-id)
                         (cons 'franchise             franchise)
                         (cons 'snapshot-said         snapshot-said)
                         (cons 'opened-at             opened-at)
                         (cons 'description           description)
                         (cons 'voice-snapshot-entries voice-snapshot-entries)
                         (cons 'citizen-registry-aids citizen-registry-aids))))

(define* (make-tally-result-credential governance-group-aid
                                       domain proposal-id franchise
                                       winner tally-data
                                       abstain-weight closed-at
                                       #:key (ballot-snapshot-said #f))
  "Governance group signs the final ballot decision — auditable proof.
   DOMAIN tags the ballot kind ('policy, 'recomposition, …).

   Per §4.9 migration: BALLOT-SNAPSHOT-SAID, when supplied, becomes an
   `e`-block NI2I edge so verifiers can walk tally → snapshot directly.
   The `proposal-id` claim is retained for backwards compatibility."
  (let ((edges (if ballot-snapshot-said
                   (list (cons 'ballot-snapshot
                               (make-edge ballot-snapshot-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-ballot-snapshot*)))
                   '())))
    (make-credential *schema-playnet-tally-result*
                     governance-group-aid governance-group-aid
                     (list (cons 'domain         domain)
                           (cons 'proposal-id    proposal-id)
                           (cons 'franchise      franchise)
                           (cons 'winner         winner)
                           (cons 'tally-data     tally-data)
                           (cons 'abstain-weight abstain-weight)
                           (cons 'closed-at      closed-at))
                     edges)))

(define* (make-work-event-credential scope-aid worker-aid
                                     event-id hours unit
                                     #:key (scope-id #f) (process-id #f)
                                           (timestamp #f)
                                           (resource-conforms-to #f)
                                           (fulfills #f)
                                           (satisfies #f)
                                           (skill-said #f)
                                           ;; the trust floor: k-of-n WITNESSES on the
                                           ;; event itself, so the evidence layer the
                                           ;; recipe metabolism reads is not one scope's
                                           ;; word (multisig block; cred-multisig-valid?)
                                           (multisig-signers #f))
  "Work event ACDC: scope governance witnesses worker's labor.
   Issuer = scope-aid, holder = worker-aid.
   fulfills:  optional commitment SAID this event fulfills (planning).
   satisfies: optional intent SAID this event satisfies (validation —
              §III.1 anchors credit on recipient-side satisfaction).
   skill-said: optional SAID of the skill ACDC this work exercises — every
              work event after the founding one edges to its skill, so the
              skill's whole history (earned-skills / practiced-hours / credit)
              is a single offline-walkable graph, not a server-side index.

   When supplied, FULFILLS / SATISFIES / SKILL-SAID are emitted as `e`-block
   NI2I edges (named 'fulfills / 'satisfies / 'skill) so verifiers can walk the
   property graph natively. Claim values are retained for back-compat."
  (let ((edges
         (append
          (if fulfills
              (list (cons 'fulfills
                          (make-edge fulfills
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-commitment*)))
              '())
          (if satisfies
              (list (cons 'satisfies
                          (make-edge satisfies
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-intent*)))
              '())
          (if skill-said
              (list (cons 'skill
                          (make-edge skill-said
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-skill*)))
              '()))))
    (make-credential *schema-playnet-work-event*
                     scope-aid worker-aid
                     (list (cons 'event-id            event-id)
                           (cons 'hours               hours)
                           (cons 'unit                unit)
                           (cons 'scope-id            scope-id)
                           (cons 'process-id          process-id)
                           (cons 'timestamp           timestamp)
                           (cons 'resource-conforms-to resource-conforms-to)
                           (cons 'fulfills            fulfills)
                           (cons 'satisfies           satisfies))
                     edges
                     #:multisig-signers multisig-signers)))

(define* (make-observation-event-credential scope-aid holder-aid event-id action
                                            #:key (qty #f) (unit #f) (scope-id #f)
                                                  (resource-conforms-to #f)
                                                  (at-location #f) (to-location #f)
                                                  (timestamp #f) (fulfills #f)
                                                  (evidence #f))
  "Observation event ACDC: scope governance witnesses an occurrence the
   ledger folded — ONE shape for every quantified observational action
   (produce / consume / use / move / raise / lower / pickup / dropoff /
   deliver-service), the material half of the evidence layer beside
   work-event's labour half and claim-event's draw half.
   Issuer = scope-aid; holder = the agent observed acting.
   FULFILLS, when present, edges to the commitment the event discharges
   (NI2I, like work-event's), so verifiers walk the confirmation mile as a
   property graph. Both ends of a move ride the claims, so the journey the
   routing table learned from is reconstructable offline.
   EVIDENCE, when present, is the sha256 of the picture a photo read was made
   from; the claim is appended only when set, so every record that names no
   picture keeps the SAID it always had."
  (make-credential *schema-playnet-observation-event*
                   scope-aid holder-aid
                   (append
                    (list (cons 'event-id             event-id)
                          (cons 'action               action)
                          (cons 'qty                  qty)
                          (cons 'unit                 unit)
                          (cons 'scope-id             scope-id)
                          (cons 'resource-conforms-to resource-conforms-to)
                          (cons 'at-location          at-location)
                          (cons 'to-location          to-location)
                          (cons 'timestamp            timestamp)
                          (cons 'fulfills             fulfills))
                    (if evidence (list (cons 'evidence evidence)) '()))
                   (if fulfills
                       (list (cons 'fulfills
                                   (make-edge fulfills
                                              #:operator 'NI2I
                                              #:schema *schema-playnet-commitment*)))
                       '())))

(define* (make-scope-merger-credential predecessor-a-aid predecessor-b-aid
                                        new-scope-aid kind merged-at
                                        #:key (edges '()) (predecessors #f)
                                        (signing-keypair #f) (multisig-signers #f))
  "Scopes merge into a new combined scope.

   Two-way (legacy): supply PREDECESSOR-A-AID and PREDECESSOR-B-AID
   positionally; claims carry `predecessor-a` and `predecessor-b`.

   N-way: pass `#:predecessors '(aid1 aid2 aid3 …)`. Claims carry a
   single `predecessors` list instead. Backwards-compatible — existing
   2-way callers remain unchanged.

   issuer = predecessor-a (or first of #:predecessors); holder = new-scope-aid.
   EDGES: optional extra ACDC edges (ratification, stale-membership)."
  (let* ((effective-issuer
          (or (and (pair? predecessors) (car predecessors))
              predecessor-a-aid))
         (claims
          (cond
           (predecessors
            (list (cons 'predecessors  predecessors)
                  (cons 'new-scope-aid new-scope-aid)
                  (cons 'kind          kind)
                  (cons 'merged-at     merged-at)))
           (else
            (list (cons 'predecessor-a predecessor-a-aid)
                  (cons 'predecessor-b predecessor-b-aid)
                  (cons 'new-scope-aid new-scope-aid)
                  (cons 'kind          kind)
                  (cons 'merged-at     merged-at))))))
    (make-credential *schema-playnet-scope-merger*
                     effective-issuer new-scope-aid
                     claims
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-scope-split-credential parent-scope-aid sub-scope-aids
                                       kind split-at
                                       #:key (edges '())
                                       (signing-keypair #f) (multisig-signers #f))
  "One scope partitions into N sub-scopes.
   issuer = parent; holder = parent (self-attested split event).
   sub-scope-aids: list of new sub-scope AIDs.
   EDGES: optional extra ACDC edges (Phase-6 ratification, etc.)."
  (make-credential *schema-playnet-scope-split*
                   parent-scope-aid parent-scope-aid
                   (list (cons 'parent-scope-aid parent-scope-aid)
                         (cons 'sub-scope-aids   sub-scope-aids)
                         (cons 'kind             kind)
                         (cons 'split-at         split-at))
                   edges
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-conflict-resolution-credential meta-scope-aid
                                              resource-id
                                              conflicting-commitments
                                              prevailing-commitment
                                              resolution-method
                                              resolved-at
                                              #:key (signing-keypair #f) (multisig-signers #f))
  "Meta-scope (federation) records resolution of overlapping commitments
   on RESOURCE-ID. conflicting-commitments: list of commitment-SAIDs.
   prevailing-commitment: SAID that wins (#f for split/mediation).
   resolution-method: symbol — 'fifo / 'priority / 'mediation / 'split / etc."
  (make-credential *schema-playnet-conflict-resolution*
                   meta-scope-aid meta-scope-aid
                   (list (cons 'resource-id             resource-id)
                         (cons 'conflicting-commitments conflicting-commitments)
                         (cons 'prevailing-commitment   prevailing-commitment)
                         (cons 'resolution-method       resolution-method)
                         (cons 'resolved-at             resolved-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-scope-rejoin-credential scope-aid old-federation-aid
                                        new-federation-aid rejoined-at
                                        #:key (edges '())
                                        (signing-keypair #f) (multisig-signers #f))
  "Scope changes its parent federation.
   issuer = scope-aid; holder = scope-aid (self-attested move).
   Old federation also revokes membership ACDC; new issues fresh one.
   EDGES: optional extra ACDC edges (Phase-6 ratification, etc.)."
  (make-credential *schema-playnet-scope-rejoin*
                   scope-aid scope-aid
                   (list (cons 'scope-aid          scope-aid)
                         (cons 'old-federation-aid old-federation-aid)
                         (cons 'new-federation-aid new-federation-aid)
                         (cons 'rejoined-at        rejoined-at))
                   edges
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))


(define* (make-commitment-credential provider-aid receiver-aid
                                      commitment-id action
                                      #:key (resource-conforms-to #f)
                                            (resource-classified-as '())
                                            (resource-quantity #f)
                                            (effort-quantity #f)
                                            (due #f) (plan-id #f)
                                            (process-id #f) (satisfies #f)
                                            (resource-inventoried-as #f)
                                            (triggered-by #f)
                                            (signing-keypair #f))
  "Commitment ACDC: provider promises to receiver.
   Issuer = provider, holder = receiver.
   resource-quantity, effort-quantity: pairs (qty . unit) or #f.
   satisfies: optional intent SAID this commitment satisfies.

   resource-inventoried-as: optional id of the EXACT EconomicResource this
   commitment moves (VF resourceInventoriedAs) — names WHICH one when the
   spec alone is ambiguous. A purchase-claim uses it to say which purse or
   balance actually paid, turning accept-reimbursement's funding-source
   check from a spec-wide heuristic into a direct read.

   triggered-by: optional SAID of the credential this one arises FROM —
   the VF `triggeredBy` relation (docs/valueflows examples, \"Claim for
   income\": a real past event entitles a reciprocal obligation, settled
   later; no Agreement, which VF reserves for connecting reciprocal
   PROMISES). governance/scope.scm's accept-reimbursement uses it: the
   commune's debt is triggered by the member's own signed purchase-claim,
   and that link is the whole binding.

   The first ten claims are emitted unconditionally, #f values included —
   exactly as this constructor always has, so every existing commitment
   credential keeps the SAID it was minted with. Only the two NEW fields
   are emitted when set, the same append-only SAID discipline the
   custody-attestation's kind claim established.

   signing-keypair: optional — the provider's Ed25519 keypair, so the promise
   carries its maker's signature (a scope signs its own commitment)."
  (make-credential *schema-playnet-commitment*
                   provider-aid receiver-aid
                   (let* ((base (list (cons 'commitment-id        commitment-id)
                                      (cons 'action               action)
                                      (cons 'resource-conforms-to resource-conforms-to)
                                      (cons 'resource-classified-as resource-classified-as)
                                      (cons 'resource-quantity    resource-quantity)
                                      (cons 'effort-quantity      effort-quantity)
                                      (cons 'due                  due)
                                      (cons 'plan-id              plan-id)
                                      (cons 'process-id           process-id)
                                      (cons 'satisfies            satisfies)))
                          (cl (if resource-inventoried-as
                                  (append base (list (cons 'resource-inventoried-as
                                                           resource-inventoried-as)))
                                  base))
                          (cl (if triggered-by
                                  (append cl (list (cons 'triggered-by triggered-by)))
                                  cl)))
                     cl)
                   '() #:signing-keypair signing-keypair))

(define* (make-redistribution-mandate-credential
          federation-aid scope-aid threshold-spec recipient-policy
          #:key (period "monthly") (effective-from #f)
          (signing-keypair #f) (multisig-signers #f))
  "Redistribution mandate ACDC: FEDERATION-AID requires SCOPE-AID
   (a member) to redistribute surplus above THRESHOLD-SPEC, with
   destination chosen by RECIPIENT-POLICY.

   Issuer = federation (the body imposing the mandate).
   Holder  = member scope (the party bound by it).
   SIGNING-KEYPAIR attaches the federation's issuer signature (the party
   imposing the mandate). A member counter-signature (acceptance of the
   obligation) is the eventual bilateral model — pass MULTISIG-SIGNERS
   then. (No production issuer wires this yet — see the acdc-signing
   audit; the earlier docstring claimed a signature the constructor had
   no parameter to store.)

   THRESHOLD-SPEC is a symbolic form, e.g.
     (surplus-above (qty 100 \"kg\") spec:grain)
     (idle-capacity-above (hours 40))
     (custody-of-spec-above spec:widget 500)

   RECIPIENT-POLICY is symbolic:
     federation-pool
     (equal-share to-leaves)
     (need-weighted to-leaves)

   PERIOD: a string like \"monthly\" / \"quarterly\" / \"weekly\";
   informational — the auditor uses it to decide how often to check."
  (make-credential *schema-playnet-redistribution-mandate*
                   federation-aid scope-aid
                   (list (cons 'federation-aid    federation-aid)
                         (cons 'scope-aid         scope-aid)
                         (cons 'threshold-spec    threshold-spec)
                         (cons 'recipient-policy  recipient-policy)
                         (cons 'period            period)
                         (cons 'effective-from    (or effective-from
                                                       (iso-utc-now))))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))


(define* (make-recomposition-ratification-credential
          scope-aid proposal-type proposal-spec
          ballot-said tally
          #:key (threshold 0.5)
                (threshold-met? #t)
                (ratified-at #f)
                (signing-keypair #f)
                (issuer-aid #f)
                (predecessors #f)
                (successor-spec #f))
  "Recomposition-ratification ACDC. Records that a labor-proportional
   ballot passed for a structural proposal.

   PROPOSAL-TYPE: 'admit-commune | 'merge-with | 'split |
                  'rejoin-federation
   PROPOSAL-SPEC: canonical equal?-comparable form (see scope.scm)
   BALLOT-SAID:   SAID of the closed ballot-snapshot ACDC anchoring
                  the labor-proportional voice computation.
   TALLY:         alist (yes . w) (no . w) (abstain . w) at close.
   THRESHOLD:     voice fraction needed (default 0.5 = simple majority).
   THRESHOLD-MET?: pre-checked at issuance; consumed by validators.

   Two issuance shapes (per democracy-on-keri.md §4.3):

   1. **Self-issued** (legacy): omit ISSUER-AID. Issuer = holder =
      SCOPE-AID. Used by tests and the pre-bottom-up flow. The
      ratification post-records the ballot's outcome on the affected
      scope's TEL.

   2. **Parent-issued** (bottom-up): supply ISSUER-AID = parent
      federation AID (or Universal Commune for federation-root
      recompositions), PREDECESSORS = list of pre-existing scope AIDs
      involved (e.g. (A B) for a merge), and SUCCESSOR-SPEC = alist
      describing the new scope to-be-incepted (e.g. ((kind . commune)
      (name . \"AB\") (members . (...)))). The ratification SAID is
      then sealed as an anchor in the new scope's inception event.
      Predates the successor's existence.

   Either shape carries an NI2I edge to the ballot-snapshot."
  (let* ((effective-issuer (or issuer-aid scope-aid))
         (claims-base (list (cons 'scope-aid       scope-aid)
                            (cons 'proposal-type   proposal-type)
                            (cons 'proposal-spec   proposal-spec)
                            (cons 'ballot-said     ballot-said)
                            (cons 'tally           tally)
                            (cons 'threshold       threshold)
                            (cons 'threshold-met?  threshold-met?)
                            (cons 'ratified-at     (or ratified-at
                                                        (iso-utc-now)))))
         (claims (cond
                  ((and predecessors successor-spec)
                   (append claims-base
                           (list (cons 'predecessors   predecessors)
                                 (cons 'successor-spec successor-spec))))
                  (predecessors
                   (append claims-base
                           (list (cons 'predecessors predecessors))))
                  (successor-spec
                   (append claims-base
                           (list (cons 'successor-spec successor-spec))))
                  (else claims-base)))
         (edges
          (list (cons 'ballot-snapshot
                      (make-edge ballot-said
                                 #:operator 'NI2I
                                 #:schema *schema-playnet-ballot-snapshot*)))))
    (make-credential *schema-playnet-recomposition-ratification*
                     effective-issuer effective-issuer
                     claims
                     edges
                     #:signing-keypair signing-keypair)))


(define* (make-commitment-fulfillment-credential
          receiver-aid provider-aid commitment-said
          #:key (fulfilled-at #f) (note #f))
  "Commitment-fulfillment ACDC issued by the RECEIVER of a commitment
   to the PROVIDER, marking that commitment as satisfied.

   This replaces the unilateral `(cred-claim c 'finished)` flag for
   purposes of the custody-transfer validator: a commitment is
   'finished' iff a non-revoked fulfillment ACDC referencing its
   SAID exists. A captured provider can no longer mark its own
   commitments finished to escape the orphan check.

   Issuer = receiver (the party attesting that the obligation was met).
   Holder = provider. Carries the commitment SAID as an edge."
  (let ((edges
         (list (cons 'fulfills
                     (make-edge commitment-said
                                #:operator 'NI2I
                                #:schema *schema-playnet-commitment*)))))
    (make-credential *schema-playnet-commitment-fulfillment*
                     receiver-aid provider-aid
                     (list (cons 'commitment-said commitment-said)
                           (cons 'fulfilled-at   (or fulfilled-at
                                                      (iso-utc-now)))
                           (cons 'note           note))
                     edges)))


(define* (make-custody-attestation-credential
          issuing-authority-aid custodian-aid resource-spec qty
          #:key (valid-from #f) (valid-until #f) (supersedes #f)
          (movable #f) (return-to #f) (condition-floor #f) (resource #f)
          (qty-unit #f) (kind #f) (ref #f) (eligible #f)
          (signing-keypair #f) (multisig-signers #f))
  "Custody-attestation ACDC: ISSUING-AUTHORITY-AID attests that
   CUSTODIAN-AID is the current steward of QTY of RESOURCE-SPEC.

   KIND: what the custodian may DO with the thing. Absent (every grant so
   far) it is a USE grant — the custodian engages the thing and returns it
   whole. \"consume\" is a CONSUME grant: the custodian may SPEND up to QTY of
   the holding (money, fuel, seed) within the window; what is unspent at
   the window's close is the owner's again. Emitted as a claim only when
   given, so every use-grant keeps the SAID it always had.

   Issuer = issuing authority (federation, commons body, or scope itself
   for genesis self-attestation). Holder = custodian.

   valid-from / valid-until: optional timestamps (epoch seconds or ISO);
   #f means open-ended. An attestation whose valid-until is in the past
   is treated as revoked by observers.

   MOVABLE: whether this custody grant permits the custodian to RELOCATE
   the thing (default #f = keep in place — used where it sits).

   RETURN-TO / CONDITION-FLOOR: reciprocal CARE terms the custodian owes on
   return — a place the thing must come back to (for a movable grant) and a
   minimum condition it must come back in. (Return-BY is `valid-until`;
   the per-period capacity ceiling is `qty`; both are structural.)

   QTY-UNIT: what QTY is measured in. A capacity ceiling is a RATE — `8 hours a
   day` of a workshop — and a rate means nothing until it says per what, so the
   unit carries the denominator as one quotient — hours/day — see utils/units.scm.
   Absent, the solve reads the unit off the granted resource's own measure, which
   is the right default for a grant of everything a thing can render. Optional and
   therefore SAID-stable: a grant that omits it keeps the SAID it always had.

   RESOURCE: optional id of the exact EconomicResource this grant is over
   (resourceInventoriedAs) — names WHICH one when the owner holds several of a
   spec; when absent the subject is the owner's resource of RESOURCE-SPEC.

   ELIGIBLE: optional steward rule — a filter-rule expression (see
   matching/filter-rule.scm) carried verbatim as the JSON string the grantor
   signed. Bounds who may be ASSIGNED to work drawing on this grant; the
   commune's capacity is otherwise anonymous. Evaluated fail-closed at the
   assignment doors, never inside the LP.

   Every optional field is emitted as a claim only when set, so an
   attestation that uses none of them keeps the exact SAID it had before.

   SUPERSEDES: optional SAID of a prior custody-attestation this one
   replaces. Adds an I2I edge so the chain is attestable. Note the actual
   ACDC §8.6 I2I rule: issuee(target) == issuer(this) — i.e. the party
   issuing the superseding attestation must be the one the PRIOR
   attestation named as custodian (its issuee), not merely the prior's
   issuer. That is the meaningful constraint here: only the current
   custodian can hand custody on. It holds for both flows, since a
   scope's custody chain is self-attested (issuer == issuee == scope)
   before any transfer."
  (let ((edges (if supersedes
                   (list (cons 'supersedes
                               (make-edge supersedes
                                          #:operator 'I2I
                                          #:schema *schema-playnet-custody-attestation*)))
                   '())))
    (make-credential *schema-playnet-custody-attestation*
                     issuing-authority-aid custodian-aid
                     (let* ((base (list (cons 'custodian-aid  custodian-aid)
                                        (cons 'resource-spec resource-spec)
                                        (cons 'qty           qty)
                                        (cons 'valid-from    valid-from)
                                        (cons 'valid-until   valid-until)
                                        (cons 'issued-by     issuing-authority-aid)))
                            ;; optional grant metadata — each emitted only when set, so
                            ;; a grant that uses none keeps the exact SAID it had before
                            (cl base)
                            (cl (if movable         (cons (cons 'movable movable) cl) cl))
                            (cl (if return-to       (cons (cons 'return-to return-to) cl) cl))
                            (cl (if condition-floor (cons (cons 'condition-floor condition-floor) cl) cl))
                            (cl (if resource        (cons (cons 'resource-id resource) cl) cl))
                            (cl (if qty-unit        (cons (cons 'qty-unit qty-unit) cl) cl))
                            (cl (if kind            (cons (cons 'kind kind) cl) cl))
                            ;; REF (append-only, emit-when-set — SAID-stable
                            ;; for every grant minted before it existed): a
                            ;; caller nonce distinguishing two same-termed
                            ;; grants. Without it, recall-then-relend with
                            ;; identical terms rebuilt the identical SAID,
                            ;; and the revoked copy swallowed the re-issue —
                            ;; the wire answered 'ok while the grant stayed
                            ;; dead. Revocation stays append-only on purpose
                            ;; (the old signature verifies forever, so
                            ;; un-revoke-on-reissue would let anyone replay a
                            ;; recalled grant back to life); a fresh ref is
                            ;; the correct way to lend again.
                            (cl (if ref             (cons (cons 'ref ref) cl) cl))
                            ;; ELIGIBLE (append-only, emit-when-set — SAID-stable
                            ;; for every grant minted before it existed): the
                            ;; owner's steward rule, a filter-rule expression
                            ;; (matching/filter-rule.scm) carried as the verbatim
                            ;; JSON string the grantor signed. It bounds WHO may
                            ;; be assigned to work drawing on this grant, the way
                            ;; mandate-spec bounds a delegate's ballot — and like
                            ;; every filter-rule it fails CLOSED: a clause the
                            ;; evaluator does not know denies.
                            (cl (if eligible        (cons (cons 'eligible eligible) cl) cl)))
                       cl)
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

(define* (make-ownership-attestation-credential
          owner-aid resource-id resource-spec
          #:key (kind "declared") (holder #f) (valid-from #f) (valid-until #f)
          (qty #f) (qty-unit #f) (ref #f) (supersedes #f) (stake #f)
          (signing-keypair #f) (multisig-signers #f))
  "Ownership-attestation ACDC: the TITLE claim behind a declared means,
   as a first-class credential. Custody's sibling on the other side of
   the rights/custody split: custody says who stewards a thing now,
   this says whose claim on its congealed labour stands
   (docs/common-property.typ).

   KIND \"declared\" is a self-assertion: issuer = holder = the owner.
   Self-issuance is the honest form of what declare-means already does —
   the signature makes the claim non-repudiable, revocable, and a
   subject others can attest or contest; it does not make it TRUE, which
   is what the auditor's ownership-coherence check and, later, the
   governed passage exist for. A future passage lands as KIND
   \"passage\": a superseding attestation whose issuer is the old owner
   and whose holder is the receiving scope — title moving as a chain,
   exactly custody-transfer's shape.

   QTY/QTY-UNIT: optional — the resource's own measure is the default
   truth, and a standing title stores no derived quantities (the skill
   credential's discipline). EMISSION, precisely (it is SAID-load-bearing):
   `valid-from` and `kind` are emitted UNCONDITIONALLY — #f and the
   \"declared\" default included — exactly as this constructor always has;
   only `valid-until`/`qty`/`qty-unit` are emitted when set. Do not
   \"align\" valid-from with valid-until: making it conditional would
   silently re-SAID every existing bare title (a #f entry in the claims
   alist IS SAID material — said-portable.scm).

   SUPERSEDES: SAID of the prior ownership attestation this replaces
   (I2I — only the titled owner passes title on). STAKE: SAID of an
   auditor's SNLT stake attestation (NI2I) — the ℓ_own⁰ edge the
   governed-passage design names; reserved, unused today."
  (let* ((edges '())
         (edges (if stake
                    (cons (cons 'stake (make-edge stake #:operator 'NI2I))
                          edges)
                    edges))
         (edges (if supersedes
                    (cons (cons 'supersedes
                                (make-edge supersedes
                                           #:operator 'I2I
                                           #:schema *schema-playnet-ownership-attestation*))
                          edges)
                    edges)))
    (make-credential *schema-playnet-ownership-attestation*
                     owner-aid (or holder owner-aid)   ; passage names the scope
                     ;; base emits valid-from/kind unconditionally (#f and
                     ;; default included) — historical, and therefore frozen:
                     ;; see the docstring's EMISSION note before touching this
                     (let* ((base (list (cons 'resource-id   resource-id)
                                        (cons 'resource-spec resource-spec)
                                        (cons 'kind          kind)
                                        (cons 'valid-from    valid-from)
                                        (cons 'issued-by     owner-aid)))
                            (cl base)
                            (cl (if valid-until (cons (cons 'valid-until valid-until) cl) cl))
                            (cl (if qty         (cons (cons 'qty qty) cl) cl))
                            (cl (if qty-unit    (cons (cons 'qty-unit qty-unit) cl) cl))
                            ;; REF (append-only, emit-when-set): the caller
                            ;; nonce that lets a disowned title be asserted
                            ;; anew — identical terms rebuilt the identical
                            ;; SAID, the revoked copy swallowed the re-issue,
                            ;; and title-permits? then locked the owner out
                            ;; of their own resource forever
                            (cl (if ref         (cons (cons 'ref ref) cl) cl)))
                       cl)
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))

;; A scope speaking only for itself: issuer = holder = the scope, no edges, a
;; window, revocable on its own TEL with no counterparty. The shape span
;; declarations and hosting willingness share — each adds only its claims.
(define* (%make-scope-self-declaration schema scope-aid claims
          #:key (valid-from #f) (valid-until #f)
          (signing-keypair #f) (multisig-signers #f))
  (make-credential schema scope-aid scope-aid
                   (append claims
                           (list (cons 'valid-from  valid-from)
                                 (cons 'valid-until valid-until)
                                 (cons 'issued-by   scope-aid)))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-span-declaration-credential
          scope-aid resource-id span-place
          #:key (valid-from #f) (valid-until #f)
          (signing-keypair #f) (multisig-signers #f))
  "Span-declaration ACDC: SCOPE-AID (the means' steward) declares that
   RESOURCE-ID's service pool is constituted at SPAN-PLACE — the container
   whose cells the pool spans, wider or narrower than where the thing sits.

   Issuer = holder = the steward scope: the declaration is the scope's own
   governed act, revocable on its own TEL like any grant (no counterparty).
   valid-from / valid-until bound the window; expiry reverts the pool to the
   holding place with no further event, the same live-read discipline as
   custody (`custody-cred-live?` gates it).

   The claim references a place; it never IS one. The resource's location
   and the spatial tree stay untouched — this is the declaration half of
   'span is governed, location is fact'."
  (%make-scope-self-declaration *schema-playnet-span-declaration* scope-aid
                                (list (cons 'resource-id resource-id)
                                      (cons 'span-place  span-place))
                                #:valid-from valid-from #:valid-until valid-until
                                #:signing-keypair signing-keypair
                                #:multisig-signers multisig-signers))

(define* (make-hosting-willingness-credential
          scope-aid resource-spec ceiling
          #:key (valid-from #f) (valid-until #f)
          (signing-keypair #f) (multisig-signers #f))
  "Hosting-willingness ACDC: SCOPE-AID declares it is willing and able to host
   up to CEILING unit-hours/day of RESOURCE-SPEC's service — running and
   maintaining it included. The labour availability pattern over means: what a
   scope did not offer cannot be placed in it, and the ceiling is the most it
   ever hosts, not a request for that much.

   Issuer = holder = the hosting scope: its own consent, on its own TEL,
   revocable with no counterparty (revocation is the grantor's, always) —
   exactly the span declaration's shape, because both are a scope speaking
   only for itself (`%make-scope-self-declaration`)."
  (%make-scope-self-declaration *schema-playnet-hosting-willingness* scope-aid
                                (list (cons 'resource-spec resource-spec)
                                      (cons 'ceiling       ceiling))
                                #:valid-from valid-from #:valid-until valid-until
                                #:signing-keypair signing-keypair
                                #:multisig-signers multisig-signers))

(define* (make-regime-claim-credential
          scope-aid domain-spec tails process
          #:key (valid-from #f) (valid-until #f)
          (signing-keypair #f) (multisig-signers #f))
  "Regime-claim ACDC: SCOPE-AID attests DOMAIN-SPEC's epistemic regime —
   TAILS ∈ thin|fat|unknown, PROCESS ∈ stable|shifting|unknown. Statistics is
   licensed only by thin AND stable, both live; everything else, ignorance
   included, reads probability-free (the asymmetry of the error demands the
   dangerous default). Who may credibly claim a domain's tails is policy above
   this layer — witness it k-of-n exactly as work events are."
  (%make-scope-self-declaration *schema-playnet-regime-claim* scope-aid
                                (list (cons 'domain-spec domain-spec)
                                      (cons 'tails       tails)
                                      (cons 'process     process))
                                #:valid-from valid-from #:valid-until valid-until
                                #:signing-keypair signing-keypair
                                #:multisig-signers multisig-signers))

(define* (make-contrary-observation-credential observer-aid scope-id process action spec
                                                nominal reading witness observed-at
                                                #:key (signing-keypair #f))
  "Contrary-observation ACDC: OBSERVER-AID, who ran PROCESS in SCOPE-ID, read
   ACTION on SPEC at READING where the map states NOMINAL; WITNESS is the id
   of the work event the reading came from. Issuer = holder = the observer:
   a constative statement in their own name, signed with their own key,
   revocable by them alone. One live statement per (observer, scope,
   process, action) — a restatement supersedes (governance/service.scm). Who
   may speak — the worker the witness names — is a fact the service reads
   off the observer; what the solve makes of it is planner/solve/engine/robust.scm
   observed-shocks: the read moves in the cautious direction only."
  (make-credential *schema-playnet-contrary-observation*
                   observer-aid observer-aid
                   (list (cons 'scope-id    scope-id)
                         (cons 'process     process)
                         (cons 'action      (if (symbol? action) (symbol->string action) action))
                         (cons 'spec        spec)
                         (cons 'nominal     nominal)
                         (cons 'reading     reading)
                         (cons 'witness     witness)
                         (cons 'observed-at observed-at))
                   '()
                   #:signing-keypair signing-keypair))

(define* (make-skill-credential
          issuing-aid worker-aid skill founding-event-said
          #:key (valid-from #f) (valid-until #f))
  "Skill membership ACDC: ISSUING-AID attests that WORKER-AID holds SKILL,
   minted ONCE per (worker, skill) on the first work event conforming to it.

   Issuer = the witnessing scope (or a training authority that produced the
   skill — just *who* issued it, never a 'certification' flag). Holder =
   worker. There is no hours field: accumulated competence is DERIVED from
   the worker's work-event log (observer `practiced-hours`), so this token
   never drifts and a retroactively-voided work simply drops from the sum.

   FOUNDING-EVENT-SAID: the work-event ACDC SAID this skill was first earned
   on. Added as an NI2I edge so the skill's provenance is attestable; the
   later works that exercise the skill are the derived index, not edges here.

   valid-from / valid-until: optional (epoch or ISO); #f = open-ended. A
   skill whose valid-until is past is treated as lapsed by observers — the
   same live/expiry convention as custody attestations (so `*-cred-live?`
   transfers), the structural home for recertification-style decay."
  (let ((edges (if founding-event-said
                   (list (cons 'founding-event
                               (make-edge founding-event-said
                                          #:operator 'NI2I
                                          #:schema *schema-playnet-work-event*)))
                   '())))
    (make-credential *schema-playnet-skill*
                     issuing-aid worker-aid
                     (list (cons 'skill              skill)
                           (cons 'founding-event-id  founding-event-said)
                           (cons 'valid-from         valid-from)
                           (cons 'valid-until        valid-until)
                           (cons 'issued-by          issuing-aid))
                     edges)))

(define* (make-claim-event-credential
          scope-aid claimant-aid event-id labor-cost unit
          #:key (resource-spec #f) (qty #f) (timestamp #f) (settles #f))
  "Claim-event ACDC: the consumption mirror of the work-event ACDC. CLAIMANT-AID
   draws LABOR-COST hours of earned credit to receive RESOURCE-SPEC. Issuer =
   scope, holder = claimant. No balance lives on the token — credit is DERIVED:
   gross (work-event ACDCs) − claimed (these). When SETTLES is a <claim> SAID,
   an NI2I edge records which planning-layer claim this draw settles."
  (let ((edges (if settles
                   (list (cons 'settles (make-edge settles #:operator 'NI2I #:schema #f)))
                   '())))
    (make-credential *schema-playnet-claim*
                     scope-aid claimant-aid
                     (list (cons 'event-id      event-id)
                           (cons 'claimant      claimant-aid)
                           (cons 'labor-cost    labor-cost)
                           (cons 'unit          unit)
                           (cons 'resource-spec resource-spec)
                           (cons 'qty           qty)
                           (cons 'timestamp     timestamp)
                           (cons 'settles       settles))
                     edges)))

(define* (make-custody-transfer-commitment-credential
          from-scope-aid to-scope-aid resource-spec qty
          new-attestation-said revoked-attestation-said
          #:key (carries-commitments '()) (effective-at #f)
          (signing-keypair #f) (multisig-signers #f))
  "Custody-transfer commitment ACDC: FROM-SCOPE-AID commits to transfer
   custody of QTY RESOURCE-SPEC to TO-SCOPE-AID.

   Issuer = from-scope (relinquishing custody). Holder = to-scope
   (inheriting). SIGNING-KEYPAIR signs the from-scope's own side (the
   relinquishing commitment). A full bilateral co-signature (to-scope
   counter-signs its acceptance) is the eventual model — pass
   MULTISIG-SIGNERS or add a receiver-fulfillment ACDC then; for now the
   from-scope's single issuer signature is what's attached, not the
   \"both sign\" the earlier docstring wrongly claimed.

   NEW-ATTESTATION-SAID: SAID of the freshly-issued custody-attestation
   for the receiving scope.
   REVOKED-ATTESTATION-SAID: SAID of the predecessor attestation being
   superseded.

   CARRIES-COMMITMENTS: list of prior commitment SAIDs that travel with
   the inventory. The protocol layer rejects a transfer that orphans
   outstanding commitments against the resource — an empty list is the
   explicit \"no obligations follow\" assertion, not a default."
  (let* ((carry-edges
          (map (lambda (i said)
                 (cons (string->symbol (format #f "carries-commitment-~a" i))
                       (make-edge said
                                  #:operator 'NI2I
                                  #:schema *schema-playnet-commitment*)))
               (iota (length carries-commitments))
               carries-commitments))
         (attestation-edges
          ;; NI2I, not I2I. I2I (ACDC §8.6) requires issuee(target) ==
          ;; issuer(this). Here issuer(this) is FROM-SCOPE while the new
          ;; attestation's issuee is TO-SCOPE — different by construction, since
          ;; the whole point is a transfer. The I2I constraint could therefore
          ;; never hold; NI2I ("no issuer/issuee constraint") is the correct
          ;; operator, matching the sibling revoked-attestation edge.
          (list (cons 'new-attestation
                      (make-edge new-attestation-said
                                 #:operator 'NI2I
                                 #:schema *schema-playnet-custody-attestation*))
                (cons 'revoked-attestation
                      (make-edge revoked-attestation-said
                                 #:operator 'NI2I
                                 #:schema *schema-playnet-custody-attestation*))))
         (edges (append attestation-edges carry-edges)))
    (make-credential *schema-playnet-custody-transfer-commitment*
                     from-scope-aid to-scope-aid
                     (list (cons 'from-scope-aid       from-scope-aid)
                           (cons 'to-scope-aid         to-scope-aid)
                           (cons 'resource-spec        resource-spec)
                           (cons 'qty                  qty)
                           (cons 'new-attestation      new-attestation-said)
                           (cons 'revoked-attestation  revoked-attestation-said)
                           (cons 'effective-at         effective-at))
                     edges
                     #:signing-keypair signing-keypair
                     #:multisig-signers multisig-signers)))


;; Recognition of a plan or an intent at a federation level is the observer's
;; own rail (observation/observer.scm confirm-plan / recognize-intent): the
;; validation maps every credit and voice read gates on. It is a fact about
;; the scope's own record and needs no credential of its own.


(define* (make-agreement-credential acceptor-aid proposer-aid
                                     agreement-id
                                     #:key (proposal-id #f)
                                           (primary-commitment-ids '())
                                           (reciprocal-commitment-ids '())
                                           (counterparty-provider #f)
                                           (counterparty-receiver #f)
                                           (accepted-at #f)
                                           (signing-keypair #f))
  "Agreement ACDC: ACCEPTOR-AID has accepted PROPOSER-AID's proposal.
   Issuer = acceptor (the party taking on the commitments).
   Holder = proposer (the party whose proposal was accepted).
   Claims anchor the proposal, the agreement record, its primary and
   reciprocal commitment IDs, the counterparty roles used during
   promotion, and the acceptance timestamp.
   signing-keypair: optional — the acceptor's keypair, so the acceptance
   carries the acceptor's signature (a scope signs its own consent)."
  (make-credential *schema-playnet-agreement*
                   acceptor-aid proposer-aid
                   (list (cons 'agreement-id             agreement-id)
                         (cons 'proposal-id              proposal-id)
                         (cons 'primary-commitment-ids   primary-commitment-ids)
                         (cons 'reciprocal-commitment-ids reciprocal-commitment-ids)
                         (cons 'counterparty-provider    counterparty-provider)
                         (cons 'counterparty-receiver    counterparty-receiver)
                         (cons 'accepted-at              accepted-at))
                   '() #:signing-keypair signing-keypair))

(define* (make-external-index-observation-credential
          oracle-aid index-uri observed-value observed-at
          #:key (holder-aid #f) (source-note #f)
          (signing-keypair #f) (multisig-signers #f))
  "External index observation ACDC: an oracle records a scalar reading
   of an external data stream at a timestamp.

   index-uri:     string identifying the external source (e.g.
                  \"market:slabs-aaa-abx\", \"fred:gdp-us\").
   observed-value: number.
   observed-at:   epoch seconds (number) or ISO-8601 string.
   source-note:   optional provenance string.

   Issuer = oracle-aid; holder defaults to oracle-aid unless specified
   (e.g. federated dashboards may hold externally-issued observations)."
  (make-credential *schema-playnet-external-index-observation*
                   oracle-aid
                   (or holder-aid oracle-aid)
                   (list (cons 'index-uri      index-uri)
                         (cons 'observed-value observed-value)
                         (cons 'observed-at    observed-at)
                         (cons 'source-note    source-note))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))


(define* (make-intent-credential issuer-aid intent-id action
                                  #:key (provider #f) (receiver #f)
                                        (resource-conforms-to #f)
                                        (resource-classified-as '())
                                        (resource-quantity #f)
                                        (effort-quantity #f)
                                        (available-quantity #f)
                                        (minimum-quantity #f)
                                        (due #f) (plan-id #f)
                                        (process-id #f)
                                        (satisfies #f)
                                        (holder-aid #f))
  "Intent ACDC: unilateral signal — provider XOR receiver.
   Issuer = the agent declaring the intent (provider OR receiver).
   Holder = governance-group-aid (or scope-aid) by default — the
   federation/commune that hosts the intent for discovery.
   resource-quantity / effort-quantity: pairs (qty . unit) or #f.
   satisfies: optional parent intent ID this refines."
  (when (and provider receiver)
    (error "VF constraint: intent has provider XOR receiver, not both"
           intent-id))
  (make-credential *schema-playnet-intent*
                   issuer-aid
                   (or holder-aid issuer-aid)
                   (list (cons 'intent-id           intent-id)
                         (cons 'action              action)
                         (cons 'provider            provider)
                         (cons 'receiver            receiver)
                         (cons 'resource-conforms-to resource-conforms-to)
                         (cons 'resource-classified-as resource-classified-as)
                         (cons 'resource-quantity   resource-quantity)
                         (cons 'effort-quantity     effort-quantity)
                         (cons 'available-quantity  available-quantity)
                         (cons 'minimum-quantity    minimum-quantity)
                         (cons 'due                 due)
                         (cons 'plan-id             plan-id)
                         (cons 'process-id          process-id)
                         (cons 'satisfies           satisfies))))




;; =========================================================================
;; Phase-1 hardening: audit + reversion credentials
;; =========================================================================


(define* (make-audit-pass-credential auditor-aid federation-aid
                                      #:key (audited-at #f) (cycle #f)
                                            (signing-keypair #f))
  "Heartbeat credential issued when the federation tree passes
   federation-tree-coherent?.

   UNTARGETED (ACDC §7.5): issuer only, no issuee. This is an
   observation the issuer publishes — 'addressed to whom it may
   concern' — not an authorization directed at a target AID that the
   target would present. The spec's own example for this shape is an
   observer that controls an AID publishing verifiable non-repudiable
   measurements. The subject rides in the `federation-aid` claim, so
   nothing is lost by having no issuee.

   SIGNING-KEYPAIR (Ed25519, matching AUDITOR-AID's KERI prefix)
   attaches a CESR signature for KERI portability; bare-data
   deployment passes #f."
  (make-credential *schema-playnet-audit-pass*
                   auditor-aid #f
                   (list (cons 'federation-aid federation-aid)
                         (cons 'audited-at     (or audited-at (iso-utc-now)))
                         (cons 'cycle          cycle))
                   '()
                   #:signing-keypair signing-keypair))

(define* (make-incoherence-alert-credential auditor-aid federation-aid
                                             violations
                                             #:key (audited-at #f)
                                                   (cycle #f)
                                                   (signing-keypair #f))
  "Issued when federation-tree-coherent? returns #f. VIOLATIONS is an
   alist of invariant → offending entities.

   UNTARGETED (ACDC §7.5), like make-audit-pass-credential — a
   published observation, not an authorization aimed at an issuee. The
   subject rides in the `federation-aid` claim.

   SIGNING-KEYPAIR optional, see make-audit-pass-credential."
  (make-credential *schema-playnet-incoherence-alert*
                   auditor-aid #f
                   (list (cons 'federation-aid federation-aid)
                         (cons 'audited-at     (or audited-at (iso-utc-now)))
                         (cons 'cycle          cycle)
                         (cons 'violations     violations))
                   '()
                   #:signing-keypair signing-keypair))

(define* (make-reversion-attestation-credential
          authority-aid default-custodian-aid
          resource-spec qty expired-attestation-said
          #:key (effective-at #f) (signing-keypair #f))
  "Issued by the half-life watcher when a custody-attestation expires
   without renewal. Credits a configured DEFAULT-CUSTODIAN; carries a
   `reverted-from` edge to the expired SAID. SIGNING-KEYPAIR optional
   for KERI portability."
  (let ((edges
         (list (cons 'reverted-from
                     (make-edge expired-attestation-said
                                #:operator 'NI2I
                                #:schema
                                *schema-playnet-custody-attestation*)))))
    (make-credential *schema-playnet-reversion-attestation*
                     authority-aid default-custodian-aid
                     (list (cons 'custodian-aid       default-custodian-aid)
                           (cons 'resource-spec      resource-spec)
                           (cons 'qty                qty)
                           (cons 'valid-from         (or effective-at
                                                          (iso-utc-now)))
                           (cons 'valid-until        #f)
                           (cons 'issued-by          authority-aid)
                           (cons 'reverted-from-said expired-attestation-said))
                     edges
                     #:signing-keypair signing-keypair)))


(define* (make-derived-state-snapshot-credential
          auditor-aid scope-aid snapshot-data
          #:key (input-saids '())
                (snapshot-at #f)
                (signing-keypair #f))
  "Auditor-issued snapshot of derived state (voice shares, P_extract,
   credit balances, …) for SCOPE-AID, computed from the inputs whose
   SAIDs are in INPUT-SAIDS.

   SNAPSHOT-DATA is SAID material and must be built of readable forms —
   atoms, pairs, alists, vectors. A live hashmap or record here now
   errors loudly at mint time (canonical-string's unrenderable-object
   guard, said-portable.scm) instead of silently hashing the host
   printer's truncated rendering; fold to a key-sorted alist first.

   The snapshot's authenticity comes from (1) the auditor's signature
   and (2) the NI2I edges to every input — a verifier can recompute the
   derived state from the listed inputs and confirm it matches.

   Per democracy-on-keri.md §4.5: this answers \"how do you authenticate
   live derived numbers?\" without re-signing them on every read. The
   inputs (work-event, audit-pass, …) keep their immutable signatures;
   the snapshot is a periodic crystallization with provenance edges."
  (let ((edges
         (let loop ((saids input-saids) (i 1) (acc '()))
           (cond
            ((null? saids) (reverse acc))
            (else
             (let ((label (string->symbol
                           (string-append "input-"
                                          (number->string i)))))
               (loop (cdr saids) (+ i 1)
                     (cons (cons label
                                 (make-edge (car saids)
                                            #:operator 'NI2I
                                            #:schema #f))
                           acc))))))))
    ;; UNTARGETED (ACDC §7.5): a published measurement of derived state, not an
    ;; authorization aimed at an issuee. Both the observer and the subject ride
    ;; in claims (auditor-aid / scope-aid), so no issuee is needed.
    (make-credential *schema-playnet-derived-state-snapshot*
                     auditor-aid #f
                     (list (cons 'auditor-aid    auditor-aid)
                           (cons 'scope-aid      scope-aid)
                           (cons 'snapshot      snapshot-data)
                           (cons 'snapshot-at   (or snapshot-at
                                                     (iso-utc-now)))
                           (cons 'input-count   (length input-saids)))
                     edges
                     #:signing-keypair signing-keypair)))


;; =========================================================================
;; Mandate-spec DSL ↔ predicate
;; =========================================================================

(define (compile-mandate-spec spec)
  "Compile a mandate-spec into a predicate (cleartext-stance → bool).
   Returns #f for opaque or unrecognized specs (recovers as liquid).

   Recognized specs:
     (equal-position SYMBOL)
     (any-of-position (SYMBOL ...))
     (min-distribution PLAN-ID FRACTION)
     opaque    → #f"
  (cond
    ((eq? spec 'opaque) #f)
    ((not (pair? spec)) #f)
    (else
     (case (car spec)
       ((equal-position)
        (let ((target (cadr spec)))
          (lambda (stance) (eq? (caddr stance) target))))
       ((any-of-position)
        (let ((targets (cadr spec)))
          (lambda (stance) (and (memq (caddr stance) targets) #t))))
       ((min-distribution)
        (let ((target-id (cadr spec))
              (min-frac  (caddr spec)))
          (lambda (stance)
            ;; cleartext for expression: (expression DOMAIN EID dist citizen-id keri-aid)
            ;; dist is a hashmap target-id → fraction
            (let ((dist (cadddr stance)))
              (>= (hashmap-ref dist target-id 0) min-frac)))))
       (else #f)))))

(define (mandate-spec-of pred)
  "Best-effort introspection of a mandate predicate. Returns 'opaque
   for predicates we can't recognize. To make a predicate recognizable,
   construct it via the DSL — i.e. callers should keep the spec around
   and use compile-mandate-spec, not arbitrary lambdas.

   Phase-1 limitation: we don't introspect lambda bodies. The signal
   to use the DSL: callers who care about ACDC round-trip should pass
   an additional `:mandate-spec` to delegate-mandated alongside the
   predicate. (In Phase-2 we may invert: callers pass only the spec,
   actor compiles it.)

   For now: return 'opaque if we don't have a registered association."
  (or (predicate->spec pred)
      'opaque))

(define *predicate-spec-registry* (make-hash-table))

(define (register-mandate-predicate pred spec)
  "Associate a predicate with its spec so mandate-spec-of can recover it."
  (hash-set! *predicate-spec-registry* pred spec)
  pred)

(define (predicate->spec pred)
  (hash-ref *predicate-spec-registry* pred #f))

(define (mandate spec)
  "Convenience: compile a spec and register the resulting predicate so
   mandate-spec-of can later recover the spec for ACDC issuance.

   Use:  ($ delegation-map 'delegate-mandated D F (mandate '(equal-position yes)))"
  (let ((pred (compile-mandate-spec spec)))
    (when pred
      (register-mandate-predicate pred spec))
    pred))


;; =========================================================================
;; Witness assignment — federation-member operation of KERI witnesses
;; =========================================================================
;;
;; Issued by a federation's governance group AID to a member AID,
;; attesting that the member runs a specific KERIA witness identified
;; by its AID + OOBI. The bootstrap helper in (playnet keri witnesses-
;; federation) reads these credentials to resolve OOBIs into the
;; local KERIA agent. The auditor walks them to check that the toad-
;; many witnesses are operated by distinct members.
;;
;; Sharing a witness across federations is per-federation issuance:
;; each federation that wants the witness in its quorum issues its
;; own assignment. KERI witnesses aren't federation-aware — the
;; cleanest model is the truthful one. See
;; docs/governance/FEDERATION-WITNESSES.md.
;;
;; Claims:
;;   witness-aid   string  — the witness's KERIA AID
;;   witness-oobi  string  — resolvable OOBI URL
;;   group-aid     string  — federation's group AID this witness serves
;;   assigned-at   integer — epoch seconds (timestamp claim)

(define* (make-witness-assignment-credential federation-aid member-aid
                                              witness-aid witness-oobi
                                              group-aid assigned-at
                                              #:key (signing-keypair #f))
  "Federation-issued attestation that MEMBER-AID runs the KERIA witness
   identified by WITNESS-AID + WITNESS-OOBI on behalf of GROUP-AID.
   FEDERATION-AID is the issuer; MEMBER-AID is the holder."
  (make-credential *schema-playnet-witness-assignment*
                   federation-aid member-aid
                   (list (cons 'witness-aid  witness-aid)
                         (cons 'witness-oobi witness-oobi)
                         (cons 'group-aid    group-aid)
                         (cons 'assigned-at  assigned-at))
                   '()
                   #:signing-keypair signing-keypair))

(define (witness-assignments-for-federation federation-aid all-creds)
  "Filter ALL-CREDS down to the non-revoked witness-assignment
   credentials issued by FEDERATION-AID. Each federation maintains
   its own assignment set; cross-federation reuse is achieved by each
   federation issuing its own assignment to the same operator for
   the same witness AID — the operator runs one witness, multiple
   federations independently attest to it. See
   docs/governance/FEDERATION-WITNESSES.md § *Sharing witnesses
   across federations*."
  (filter (lambda (c)
            (and (equal? (cred-schema c) *schema-playnet-witness-assignment*)
                 (equal? (cred-issuer c) federation-aid)
                 (not (cred-revoked? c))))
          all-creds))

(define (count-witness-attestors federation-aid all-creds)
  "Number of distinct members holding non-revoked witness-assignment
   credentials from FEDERATION-AID. Use as a governance dashboard
   pre-check — \"have we issued enough assignments to even attempt
   quorum?\" — separate from the cryptographic
   audit-witness-quorum-independence below."
  (length (delete-duplicates
           (map cred-holder
                (witness-assignments-for-federation federation-aid all-creds)))))

(define (audit-witness-quorum-independence federation-aid toad all-creds
                                           kel-witness-aids)
  "Return #t iff the witnesses ACTUALLY in FEDERATION-AID's group KEL
   `b` list (per KERI spec Table 4) map — via the federation's own
   witness-assignment ACDCs — to ≥TOAD distinct operating members.

   The truthful security predicate. Only KEL backers receipt; off-KEL
   assignments don't count (they're metadata without a receipt slot),
   so we intersect the assignments with the live backer set before
   counting distinct operators.

   Set-on-holder semantics: a member running multiple witnesses still
   counts as one operator — we care about operator coercion, not
   witness count.

   KEL-WITNESS-AIDS is required and not optional: the caller must
   query KERIA for the federation's group AID state and pass its
   `b` field. This forces every audit call to consult the live KEL
   rather than silently degrading into a credential-only check.
   For the cheap dashboard 'have we issued enough?' question, use
   `count-witness-attestors` instead.

   TOAD is typically `(keri-toad-for-count N)` where N is the
   federation's KEL backer count (Table 4 field `bt`)."
  (let* ((assignments
          (witness-assignments-for-federation federation-aid all-creds))
         (active
          (filter (lambda (c)
                    (member (cred-claim c 'witness-aid) kel-witness-aids))
                  assignments))
         (distinct-operators
          (delete-duplicates (map cred-holder active))))
    (>= (length distinct-operators) toad)))
