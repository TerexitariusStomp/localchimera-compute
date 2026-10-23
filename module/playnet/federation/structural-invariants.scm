;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation/structural-invariants.scm — leaves-are-real validators
;;;
;;; Implements the four structural invariants documented in
;;; docs/governance/LEAVES-ARE-REAL.md:
;;;
;;;   1. Unique-path *citizenship*  (federation-membership-paths-unique?)
;;;      Note: this guards consumption-side integrity (a person should
;;;      not hold an active citizenship credential in two leaves of the
;;;      same federation tree, since CCF is per-leaf and parallel
;;;      memberships could parallel-claim the consumption fund).
;;;      Voice does NOT depend on citizenship — voice is universal
;;;      labor-proportional (gross/total computed globally), so
;;;      double-counting is structurally impossible regardless of
;;;      this validator. The "membership" here is a recognized-
;;;      citizenship relation; voice rides on labor.
;;;   2. Leaf-only labor          (leaf-only-labor-coherent?)
;;;   3. Recomputability          (a property of the aggregator code path,
;;;                                not a runtime check; see async.scm)
;;;   4. Kind transitions         (audited via lineage; recomposition ACDCs)
;;;
;;; All checks here are synchronous and operate on near-refs. Cross-vat
;;; variants would lift these to vow-based walks; deferred until a
;;; cross-server federation actually needs them.
;;;


;; ── Leaf predicate + tree walk ──────────────────────────────────────────────

(define-module (playnet federation structural-invariants)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials custody)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri acdc-store)
  #:use-module (playnet scope actor)
  #:use-module (ice-9 match)
  #:use-module (playnet vf facts partition)
  #:use-module ((playnet economy socialization) #:select (ownership-ok?))
  #:use-module ((playnet vf schemas) #:select (economic-resource-id economic-resource-primary-accountable agent-id))
  #:use-module (goblins)
  #:export (scope-leaf? federation-leaves leaf-member-aids federation-aid-paths
            federation-membership-paths-unique? federation-double-counted-members
            tree-credentials-of-schema tree-work-events leaf-only-labor-coherent?
            leaf-only-labor-violations federation-members-attested?
            federation-unattested-members verify-kind-from-lineage
            compose-federation-admitting compile-threshold-spec
            threshold-spec-resource-spec redistribution-mandate-breaches
            redistribution-coherent? scope-has-contributors?
            recomposition-acdcs-in-tree recomposition-acdc-ratified?
            target-scope-was-genesis? recomposition-ratified?
            unratified-recomposition-acdcs federation-tree-coherent?
            ownership-coherent? ownership-violations
            records-held-once? records-held-twice))

(define (scope-leaf? scope-ref)
  "True iff SCOPE-REF is a leaf scope (kind = 'commune). Communes are
   the only scopes where real economic facts (members, labor, voice,
   inventory) are attested. Federations aggregate; they do not attest."
  (eq? 'commune ($ scope-ref 'kind)))

