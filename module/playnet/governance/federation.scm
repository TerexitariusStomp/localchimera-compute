;;; federation.scm — facade over ^scope (kind='federation)
;;;
;;; ^federation is a backward-compat alias for ^scope; spawn-federation
;;; calls spawn-scope with kind='federation. All federation-specific
;;; methods (admit-commune, remove-commune, member-communes, commune-weight,
;;; receive-commune-stance, tally-mandated, open-direct-ballot, sturdyref
;;; resolution, find-commitment-by-id) live on ^scope and dispatch by kind.
;;;
;;; Existing call sites using spawn-federation work unchanged.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


(define-module (playnet governance federation)
  #:use-module (playnet governance scope)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^federation spawn-federation federation-env))

(define ^federation ^scope)

(define* (spawn-federation name
                           #:key (federation-aid #f) (acdc-store #f)
                                 (mycapn-ref #f))
  "Spawn a federation-kind ^scope.

   federation-aid: AID string for the federation's governance group AID.
                   Defaults to a synthetic 'E_federation_<name>'.
   acdc-store:     optional ^acdc-store ref for emission.
   mycapn-ref:     mycapn actor ref for resolving remote commune sturdyrefs."
  (spawn-scope name
               #:kind 'federation
               #:scope-aid federation-aid
               #:acdc-store acdc-store
               #:mycapn-ref mycapn-ref))


(define federation-env scope-env)
