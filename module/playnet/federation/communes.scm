;;; module/playnet/federation/communes.scm — the commune and federation methods of a scope: admission near and remote, the federation spec and census, resolution, and recomposition (merge, split, rejoin).
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet federation communes)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet credentials commitments)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials recomposition)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet federation sturdyref-credential) #:select (sturdyref-credentials->spec census-credential-goods census-key-state *schema-playnet-federation-census* *schema-playnet-federation-sturdyref*))
  #:use-module ((playnet keri key-state) #:select (state-sn state-said rotation-count))
  #:use-module (playnet federation scope-graph)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet keri inception)
  #:use-module (playnet federation vows)
  #:use-module (playnet keys exchange)
  #:use-module (goblins ocapn ids)
  #:use-module (srfi srfi-11)
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-communes-doors
            split-scope-with-aids))

(define (scope-communes-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

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

    ;; ====================================================================
    ;; Federation-kind methods (sub-scope membership)
    ;; ====================================================================

    ((member-communes) members)

             ;; alias
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
       (bcom (rebuild #:members (hashmap-set members commune-id commune-ref)))))

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
     (bcom (rebuild #:members (hashmap-remove members commune-id)
                    #:member-sturdyrefs (and member-sturdyrefs
                                             (hashmap-remove member-sturdyrefs commune-id)))))

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
       (bcom (rebuild #:member-sturdyrefs (hashmap-set (or member-sturdyrefs (hashmap))
                                                       commune-id sturdyref-uri)))))

    ;; The federation on the wire, read off its own store: every member's
    ;; sturdyref credential that stands (issued here, not revoked), and the
    ;; roster they make — ((good aid …) …), the members each good crosses
    ;; for. What a member's peer is built with (federation/federate.scm),
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
     (bcom (rebuild #:members (hashmap-set members commune-id commune-ref))))

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
       'ok)))))


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
