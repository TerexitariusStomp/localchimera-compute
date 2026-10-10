;;; credentials/recomposition.scm — scopes recomposed: merger, split, rejoin, conflict resolution.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6). A constructor returns the ACDC bundle as an alist — said, schema, issuer,
;;; holder, claims, edges, revoked? — with its SAID computed over the whole; the
;;; edge block follows ACDC §8 (`make-edge` in (playnet keri acdc)).

(define-module (playnet credentials recomposition)
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

;; The claims the store indexes for this family, for O(1) lookup; registered
;; here at load, so a module that imports one family finds its credentials.
(register-claim-indexes!
 `((,*schema-playnet-scope-merger* . (new-scope-aid))
   (,*schema-playnet-scope-split* . (parent-scope-aid))
   (,*schema-playnet-scope-rejoin* . (scope-aid))
   (,*schema-playnet-conflict-resolution* . (resource-id))))

;; The claim each schema keeps its observation time under (the default is
;; `timestamp`), for the store's time-range queries.
(register-timestamp-claims!
 `((,*schema-playnet-scope-merger* . merged-at)
   (,*schema-playnet-scope-split* . split-at)
   (,*schema-playnet-scope-rejoin* . rejoined-at)
   (,*schema-playnet-conflict-resolution* . resolved-at)))
