;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/org/factories.scm — Org factories and the 3-seal pattern
;;;
;;; Kernel file #3 (alongside gplay.scm and endorsement.scm).
;;; Creates governed and open orgs with proper record wrappers.
;;;
;;; make-governed-org → (values org gov-seal infra-seal member-seal)
;;; make-open-org     → org

(define-module (localchimera org factories)
  #:use-module (goblins)
  #:use-module (localchimera org gplay)
  #:use-module (localchimera lang evaluator)
  #:use-module (localchimera utils endorsement)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-9)
  #:export (make-org
            make-open-org
            make-governed-org
            org?
            org-name
            org-vat
            org-ref)
  #:re-export (default-base-bindings
               make-io-bindings))

;;; ── Org record ────────────────────────────────────────────────────────────

(define-record-type <org>
  (%make-org name vat ref)
  org?
  (name org-name)
  (vat  org-vat)
  (ref  org-ref))

;;; ── Open org ──────────────────────────────────────────────────────────────

(define* (make-org name
                   #:optional (base-bindings default-base-bindings)
                   #:key (output #f))
  "Create an open org (no governance). Optionally route display/write/
   newline/format to OUTPUT (a port). Returns an <org> record."
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let* ((io-bindings (if output
                              (make-io-bindings output)
                              (make-io-bindings)))
             (raw-org (make-initial-org (append io-bindings base-bindings))))
        (%make-org name vat raw-org)))))

;; Back-compat alias — same constructor, different name.
(define make-open-org make-org)

;;; ── Governed org ──────────────────────────────────────────────────────────

(define* (make-governed-org name #:optional (base-bindings default-base-bindings))
  "Create a governed org with 3-seal endorsement pattern.
   Returns (values org gov-seal infra-seal member-seal).

   gov-seal:    sealer actor for governance (enact! validator changes)
   infra-seal:  sealer actor for infra-* names
   member-seal: sealer actor for member-* names"
  (let ((vat (spawn-vat)))
    (with-vat vat
      ;; Create endorsement authorities for the 3-seal pattern
      (receive (gov-seal gov-unseal gov-sealed?)
        (make-endorsement-authority)
        (receive (infra-seal infra-unseal infra-sealed?)
          (make-endorsement-authority)
          (receive (member-seal member-unseal member-sealed?)
            (make-endorsement-authority)
            ;; Build the faceted validator
            (let* ((validator (spawn ^faceted-validator
                                     (list (make-facet (spawn ^name-predicate '(set (validator)))
                                                       gov-sealed?)
                                           (make-facet (spawn ^name-predicate '(prefix "infra-"))
                                                       infra-sealed?)
                                           (make-facet (spawn ^name-predicate '(prefix "member-"))
                                                       member-sealed?))))
                   (endorsement-bindings
                    `((endorse . ,endorse)
                      (endorsed-with? . ,endorsed-with?)))
                   (all-bindings (append endorsement-bindings
                                        (make-io-bindings)
                                        base-bindings))
                   (raw-org (make-initial-org all-bindings #:validator validator)))
              (values (%make-org name vat raw-org)
                      gov-seal infra-seal member-seal))))))))