(define (federation-leaves scope-ref)
  "Walk down the federation tree rooted at SCOPE-REF, returning all
   leaf scope refs. Order is left-to-right pre-order; duplicates can
   appear if a leaf is admitted into two federations within this tree
   (which is itself a structural anomaly, surfaced by
   federation-membership-paths-unique? at the AID level)."
  (if (scope-leaf? scope-ref)
      (list scope-ref)
      (append-map
       (lambda (mid)
         (let ((child ($ scope-ref 'member mid)))
           (if child (federation-leaves child) '())))
       ($ scope-ref 'member-ids))))


;; ── Invariant 1: unique-path citizenship ───────────────────────────────────
;;
;; *Voice* does not depend on this — voice is labor-proportional and
;; computed globally from work-events; nothing here can double-count
;; voice. What this invariant guards is *citizenship-side integrity*:
;; a person holding membership credentials in two leaves of the same
;; federation tree can parallel-claim CCF / consumption fund. The
;; validator below catches that. Anyone can do labor in any scope
;; (and earn voice from it) regardless of citizenship anywhere.

(define (leaf-member-aids leaf)
  "Citizenship AIDs recognized by LEAF, derived from non-revoked
   playnet-membership credentials in the leaf's acdc-store. The
   in-actor `members` hashmap is empty for communes (it's only used
   by federations to hold sub-scope refs); the credential layer is
   the source of truth for citizen rosters. Voice does NOT ride on
   this — it rides on work-events. This is consumption-side."
  (let ((store ($ leaf 'acdc-store))
        (aid   ($ leaf 'scope-aid)))
    (if store (membership-holders ($ store 'all) aid) '())))

(define (federation-aid-paths scope-ref)
  "Return an alist (person-aid . leaf-aid-list) — for each member-aid
   reachable through the tree rooted at SCOPE-REF, the list of leaves
   that claim them as a member. A healthy tree has all lists of
   length 1; longer lists are double-counts."
  (let ((acc (make-hash-table)))
    (for-each
     (lambda (leaf)
       (let ((leaf-aid ($ leaf 'scope-aid)))
         (for-each
          (lambda (aid)
            (hash-set! acc aid
                       (cons leaf-aid (hash-ref acc aid '()))))
          (leaf-member-aids leaf))))
     (federation-leaves scope-ref))
    (hash-fold (lambda (aid leaves acc) (cons (cons aid leaves) acc))
               '() acc)))

(define (federation-membership-paths-unique? scope-ref)
  "True iff every citizenship-AID reachable from SCOPE-REF is held
   by exactly one leaf. False (with the duplicates) when at least
   one AID has multiple leaf paths — the structural signature of a
   double-citizenship anomaly (consumption-side: parallel CCF claims).
   Does NOT affect voice: voice is universal labor-proportional and
   counted-once-globally regardless of citizenship."
  (every (lambda (entry) (= 1 (length (cdr entry))))
         (federation-aid-paths scope-ref)))

(define (federation-double-counted-members scope-ref)
  "Return only the AIDs that appear in more than one leaf, with their
   leaf paths. Empty list = healthy tree."
  (filter (lambda (entry) (> (length (cdr entry)) 1))
          (federation-aid-paths scope-ref)))


;; ── Invariant 2: leaf-only labor ────────────────────────────────────────────

(define (tree-credentials-of-schema scope-ref schema)
  "All non-revoked credentials of SCHEMA reachable through SCOPE-REF's
   subtree, deduplicated by SAID. Multiple scopes in a tree can share
   an acdc-store; without dedup, the same credential would surface
   per-scope it's reachable through. Pure tree-walk + filter."
  (let ((seen (make-hash-table))
        (out  '()))
    (for-each
     (lambda (s)
       (let ((store ($ s 'acdc-store)))
         (when store
           (for-each
            (lambda (c)
              (unless (or (cred-revoked? c)
                          (hash-ref seen (cred-said c) #f))
                (hash-set! seen (cred-said c) #t)
                (set! out (cons c out))))
            ($ store 'by-schema schema)))))
     (cons scope-ref (federation-leaves scope-ref)))
    out))

(define (tree-work-events scope-ref)
  "All non-revoked work-event credentials reachable through SCOPE-REF.
   Thin alias of `tree-credentials-of-schema`, kept for legibility."
  (tree-credentials-of-schema scope-ref *schema-playnet-work-event*))

(define (leaf-only-labor-coherent? scope-ref)
  "True iff every work-event credential reachable through SCOPE-REF's
   tree was issued by a leaf scope. A federation issuing a work-event
   is the structural signature of voice/credit fabrication ungrounded
   in real labor at a real leaf."
  (let ((leaf-aids (map (lambda (l) ($ l 'scope-aid))
                        (federation-leaves scope-ref))))
    (every (lambda (we) (member (cred-issuer we) leaf-aids))
           (tree-work-events scope-ref))))

(define (leaf-only-labor-violations scope-ref)
  "Return the list of work-event credentials whose issuer is not a
   leaf scope in this tree. Empty = healthy."
  (let ((leaf-aids (map (lambda (l) ($ l 'scope-aid))
                        (federation-leaves scope-ref))))
    (filter (lambda (c) (not (member (cred-issuer c) leaf-aids)))
            (tree-work-events scope-ref))))


;; ── Invariant: federation members are attested by ACDCs ────────────────────

(define (federation-members-attested? fed-ref)
  "True iff every sub-scope ref in FED-REF's `members` hashmap has a
   live federation-membership ACDC issued by FED-REF in its store
   crediting the sub-scope's AID. Closes the 'fake federation' attack
   where someone instantiates a federation with member refs that
   never agreed to being admitted."
  (let* ((store    ($ fed-ref 'acdc-store))
         (fed-aid  ($ fed-ref 'scope-aid))
         (mids     ($ fed-ref 'member-ids)))
    (cond
     ((not store) (null? mids))             ;; no store → must have no members
     ((not (eq? 'federation ($ fed-ref 'kind))) #t)  ;; n/a for leaves
     (else
      (let ((memberships
             (filter (lambda (c)
                       (and (not (cred-revoked? c))
                            (equal? fed-aid (cred-issuer c))))
                     ($ store 'by-schema
                        *schema-playnet-federation-membership*))))
        (every
         (lambda (mid)
           (let ((member-ref ($ fed-ref 'member mid)))
             (and member-ref
                  (let ((member-aid ($ member-ref 'scope-aid)))
                    (any (lambda (c) (equal? member-aid (cred-holder c)))
                         memberships)))))
         mids))))))

(define (federation-unattested-members fed-ref)
  "List of member-ids whose ref lacks a backing federation-membership
   ACDC. Empty = healthy federation."
  (let* ((store    ($ fed-ref 'acdc-store))
         (fed-aid  ($ fed-ref 'scope-aid)))
    (if (and store (eq? 'federation ($ fed-ref 'kind)))
        (let ((memberships
               (filter (lambda (c)
                         (and (not (cred-revoked? c))
                              (equal? fed-aid (cred-issuer c))))
                       ($ store 'by-schema
                          *schema-playnet-federation-membership*))))
          (filter
           (lambda (mid)
             (let ((member-ref ($ fed-ref 'member mid)))
               (or (not member-ref)
                   (let ((member-aid ($ member-ref 'scope-aid)))
                     (not (any (lambda (c)
                                 (equal? member-aid (cred-holder c)))
                               memberships))))))
           ($ fed-ref 'member-ids)))
        '())))


;; ── Invariant: kind is consistent with recomposition lineage ───────────────

(define (verify-kind-from-lineage scope-ref)
  "Walk recomposition ACDCs in SCOPE-REF's store and verify the
   scope's claimed kind is consistent with what the lineage records.

   For a scope that appears as a successor in a `scope-merger` or
   `scope-split` credential, the kind recorded in that credential
   must match the scope's current kind.

   Genesis scopes (never named as a successor in any recomposition
   ACDC) have self-attested kind — this returns #t for them, since
   foundational scopes must be founded by someone.

   Returns #t iff consistent. False iff a credential names this scope
   as successor with a different kind than it currently claims —
   the structural signature of a 'silent kind transition' attack."
  (let ((store     ($ scope-ref 'acdc-store))
        (scope-aid ($ scope-ref 'scope-aid))
        (cur-kind  ($ scope-ref 'kind)))
    (if (not store) #t
        (let* ((mergers
                (filter (lambda (c)
                          (and (not (cred-revoked? c))
                               (equal? scope-aid
                                       (cred-claim c 'new-scope-aid))))
                        ($ store 'by-schema
                           *schema-playnet-scope-merger*)))
               (splits-as-successor
                (filter (lambda (c)
                          (and (not (cred-revoked? c))
                               (member scope-aid
                                       (or (cred-claim c 'sub-scope-aids)
                                           '()))))
                        ($ store 'by-schema
                           *schema-playnet-scope-split*))))
          (and (every (lambda (c) (eq? cur-kind (cred-claim c 'kind)))
                      mergers)
               ;; Splits record the *predecessor's* kind. Successors of a
               ;; split inherit no kind constraint from the split itself
               ;; (a leaf can split into leaves OR into a federation
               ;; admitting them externally — kind of successors is set
               ;; at their construction). So we don't constrain on splits.
               (or (null? splits-as-successor) #t))))))


;; ── Composition helper: spawn a fresh federation admitting existing ────────

(define* (compose-federation-admitting name member-scope-refs gov-cap-fn
                                       #:key
                                       (scope-aid #f)
                                       (acdc-store #f)
                                       (mycapn-ref #f))
  "Spawn a fresh federation NAME and atomically admit each scope in
   MEMBER-SCOPE-REFS. The original member scopes are unchanged
   (compose mode — non-destructive; no kind mutation anywhere). Each
   admission emits a federation-membership ACDC.

   GOV-CAP-FN: a thunk returning a fresh gov-cap for the new federation
   when called. (Built this way because the federation's seal is
   established at spawn; the caller mints a cap from the fresh scope.)

   Returns the new federation ref.

   Use this — never an in-place kind change — when an existing scope
   wants to participate in a new federation."
  (let ((fed (spawn-scope name
                          #:kind 'federation
                          #:scope-aid scope-aid
                          #:acdc-store acdc-store
                          #:mycapn-ref mycapn-ref)))
    (let ((gov-cap (gov-cap-fn fed)))
      (for-each
       (lambda (m)
         (let ((mid ($ m 'name)))
           ($ fed 'admit-commune gov-cap mid m)))
       member-scope-refs))
    fed))


;; ── Invariant: redistribution mandates honored ─────────────────────────────
;;
;; A scope holding a redistribution-mandate must have transferred
;; surplus above the threshold to the recipient policy. The auditor
;; calls `redistribution-mandate-breaches` and treats any returned
;; mandate as an incoherence-alert.

(define (compile-threshold-spec spec)
  "Compile a threshold-spec to a predicate (custody-qty → over?).
   Returns #f for unrecognized specs."
  (match spec
    (('custody-of-spec-above _spec qty-limit)
     (lambda (cur-qty) (> cur-qty qty-limit)))
    (('surplus-above ('qty qty-limit _unit) _spec)
     (lambda (cur-qty) (> cur-qty qty-limit)))
    (_ #f)))

(define (threshold-spec-resource-spec spec)
  "Extract the resource-spec a threshold-spec applies to."
  (match spec
    (('custody-of-spec-above resource-spec _) resource-spec)
    (('surplus-above _ resource-spec)         resource-spec)
    (_ #f)))

(define (redistribution-mandate-breaches scope-ref)
  "Return list of (mandate-cred . current-qty) for mandates this
   scope holds that are currently breached. Empty = compliant.
   Uses the scope's live custody-attestations for the mandated spec."
  (let* ((store ($ scope-ref 'acdc-store))
         (aid   ($ scope-ref 'scope-aid)))
    (if (not store)
        '()
        (let ((mandates
               (filter (lambda (c)
                         (and (not (cred-revoked? c))
                              (equal? aid (cred-holder c))))
                       (non-revoked-by-schema
                        store *schema-playnet-redistribution-mandate*))))
          (filter-map
           (lambda (m)
             (let* ((threshold (cred-claim m 'threshold-spec))
                    (pred (compile-threshold-spec threshold))
                    (rspec (threshold-spec-resource-spec threshold)))
               (if (or (not pred) (not rspec))
                   #f
                   (let* ((live-atts
                           (filter (lambda (a)
                                     (and (not (cred-revoked? a))
                                          (equal? rspec
                                                  (cred-claim a 'resource-spec))
                                          (equal? aid (cred-holder a))))
                                   ($ store 'by-schema
                                      *schema-playnet-custody-attestation*)))
                          (qty (fold (lambda (a acc)
                                       (+ acc (or (cred-claim a 'qty) 0)))
                                     0 live-atts)))
                     (if (pred qty) (cons m qty) #f)))))
           mandates)))))

(define (redistribution-coherent? scope-ref)
  "True iff this scope (and all leaves under it, if a federation) is
   compliant with all redistribution mandates."
  (and (null? (redistribution-mandate-breaches scope-ref))
       (every (lambda (l) (null? (redistribution-mandate-breaches l)))
              (federation-leaves scope-ref))))


;; ── Bundle: tree-coherent? ──────────────────────────────────────────────────

;; ── Invariant: recompositions ratified once post-genesis ───────────────────
;;
;; A scope is post-genesis iff at least one non-revoked work-event has been
;; issued by it (or, for federations, by any leaf in its subtree). Once
;; post-genesis, every recomposition ACDC issued by it must carry a
;; `ratification` edge — the structural cooption-closing claim of Phase 6.
;;
;; The genesis approximation is conservative ("has no contributors NOW")
;; rather than exact ("had no contributors at issue time"). This is
;; fail-closed in the right direction: a scope that was genesis at issue
;; and added contributors later will retroactively be flagged, which is
;; correct — once stakeholders exist, the absence of their consent is a
;; real signal. The scope can issue a retroactive ratification ACDC
;; backed by its now-present voice to clear the flag.

(define (scope-has-contributors? scope-ref)
  "True iff there is any non-revoked work-event credential issued by
   SCOPE-REF (or, for federations, any leaf in its subtree) — the
   structural signature of post-genesis state."
  (let ((tree (cons scope-ref (federation-leaves scope-ref))))
    (any (lambda (s)
           (let ((store ($ s 'acdc-store))
                 (aid   ($ s 'scope-aid)))
             (and store
                  (any (lambda (c)
                         (and (not (cred-revoked? c))
                              (equal? aid (cred-issuer c))))
                       ($ store 'by-schema *schema-playnet-work-event*)))))
         tree)))

(define (recomposition-acdcs-in-tree scope-ref)
  "Non-revoked recomposition ACDCs reachable in SCOPE-REF's subtree:
   scope-merger, scope-split, scope-rejoin, federation-membership.
   federation-membership is included because admit-commune is the
   cooption vector this phase closes."
  (append
   (tree-credentials-of-schema scope-ref *schema-playnet-scope-merger*)
   (tree-credentials-of-schema scope-ref *schema-playnet-scope-split*)
   (tree-credentials-of-schema scope-ref *schema-playnet-scope-rejoin*)
   (tree-credentials-of-schema scope-ref
                               *schema-playnet-federation-membership*)))

(define (recomposition-acdc-ratified? cred)
  "True iff CRED carries a 'ratification edge."
  (and (cred-edge cred 'ratification) #t))

(define (target-scope-was-genesis? scope-ref cred)
  "Conservative: the *target* (holder) scope has no contributors NOW.
   Holder is the affected scope:
     federation-membership: holder = commune being admitted
     scope-merger:          holder = new combined scope
     scope-split:           holder = parent (= self)
     scope-rejoin:          holder = scope (= self)
   So checking the holder uniformly locates the scope whose
   contributors are bound by the recomposition. Approximation —
   documented in `recomposition-ratified?`."
  (let ((target-aid (cred-holder cred)))
    (not (any (lambda (s)
                (and (equal? target-aid ($ s 'scope-aid))
                     (scope-has-contributors? s)))
              (cons scope-ref (federation-leaves scope-ref))))))

(define (recomposition-ratified? scope-ref)
  "True iff every recomposition ACDC in SCOPE-REF's subtree, issued
   by a post-genesis scope, carries a ratification edge."
  (every
   (lambda (c)
     (or (recomposition-acdc-ratified? c)
         (target-scope-was-genesis? scope-ref c)))
   (recomposition-acdcs-in-tree scope-ref)))

(define (unratified-recomposition-acdcs scope-ref)
  "Diagnostic: list of recomposition ACDCs that needed but lack
   ratification. Empty = healthy."
  (filter (lambda (c)
            (and (not (recomposition-acdc-ratified? c))
                 (not (target-scope-was-genesis? scope-ref c))))
          (recomposition-acdcs-in-tree scope-ref)))


(define (federation-tree-coherent? scope-ref)
  "Single-call check covering the structural invariants that are
   runtime-checkable. Returns #t iff:
     - every member-AID has a unique leaf path, AND
     - every work-event was issued by a leaf scope, AND
     - every federation has its members backed by attested
       federation-membership credentials, AND
     - every federation's claimed kind is consistent with its
       recomposition lineage, AND
     - no scope in the tree breaches a redistribution mandate it
       holds, AND
     - every post-genesis recomposition ACDC carries a ratification
       edge (Phase-6).

   Recomputability is a property of the code path; the voice/CCF
   separation is enforced by code-path discipline."
  (and (federation-membership-paths-unique? scope-ref)
       (leaf-only-labor-coherent? scope-ref)
       (every federation-members-attested?
              (filter (lambda (s) (eq? 'federation ($ s 'kind)))
                      (cons scope-ref (federation-leaves scope-ref))))
       (every verify-kind-from-lineage
              (cons scope-ref (federation-leaves scope-ref)))
       (redistribution-coherent? scope-ref)
       (recomposition-ratified? scope-ref)))

;; ── Invariant: the field agrees with the standing titles ────────────────────
;; declare-means writes `primary-accountable` self-asserted; the ownership
;; attestation is that assertion as a credential. This check is the promised
;; backstop: for every resource a scope's observer holds, once ANY title over
;; it stands in the scope's store, a LIVE one must name the field's owner
;; (ownership-ok? — the same rule the socialization gates read, so audit and
;; gate can never disagree). A world with no titles is coherent by silence.

(define (ownership-violations scope-ref)
  "((scope-aid resource-id claimed-owner) …) — every resource whose field
   contradicts the standing titles, across SCOPE-REF and its leaves."
  (append-map
   (lambda (s)
     (let ((store ($ s 'acdc-store))
           (root  ($ s 'scope-root)))
       (if (not (and store root)) '()
           (filter-map
            (lambda (r)
              (and (not (ownership-ok? store r))
                   (list ($ s 'scope-aid)
                         (economic-resource-id r)
                         (economic-resource-primary-accountable r))))
            (or (false-if-exception ($ ($ root 'observer) 'all-resources))
                '())))))
   (cons scope-ref (federation-leaves scope-ref))))

(define (ownership-coherent? scope-ref)
  "True iff no resource under SCOPE-REF contradicts a standing title."
  (null? (ownership-violations scope-ref)))


;; ── Invariant: one record, one scope ────────────────────────────────────────
;; Every federation fold is sound on one condition the fold itself cannot see:
;; each underlying RECORD — an agent, an economic resource — is held by exactly
;; one scope's store. A fold sums totals keyed by what a read must answer
;; (demand and means by spec and place, with no id in the key), so a record
;; copied into two scopes is counted twice and nothing downstream can tell.
;; Custody projection is a per-solve VIEW precisely so a socialized thing is
;; never copied; this check makes that discipline a FINDING, the way
;; federation-aid-paths makes double citizenship one.

(define (federation-scopes scope-ref)
  "SCOPE-REF and every scope below it, pre-order: the intermediate scopes hold
   records of their own as the leaves do."
  (cons scope-ref
        (append-map
         (lambda (mid)
           (let ((child ($ scope-ref 'member mid)))
             (if child (federation-scopes child) '())))
         (if (scope-leaf? scope-ref) '() ($ scope-ref 'member-ids)))))

(define (records-held-twice scope-ref)
  "((kind id scope-aids…) …) — every agent-id, resource-id or declared-need id
   held in more than one scope's store under SCOPE-REF. Empty = every record
   lives once. The count is the planner's `held-twice` over `root-holdings`,
   the same one the solve's entry applies to the communes of a call."
  (map (lambda (hit) (cons (caar hit) (cons (cdar hit) (cdr hit))))
       (held-twice
        (filter-map
         (lambda (scope)
           (let ((root (false-if-exception ($ scope 'scope-root))))
             (and root (cons ($ scope 'scope-aid) (root-holdings root)))))
         (federation-scopes scope-ref)))))

(define (records-held-once? scope-ref)
  "True iff no agent, resource or declared-need record is held by two scopes."
  (null? (records-held-twice scope-ref)))
