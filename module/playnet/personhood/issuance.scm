;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/personhood/issuance.scm — the personhood methods of a scope: PHC issuance and revocation, the issuer blessing, invitations, vouches, enrollment, the trust triangle.
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet personhood issuance)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module (srfi srfi-1)
  #:use-module (playnet personhood enrollment)
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-issuance-doors))

(define (scope-issuance-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

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
                     #:ecosystem-aid scope-aid
                     #:holder-aid candidate-aid
                     #:enrolled-at enrolled-at
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
                    #:root-aid scope-aid
                    #:ecosystem-aid issuer-aid
                    #:blessed-at blessed-at
                    #:signing-keypair keypair)))
         (when keypair
           (assert-signature-binds! aic scope-aid "bless-issuer"))
         ($ acdc-store 'issue aic))))

    ((admit-body gov-cap body-aid . rest)
     ;; A legal body admitted to this scope: the body credential, issued by
     ;; this scope to the body's group AID with the same `issuer-authz` edge
     ;; to the scope's own blessing a personhood credential carries, so a
     ;; verifier walks body → scope → root (docs/legal/bodies.md §3, the
     ;; vLEI's Legal Entity credential in our chain). The admission tests
     ;; are the planner's (legal/bodies.scm); the door asks them first and
     ;; comes here only when none errs. Trailing positional rest:
     ;;   (kind jurisdiction legal-ids quorum admitted-at).
     ;; Idempotent on the body: re-admitting is a no-op, not a duplicate.
     (require-gov-cap! gov-sealed? gov-cap "admit-body" name)
     (require-store!   acdc-store    "admit-body" name)
     (let-optional rest ((kind #f) (jurisdiction #f) (legal-ids '()) (quorum #f)
                         (admitted-at (current-time)))
       (let ((cred (make-body-credential
                    #:ecosystem-aid scope-aid
                    #:body-aid body-aid
                    #:admitted-at admitted-at
                    #:kind kind
                    #:jurisdiction jurisdiction
                    #:legal-ids legal-ids
                    #:quorum quorum
                    #:issuer-authz-said (scope-own-aic-said)
                    #:signing-keypair keypair)))
         (when keypair
           (assert-signature-binds! cred scope-aid "admit-body"))
         ($ acdc-store 'issue-idempotent cred)
         (cred-said cred))))

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
                    #:ecosystem-aid scope-aid
                    #:holder-aid candidate-aid
                    #:enrolled-at enrolled-at
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
                      #:issuer-aid caller-aid
                      #:subject-aid subject-aid
                      #:relationship-type relationship-type
                      #:issuer-phc-said (cred-said caller-phc)
                      #:issued-at (current-time)
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
     (and acdc-store (holds-live-phc? acdc-store scope-aid aid) #t)))))
