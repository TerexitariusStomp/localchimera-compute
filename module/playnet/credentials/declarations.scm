;;; credentials/declarations.scm — what a scope says of itself: span, hosting willingness, regime claim, and the generic self-declaration.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6). A constructor returns the ACDC bundle as an alist — said, schema, issuer,
;;; holder, claims, edges, revoked? — with its SAID computed over the whole; the
;;; edge block follows ACDC §8 (`make-edge` in (playnet keri acdc)).

(define-module (playnet credentials declarations)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
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
  #:export (*schema-playnet-hosting-willingness*
            *schema-playnet-regime-claim*
            *schema-playnet-span-declaration*
            %make-scope-self-declaration
            make-hosting-willingness-credential
            make-regime-claim-credential
            make-span-declaration-credential))
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
