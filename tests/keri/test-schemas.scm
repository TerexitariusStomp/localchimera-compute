;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/keri/test-schemas.scm — ACDC role schemas are self-saidified
;;;
;;; Each of the four playnet role-credential schemas
;;; (member/supplier/planner/governor) is a JSON Schema 2020-12 document
;;; whose `$id` field holds its own blake3-256 SAID, computed via
;;; saidify-schema with `$id` blanked to 44 `#` chars.
;;;
;;; This suite asserts, for each schema:
;;;   - file parses as JSON and structurally matches the ACDC envelope
;;;   - recomputing the SAID reproduces the stored `$id` (idempotency)
;;;   - credentials.scm's %schema-* bindings match the stored SAIDs
;;;
;;; Run:
;;;   make test-schemas
;;;
;;; The Makefile's `test-schemas` target also runs
;;; `tools/emit/saidify-schemas.scm --check` as a CI guard against edits that
;;; weren't followed by `make schemas`.

(use-modules (playnet test harness)
             (playnet keri credentials)
             (playnet keri schemas)
             (playnet keri signify)
             (ice-9 format)
             (json)
             (srfi srfi-1))

(define %placeholder (make-string 44 #\#))

(define (alist? x)
  (and (list? x) (not (null? x)) (every pair? x) (every string? (map car x))))

;; Order-preserving parse comes from the catalog module; the SAID
;; recomputation below stays independent of it — that independence is
;; the property under test.
(define read-schema read-schema-alist)

(define (blank-id alist)
  (map (lambda (p) (if (equal? (car p) "$id") (cons "$id" %placeholder) p))
       alist))

(define (expected-said alist)
  (call-with-values
      (lambda () (saidify-schema (blank-id alist)))
    (lambda (_str said _final) said)))

;; Every catalogued schema, paired with its credentials.scm binding —
;; stated explicitly (not derived through the catalog) so a wiring slip
;; between the two modules shows up as a mismatch here.
(define %schemas
  `(("member.json"     ,%schema-member)
    ("supplier.json"   ,%schema-supplier)
    ("planner.json"    ,%schema-planner)
    ("governor.json"   ,%schema-governor)
    ("work-event.json" ,%schema-work-event)
    ("skill.json"      ,%schema-skill)
    ("intent.json"     ,%schema-intent-acdc)
    ("commitment.json" ,%schema-commitment-acdc)
    ("claim.json"      ,%schema-claim)
    ("ownership-attestation.json" ,%schema-ownership-attestation)
    ("personhood.json"        ,%schema-personhood)
    ("membership.json"        ,%schema-membership)
    ("authorized-issuer.json" ,%schema-authorized-issuer)
    ("body.json"              ,%schema-body)
    ("body-role.json"         ,%schema-body-role)))

(format #t "=== ACDC role schemas ===~%")

(for-each
 (lambda (entry)
   (let* ((name     (car entry))
          (bound    (cadr entry))
          (schema   (read-schema name))
          (stored   (assoc-ref schema "$id"))
          (computed (expected-said schema)))
     (format #t "~%-- ~a --~%" name)

     (check (format #f "~a parses as alist" name)
            (alist? schema))

     (check (format #f "~a has `$id` as a qb64 SAID" name)
            (and (string? stored)
                 (= 44 (string-length stored))
                 (char=? #\E (string-ref stored 0))))

     (check (format #f "~a envelope has the ACDC top-level fields" name)
            (every (lambda (k) (assoc-ref schema k))
                   '("$schema" "title" "type" "credentialType"
                     "version" "properties" "required")))

     (check (format #f "~a `$id` matches recomputed SAID (idempotent)" name)
            (string=? stored computed))

     (check (format #f "~a SAID matches the credentials.scm binding" name)
            (string=? stored bound))))
 %schemas)

(format #t "~%=== schema catalog ===~%")

(check "test list covers the whole catalog"
       (equal? (map car %schemas) (map car %schema-catalog)))

(check "all-schema-saids returns one SAID per catalog entry"
       (= (length (all-schema-saids)) (length %schema-catalog)))

;; The serving contract: for each stored SAID, schema-document-for-said
;; returns bytes whose parsed `$id` is that same SAID (what a KERIA
;; resolver re-derives over), and an unknown SAID returns #f.
(for-each
 (lambda (entry)
   (let* ((name (car entry))
          (said (cadr entry))
          (doc  (schema-document-for-said said)))
     (check (format #f "~a served verbatim for its SAID" name)
            (and (string? doc)
                 (equal? said (assoc-ref (json-string->scm doc) "$id"))))))
 %schemas)

(check "unknown SAID serves nothing"
       (not (schema-document-for-said
             (string-append "E" (make-string 43 #\A)))))

(test-summary!)
