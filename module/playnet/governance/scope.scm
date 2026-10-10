;;; scope.scm — unified governance scope actor
;;;
;;; A `^scope` is a group AID with members + acdc-store + governance
;;; methods. The `kind` field specializes:
;;;
;;;   'commune    — members are citizen AIDs; wraps an economic ^scope-root
;;;                 (planner substrate). Has member-seal for member-gated ops.
;;;   'federation — members are scope-AIDs (sub-scopes); no scope-root.
;;;                 Sub-scopes can themselves be communes OR federations
;;;                 (recursive composition).
;;;
;;; Recomposition is first-class: scopes can merge, split, or rejoin
;;; different parents. Each recomposition emits an ACDC; lineage tracks
;;; ancestor scopes so a recomposed scope can recover its history.
;;;
;;; Free composition: scopes compose without pre-emption. Two scopes with
;;; overlapping plans can both join a federation; the resulting overlap is
;;; surfaced via `detect-commitment-conflicts` (a deliberation surface,
;;; not a planning error).
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


;; ── Phase-6 ratification helpers ────────────────────────────────────────────
;;
;; A recomposition method, when called with `'ratification SAID`, runs
;; `verify-ratification!` to confirm the SAID points at a valid
;; recomposition-ratification ACDC matching the proposal-type and
;; proposal-spec. The method then attaches a `ratification` NI2I edge
;; to the emitted recomposition ACDC via `ratification-edges`. When
;; ratification is absent the helpers no-op (returning '()), preserving
;; the genesis path; the auditor flags post-genesis recomp ACDCs that
;; lack the edge (see structural-invariants.scm).

(define-module (playnet governance scope)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet governance root-lineage)   ; a scope recomposes, so its lineage walk loads with it
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials custody)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module ((playnet governance sturdyref-credential) #:select (sturdyref-credentials->spec census-credential-goods census-key-state *schema-playnet-federation-census* *schema-playnet-federation-sturdyref*))
  #:use-module ((playnet keri key-state) #:select (state-sn state-said rotation-count))
  #:use-module ((playnet governance debts) #:select (debt-commitment))
  #:use-module ((playnet governance socialization)
                #:select (member-consume-grant-total member-consume-grant-over))
  #:use-module (playnet keri signify-portable)
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module (playnet keri said-portable)
  #:use-module (playnet governance scope-graph)
  #:use-module (playnet utils paths)
  #:use-module (playnet vf facts validity)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet governance acdc-bridge)
  #:use-module (playnet keri citizen-sig)
  #:use-module (playnet keri inception)
  #:use-module (playnet keys peers)
  #:use-module (playnet org endorsement)
  #:use-module (playnet keri acdc-store)
  #:use-module (playnet governance async)
  #:use-module (playnet governance ballot)
  #:use-module (playnet governance governance-policy)
  #:use-module (playnet utils governed-row)
  #:use-module ((playnet governance attestation-ceremony)
                #:select (^attestation-ceremony register-attestation-ceremony!))
  #:use-module (playnet keys exchange)
  #:use-module (playnet identity enrollment)
  #:use-module (playnet keys kel-store)
  #:use-module (playnet keys bran-custody)
  #:use-module (goblins ocapn ids)
  #:use-module (srfi srfi-11)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (any-cred-by-said verify-ratification! require-ratification! may-govern?
            verify-parent-ratification!
            federation-memberships-of federation-memberships-of-holder
            resolve-merge-ratifier ratification-edges stale-membership-edges
            do-anchor-best-effort do-anchor-acdc-into-kel! also-push-to-uc!
            kel-identifier register-rotation-keypair-fn! rotation-keypair-fn
            *scope-brands* find-vat-brand ^brand-marker ensure-scope-brand!
            current-scope-brand verify-scope! ^scope *spec-generalizations*
            register-spec-generalization! clear-spec-generalizations! spawn-scope
            split-scope-with-aids open-recomposition-ballot scope-env))

