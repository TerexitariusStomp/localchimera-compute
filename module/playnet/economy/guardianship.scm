;;; economy/guardianship.scm — documentary guardian↔ward primitive
;;;
;;; Voice in playnet is pure labor proportion: a citizen with no labor
;;; (CCF=0 infants, severe dementia, etc.) has voice-share = 0. They are
;;; politically absent under the pure rule. Guardianship is the social
;;; institution that lets a guardian "speak for" such a ward — without,
;;; in this first pass, modifying the voice equation.
;;;
;;; This primitive records the guardian↔ward relationship and provides
;;; a way for the guardian to attach an `on-behalf-of` annotation to
;;; their own stance. The ballot stores the annotation alongside the
;;; cleartext but the tally weight is unchanged — the guardian votes
;;; with their own voice; the ward's voice is still 0.
;;;
;;; This is intentionally a minimum viable primitive. Three voice-math
;;; alternatives (guardian gets a bump, welfare contributes to voice,
;;; or strict zero) are documented in
;;; docs/governance/GUARDIANSHIP-DESIGN.md. The community can pick one
;;; and extend later; the relationship-tracking layer here is a
;;; prerequisite either way.
;;;

(define-module (playnet economy guardianship)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^guardianship spawn-guardianship guardianship-env))

;; =========================================================================
;; ^guardianship — relationship + on-behalf-of cast helper
;; =========================================================================

(define-actor (^guardianship bcom
                             guardian-aid
                             ward-aid
                             guardian-voice    ;; ^voice-signer ref for guardian
                             authorizing-scope ;; commune name (string), informational
                             established-at)   ;; epoch seconds, informational
  #:version 1

  (methods

    ((guardian-aid)        guardian-aid)
    ((ward-aid)            ward-aid)
    ((authorizing-scope)   authorizing-scope)
    ((established-at)      established-at)

    ;; --- Cast a stance attributing on-behalf-of the ward ---
    ;;
    ;; Returns a 2-element list:
    ;;   (stance-bundle on-behalf-of)
    ;; where stance-bundle is the regular (cleartext . sealed) pair from
     ;; ^voice-signer, and on-behalf-of is the ward-aid string (or list).
    ;;
    ;; Caller hands stance-bundle to ballot.cast (binding voice = guardian's
    ;; own voice, unchanged) and may publish on-behalf-of in deliberation
    ;; channels for transparency. Ballot doesn't currently consume the
    ;; on-behalf-of annotation — voice math unchanged. Future variants
    ;; (see GUARDIANSHIP-DESIGN.md) may extend the ballot to pick it up.
    ((stance-on-behalf proposal-id position)
     (let ((stance-bundle ($ guardian-voice 'stance proposal-id position)))
       (list stance-bundle (list 'on-behalf-of ward-aid))))))


;; =========================================================================
;; spawn-guardianship
;; =========================================================================

(define (spawn-guardianship guardian-aid ward-aid guardian-voice
                            authorizing-scope established-at)
  "Establish a guardianship relationship. Returns the actor ref.

   guardian-aid:        AID of the guardian
   ward-aid:            AID of the ward
   guardian-voice:      ^voice-signer actor for the guardian (must be in
                        the same vat); used to produce stance bundles
   authorizing-scope:   string name of the scope that recognized this
                        guardianship (informational)
   established-at:      epoch seconds when this was established (informational)

   Voice math is unchanged: ward stays voice=0, guardian votes with their
   own voice. The guardianship just provides an audit-trail annotation."
  (spawn ^guardianship guardian-aid ward-aid guardian-voice
         authorizing-scope established-at))


;; =========================================================================
;; Persistence
;; =========================================================================

(define guardianship-env
  (make-persistence-env
    `((((playnet economy guardianship) ^guardianship) ,^guardianship))))
