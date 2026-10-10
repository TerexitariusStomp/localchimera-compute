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
;;; (playnet boot scope) composes it from its fragments.


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

(define-module (playnet scope actor)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials custody)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module ((playnet federation sturdyref-credential) #:select (sturdyref-credentials->spec census-credential-goods census-key-state *schema-playnet-federation-census* *schema-playnet-federation-sturdyref*))
  #:use-module (playnet keri signify-portable)
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module (playnet federation scope-graph)
  #:use-module (playnet utils paths)
  #:use-module (playnet vf facts validity)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet observation credentials)
  #:use-module (playnet keri inception)
  #:use-module (playnet keys peers)
  #:use-module (playnet org endorsement)
  #:use-module (playnet keri acdc-store)
  #:use-module (playnet voice quorum)
  #:use-module (playnet keys exchange)
  #:use-module (playnet keys kel-store)
  #:use-module (playnet keys bran-custody)
  #:use-module (srfi srfi-11)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet protocol dispatch) #:select (compose-doors))
  #:export (any-cred-by-said
            verify-ratification!
            require-ratification!
            may-govern?
            verify-parent-ratification!
            federation-memberships-of
            federation-memberships-of-holder
            resolve-merge-ratifier
            ratification-edges
            stale-membership-edges
            do-anchor-best-effort
            do-anchor-acdc-into-kel!
            also-push-to-uc!
            kel-identifier
            register-rotation-keypair-fn!
            rotation-keypair-fn
            *scope-brands*
            find-vat-brand
            ^brand-marker
            ensure-scope-brand!
            current-scope-brand
            verify-scope!
            ^scope
            *spec-generalizations*
            register-spec-generalization!
            clear-spec-generalizations!
            spawn-scope
            scope-env
            scope-fragments
            set-scope-fragments!
            with-scope-ctx
            make-scope-ctx
            scope-ctx-bcom
            scope-ctx-name
            scope-ctx-kind
            scope-ctx-scope-aid
            scope-ctx-members
            scope-ctx-member-sturdyrefs
            scope-ctx-excluded
            scope-ctx-ballots
            scope-ctx-commune-stances
            scope-ctx-gov-seal
            scope-ctx-gov-sealed?
            scope-ctx-planning-seal
            scope-ctx-planning-sealed?
            scope-ctx-delegate-seal
            scope-ctx-delegate-sealed?
            scope-ctx-member-seal
            scope-ctx-member-sealed?
            scope-ctx-acdc-store
            scope-ctx-mycapn-ref
            scope-ctx-scope-root-ref
            scope-ctx-lineage
            scope-ctx-keri-backend
            scope-ctx-keypair
            scope-ctx-next-keypair
            scope-ctx-kel-store
            scope-ctx-rebuild
            scope-ctx-scope-own-aic-said
            scope-ctx-maybe-authorize-issuer!
            scope-ctx-live-custody-attestations
            scope-ctx-custody-attestation-for
            scope-ctx-commitment-fulfilled?
            scope-ctx-spec-matches?
            scope-ctx-outstanding-commitments-of-spec
            %rotation-keypair-fns
            censuses-told-to))

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
   governance-policy (voice/quorum.scm) has set `require-ratification`
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


;;; ── the context a fragment reads ─────────────────────────────────────────────
;;;
;;; The actor's fields and its internal helpers, as one record a fragment is
;;; handed; `with-scope-ctx` binds each under the name the clauses were written
;;; with, so a fragment's clauses read as they did inside the actor. `bcom` and
;;; `rebuild` are among them: a clause that changes a field returns
;;; (bcom (rebuild …)) as before.

(define-record-type <scope-ctx>
  (make-scope-ctx bcom name kind scope-aid members member-sturdyrefs excluded ballots commune-stances gov-seal gov-sealed? planning-seal planning-sealed? delegate-seal delegate-sealed? member-seal member-sealed? acdc-store mycapn-ref scope-root-ref lineage keri-backend keypair next-keypair kel-store rebuild scope-own-aic-said maybe-authorize-issuer! live-custody-attestations custody-attestation-for commitment-fulfilled? spec-matches? outstanding-commitments-of-spec)
  scope-ctx?
  (bcom scope-ctx-bcom)
  (name scope-ctx-name)
  (kind scope-ctx-kind)
  (scope-aid scope-ctx-scope-aid)
  (members scope-ctx-members)
  (member-sturdyrefs scope-ctx-member-sturdyrefs)
  (excluded scope-ctx-excluded)
  (ballots scope-ctx-ballots)
  (commune-stances scope-ctx-commune-stances)
  (gov-seal scope-ctx-gov-seal)
  (gov-sealed? scope-ctx-gov-sealed?)
  (planning-seal scope-ctx-planning-seal)
  (planning-sealed? scope-ctx-planning-sealed?)
  (delegate-seal scope-ctx-delegate-seal)
  (delegate-sealed? scope-ctx-delegate-sealed?)
  (member-seal scope-ctx-member-seal)
  (member-sealed? scope-ctx-member-sealed?)
  (acdc-store scope-ctx-acdc-store)
  (mycapn-ref scope-ctx-mycapn-ref)
  (scope-root-ref scope-ctx-scope-root-ref)
  (lineage scope-ctx-lineage)
  (keri-backend scope-ctx-keri-backend)
  (keypair scope-ctx-keypair)
  (next-keypair scope-ctx-next-keypair)
  (kel-store scope-ctx-kel-store)
  (rebuild scope-ctx-rebuild)
  (scope-own-aic-said scope-ctx-scope-own-aic-said)
  (maybe-authorize-issuer! scope-ctx-maybe-authorize-issuer!)
  (live-custody-attestations scope-ctx-live-custody-attestations)
  (custody-attestation-for scope-ctx-custody-attestation-for)
  (commitment-fulfilled? scope-ctx-commitment-fulfilled?)
  (spec-matches? scope-ctx-spec-matches?)
  (outstanding-commitments-of-spec scope-ctx-outstanding-commitments-of-spec))

