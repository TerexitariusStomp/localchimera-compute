;;; socialization.scm — Temporary socialization of private property
;;;
;;; An owner may TEMPORARILY place a privately-held resource into a commune's
;;; shared `use`-pool for a bounded window, WITHOUT giving up ownership — the
;;; apple-press / library-book pattern of ValueFlows §Transfers ("loaning a
;;; resource to another agent"), and the usufruct-not-title custody of
;;; `docs/social-means.typ` ("a moving assignment that expires rather than
;;; vesting").
;;;
;;; The subject is PRIVATE property in the precise sense — privately-held MEANS OF
;;; PRODUCTION (a workshop, a machine, land), not merely PERSONAL property
;;; (consumption goods). That is the politically meaningful case and the whole
;;; point of "The Means in Common": bringing privately-held means into common USE
;;; without taking TITLE from its holder — the reversible, transitional form of
;;; socialization. The mechanism is identical for a personal item; what differs is
;;; that a socialized productive means enters the plan as a `use`-CAPACITY subject
;;; to the whole means-in-common apparatus (egalitarian scheduling, wear,
;;; maintenance, reproduction), where a personal item merely sits in the pool.
;;;
;;; This is NOT a sale. It never touches rights:
;;;   • custody (onhand / holder)  → moves to the commune for the window
;;;   • rights  (accounting / primaryAccountable) → stay with the owner, untouched
;;; and it uses NO transfer-all-rights and NO medium-of-exchange. The mechanism is
;;; a custody-attestation ACDC (governance.credentials): the OWNER issues it,
;;; crediting the COMMUNE as custodian, with `valid-until` = the return-by. The
;;; attestation's window IS the socialization window — `custody-cred-live?` (live
;;; planner) already time-filters it, so a socialized durable enters the commune's
;;; plan only while its grant is live and drops out when the window lapses.
;;;
;;; Two exit paths, symmetric to how delegation and custody already expire/revert:
;;;   • ACTIVE (owner recalls early): `desocialize-private-resource!` — the
;;;     delegator-owned revocation pattern (governance.delegation-map): the owner
;;;     revokes their OWN grant on their own TEL. No recall ceremony, no
;;;     counterparty consent (revocation is the grantor's, always — see the
;;;     `no-recall-ceremony` design note).
;;;   • PASSIVE (window lapses): the existing `^custody-half-life-watcher`
;;;     (governance.auditor) reverts custody at `valid-until`. Wire it with
;;;     `socialization-owner-reverter` so custody returns to the granting owner,
;;;     not a commons pool.
;;;
;;; Containment: socializing a container socializes its contents (an apartment
;;; carries its oven) — `commune-socialized-caps` walks `contained-in`, with a
;;; positive RETENTION the opt-out. See its docstring.
;;;
;;; Consent is BILATERAL: the owner grants (`socialize-private-resource`,
;;; owner-signed) and, when there are care terms, the commune accepts via its own
;;; gov-cap-gated, scope-signed `accept-socialization` ^scope method (scope.scm) —
;;; neither party forges the other's side (see the note below). These helpers are
;;; the credential half; `commune-socialized-caps` derives the per-window `Svc|spec` capacity into
;;; the commune's solve, and `project-socialized-custody` derives the durable's
;;; `custodian-scope = commune` — ALL of it a per-solve VIEW of the live grants,
;;; nothing stored, nothing reverted (a lapsed grant simply stops projecting). The
;;; grant is the single source of truth; capacity, mobility, care, and custody are
;;; each read off it fresh each solve — so there is no field to keep in sync. The
;;; planner stays governance-agnostic: `plan-scope` takes a `#:resource-view`
;;; transform and the caller supplies the projection.
;;;
;;; Included fragment — imports come from (playnet governance). Must follow
;;; credentials.scm (make-custody-attestation-credential) and acdc-store.scm.

;; ── The custody-attestation builder — the ONE place args become the grant ────
;; The pure builder (no store): both socialization paths mint the credential here,
;; so the arg→claim mapping lives once. The gateway's CLIENT-signed flow
;; (governance-service socialize-preimage / socialize-signed) calls it with neither
;; FROM nor SIGNING-KEYPAIR: valid-from stays OPEN (#f) and the copy stays unsigned,
;; so the SAID is fully determined by the visible args — nothing server-volatile to
;; echo across the sign round-trip, and the client signs it. `socialize-private-
;; resource` (server-signed) passes FROM = now and its keypair. Empty strings
;; normalize to #f so optional claims stay omitted (SAID-stable), and #f fields are
;; emitted as no claim at all — so the two paths agree bit-for-bit where they share
;; args.
(define-module (playnet governance socialization)
  #:use-module (playnet planner formulas flows)
  #:use-module ((playnet planner formulas actions) #:select (labour-specs))
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils keywords) #:select (kw-without kw-ref))
  #:use-module (playnet governance credentials)
  #:use-module (playnet governance demand-fold)
  #:use-module (playnet planner aggregation containment)
  #:use-module (playnet keri acdc)
  #:use-module (playnet planner formulas capacity)
  #:use-module (playnet planner facts validity)
  #:use-module (playnet planner observation account)
  #:use-module (playnet planner observation observer)
  #:use-module (playnet planner formulas capacity)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet planner observation account) #:select (set-person-substrate!))
  #:use-module ((playnet openvtc first-person) #:select (holds-any-live-phc? personhood-bootstrapped?))
  #:use-module ((playnet planner solve engine) #:select (key-spec       ; "spec#place@t" → spec, the one split
                                                   declared-partition set-period-span!))   ; the standing partition, laid before the caps
  #:use-module (playnet planner scope live)
  #:use-module (playnet planner aggregation scope-tree)
  #:use-module ((playnet planner matching filter-rule)
                #:select (rule-passes? context criteria-json->alist criteria-ref))
  #:use-module ((playnet social lens) #:select (contact-aid contact-rel))
  #:use-module ((playnet social relationship-kinds) #:select (normalize-rel))
  #:use-module (ice-9 receive)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (ownership-credential ownership-ok? title-permits?
            %live-ownership-attestations withdraw-title! revoke-own-credential!
            socialization-credential grant-consume? grant-kind-claim socialize-private-resource
            desocialize-private-resource! socialization-owner-reverter %live-by-schema
            %live-custody-attestations %live-commune-grants member-consume-grant-total member-consume-grant-over %grant-over?
            %resource-resolver %socialization-place-of %add-caps %sum-facts
            %socialized-selector commune-socialized-caps project-socialized-custody
            commune-resource-view labour-specs-of verb-specs-of %scope-subtree-resources
            federation-resource-resolver
            plan-commune-scope %slots-with-draw
            commune-world commune-demand commune-stamp socialized-readers title-rights-of lent-to
            commune-socialized-slots
            socialization-care-terms %ne? socialization-care-demand
            socialization-care-breaches commune-care-breaches %live-span-decls
            live-span-of live-willingness-of consented-span-of
            grant-steward-rule commune-steward-rules make-may-steward make-knows vrc-groups-of))

