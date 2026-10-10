;;; federation/universal-commune.scm — Universal Commune actor
;;;
;;; Per docs/rules.md:
;;;
;;;   "The Universal Commune unifies the federation: formed at planning
;;;    time, its children are all federation roots (scopes with no
;;;    parent). Aggregations below are computed across federation roots."
;;;
;;; And per docs/governance/democracy-on-keri.md §4.3, Universal Commune
;;; is the **implicit ratifier** for top-level recompositions: when two
;;; federation-root scopes merge (or split, or rejoin) and have no
;;; shared parent federation, the UC issues the
;;; recomposition-ratification ACDC into its TEL. Its SAID then seals
;;; the new scope's inception event.
;;;
;;; UC is a single autonomous-signer scope per vat: one transferable
;;; AID, keypair held inside the UC actor, host-isolated. Its only
;;; behavioural difference from any other federation scope is that it
;;; needs no parent (it IS the implicit root).

(define-module (playnet federation universal-commune)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)   ;; fold, lset-intersection, filter-map
  #:use-module (srfi srfi-13)  ;; string-join
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet credentials registry)
  #:use-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module (playnet utils paths)
  #:use-module (playnet scope actor)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri inception)
  #:use-module (playnet keri first-person predicates)
  #:use-module ((playnet keys keri-backend)
                #:select (stub-keri-backend))
  ;; D2: ratification ACDCs delivered to remote predecessors via
  ;; Phase-6 IPEX so cross-gateway recomposition's sealing-into-icp.a
  ;; step has the SAID it needs.
  #:use-module ((playnet keys exchange)
                #:select (scope-deliver-grant!))
  #:use-module ((playnet utils common) #:select (for-each-catching))
  #:export (spawn-universal-commune
            current-universal-commune
            reset-universal-commune!
            ratify-recomposition!
            merge-bottom-up!
            split-bottom-up!
            uc-collision-status
            uc-reconcile-action
            ^uc-merge-proposals
            spawn-uc-merge-proposals
            uc-merge-proposals-env))

;;; ════════════════════════════════════════════════════════════════════════════
;;; Cross-gateway UC reconciliation — "one UC" as gravity, not decree
;;;
;;; The UC singularity check is VAT-LOCAL (it stops one boot double-minting).
;;; Nothing prevents two independently-booted graphs, each with its own UC,
;;; from meeting over cross-gateway federation. The one-universal-commune
;;; telos says that meeting should tend toward unity — but by CONSENT, never
;;; imposition. So a collision is surfaced as a *proposed* merge (ratified
;;; through `merge-bottom-up!`), and until then the two UCs cross-recognize
;;; as roots. Detection is lineage-aware so a UC that already merged with
;;; ours (a recomposition descendant/ancestor) is not mistaken for a rival.
;;; ════════════════════════════════════════════════════════════════════════════

