;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-span-declaration.scm — span is governed, location is fact: the
;;; credential half. A steward scope declares how far a means' service pools
;;; (patchwork-scopes-containment.md §2.2–2.3); the declaration is a
;;; scope-signed ACDC on the scope's own TEL, window-bounded, and read as a
;;; per-solve view (`live-span-of`) into the alist the planner's #:span-of
;;; takes. The planner half is test-span-declaration.scm.

(use-modules (playnet test harness))
(use-modules (srfi srfi-1))
(use-modules (playnet credentials declarations) (playnet keri acdc) (playnet economy socialization) (playnet keri acdc) (playnet keri acdc-store))
(use-modules (goblins))
(use-modules (srfi srfi-1))

(define SCOPE  "EWorkshopScope")
(define LATHE  "lathe-1")
(define FUTURE "2099-12-31T00:00:00Z")
(define PAST   "2000-01-01T00:00:00Z")

(display "\n── 1. The declaration: scope-signed, references a place ──\n")

(let ((d (make-span-declaration-credential #:scope-aid SCOPE
                                           #:resource-id LATHE
                                           #:span-place "town"
                                           #:valid-until FUTURE)))
  (check-pred "issuer = the steward scope"  (equal? SCOPE (cred-issuer d)))
  (check-pred "holder = the same scope (its own governed act)"
              (equal? SCOPE (cred-holder d)))
  (check-pred "span schema" (equal? *schema-playnet-span-declaration* (cred-schema d)))
  (check-pred "names the resource"  (equal? LATHE (cred-claim d 'resource-id)))
  (check-pred "references the place, never is one"
              (equal? "town" (cred-claim d 'span-place)))
  (check-pred "window bounded" (equal? FUTURE (cred-claim d 'valid-until))))

(define vat (spawn-vat))

(display "\n── 2. live-span-of: the per-solve view ──\n")

(with-vat vat
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid SCOPE
                                                      #:resource-id LATHE
                                                      #:span-place "town"
                                                      #:valid-until FUTURE))
    ($ store 'issue (make-span-declaration-credential #:scope-aid SCOPE
                                                      #:resource-id "oven-9"
                                                      #:span-place "kitchen"))   ; open-ended
    (let ((span-of (live-span-of store)))
      (check-pred "a live declaration projects"
                  (equal? "town" (assoc-ref span-of LATHE)))
      (check-pred "an open-ended one projects too"
                  (equal? "kitchen" (assoc-ref span-of "oven-9")))
      (check-pred "the view is the planner's #:span-of shape"
                  (every (lambda (p) (and (string? (car p)) (string? (cdr p)))) span-of)))))

(display "\n── 3. A lapsed declaration stops projecting — the pool reverts ──\n")

(with-vat vat
  (let ((store (spawn-acdc-store)))
    ($ store 'issue (make-span-declaration-credential #:scope-aid SCOPE
                                                      #:resource-id LATHE
                                                      #:span-place "town"
                                                      #:valid-until PAST))
    (check-pred "lapsed ⇒ absent from the view (span reverts to the holding place)"
                (not (assoc-ref (live-span-of store) LATHE)))))

(display "\n── 4. Revocation is the scope's own, and immediate ──\n")

(with-vat vat
  (let* ((store (spawn-acdc-store))
         (d     (make-span-declaration-credential #:scope-aid SCOPE
                                                  #:resource-id LATHE
                                                  #:span-place "town"
                                                  #:valid-until FUTURE)))
    ($ store 'issue d)
    (check-pred "projects while live" (equal? "town" (assoc-ref (live-span-of store) LATHE)))
    ($ store 'revoke (cred-said d))
    (check-pred "revoked ⇒ gone from the view, no further event"
                (not (assoc-ref (live-span-of store) LATHE)))))

(test-summary!)