(define-syntax with-scope-ctx
  (lambda (x)
    (syntax-case x ()
      ((_ ctx body ...)
       (with-syntax (((name ...) (map (lambda (n) (datum->syntax x n)) '(bcom name kind scope-aid members member-sturdyrefs excluded ballots commune-stances gov-seal gov-sealed? planning-seal planning-sealed? delegate-seal delegate-sealed? member-seal member-sealed? acdc-store mycapn-ref scope-root-ref lineage keri-backend keypair next-keypair kel-store rebuild scope-own-aic-said maybe-authorize-issuer! live-custody-attestations custody-attestation-for commitment-fulfilled? spec-matches? outstanding-commitments-of-spec)))
                     ((ref ...) (map (lambda (n) (datum->syntax x (string->symbol (string-append "scope-ctx-" (symbol->string n))))) '(bcom name kind scope-aid members member-sturdyrefs excluded ballots commune-stances gov-seal gov-sealed? planning-seal planning-sealed? delegate-seal delegate-sealed? member-seal member-sealed? acdc-store mycapn-ref scope-root-ref lineage keri-backend keypair next-keypair kel-store rebuild scope-own-aic-said maybe-authorize-issuer! live-custody-attestations custody-attestation-for commitment-fulfilled? spec-matches? outstanding-commitments-of-spec))))
         #'(let ((name (ref ctx)) ...) body ...))))))

;;; ── the fragments ────────────────────────────────────────────────────────────
;;;
;;; The methods of a scope are written in the directory of the subsystem each
;;; serves (docs/planning/codebase-layout.md §5): scope/keys, scope/capabilities,
;;; scope/membership, scope/custody, federation/communes, federation/conflicts,
;;; voice/scope-ballots, personhood/issuance, economy/acceptance. Each is a
;;; procedure from a <scope-ctx> to a declared-doors fragment. This module
;;; imports none of them: the composition root (playnet boot scope) sets the
;;; list once per process, and every spawn — and every restore — composes the
;;; actor from it.

(define *scope-fragments* '())
(define (scope-fragments) *scope-fragments*)
(define (set-scope-fragments! makers)
  "MAKERS: procedures from a <scope-ctx> to a fragment, in dispatch order."
  (set! *scope-fragments* makers))

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


  (let ((ctx (make-scope-ctx bcom name kind scope-aid members member-sturdyrefs excluded ballots commune-stances gov-seal gov-sealed? planning-seal planning-sealed? delegate-seal delegate-sealed? member-seal member-sealed? acdc-store mycapn-ref scope-root-ref lineage keri-backend keypair next-keypair kel-store rebuild scope-own-aic-said maybe-authorize-issuer! live-custody-attestations custody-attestation-for commitment-fulfilled? spec-matches? outstanding-commitments-of-spec)))
    (compose-doors
     (map (lambda (make) (make ctx)) (scope-fragments))
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

    ((commune-aid) scope-aid)

        ;; alias for commune-style callers
    ((federation-aid) scope-aid)

     ;; alias for federation-style callers
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

    ;; --- Recovery hook: rebind acdc-store post-construction ---
    ((set-acdc-store new-store)
     (bcom (rebuild members excluded ballots commune-stances
              member-sturdyrefs mycapn-ref new-store lineage)))

    ;; --- Cross-server: bind mycapn for sturdyref resolution ---
    ((set-mycapn ref)
     (bcom (rebuild members excluded ballots commune-stances
              member-sturdyrefs ref acdc-store lineage)))

    ;; --- Recovery hook: register an already-reconstructed ballot ---
    ;; recover-ballot-state (federation/rebuild.scm) rebuilds a ^ballot
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

    ((excluded-aid? aid) (and excluded (hashmap-ref excluded aid #f) #t))))))

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

(define scope-env
  (make-persistence-env
    `((((playnet scope actor) ^scope) ,^scope))))
