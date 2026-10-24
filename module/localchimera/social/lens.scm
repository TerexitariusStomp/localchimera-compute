;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; social/lens.scm — a named neighbourhood of AIDs over the social graph.
;;;
;;; A LENS names WHOSE assertions count when a collaborative signal is weighted:
;;; the folksonomy's "my friends' cut" vs the global majority (folksonomy.md
;;; §Collaborative filtering), and — ahead — the matcher's tilt toward taxonomic
;;; kin (Phase 5). It is deliberately tiny and DATA-DRIVEN: any contact `rel`
;;; value is itself a valid lens name, so new relationship kinds (friend, family,
;;; commons, colleague, or a custom one) become lenses for free, no code change.
;;;
;;; The split that matters: resolve-lens returns the AID SET (or #f for the whole
;;; population); the consumer builds the aid→bool predicate LOCALLY with
;;; lens-predicate. A closure can't cross an OCapN vat boundary, so the set
;;; travels the wire and the predicate is built where the weighting runs. This is
;;; why the folksonomy's coarse scope-tree lens (which scope you read) and this
;;; fine social lens compose cleanly — both end up as a plain aid→bool.

(define-module (localchimera social lens)
  #:use-module (srfi srfi-1)
  #:use-module ((localchimera social relationship-kinds) #:select (normalize-rel rel=?))
  #:export (resolve-lens lens-predicate %lens-everyone
            contact-aid contact-rel))

(define (contact-field c key)
  ;; tolerant of symbol- OR string-keyed alists (the synced book is symbol-keyed)
  (let ((p (or (assq key c) (assoc (symbol->string key) c))))
    (and p (cdr p))))

(define (contact-aid c) (or (contact-field c 'aid) (contact-field c 'prefix)))
(define (contact-rel c) (normalize-rel (contact-field c 'rel)))

(define %lens-everyone #f)   ; the whole population — no weighting

(define (resolve-lens name contacts self-aid)
  "Resolve lens NAME to a list of AIDs, or #f for the whole population.
   CONTACTS is the caller's contact book (alists carrying aid/prefix + rel).
   Special names: everyone/all/global/\"\"/#f → #f; me/self → (self-aid);
   contacts/network → all contacts. Any OTHER name matches contacts' `rel`, so
   friends/family/commons/colleague/… all work, and so does any custom rel."
  (cond
   ;; "social" = the whole commons (the dial's social⇄individual toggle) — the
   ;; UC-level aggregate, i.e. no weighting. "individual" = just you.
   ((or (not name) (member name '("" "everyone" "all" "global" "social")))
    %lens-everyone)
   ((member name '("me" "self" "individual")) (if self-aid (list self-aid) '()))
   ((member name '("contacts" "network" "all-contacts"))
    (filter-map contact-aid contacts))
   (else
    (filter-map (lambda (c) (and (rel=? (contact-rel c) name)
                                 (contact-aid c)))
                contacts))))

(define (lens-predicate aids)
  "Build the aid→bool predicate from a resolved lens. #f (everyone) stays #f,
   which every consumer reads as 'apply no weighting' (folksonomy-template
   treats a #f lens as the global cut)."
  (and aids (lambda (aid) (and (member aid aids) #t))))
