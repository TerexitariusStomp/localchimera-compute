;;; commune.scm — facade over ^scope (kind='commune)
;;;
;;; ^commune is a backward-compat alias for ^scope; spawn-commune calls
;;; spawn-scope with kind='commune. All commune-specific methods
;;; (set-ccf, exclude-member, reinstate-member, admit-member,
;;; open-ballot-for-scope, close-ballot, filter-excluded, excluded?,
;;; excluded-aid?) live on ^scope and dispatch by kind.
;;;
;;; Existing call sites using spawn-commune work unchanged.
;;;
;;; A module of (playnet governance); the umbrella re-exports it.


(define-module (playnet governance commune)
  #:use-module (playnet governance scope)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^commune spawn-commune commune-env))

(define ^commune ^scope)

(define* (spawn-commune name scope-root
                        #:key (commune-aid #f) (acdc-store #f))
  "Spawn a commune-kind ^scope wrapping SCOPE-ROOT.

   commune-aid: AID string for this commune's governance group AID.
                Defaults to a synthetic 'E_commune_<name>'.
   acdc-store:  optional ^acdc-store ref. If provided, mutations
                emit + revoke the corresponding playnet-* credentials."
  (spawn-scope name
               #:kind 'commune
               #:scope-root-ref scope-root
               #:scope-aid commune-aid
               #:acdc-store acdc-store))


(define commune-env scope-env)