(define* (socialization-credential owner-aid commune-aid resource-spec qty
                                   #:key (until #f) (from #f) (movable? #f)
                                         (return-to #f) (condition-floor #f)
                                         (resource #f) (qty-unit #f)
                                         (kind #f) (ref #f) (eligible #f)
                                         (signing-keypair #f))
  (define (ne s) (if (and (string? s) (string-null? s)) #f s))
  (make-custody-attestation-credential
   owner-aid commune-aid resource-spec qty
   #:valid-from (ne from) #:valid-until (ne until) #:movable (and movable? #t)
   #:return-to (ne return-to) #:condition-floor (ne condition-floor)
   #:resource (ne resource) #:qty-unit (ne qty-unit)
   #:kind (grant-kind-claim kind)
   #:ref (ne ref)
   #:eligible (ne eligible)
   #:signing-keypair signing-keypair))

;; ── Grant KINDS: use (the default) and consume ──────────────────────────────
;; A USE grant lends a thing's service: the commune engages it and hands it
;; back whole — the apple press, the workshop, the bike. A CONSUME grant lends
;; a quantity to be SPENT: money into the commune's purse, fuel into its tank,
;; seed into its beds. Same credential, same issuer-owned recall, same window;
;; what differs is how the solve reads it — a use grant projects as `Svc|spec`
;; CAPACITY (commune-socialized-caps), a consume grant as bounded STOCK of the
;; spec itself (project-socialized-custody clamps the holding to the granted
;; qty), so the plan may draw up to QTY and no more. "Unspent returns" needs
;; no event: a lapsed or recalled grant stops projecting and the remainder is
;; the owner's holding again, as it never stopped being.
;;
;; There is no USE grant of money — deliberately. Money has no use-value of
;; its own to engage-without-spending the way a bike or a bed does; a
;; `kind: use` grant of a medium-of-exchange spec is mechanically legal
;; (zeroed onhand, nothing to draw) but inert by construction, and nothing
;; here reports it as though it did something. "Borrow money, give it back"
;; is REPAY below — a different shape, riding on `consume`, not `use`.
(define (grant-kind-claim kind)
  "The claim value for KIND: #f for a use grant (no claim — SAID-stable for
   every grant minted before kinds existed), \"consume\" for a consume grant."
  (cond ((or (not kind) (eq? kind 'use) (equal? kind "use") (equal? kind "")) #f)
        ((or (eq? kind 'consume) (equal? kind "consume")) "consume")   ; verb-meant: the wire's word for a consume grant
        (else (error "grant kind must be use or consume" kind))))
(define (grant-consume? c)
  "Is credential C a consume grant?"
  (equal? "consume" (cred-claim c 'kind)))

;; ── A loan primitive was tried here and deliberately removed ───────────────
;; A consume-grant carrying a repayment care term (accept-socialization's
;; reciprocal minting a `transfer` debt for equivalent value instead of the
;; durable path's `transfer-custody`) was built, wired end-to-end, and then
;; taken back out: private bilateral loan repayment lets a borrower take
;; commons-lent value out into ordinary wage-labour production and launder
;; the resulting surplus back in as a clean recipe-priced object, a real
;; circuit seam (M...M′) that no provenance check on the repaid
;; object can close without becoming an unenforceable audit regime. The
;; commons' own labour-credit system already has no such seam — credited
;; hours can only ever equal hours the credited person actually worked — so
;; anyone who wants to "borrow" value from the commons works for it instead;
;; there is no lending primitive between that and a plain gift. See
;; project_consume_grant_money.md for the fuller reasoning trail.

;; ── The rights side: ownership attestations ─────────────────────────────────
;; Title as a credential (credentials.scm make-ownership-attestation-credential)
;; — the same normalize-and-build seam socialization-credential is for custody,
;; so the client-signed legs rebuild the identical SAID from the same args.
(define* (ownership-credential owner-aid resource-id resource-spec
                               #:key (qty #f) (qty-unit #f) (ref #f)
                                     (signing-keypair #f))
  (define (ne s) (if (and (string? s) (string-null? s)) #f s))
  (make-ownership-attestation-credential
   owner-aid resource-id resource-spec
   #:qty (ne qty) #:qty-unit (ne qty-unit) #:ref (ne ref)
   #:signing-keypair signing-keypair))

(define* (%live-ownership-attestations store #:optional (now #f))
  (%live-by-schema store *schema-playnet-ownership-attestation* now))

(define* (title-permits? store owner-aid resource-id #:optional (now #f))
  "The ownership compat rule, in one place: may OWNER-AID be treated as
   RESOURCE-ID's owner? A store holding NO ownership attestation naming the
   id leaves the field-only trust standing (every world predating titles,
   verbatim); a store holding ANY — live or revoked — demands a LIVE one
   issued by OWNER-AID. So a title, once anyone has spoken one over a
   thing, is the only voice the gates hear about it."
  (or (not store) (not resource-id)
      (let ((over (filter (lambda (c)
                            (equal? resource-id (cred-claim c 'resource-id)))
                          ($ store 'by-schema
                             *schema-playnet-ownership-attestation*))))
        (or (null? over)
            (any (lambda (c)
                   (and (cred-live? c now)
                        (equal? owner-aid (cred-issuer c))))
                 over)))))

(define* (title-rights-of store resource-id uc-aid #:optional (now #f))
  "Who holds RESOURCE-ID's rights, read off the title rail for the span
   gate (consented-span-of #:rights-of): the issuer of its live ownership
   attestation; 'common when that issuer is the universal commune UC-AID;
   #f when no title has been spoken over it (unknown = ungated)."
  (and store resource-id
       (let ((live (filter (lambda (c) (and (cred-live? c now)
                                            (equal? resource-id (cred-claim c 'resource-id))))
                           ($ store 'by-schema *schema-playnet-ownership-attestation*))))
         (and (pair? live)
              (let ((owner (cred-issuer (car live))))
                (if (and uc-aid (equal? owner uc-aid)) 'common owner))))))

(define* (ownership-ok? store r #:optional (now #f))
  "title-permits?, asked of a resource record's own ownership field."
  (title-permits? store
                  (economic-resource-primary-accountable r)
                  (economic-resource-id r)
                  now))

;; ── Grant: common a privately-held resource into the commune ────────────────

(define* (socialize-private-resource store owner-aid commune-aid
                                     resource-spec qty
                                     #:key (until #f) (from #f)
                                           (movable? #f)
                                           (return-to #f) (condition-floor #f)
                                           (resource #f) (qty-unit #f)
                                           (kind #f) (ref #f) (eligible #f)
                                           (signing-keypair #f))
  "OWNER-AID temporarily socializes QTY of RESOURCE-SPEC into COMMUNE-AID's
   use-pool — a usufruct grant via a custody attestation. RESOURCE-SPEC is a
   privately-held means (workshop, machine, land) or a personal item alike.
   Custody moves to the commune; rights stay with the owner (this issues a
   custody-attestation, never a transfer-all-rights, so `primaryAccountable` /
   `accountingQuantity` are untouched). UNTIL is the return-by (epoch or ISO;
   #f = open-ended); FROM defaults to now.

   The grant is the NARROWEST useful permission by default: the commune may
   `use` the thing WHERE IT SITS, whole, until the window closes. MOVABLE? widens
   it to permit relocation (take the radio). `use` never consumes and never (by
   default) moves the thing, so `don't move the oven` / `don't spend it` are the
   defaults, not instructions. KIND 'consume widens it the other way: the
   commune may SPEND up to QTY of the holding (a purse of EUR, a tank of fuel)
   within the window — see grant-kind-claim.

   RETURN-TO and CONDITION-FLOOR are the reciprocal CARE terms the commune owes
   on return — bring a movable thing back to RETURN-TO, in condition ≥
   CONDITION-FLOOR (apple-press: 'clean it up before returning it'). Return-BY is
   UNTIL; the capacity ceiling is QTY; both are structural. Verify a return
   against these with `socialization-care-breaches` / `commune-care-breaches`.

   ELIGIBLE is the owner's STEWARD RULE — the criteria object the declare wire
   already speaks (matching/filter-rule.scm), whose filter-rule bounds WHO may
   be assigned to work drawing on this grant: `[\"aid\", …]` names people,
   `[\"in-group\", \"friends\"]` names a rel in the owner's contact book. The
   commune's capacity stays anonymous inside the solve; the rule is asked at
   the doors where a person is chosen (make-may-steward). Absent = anyone.

   When STORE is a live ^acdc-store ref the attestation is issued into it.
   Returns the attestation credential (read `cred-said` for the grant id used to
   recall it)."
  ;; the title gate: naming an exact resource must be the TITLED owner's to
  ;; do, once any title over it stands (title-permits? — silence keeps the
  ;; field-only world this call always lived in)
  (when (and store resource
             (not (title-permits? store owner-aid resource)))
    (error "a standing title over that resource names another owner" resource))
  (let ((att (socialization-credential
              owner-aid commune-aid resource-spec qty
              #:from (or from (iso-utc-now)) #:until until #:movable? movable?
              #:return-to return-to #:condition-floor condition-floor
              #:resource resource #:qty-unit qty-unit #:kind kind #:ref ref
              #:eligible eligible
              #:signing-keypair signing-keypair)))
    (when store ($ store 'issue att))
    att))

;; ── Consent is BILATERAL and lives where each party can sign ────────────────
;;
;; Socialization with care terms is a two-party act, and neither party may forge
;; the other's side — so there is no single function that mints both. The flow is:
;;
;;   1. the OWNER grants (offer):  `socialize-private-resource` (owner-signed),
;;      carrying the care terms as claims — a custody attestation into the commune.
;;   2. the COMMUNE accepts:       `(\$ commune 'accept-socialization gov-cap grant-said)`
;;      — a gov-cap-gated, scope-SIGNED ^scope method (scope.scm) that binds the
;;      grant (primary) to the commune's return COMMITMENT (reciprocal) in an
;;      Agreement. That commitment travels with custody via transfer-custody's
;;      `#:carries`, so whoever the plan hands the means to inherits the return
;;      obligation (social-means: custody is a moving assignment).
;;
;; A BARE grant (no care terms) needs no acceptance — it is a unilateral gift of
;; use into the commons pool; step 1 alone suffices. (This replaced an earlier
;; `socialize-with-agreement` that fabricated the commune's unsigned side — only
;; the commune, through its own gov-cap, can commit the commune.)

;; ── Recall: owner-driven early return (delegator-owned revocation) ──────────

;; Revocation is ISSUER-OWNED — the one statement of it. A custody grant's
;; recall and a title's withdrawal are the same act: only the AID that spoke
;; the credential may unspeak it (the same principle that keeps revocation
;; delegator-owned everywhere: no recall ceremony stands over it). Verified
;; before revoking, so no one else can pull another's word.
(define (revoke-own-credential! store caller-aid said what)
  (let ((cred (find (lambda (c) (equal? said (cred-said c)))
                    ($ store 'all))))
    (unless cred
      (error (string-append what ": no such credential") said))
    (unless (equal? caller-aid (cred-issuer cred))
      (error (string-append what ": only the issuer may revoke")
             caller-aid (cred-issuer cred)))
    ($ store 'revoke said)
    said))

(define (desocialize-private-resource! store owner-aid attestation-said)
  "Owner recalls a socialized resource early, returning custody immediately —
   revoke-own-credential!, the active twin of the half-life watcher's passive
   expiry-revert. Returns the revoked SAID."
  (revoke-own-credential! store owner-aid attestation-said "desocialize"))

(define (withdraw-title! store owner-aid title-said)
  "Owner withdraws their ownership attestation — the same act on the rights
   side. The compat rule then treats the resource as titled-and-contested
   (a revoked-only title blocks the field) until a fresh title is spoken."
  (revoke-own-credential! store owner-aid title-said "disown"))

;; ── Reverter: expiry returns custody to the granting owner ──────────────────

(define (socialization-owner-reverter store)
  "A `default-custodian-fn` for `^custody-half-life-watcher`: on window lapse,
   revert a socialized resource to the AID that GRANTED it (the attestation's
   issuer = the owner), rather than to a commons pool. Resolves the owner from
   the live grant for RESOURCE-SPEC; #f when no grant is found."
  (lambda (resource-spec)
    (let ((att (find (lambda (c)
                       (and (equal? *schema-playnet-custody-attestation*
                                    (cred-schema c))
                            (equal? resource-spec (cred-claim c 'resource-spec))))
                     ($ store 'all))))
      (and att (cred-issuer att)))))

;; ── Bridge to the live solve: socialized grants → use-capacity ──────────────

;; Non-revoked, unexpired custody attestations in STORE (the live grants).
;; The live credentials of one schema — the read every per-solve view starts
;; from (custody, span, willingness …): non-revoked, in-window, one idiom.
(define (%live-by-schema store schema now)
  (filter (lambda (c) (and (equal? schema (cred-schema c))
                           (custody-cred-live? c now)))
          ($ store 'all)))

(define (%live-custody-attestations store now)
  (%live-by-schema store *schema-playnet-custody-attestation* now))

;; The live custody attestations the commune HOLDS — its live socialization grants.
(define (%live-commune-grants store commune-aid now)
  (filter (lambda (c) (equal? commune-aid (cred-holder c)))
          (%live-custody-attestations store now)))

;; What a commune is lent: the live custody grants whose holder is COMMUNE-AID,
;; each as ((owner . aid) (resource-id . id | #f) (spec . spec)). A grant names
;; its commune and only that commune's resource view projects the thing, so a
;; means that moves to another scope leaves its grant behind; the planner asks
;; this before it moves one (a person's move keeps what is lent and says so).
(define* (lent-to store commune-aid #:optional (now #f))
  (map (lambda (g) `((owner . ,(cred-issuer g))
                     (resource-id . ,(cred-claim g 'resource-id))
                     (spec . ,(cred-claim g 'resource-spec))))
       (%live-commune-grants store commune-aid now)))

;; How much OWNER-AID has currently, live, socialized as a CONSUME grant of
;; SPEC — a standing "this money is free, don't pay me back for it" promise.
;; accept-reimbursement (governance/scope.scm) reads this to FLAG (never
;; silently block) a reimbursement claim that overlaps with money the same
;; member has already given away for free: a real, unresolvable ambiguity
;; (they may hold an unrelated purse and still have genuinely fronted this
;; specific purchase from their own pocket) surfaced for governance to
;; weigh, not auto-resolved either way.
(define* (member-consume-grant-total store owner-aid spec #:optional (now #f))
  (fold (lambda (c acc)
          (if (and (equal? owner-aid (cred-issuer c))
                   (equal? spec (cred-claim c 'resource-spec))
                   (grant-consume? c))
              (+ acc (or (cred-claim c 'qty) 0))
              acc))
        0
        (%live-custody-attestations store now)))

;; The PRECISE form of the same question, for a claim that NAMES which
;; resource paid (resourceInventoriedAs on a purchase-claim): the live
;; consume-grant OWNER-AID has made to COMMUNE-AID covering RESOURCE-ID —
;; by the exact id when the grant names one, else by SPEC under the
;; owner-holds-one-of-spec convention socialize-private-resource states
;; (a spec-level grant is a grant of THE one such resource the owner
;; holds, so a named resource of that spec is the granted one). #f when
;; none covers it: the named resource is the owner's own, ungranted, and
;; the naming positively clears the coarse flag above.
(define* (member-consume-grant-over store owner-aid commune-aid resource-id spec
                                    #:optional (now #f))
  (find (lambda (c)
          (and (equal? owner-aid   (cred-issuer c))
               (equal? commune-aid (cred-holder c))
               (grant-consume? c)
               (let ((gr (cred-claim c 'resource-id)))
                 (if gr
                     (equal? gr resource-id)
                     (equal? spec (cred-claim c 'resource-spec))))))
        (%live-custody-attestations store now)))

;; Is grant C over resource R? — by the exact resource-id when the grant names one
;; (an owner with several of a spec), else the owner's (issuer's) resource of the
;; granted spec.
;; A grant only reaches a resource its ISSUER holds the rights to. Lending a
;; thing is an exercise of rights, so having none over it is having nothing to
;; lend — and a signature proves only that the claim is authentically yours, not
;; that it was yours to make. The spec-matching branch always said this; naming
;; an exact resource does not buy past it, which it silently did while the
;; resource-id branch stood alone. Fail-safe by construction: an ungrounded grant
;; simply never projects, here or in `commune-socialized-caps`.
;; STORE (optional): when given, the issuer's field-ownership must ALSO stand
;; under the title rule (ownership-ok?) — a standing title contradicting the
;; field silences the grant. Absent (unit worlds, secondary projections with
;; no store in reach), the field-only check stands as it always did.
(define* (%grant-over? c r #:optional (store #f) (now #f))
  (and (equal? (economic-resource-primary-accountable r) (cred-issuer c))
       (let ((rid (cred-claim c 'resource-id)))
         (if rid
             (equal? rid (economic-resource-id r))
             (equal? (economic-resource-conforms-to r) (cred-claim c 'resource-spec))))
       (ownership-ok? store r now)))

;; The containment climb, in the terms EconomicResources are held in — the
;; walk itself lives once, in (playnet planner aggregation containment).
(define (%resource-resolver resources)
  (lambda (id) (find (lambda (y) (equal? id (economic-resource-id y))) resources)))

;; A durable's spatial PLACE: its own current-location, else the nearest
;; container's — the oven inherits the flat's location.
(define (%socialization-place-of resources r)
  (containment-first r economic-resource-current-location
                     #:parent-of economic-resource-contained-in
                     #:resolve (%resource-resolver resources)))

;; ((spec place cap) …) → one fact per (spec, place), capacities summed. This is
;; the federation fold's keyed sum (`sum-by-key`) at a different key type: two
;; members lending into one place lend one pool, exactly as two members wanting
;; a thing in one place want one amount of it. Order is by first appearance, so
;; the caps a solve sees stay stable.
(define (%add-caps a b)
  "Two capacities at one (spec, place), pooled. Each is a number or a reading PER
   PERIOD (a procedure of T — what an availability window makes of a holding), and
   two windows need not agree, so the sum is taken period by period whenever either
   side varies. Pooling the numbers first and the windows afterwards would lend the
   commons one member's hours on everybody's count."
  (cond ((and (procedure? a) (procedure? b)) (lambda (t) (+ (a t) (b t))))
        ((procedure? a) (lambda (t) (+ (a t) b)))
        ((procedure? b) (lambda (t) (+ a (b t))))
        (else (+ a b))))
(define (%sum-facts facts)
  (let ((pooled '()))                       ; ((spec . place) . cap), first appearance first
    (for-each
     (lambda (f)
       (let* ((k (cons (car f) (cadr f)))
              (hit (assoc k pooled)))
         (if hit
             (set-cdr! hit (%add-caps (cdr hit) (caddr f)))
             (set! pooled (append pooled (list (cons k (caddr f))))))))
     facts)
    (map (lambda (p) (list (caar p) (cdar p) (cdr p))) pooled)))

;; ── the ONE cascade: root, containment, retention — derived once ────────────
;; A resource is SOCIALIZED into COMMUNE-AID iff a live commune-held grant
;; names it (a ROOT — %grant-over?, resource-id-aware), or it stands
;; transitively contained-in a root with no RETAINED spec cutting the chain —
;; and its own spec is not retained (what the owner kept back keeps itself
;; back). Retention is the positive opt-out: a live attestation for the spec
;; held by a NON-commune agent. Capacity (commune-socialized-caps) and custody
;; (project-socialized-custody) both build their predicates HERE, so the two
;; cascades cannot drift; reach (federation-resource-resolver) walks the same
;; containment relation from the other end.
(define* (%socialized-selector store commune-aid resources #:optional (now #f))
  "(values socialized? grant-of lent-under) over RESOURCES for COMMUNE-AID's
   live grants at NOW: SOCIALIZED? is the cascade-and-retention test above;
   GRANT-OF the commune-held grant a resource is the direct subject of, or #f (a
   content carried in by containment has none — it lends its own onhand, not a
   qty); LENT-UNDER the grant a resource came in by — its own, or the grant
   over the root it stands in."
  (let* ((live   (%live-custody-attestations store now))
         (grants (filter (lambda (c) (equal? commune-aid (cred-holder c))) live))
         (retained? (lambda (spec)
                      (any (lambda (c) (and (equal? spec (cred-claim c 'resource-spec))
                                            (not (equal? commune-aid (cred-holder c)))))
                           live)))
         ;; RESOURCES indexed once (id → resource) rather than `find`-scanned
         ;; per lookup: BY-ID is called once per step of every resource's
         ;; containment-chain walk, so a linear scan here made the selector
         ;; O(resources² × depth) instead of O(resources × depth).
         (resource-index (let ((h (make-hash-table)))
                           (for-each (lambda (r) (hash-set! h (economic-resource-id r) r)) resources)
                           h))
         (by-id (lambda (id) (hash-ref resource-index id #f)))
         (grant-of (lambda (r) (find (lambda (c) (%grant-over? c r store now)) grants)))
         (root? (lambda (r) (and (grant-of r) #t)))
         ;; transitively inside a socialized root; a RETAINED container cuts
         ;; the chain rather than being searched past
         (inside? (lambda (r)
                    (and (any root?
                              (take-while
                               (lambda (c) (not (retained? (economic-resource-conforms-to c))))
                               (containment-chain r
                                 #:parent-of economic-resource-contained-in
                                 #:resolve by-id)))
                         #t))))
    (values (lambda (r)
              (and (not (retained? (economic-resource-conforms-to r)))
                   (or (root? r) (inside? r))))
            grant-of
            (lambda (r)
              (or (grant-of r)
                  (any grant-of
                       (take-while
                        (lambda (c) (not (retained? (economic-resource-conforms-to c))))
                        (containment-chain r
                          #:parent-of economic-resource-contained-in
                          #:resolve by-id))))))))

(define* (commune-socialized-caps store commune-aid resources periods
                                  #:optional (now-epoch #f)
                                  #:key (period-epoch #f) (span-of '()))
  "The eco-caps a commune's LIVE socialization grants contribute to its solve,
   RESPECTING CONTAINMENT: socializing a container socializes its contents.

   PERIOD-EPOCH (optional, `period → timestamp`): when given, a grant contributes
   to period T only if it is live AT that period's time — so a grant whose
   [from,until] covers only part of a multi-period horizon caps just the in-window
   periods (the same `custody-cred-live?` gate, read per period). Absent, a grant
   live now caps every solve period (the single-period / grant-covers-horizon case).

   Reads live custody attestations (gated by `custody-cred-live?` — an expired or
   revoked grant silently drops, its custody already reverted). A durable is
   socialized if it is a ROOT (its spec granted to COMMUNE-AID and it is the
   commune-custodied resource of that spec) or if it is transitively CONTAINED-IN
   a socialized root — socializing an apartment socializes the oven inside it,
   *unless otherwise specified*. The opt-out is a positive RETENTION: a live
   custody attestation for that spec held by a NON-commune agent (the owner keeps
   it, VF's `separate`) — which also blocks the cascade past a retained container.
   Capacity: a directly-granted root lends the `qty` on its grant; a content
   carried in by containment lends its own inherent per-period service (its
   onhand — the oven comes with the flat, at the oven's own capacity). Mapped to
   `Svc|spec` eco-caps via the planner's neutral `svc-eco-caps`. Feed into the
   live solve alongside any base caps:

     (plan-scope root #:eco-caps (append base (commune-socialized-caps …)))"
  (define (facts-at now)
   (receive (socialized? grant-of lent-under)
       (%socialized-selector store commune-aid resources now)
    (let* ((facts
          (filter-map
           (lambda (r)
             (and (socialized? r)
                  ;; a CONSUME grant lends stock, not service: its holding is
                  ;; clamped in the projected view and read by ingest-stock!
                  ;; as a bounded draw — no Svc| cap for it here
                  (not (and (grant-of r) (grant-consume? (grant-of r))))
                  ;; a MOVABLE use grant lends the thing itself (the view holds
                  ;; it — project-socialized-custody), and what stands in it
                  ;; comes with it: their capacity is the holdings' own,
                  ;; wherever the thing stands, and no cap for them here
                  (not (and=> (lent-under r) (lambda (g) (cred-claim g 'movable))))
                  (let* ((spec  (economic-resource-conforms-to r))
                         (grant (grant-of r))
                         ;; the LENT-IN span analogue: a live span declaration
                         ;; moves where the granted capacity POOLS, exactly as it
                         ;; does for owned means — the location stays the record's
                         (place (or (assoc-ref span-of (economic-resource-id r))
                                    (%socialization-place-of resources r)))
                         (oh    (economic-resource-onhand-quantity r))
                         ;; a granted root lends the qty it stated; a content carried
                         ;; in by containment lends its own onhand service capacity.
                         (qty   (if grant (cred-claim grant 'qty)
                                    (and oh (measure-has-numerical-value oh))))
                         ;; WHAT that number is measured in, and so what it renders
                         ;; per hour. THE conversion is the engine's own (planner
                         ;; live): a capacity derived any other way drifts from the
                         ;; one ingest-stock! computes for the same resource — by a
                         ;; factor of the period, and silently, because the eco-cap
                         ;; overrides the ingested one.
                         ;;
                         ;; Two provenances, two readings:
                         ;;
                         ;;   a GRANT states a ceiling — `qty` is documented as the
                         ;;   per-period capacity the owner lends. Saying `qty-unit`
                         ;;   makes that a rate and settles it. A grant minted before
                         ;;   the claim existed cannot gain one (its SAID is fixed),
                         ;;   so its denominator is the scope's own DECLARED period
                         ;;   length — a stated quantity, and one that holds still
                         ;;   while the lattice is refined, unlike the period the
                         ;;   solve happens to be using.
                         ;;
                         ;;   CONTAINMENT lends the thing's own onhand, which is
                         ;;   already a well-formed holding, so it reads as written.
                         (unit  (or (and grant (cred-claim grant 'qty-unit))
                                    (and (not grant) oh (measure-has-unit oh))))
                         ;; per PERIOD, because an availability window opens for part
                         ;; of a horizon: a workshop lent for evenings caps the
                         ;; evening periods and none of the others.
                         (cap-at
                          (and qty
                               (if unit
                                   (lambda (t) (holding-capacity qty (make-measure qty unit) r
                                                                 (resource-window-hours r t)))
                                   (lambda (t) (* qty (/ (resource-window-hours r t)
                                                         (declared-period-hours))))))))
                    (and spec place qty (> qty 0.0) (list spec place cap-at)))))
           resources)))
     ;; POOL the facts: two members who socialize the same spec INTO THE SAME
     ;; PLACE lend one pool of that service, and the commons may draw the sum.
     ;; Summed HERE so `svc-eco-caps` emits one located key `Svc|spec#place@t`
     ;; per pool; the engine's ingest ADDS a second policy cap on the same key
     ;; (engine.scm: pools add, the means fold's own monoid), so this sum and
     ;; a UC allocation on the same place stand as two pools beside each other.
     (%sum-facts facts))))
  (if period-epoch
      ;; per-period: only the grants live at each period's time cap that period
      (append-map (lambda (t) (svc-eco-caps (facts-at (period-epoch t)) (list t))) periods)
      (svc-eco-caps (facts-at now-epoch) periods)))

;; ── Projection: the live grant → the commune's custodian VIEW (per-solve) ────

(define* (project-socialized-custody resources store commune-aid #:optional (now #f))
  "Project the commune's LIVE grants onto RESOURCES: each grant's subject — the
   owner's resource of the granted spec (matched by `primary-accountable` = the
   grant's issuer) — comes back with `custodian-scope = commune`, rights untouched
   (primary-accountable stays the owner, so it reads as loaned-in, `channel-rented?`).
   RESPECTS CONTAINMENT: a resource transitively contained in a granted root
   projects too (socializing the flat projects the beds and the oven inside),
   unless a retained spec cuts the chain — the same cascade-and-retention rule
   commune-socialized-caps applies to capacity, so view and caps agree.

   This is a per-solve VIEW derived from the live grants, NOT a stored mutation: a
   lapsed or recalled grant simply stops projecting, so custody reverts with no
   extra event — the same 'derived from the live grant' discipline as the capacity,
   mobility, and care passes, so the grant stays the single source of truth. Apply
   it at the solve's resource boundary so `commune-socialized-caps` and the scope
   filter see one consistent custodian:

     (let* ((rs (project-socialized-custody (obs-resources) store commune-aid)))
       (plan-scope root #:resource-view (lambda (_) rs)
                        #:eco-caps (append base (commune-socialized-caps store commune-aid rs periods))))

   (Owner-holds-one-of-spec is assumed; a grant naming the exact resource is the
   refinement for an owner with several of a kind.)"
  (receive (socialized? grant-of . _)
      (%socialized-selector store commune-aid resources now)
    (map (lambda (r)
           (if (socialized? r)
               (let ((g (grant-of r))
                     (c (economic-resource-set-custodian-scope r commune-aid)))
                 ;; a CONSUME grant lends a QUANTITY to spend: the commune's
                 ;; view holds min(granted, onhand) of it — the solve draws on
                 ;; that and nothing past it; the remainder stays the owner's
                 (let* ((oh   (economic-resource-onhand-quantity r))
                        (have (if oh (measure-has-numerical-value oh) 0))
                        (unit (or (and oh (measure-has-unit oh))
                                  (and g (cred-claim g 'qty-unit)) "each")))
                   (cond
                    ((and g (grant-consume? g))
                     (economic-resource-set-onhand-quantity
                      c (make-measure (min have (cred-claim g 'qty)) unit)))
                    ;; a USE grant's ROOT lends the SERVICE its grant states
                    ;; (commune-socialized-caps reads the grant's qty, never the
                    ;; holding) and nothing of its SUBSTANCE: the view holds
                    ;; none of it to consume, so a purse lent "for use" buys
                    ;; nothing and a bike lent for use is never eaten. A content
                    ;; carried in by containment keeps its onhand — that IS its
                    ;; capacity.
                    ;; A use grant that lets the means TRAVEL (`#:movable?`) lends
                    ;; the thing: the view holds min(granted, onhand) of it, so
                    ;; the solve reads it as a means standing where it stands —
                    ;; carried by the mode of the scope that names it, its
                    ;; capacity following it — and no cap pins it to a place.
                    ((and g (cred-claim g 'movable))
                     (economic-resource-set-onhand-quantity
                      c (make-measure (min have (cred-claim g 'qty)) unit)))
                    (g (economic-resource-set-onhand-quantity c (make-measure 0 unit)))
                    (else c))))
               r))
         resources)))

(define* (commune-resource-view own-resources store commune-aid
                                #:optional (resolve (lambda (grant) '())) (now #f)
                                #:key (labour-specs '()) (means-specs #f) (persons '()))
  "The full resource set a commune's solve should see: its OWN resources plus, for
   each LIVE grant it holds, the granted resource fetched via RESOLVE — the whole
   projected commune-custodied. RESOLVE is the federation seam: (grant → its
   resource record(s)), e.g. by walking to the owner's scope-root; it defaults to
   none, for when the commune already holds the record in OWN. This is the
   'commune's view = own ∪ live-granted, DERIVED not copied' rule: a lapsed or
   recalled grant drops both the resource and its custody next solve, nothing
   stored. Feed it as the solve's resource-view:

     (plan-scope scope #:resource-view (lambda (own) (commune-resource-view own store commune-aid resolve))
                       #:eco-caps      (commune-socialized-caps store commune-aid
                                         (commune-resource-view own-resources store commune-aid resolve) periods))

   The view is the commune's TENURE, read off the projected records: a resource
   enters the solve iff the commune holds it — as owner (`primary-accountable`),
   as custodian (`custodian-scope`, which is what a live grant projects), or
   unattributed (a bare seed with neither field, the pre-tenure world).

   Tenure governs what can be TAKEN — stock and means, which the commune draws
   only if it holds them or was lent them. LABOUR cannot be taken: scheduling
   a person's hours is asking them, and their consent is the accept itself
   (commitment-horizon.md — refusal is the default, the gate and the lapses
   stand at that door). So a resource that IS labour — whose spec some `work`
   flow conforms to, LABOUR-SPECS, which the recipes say and nothing else
   does — enters the view as its holder's capacity, whoever holds it; that
   holder is exactly who the engine reads it as (vf-agent-skills: a person's
   skills are the resources they are accountable for). Absent LABOUR-SPECS
   (a caller with no recipes in hand) the view is tenure alone. A
   member's PRIVATE holding — owner set to their AID, no grant over it — sits in
   the same observer (declare-means seeds it there, so the slots match on it).
   A MEANS they hold — a spec some `use` flow touches, MEANS-SPECS, again the
   recipes' word — stays out of the plan until they lend it: the grant is the
   consent, and the lend button is where a declared offer becomes common
   capacity. The same rule the service's inventory read applies (`in-scope?`),
   so what a member sees listed as the commune's and what the solve draws on
   agree. A GOOD they hold — the loaf a claim handed them — enters as their
   own: the engine names it \"spec~aid\" (ingest-stock!, the same rename the
   claim recipe produces), so their next want is met from it first and the
   plan claims no second copy. What a process uses, no person claims; what a
   person holds, no plan takes. PERSONS is the roster of AIDs read that way —
   the scope's people, whose holdings the engine can name — and MEANS-SPECS
   must be stated for any private good to pass: absent either, tenure alone."
  (let* ((grants (%live-commune-grants store commune-aid now))
         (seen   (let ((h (make-hash-table)))        ; a set, not a list `member`-scanned per candidate
                   (for-each (lambda (r) (hash-set! h (economic-resource-id r) #t)) own-resources)
                   h))
         (extra  (filter (lambda (r) (not (hash-ref seen (economic-resource-id r) #f)))
                         (append-map resolve grants)))
         (labour? (lambda (r) (and (member (economic-resource-conforms-to r) labour-specs) #t)))
         (held?  (lambda (r)
                   (let ((cs (economic-resource-custodian-scope r))
                         (pa (economic-resource-primary-accountable r)))
                     (or (labour? r)                       ; a capacity: its holder's, consent is the accept
                         (and (not cs) (not pa))
                         (equal? cs commune-aid)
                         (equal? pa commune-aid)
                         (and means-specs (not cs) (member pa persons)   ; a person's own GOOD: theirs, named so by the engine
                              (not (member (economic-resource-conforms-to r) means-specs))))))))
    (filter held?
            (project-socialized-custody (append own-resources extra) store commune-aid now))))

;; The subtree walk itself lives in (playnet planner aggregation scope-tree) —
;; ONE walk for everything read off the federation tree, so a member with no
;; economic root, a down branch, a DAG and a cycle are handled in one place.

;; Every ^scope is a uniform node: its own economic root (`scope-root`, maybe #f)
;; plus its sub-scopes (`members`, maybe empty). This collects the resources of the
;; WHOLE SUBTREE, arbitrarily deep — each node's own scope-root resources, then its
;; members' recursively — so an ancestor (the commons, at the limit) sees a means
;; socialized anywhere below it. The pull twin of labour's arbitrarily-deep fold
;; (aggregation/scope-tree.scm), but read FRESH each solve rather than pushed into a
;; standing aggregate: exact under REFEDERATION with nothing to rewire — the tree is
;; whatever it is at planning time. A visited-set (eq? identity) folds a CYCLE or a
;; DAG (a commune shared by two federations) to ONE visit per node, so a loop
;; terminates and shared membership never double-counts.
;; the specs the scope's recipes draw as WORK — the one fact that makes a
;; resource a capacity rather than a means. Read off the recipe store's
;; flows; a root without one (a bare mock) has no labour to name.
(define (verb-specs-of scope-root action)
  "Every spec the scope's recipes touch under ACTION — `work` says what labour
   is, `use` what a means is. The recipes' word, read once off the store."
  (let ((rs (false-if-exception ($ scope-root 'recipe-store))))
    (if (not rs) '()
        (call-with-values (lambda () (gather-recipes rs))
          (lambda (procs flows)
            (delete-duplicates
             (filter-map (lambda (f) (and (eq? (recipe-flow-action f) action)
                                          (recipe-flow-resource-conforms-to f)))
                         flows)))))))
(define (labour-specs-of scope-root)
  "What labour is here: the worked specs (formulas/actions labour-specs — an
   effort unit stated, or a recipe drawing it as work), read off the store."
  (let ((rs (false-if-exception ($ scope-root 'recipe-store))))
    (if (not rs) '()
        (call-with-values (lambda () (gather-recipes rs))
          (lambda (procs flows) (labour-specs flows (scope-resource-specs rs)))))))

(define (%scope-subtree-resources scope)
  (scope-subtree-collect scope (lambda (root) ($ ($ root 'observer) 'all-resources))))

(define (federation-resource-resolver federation-scope)
  "The cross-scope RESOLVE for `commune-resource-view`: fetch a grant's subject
   resource by searching the federation SUBTREE rooted at FEDERATION-SCOPE —
   arbitrarily deep, every scope's own root and its members' recursively — so a
   scope can see and schedule a resource a member, a sibling, or a member's member
   holds, at any depth. Read FRESH each solve, never copied; correct under
   refederation. Uses `%grant-over?`, so a grant that names an exact resource
   resolves precisely.

   Reach (which resources exist where) is orthogonal to VISIBILITY (which grants a
   scope sees): a grant is still seen only by its HOLDER scope
   (`commune-socialized-caps` filters by holder). So this deepening lets the ONE
   global commons solve (a grant to the UC) reach a means nested anywhere below,
   without letting a leaf solved in isolation see an ancestor's grant — see
   test-socialize-to-uc.

   For the common INTRA-commune case (the owner is a member of the very commune the
   grant socializes into), the resource is already in the commune's own observer —
   no resolver is needed; `commune-resource-view` with the default (none) suffices."
  (lambda (grant)
    (let* ((pool  (%scope-subtree-resources federation-scope))
           (roots (filter (lambda (r) (%grant-over? grant r)) pool)))
      ;; a granted CONTAINER carries its contents: close the fetch over the
      ;; contained-in relation, so a cross-scope grant of the flat reaches the
      ;; beds inside it. This is REACH only — whether a content's capacity
      ;; counts (and whether a retained spec is kept back) stays with
      ;; commune-socialized-caps / project-socialized-custody, which gate the
      ;; same set this returns.
      ;; A BFS over a precomputed contained-in index, not a repeated
      ;; whole-POOL filter against a growing, rebuilt ids list: that was
      ;; O(pool) work PER ROUND (rebuilding ids, then an O(acc) `member`
      ;; twice per pool element), and the loop can run up to pool rounds —
      ;; O(pool²) worst case for what is really one pass per resource.
      (let ((children-by-container
             (let ((h (make-hash-table)))
               (for-each (lambda (r)
                           (let ((cid (economic-resource-contained-in r)))
                             (when cid (hash-set! h cid (cons r (hash-ref h cid '()))))))
                         pool)
               h))
            (seen (let ((h (make-hash-table)))
                    (for-each (lambda (r) (hash-set! h (economic-resource-id r) #t)) roots)
                    h)))
        (let loop ((acc roots) (frontier roots))
          (let ((more (append-map
                       (lambda (r)
                         (filter (lambda (k)
                                   (let ((kid (economic-resource-id k)))
                                     (and (not (hash-ref seen kid #f))
                                          (begin (hash-set! seen kid #t) #t))))
                                 (hash-ref children-by-container (economic-resource-id r) '())))
                       frontier)))
            (if (null? more) acc (loop (append acc more) more))))))))

;; ── Auto-apply socialization at the scope level ─────────────────────────────

(define* (commune-demand scope-root store commune-aid
                         #:key (demand-scope #f) (home-of #f) (today #f) (voice-source #f)
                               (periods '(0)) (horizon #f) (demand '()) (period-spans #f)
                         #:allow-other-keys)
  "THE DEMAND A SOLVE AT THIS SCOPE ANSWERS FOR, as one reading:
     ((demand . rows) (horizon . (start . n)) (periods . (0 …))
      (desire-weights . …) (repro-floors . …) (budgeted-floors . …) (insurance . …))
   DEMAND-SCOPE is the governance ^scope for this root or its standing
   ^demand-node (demand-cells-of reads either): every declared need in the
   subtree, summed fresh, with the scope's own rows named per citizen
   (name-own-rows) and the caller's DEMAND riding on top as a what-if; the
   horizon the needs' own dates decide unless HORIZON is given; the clock
   laid for the projection (a bounded need confined to its own day). With no
   DEMAND-SCOPE the caller's demand stands alone — every plain solve."
  ;; homes resolve off the scope's own TREE (the root, its agents and stock),
  ;; never off the demand node — a node answers no roster, and a resolver
  ;; over it read every citizen at the placeholder (found live)
  (let* ((home-of (or home-of (and demand-scope (federation-home-of scope-root))))
         (cells   (and demand-scope (demand-cells-of demand-scope #:home-of home-of
                                                     #:voice-of (federation-voice-of demand-scope voice-source))))
         (horizon (or horizon (and demand-scope (cells->horizon (or cells '()) #:today today))))
         (periods (if horizon (iota (cdr horizon)) periods)))
    ;; demand-for's period projection reads period-span (engine state) to
    ;; confine a bounded need to its own day; the solve lays that state out
    ;; only once it runs — after dem is computed — so it is laid HERE,
    ;; idempotent with the solve's own laying
    (cond (horizon (set-daily-horizon! (car horizon) (cdr horizon)))
          ((not period-spans)
           (for-each (lambda (t sp) (set-period-span! t (car sp) (cdr sp)))
                     periods
                     (declared-partition '() '() #f #f (length periods)))))
    (let* ((terms (if cells
                      (demand-terms-for (name-own-rows cells scope-root #:home-of home-of #:voice-source voice-source) periods)
                      '()))
           (dem (if cells (merge-demand (assq-ref terms 'demand) demand) demand)))
      `((demand . ,dem) (horizon . ,horizon) (periods . ,periods)
        (desire-weights . ,(or (assq-ref terms 'desire-weights) '()))
        (repro-floors . ,(or (assq-ref terms 'repro-floors) '()))
        (budgeted-floors . ,(or (assq-ref terms 'budgeted-floors) '()))
        (insurance . ,(or (assq-ref terms 'insurance) '()))))))

(define (commune-stamp store commune-aid world alist)
  "The solve's ALIST with what only the custody projection knows: the
   loaned-in service goods for the wheel's rented sector, the pool's slots
   stamped with how occupied this solve left them (%slots-with-draw), the
   owners' steward rules beside the slots they bound, and the demand the
   solve ran on (so a reader pricing it asks about the same rows)."
  (let ((rented (assq-ref world 'rented)) (slots (assq-ref world 'slots)) (caps (assq-ref world 'caps)))
    (append (if (pair? rented) `((rented-goods . ,rented)) '())
            (if (pair? slots) `((socialized-slots . ,(%slots-with-draw slots alist caps))) '())
            (let ((rules (commune-steward-rules store commune-aid)))
              (if (pair? rules) `((steward-rules . ,rules)) '()))
            `((demand . ,(or (assq-ref alist 'demand) '())))
            (alist-delete 'demand alist))))

(define* (socialized-readers store #:key (resolve (lambda (grant) '())) (scope-of #f) (consent-of #f) (voice-source #f))
  "GOVERNANCE AS READERS OF A SCOPE, for ^planner-service (live.scm
   solve-with-readers): WORLD (commune-world: the custody projection, the
   socialized caps, the spans, the care rows), DEMAND (commune-demand: the
   tree's declared needs with the caller's riding on them), STAMP
   (commune-stamp), POOL (the socialized slots, live). SCOPE-OF (aid → the
   ^scope or its ^demand-node) turns the demand fold on; CONSENT-OF (a thunk
   → the span gate's mappings) turns the consent gate on; RESOLVE is the
   federation seam. One person, one dividend: the credit fold counts a
   citizen only where STORE holds a live personhood for the account —
   failing OPEN until the first person is recognised. VOICE-SOURCE (a thunk →
   the federation's credit node, or #f) is the pool a citizen's voice is read
   against; without it, the scope's own subtree."
  (set-person-substrate!
   (lambda (aid) (or (not (personhood-bootstrapped? store)) (holds-any-live-phc? store aid))))
  (let ((consent (lambda () (if consent-of (or (false-if-exception (consent-of)) '()) '()))))
    `((world . ,(lambda (root sid . kw)
                  (apply commune-world root store sid #:resolve resolve (append kw (consent)))))
      (demand . ,(lambda (root sid . kw)
                   (apply commune-demand root store sid
                          #:demand-scope (or (kw-ref kw #:demand-scope) (and scope-of (scope-of sid)))
                          #:voice-source (and voice-source (voice-source))
                          (kw-without kw '(#:demand-scope)))))
      (stamp . ,(lambda (root sid world alist) (commune-stamp store sid world alist)))
      (lent . ,(lambda (sid) (lent-to store sid)))
      (pool . ,(lambda (root sid) (commune-socialized-slots root store sid #:resolve resolve))))))

(define* (plan-commune-scope scope-root store commune-aid
                             #:key (resolve (lambda (grant) '())) (demand-scope #f)
                             #:allow-other-keys #:rest kw)
  "Plan over a COMMUNE scope with its live socialization folded in — the
   plain solve (plan-scope->alist) through governance's readers
   (socialized-readers): the custody projection as #:resource-view, the
   socialized Svc| capacity under the caller's #:eco-caps, the governed
   spans, the tree's declared demand with the caller's #:demand riding on
   it (#:DEMAND-SCOPE: a live ^scope walked or a standing ^demand-node
   read), the care upkeep of every floored grant, and the result stamped
   with what only the projection knows. Every other keyword forwards to
   plan-scope->alist. The ^planner-service composes the same readers the
   same way (live.scm solve-with-readers); this is that composition for a
   caller holding the store."
  (apply solve-with-readers (lambda (root _sid . kw) (apply plan-scope->alist root kw))   ; the plain solve, as the service names it (plain-plan-fn)
         (socialized-readers store #:resolve resolve #:scope-of (lambda (_) demand-scope))
         scope-root commune-aid
         (kw-without kw '(#:resolve #:demand-scope))))

;; how OCCUPIED each pool slot came out of the solve it rode in: per Svc| good,
;; the material draw over the socialized capacity — a fraction in [0,1] on the
;; slot row (`drawn`), so a surface can say "2 of 2 beds taken" without
;; re-deriving either side. Draw and cap are both in service units (unit-hours),
;; so the ratio is unit-free; a spec the solve never touched reads 0.
(define (%slots-with-draw slots alist caps)
  (let ((draw (make-hash-table)) (cap (make-hash-table)))
    (for-each
     (lambda (m)
       (let ((g (row-spec m)) (q (or (row-quantity m) 0)))
         (when (and (string? g) (eq? 'use (row-action m)))   ; a means in use, under its own specification
           (let ((svc (string-append "Svc|" g)))
             (hash-set! draw svc (+ (hash-ref draw svc 0) (abs q)))))))
     (or (assq-ref alist 'material) '()))
    (for-each
     (lambda (c)
       (let* ((g (key-spec (car c)))
              (v (cdr c)))
         (when (number? v)
           (hash-set! cap g (+ (hash-ref cap g 0) v)))))
     (or caps '()))
    (map (lambda (s)
           (let* ((g (string-append "Svc|" (or (assq-ref s 'spec) "")))
                  (c (hash-ref cap g 0)) (d (hash-ref draw g 0)))
             (cons (cons 'drawn (if (> c 0) (exact->inexact (min 1.0 (/ d c))) 0.0))
                   s)))
         slots)))


;; the pool as SLOTS: one row per loaned-in resource (custody=commune,
;; rights=owner) in VIEW, each at the place the containment climb resolves
;; (the oven inherits the flat's location). VIEW is a custody projection
;; (commune-resource-view), so a recalled grant stops projecting and its row
;; leaves with it — nothing is stored, nothing needs a solve.
(define (%socialized-slot-rows store commune-aid view)
  (let ((grant-of (receive (_ g . __) (%socialized-selector store commune-aid view) g)))
    (filter-map
     (lambda (r)
       (and (resource-rented? r commune-aid)
            (let ((g (grant-of r))
                  (m (economic-resource-onhand-quantity r)))
              `((id    . ,(economic-resource-id r))
                (spec  . ,(economic-resource-conforms-to r))
                (name  . ,(or (economic-resource-name r)
                              (economic-resource-conforms-to r)))
                (emoji . ,(economic-resource-image r))
                ;; a granted root shows what the grant lends; a content
                ;; carried in by containment shows its own holding
                (qty   . ,(cond (g (cred-claim g 'qty))
                                (m (measure-has-numerical-value m))
                                (else 0)))
                (unit  . ,(or (and m (measure-has-unit m)) "each"))
                (kind  . ,(if (and g (grant-consume? g)) "consume" "use"))
                (where . ,(%socialization-place-of view r))
                (owner . ,(economic-resource-primary-accountable r))))))
     view)))

(define* (commune-world scope-root store commune-aid
                        #:key (resolve (lambda (grant) '())) (periods '(0)) (period-epoch #f)
                              (span-of '()) (place-scope-of #f) (spec-of #f) (rights-of #f) (uc-aid #f)
                              (care-upkeep-of #f)
                        #:allow-other-keys)
  "THE RESOURCES A SOLVE AT THIS SCOPE MAY SEE, as one reading:
     ((view . resources) (caps . ((located-good . cap) …)) (span . ((rid . place) …))
      (slots . rows) (rented . (\"Svc|spec\" …)) (care . demand-rows))
   VIEW is SCOPE-ROOT's own resources plus what live grants resolve, through
   the custody projection (commune-resource-view: tenure filter, custodian
   set to the commune, a use grant's root zeroed); CAPS the socialized Svc|
   pools over PERIODS derived from that same view; SPAN the governed pool
   spans, consent- and standing-gated when the mappings are supplied; SLOTS
   the pool as rows for the map; RENTED the loaned-in service goods for the
   wheel's rented sector. Every solve — the scope's own (plan-commune-scope),
   the federated and the consensus solves (the service's world-of), and the
   pool read outside any solve (commune-socialized-slots) — reads this one
   function, so no solve sees a world another solve does not."
  (let* ((own    ($ ($ scope-root 'observer) 'all-resources))
         ;; what LABOUR is, the recipes say: every spec a `work` flow conforms
         ;; to — read off the scope's own store, once, so the view can let a
         ;; person's capacity through tenure (see commune-resource-view)
         (view   (commune-resource-view own store commune-aid resolve
                                        #:labour-specs (labour-specs-of scope-root)
                                        ;; a person's own good enters as theirs; a means they hold waits for the lend
                                        #:means-specs (verb-specs-of scope-root 'use)
                                        #:persons (filter-map (lambda (a) (and (eq? (agent-type a) 'person) (agent-id a)))
                                                              ($ ($ scope-root 'agent-store) 'all-agents))))
         (span   (append span-of
                         (consented-span-of store #:place-scope-of place-scope-of #:spec-of spec-of
                                                  #:rights-of rights-of #:uc-aid uc-aid)))
         (caps   (commune-socialized-caps store commune-aid view periods
                                          #:period-epoch period-epoch #:span-of span))
         ;; the loaned-in means' Svc| goods, for the RENTED wheel sector: they live
         ;; only in this per-solve projection (custody=commune), never on the stored
         ;; observer, so the solve surfaces them in its result alist — the one place
         ;; the projection exists — for scope-fragility-wire to read them back.
         ;; The pool as SLOTS, for the map and any other surface that wants to
         ;; draw the socialized means at their places; a solve stamps each with
         ;; how occupied it left it (%slots-with-draw).
         (slots  (%socialized-slot-rows store commune-aid view))
         ;; the wheel's rented goods ARE the pool's service specs — the same
         ;; resource-rented? pass read once, deduped for the frag sector; a
         ;; consume grant lends stock, not a service, so it has no Svc| good
         (rented (delete-duplicates
                  (filter-map (lambda (s) (and (equal? "use" (assq-ref s 'kind))
                                               (string-append "Svc|" (assq-ref s 'spec))))
                              slots)))
         ;; the care terms' material half, compiled to demand: a live grant
         ;; with a condition-floor asks for its upkeep deliverable (named by
         ;; CARE-UPKEEP-OF, the knowledge join) before the return — care as
         ;; scheduled labour, not only a check at hand-back
         (care   (socialization-care-demand store commune-aid view periods
                                            #:upkeep-of (or care-upkeep-of (lambda (s) #f)))))
    `((view . ,view) (caps . ,caps) (span . ,span) (slots . ,slots) (rented . ,rented) (care . ,care))))

(define* (commune-socialized-slots scope-root store commune-aid
                                   #:key (resolve (lambda (grant) '())))
  "What stands IN the commons right now, as slot rows — the means COMMUNE-AID
   holds by live grant, read straight off the store and SCOPE-ROOT's own
   resources through the custody projection every solve derives
   (commune-world). A grant issued a moment ago is a row a moment ago; a
   recalled one is gone. The rows carry no `drawn`: how occupied a slot is
   belongs to a solve (plan-commune-scope stamps it), and a reader joins the
   two by id when it wants both. RESOLVE is the federation seam."
  (assq-ref (commune-world scope-root store commune-aid #:resolve resolve) 'slots))

;; ── The steward gate: WHO may be assigned to work drawing on a grant ────────
;; A grant's `eligible` claim is the owner's steward rule — the same criteria
;; object the declare wire carries for a slot (matching/filter-rule.scm), so the
;; dial's one rule editor and the one evaluator serve both. Inside the solve the
;; commune's capacity is anonymous (the LP never names a person); the rule is
;; asked at the doors where a person IS chosen — the accept door, the UC
;; matching's candidate filter, the directed offer — through the one predicate
;; make-may-steward builds, injected into the planner service the way debts and
;; standing are. It is evaluated over the OWNER's contact book: recognition is
;; 1.0 when the candidate stands in it, `groups` are the rels the owner gave
;; them, so `["in-group", "friends"]` reads exactly as the social lens does;
;; `["vouched"]` admits whoever the owner holds a live signed vouch for.
;; Pooled same-spec capacity reads as one: a candidate admitted by ANY live
;; grant of the spec — or by a grant carrying no rule — may draw the pool.
;; Per-resource draw attribution is a later refinement of the same read.

;; the criteria on GRANT's `eligible` claim when it carries a filter-rule,
;; else #f — the one parse both readers below share
(define (grant-steward-criteria grant)
  (let ((c (criteria-json->alist (cred-claim grant 'eligible))))
    (and c (criteria-ref c 'filter-rule) c)))

(define (grant-steward-rule grant)
  "The owner's steward rule on GRANT, or #f (anyone)."
  (and=> (grant-steward-criteria grant) (lambda (c) (criteria-ref c 'filter-rule))))

(define* (commune-steward-rules store commune-aid #:optional (now #f))
  "One row per live grant COMMUNE-AID holds that carries a steward rule:
   ((spec . S) (owner . AID) (criteria . ALIST)) — two owners lending the
   same spec each speak for their own."
  (filter-map (lambda (g)
                (and=> (grant-steward-criteria g)
                       (lambda (c)
                         `((spec . ,(cred-claim g 'resource-spec))
                           (owner . ,(cred-issuer g))
                           (criteria . ,c)))))
              (%live-commune-grants store commune-aid now)))

;; the signed half of a group: OWNER's live relationship credentials
;; (playnet-relationship/v1 — "I know SUBJECT as REL", an I2I edge to the
;; voucher's personhood) naming AGENT, each rel a group the way a contact's
;; `rel` is. Read first; the synced book is the fallback for an owner who
;; holds no personhood yet.
(define (vrc-groups-of store owner-aid agent-aid)
  (filter-map (lambda (c)
                (and (equal? owner-aid (cred-issuer c))
                     (equal? agent-aid (cred-holder c))
                     (normalize-rel (cred-claim c 'relationship-type))))
              (%live-by-schema store *schema-playnet-relationship* #f)))

(define* (make-knows store #:key (contacts-of (lambda (aid) '())))
  "(owner-aid agent-aid) → how OWNER knows AGENT, as a rule's context reads it
   (filter-rule.scm `context` #:knows): ((recognition . 1.0|#f) (groups . rels)
   (vouched . bool)). The groups are the rels of OWNER's live signed vouches
   for AGENT, then the rels OWNER's synced contact book (CONTACTS-OF) gives
   them; vouched is the signed half alone. The ONE social reading: the steward
   gate and the slot matcher both ask it, so a group or a vouch admits the same
   people on a lend and on a slot."
  (lambda (owner agent)
    (let* ((book   (or (false-if-exception (contacts-of owner)) '()))
           (mine   (filter (lambda (c) (equal? agent (contact-aid c))) book))
           (signed (vrc-groups-of store owner agent))
           (rels   (append signed (map contact-rel mine))))
      `((recognition . ,(and (pair? rels) 1.0))
        (groups . ,rels)
        (vouched . ,(pair? signed))))))

;; the specs of every container a resource of SPEC stands in, climbing
;; `contained-in` through RESOURCES — the oven's flat, the shelf's workshop
(define (container-specs-of resources spec)
  (let ((by-id (lambda (id) (find (lambda (r) (equal? id (economic-resource-id r))) resources))))
    (delete-duplicates
     (append-map
      (lambda (r)
        (let climb ((c (and=> (economic-resource-contained-in r) by-id)) (seen '()))
          (if (and c (not (memq c seen)))
              (cons (economic-resource-conforms-to c)
                    (climb (and=> (economic-resource-contained-in c) by-id) (cons c seen)))
              '())))
      (filter (lambda (r) (equal? spec (economic-resource-conforms-to r))) resources)))))

(define* (make-may-steward store #:key (contacts-of (lambda (aid) '()))
                                       (skills-of (lambda (aid) '()))
                                       (knows (make-knows store #:contacts-of contacts-of))
                                       (resources-of #f))
  "(commune-aid agent-aid spec [skills]) → may AGENT-AID be assigned to work
   drawing on COMMUNE-AID's socialized SPEC? CONTACTS-OF (owner-aid → the
   owner's synced contact book, alists carrying aid/prefix + rel) supplies the
   recognition and groups; SKILLS come from the caller (the planner's own
   agent-skills read) or SKILLS-OF (aid → spec ids). Both default empty,
   which still answers explicit `aid` rules. No live grant of SPEC carrying a
   rule → anyone.

   A lent container speaks for what stands inside it: with RESOURCES-OF
   (commune-aid → the resources the scope sees), a SPEC no grant names is
   under the grants over the containers its resources stand in — whoever may
   enter the flat may use the oven in it. A content lent by its own grant
   answers to that grant."
  (lambda* (commune-aid agent-aid spec #:optional (skills #f))
    (let* ((live   (%live-commune-grants store commune-aid #f))
           (named  (lambda (sp) (filter (lambda (g) (equal? sp (cred-claim g 'resource-spec))) live)))
           (grants (let ((own (named spec)))
                     (if (or (pair? own) (not resources-of))
                         own
                         (append-map named
                                     (container-specs-of (or (false-if-exception (resources-of commune-aid)) '())
                                                         spec)))))
           (skills (or skills (false-if-exception (skills-of agent-aid)) '()))
           (admits?
            (lambda (g)
              (let ((rule (grant-steward-rule g)))
                (or (not rule)
                    (rule-passes? rule
                      (context #:aid agent-aid
                               #:scopes (list commune-aid)
                               #:skills skills
                               #:knows (knows (cred-issuer g) agent-aid))))))))
      (or (null? grants) (any admits? grants)))))

;; ── Reciprocal care terms: what the commune owes on return ──────────────────

(define (socialization-care-terms grant)
  "The reciprocal care obligations recorded on a socialization GRANT (a custody
   attestation) — what the commune owes when it hands the thing back. Two are
   STRUCTURAL (already enforced elsewhere): `return-by` is the window (the
   half-life watcher reverts custody at it) and `capacity-ceiling` is the granted
   qty (the solve can't draw past it). Two need post-hoc verification:
   `return-to` (a movable thing's origin) and `condition-floor` (return it no
   worse than this). Returns an alist."
  (list (cons 'return-by        (cred-claim grant 'valid-until))
        (cons 'capacity-ceiling (cred-claim grant 'qty))
        (cons 'return-to        (cred-claim grant 'return-to))
        (cons 'condition-floor  (cred-claim grant 'condition-floor))))

;; ── Care, compiled to scheduled labour ──────────────────────────────────────
;; A condition-floor is not only a check at return (socialization-care-breaches,
;; below) — meeting it is WORK, and work the plan can schedule is work that
;; actually happens. This compiles the MATERIAL half of the care terms into
;; demand rows: each live grant that states a condition-floor asks for one unit
;; of its means' UPKEEP DELIVERABLE at the place the means stands, timed at the
;; last period before the return — upkeep before hand-back, as a row the solve
;; fills through whatever repair recipe delivers it (a repair
;; recipe's leak-fixed, household's states, …).
;;
;; The seam is deliberate: mechanics derive WHEN, WHERE and WHETHER (the live
;; grant, its floor, its place, its window); knowledge names WHAT (UPKEEP-OF:
;; lent spec → deliverable spec — the join only a recipe catalogue can make).
;; A spec the mapping does not name compiles to nothing, fail-closed and
;; visible: an unnamed deliverable is an unscheduled obligation, exactly what
;; the post-hoc breach check then reports.
(define (%ne? s) (and (string? s) (not (string-null? s)) s))
(define* (socialization-care-demand store commune-aid resources periods
                                    #:key (upkeep-of (lambda (spec) #f)) (now #f))
  "Demand rows ((\"deliverable#place@t\" . 1.0) …) for the care upkeep of every
   live grant COMMUNE-AID holds that states a condition-floor. PLACE is the
   containment climb's answer for the granted resource; T is the last of
   PERIODS (upkeep lands by the return). A lapsed or recalled grant compiles
   to nothing, like every other projection of it."
  (let ((t (if (pair? periods) (last periods) 0)))
    (filter-map
     (lambda (c)
       (and (%ne? (cred-claim c 'condition-floor))
            (let* ((r     (find (lambda (x) (%grant-over? c x store now)) resources))
                   (deliv (upkeep-of (cred-claim c 'resource-spec)))
                   (place (and r (%socialization-place-of resources r))))
              (and deliv place
                   (cons (format #f "~a#~a@~a" deliv place t) 1.0)))))
     (%live-commune-grants store commune-aid now))))

(define (socialization-care-breaches grant resource)
  "The care terms of GRANT that RESOURCE's returned state VIOLATES — the
   accountability primitive behind 'bring it back, in condition'. Returns a list
   of breach symbols (empty ⇒ returned in good order):
     not-at-origin   — a movable grant whose thing did not come back to `return-to`
     below-condition — returned worn below `condition-floor`
   `return-by` and `capacity-ceiling` are structural (window + solve), so they are
   not re-checked here."
  (let ((return-to (cred-claim grant 'return-to))
        (floor     (cred-claim grant 'condition-floor))
        (loc       (economic-resource-current-location resource))
        (cond      (let ((oh (economic-resource-onhand-quantity resource)))
                     (and oh (measure-has-numerical-value oh)))))
    (append
     (if (and return-to (not (equal? return-to loc)))  '(not-at-origin)   '())
     (if (and floor cond (< cond floor))               '(below-condition) '()))))

(define* (commune-care-breaches store commune-aid resources #:optional (now-epoch #f))
  "The accountability pass that pairs with the half-life watcher: for every
   socialization grant whose window is OVER (return is due — expired or recalled)
   and that carried care terms, the terms its returned resource breached. Returns
   ((spec breach …) …), empty when every return was in good order (a clean return
   reports nothing)."
  (filter-map
   (lambda (c)
     (and (equal? *schema-playnet-custody-attestation* (cred-schema c))
          (equal? commune-aid (cred-holder c))
          (not (custody-cred-live? c now-epoch))              ; window over ⇒ return due
          (or (cred-claim c 'return-to) (cred-claim c 'condition-floor))  ; had care terms
          (let* ((spec (cred-claim c 'resource-spec))
                 (r    (find (lambda (x) (equal? spec (economic-resource-conforms-to x)))
                             resources))
                 (bs   (and r (socialization-care-breaches c r))))
            (and bs (pair? bs) (cons spec bs)))))
   ($ store 'all)))

;; ── Span: the live declarations → the solve's *span-of* alist ────────────────
;;
;; The read half of `make-span-declaration-credential` (credentials.scm): the
;; non-revoked, in-window span declarations in STORE, as the ((resource-id .
;; place) …) alist `ingest-records!`/`ingest-located!` take as #:span-of. The
;; same per-solve-view discipline as every projection in this file — a lapsed
;; or revoked declaration simply stops appearing, and the pool stands at the
;; holding place again with no further event. One live declaration per
;; resource is the intended state — a scope re-spanning a means revokes the
;; old declaration on its own TEL first (the no-recall-ceremony rule: it is
;; the scope's own grant). With several live, the first the store returns
;; wins; nothing here invents an ordering the credentials do not carry.
;; The triples (resource-id place issuer) of the live declarations — issuer kept
;; because the consent gate (means-fold.scm) asks whose act a span was; the
;; plain view below drops it.
(define* (%live-span-decls store #:optional (now #f) (admit? #f))
  "One (resource-id place issuer) per resource, first live declaration the
   store returns. ADMIT? (triple → bool), when given, filters BEFORE the
   per-resource dedup — so an inadmissible declaration cannot SHADOW an
   admissible one (the standing gate rides here, means-fold.scm)."
  (fold (lambda (c acc)
          (let* ((rid (cred-claim c 'resource-id))
                 (at  (cred-claim c 'span-place))
                 (d   (and rid at (list rid at (cred-issuer c)))))
            (if (and d (not (assoc rid acc)) (or (not admit?) (admit? d)))
                (cons d acc)
                acc)))
        '() (%live-by-schema store *schema-playnet-span-declaration* now)))

(define* (live-span-of store #:optional (now #f))
  (map (lambda (d) (cons (car d) (cadr d))) (%live-span-decls store now)))

;;; The consent gate lives HERE, beside `live-span-of` it is the gated form
;;; of, rather than in means-fold.scm where it was written. Both halves read
;;; the same two credential views (`%live-by-schema`, `%live-span-decls`), so
;;; splitting them put the gate in a file that had to reach back into this one
;;; while this one reached forward for the gate — a dependency cycle standing
;;; on nothing but which file the code was typed into. means-fold.scm still
;;; reads this file (for `%socialization-place-of`); nothing reads it back.

;; ── Willingness: consent bounds how far a span may reach (step 4) ────────────
;;
;; A span declaration is the STEWARD's act; a span that lands in another scope's
;; place also needs the HOST's. `live-willingness-of` reads the standing
;; consent; `consented-span-of` is `live-span-of` with the gate applied — the
;; view a caller feeds to #:span-of when it can say whose place a place is.

(define* (live-willingness-of store #:optional (now #f))
  "The live hosting consents in STORE, as (((scope-aid . spec) . ceiling) …) —
   the same pair-key style as the capacity cells. Read through the one live-
   credential idiom every view here starts from (`%live-by-schema`)."
  (filter-map
   (lambda (c)
     (let ((spec (cred-claim c 'resource-spec))
           (ceil (cred-claim c 'ceiling)))
       (and spec (number? ceil)
            (cons (cons (cred-holder c) spec) ceil))))
   (%live-by-schema store *schema-playnet-hosting-willingness* now)))

(define* (consented-span-of store #:key (place-scope-of #f) (spec-of #f)
                                   (rights-of #f) (uc-aid #f) (now #f))
  "`live-span-of`, gated by consent: a declaration whose span-place belongs to
   ANOTHER scope passes only while that scope holds live willingness (ceiling
   > 0) for the resource's spec; dropped, the pool stands at the holding place
   — refusal is the default, never an event.

   PLACE-SCOPE-OF (place → scope-aid or #f) says whose place a place is, and
   SPEC-OF (resource-id → spec) what a declaration is over — both INJECTED,
   like demand-fold's home-of, because only the caller knows the scope graph.
   Either absent ⇒ the gate cannot be asked and every declaration passes,
   which is `live-span-of` — today's behaviour, stated rather than implied.
   A scope's own places need no consent: the steward spanning within its own
   walls is the case that always worked.

   STANDING (patchwork §4a, 'span authority follows rights'): with RIGHTS-OF
   (resource-id → owner aid | 'common | #f) supplied, a declaration passes only
   from the resource's rights-holder — the owner for an offered means; for a
   COMMON means only UC-AID itself, universal governance being the sole body
   with standing over what is everyone's. #f rights = unknown = ungated
   (today's behaviour, stated). The standing gate runs before consent: a
   declaration nobody was entitled to make needs no host to refuse it.

   This slice gates on CONSENT EXISTING; the ceiling's QUANTITY binds at
   placement, where there is a number to hold it against."
  (let* ((standing? (lambda (rid steward)
                      (if (not rights-of) #t
                          (let ((r (rights-of rid)))
                            (cond ((not r) #t)                      ; unknown: ungated
                                  ((eq? r 'common) (and uc-aid (equal? steward uc-aid)))
                                  (else (equal? steward r)))))))
         ;; standing filters BEFORE the per-resource dedup (inside
         ;; %live-span-decls), so an entitled declaration cannot be shadowed
         ;; by a stranger's — the test that found this is §5 of
         ;; test-hosting-willingness.
         (decls (%live-span-decls store now
                                  (lambda (d) (standing? (car d) (caddr d))))))
    (if (not (and place-scope-of spec-of))
        (map (lambda (d) (cons (car d) (cadr d))) decls)
        (let ((willing (live-willingness-of store now)))
          (filter-map
           (lambda (d)                            ; (resource-id place issuer)
             (let* ((rid (car d)) (at (cadr d)) (steward (caddr d))
                    (host (place-scope-of at)))
               (and (or (not host)                ; a place no scope claims: open ground
                        (equal? host steward)     ; the steward's own walls
                        (let ((ceil (assoc-ref willing (cons host (spec-of rid)))))
                          (and (number? ceil) (> ceil 0))))
                    (cons rid at))))
           decls)))))