(define (any-cred-by-said store said)
  "Find a credential by SAID across all schemas; #f if not present.
   Used by verify-ratification! since the ratification's schema is
   what we're verifying — we can't pre-filter by it."
  (find (lambda (c) (equal? said (cred-said c)))
        ($ store 'all)))

(define (verify-ratification! store target-aid ratification-said
                              expected-type expected-spec)
  "Fail-closed verification of a recomposition-ratification ACDC.
   STORE:        ACDC store
   TARGET-AID:   the affected scope's AID — for admit-commune this is
                 the commune being admitted (whose contributors bound
                 by the new federation rules); for merge-with, split,
                 rejoin-federation it is the invoking scope itself.
   RATIFICATION-SAID: SAID supplied by the caller.
   EXPECTED-TYPE / EXPECTED-SPEC: what the method-args canonicalize to.

   The ratification credential must be self-issued by the target —
   i.e. cred-issuer = TARGET-AID. This locates consent at the scope
   whose contributors are actually bound, not at the executor.

   Errors with explicit messages on every failure mode."
  (unless store
    (error "ratification supplied but no acdc-store" target-aid))
  (let ((cred (any-cred-by-said store ratification-said)))
    (unless cred
      (error "ratification SAID not in store" ratification-said))
    (when (cred-revoked? cred)
      (error "ratification revoked" ratification-said))
    (unless (equal? *schema-playnet-recomposition-ratification*
                    (cred-schema cred))
      (error "ratification: wrong schema" (cred-schema cred)))
    (unless (equal? target-aid (cred-issuer cred))
      (error "ratification: not self-issued by target scope"
             target-aid (cred-issuer cred)))
    (unless (eq? expected-type (cred-claim cred 'proposal-type))
      (error "ratification: mismatched-proposal type"
             expected-type (cred-claim cred 'proposal-type)))
    (unless (equal? expected-spec (cred-claim cred 'proposal-spec))
      (error "ratification: mismatched-proposal spec"
             expected-spec (cred-claim cred 'proposal-spec)))
    (unless (cred-claim cred 'threshold-met?)
      (error "ratification: threshold not met" ratification-said))
    #t))

;; ── Self-governed authority: WHO may mint a gov-cap for THIS scope ──────────
;; Lives with mint-gov-cap itself, not at whichever call site remembers to
;; check first — the same shape monero/policy.scm's ^wallet-policy governs
;; spend from INSIDE the wallet, never re-checked at the RPC layer that
;; happens to call it. Every caller — the gateway, a future one, a test —
;; gets this for free, and none can bypass it by reaching mint-gov-cap
;; directly.
;;
;; A commune's own recognised persons (holds-live-phc?, first-person.scm)
;; are the minimum-viable signal available today — NOT the doctrinally
;; precise one (docs/playnet.typ, Citizenship: a production-governance act
;; answers to PRODUCER VOICE, grounded in labour actually contributed to
;; THIS scope, never to personhood alone). Fails open before THIS scope's
;; own first PHC — ecosystem-personhood-bootstrapped? is scoped to
;; SCOPE-AID, deliberately not the store-wide personhood-bootstrapped?,
;; whose use here would let one commune's bootstrap slam shut every OTHER
;; commune's open window the instant they share an acdc-store (the exact
;; bug fp-grant, service.scm, had until fixed alongside this).
;;
;; Federation/UC-kind scopes: their `members` are OTHER SCOPES (commune-
;; refs), which admit-commune-remote can make a genuinely remote sturdyref.
;; `$` only ever works on a near-refr? — a far ref (cross-vat, in-process
;; or over the network alike) makes `$` THROW ("Not in the same vat"),
;; synchronously and immediately, never hang or silently hand back an
;; unusable promise (Goblins: `$` is the near-only operator; a far ref
;; needs `<-`). So `false-if-exception` around each member's `scope-aid`
;; is the whole fix, not a CPS/on-> rewrite: a near member resolves and
;; counts normally; a far one throws, is caught, and simply doesn't count
;; toward eligibility THIS turn — safe-by-construction (a citizen of an
;; unreachable member commune is conservatively excluded, never wrongly
;; admitted) and still fully synchronous, so mint-gov-cap's return type
;; and every existing caller are untouched.
(define (may-govern? kind scope-aid acdc-store holder-aid members)
  (cond
   ((not acdc-store) #t)
   ((eq? kind 'commune)
    (or (not (ecosystem-personhood-bootstrapped? acdc-store scope-aid))
        (holds-live-phc? acdc-store scope-aid holder-aid)))
   ((memq kind '(federation universal-commune))
    (let ((communes (hashmap-fold (lambda (_k v acc) (cons v acc)) '() members))
          ;; the federation's OWN people, as a commune's: open while it has
          ;; recognised nobody, then those it has. A federation whose members
          ;; are all remote has no near commune to read, and this is what
          ;; closes it once it has a founder; with near members it is one more
          ;; way to be recognised.
          (own-open? (not (ecosystem-personhood-bootstrapped? acdc-store scope-aid)))
          (own? (holds-live-phc? acdc-store scope-aid holder-aid)))
      (or (and (null? communes) own-open?)
          own?
          (any (lambda (commune-ref)
                 (let ((commune-aid (false-if-exception ($ commune-ref 'scope-aid))))
                   (and commune-aid
                        ;; a member commune that hasn't recognised anyone of
                        ;; its OWN yet is open, exactly the commune-branch
                        ;; reasoning above, applied per member — a caught
                        ;; test bug: without this, admitting the FIRST
                        ;; member commune (still unbootstrapped itself)
                        ;; would close the federation's own open window.
                        (or (not (ecosystem-personhood-bootstrapped? acdc-store commune-aid))
                            (holds-live-phc? acdc-store commune-aid holder-aid)))))
               communes))))
   (else #t)))

(define (require-ratification! scope-root-ref store target-aid ratification-said
                               expected-type expected-spec)
  "The gate every ratification-accepting act (admit-commune, merge-with,
   split, rejoin-federation, accept-socialization, accept-reimbursement)
   calls in place of a bare `(when ratification-said (verify-ratification!
   ...))`. When RATIFICATION-SAID is supplied it is verified exactly as
   before. When it is absent, the act is refused if THIS scope's own
   governance-policy (governance-policy.scm) has set `require-ratification`
   — read fresh off SCOPE-ROOT-REF's plan-store, defaulting to #f (today's
   behaviour) when the scope has no economic root or has never opted in."
  (cond
   (ratification-said
    (verify-ratification! store target-aid ratification-said
                          expected-type expected-spec))
   ;; governance-policy already tolerates a #f plan-store (defaults #f);
   ;; the only thing worth guarding here is a #f scope-root-ref itself,
   ;; which can't be $-messaged at all.
   ((and scope-root-ref
         (governance-policy ($ scope-root-ref 'plan-store) 'require-ratification))
    (error "ratification required by this scope's governance policy"
           expected-type expected-spec))))

(define (verify-parent-ratification! store parent-aid
                                      expected-predecessors
                                      expected-successor-spec
                                      ratification-said
                                      expected-type expected-spec)
  "Bottom-up verification (democracy-on-keri.md §4.3): the ratification
   ACDC must have been issued by PARENT-AID (a federation parent or the
   Universal Commune), name EXPECTED-PREDECESSORS in its `predecessors`
   claim, and describe EXPECTED-SUCCESSOR-SPEC in its `successor-spec`
   claim. Distinct from `verify-ratification!` (legacy self-issued)
   because here the issuer is the parent, not the affected scope, and
   the ratification predates the successor's existence — so it cannot
   be self-attested.

   Errors with explicit messages on every failure mode."
  (unless store
    (error "parent ratification supplied but no acdc-store" parent-aid))
  (let ((cred (any-cred-by-said store ratification-said)))
    (unless cred
      (error "parent ratification SAID not in store" ratification-said))
    (when (cred-revoked? cred)
      (error "parent ratification revoked" ratification-said))
    (unless (equal? *schema-playnet-recomposition-ratification*
                    (cred-schema cred))
      (error "parent ratification: wrong schema" (cred-schema cred)))
    (unless (equal? parent-aid (cred-issuer cred))
      (error "parent ratification: not issued by claimed parent"
             parent-aid (cred-issuer cred)))
    (unless (eq? expected-type (cred-claim cred 'proposal-type))
      (error "parent ratification: mismatched proposal type"
             expected-type (cred-claim cred 'proposal-type)))
    (unless (equal? expected-spec (cred-claim cred 'proposal-spec))
      (error "parent ratification: mismatched proposal spec"
             expected-spec (cred-claim cred 'proposal-spec)))
    (unless (equal? expected-predecessors
                    (cred-claim cred 'predecessors))
      (error "parent ratification: predecessors mismatch"
             expected-predecessors (cred-claim cred 'predecessors)))
    (unless (equal? expected-successor-spec
                    (cred-claim cred 'successor-spec))
      (error "parent ratification: successor-spec mismatch"
             expected-successor-spec
             (cred-claim cred 'successor-spec)))
    (unless (cred-claim cred 'threshold-met?)
      (error "parent ratification: threshold not met" ratification-said))
    #t))

;; ── Multi-parent helpers (democracy-on-keri.md §4.3 follow-up) ─────────────
;;
;; A scope can be a child of multiple federations simultaneously
;; (rules.md). When two scopes recompose, we need to know: who are their
;; current parents? Is there a unique shared parent that should ratify?
;; Or do we fall back to the Universal Commune?
;;
;; Previous parents that are NOT the ratifier become "stale-membership"
;; observers: their `federation-membership` ACDCs for the now-dissolved
;; predecessor remain on their TEL until they revoke. The merger ACDC
;; carries NI2I edges to those stale memberships so observing parents
;; can find them.

(define (federation-memberships-of store scope-aid)
  "Return a list of (parent-aid . membership-said) pairs for every live
   playnet-federation-membership/v1 ACDC whose holder = SCOPE-AID."
  (if store
      (filter-map
       (lambda (c)
         (and (not (cred-revoked? c))
              (cons (cred-issuer c) (cred-said c))))
       ($ store 'by-schema *schema-playnet-federation-membership*))
      '()))

(define (federation-memberships-of-holder store scope-aid)
  "Like federation-memberships-of but additionally filters by holder.
   `by-schema` returns all federation-membership ACDCs in the store; we
   only want those naming SCOPE-AID as their holder."
  (if store
      (filter-map
       (lambda (c)
         (and (not (cred-revoked? c))
              (equal? scope-aid (cred-holder c))
              (cons (cred-issuer c) (cred-said c))))
       ($ store 'by-schema *schema-playnet-federation-membership*))
      '()))

(define (resolve-merge-ratifier store-a a-aid store-b b-aid uc-aid)
  "Given the federation memberships of A and B, decide who ratifies
   their merge. Returns (values ratifier-aid ratifier-source stale-saids)
   where:

     ratifier-aid   = the chosen parent's AID (or UC AID)
     ratifier-source = 'shared-parent | 'multiple-shared | 'universal-commune
     stale-saids    = list of membership SAIDs of A's and B's
                      memberships that point at parents OTHER than the
                      chosen ratifier — these become stale once C exists.

   When A and B share exactly one parent, that parent ratifies. When they
   share multiple, the aggregating parent (scope-graph.scm's one rule: the
   smallest AID) ratifies and the rest are recorded as stale (caller may
   want to disambiguate).
   When they share none, UC ratifies.

   Reasoning per docs/governance/democracy-on-keri.md §4.3 follow-up:
   previous parents have observation rights and bookkeeping duties, not
   ratification authority. The choice of \"where C lives\" is itself a
   recomposition input."
  (let* ((a-memberships (federation-memberships-of-holder store-a a-aid))
         (b-memberships (federation-memberships-of-holder store-b b-aid))
         (a-parents     (map car a-memberships))
         (b-parents     (map car b-memberships))
         (shared        (lset-intersection equal? a-parents b-parents))
         (chosen        (or (aggregating-parent shared) uc-aid))
         (source        (cond
                         ((null? shared)        'universal-commune)
                         ((null? (cdr shared))  'shared-parent)
                         (else                  'multiple-shared)))
         ;; Stale = every membership of A or B whose parent ≠ chosen.
         (stale-saids
          (append
           (filter-map (lambda (m)
                         (and (not (equal? (car m) chosen))
                              (cdr m)))
                       a-memberships)
           (filter-map (lambda (m)
                         (and (not (equal? (car m) chosen))
                              (cdr m)))
                       b-memberships))))
    (values chosen source stale-saids)))

(define (ratification-edges ratification-said)
  "Build the edges-list to attach to a recomposition ACDC. When
   RATIFICATION-SAID is #f returns '(); otherwise returns a single
   ratification edge (NI2I → recomposition-ratification schema)."
  (if ratification-said
      (list (cons 'ratification
                  (make-edge ratification-said
                             #:operator 'NI2I
                             #:schema *schema-playnet-recomposition-ratification*)))
      '()))

(define (stale-membership-edges stale-membership-saids)
  "Build a list of NI2I edges, one per now-stale federation-membership
   ACDC, to attach to a recomposition (merger / split / rejoin) ACDC.
   Parents observing the recomposition can use these edges to find the
   federation-membership ACDCs they need to revoke on their own TEL.

   Edge labels are 'stale-membership-1, 'stale-membership-2, … so the
   merger ACDC's edges block remains valid even with multiple stale
   memberships."
  (let loop ((saids stale-membership-saids) (i 1) (acc '()))
    (cond
     ((null? saids) (reverse acc))
     (else
      (let ((label (string->symbol
                    (string-append "stale-membership-"
                                   (number->string i)))))
        (loop (cdr saids) (+ i 1)
              (cons (cons label
                          (make-edge (car saids)
                                     #:operator 'NI2I
                                     #:schema *schema-playnet-federation-membership*))
                    acc)))))))


;; ── KEL anchoring helper (extracted from ^scope 'anchor-acdc) ──────────────
;;
;; OOBI.md §3.2.1 (KEL-Anchored Updates): a credential's SAID anchored
;; into the issuer's KEL via an ixn event is strictly stronger than
;; signed-not-anchored (§3.2.2). Receivers can verify "issuer's KEL
;; commits to this credential at sequence N" — the issuer can't
;; repudiate without forking the chain (which witnesses would catch).
;;
;; Two callers: the 'anchor-acdc method (strict, errors on missing
;; primitives) and the 'anchor-acdc/best-effort method (silent skip).
;; admit-commune et al. invoke best-effort right after issuance.

(define (kel-identifier kel-store scope-aid)
  "The identifier the scope's key event log is OF: the `i` of its inception.
   A scope is known by the key it incepted with (SCOPE-AID, a D prefix) while
   the log it keeps names itself by the SAID of its inception (an E prefix), and
   every event after the inception carries that second one — so the log chains
   for a verifier who holds nothing but the log (keri/key-state.scm). SCOPE-AID
   answers while the log is empty (synthetic scopes)."
  (let* ((first (and kel-store (positive? ($ kel-store 'count)) ($ kel-store 'first)))
         (icp (and first (assoc-ref first "icp"))))
    (or (and icp (assoc-ref icp "i")) scope-aid)))

;; The keys a scope will sign with after its next rotations are derived from its
;; bran, and the actor never holds the bran. Whoever spawns the scope with one
;; registers here the function that derives the keypair at rotation index N
;; (`bran->rotation-keypair`), so the key a rotation commits to as the NEXT is
;; the one a restart derives again, and the scope can rotate after a restart.
;; Held beside the actor like the bran's vault and read by `rotate-keys` alone.
(define %rotation-keypair-fns (make-hash-table))
(define (register-rotation-keypair-fn! scope-aid fn) (hash-set! %rotation-keypair-fns scope-aid fn))
(define (rotation-keypair-fn bran-bv)
  "The function N → the keypair at rotation index N, from the bran BRAN-BV."
  (let ((bran-str (bv->hex bran-bv)))
    (lambda (n) (bran->rotation-keypair bran-str n))))

(define (do-anchor-best-effort kel-store scope-aid keypair target-said)
  "Anchor TARGET-SAID into kel-store via ixn when all primitives are
   present (kel-store + keypair + non-empty KEL); silently return #f
   otherwise. The right call from issuance paths (admit-commune,
   ratify-recomposition!) where synthetic / test mode is common and
   shouldn't crash."
  (and kel-store keypair target-said
       (positive? ($ kel-store 'count))
       (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said)))

(define (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said)
  "Build + sign an ixn event with TARGET-SAID as a digest seal; append
   to kel-store. Returns the ixn's SAID. Caller verifies kel-store
   non-empty, keypair non-#f."
  (let* ((latest    ($ kel-store 'latest))
         (prior-said
          (let ((inner (or (assoc-ref latest "icp")
                           (assoc-ref latest "rot")
                           (assoc-ref latest "ixn"))))
            (and inner (assoc-ref inner "d"))))
         (next-seq  ($ kel-store 'count))
         (anchors   (list (list (cons "d" target-said)))))
    (call-with-values
      (lambda ()
        (build-ixn (kel-identifier kel-store scope-aid) prior-said
                   #:sn next-seq #:anchors anchors))
      (lambda (ixn-json ixn-said ixn-alist)
        (let* ((sig  (sign-event ixn-json keypair))
               (body (list (cons "name" (string-append "scope-" scope-aid))
                           (cons "ixn"  ixn-alist)
                           (cons "sigs" (vector sig)))))
          ($ kel-store 'append body)
          ixn-said)))))


;; ── Phase-6 cross-gateway visibility helper ────────────────────────────────
;;
;; When this gateway federates with a Universal Commune (env var
;; PLAYNET_UC_AID set), also push membership credentials to UC's AID
;; so UC observers see the parent edge via inbound IPEX rather than
;; polling. No-op for standalone gateways. The (not (equal? uc target))
;; guard prevents a double-grant if UC happens to BE the target — same
;; SAID being granted twice is wasted bandwidth, not a bug.

(define* (also-push-to-uc! scope-aid keypair membership-said target-aid
                           #:key (acdc-store #f))
  (let ((uc (known-uc-aid)))
    (when (and uc membership-said (not (equal? uc target-aid)))
      (scope-deliver-grant! scope-aid keypair membership-said uc
                            #:acdc-store acdc-store))))


;; ── Scope brand ─────────────────────────────────────────────────────────────
;;
;; Sealer triplets that let us verify a ref is a real ^scope rather than
;; duck-typing on 'scope-aid / 'name. Without this, any actor that responds
;; to those messages can be fed to merge-with / admit-commune and forge a
;; counterparty AID (type confusion at the capability surface).
;;
;; A brand triplet is per-vat: each vat that spawns a scope lazily mints
;; one (the actors must live in the vat that calls them with `$`). All
;; scopes within a vat share that vat's triplet, so they can sync-verify
;; each other. Cross-vat verification would require `<-`; for now the
;; methods that use brand checks (merge-with, admit-commune) are sync and
;; therefore inherently same-vat.
;;
;; Indexed by (refr-equal-on-vat) using the *scope-brand-marker* identity:
;; we spawn a fresh marker per vat and use object identity to find it.

(define *scope-brands* '())  ;; alist: marker-ref → (sealer . sealed?)

(define (find-vat-brand)
  ;; Return (sealer . sealed?) for the current vat, or #f if not yet minted.
  ;; Detects current vat by trying to call each known marker with `$` —
  ;; only the one in our vat will succeed (others throw cross-vat errors).
  (let loop ((entries *scope-brands*))
    (cond
      ((null? entries) #f)
      (else
       (let* ((entry (car entries))
              (marker (car entry))
              (works? (catch #t
                        (lambda () ($ marker 'ping) #t)
                        (lambda _ #f))))
         (if works? (cdr entry) (loop (cdr entries))))))))

(define-actor (^brand-marker bcom)
  (methods
    [(ping) 'pong]))

(define (ensure-scope-brand!)
  (unless (find-vat-brand)
    (let ((marker (spawn ^brand-marker)))
      (call-with-values make-endorsement-authority
        (lambda (s _u sd?)
          (set! *scope-brands*
                (cons (cons marker (cons s sd?)) *scope-brands*)))))))

(define (current-scope-brand)
  (or (find-vat-brand)
      (error "current-scope-brand: brand not initialized in this vat")))

(define (verify-scope! ref where)
  "Confirm REF is a real ^scope by asking it for a brand-token sealed
   under the current vat's scope brand. Errors with WHERE on failure."
  (let* ((brand   (current-scope-brand))
         (sealed? (cdr brand))
         (tok (catch #t
                (lambda () ($ ref 'scope-brand-token))
                (lambda _ #f))))
    (unless (and tok ($ sealed? tok))
      (error where "ref is not a ^scope" ref))))


;; The censuses a store holds that were told to FEDERATION-AID — a store is shared
;; by every scope of a gateway, so a commune that tells two federations holds
;; one census for each, and each federation reads only its own. MEMBER narrows
;; to the censuses that commune issued.
(define* (censuses-told-to acdc-store federation-aid #:optional (member #f))
  (filter (lambda (c) (and (equal? (cred-holder c) federation-aid)
                           (or (not member) (equal? (cred-issuer c) member))))
          ($ acdc-store 'by-schema *schema-playnet-federation-census*)))

(define-actor (^scope bcom
                      name
                      kind                  ;; 'commune | 'federation | 'universal-commune
                      scope-aid             ;; AID string
                      members               ;; hashmap member-id → ref-or-#f
                      member-sturdyrefs     ;; hashmap (federation-only)
                      excluded              ;; hashmap (commune-only)
                      ballots               ;; hashmap proposal-id → ballot-ref
                      commune-stances       ;; hashmap (federation-only)
                      gov-seal       gov-sealed?
                      planning-seal  planning-sealed?
                      delegate-seal  delegate-sealed?
                      member-seal    member-sealed?  ;; nullable for federations
                      acdc-store
                      mycapn-ref            ;; for federation sturdyref resolution
                      scope-root-ref        ;; for commune economic substrate
                      lineage               ;; list of ancestor scope-AIDs
                      keri-backend          ;; alist for live KERI; #f = synthetic
                      keypair               ;; scope's own Ed25519 keypair, host-isolated; #f = synthetic
                      next-keypair          ;; pre-rotated next keypair; #f = synthetic
                      kel-store)            ;; ^kel-store actor ref; #f = synthetic
  #:version 4

  (define (rebuild new-members new-excluded new-ballots new-commune-stances
                   new-member-sturdyrefs new-mycapn-ref
                   new-acdc-store new-lineage)
    (^scope bcom name kind scope-aid
            new-members new-member-sturdyrefs new-excluded
            new-ballots new-commune-stances
            gov-seal gov-sealed?
            planning-seal planning-sealed?
            delegate-seal delegate-sealed?
            member-seal member-sealed?
            new-acdc-store new-mycapn-ref scope-root-ref new-lineage
            keri-backend keypair next-keypair kel-store))

  ;; First-Person re-anchoring: when admission opts in with
  ;; 'authorize-issuer, bless the commune as an authorized PHC issuer under
  ;; this scope (its root), so the commune's PHCs chain here. Economic
  ;; membership and personhood-issuer trust are DISTINCT grants (hence
  ;; opt-in); this is the single growth-time hook — a new commune joining
  ;; and a recomposed commune re-joining both flow through it. The AIC must
  ;; be signed by the root, which only this federation controls.
  ;; The SAID of the live Authorized-Issuer Credential blessing THIS scope
  ;; (holder == scope-aid), or #f. Attached as the `issuer-authz` edge on PHCs
  ;; the scope issues, so they chain to root STRUCTURALLY — end-verifiable
  ;; from the PHC alone, no registry lookup at the verifier. #f when the scope
  ;; holds no blessing yet (self-rooted-but-unblessed); the registry and
  ;; self-root paths still recognise it, so this only strengthens, never gates.
  (define (scope-own-aic-said)
    (and acdc-store
         (let ((aic (find (lambda (c)
                            (and (equal? (cred-holder c) scope-aid)
                                 (cred-live-at? c (current-time))))
                          ($ acdc-store 'by-schema
                             *schema-playnet-authorized-issuer*))))
           (and aic (cred-said aic)))))

  (define (maybe-authorize-issuer! commune-aid admitted-at opts)
    (when (and acdc-store (kw-ref opts 'authorize-issuer #f))
      (let ((aic-said
             ($ acdc-store 'issue
                (make-authorized-issuer-credential
                  scope-aid commune-aid admitted-at
                  #:signing-keypair keypair))))
        (do-anchor-best-effort kel-store scope-aid keypair aic-said)
        (scope-deliver-grant!  scope-aid keypair aic-said commune-aid
                               #:acdc-store acdc-store))))

  ;; ── Custody helpers (closures over scope state) ──────────────────────────
  ;; Defined outside (methods) so transfer-custody can call them by name
  ;; rather than re-dispatching through the actor surface; thin method
  ;; wrappers below expose them externally too.

  (define (live-custody-attestations)
    ;; live by each attestation's OWN terms — non-revoked AND in-window
    ;; (custody-cred-live?, THE law). Filtering revocation alone left an
    ;; EXPIRED grant standing to transfer-custody's supersede path until
    ;; the half-life watcher swept; the watcher only dates the reversion.
    (if acdc-store
        (filter (lambda (c) (and (equal? scope-aid (cred-holder c))
                                 (custody-cred-live? c)))
                (non-revoked-by-schema acdc-store
                                       *schema-playnet-custody-attestation*))
        '()))

  (define (custody-attestation-for resource-spec)
    (and acdc-store
         (find (lambda (c)
                 (equal? resource-spec (cred-claim c 'resource-spec)))
               (live-custody-attestations))))

  (define (commitment-fulfilled? commitment-said)
    ;; True iff a non-revoked fulfillment ACDC referencing this
    ;; commitment SAID exists. Receiver-attested rather than self-flag,
    ;; so a captured provider can't unilaterally mark its commitments
    ;; finished to escape the orphan check.
    (and acdc-store
         (any (lambda (f)
                (and (not (cred-revoked? f))
                     (equal? commitment-said
                             (cred-claim f 'commitment-said))))
              ($ acdc-store 'by-schema
                 *schema-playnet-commitment-fulfillment*))))

  (define (spec-matches? commitment-spec target-spec)
    ;; True iff TARGET-SPEC is the same as or a generalization of
    ;; COMMITMENT-SPEC. For now, exact match; spec-hierarchy
    ;; resolution (walking resource-classified-as) is registered via
    ;; *spec-generalizations* below for callers that need it.
    (or (equal? commitment-spec target-spec)
        (member target-spec
                (hash-ref *spec-generalizations* commitment-spec '()))))

  (define (outstanding-commitments-of-spec resource-spec)
    (if acdc-store
        (filter (lambda (c)
                  (and (not (cred-revoked? c))
                       (equal? *schema-playnet-commitment* (cred-schema c))
                       (spec-matches? (cred-claim c 'resource-conforms-to)
                                      resource-spec)
                       (not (commitment-fulfilled? (cred-said c)))))
                ($ acdc-store 'by-issuer scope-aid))
        '()))

  (methods

    ;; --- Identity ---
    ((name) name)
    ((kind) kind)
    ((scope-aid) scope-aid)
    ((scope-brand-token)
     ;; Returns a token sealed by the current vat's scope brand. Only real
     ;; ^scope instances in this vat can produce one that passes
     ;; verify-scope! (which uses the same vat's sealed? predicate).
     ($ (car (current-scope-brand)) scope-aid))
    ((commune-aid) scope-aid)        ;; alias for commune-style callers
    ((federation-aid) scope-aid)     ;; alias for federation-style callers
    ((acdc-store) acdc-store)
    ((scope-root) scope-root-ref)
    ((mycapn-ref) mycapn-ref)
    ((lineage) lineage)
    ((kel-events) (if kel-store ($ kel-store 'all) '()))
    ((kel-store)  kel-store)
    ((has-keypair?) (and keypair #t))
    ;; Durable mode: when this scope owns a disk-backed acdc-store, the
    ;; canonical state directory is <state>/scopes/<aid>/. Returns #f when
    ;; the scope is in-memory only (test mode). Useful for rsync /
    ;; Syncthing / Radicle sync of a scope's portable state.
    ((state-dir)
     (and acdc-store (scope-state-dir scope-aid)))

    ;; --- Autonomous-signer signing surface (democracy-on-keri.md §4.1) ---
    ;;
    ;; The scope's keypair lives only in this actor's bcom state and is
    ;; never exported by any method. Callers ask the scope to sign a SAID
    ;; (or a credential's SAID); the scope produces a CESR-qb64 signature
    ;; using its own keys. The legitimacy of the signature is "the scope's
    ;; methods executed and produced it," not "this quorum signed."
    ((sign-said said-string)
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     (sign-said said-string keypair))

    ;; --- Pillar D: cross-gateway ratification delivery ---
    ;;
    ;; When the UC (or any other federation acting as ratifier) wants
    ;; to push a recomposition-ratification ACDC to a remote
    ;; predecessor, it asks its OWN scope ref to deliver-grant! so
    ;; the keypair stays inside this actor's bcom — never exported.
    ;; Wraps scope-deliver-grant!'s best-effort logic (no-op in
    ;; synthetic mode or when KERIA is unreachable; entry lands in
    ;; pending-grants for retry on success).
    ((deliver-grant! cred-said holder-aid)
     (scope-deliver-grant! scope-aid keypair cred-said holder-aid
                           #:acdc-store acdc-store))

    ;; --- §4.6: anchor an ACDC SAID into the scope's KEL ---
    ;;
    ;; Builds a signed interaction (ixn) event with one digest-seal
    ;; pointing at TARGET-SAID, appends it to the kel-store. Witnesses
    ;; receive the new event via the existing async-broadcast path.
    ;; Returns the SAID of the new ixn event.
    ;;
    ;; Used by ballot-open and tally-close to commit ballot ACDCs into
    ;; the scope's KEL chain so a verifier walking the chain sees the
    ;; ballots in cryptographic order, not just the acdc-store's
    ;; unordered set.
    ((anchor-acdc target-said)
     ;; Strict-mode anchor: errors if keypair or kel-store are missing.
     ;; Use 'anchor-acdc/best-effort for the silent-skip variant.
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     (unless kel-store
       (error "scope has no kel-store" name))
     (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said))

    ((anchor-acdc/best-effort target-said)
     ;; OOBI.md §3.2.1 KEL-Anchored Updates pattern. Called after every
     ;; credential issuance so receivers can verify "issuer's KEL
     ;; commits to this credential's SAID at sequence N" — strictly
     ;; stronger than signed-not-anchored (§3.2.2). When the scope is
     ;; synthetic (no keypair) or has no kel-store (test mode, in-memory
     ;; scope), silently returns #f. Production scopes always have both.
     (cond
      ((and keypair kel-store (positive? ($ kel-store 'count)))
       (do-anchor-acdc-into-kel! kel-store scope-aid keypair target-said))
      (else #f)))

    ;; --- Key rotation ---
    ;; Rotate to the pre-committed next-keypair, derive a fresh
    ;; next-keypair, and append a signed rot event to the kel-store. The
    ;; previous keypair becomes unrecoverable from outside the actor.
    ;; rest-args carries optional #:anchors — a list of seal alists
    ;; ((d . SAID) (s . schema) ...) folded into the rot event's `a`
    ;; block per KERI §2 (anchored seals). UC's curator uses this to
    ;; anchor a digest of the member-set on every rotation, giving
    ;; observers a verifiable trail of who-was-in-UC-when without
    ;; bloating the KEL with the full membership.
    ((rotate-keys . rest-args)
     (unless keypair
       (error "scope has no keypair (synthetic mode)" name))
     ;; A real rot event chains to the prior KEL event's own SAID (icp, or
     ;; the last rot) — spawn-scope's own contract is that a real KEYPAIR
     ;; always comes with a KEL-STORE (either supplied or minted alongside
     ;; it at inception), so this is an invariant violation, not a mode
     ;; this method degrades gracefully for.
     (unless kel-store
       (error "scope has a keypair but no kel-store — cannot rotate without a KEL to chain from" name))
     (let* ((anchors    (let loop ((r rest-args))
                          (cond
                           ((null? r) '())
                           ((eq? (car r) #:anchors) (cadr r))
                           (else (loop (cddr r))))))
            (new-kp     next-keypair)
            (next-seq   ($ kel-store 'count))
            ;; the key this rotation commits to as the next: derived from the bran at
            ;; the index after the one it reveals, when the scope's spawner registered
            ;; how, so a restart finds it again; fresh entropy otherwise, which is
            ;; only in this actor's state until the next rotation
            (rotations  (rotation-count ($ kel-store 'all)))
            (derive     (hash-ref %rotation-keypair-fns scope-aid #f))
            (new-nkp    (if derive
                            (derive (+ rotations 2))
                            (keri-identity-keypair (make-keri-identity))))
            (prior-said (let ((latest ($ kel-store 'latest)))
                          (or (and latest (kel-event-said latest))
                              (error "rotate-keys: kel-store has no prior event to rotate from" scope-aid))))
            (kkey       (public-key->aid-prefix (ed25519-keypair-public new-kp)))
            (nkey       (next-key-digest (ed25519-keypair-public new-nkp))))
       (call-with-values
         (lambda ()
           (build-rot (kel-identifier kel-store scope-aid) prior-said
                      #:keys (list kkey) #:nkeys (list nkey)
                      #:sn next-seq #:anchors anchors))
         (lambda (rot-json _said rot-alist)
           (let* ((sig       (sign-event rot-json new-kp))
                  (rot-event (list (cons "name" (string-append "scope-" scope-aid))
                                   (cons "rot"  rot-alist)
                                   (cons "sigs" (vector sig)))))
             ($ kel-store 'append rot-event)
             (bcom (^scope bcom name kind scope-aid
                           members member-sturdyrefs excluded
                           ballots commune-stances
                           gov-seal gov-sealed?
                           planning-seal planning-sealed?
                           delegate-seal delegate-sealed?
                           member-seal member-sealed?
                           acdc-store mycapn-ref scope-root-ref lineage
                           keri-backend
                           new-kp new-nkp
                           kel-store)))))))

    ;; --- Authority issuance ---
    ((mint-gov-cap holder-aid)
     (unless (may-govern? kind scope-aid acdc-store holder-aid members)
       (error "mint-gov-cap: not recognised by this scope" name holder-aid))
     ($ gov-seal holder-aid))
    ((mint-planning-cap holder-aid) ($ planning-seal holder-aid))
    ((mint-delegate-cap holder-aid) ($ delegate-seal holder-aid))
    ((mint-member-cap holder-aid)
     (unless member-seal
       (error "scope has no member-seal (federation kind)" name))
     ($ member-seal holder-aid))
    ((close-authority) gov-sealed?)
    ((gov-cap? cap)      ($ gov-sealed? cap))
    ((planning-cap? cap) ($ planning-sealed? cap))
    ((delegate-cap? cap) ($ delegate-sealed? cap))
    ((member-cap? cap)
     (and member-sealed? ($ member-sealed? cap)))

    ;; --- Recovery hook: rebind acdc-store post-construction ---
    ((set-acdc-store new-store)
     (bcom (rebuild members excluded ballots commune-stances
              member-sturdyrefs mycapn-ref new-store lineage)))

    ;; --- Cross-server: bind mycapn for sturdyref resolution ---
    ((set-mycapn ref)
     (bcom (rebuild members excluded ballots commune-stances
              member-sturdyrefs ref acdc-store lineage)))

    ;; --- Recovery hook: register an already-reconstructed ballot ---
    ;; recover-ballot-state (governance/recovery.scm) rebuilds a ^ballot
    ;; from its snapshot+stance ACDCs and records it in the shared
    ;; ballot-store, but has no way to also register it back into a
    ;; specific scope's OWN ballots index — open-direct-ballot/
    ;; open-ballot-for-scope always mint a fresh ballot, which would
    ;; create a second, distinct actor for the same proposal-id instead
    ;; of reusing the one recovery already rebuilt. This is the missing
    ;; piece: hand it an already-live ballot ref directly. No gov-cap
    ;; gate — recovery-only, same shape as set-acdc-store/set-mycapn
    ;; above, not a citizen-facing mutation.
    ((register-ballot! proposal-id ballot-ref)
     (bcom (rebuild members excluded
              (hashmap-set ballots proposal-id ballot-ref)
              commune-stances
              member-sturdyrefs mycapn-ref acdc-store lineage)))

    ;; --- Common reads ---
    ((members) members)
    ((member-ids)
     (hashmap-fold (lambda (k _v acc) (cons k acc)) '() members))
    ((member member-id)
     (hashmap-ref members member-id #f))
    ((ballots) ballots)
    ((get-ballot proposal-id) (hashmap-ref ballots proposal-id #f))

    ;; ====================================================================
    ;; Commune-kind methods (citizen membership)
    ;; ====================================================================

    ((excluded?) excluded)
    ((excluded-aid? aid) (and excluded (hashmap-ref excluded aid #f) #t))

    ;; The ecosystem's word on how a person is recognised: the
    ;; personhood-policy row on this commune's plan-store (enrollment-k,
    ;; witness-cap, witness-window, ceremony-ttl — first-person/personhood-policy.scm).
    ;; Gov-cap gated; a partial alist updates only the keys it names, and
    ;; every reader reads the row fresh, so the change binds the next act.
    ((set-personhood-policy! gov-cap changes)
     (require-gov-cap! gov-sealed? gov-cap "set-personhood-policy!" name)
     (unless scope-root-ref
       (error "set-personhood-policy!: scope has no economic root" name))
     (merge-governed-row! ($ scope-root-ref 'plan-store) "personhood-policy" changes
                          #:who "set-personhood-policy!" #:shape "(key . positive integer)"
                          #:valid? (lambda (kv) (and (pair? kv) (symbol? (car kv))
                                                     (integer? (cdr kv)) (>= (cdr kv) 1)))))

    ;; This scope's own word on whether its governance acts (admit-commune,
    ;; merge-with, split, rejoin-federation, accept-socialization,
    ;; accept-reimbursement) require a passing `^ballot` ratification, or
    ;; accept a bare gov-cap alone (governance-policy.scm). Same shape as
    ;; set-personhood-policy! above: gov-cap gated, partial-alist merge,
    ;; read fresh by require-ratification! on every act.
    ((set-governance-policy! gov-cap changes)
     (require-gov-cap! gov-sealed? gov-cap "set-governance-policy!" name)
     (unless scope-root-ref
       (error "set-governance-policy!: scope has no economic root" name))
     (merge-governed-row! ($ scope-root-ref 'plan-store) "governance-policy" changes
                          #:who "set-governance-policy!"))

    ((set-ccf gov-cap aid new-ccf . rest)
     (unless (eq? kind 'commune)
       (error "set-ccf: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "set-ccf requires gov-authority" name aid))
     (when (or (< new-ccf 0) (> new-ccf 1))
       (error "CCF must be in [0, 1]" aid new-ccf))
     (let ((assessed-at (if (pair? rest) (car rest) (current-time)))
           (reason      (if (and (pair? rest) (pair? (cdr rest)))
                            (cadr rest) #f)))
       (when scope-root-ref
         ($ ($ scope-root-ref 'account-store) 'set-ccf aid new-ccf))
       (when acdc-store
         ($ acdc-store 'issue
            (make-ccf-credential scope-aid aid name new-ccf
                                 assessed-at reason
                                 #:signing-keypair keypair)))
       'ok))

    ((exclude-member gov-cap aid . rest)
     (unless (eq? kind 'commune)
       (error "exclude-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "exclude-member requires gov-authority" name aid))
     (let ((excluded-at (if (pair? rest) (car rest) (current-time))))
       (when acdc-store
         ($ acdc-store 'issue
            (make-exclusion-credential scope-aid aid name excluded-at
                                       #:signing-keypair keypair)))
       (bcom (rebuild members
                (hashmap-set (or excluded (hashmap)) aid #t)
                ballots commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage))))

    ((reinstate-member gov-cap aid)
     (unless (eq? kind 'commune)
       (error "reinstate-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "reinstate-member requires gov-authority" name aid))
     ;; Revoke matching exclusion ACDCs
     (when acdc-store
       (let ((matches
               (filter
                 (lambda (c)
                   (and (not (cred-revoked? c))
                        (equal? (cred-schema c) *schema-playnet-exclusion*)
                        (equal? (cred-holder c) aid)
                        (equal? (cred-claim c 'commune) name)))
                 ($ acdc-store 'by-issuer scope-aid))))
         (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c))) matches)))
     (bcom (rebuild members
              (and excluded (hashmap-remove excluded aid))
              ballots commune-stances
              member-sturdyrefs mycapn-ref acdc-store lineage)))

    ((admit-member gov-cap aid . rest)
     (unless (eq? kind 'commune)
       (error "admit-member: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "admit-member requires gov-authority" name aid))
     (let ((admitted-at (if (pair? rest) (car rest) (current-time))))
       (when scope-root-ref
         ($ ($ scope-root-ref 'account-store) 'ensure-account aid))
       (when acdc-store
         ($ acdc-store 'issue
            (make-membership-credential scope-aid aid name admitted-at
                                        #:signing-keypair keypair)))
       'ok))

    ;; ====================================================================
    ;; Federation-kind methods (sub-scope membership)
    ;; ====================================================================

    ((member-communes) members)             ;; alias
    ((member-commune commune-id) (hashmap-ref members commune-id #f))
    ((member-commune-ids)
     (hashmap-fold (lambda (k _v acc) (cons k acc)) '() members))
    ((member-sturdyrefs) (or member-sturdyrefs (hashmap)))

    ((admit-commune gov-cap commune-id commune-ref . opts)
     ;; opts (kw-ref): 'admitted-at T, 'ratification SAID (Phase-6)
     (unless (memq kind '(federation universal-commune))
       (error "admit-commune: scope is not a federation/UC" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "admit-commune requires gov-authority" name commune-id))
     (verify-scope! commune-ref 'admit-commune)
     (let* ((admitted-at (kw-ref opts 'admitted-at (current-time)))
            (ratification-said (kw-ref opts 'ratification #f))
            (commune-aid ($ commune-ref 'commune-aid))
            (proposal-spec (list 'admit-commune commune-id commune-aid)))
       ;; Target = commune being admitted (whose contributors are
       ;; bound to the federation's rules by this admission).
       (require-ratification! scope-root-ref acdc-store commune-aid ratification-said
                              'admit-commune proposal-spec)
       (let ((membership-said
              (and acdc-store
                   ($ acdc-store 'issue
                      (make-federation-membership-credential
                        scope-aid commune-aid name commune-id admitted-at
                        #:edges (ratification-edges ratification-said)
                        #:signing-keypair keypair)))))
         ;; OOBI.md §3.2.1: anchor the credential SAID into our KEL via
         ;; ixn so receivers can verify the chain commits to it. Best-
         ;; effort: no-op in synthetic mode + when kel-store absent.
         (when membership-said
           (do-anchor-best-effort kel-store scope-aid keypair membership-said))
         ;; Deliver the membership credential to the commune via IPEX,
         ;; signed under this federation's own keypair so the commune's
         ;; gateway can verify the chain back to OUR KEL — not to
         ;; whichever umbrella signify happens to host us.
         (scope-deliver-grant! scope-aid keypair membership-said commune-aid
                               #:acdc-store acdc-store)
         (also-push-to-uc!     scope-aid keypair membership-said commune-aid
                               #:acdc-store acdc-store))
       (maybe-authorize-issuer! commune-aid admitted-at opts)
       ;; Reactive hook: notify the gateway-wide ^scope-graph so the
       ;; UC curator sees this commune drop out of the orphan set on
       ;; its next tick. Guard for test/no-graph mode.
       (let ((g (current-scope-graph)))
         (when g (<- g 'note-parent-link commune-aid scope-aid)))
       (bcom (rebuild (hashmap-set members commune-id commune-ref)
                excluded ballots commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage))))

    ((remove-commune gov-cap commune-id)
     (unless (memq kind '(federation universal-commune))
       (error "remove-commune: scope is not a federation/UC" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "remove-commune requires gov-authority" name commune-id))
     (when acdc-store
       (let ((matches
               (filter
                 (lambda (c)
                   (and (not (cred-revoked? c))
                        (equal? (cred-schema c)
                                *schema-playnet-federation-membership*)
                        (equal? (cred-claim c 'federation) name)
                        (equal? (cred-claim c 'commune-id) commune-id)))
                 ($ acdc-store 'by-issuer scope-aid))))
         (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c))) matches)))
     ;; Reactive hook: the unlinked commune returns to orphan status;
     ;; UC curator's next tick will re-admit it. The commune-id IS the
     ;; commune's AID for native federation membership (admit-commune
     ;; uses commune-id == commune-aid via verify-scope!).
     (let ((g (current-scope-graph))
           (commune-aid commune-id))
       (when g (<- g 'note-unlink commune-aid scope-aid)))
     (bcom (rebuild (hashmap-remove members commune-id)
              excluded ballots commune-stances
              (and member-sturdyrefs (hashmap-remove member-sturdyrefs commune-id))
              mycapn-ref acdc-store lineage)))

    ;; --- Cross-server: sturdyref-backed remote communes ---

    ((admit-commune-remote gov-cap commune-id commune-aid sturdyref-uri . opts)
     ;; opts (kw-ref): 'admitted-at T, 'ratification SAID (Phase-6). The goods
     ;; that cross are not said here: each member tells its census
     ;; (accept-census) and the roster is what at least two deal in.
     (unless (memq kind '(federation universal-commune))
       (error "admit-commune-remote: scope is not a federation/UC" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "admit-commune-remote requires gov-authority" name commune-id))
     (let* ((admitted-at (kw-ref opts 'admitted-at (current-time)))
            (ratification-said (kw-ref opts 'ratification #f))
            (proposal-spec (list 'admit-commune commune-id commune-aid)))
       ;; Target = commune being admitted (see admit-commune).
       (require-ratification! scope-root-ref acdc-store commune-aid ratification-said
                              'admit-commune proposal-spec)
       (let ((membership-said
              (and acdc-store
                   ($ acdc-store 'issue
                      (make-federation-membership-credential
                        scope-aid commune-aid name commune-id admitted-at
                        #:edges (ratification-edges ratification-said)
                        #:signing-keypair keypair))))
             (sturdyref-said
              (and acdc-store
                   ($ acdc-store 'issue
                      (make-federation-sturdyref-credential
                        scope-aid commune-aid commune-id sturdyref-uri
                        'websocket admitted-at
                        #:signing-keypair keypair)))))
         ;; OOBI.md §3.2.1 KEL-anchor both credentials; best-effort.
         (do-anchor-best-effort kel-store scope-aid keypair membership-said)
         (do-anchor-best-effort kel-store scope-aid keypair sturdyref-said)
         ;; Cross-gateway delivery: the commune lives on a different
         ;; server, so this is the load-bearing IPEX-grant path.
         (scope-deliver-grant! scope-aid keypair membership-said commune-aid
                               #:acdc-store acdc-store)
         (scope-deliver-grant! scope-aid keypair sturdyref-said  commune-aid
                               #:acdc-store acdc-store)
         (also-push-to-uc!     scope-aid keypair membership-said commune-aid
                               #:acdc-store acdc-store))
       (maybe-authorize-issuer! commune-aid admitted-at opts)
       (let ((g (current-scope-graph)))
         (when g (<- g 'note-parent-link commune-aid scope-aid)))
       (bcom (rebuild members excluded ballots commune-stances
                (hashmap-set (or member-sturdyrefs (hashmap))
                             commune-id sturdyref-uri)
                mycapn-ref acdc-store lineage))))

    ;; The federation on the wire, read off its own store: every member's
    ;; sturdyref credential that stands (issued here, not revoked), and the
    ;; roster they make — ((good aid …) …), the members each good crosses
    ;; for. What a member's peer is built with (gateway/federate.scm),
    ;; nothing typed.
    ((federation-spec)
     (sturdyref-credentials->spec
      scope-aid (if acdc-store
                    (append ($ acdc-store 'by-issuer scope-aid)
                            (censuses-told-to acdc-store scope-aid))
                    '())))

    ;; A member tells what it deals in: a census credential, issued and signed
    ;; by the commune, held by this federation. It stands when it checks (the
    ;; schema, the SAID, the member's signature), the member is admitted here,
    ;; and it is told to this federation; it revokes the member's earlier
    ;; census, so one stands per member. Telling the same census twice is one.
    ((accept-census cred)
     (unless (memq kind '(federation universal-commune))
       (error "accept-census: scope is not a federation/UC" name kind))
     (unless acdc-store (error "accept-census: scope has no credential store" name))
     (census-credential-goods cred)
     (unless (equal? (cred-holder cred) scope-aid)
       (error "accept-census: told to another federation" name (cred-holder cred)))
     (unless (any (lambda (c) (and (not (cred-revoked? c))
                                   (equal? (cred-holder c) (cred-issuer cred))))
                  (filter (lambda (c) (equal? (cred-schema c) *schema-playnet-federation-sturdyref*))
                          ($ acdc-store 'by-issuer scope-aid)))
       (error "accept-census: not a member here" name (cred-issuer cred)))
     (let ((told (censuses-told-to acdc-store scope-aid (cred-issuer cred)))
           (mine (census-key-state cred)))
       ;; the member's key log only moves on: a census whose log is behind what
       ;; this federation has read of it (no log at all, once it has rotated), or
       ;; forks it at the same sequence, is refused whoever signed it
       (for-each (lambda (c)
                   (let ((theirs (census-key-state c)))
                     (when theirs
                       (when (< (if mine (state-sn mine) 0) (state-sn theirs))
                         (error "accept-census: the member's key log is behind one already told" name (cred-issuer cred)))
                       (when (and mine (= (state-sn mine) (state-sn theirs))
                                  (not (equal? (state-said mine) (state-said theirs))))
                         (error "accept-census: the member's key log forks one already told" name (cred-issuer cred))))))
                 told)
       (for-each (lambda (c)
                   (unless (or (cred-revoked? c) (equal? (cred-said c) (cred-said cred)))
                     ($ acdc-store 'revoke (cred-said c))))
                 told))
     ($ acdc-store 'issue-idempotent cred))

    ((resolve-commune commune-id)
     (let ((uri (and member-sturdyrefs
                     (hashmap-ref member-sturdyrefs commune-id #f))))
       (unless uri
         (error "resolve-commune: no sturdyref for commune" commune-id))
       (unless mycapn-ref
         (error "resolve-commune: no mycapn-ref set" commune-id))
       (<- mycapn-ref 'enliven (string->ocapn-id uri))))

    ((store-resolved commune-id commune-ref)
     (bcom (rebuild (hashmap-set members commune-id commune-ref)
              excluded ballots commune-stances
              member-sturdyrefs mycapn-ref acdc-store lineage)))

    ;; --- Federation voice math ---
    ((commune-weight commune-id scope-roots)
     (let ((commune (hashmap-ref members commune-id #f)))
       (cond
         ((not commune) 0)
         (else
          (let* ((scope ($ commune 'scope-root))
                 (local ($ ($ scope 'account-store) 'total-social-svc))
                 (total (global-total-social-svc scope-roots)))
            (if (= 0 total) 0 (/ local total)))))))

    ;; --- Mandated commune-stance: a commune's delegate casts on its behalf ---
    ((receive-commune-stance delegate-cap commune-id proposal-id stance-bundle)
     (unless (memq kind '(federation universal-commune))
       (error "receive-commune-stance: scope is not a federation/UC" name kind))
     (unless ($ delegate-sealed? delegate-cap)
       (error "receive-commune-stance requires delegate-authority"
              name commune-id))
     (unless (hashmap-ref members commune-id #f)
       (error "Unknown commune" commune-id))
     (let* ((per-proposal (hashmap-ref (or commune-stances (hashmap))
                                       proposal-id (hashmap)))
            (updated (hashmap-set per-proposal commune-id stance-bundle))
            (new-cs  (hashmap-set (or commune-stances (hashmap))
                                  proposal-id updated)))
       (bcom (rebuild members excluded ballots new-cs
                member-sturdyrefs mycapn-ref acdc-store lineage))))

    ((commune-stances-for proposal-id)
     (hashmap-ref (or commune-stances (hashmap)) proposal-id (hashmap)))

    ;; --- Mandated tally with commune weights ---
    ((tally-mandated proposal-id scope-roots)
     (let ((per-proposal (hashmap-ref (or commune-stances (hashmap))
                                      proposal-id (hashmap)))
           (tally (hashmap))
           (total-weight 0))
       (define (add-tally pos w)
         (set! tally (hashmap-set tally pos
                                  (+ w (hashmap-ref tally pos 0)))))
       (let ((fed-total (global-total-social-svc scope-roots)))
         (hashmap-fold
           (lambda (commune-id stance-bundle _)
             (let* ((commune (hashmap-ref members commune-id #f))
                    (scope   (and commune ($ commune 'scope-root)))
                    (local   (and scope
                                  ($ ($ scope 'account-store) 'total-social-svc)))
                    (weight  (if (and local (not (= 0 fed-total)))
                                 (* local (/ 1 fed-total))
                                 0))
                    (cleartext (if (pair? stance-bundle) (car stance-bundle)
                                   stance-bundle))
                    (position (and (pair? cleartext) (caddr cleartext))))
               (when position
                 (set! total-weight (+ total-weight weight))
                 (add-tally position weight))))
           #f per-proposal))
       (list (cons 'tally tally)
             (cons 'total-mandated-weight total-weight)
             (cons 'mode 'mandated))))

    ;; --- Cross-scope ACDC discovery (federation pattern) ---
    ((find-commitment-by-id commitment-id)
     (let loop ((cs (hashmap-fold (lambda (_k v acc) (cons v acc))
                                  '() members)))
       (cond
         ((null? cs)
          (let-values (((p r) (spawn-promise-and-resolver)))
            (<-np r 'fulfill #f)
            p))
         (else
          (on-> (<- (car cs) 'acdc-store)
                (lambda (store)
                  (cond
                    ((not store) (loop (cdr cs)))
                    (else
                     (on-> (<- store 'by-claim-1
                                *schema-playnet-commitment*
                                'commitment-id commitment-id)
                           (lambda (cred)
                             (or cred (loop (cdr cs)))))))))))))

    ;; --- Direct federation ballot lifecycle ---
    ((open-direct-ballot gov-cap proposal-id description
                          citizen-registry citizen-voice-data)
     (unless ($ gov-sealed? gov-cap)
       (error "open-direct-ballot requires gov-authority" name proposal-id))
     (let ((b (open-ballot 'policy proposal-id 'federation description
                           citizen-registry citizen-voice-data
                           #:close-authority gov-sealed?)))
       (bcom (rebuild members excluded
                (hashmap-set ballots proposal-id b)
                commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage)
             b)))

    ((open-ballot-for-scope gov-cap proposal-id description
                             citizen-registry citizen-voice-data)
     (unless (eq? kind 'commune)
       (error "open-ballot-for-scope: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "open-ballot-for-scope requires gov-authority" name proposal-id))
     (let ((b (open-ballot 'policy proposal-id (list 'scope name) description
                           citizen-registry citizen-voice-data
                           #:close-authority gov-sealed?)))
       (bcom (rebuild members excluded
                (hashmap-set ballots proposal-id b)
                commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage)
             b)))

    ;; Close a ballot held by this scope (gov-gated). A single gov-cap
    ;; holder closing a live ballot unilaterally — early, before other
    ;; members cast — decides its outcome alone; open-close-ceremony below
    ;; is the k-of-n alternative that removes that single point.
    ((close-ballot gov-cap proposal-id)
     (unless ($ gov-sealed? gov-cap)
       (error "close-ballot requires gov-authority" name proposal-id))
     (let ((b (hashmap-ref ballots proposal-id #f)))
       (unless b (error "Unknown ballot in this scope" proposal-id))
       ($ b 'close gov-cap)))

    ;; k-of-n co-signed close: the SAME ^attestation-ceremony enrollment and
    ;; witnessed work-events already use (attestation-ceremony.scm), with
    ;; this commune's own may-govern? as ELIGIBLE? and the actual close as
    ;; ISSUE!. Opening the ceremony is gov-cap-gated and procedural — low-
    ;; stakes, the same as proposing a ballot at all — but nobody may CLOSE
    ;; it until THRESHOLD-K distinct eligible members have each signed the
    ;; ceremony's own statement-said and someone calls its 'finalize. That
    ;; is the fix: closing now takes k independent signatures, never one.
    ((open-close-ceremony gov-cap proposal-id threshold-k)
     (require-gov-cap! gov-sealed? gov-cap "open-close-ceremony" name)
     (let ((b (hashmap-ref ballots proposal-id #f)))
       (unless b (error "Unknown ballot in this scope" proposal-id))
       (let* ((statement-said (string-append "close-ballot:" scope-aid ":" proposal-id))
              (ceremony (spawn ^attestation-ceremony 'collecting statement-said threshold-k
                              (lambda (aid) (may-govern? kind scope-aid acdc-store aid members))
                              (lambda (attestations) ($ b 'close gov-cap))
                              '() #f)))
         (register-attestation-ceremony! statement-said ceremony)
         ceremony)))

    ;; Filter voice-data to remove excluded members (commune-only)
    ((filter-excluded voice-data)
     (unless (eq? kind 'commune)
       (error "filter-excluded: scope is not a commune" name kind))
     (hashmap-fold
       (lambda (cid data acc)
         (if (and excluded (hashmap-ref excluded cid #f))
             acc
             (hashmap-set acc cid data)))
       (hashmap) voice-data))

    ;; ====================================================================
    ;; First-Person layer: invitation, personhood, peer vouching
    ;; ====================================================================
    ;;
    ;; This scope's AID is the ecosystem AID for the PHCs it issues. A
    ;; scope can act as an ecosystem regardless of kind — a federation
    ;; does so for cross-commune personhood; a commune does so for its
    ;; own roster. Voice (labor-based) stays orthogonal: holding a PHC
    ;; does not grant voice; contributing labor does.

    ;; -- helpers shared across the four FP methods below ----------------
    ;; Defined as local procedures inside this `methods` form via let
    ;; would force a refactor of the macro shape; instead we inline the
    ;; two small primitives needed: (1) optional positional unpacking
    ;; and (2) signature-binds-aid assertion. Each method stays a
    ;; straight-line read.

    ((issue-phc gov-cap candidate-aid . rest)
     ;; Unilateral enrollment by the scope's governance group. Trailing
     ;; positional rest: (evidence-digest enrolled-at signing-keypair).
     ;; SIGNING-KEYPAIR must bind to SCOPE-AID when supplied.
     (require-gov-cap! gov-sealed? gov-cap "issue-phc" name)
     (require-store! acdc-store "issue-phc" name)
     (let-optional rest ((evidence-digest #f)
                         (enrolled-at (current-time))
                         (override-keypair #f))
       ;; Sign with the scope's OWN autonomous-signer keypair by default —
       ;; the ecosystem (this scope) is attesting personhood, so its D/B AID
       ;; signs and any verifier checks the sig against scope-aid. A caller
       ;; may override; #f in synthetic test mode leaves it unsigned.
       (let* ((sign-kp (or override-keypair keypair))
              (phc (make-personhood-credential
                     scope-aid candidate-aid enrolled-at
                     #:enrollment-evidence-digest evidence-digest
                     #:issuer-authz-said (scope-own-aic-said)
                     #:signing-keypair sign-kp)))
         (when sign-kp
           (assert-signature-binds! phc scope-aid "issue-phc"))
         ($ acdc-store 'issue phc))))

    ((bless-issuer gov-cap issuer-aid . rest)
     ;; Issue a signed Authorized-Issuer Credential blessing ISSUER-AID as a
     ;; PHC issuer under this scope (its root) — the by-AID path for
     ;; populating the trust registry (e.g. a federation blessing its member
     ;; communes at boot), lighter than `admit-commune` which also needs a
     ;; ref + membership. Signed by the scope's own keypair. Trailing
     ;; positional rest: (blessed-at).
     (require-gov-cap! gov-sealed? gov-cap "bless-issuer" name)
     (require-store! acdc-store "bless-issuer" name)
     (let-optional rest ((blessed-at (current-time)))
       (let ((aic (make-authorized-issuer-credential
                    scope-aid issuer-aid blessed-at
                    #:signing-keypair keypair)))
         (when keypair
           (assert-signature-binds! aic scope-aid "bless-issuer"))
         ($ acdc-store 'issue aic))))

    ((invite gov-cap sponsor-aid candidate-aid . rest)
     ;; Sponsored enrollment. Governance still gates issuance — the
     ;; sponsor's PHC is precondition, not bypass. Each invite-issued
     ;; PHC records `sponsor-aid` so subsequent invites can count
     ;; recent fan-out and enforce a per-window cap. The cap defaults
     ;; to *default-sponsor-fanout-cap* / *default-sponsor-fanout-window*;
     ;; callers can pass per-invite overrides as the trailing optionals.
     ;; Trailing positional rest:
     ;;   (evidence-digest enrolled-at fanout-cap fanout-window).
     (require-gov-cap! gov-sealed? gov-cap "invite" name)
     (require-store! acdc-store "invite" name)
     (unless (holds-live-phc? acdc-store scope-aid sponsor-aid)
       (error "invite: sponsor does not hold a live PHC in this ecosystem"
              sponsor-aid))
     (let-optional rest ((evidence-digest #f)
                         (enrolled-at (current-time))
                         (fanout-cap *default-sponsor-fanout-cap*)
                         (fanout-window *default-sponsor-fanout-window*))
       (assert-sponsor-fanout! acdc-store scope-aid sponsor-aid
                                fanout-cap fanout-window enrolled-at)
       ;; Signed by the scope's own keypair (as issue-phc); #f → unsigned.
       ;; Structurally rooted via the scope's own blessing edge.
       (let ((phc (make-personhood-credential
                    scope-aid candidate-aid enrolled-at
                    #:enrollment-evidence-digest evidence-digest
                    #:sponsor-aid sponsor-aid
                    #:issuer-authz-said (scope-own-aic-said)
                    #:signing-keypair keypair)))
         (when keypair
           (assert-signature-binds! phc scope-aid "invite"))
         ($ acdc-store 'issue phc))))

    ((revoke-phc gov-cap holder-aid)
     ;; Revoke HOLDER-AID's PHC(s) from this ecosystem. VRCs are
     ;; deliberately untouched — personhood and relationship are
     ;; orthogonal lifecycles.
     (require-gov-cap! gov-sealed? gov-cap "revoke-phc" name)
     (require-store! acdc-store "revoke-phc" name)
     (let ((live (filter (lambda (c)
                           (and (not (cred-revoked? c))
                                (equal? (cred-holder c) holder-aid)))
                         (phcs-by-ecosystem acdc-store scope-aid))))
       (for-each (lambda (c) ($ acdc-store 'revoke (cred-said c))) live)
       (length live)))

    ((vouch caller-aid subject-aid relationship-type . rest)
     ;; Peer attestation. CALLER issues a VRC carrying an I2I edge to
     ;; the caller's PHC in this ecosystem. Optional 4th arg: an
     ;; Ed25519 keypair binding to CALLER-AID — proof-of-possession,
     ;; not trust-the-arg.
     (require-store! acdc-store "vouch" name)
     (let ((caller-phc (phc-for acdc-store scope-aid caller-aid)))
       (unless caller-phc
         (error "vouch: caller has no live PHC in this ecosystem"
                caller-aid))
       (let-optional rest ((keypair #f))
         (let ((vrc (make-relationship-credential
                      caller-aid subject-aid relationship-type
                      (cred-said caller-phc)
                      (current-time)
                      #:signing-keypair keypair)))
           (when keypair
             (assert-signature-binds! vrc caller-aid "vouch"))
           ($ acdc-store 'issue vrc)))))

    ((open-enrollment gov-cap candidate-aid evidence-digest sponsor-aid k)
     ;; Open a k-of-n witness ceremony to enroll CANDIDATE-AID. Returns
     ;; an `^enrollment-ceremony` actor whose `attest` method existing
     ;; PHC-holders call (with their AID + Ed25519 signature over the
     ;; ceremony's statement-SAID); finalize issues a PHC carrying NI2I
     ;; edges to each witness's own PHC. SPONSOR-AID is a PHC-holder
     ;; introducing the candidate, or #f for the candidate's own request.
     ;; `issue-phc` remains the unilateral path for founders/admins.
     (require-gov-cap! gov-sealed? gov-cap "open-enrollment" name)
     (require-store! acdc-store "open-enrollment" name)
     ;; Signed by the scope's own keypair like issue-phc/invite (#f in
     ;; synthetic test mode → unsigned). Spawning registers the ceremony,
     ;; lands it in the witness inbox AND publishes the ask for every
     ;; peer gateway's poll — same rails as work witnessing.
     (spawn-enrollment-ceremony scope-aid candidate-aid evidence-digest
                                sponsor-aid k acdc-store
                                #:signing-keypair keypair))

    ((trust-triangle? aid-a aid-b . rest)
     ;; Trailing optional: require-signatures? (default #f for in-scope
     ;; queries — the scope already enforces sig-binding inside `vouch`,
     ;; so re-checking here costs work for no extra guarantee. External
     ;; verifiers should call `trust-triangle-holds?` directly with the
     ;; default #t fail-closed semantics.)
     (let-optional rest ((require-signatures? #f))
       (and acdc-store
            (trust-triangle-holds? acdc-store aid-a aid-b scope-aid
                                   #:require-signatures? require-signatures?))))

    ;; Read-only personhood query: does AID hold a live PHC in this
    ;; ecosystem? The dial reads this to show provisional vs verified.
    ((personhood? aid)
     (and acdc-store (holds-live-phc? acdc-store scope-aid aid) #t))

    ;; ====================================================================
    ;; Voice and weight rules (Phase 3 hardening)
    ;; ====================================================================
    ;;
    ;; A leaf's voice rule and a federation's weight rule are stored
    ;; as credentials, not implicit in code paths. Changes are
    ;; governance acts: they require gov-cap, emit a credential, and
    ;; supersede the prior rule (revoking it).

    ;; Voice rule and weight rule are both universal labor-proportional.
    ;; Voice = gross/total at every level; federation aggregation is
    ;; commune-weight-async (labor-share, hardcoded). Neither is
    ;; configurable; the protocol commits.


    ;; ====================================================================
    ;; Custody: attestation + transfer-commitment
    ;; ====================================================================
    ;;
    ;; Custody is a credential. A scope acts as the issuing authority for
    ;; its own inventory: `attest-custody` issues a self-held attestation;
    ;; `transfer-custody` co-issues (a) a new attestation crediting the
    ;; receiving scope and (b) a transfer-commitment that enumerates the
    ;; outstanding commitments traveling with the inventory. The prior
    ;; attestation is revoked atomically.
    ;;
    ;; The validator: outstanding commitments are commitments where this
    ;; scope is provider, resource-conforms-to matches, and the credential
    ;; is neither finished nor revoked. The `#:carries` policy chooses:
    ;;   'all       (default) — auto-enumerate all outstanding
    ;;   '()                  — must be no outstanding (else error)
    ;;   (list …)             — caller-supplied SAIDs (partial / curated)

    ((live-custody-attestations)         (live-custody-attestations))
    ((custody-attestation-for spec)      (custody-attestation-for spec))
    ((outstanding-commitments-of-spec s) (outstanding-commitments-of-spec s))

    ((attest-custody gov-cap resource-spec qty . opts)
     (require-gov-cap! gov-sealed? gov-cap "attest-custody" name)
     (let ((cred (make-custody-attestation-credential
                  scope-aid scope-aid resource-spec qty
                  #:valid-from  (kw-ref opts 'valid-from (iso-utc-now))
                  #:valid-until (kw-ref opts 'valid-until)
                  #:supersedes  (kw-ref opts 'supersedes)
                  #:signing-keypair keypair)))
       (when acdc-store ($ acdc-store 'issue cred))
       (cred-said cred)))

    ((transfer-custody gov-cap resource-spec qty to-scope-aid . opts)
     (require-gov-cap! gov-sealed? gov-cap "transfer-custody" name)
     (require-store!   acdc-store    "transfer-custody" name)
     (let* ((carries-policy (kw-ref opts 'carries 'all))
            (effective-at   (kw-ref opts 'effective-at (iso-utc-now)))
            (prior          (custody-attestation-for resource-spec))
            (outstanding    (outstanding-commitments-of-spec resource-spec))
            (outstanding-saids (map cred-said outstanding))
            (resolve-carries
             (lambda ()
               (cond
                ((eq? carries-policy 'all) outstanding-saids)
                ((null? carries-policy)
                 (unless (null? outstanding-saids)
                   (error "transfer-custody: outstanding commitments would be orphaned"
                          name resource-spec outstanding-saids))
                 '())
                ((list? carries-policy)
                 (let ((missing (lset-difference equal?
                                                 outstanding-saids
                                                 carries-policy)))
                   (unless (null? missing)
                     (error "transfer-custody: explicit carries omits outstanding"
                            name missing)))
                 carries-policy)
                (else (error "transfer-custody: invalid carries policy"
                             carries-policy))))))
       (unless prior
         (error "transfer-custody: no prior attestation"
                name resource-spec scope-aid))
       (let* ((carries (resolve-carries))
              ;; the prior grant's TERMS travel with custody: movability, care
              ;; terms, the exact-resource binding, the unit, the kind, and the
              ;; owner's steward rule all bind the next custodian the way they
              ;; bound this one. `ref` stays per-issuance — it is the
              ;; anti-replay nonce, not a term.
              (new-att (make-custody-attestation-credential
                        scope-aid to-scope-aid resource-spec qty
                        #:valid-from effective-at
                        #:supersedes (cred-said prior)
                        #:valid-until    (cred-claim prior 'valid-until)
                        #:movable        (cred-claim prior 'movable)
                        #:return-to      (cred-claim prior 'return-to)
                        #:condition-floor (cred-claim prior 'condition-floor)
                        #:resource       (cred-claim prior 'resource-id)
                        #:qty-unit       (cred-claim prior 'qty-unit)
                        #:kind           (cred-claim prior 'kind)
                        #:eligible       (cred-claim prior 'eligible)
                        #:signing-keypair keypair))
              (xfer    (make-custody-transfer-commitment-credential
                        scope-aid to-scope-aid resource-spec qty
                        (cred-said new-att) (cred-said prior)
                        #:carries-commitments carries
                        #:effective-at effective-at
                        #:signing-keypair keypair)))
         ($ acdc-store 'issue new-att)
         ($ acdc-store 'issue xfer)
         ($ acdc-store 'revoke (cred-said prior))
         (cred-said xfer))))

    ((accept-socialization gov-cap grant-said . opts)
     ;; The commune's BILATERAL consent to an owner's temporary-socialization
     ;; grant (a custody attestation an owner issued crediting this commune).
     ;; Only the commune, through its OWN gov-cap, can commit the commune — so
     ;; the consent is minted HERE, gov-cap-gated and scope-SIGNED, not fabricated
     ;; by the owner. Binds the owner's grant (primary) to the commune's return
     ;; COMMITMENT (reciprocal, always `transfer-custody` — the object comes
     ;; back, never a value substitute; see socialization.scm's grant-consume?
     ;; comment for why a private-repayment loan shape was tried and removed)
     ;; in an Agreement. The return commitment is a real outstanding commitment
     ;; against the spec, so it TRAVELS with custody (transfer-custody #:carries)
     ;; to whoever the plan hands the means to next — each holder accountable
     ;; in turn (social-means: a moving assignment). A bare grant with no care
     ;; terms needs none of this — it is a unilateral gift of use into the pool.
     ;;
     ;; opts (kw-ref): 'contribution (money-spec amount unit due) — a share of
     ;; the lent thing's running cost the commune bears: ONE more reciprocal
     ;; clause, a fixed sum of money due on a date, never a price per use
     ;; (docs/legal/structure.md §5; the records read it as `cost-share`,
     ;; and a sum that tracked the use as `metered-use`, a rent).
     ;; opts (kw-ref): 'ratification SAID — a closed, labour-voice-weighted
     ;; `^ballot`'s ratification naming this exact grant (docs/playnet.typ:
     ;; "producers recognise... weighted by labour-voice"), the same
     ;; optional evidence admit-commune/merge-with/split accept. Optional
     ;; unless this scope's own governance-policy has set
     ;; require-ratification, in which case require-ratification! refuses
     ;; the act without one — see governance-policy.scm.
     (require-gov-cap! gov-sealed? gov-cap "accept-socialization" name)
     (require-store!   acdc-store    "accept-socialization" name)
     (require-ratification! scope-root-ref acdc-store scope-aid
                            (kw-ref opts 'ratification #f)
                            'accept-socialization grant-said)
     (let ((grant (any-cred-by-said acdc-store grant-said)))
       ;; it must be a custody attestation crediting THIS commune — the commune
       ;; accepts a grant made TO it, not any credential and not one addressed elsewhere.
       (unless (and grant
                    (equal? *schema-playnet-custody-attestation* (cred-schema grant))
                    (equal? scope-aid (cred-holder grant)))
         (error "accept-socialization: not a custody grant to this commune" name grant-said))
       (let* ((owner (cred-issuer grant))
              (spec  (cred-claim grant 'resource-spec))
              (until (cred-claim grant 'valid-until))
              (return-c (make-commitment-credential
                         scope-aid owner (string-append "return-" grant-said)
                         'transfer-custody
                         #:resource-conforms-to spec #:due until
                         #:signing-keypair keypair))
              (contribution (kw-ref opts 'contribution #f))
              (share-c (and contribution
                            (let ((money-spec (list-ref contribution 0))
                                  (amount (list-ref contribution 1))
                                  (unit (list-ref contribution 2))
                                  (due (list-ref contribution 3)))
                              (make-commitment-credential
                               scope-aid owner (string-append "share-" grant-said)
                               'transfer
                               #:resource-conforms-to money-spec
                               #:resource-quantity (cons amount unit) #:due due
                               #:signing-keypair keypair))))
              (agreement (make-agreement-credential
                          scope-aid owner (string-append "agr-" grant-said)
                          #:primary-commitment-ids    (list grant-said)
                          #:reciprocal-commitment-ids (append (list (cred-said return-c))
                                                              (if share-c (list (cred-said share-c)) '()))
                          #:accepted-at (iso-utc-now)
                          #:signing-keypair keypair)))
         ;; idempotent: the ids are deterministic from the grant, so re-accepting
         ;; is a no-op rather than a duplicate.
         ($ acdc-store 'issue-idempotent return-c)
         (when share-c ($ acdc-store 'issue-idempotent share-c))
         ($ acdc-store 'issue-idempotent agreement)
         (cred-said agreement))))

    ((accept-reimbursement gov-cap claim-said . opts)
     ;; The reimbursement acceptance, in the VF Claim shape (docs/valueflows
     ;; examples, "Claim for income"): the member's own signed purchase-claim
     ;; (governance/debts.scm purchase-claim, client-signed via the same
     ;; ceremony socialize-preimage/-signed uses) attests a PAST fact — "I
     ;; gave the commons this" — so the commune's reciprocal debt is
     ;; TRIGGERED BY it (the debt carries `triggered-by` = the claim's SAID)
     ;; rather than bound in an Agreement, which VF reserves for connecting
     ;; reciprocal PROMISES (accept-socialization's case: a grant offer and
     ;; a return commitment, both forward-looking). One credential minted,
     ;; the provenance on it. Only the commune, through its OWN gov-cap, may
     ;; commit itself to owing anything back — so the debt is minted HERE,
     ;; gov-cap-gated and scope-signed; the claim already exists,
     ;; member-signed, never fabricated by governance.
     ;;
     ;; FUNDING SOURCE (docs/planning/socialization/reimbursement-funding-source.md):
     ;;   - a claim NAMING the resource that paid (resource-inventoried-as)
     ;;     is checked exactly: a resource under a live consume-grant to
     ;;     this commune is a self-attested spend of already-socialized
     ;;     money — REFUSED outright, a gift owes nothing back; an
     ;;     ungranted named resource positively clears the coarse flag.
     ;;   - a claim naming nothing falls back to the spec-wide flag
     ;;     (member-consume-grant-total), surfaced in the return value for
     ;;     governance to weigh, never auto-deducted — an unrelated purse
     ;;     and a genuinely-fronted purchase look identical from outside.
     ;;
     ;; Deterministic id from claim-said — re-accepting the same claim is a
     ;; no-op, not a duplicate. Returns (list debt-said flagged-amount).
     ;;
     ;; opts (kw-ref): 'ratification SAID — same evidence and same policy
     ;; gate as accept-socialization above.
     (require-gov-cap! gov-sealed? gov-cap "accept-reimbursement" name)
     (require-store!   acdc-store    "accept-reimbursement" name)
     (require-ratification! scope-root-ref acdc-store scope-aid
                            (kw-ref opts 'ratification #f)
                            'accept-reimbursement claim-said)
     (let ((claim (any-cred-by-said acdc-store claim-said)))
       (unless (and claim
                    (equal? *schema-playnet-commitment* (cred-schema claim))
                    (eq? 'transfer (cred-claim claim 'action))
                    (equal? scope-aid (cred-holder claim)))
         (error "accept-reimbursement: not a purchase claim addressed to this commune" name claim-said))
       (let* ((member (cred-issuer claim))
              (spec   (cred-claim claim 'resource-conforms-to))
              (rq     (cred-claim claim 'resource-quantity))
              (qty    (and (pair? rq) (car rq)))
              (unit   (and (pair? rq) (cdr rq)))
              (due    (cred-claim claim 'due))
              (rid    (cred-claim claim 'resource-inventoried-as)))
         (when (and rid (member-consume-grant-over acdc-store member scope-aid rid spec))
           (error "accept-reimbursement: the claim names a resource already consume-granted to this commune — socialized money owes nothing back" claim-said))
         (let ((flagged (if rid 0 (member-consume-grant-total acdc-store member spec)))
               (debt    (debt-commitment scope-aid member (string-append "repay-" claim-said)
                                         spec qty unit due
                                         #:triggered-by claim-said
                                         #:signing-keypair keypair)))
           ($ acdc-store 'issue-idempotent debt)
           (list (cred-said debt) flagged)))))


    ;; ====================================================================
    ;; Recomposition: merge, split, rejoin (free composition)
    ;; ====================================================================

    ((merge-with other-scope-ref gov-cap . opts)
     ;; opts (kw-ref): 'ratification SAID (Phase-6).
     ;; Two scopes co-author a merger. Returns the new combined scope AID.
     ;; If keri-backend is bound, performs real KERI multi-sig group inception
     ;; for the new AID and rotates both predecessors to dissolve them.
     ;; Otherwise (test mode), uses synthetic combined-aid.
     (unless ($ gov-sealed? gov-cap)
       (error "merge-with requires gov-authority" name))
     (verify-scope! other-scope-ref 'merge-with)
     (let* ((other-aid    ($ other-scope-ref 'scope-aid))
            (other-name   ($ other-scope-ref 'name))
            (ratification-said (kw-ref opts 'ratification #f))
            (proposal-spec (list 'merge-with other-aid)))
       (require-ratification! scope-root-ref acdc-store scope-aid ratification-said
                              'merge-with proposal-spec)
       (let* ((combined-aid
               (cond
                 (keri-backend
                  (let ((create-group (assq-ref keri-backend 'create-group))
                        (rotate-keys  (assq-ref keri-backend 'rotate-keys)))
                    (let ((new-aid (create-group (list scope-aid other-aid) 2)))
                      (when rotate-keys
                        (rotate-keys scope-aid #:cuts '(0))
                        (rotate-keys other-aid #:cuts '(0)))
                      new-aid)))
                 (else
                  (string-append "E_merged_" name "_" other-name))))
              (merged-at (current-time)))
         (when acdc-store
           ($ acdc-store 'issue
              (make-scope-merger-credential
                scope-aid other-aid combined-aid kind merged-at
                #:edges (ratification-edges ratification-said)
                ;; issuer = predecessor-a = this scope, so our keypair is the
                ;; right signer.
                #:signing-keypair keypair)))
         combined-aid)))

    ;; Bottom-up merge: parent federation (or Universal Commune) has
    ;; already issued a recomposition-ratification ACDC into its TEL
    ;; *before* the new C exists. We verify it, mint C with the
    ;; ratification SAID sealed in C's inception event (anchor seal),
    ;; rotate-dissolve predecessors. Per democracy-on-keri.md §4.3.
    ;;
    ;; Args:
    ;;   other-scope-ref: predecessor B (this scope is A)
    ;;   gov-cap:         A's gov authority
    ;;   parent-aid:      AID of the parent federation or UC
    ;;   parent-store:    acdc-store containing the ratification
    ;;   ratification-said: SAID of the parent-issued ratification
    ;;   successor-spec:  alist describing C — must equal what's claimed
    ;;                    in the ratification (predecessors + successor)
    ;;
    ;; Returns the new C scope's AID prefix.
    ((merge-with-parent other-scope-ref gov-cap parent-aid
                        parent-store ratification-said successor-spec
                        . opts)
     ;; opts (kw-ref): 'stale-memberships → list of federation-membership
     ;; SAIDs that point at parents OTHER than the chosen ratifier; they
     ;; will be embedded as NI2I edges in the merger ACDC so observing
     ;; parents can revoke them on their own TEL. See democracy-on-keri.md
     ;; §4.3 follow-up.
     (unless ($ gov-sealed? gov-cap)
       (error "merge-with-parent requires gov-authority" name))
     (verify-scope! other-scope-ref 'merge-with-parent)
     (let* ((other-aid     ($ other-scope-ref 'scope-aid))
            (other-name    ($ other-scope-ref 'name))
            (predecessors  (sort (list scope-aid other-aid) string<?))
            (proposal-spec (list 'merge-with other-aid))
            (stale-saids   (kw-ref opts 'stale-memberships '())))
       (verify-parent-ratification! parent-store parent-aid
                                    predecessors successor-spec
                                    ratification-said
                                    'merge-with proposal-spec)
       ;; Mint C with the ratification SAID sealed in icp.a.
       (let* ((anchors (list (list (cons "d" ratification-said))))
              (combined-aid
               (cond
                 ((and keri-backend
                       (assq-ref keri-backend 'create-scope-aid))
                  (let* ((csa (assq-ref keri-backend 'create-scope-aid))
                         (inception (csa #:anchors anchors)))
                    (scope-inception-aid inception)))
                 (else
                  ;; Synthetic mode: anchor lives only in the merger ACDC.
                  (string-append "E_merged_bottom_up_" name "_" other-name))))
              ;; Dissolve predecessors via rotate-keys when available.
              (_dissolve
               (let ((rotate-keys (and keri-backend
                                       (assq-ref keri-backend 'rotate-keys))))
                 (when rotate-keys
                   (rotate-keys scope-aid #:cuts '(0))
                   (rotate-keys other-aid #:cuts '(0)))))
              (merged-at (current-time))
              (merger-edges (append (ratification-edges ratification-said)
                                    (stale-membership-edges stale-saids))))
         (when acdc-store
           ($ acdc-store 'issue
              (make-scope-merger-credential
                scope-aid other-aid combined-aid kind merged-at
                #:edges merger-edges
                #:signing-keypair keypair)))
         combined-aid)))

    ;; N-way merge: M predecessors → 1 successor. Generalises
    ;; 'merge-with-parent. OTHER-REFS is a list of additional
    ;; predecessor scopes (this scope is the initiator, included
    ;; implicitly).
    ((merge-with-parent-many other-refs gov-cap parent-aid
                              parent-store ratification-said successor-spec
                              . opts)
     (unless ($ gov-sealed? gov-cap)
       (error "merge-with-parent-many requires gov-authority" name))
     (for-each (lambda (r) (verify-scope! r 'merge-with-parent-many))
               other-refs)
     (let* ((all-aids   (cons scope-aid
                              (map (lambda (r) ($ r 'scope-aid))
                                   other-refs)))
            (predecessors-sorted (sort all-aids string<?))
            (proposal-spec (list 'merge-with predecessors-sorted))
            (stale-saids   (kw-ref opts 'stale-memberships '())))
       (verify-parent-ratification! parent-store parent-aid
                                    predecessors-sorted successor-spec
                                    ratification-said
                                    'merge-with proposal-spec)
       (let* ((anchors (list (list (cons "d" ratification-said))))
              (combined-aid
               (cond
                 ((and keri-backend
                       (assq-ref keri-backend 'create-scope-aid))
                  (let* ((csa (assq-ref keri-backend 'create-scope-aid))
                         (inception (csa #:anchors anchors)))
                    (scope-inception-aid inception)))
                 (else
                  (string-append "E_merged_bottom_up_"
                                 (string-join all-aids "_")))))
              (_dissolve
               (let ((rotate-keys (and keri-backend
                                       (assq-ref keri-backend 'rotate-keys))))
                 (when rotate-keys
                   (for-each (lambda (a) (rotate-keys a #:cuts '(0)))
                             all-aids))))
              (merged-at (current-time))
              (merger-edges (append (ratification-edges ratification-said)
                                    (stale-membership-edges stale-saids))))
         (when acdc-store
           ($ acdc-store 'issue
              (make-scope-merger-credential
                ;; Legacy positional args ignored when #:predecessors given.
                #f #f
                combined-aid kind merged-at
                #:predecessors predecessors-sorted
                #:edges merger-edges
                ;; N-way issuer is (car predecessors-sorted) for determinism,
                ;; which is NOT necessarily this scope. Only sign when we
                ;; actually are the nominal issuer — signing someone else's
                ;; issuer AID with our key would produce a signature that
                ;; fails verification, strictly worse than leaving it
                ;; unsigned (the ratification edge + the ratifier's KEL
                ;; anchor still bind the authorization).
                #:signing-keypair (and (equal? scope-aid
                                               (car predecessors-sorted))
                                       keypair))))
         combined-aid)))

    ((set-keri-backend backend)
     ;; Late-bind the KERI backend (alist of create-scope-aid / create-group /
     ;; rotate-keys / create-aid).
     (bcom (^scope bcom name kind scope-aid
                   members member-sturdyrefs excluded
                   ballots commune-stances
                   gov-seal gov-sealed?
                   planning-seal planning-sealed?
                   delegate-seal delegate-sealed?
                   member-seal member-sealed?
                   acdc-store mycapn-ref scope-root-ref lineage
                   backend keypair next-keypair kel-store)))

    ((keri-backend) keri-backend)

    ((set-lineage new-lineage)
     ;; Late-bind lineage (used by recover-lineage from recomposition ACDCs).
     (bcom (rebuild members excluded ballots commune-stances
              member-sturdyrefs mycapn-ref acdc-store new-lineage)))

    ((split sub-scope-aids gov-cap . opts)
     ;; opts (kw-ref): 'ratification SAID (Phase-6).
     (unless ($ gov-sealed? gov-cap)
       (error "split requires gov-authority" name))
     (let* ((ratification-said (kw-ref opts 'ratification #f))
            (proposal-spec (list 'split (sort sub-scope-aids string<?)))
            (split-at (current-time)))
       (require-ratification! scope-root-ref acdc-store scope-aid ratification-said
                              'split proposal-spec)
       (when keri-backend
         (let ((rotate-keys (assq-ref keri-backend 'rotate-keys)))
           (when rotate-keys
             (rotate-keys scope-aid #:cuts '(0)))))
       (when acdc-store
         ($ acdc-store 'issue
            (make-scope-split-credential
              scope-aid sub-scope-aids kind split-at
              #:edges (ratification-edges ratification-said)
              #:signing-keypair keypair)))
       sub-scope-aids))

    ((rejoin-federation gov-cap old-fed-aid new-fed-aid . opts)
     ;; opts (kw-ref): 'ratification SAID (Phase-6).
     (unless ($ gov-sealed? gov-cap)
       (error "rejoin-federation requires gov-authority" name))
     (let* ((ratification-said (kw-ref opts 'ratification #f))
            (proposal-spec (list 'rejoin-federation old-fed-aid new-fed-aid)))
       (require-ratification! scope-root-ref acdc-store scope-aid ratification-said
                              'rejoin-federation proposal-spec)
       (when acdc-store
         ($ acdc-store 'issue
            (make-scope-rejoin-credential
              scope-aid old-fed-aid new-fed-aid (current-time)
              #:edges (ratification-edges ratification-said)
              #:signing-keypair keypair)))
       'ok))

    ;; ====================================================================
    ;; Conflict detection (free composition's deliberation surface)
    ;; ====================================================================

    ((detect-commitment-conflicts)
     ;; Walk member scopes' acdc-stores for overlapping commitments on the
     ;; same resource-conforms-to. Returns a vow resolving to a list of
     ;; conflict groups: ((resource-spec . (commitment-creds...)) ...)
     (let-values (((p r) (spawn-promise-and-resolver)))
       (let* ((member-list (hashmap-fold (lambda (_k v acc) (cons v acc))
                                         '() members)))
         (on-> (vow-fold-async
                 member-list
                 (lambda (mem acc)
                   (on-> (<- mem 'acdc-store)
                         (lambda (store)
                           (cond
                             ((not store) acc)
                             (else
                              (on-> (<- store 'by-schema
                                         *schema-playnet-commitment*)
                                    (lambda (creds)
                                      (append (filter (lambda (c)
                                                        (not (cred-revoked? c)))
                                                      creds)
                                              acc))))))))
                 '())
               (lambda (all-commitments)
                 ;; Group by resource-conforms-to
                 (let ((groups (hashmap)))
                   (for-each
                     (lambda (cred)
                       (let ((res (cred-claim cred 'resource-conforms-to)))
                         (when res
                           (let ((existing (hashmap-ref groups res '())))
                             (set! groups (hashmap-set groups res
                                                       (cons cred existing)))))))
                     all-commitments)
                   ;; Conflicts = groups with >1 commitment
                   (let ((conflicts
                          (hashmap-fold
                            (lambda (res creds acc)
                              (if (> (length creds) 1)
                                  (cons (cons res creds) acc)
                                  acc))
                            '() groups)))
                     (<-np r 'fulfill conflicts)))))
         p)))

    ((resolve-conflict gov-cap resource-id conflicting-saids
                       prevailing-said resolution-method)
     ;; Record a resolution decision as ACDC.
     (unless ($ gov-sealed? gov-cap)
       (error "resolve-conflict requires gov-authority" name))
     (when acdc-store
       ($ acdc-store 'issue
          (make-conflict-resolution-credential
            scope-aid resource-id conflicting-saids
            prevailing-said resolution-method (current-time)
            #:signing-keypair keypair)))
     'ok)))


;; =========================================================================
;; Spec hierarchy registry
;; =========================================================================
;;
;; Maps a specific spec → list of generalizations. Used by
;; `outstanding-commitments-of-spec` to recognize that a transfer of a
;; parent spec must respect commitments against its specializations.
;; e.g. registering ("spec:wheat-grade-A" → '("spec:wheat")) means a
;; transfer of "spec:wheat" looks for outstanding commitments against
;; both "spec:wheat" and "spec:wheat-grade-A".
;;
;; Populated externally by application code that knows the recipe
;; classification graph; defaults to empty (exact-match only).

(define *spec-generalizations* (make-hash-table))

(define (register-spec-generalization! specific general)
  "Declare that SPECIFIC is a specialization of GENERAL — a commitment
   for SPECIFIC should be considered outstanding when transferring
   custody of GENERAL."
  (hash-set! *spec-generalizations* specific
             (cons general
                   (hash-ref *spec-generalizations* specific '()))))

(define (clear-spec-generalizations!)
  "Reset the generalization registry. Useful in tests."
  (set! *spec-generalizations* (make-hash-table)))


;; =========================================================================
;; spawn-scope — primary constructor
;; =========================================================================

(define* (spawn-scope name
                      #:key
                      (kind 'commune)
                      (scope-aid #f)
                      (scope-root-ref #f)
                      (members (hashmap))
                      (acdc-store #f)
                      (mycapn-ref #f)
                      (lineage '())
                      (keri-backend #f)
                      (anchors '())
                      (durable? #f)
                      (bran #f)
                      (custody-mode 'auto)   ;; auto | shamir | vault | in-memory
                      (share-holders '())
                      (share-store #f)
                      (threshold #f)
                      (issuer-aid #f)
                      (keypair #f)
                      (next-keypair #f)
                      (kel-store #f)
                      (witnesses (default-scope-witnesses)))
  "Spawn a unified ^scope. KIND is 'commune or 'federation:
     commune    requires SCOPE-ROOT-REF (the economic substrate);
                MEMBERS is hashmap citizen-aid → #t (or empty).
     federation requires no scope-root; MEMBERS is hashmap commune-id → ref.

   Autonomous-signer inception (democracy-on-keri.md §4.1): when
   KERI-BACKEND is provided and exposes 'create-scope-aid, this scope
   mints a transferable single-controller AID. The keypair is captured
   in bcom state and never exposed; the underlying BRAN is persisted
   via Shamir share-holders or vault-on-disk so the scope is recoverable
   across vat restarts.

   ANCHORS may carry KERI seal alists (e.g. predecessor-issued
   ratification SAIDs) to be embedded in the inception event's `a`
   field — used by §4.3 bottom-up recomposition.

   Persistence kwargs (active when DURABLE? is #t):
     BRAN          — supply for recovery (32-byte bytevector); else
                     fresh entropy is drawn at spawn time.
     SHARE-HOLDERS — list of holder AIDs for Shamir-distributed bran.
                     If non-empty, spawn issues N bran-share ACDCs into
                     SHARE-STORE; restart needs at least THRESHOLD
                     shares to reconstruct.
     SHARE-STORE   — acdc-store where bran-share ACDCs land. Defaults
                     to the scope's own acdc-store when not supplied.
     THRESHOLD     — Shamir k. Defaults to (max 1 (ceiling 2/3 N)).
     ISSUER-AID    — AID stamped as issuer of the bran-share ACDCs.
                     Defaults to the scope's own AID (self-issued).
   When SHARE-HOLDERS is empty in DURABLE? mode, the bran is encrypted
   to <state>/scopes/<aid>/vault under PLAYNET_VAULT_KEY (single-host
   fallback).

   KEYPAIR / NEXT-KEYPAIR / KEL-STORE — recovery hooks.  Pre-derive
   keys from a recovered bran and pass an already-loaded kel-store +
   acdc-store to skip the mint path entirely (used by scope-recovery).

   When KERI-BACKEND is #f or lacks 'create-scope-aid, falls back to a
   synthetic AID derived from name + kind (test mode); keypair is #f.
   SCOPE-AID, when supplied, overrides any minted AID."
  (ensure-scope-brand!)
  (let*-values
      (((minted-aid minted-bran minted-kp minted-nkp icp-body)
        ;; Recovery path: when the caller supplies pre-derived
        ;; keypairs and an explicit scope-aid (scope-recovery's
        ;; restore-scope! does this after reading the kel-store
        ;; from disk and reconstituting the bran), we bypass the
        ;; mint entirely. Otherwise call the backend.
        (let ((inception
               (cond
                ((and keypair next-keypair scope-aid)
                 (make-scope-inception scope-aid bran
                                       keypair next-keypair #f))
                (else
                 (let ((csa (and keri-backend
                                 (assq-ref keri-backend
                                           'create-scope-aid))))
                   (and csa (not scope-aid)
                        (csa #:anchors anchors #:bran bran)))))))
          (if inception
              (values (scope-inception-aid          inception)
                      (scope-inception-bran         inception)
                      (scope-inception-keypair      inception)
                      (scope-inception-next-keypair inception)
                      (scope-inception-signed-icp   inception))
              (values #f #f #f #f #f))))
       ((effective-aid)
        (or scope-aid
            minted-aid
            (string-append "E_" (symbol->string kind) "_" name)))
       ;; Durable mode: when no acdc-store was supplied and the caller
       ;; asked for persistence, mint a disk-backed store under
       ;; <state>/scopes/<aid>/acdc/. ACDCs the scope issues from now on
       ;; survive vat restart (see democracy-on-keri.md §4.1).
       ((effective-acdc-store)
        (cond
         (acdc-store acdc-store)
         (durable?
          (let ((dir (scope-acdc-dir effective-aid)))
            (ensure-directory! dir)
            (spawn-acdc-store #:durable-dir dir)))
         (else #f)))
       ;; KEL store: callers in recovery mode pass a pre-loaded
       ;; kel-store; otherwise mint one. In durable mode it points
       ;; at the per-scope kel/ subdir; otherwise in-memory. Every
       ;; witness joins the store through its `witness!` door, which
       ;; also hands it the events the log already holds — so a scope
       ;; older than a witness (the founding scopes, restored on every
       ;; boot since before the oobi-host mirror existed) reaches it on
       ;; the next restore, and a freshly-minted icp reaches it as it
       ;; is appended.
       ((effective-kel-store)
        (let ((store (or kel-store
                         (spawn-kel-store
                          #:durable-dir (and durable?
                                             (scope-kel-dir effective-aid))
                          #:aid effective-aid))))
          (for-each (lambda (w) ($ store 'witness! w)) witnesses)
          (when (and (not kel-store) icp-body) ($ store 'append icp-body))
          store))
       ;; Bran custody: persist the bran via Shamir or vault when
       ;; running durable. Skipped in recovery (the bran was already
       ;; reconstituted by the caller and arrived via #:bran).
       ;;
       ;; CUSTODY-MODE selects the persistence strategy:
       ;;   'auto      — Shamir if share-holders are non-empty, else vault.
       ;;   'shamir    — fail unless share-holders are non-empty.
       ;;   'vault     — fail if share-holders are non-empty (caller likely
       ;;                made a mistake), force vault-on-disk.
       ;;   'in-memory — skip persistence (test mode against #:durable? #t
       ;;                is unusual; the actor lives only in memory).
       ((_persist-bran)
        (begin
          (when (and durable? minted-bran
                     (not (eq? custody-mode 'in-memory)))
            ;; A bran that cannot be persisted is a scope that can never be
            ;; restored — and by this point the durable acdc/ + kel/ dirs for
            ;; the minted AID already exist on disk. If persistence fails
            ;; (the classic case: no PLAYNET_VAULT_KEY in a dev process),
            ;; sweep those freshly-created dirs before rethrowing, so a
            ;; failed mint leaves NO orphan scope-state for every later
            ;; boot's recovery walk to trip over. Only the mint path sweeps:
            ;; a caller-supplied store means the dirs are someone else's.
            (catch #t
              (lambda ()
                (let ((effective-mode
                       (case custody-mode
                         ((auto) (if (pair? share-holders) 'shamir 'vault))
                         (else   custody-mode))))
                  (case effective-mode
                    ((shamir)
                     (unless (pair? share-holders)
                       (error "spawn-scope: 'shamir custody requires share-holders"
                              effective-aid))
                     (let* ((store (or share-store effective-acdc-store))
                            (n     (length share-holders))
                            (k     (or threshold (max 1 (ceiling (* 2/3 n))))))
                       (unless store
                         (error "spawn-scope: 'shamir custody needs a share-store"
                                effective-aid))
                       (split-and-issue-bran-shares!
                        minted-bran share-holders k
                        effective-aid
                        (or issuer-aid effective-aid)
                        store
                        #:signing-keypair minted-kp)))
                    ((vault)
                     (when (pair? share-holders)
                       (error "spawn-scope: 'vault custody but share-holders given"
                              effective-aid share-holders))
                     (ensure-directory! (scope-state-dir effective-aid))
                     (write-vault-bran! minted-bran
                                        (scope-vault-path effective-aid)))
                    (else
                     (error "spawn-scope: unknown custody-mode" custody-mode)))))
              (lambda (key . args)
                (when (and (not acdc-store) (not kel-store))
                  (remove-tree! (scope-state-dir effective-aid)))
                (apply throw key args))))
          #f))
       ;; a minted scope can rotate after a restart: the keys it will rotate to are
       ;; derivable from the bran it persisted, and rotate-keys commits to them
       ((_register-rotation)
        (when minted-bran
          (register-rotation-keypair-fn! effective-aid (rotation-keypair-fn minted-bran)))))
    (call-with-values
      (lambda () (make-endorsement-authority))
      (lambda (gov-seal _gu gov-sealed?)
        (call-with-values
          (lambda () (make-endorsement-authority))
          (lambda (planning-seal _pu planning-sealed?)
            (call-with-values
              (lambda () (make-endorsement-authority))
              (lambda (delegate-seal _du delegate-sealed?)
                ;; member-seal only for communes
                (call-with-values
                  (lambda ()
                    (if (eq? kind 'commune)
                        (make-endorsement-authority)
                        (values #f #f #f)))
                  (lambda (member-seal _mu member-sealed?)
                    (let ((federation-like? (memq kind '(federation universal-commune)))
                          (new-ref
                           (spawn ^scope name kind effective-aid
                                  members
                                  (if (memq kind '(federation universal-commune))
                                      (hashmap) #f)  ;; sturdyrefs
                                  (if (eq? kind 'commune) (hashmap) #f)     ;; excluded
                                  (hashmap)                                  ;; ballots
                                  (if (memq kind '(federation universal-commune))
                                      (hashmap) #f)  ;; commune-stances
                                  gov-seal      gov-sealed?
                                  planning-seal planning-sealed?
                                  delegate-seal delegate-sealed?
                                  member-seal   member-sealed?
                                  effective-acdc-store mycapn-ref scope-root-ref
                                  lineage keri-backend
                                  (or keypair      minted-kp)
                                  (or next-keypair minted-nkp)
                                  effective-kel-store)))
                      ;; Persist the kind tag and KERIA alias on disk so
                      ;; scope-recovery reads them at next boot — and so a
                      ;; tarball of <state>/scopes/<aid>/ is the complete
                      ;; portable artifact (vault carries the secret;
                      ;; aid-name + kind document how to wire it up on
                      ;; the receiving gateway). Convention: aid-name =
                      ;; "scope-<aid>", matching what
                      ;; governance-create-scope-aid! already bakes into
                      ;; the inception body.
                      (let ((scope-name (default-scope-aid-name effective-aid)))
                        (when durable?
                          (write-scope-kind! effective-aid kind)
                          (write-scope-aid-name! effective-aid scope-name))
                        ;; Reactive hook: let the gateway-wide scope-graph
                        ;; know a scope just appeared, with its KERIA alias.
                        ;; The IPEX grant handler reads aid-name via
                        ;; `(get-aid-name issuee)` to sign admit/spurn under
                        ;; the right local identity.
                        (let ((g (current-scope-graph)))
                          (when g
                            (<- g 'note-spawn effective-aid kind '()
                                #:ref new-ref
                                #:aid-name scope-name))))
                      ;; Turn ON the credential substrate: when this scope has both
                      ;; an economic substrate and a store, planner events mint the
                      ;; work/skill/intent/commitment/claim ACDCs. Idempotent, and
                      ;; recovery re-runs it (restored records replay via the silent
                      ;; paths, so nothing double-issues).
                      (when (and scope-root-ref effective-acdc-store)
                        (install-credentialing! scope-root-ref effective-acdc-store
                                                effective-aid
                                                ;; gap #18: durable scopes get a
                                                ;; portable event stream, anchored
                                                ;; into their KEL at each commitment
                                                #:event-log-dir
                                                (and durable? (scope-events-dir effective-aid))
                                                #:anchor
                                                (and durable?
                                                     (lambda (said)
                                                       (<- new-ref 'anchor-acdc/best-effort said)))
                                                ;; provenance-sign each ledger ACDC via the
                                                ;; scope's own sign-said (keypair never
                                                ;; leaves the actor); cred-signed-by-scope
                                                ;; no-ops for synthetic scopes with no key
                                                #:signer new-ref))
                      new-ref)))))))))))


;; =========================================================================
;; split-scope-with-aids — ergonomic helper that creates sub-scope AIDs
;; =========================================================================

(define (split-scope-with-aids parent-scope sub-names gov-cap)
  "Convenience wrapper around `(parent-scope 'split sub-aids gov-cap)`.

   For each name in SUB-NAMES, mints a sub-scope AID via the parent's
   bound keri-backend (calling its `create-aid` if available). When
   no backend is bound, generates synthetic AIDs of the form
   \"E_split_<name>\" so the synthetic test path stays self-contained.

   Then invokes `parent-scope.split` with those AIDs and GOV-CAP.

   Returns the list of newly created sub-scope AIDs.

   This collapses the runbook's two-step instruction
     (keri-create-aid \"sub-1\" ...)
     ($ parent 'split '(\"E_sub_1\" ...) gov-cap)
   into a single call where the AIDs come from the same backend that
   the parent will use to dissolve itself."
  (let* ((backend ($ parent-scope 'keri-backend))
         (create-aid (and backend (assq-ref backend 'create-aid)))
         (sub-aids (map (lambda (name)
                          (if create-aid
                              (create-aid name)
                              (string-append "E_split_" name)))
                        sub-names)))
    ($ parent-scope 'split sub-aids gov-cap)
    sub-aids))


;; =========================================================================
;; open-recomposition-ballot — labor-proportional ballot on a structural
;; question. Phase-6.
;; =========================================================================
;;
;; Same orchestration shape as other ballots: caller composes
;;   open → cast → close → snapshot → ratification → invoke recomposition method.
;; This helper is a thin wrapper over `open-ballot` that derives a
;; deterministic proposal-id from the canonical proposal-spec, so two
;; callers proposing the same merger get the same ballot-id and tally
;; concurrently.

(define* (open-recomposition-ballot scope-ref proposal-type proposal-spec
                                    description
                                    citizen-registry citizen-voice-data
                                    #:key
                                    (credential-check (lambda (_aid) #t))
                                    (close-authority #f))
  "Open a labor-proportional ballot on a structural question.

   PROPOSAL-TYPE: 'admit-commune | 'merge-with | 'split |
                  'rejoin-federation
   PROPOSAL-SPEC: canonical equal?-comparable form (see scope.scm method bodies)
   DESCRIPTION:   human-readable summary
   CITIZEN-REGISTRY: hashmap citizen-id → sealed?-actor
   CITIZEN-VOICE-DATA: hashmap citizen-id → (voice-share . delegation-map-ref)
   CLOSE-AUTHORITY: optional sealed?-actor required to close

   Returns the spawned ^ballot. Caller orchestrates votes, close,
   ballot-snapshot ACDC, ratification ACDC, and recomposition method
   invocation with `'ratification SAID`."
  (let ((proposal-id
         (string-append "recomp:"
                        (symbol->string proposal-type)
                        ":"
                        (canonical-string proposal-spec))))
    (open-ballot 'recomposition proposal-id
                 (list 'scope ($ scope-ref 'name))
                 description
                 citizen-registry
                 citizen-voice-data
                 #:credential-check credential-check
                 #:close-authority close-authority)))


(define scope-env
  (make-persistence-env
    `((((playnet governance) ^scope) ,^scope))))
