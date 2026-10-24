;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; voice/demand-bridge.scm — promote tallied demands into VF proposals
;;;
;;; Closes the loop: an ^expression with `domain='demand` whose
;;; target-ids are demand-ids, once tallied, tells us which demands in
;;; a scope are socially recognized (labor-share-weighted). This module
;;; takes that ranking and materializes the top entries as VF
;;; <proposal> + <intent> records in the scope's plan-store, copying
;;; through whatever partial-intent fields the proposer (and later
;;; elaborators) filled in, and marks them promoted in the demand-
;;; registry.
;;;
;;; Threshold semantics: a demand is promoted iff its weighted tally is
;;; ≥ threshold, in the same units as the voice-shares given to
;;; open-expression.

(define-module (localchimera voice demand-bridge)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera scope demand-registry)
  #:use-module ((localchimera keri first-person predicates) #:select (holds-any-live-phc?))
  #:export (promote-demands demand-entry->intent any-live-phc-holder-elaborate?))


(define (demand-entry->intent entry scope-name)
  "Build an <intent> from a demand-registry ENTRY, using SCOPE-NAME as
   the receiver. Fields that are #f in the entry stay #f on the
   intent; the planner treats them as open/unspecified until elaborated.
   A <measure> is reconstructed from (quantity-value . quantity-unit)
   iff both are present."
  (let* ((qv (demand-entry-quantity-value entry))
         (qu (demand-entry-quantity-unit  entry))
         (quantity (and qv qu (make-measure qv qu))))
    ;; the id is the caller's to assign; the provider stays open
    (make-intent #:action 'use
                 #:name (demand-entry-description entry)
                 #:note "auto-promoted from weighted voice tally"
                 #:resource-conforms-to (demand-entry-resource-conforms-to entry)
                 #:resource-classified-as (demand-entry-resource-classified-as entry)
                 #:resource-quantity quantity
                 #:receiver scope-name
                 #:has-beginning (demand-entry-has-beginning entry)
                 #:has-end (demand-entry-has-end entry)
                 #:at-location (demand-entry-at-location entry)
                 #:in-scope-of (list scope-name))))


(define* (promote-demands scope-root expression threshold
                          #:key (acceptors '()))
  "Read EXPRESSION's result, for every demand whose weighted tally is
   ≥ THRESHOLD look up the demand in SCOPE-ROOT's demand-registry,
   materialize a VF <intent> + <proposal> in the plan-store (copying
   through any partial-intent fields), and mark the demand promoted.
   Must be called within the same vat as SCOPE-ROOT.

   ACCEPTORS: optional list of agent-ids who are authorized to call
   accept-proposal on the promoted proposals. Landed on the proposal's
   proposed-to field; the planner's accept-proposal enforces the
   whitelist. Empty list = open (anyone can accept).

   Returns a list of (demand-id . proposal-id) pairs for the promoted
   set, in descending tally order."
  (let* ((registry   ($ scope-root 'demand-registry))
         (plan-store ($ scope-root 'plan-store))
         (scope-name ($ scope-root 'name))
         (result     ($ expression 'result))
         (ranked     (assoc-ref result 'ranked)))
    (filter-map
      (lambda (entry)
        (let ((demand-id (car entry))
              (weight    (cdr entry)))
          (cond
            ((< weight threshold) #f)
            (else
             (let* ((dreg-entry ($ registry 'get demand-id))
                    (_ (unless dreg-entry
                         (error "Tally references unknown demand-id"
                                demand-id)))
                    (description (demand-entry-description dreg-entry))
                    (proposal-id (string-append demand-id "-proposal"))
                    (intent      (demand-entry->intent dreg-entry scope-name))
                    (intent-id   ($ plan-store 'add-intent intent))
                    (proposal
                     (make-proposal
                       #:id proposal-id               ;; id
                       #:name description               ;; name
                        ;; note
                       #:has-beginning (demand-entry-has-beginning dreg-entry)
                       #:has-end (demand-entry-has-end       dreg-entry)                        ;; unit-based
                        ;; created
                       #:purpose 'request                  ;; purpose (demand-side)
                       #:eligible-location (demand-entry-at-location dreg-entry)
                       #:in-scope-of (list scope-name)         ;; in-scope-of
                       #:publishes (list intent-id)          ;; publishes
                       #:reciprocal '()                       ;; reciprocal
                       #:proposed-to acceptors)))              ;; proposed-to
               ($ plan-store 'add-proposal proposal)
               ($ registry 'mark-promoted demand-id proposal-id)
               (cons demand-id proposal-id))))))
      ranked)))


(define (any-live-phc-holder-elaborate? acdc-store)
  "Return a CAN-ELABORATE? predicate (for spawn-demand-registry, localchimera
   governance demand-registry) admitting any caller holding a live
   personhood credential in ACDC-STORE, in any ecosystem — the same
   portable-personhood check open-terminal/get-mailbox and
   accept-socialization gate on elsewhere. Lives here rather than in
   demand-registry.scm itself: first-person.scm's own dependency chain
   (first-person → credentials → planner) loops back through demand-
   registry.scm, so importing it there would be circular."
  (lambda (caller-id entry)
    (holds-any-live-phc? acdc-store caller-id)))
