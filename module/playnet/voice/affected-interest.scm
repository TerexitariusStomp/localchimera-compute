;;; voice/affected-interest.scm — advisory voice for non-members of a scope
;;;
;;; A scope's decisions can affect groups beyond its formal membership
;;; (downstream watershed users, future generations, neighboring communes).
;;; ^affected-interest-voice is a faceted view of a ^ballot that lets
;;; identified non-member groups cast advisory stances. These stances are
;;; recorded on the ballot in a separate `advisory-stances` map and reported
;;; alongside the binding tally — but they don't contribute weight.
;;;
;;; This is the structural realization of "affected interests can speak
;;; but cannot decide" from GOVERNANCE-PROPORTIONAL.md.
;;;
;;; Identification of affected groups is deliberately out of scope here:
;;; the metabolic-tracing protocol that figures out who's affected is
;;; future work. This module just provides the mechanism once a group
;;; has been identified.
;;;

(define-module (playnet voice affected-interest)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^affected-interest-voice spawn-affected-interest-voice
            affected-interest-env))

;; =========================================================================
;; ^affected-interest-voice — facet over a ballot
;; =========================================================================

(define-actor (^affected-interest-voice bcom
                                        ballot-ref
                                        group-name)
  ;; ballot-ref:  the ^ballot this advisor speaks to.
  ;; group-name:  human-readable label for this affected group, used in
  ;;              audit/display.

  #:version 1

  (methods

    ((group-name) group-name)
    ((ballot-ref) ballot-ref)

    ;; --- Cast an advisory stance ---
    ;; The advisor must have been registered on the ballot via
    ;; (register-advisor aid sealed?-actor) — typically by whoever
    ;; spawned this affected-interest-voice (governance acted on the
    ;; identification of this group as affected).
    ((cast aid stance-bundle)
     ($ ballot-ref 'advisory-cast aid stance-bundle))

    ;; --- Read the binding tally + advisory tally ---
    ((view-tally)        ($ ballot-ref 'tally))
    ((view-advisory)     ($ ballot-ref 'advisory-tally))

    ;; --- Status / metadata ---
    ((status)            ($ ballot-ref 'status))
    ((proposal-id)       ($ ballot-ref 'proposal-id))
    ((description)       ($ ballot-ref 'description))))


;; =========================================================================
;; spawn-affected-interest-voice — convenience constructor
;; =========================================================================

(define (spawn-affected-interest-voice ballot-ref group-name)
  "Create an advisory facet on BALLOT-REF for the named affected group.
   Caller is expected to have identified the group through metabolic
   analysis or governance recognition. Members of the group then need
   to register their AIDs on the ballot via the returned actor (or
   directly on the ballot) before they can advisory-cast."
  (spawn ^affected-interest-voice ballot-ref group-name))


;; =========================================================================
;; Persistence
;; =========================================================================

(define affected-interest-env
  (make-persistence-env
    `((((playnet governance) ^affected-interest-voice)
       ,^affected-interest-voice))))
