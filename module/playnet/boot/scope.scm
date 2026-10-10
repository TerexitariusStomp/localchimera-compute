;;; module/playnet/boot/scope.scm — a scope composed from its fragments.
;;;
;;; The composition root's word on what a scope is: the actor (playnet scope
;;; actor) and the nine fragments of docs/planning/codebase-layout.md §5, set
;;; once per process so every spawn and every restore composes the same actor.
;;; Import this module wherever scopes are spawned or restored — the gateway,
;;; the test suites — and (playnet scope actor) where only the record and the
;;; helpers are read. spawn-commune and spawn-federation are the two spellings
;;; of spawn-scope by kind the suites use.

(define-module (playnet boot scope)
  #:use-module (playnet scope actor)
  #:use-module (playnet federation root-lineage)   ;; load: a scope recomposes; the lineage walk installs with the composition
  #:use-module ((playnet scope keys) #:select (scope-keys-doors))
  #:use-module ((playnet scope capabilities) #:select (scope-capabilities-doors))
  #:use-module ((playnet scope membership) #:select (scope-membership-doors))
  #:use-module ((playnet scope custody) #:select (scope-custody-doors))
  #:use-module ((playnet federation communes) #:select (scope-communes-doors split-scope-with-aids))
  #:use-module ((playnet federation conflicts) #:select (scope-conflicts-doors))
  #:use-module ((playnet voice scope-ballots) #:select (scope-ballots-doors open-recomposition-ballot))
  #:use-module ((playnet personhood issuance) #:select (scope-issuance-doors))
  #:use-module ((playnet economy acceptance) #:select (scope-acceptance-doors))
  #:re-export (any-cred-by-said
               verify-ratification!
               require-ratification!
               may-govern?
               verify-parent-ratification!
               federation-memberships-of
               federation-memberships-of-holder
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
               split-scope-with-aids open-recomposition-ballot)
  #:export (spawn-commune spawn-federation))

(set-scope-fragments!
 (list scope-keys-doors scope-capabilities-doors scope-membership-doors scope-custody-doors
       scope-communes-doors scope-conflicts-doors scope-ballots-doors
       scope-issuance-doors scope-acceptance-doors))

(define* (spawn-commune name scope-root #:key (commune-aid #f) (acdc-store #f))
  "A commune-kind scope over SCOPE-ROOT; COMMUNE-AID defaults to a synthetic one."
  (spawn-scope name #:kind 'commune #:scope-root-ref scope-root
               #:scope-aid commune-aid #:acdc-store acdc-store))

(define* (spawn-federation name #:key (federation-aid #f) (acdc-store #f) (mycapn-ref #f))
  "A federation-kind scope; FEDERATION-AID defaults to a synthetic one."
  (spawn-scope name #:kind 'federation #:scope-aid federation-aid
               #:acdc-store acdc-store #:mycapn-ref mycapn-ref))
