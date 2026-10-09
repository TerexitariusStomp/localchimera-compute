;;; module/playnet/governance.scm — the (playnet governance) umbrella module
;;;
;;; Governance actors for liquid democracy on playnet:
;;;   - ^voice-signer — sealer-wrapped political identity
;;;   - ^delegation-map     — per-citizen universal delegation with scope overrides
;;;   - ^ballot             — frozen-snapshot ballot with pure-function tally
;;;
;;; Depends on (playnet planner) for voice-share and related economic
;;; primitives; on (playnet org endorsement) for sealer triplets; and on
;;; Goblins for actor infrastructure.

(define-module (playnet governance)
  #:use-module (playnet governance auditor)
  #:use-module (playnet governance structural-invariants)
  #:use-module (playnet governance federation)
  #:use-module (playnet governance commune)
  #:use-module (playnet governance service)
  #:use-module (playnet governance scope)
  #:use-module (playnet openvtc sybil-detect)
  #:use-module (playnet governance recovery)
  #:use-module (playnet governance expression)
  #:use-module (playnet identity enrollment)
  #:use-module (playnet openvtc personhood-policy)
  #:use-module (playnet governance async)
  #:use-module (playnet governance recipe-standing)
  #:use-module (playnet governance means-fold)
  #:use-module (playnet openvtc first-person)
  #:use-module (playnet governance root-lineage)   ; installs the recomposition walk as the root lineage
  #:use-module (playnet governance ballot)
  #:use-module (playnet governance socialization)
  #:use-module (playnet governance debts)
  #:use-module (playnet governance index-oracle)
  #:use-module (playnet governance delegation-map)
  #:use-module (playnet governance bran-custody)
  #:use-module (playnet governance bootstrap)
  #:use-module (playnet governance acdc-store)
  #:use-module (playnet governance acdc-bridge)
  #:use-module (playnet governance voice-signer)
  #:use-module (playnet governance snapshot)
  #:use-module (playnet governance guardianship)
  #:use-module (playnet governance demand-fold)
  #:use-module (playnet governance credentials)
  #:use-module (playnet governance attestation-ceremony)
  #:use-module (playnet governance affected-interest)
  #:use-module (playnet utils clock)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib cell)
  #:use-module (goblins actor-lib facet)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (gcrypt hash)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri citizen-sig)
  ;; SAID derivation is shared with the browser (see said-portable.scm) so both
  ;; sides derive identical SAIDs — the precondition for client-side citizen
  ;; signing without blind-signing. said-portable is pure (no FFI, so it stays
  ;; Hoot-clean); the server installs the blake3 backend just below, preserving
  ;; the deliberate lazy resolution (no dlopen of libblake3 at load time).
  #:use-module (playnet keri said-portable)
  #:re-export (canonical-string compute-said said-sort-pairs
               install-said-blake3!
              ;; from (playnet governance affected-interest)
              ^affected-interest-voice affected-interest-env
              spawn-affected-interest-voice
              ;; from (playnet governance attestation-ceremony)
              ^attestation-ceremony attestation-ceremony-for land-witness-attestation!
              register-attestation-ceremony! witness-attest-handler
              current-aid-key-resolver
              ;; from (playnet governance credentials)
              *claim-index-registry* *contact-point-kinds* *playnet-schemas*
              *schema-playnet-agreement* *schema-playnet-audit-pass*
              *schema-playnet-authorized-issuer* *schema-playnet-ballot-snapshot*
              *schema-playnet-bran-share* *schema-playnet-ccf-assessment*
              *schema-playnet-claim* *schema-playnet-commitment*
              *schema-playnet-commitment-fulfillment*
              *schema-playnet-conflict-resolution* *schema-playnet-contact-point*
              *schema-playnet-custody-attestation*
              *schema-playnet-custody-transfer-commitment* *schema-playnet-delegation*
              *schema-playnet-derived-state-snapshot* *schema-playnet-exclusion*
              *schema-playnet-expression-stance*
              *schema-playnet-external-index-observation*
              *schema-playnet-federation-membership*
              *schema-playnet-federation-sturdyref* *schema-playnet-federation-census* *schema-playnet-hosting-willingness*
              *schema-playnet-incoherence-alert* *schema-playnet-intent*
              *schema-playnet-membership* *schema-playnet-personhood*
              *schema-playnet-recomposition-ratification*
              *schema-playnet-redistribution-mandate* *schema-playnet-regime-claim*
              *schema-playnet-relationship* *schema-playnet-reversion-attestation*
              *schema-playnet-scope-merger*
              *schema-playnet-scope-rejoin* *schema-playnet-scope-split*
              *schema-playnet-skill* *schema-playnet-span-declaration*
              *schema-playnet-stance* *schema-playnet-tally-result*
              *schema-playnet-witness-assignment* *schema-playnet-work-event*
              *timestamp-claim-registry* audit-witness-quorum-independence
              compile-mandate-spec compute-plan-said contact-point-acceptable?
              contact-point-binding-fields contact-point-identifying?
              contact-point-kind? count-witness-attestors cred-claim cred-claims
              cred-edge cred-edges cred-holder cred-issuer cred-recompute-said
              cred-revoked? cred-said cred-said-consistent? cred-schema cred-signature
              cred-signed-by-scope cred-timestamp cred-with-revoked cred-with-signature
              edge-i2i-holds? edge-operator edge-schema edge-target indexed-claims-for
              iso-utc-now make-agreement-credential make-audit-pass-credential
              make-authorized-issuer-credential make-ballot-snapshot-credential
              make-bran-share-credential make-ccf-credential make-claim-event-credential
              make-commitment-credential make-commitment-fulfillment-credential
              make-conflict-resolution-credential make-contact-point-credential
              make-credential make-custody-attestation-credential
              make-custody-transfer-commitment-credential make-delegation-credential
              make-derived-state-snapshot-credential make-edge make-exclusion-credential
              make-expression-stance-credential
              make-external-index-observation-credential
              make-federation-membership-credential make-federation-sturdyref-credential make-federation-census-credential
              make-hosting-willingness-credential make-incoherence-alert-credential
              make-intent-credential make-membership-credential
              make-personhood-credential make-recomposition-ratification-credential
              make-redistribution-mandate-credential make-regime-claim-credential
              make-relationship-credential make-reversion-attestation-credential
              make-scope-merger-credential
              make-scope-rejoin-credential make-scope-split-credential
              make-skill-credential make-span-declaration-credential
              make-stance-credential make-tally-result-credential
              make-witness-assignment-credential make-work-event-credential mandate
              mandate-spec-of parse-time-value predicate->spec
              register-mandate-predicate timestamp-claim-for
              witness-assignments-for-federation
              ;; from (playnet governance demand-fold)
              ^demand-node cells->horizon demand-cells-of demand-for demand-monoid
              demand-of demand-scope-horizon federation-home-of merge-demand
              scope-own-demand scope-subtree-demand wire-demand-node!
              ;; from (playnet governance guardianship)
              ^guardianship guardianship-env spawn-guardianship
              ;; from (playnet governance snapshot)
              build-citizen-registry build-voice-snapshot citizen-record-delegation-map
              citizen-record-id citizen-record-keri-aid
              ;; from (playnet governance voice-signer)
              ^voice-signer spawn-keri-voice-signer spawn-voice-signer voice-signer-env
              ;; from (playnet governance acdc-bridge)
              ^work-witness attest-contribution! event-log-reconcile!
              gather-witnessed-attestation! open-work-witnessing! witness-work-inbox scope-acdc-store current-vouch-reader
              witness-pending-context remember-remote-witness-request!
              forget-remote-witness-request! remote-witness-request
              held-skill-cred install-credentialing!
              kel-anchored-saids make-credentialing-on-event
              make-plan-credentialing-callbacks mint-skill-if-new!
              reconstruct-claimed-hours reconstruct-credit-balance
              reconstruct-earned-skills reconstruct-practiced-hours skill-held?
              snapshot-complete? snapshot-input-saids snapshot-missing snapshot-over
              spawn-witnessed-work-ceremony witness-quorum work-events-for-skill
              ;; from (playnet governance acdc-store)
              ^acdc-store acdc-store-env non-revoked-by-schema spawn-acdc-store
              ;; from (playnet governance bootstrap)
              ^bootstrap-ceremony bootstrap-ceremony! spawn-bootstrap-ceremony
              ;; from (playnet governance bran-custody)
              ^bran-custodian host-vault-key read-vault-bran read-vault-secret
              reconstitute-bran-from-custodians reconstitute-bran-from-store
              restore-bran-custodian spawn-bran-custodian split-and-issue-bran-shares!
              split-and-spawn-custodians! with-host-vault-key
              write-vault-bran! write-vault-secret!
              ;; from (playnet governance delegation-map)
              ^delegation-map delegation-map-env delegation-sum entry-fraction
              entry-mandate make-entry mandate-satisfied? merge-overrides
              resolve-delegation spawn-delegation-map
              ;; from (playnet governance index-oracle)
              ^index-oracle credential-stream->pairs-fn observation-value
              spawn-index-oracle
              ;; from (playnet governance socialization)
              commune-care-breaches commune-resource-view labour-specs-of verb-specs-of commune-socialized-caps
              consented-span-of
              desocialize-private-resource! federation-resource-resolver live-span-of
              live-willingness-of plan-commune-scope project-socialized-custody
              socialization-care-breaches socialization-care-demand
              socialization-care-terms socialization-credential grant-consume? grant-kind-claim
              socialization-owner-reverter socialize-private-resource socialized-readers
              commune-socialized-slots commune-world commune-demand commune-stamp title-rights-of
              grant-steward-rule commune-steward-rules make-may-steward make-knows vrc-groups-of
              ownership-credential ownership-ok? title-permits?
              %live-ownership-attestations %grant-over? member-consume-grant-total member-consume-grant-over
              ;; from (playnet governance debts)
              money-rate debt-commitment purchase-claim open-debts debt-remaining debt->alist
              open-debts-alist debts-owed-in-xmr settle-debts! %payout-spec
              ;; from (playnet governance ballot)
              ^ballot ballot-env make-citizen-verifier make-sealer-verifier open-ballot
              tally-snapshot voice-snap voice-snap-delegation voice-snap-share
              ;; from (playnet openvtc first-person)
              *default-sponsor-fanout-cap* *default-sponsor-fanout-window*
              aic-valid-by-root? any-live-phc-for assert-sponsor-fanout!
              authorized-issuer-cred cred-live-at? cred-multisig-valid?
              cred-signature-valid? ecosystem-chains-to-any-root? holds-any-live-phc?
              holds-live-phc? issuer-chains-to-root? multi-ecosystem-triangle-holds?
              mutual-vrcs personhood-bootstrapped? phc-chains-to-root? phc-for
              phc-issuer-authz-edge phc-live? phcs-by-ecosystem phcs-in-ecosystem
              root-lineage-closure sponsor-recent-invites trust-triangle-holds?
              vrc-from-to
              ;; from (playnet governance means-fold)
              ^means-pool capacity-bars capacity-cells capacity-facts
              common-span-defaults means-monoid means-refold-listener means-withholding
              scope-own-capacity scope-subtree-capacity wire-means-node!
              withholding-snapshot
              ;; from (playnet governance recipe-standing)
              live-regime-of observer-runs standing-position
              realized-scenario scope-standing
              ;; from (playnet governance async)
              async-sum-over-scopes commune-weight-async global-citizen-claimed-async
              global-citizen-gross-async global-citizen-unmet-async
              global-effective-balance-async global-embodied-labor-in-pool-async
              global-sum-met-capacity-async global-sum-unmet-capacity-async
              global-total-social-svc-async global-citizen-ability-async global-ability-norm-async on->
              open-ballot-async spawn-ballot-from-snapshot tally-mandated-async
              voice-share-async vow-fold-async vow-let*
              ;; from (playnet identity enrollment)
              enrollment-statement-said spawn-enrollment-ceremony
              enroll-ceremony-for-candidate enroll-asks enrollment-record
              witness-recent-enrollments expire-stale-enrollments!
              rehydrate-enrollment-ceremonies! current-enroll-announcer *self-request-evidence*
              ;; from (playnet openvtc personhood-policy)
              personhood-policy *personhood-policy-defaults* effective-k
              ;; from (playnet governance expression)
              ^expression distribution-sum express expression-env open-expression
              tally-expression-snapshot validate-distribution
              ;; from (playnet governance recovery)
              latest-by-claim recover-ballot-state recover-ballots-into-scope!
              recover-commitments recover-commune-state recover-delegation-map
              recover-economic-state recover-federation-state
              recover-federation-state-remote recover-intents recover-lineage
              recover-personhood-state recover-work-events
              ;; from (playnet openvtc sybil-detect)
              detect-suspicious-subgraphs sponsor-fanout-counts suspicious-clusters
              suspicious-sponsors vrc-edges
              ;; from (playnet governance scope)
              ^scope clear-spec-generalizations! federation-memberships-of-holder
              may-govern? open-recomposition-ballot ratification-edges
              register-spec-generalization! resolve-merge-ratifier scope-env spawn-scope kel-identifier register-rotation-keypair-fn! rotation-keypair-fn
              split-scope-with-aids stale-membership-edges verify-parent-ratification!
              ;; from (playnet governance service)
              ^governance-service governance-service-env spawn-governance-service plan-part-hands-of contrary-observations-of contrary-readings-of
              ;; from (playnet governance commune)
              ^commune commune-env spawn-commune
              ;; from (playnet governance federation)
              ^federation federation-env spawn-federation
              ;; from (playnet governance structural-invariants)
              compile-threshold-spec compose-federation-admitting federation-aid-paths
              federation-double-counted-members federation-leaves
              federation-members-attested? federation-membership-paths-unique?
              federation-tree-coherent? federation-unattested-members leaf-member-aids
              leaf-only-labor-coherent? leaf-only-labor-violations
              recomposition-acdc-ratified? recomposition-acdcs-in-tree
              recomposition-ratified? redistribution-coherent?
              redistribution-mandate-breaches scope-has-contributors? scope-leaf?
              tree-credentials-of-schema tree-work-events unratified-recomposition-acdcs
              verify-kind-from-lineage ownership-coherent? ownership-violations
              records-held-once? records-held-twice
              ;; from (playnet governance auditor)
              *auditor-methods-readonly* ^custody-half-life-watcher ^federation-auditor
              spawn-auditor-facet spawn-custody-half-life-watcher
              spawn-federation-auditor)
  #:re-export (make-keri-identity keri-identity?
               keri-identity-aid keri-identity-keypair
               keri-identity-public-key keri-identity-from-seed
               aid-prefix->pubkey sign-said verify-said-signature
               sign-said-multisig verify-said-multisig)
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-random-bytes
                          keri-crypto-hmac-sha256))
  #:use-module ((playnet keri signify-portable)
                #:select (hkdf bran->signing-keypair bran->next-keypair
                          bran->rotation-keypair build-ixn sign-event))
  #:use-module ((playnet utils hex) #:select (bv->hex hex->bv))
  #:use-module ((playnet keri inception)
                #:select (governance-create-scope-aid!
                          <scope-inception> make-scope-inception
                          scope-inception?
                          scope-inception-aid scope-inception-bran
                          scope-inception-keypair
                          scope-inception-next-keypair
                          scope-inception-signed-icp))
  #:use-module ((playnet governance keri federation-peers) #:select (known-uc-aid))
  #:re-export (governance-create-scope-aid!
               <scope-inception> make-scope-inception scope-inception?
               scope-inception-aid scope-inception-bran
               scope-inception-keypair scope-inception-next-keypair
               scope-inception-signed-icp)
  #:use-module (playnet org endorsement)
  #:use-module (ice-9 match)
  #:use-module (playnet governance ballot-store)
  #:use-module ((playnet planner scope live)         ; governance→planner, one direction —
                ;; holding-capacity deliberately NOT selected: the umbrella
                ;; supplies the one conversion, so the two never collide
                #:select (cell declared-period-hours period-span plan-scope
                          plan-scope->alist resource-window-hours set-daily-horizon!
                          ;; the scenario record's own accessors
                          scenario-shocks shock-action shock-key shock-factor))
  ;; the federation fold: ONE walk over the scope tree and ONE keyed-sum
  ;; combine, shared by socialized capacity and declared demand alike
  #:use-module (playnet planner aggregation scope-tree)
  #:use-module (playnet planner aggregation fold-node)
  ;; the unit algebra, for the means fold's rate test (means-fold.scm)
  #:use-module ((playnet utils units) #:select (unit-rate? unit->substance unit-rate-parts))
  ;; the containment climb (a place inside a place, an oven inside a flat)
  #:use-module (playnet planner aggregation containment)
  #:use-module (playnet planner observation event-log-store)
  #:use-module (playnet utils said-store)
  #:use-module (playnet crypto shamir)
  #:use-module (playnet governance paths)
  #:re-export (current-playnet-state-dir-override
               playnet-state-dir scope-state-dir
               scope-acdc-dir scope-kel-dir scope-vault-path
               custodian-share-path
               scope-kind-file read-scope-kind write-scope-kind!
               scope-aid-name-file read-scope-aid-name
               write-scope-aid-name! default-scope-aid-name
               durable-default? default-scope-witnesses
               ensure-directory!)
  #:use-module (playnet governance kel-store)
  #:re-export (^kel-store spawn-kel-store
               kel-event-said kel-event-seq kel-event-type kel-event-aid)
  #:use-module (playnet governance scope-witness)
  #:re-export (^scope-witness spawn-scope-witness
               scope-witness-mirror! scope-witness-kel-for)
  #:use-module (playnet identity oobi-host-mirror)
  #:re-export (^oobi-host-mirror spawn-oobi-host-mirror)
  #:use-module (playnet governance scope-graph)
  #:re-export (^scope-graph current-scope-graph)
  #:use-module (playnet governance audit-scheduler)
  #:re-export (^audit-scheduler spawn-audit-scheduler)
  #:use-module (playnet governance http-witness-publisher)
  #:re-export (^http-witness-publisher spawn-http-witness-publisher)
  #:use-module ((playnet keri witness-publisher)
                #:select (witness-push-urls keri-publish-event!
                          keri-fetch-kel-from-witness))
  #:re-export (witness-push-urls keri-publish-event!
               keri-fetch-kel-from-witness)
  #:use-module ((playnet governance keri scope-exchange) #:select (scope-deliver-grant! governance-cred->wire))
  #:use-module (json)
  #:use-module (goblins ocapn ids)
  #:use-module (playnet governance ballot-store)
  #:re-export (^ballot-store spawn-ballot-store ballot-store-env)
  #:export (;; ACDC layer (Phase-1 in-memory; Phase-2 swaps in KERIA)
            ;; Federation-member witness operation
            ;; Bran custody (Shamir + vault) — (playnet governance bran-custody)
            ;; means-fold: the capacity column of the federation fold
            ;; willingness: consent bounds how far a span may reach
            ;; recipe-standing: observer → runs → one record per recipe
            ;; the witness-gathering ceremony (in-vat slice)
            ;; the trust floor's credential slice: witnessed work events
            ;; demand-fold: declared needs → the demand a solve answers for
            ;; Cross-vat async (vow-based)
            ;; Bootstrap ceremony
            ;; Enrollment ceremony (k-of-n witness co-sign for PHC issuance)
            ;; Unified scope (commune + federation as one actor)
            ;; Bottom-up recomposition (democracy-on-keri.md §4.3)
            ;; Phase-1 hardening: audit + reversion credentials
            ;; Phase-2: commitment fulfillment + spec hierarchy
            ;; Voice and federation aggregation are both universal
            ;; labor-proportional. Voice = gross/total at every level;
            ;; federation aggregation uses commune-weight-async
            ;; (labor-share, hardcoded). No rule-spec schemas, no
            ;; setters, no compilers — the protocol commits.
            ;; Phase-4: redistribution mandates
            ;; Phase-6: recomposition ratification
            ;; Phase-1 actors
            ;; Structural invariants (leaves-are-real)
            ))

;; The server's blake3 backend is installed by (playnet keri said), which the
;; credential layer imports — lazily, so loading governance never dlopens
;; libblake3. (Hoot installs its own noble.js backend instead.)

;; Each of the 29 files this umbrella used to include textually is a module
;; now, imported above. What stood here was a running commentary on INCLUDE
;; ORDER — which file had to precede which — and there is no such order any
;; more: every module names its own dependencies in its own #:use-module
;; list, and Guile resolves the graph. What each file is FOR is stated in
;; that file's header, where it stays true whatever imports it.