(define (uc-collision-status acdc-store my-uc-aid peer-uc-aid)
  "Classify two Universal-Commune AIDs observed in one connected topology:
     'none       — a UC AID is missing; nothing to compare
     'identical  — the same UC; already unified
     'lineal     — one is a ratified recomposition ancestor of the other,
                   so they are already ONE UC across a merge/split — adopt
                   the descendant, no new merge needed
     'collision  — unrelated roots → the one-UC telos calls for a PROPOSED
                   (consensual) merge; until ratified they cross-recognize

   Lineage-aware via `root-lineage-closure` — the same ratified lineage the
   root-of-trust checks walk — so a descendant is never taken for a rival."
  (cond
   ((or (not my-uc-aid) (not peer-uc-aid)) 'none)
   ((equal? my-uc-aid peer-uc-aid) 'identical)
   ((or (member peer-uc-aid (root-lineage-closure acdc-store my-uc-aid))
        (member my-uc-aid   (root-lineage-closure acdc-store peer-uc-aid)))
    'lineal)
   (else 'collision)))

(define (uc-reconcile-action acdc-store my-uc-aid peer-uc-aid)
  "The recommended reconciliation for a peer-UC observation. On a genuine
   'collision returns `(propose-merge MY-UC PEER-UC)` — a PROPOSED merge,
   never auto-executed: merging UCs is `merge-bottom-up!`, which requires
   each side's governance to ratify. Otherwise `(no-op STATUS)`. This keeps
   the pull toward one UC while leaving the decision with the communes."
  (let ((status (uc-collision-status acdc-store my-uc-aid peer-uc-aid)))
    (if (eq? status 'collision)
        (list 'propose-merge my-uc-aid peer-uc-aid)
        (list 'no-op status))))

(define (uc-pair-eq? entry a b)
  "Two UC-merge proposals are the same regardless of which side observed
   the other — the pair {a,b} is unordered."
  (or (and (equal? (car entry) a) (equal? (cadr entry) b))
      (and (equal? (car entry) b) (equal? (cadr entry) a))))

(define-actor (^uc-merge-proposals bcom proposals)
  ;; proposals: list of (my-uc peer-uc . at) — surfaced collisions awaiting
  ;; a CONSENSUAL merge. This is the surface→ratify handoff: the reconciler
  ;; records here; UC governance drains `pending`, and on ratification runs
  ;; `merge-bottom-up!` then `resolve`. Turning detection into a governance
  ;; proposal rather than a log line.

  ;; Plain data (UC AID strings + timestamps, compared via equal? in
  ;; uc-pair-eq? — not actor refs) — no closures, straightforward to persist.
  #:portrait
  (lambda () (list proposals))

  #:version 1

  #:restore
  (lambda (version data)
    (case version
      ((1) (spawn ^uc-merge-proposals data))
      (else (error "Unknown ^uc-merge-proposals version" version))))

  (methods
   ((pending) proposals)
   ((count)   (length proposals))
   ((propose my-uc peer-uc . rest)
    "Record a proposed merge unless the unordered pair is already pending.
     Returns 'recorded or 'duplicate."
    (if (find (lambda (e) (uc-pair-eq? e my-uc peer-uc)) proposals)
        'duplicate
        (bcom (^uc-merge-proposals bcom
                (cons (cons* my-uc peer-uc (if (pair? rest) (car rest) #f))
                      proposals))
              'recorded)))
   ((resolve my-uc peer-uc)
    "Drop a proposal once its merge has been ratified + executed."
    (bcom (^uc-merge-proposals bcom
            (remove (lambda (e) (uc-pair-eq? e my-uc peer-uc)) proposals))
          'resolved))
   ((clear!) (bcom (^uc-merge-proposals bcom '()) 'cleared))))

(define (spawn-uc-merge-proposals) (spawn ^uc-merge-proposals '()))

(define uc-merge-proposals-env
  (make-persistence-env
    `((((playnet federation universal-commune) ^uc-merge-proposals) ,^uc-merge-proposals))))

;;; Vat-local UC handle.
(define *universal-commune-ref* #f)

(define* (spawn-universal-commune #:key
                                  (acdc-store #f)
                                  (mycapn-ref #f)
                                  (keri-backend #f)
                                  (durable? (durable-default?))
                                  (existing-ref #f)
                                  (scope-graph #f))
  "Spawn or restore the Universal Commune for this vat.

   Resolution order:
     1. EXISTING-REF supplied → bind vat-local to it; return. Used by
        the gateway after `restore-all-scopes!` recovers the UC from
        disk — recovery has already reconstructed the actor; we just
        adopt the ref.
     2. Vat-local cache hit → return it (idempotent re-call).
     3. SCOPE-GRAPH supplied and reports an existing UC AID we don't
        hold a ref for → ERROR. This catches the boot path forgetting
        to pass #:existing-ref, which would otherwise double-mint.
     4. Mint a new one via spawn-scope with kind = 'universal-commune.

   ACDC-STORE: optional credential store. If #f and KERI-BACKEND is
   #f (test mode), UC operates without a TEL. When DURABLE? is #t and
   no ACDC-STORE was supplied, the UC mints a disk-backed store at
   <state>/scopes/<aid>/acdc/.

   KERI-BACKEND: optional keri-backend alist. When supplied and
   exposing 'create-scope-aid, UC mints a real autonomous-signer AID;
   otherwise falls back to a synthetic deterministic AID (test mode).

   The UC's scope-kind is now 'universal-commune (was 'federation).
   The promoted kind unlocks the auto-mirror path and lets
   `find-by-kind` distinguish UC from regular federations on disk."
  (cond
   (existing-ref
    (set! *universal-commune-ref* existing-ref)
    existing-ref)
   (*universal-commune-ref* *universal-commune-ref*)
   ((and scope-graph
         (let ((existing ($ scope-graph 'find-by-kind 'universal-commune)))
           (and (pair? existing) existing)))
    => (lambda (existing-aids)
         (error "spawn-universal-commune: a UC already exists on this gateway \
but no #:existing-ref was supplied. Restore via scope-recovery first, then \
pass the restored ref via #:existing-ref."
                existing-aids)))
   (else
    (let ((uc (spawn-scope "universal-commune"
                           #:kind 'universal-commune
                           #:scope-aid (and (not keri-backend)
                                            "E_universal_commune")
                           #:acdc-store acdc-store
                           #:mycapn-ref mycapn-ref
                           #:keri-backend keri-backend
                           #:durable? durable?)))
      (set! *universal-commune-ref* uc)
      uc))))

(define (current-universal-commune)
  "Return the vat's Universal Commune ref, or #f if not yet spawned."
  *universal-commune-ref*)

(define (reset-universal-commune!)
  "Forget the current UC handle. Test-only: lets a single process spawn
   multiple Universal Communes back-to-back with distinct stores."
  (set! *universal-commune-ref* #f))

(define* (ratify-recomposition! uc-ref proposal-type proposal-spec
                                ballot-said tally
                                #:key
                                (predecessors '())
                                (successor-spec '())
                                (threshold 0.5)
                                (threshold-met? #t))
  "Issue a parent-issued recomposition-ratification ACDC from the
   Universal Commune for a top-level recomposition (federation roots
   with no shared parent).

   Returns the ratification ACDC's SAID. The caller seals this SAID
   into the new scope's inception event via spawn-scope #:anchors.

   D2 extension: also deliver the ratification ACDC to every
   predecessor AID via IPEX. For same-vat predecessors, this is
   redundant (they share the local store the cred just landed in)
   but harmless — `scope-deliver-grant!` is best-effort and no-ops
   when KERIA is unreachable or the scope is synthetic. For remote
   predecessors (cross-gateway recomposition), this is the
   load-bearing delivery path — without it, the remote predecessor
   can't seal the ratification SAID into its successor's icp.a.

   Per democracy-on-keri.md §4.3."
  (let* ((uc-aid    ($ uc-ref 'scope-aid))
         (uc-store  ($ uc-ref 'acdc-store))
         (cred0 (make-recomposition-ratification-credential
                 uc-aid proposal-type proposal-spec
                 ballot-said tally
                 #:threshold      threshold
                 #:threshold-met? threshold-met?
                 #:issuer-aid     uc-aid
                 #:predecessors   predecessors
                 #:successor-spec successor-spec))
         ;; Sign under the UC's own keypair — this is THE authority credential
         ;; every recomposition (merge/split/rejoin) edges to and verifies
         ;; against via verify-ratification!; the derived merger/split records
         ;; lean on it rather than on a self-signature. Issuer = uc-aid, so the
         ;; UC signs its own SAID through its scope ref (keypair stays in the
         ;; actor). The two-layer integrity the comment below promises — sig +
         ;; KEL anchor — is only real with this line; #f-signed in synthetic
         ;; mode where the UC has no keypair.
         (cred (cred-signed-by-scope cred0 uc-ref))
         (said (cred-said cred)))
    (when uc-store
      ($ uc-store 'issue cred))
    ;; OOBI.md §3.2.1 KEL-anchor the ratification into UC's KEL. The
    ;; receiving predecessors see two layers of integrity:
    ;;   - signature on the ACDC verifies under UC's KEL (attached above)
    ;;   - UC's KEL has an ixn digest-seal pointing at the ACDC's SAID
    ;; A repudiation attempt (UC claims they never issued it) would
    ;; require forking the KEL, which witnesses detect. Best-effort:
    ;; the 'anchor-acdc/best-effort method silently no-ops when UC is
    ;; synthetic / has no kel-store (test mode).
    (catch #t
      (lambda () ($ uc-ref 'anchor-acdc/best-effort said))
      (lambda _ #f))
    ;; D2: push the ratification ACDC to each predecessor's AID via
    ;; IPEX, signed under UC's own keypair. UC's scope ref handles
    ;; the signing internally (keypair stays in actor state).
    ;; for-each-catching logs per-predecessor failures without
    ;; aborting the rest — partial delivery is better than none.
    (for-each-catching
     "universal-commune ratification deliver-grant!"
     (lambda (pred-aid) ($ uc-ref 'deliver-grant! said pred-aid))
     predecessors)
    said))

(define (predecessor-list->refs first-ref rest)
  "Accepts either (a-ref b-ref) two-arg form or (predecessor-list)
   one-arg form (list of refs). Returns the canonical list of
   predecessor scope refs."
  (cond
   ((and (pair? rest) (null? (cdr rest))) ; 2-arg legacy form
    (list first-ref (car rest)))
   ((null? rest)                          ; 1-arg list form
    (cond
     ((list? first-ref) first-ref)
     (else (error "merge-bottom-up!: expected predecessor list" first-ref))))
   (else
    (error "merge-bottom-up!: pass either (a b) or (list-of-refs)"))))

(define (resolve-multi-merge-ratifier predecessor-stores predecessor-aids uc-aid)
  "Who ratifies a merge: the parent every predecessor shares, else the
   aggregating one among the shared, else the Universal Commune. Returns (values chosen-aid source stale-saids)."
  (let* ((per-scope-memberships
          (map (lambda (store aid)
                 (federation-memberships-of-holder store aid))
               predecessor-stores predecessor-aids))
         (per-scope-parents
          (map (lambda (mems) (map car mems)) per-scope-memberships))
         (shared
          (cond
           ((null? per-scope-parents) '())
           (else (sort
                  (fold (lambda (ps acc) (lset-intersection equal? ps acc))
                        (car per-scope-parents)
                        (cdr per-scope-parents))
                  string<?))))
         (chosen
          (cond
           ((null? shared) uc-aid)
           (else (car shared))))
         (source
          (cond
           ((null? shared)        'universal-commune)
           ((null? (cdr shared))  'shared-parent)
           (else                  'multiple-shared)))
         (stale-saids
          (apply append
                 (map (lambda (mems)
                        (filter-map
                         (lambda (m)
                           (and (not (equal? (car m) chosen))
                                (cdr m)))
                         mems))
                      per-scope-memberships))))
    (values chosen source stale-saids)))

(define* (merge-bottom-up! first-ref . args)
  "Auto-resolve the merge ratifier and execute a bottom-up merge.

   Two call shapes:

     (merge-bottom-up! a-ref b-ref gov-cap successor-spec #:key …)
       — legacy 2-way; A initiates.

     (merge-bottom-up! '(a-ref b-ref c-ref …) gov-cap successor-spec #:key …)
       — N-way merge of arbitrary M predecessors; the first ref's
         scope is the initiator (its 'merge-with-parent is invoked).

   Flow (now generalised over M predecessors):

   1. Walk every predecessor's federation-memberships.
   2. resolve-multi-merge-ratifier intersects parent sets. The
      ratifier is the unique shared parent if one exists; otherwise UC.
      Memberships pointing at any non-chosen parent become stale.
   3. The ratifier issues a recomposition-ratification ACDC naming all
      M predecessors and the successor-spec.
   4. The first predecessor invokes 'merge-with-parent with the rest
      of the predecessors, the ratification, and the stale list.
   5. C's inception event seals the ratification SAID in icp.a.

   Returns (values c-aid ratifier-ref source rat-said).

   PARENT-RESOLVER, UC-REF, BALLOT-SAID, TALLY: as before.

   Per democracy-on-keri.md §4.3 — previous parents observe via the
   stale-membership edges, they don't ratify."
  ;; Parse args: a list of positional + a tail of keyword pairs.
  (let* ((kw-tail (let loop ((xs args))
                    (cond
                     ((or (null? xs) (null? (cdr xs))) xs)
                     ((keyword? (car xs)) xs)
                     (else (loop (cdr xs))))))
         (pos     (let loop ((xs args))
                    (cond
                     ((eq? xs kw-tail) '())
                     (else (cons (car xs) (loop (cdr xs)))))))
         (parent-resolver
          (or (and (memq #:parent-resolver kw-tail)
                   (cadr (memq #:parent-resolver kw-tail)))
              (lambda (_aid) #f)))
         (uc-ref (or (and (memq #:uc-ref kw-tail)
                          (cadr (memq #:uc-ref kw-tail)))
                     (current-universal-commune)))
         (ballot-said (and (memq #:ballot-said kw-tail)
                           (cadr (memq #:ballot-said kw-tail))))
         (tally (or (and (memq #:tally kw-tail)
                         (cadr (memq #:tally kw-tail)))
                    '((yes . 1.0) (no . 0.0) (abstain . 0.0)))))
    (let* ((predecessor-refs
            (cond
             ;; 2-arg form: (b-ref gov-cap successor-spec) → 3 positional after first-ref
             ((= 3 (length pos))
              (list first-ref (car pos)))
             ;; 1-arg form: first-ref is the list, pos has 2 (gov-cap successor-spec)
             ((and (= 2 (length pos)) (list? first-ref))
              first-ref)
             (else
              (error "merge-bottom-up!: bad arity"
                     (cons first-ref args)))))
           (gov-cap         (cond
                             ((= 3 (length pos)) (cadr pos))
                             (else               (car pos))))
           (successor-spec  (cond
                             ((= 3 (length pos)) (caddr pos))
                             (else               (cadr pos))))
           (initiator       (car predecessor-refs))
           (others          (cdr predecessor-refs))
           (stores          (map (lambda (r) ($ r 'acdc-store))
                                 predecessor-refs))
           (aids            (map (lambda (r) ($ r 'scope-aid))
                                 predecessor-refs))
           (uc-aid          (and uc-ref ($ uc-ref 'scope-aid))))
      (call-with-values
          (lambda ()
            (resolve-multi-merge-ratifier stores aids uc-aid))
        (lambda (chosen-aid source stale-saids)
          (let* ((shared? (memq source '(shared-parent multiple-shared)))
                 (resolved-shared (and shared? (parent-resolver chosen-aid)))
                 (ratifier-ref (or resolved-shared
                                   uc-ref
                                   (error "merge-bottom-up!: no ratifier ref"
                                          chosen-aid)))
                 (effective-source
                  (cond
                   (resolved-shared    source)
                   ((eq? ratifier-ref uc-ref) 'universal-commune)
                   (else               source)))
                 (effective-aid ($ ratifier-ref 'scope-aid))
                 (predecessors-sorted (sort aids string<?))
                 (proposal-spec (list 'merge-with predecessors-sorted))
                 (effective-stale-saids
                  (cond
                   ((eq? ratifier-ref uc-ref)
                    (apply append
                           (map (lambda (s a)
                                  (map cdr
                                       (federation-memberships-of-holder s a)))
                                stores aids)))
                   (else stale-saids)))
                 (rat-said
                  (ratify-recomposition! ratifier-ref
                                         'merge-with proposal-spec
                                         (or ballot-said
                                             (apply string-append
                                                    "E_ballot_"
                                                    (cons (string-join
                                                           predecessors-sorted "_")
                                                          '())))
                                         tally
                                         #:predecessors predecessors-sorted
                                         #:successor-spec successor-spec))
                 (parent-store ($ ratifier-ref 'acdc-store))
                 (c-aid (apply $ initiator 'merge-with-parent-many
                               others gov-cap effective-aid parent-store
                               rat-said successor-spec
                               'stale-memberships effective-stale-saids
                               '())))
            (values c-aid ratifier-ref effective-source rat-said)))))))


;; =========================================================================
;; split-bottom-up! — federation-mediated 1 → N split
;; =========================================================================

(define* (split-bottom-up! a-ref successor-specs gov-cap
                           #:key
                           (parent-resolver (lambda (_aid) #f))
                           (uc-ref (current-universal-commune))
                           (ballot-said #f)
                           (tally '((yes . 1.0) (no . 0.0) (abstain . 0.0))))
  "Federation-mediated 1 → N split (mirror of merge-bottom-up!).

   1. Walk A's federation-memberships → pick ratifier (parent or UC).
   2. Ratifier issues a recomposition-ratification ACDC with
      `proposal-type = 'split` and the list of successor-specs.
   3. For each successor-spec, mint a fresh transferable AID via the
      keri-backend's create-scope-aid, with the ratification SAID
      sealed in `icp.a` — same pattern as merge.
   4. A emits a final dissolution rotation referencing the successor
      AIDs (when keri-backend has rotate-keys; synthetic mode skips).
   5. A issues a `playnet-scope-split/v1` ACDC with NI2I edges to the
      ratification.

   Returns (values successor-aids ratifier-ref source rat-said) where
   successor-aids is a list aligned with SUCCESSOR-SPECS.

   SUCCESSOR-SPECS: a list of alists, one per successor; each describes
   the prospective scope (`((kind . commune) (name . \"A1\") …)`).
   The full list goes into the ratification's `successor-spec` claim
   so a verifier can check that the N inceptions match what was
   ratified."
  (let* ((store-a   ($ a-ref 'acdc-store))
         (a-aid     ($ a-ref 'scope-aid))
         (uc-aid    (and uc-ref ($ uc-ref 'scope-aid))))
    ;; The one-predecessor case of resolve-multi-merge-ratifier.
    (call-with-values
        (lambda ()
          (resolve-multi-merge-ratifier (list store-a) (list a-aid) uc-aid))
      (lambda (chosen-aid source stale-saids)
        (let* ((shared? (memq source '(shared-parent multiple-shared)))
               (resolved-shared (and shared? (parent-resolver chosen-aid)))
               (ratifier-ref (or resolved-shared
                                 uc-ref
                                 (error "split-bottom-up!: no ratifier ref"
                                        chosen-aid)))
               (effective-source
                (cond
                 (resolved-shared             source)
                 ((eq? ratifier-ref uc-ref)   'universal-commune)
                 (else                        source)))
               (effective-aid ($ ratifier-ref 'scope-aid))
               (proposal-spec (cons 'split successor-specs))
               (rat-said
                (ratify-recomposition! ratifier-ref
                                       'split proposal-spec
                                       (or ballot-said
                                           (string-append "E_split_ballot_"
                                                          a-aid))
                                       tally
                                       #:predecessors (list a-aid)
                                       #:successor-spec successor-specs))
               ;; Mint each successor with the ratification SAID sealed.
               (anchors (list (list (cons "d" rat-said))))
               (successor-aids
                ;; In synthetic mode (no keri-backend create-scope-aid),
                ;; the actor's stub mint path returns deterministic AIDs.
                ;; Otherwise call the backend per successor.
                (let ((kb ($ a-ref 'keri-backend)))
                  (cond
                   ((and kb (assq-ref kb 'create-scope-aid))
                    (let ((csa (assq-ref kb 'create-scope-aid)))
                      (map (lambda (_spec)
                             (let ((inception (csa #:anchors anchors)))
                               (scope-inception-aid inception)))
                           successor-specs)))
                   (else
                    (map (lambda (spec)
                           (let ((name (or (assoc-ref spec 'name) "child")))
                             (string-append "E_split_" a-aid "_" name)))
                         successor-specs)))))
               (split-at (instant->unix (clock-now)))
               (merger-edges
                (append
                 (list (cons 'ratification
                             (make-edge rat-said
                                        #:operator 'NI2I
                                        #:schema
                                        *schema-playnet-recomposition-ratification*))))))
          ;; A emits the split ACDC into its store — issuer = a-aid, so A
          ;; signs its own split via its own sign-said (keypair stays inside
          ;; A's actor; #f-signed in synthetic mode where A has no keypair).
          (when store-a
            ($ store-a 'issue
               (cred-signed-by-scope
                (make-scope-split-credential a-aid successor-aids
                                             ($ a-ref 'kind) split-at
                                             #:edges merger-edges)
                a-ref)))
          ;; Best-effort dissolution rotation on A.
          (let ((kb ($ a-ref 'keri-backend)))
            (when (and kb (assq-ref kb 'rotate-keys))
              (catch #t
                (lambda () ((assq-ref kb 'rotate-keys) a-aid #:cuts '(0)))
                (lambda _ #f))))
          (values successor-aids ratifier-ref effective-source rat-said))))))
