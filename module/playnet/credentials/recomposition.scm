;;; credentials/recomposition.scm — scopes recomposed: merger, split, rejoin, conflict resolution.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials recomposition)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
  #:export (*schema-playnet-conflict-resolution*
            *schema-playnet-scope-merger*
            *schema-playnet-scope-rejoin*
            *schema-playnet-scope-split*
            make-conflict-resolution-credential
            make-scope-merger-credential
            make-scope-rejoin-credential
            make-scope-split-credential))
(define *schema-playnet-scope-merger*            "playnet-scope-merger/v1")
(define *schema-playnet-scope-split*             "playnet-scope-split/v1")
(define *schema-playnet-scope-rejoin*            "playnet-scope-rejoin/v1")
(define *schema-playnet-conflict-resolution*     "playnet-conflict-resolution/v1")

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

(define-credential (make-scope-split-credential parent-scope-aid sub-scope-aids kind split-at)
  "One scope partitions into N sub-scopes.
   issuer = parent; holder = parent (self-attested split event).
   sub-scope-aids: list of new sub-scope AIDs.
   EDGES: optional extra ACDC edges (Phase-6 ratification, etc.)."
  *schema-playnet-scope-split*
  #:key ((edges '()))
  #:signed (keypair multisig)
  #:holder parent-scope-aid
  #:claims (parent-scope-aid sub-scope-aids kind split-at)
  #:edges ((@ edges))
  #:index (parent-scope-aid)
  #:time split-at)

(define-credential (make-conflict-resolution-credential meta-scope-aid resource-id conflicting-commitments prevailing-commitment resolution-method resolved-at)
  "Meta-scope (federation) records resolution of overlapping commitments
   on RESOURCE-ID. conflicting-commitments: list of commitment-SAIDs.
   prevailing-commitment: SAID that wins (#f for split/mediation).
   resolution-method: symbol — 'fifo / 'priority / 'mediation / 'split / etc."
  *schema-playnet-conflict-resolution*
  #:signed (keypair multisig)
  #:holder meta-scope-aid
  #:claims (resource-id conflicting-commitments prevailing-commitment resolution-method resolved-at)
  #:index (resource-id)
  #:time resolved-at)

(define-credential (make-scope-rejoin-credential scope-aid old-federation-aid new-federation-aid rejoined-at)
  "Scope changes its parent federation.
   issuer = scope-aid; holder = scope-aid (self-attested move).
   Old federation also revokes membership ACDC; new issues fresh one.
   EDGES: optional extra ACDC edges (Phase-6 ratification, etc.)."
  *schema-playnet-scope-rejoin*
  #:key ((edges '()))
  #:signed (keypair multisig)
  #:holder scope-aid
  #:claims (scope-aid old-federation-aid new-federation-aid rejoined-at)
  #:edges ((@ edges))
  #:index (scope-aid)
  #:time rejoined-at)

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-scope-merger* (new-scope-aid) merged-at)))
