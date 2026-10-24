;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; credentials/audit.scm — what an auditor writes: the audit pass, the incoherence alert, the derived-state snapshot.
;;;
;;; One family of the localchimera credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (localchimera credentials audit)
  #:use-module (localchimera keri acdc)
  #:use-module (srfi srfi-1)
  #:export (*schema-localchimera-audit-pass*
            *schema-localchimera-derived-state-snapshot*
            *schema-localchimera-incoherence-alert*
            make-audit-pass-credential
            make-derived-state-snapshot-credential
            make-incoherence-alert-credential))
(define *schema-localchimera-audit-pass*              "localchimera-audit-pass/v1")
(define *schema-localchimera-incoherence-alert*       "localchimera-incoherence-alert/v1")
;; Scope-recognition: the single credential that materializes the
;; universality-of-contribution measure. A scope SCOPE-AID issues
;; (and self-holds) a recognition naming a target — either a plan
;; (`'plan`) or an intent (`'intent`). The observer's gate reads
;; the union of plan- and intent-level recognitions through one
;; predicate, so weighting (voice-share) and Credit validity
;; (validated-gross) share the same universality measure.
;; Binary by design — no per-credential weight (see L78–84 above);
;; aggregation stays labor-proportional.
;; §4.5: derived-state snapshot. An auditor scope periodically signs a
;; snapshot of derived numbers (voice shares, P_extract, …) plus edges
;; to the input ACDCs the snapshot was computed from. Verifiers see
;; "this snapshot is authenticated by reference to these inputs"
;; without forcing the inputs to be re-signed.
(define *schema-localchimera-derived-state-snapshot* "localchimera-derived-state-snapshot/v1")




;; =========================================================================
;; Phase-1 hardening: audit + reversion credentials
;; =========================================================================


(define-credential (make-audit-pass-credential auditor-aid federation-aid)
  "Heartbeat credential issued when the federation tree passes
   federation-tree-coherent?.

   UNTARGETED (ACDC §7.5): issuer only, no issuee. This is an
   observation the issuer publishes — 'addressed to whom it may
   concern' — not an authorization directed at a target AID that the
   target would present. The spec's own example for this shape is an
   observer that controls an AID publishing verifiable non-repudiable
   measurements. The subject rides in the `federation-aid` claim, so
   nothing is lost by having no issuee.

   SIGNING-KEYPAIR (Ed25519, matching AUDITOR-AID's KERI prefix)
   attaches a CESR signature for KERI portability; bare-data
   deployment passes #f."
  *schema-localchimera-audit-pass*
  #:key ((audited-at #f) (cycle #f))
  #:signed (keypair)
  #:holder #f
  #:claims (federation-aid (audited-at (or audited-at (iso-utc-now))) cycle))

(define-credential (make-incoherence-alert-credential auditor-aid federation-aid violations)
  "Issued when federation-tree-coherent? returns #f. VIOLATIONS is an
   alist of invariant → offending entities.

   UNTARGETED (ACDC §7.5), like make-audit-pass-credential — a
   published observation, not an authorization aimed at an issuee. The
   subject rides in the `federation-aid` claim.

   SIGNING-KEYPAIR optional, see make-audit-pass-credential."
  *schema-localchimera-incoherence-alert*
  #:key ((audited-at #f) (cycle #f))
  #:signed (keypair)
  #:holder #f
  #:claims (federation-aid (audited-at (or audited-at (iso-utc-now))) cycle violations))


(define-credential-procedure (make-derived-state-snapshot-credential auditor-aid scope-aid snapshot-data)
  #:key ((input-saids '())
         (snapshot-at #f)
         (signing-keypair #f))
  "Auditor-issued snapshot of derived state (voice shares, P_extract,
   credit balances, …) for SCOPE-AID, computed from the inputs whose
   SAIDs are in INPUT-SAIDS.

   SNAPSHOT-DATA is SAID material and must be built of readable forms —
   atoms, pairs, alists, vectors. A live hashmap or record here now
   errors loudly at mint time (canonical-string's unrenderable-object
   guard, said-portable.scm) instead of silently hashing the host
   printer's truncated rendering; fold to a key-sorted alist first.

   The snapshot's authenticity comes from (1) the auditor's signature
   and (2) the NI2I edges to every input — a verifier can recompute the
   derived state from the listed inputs and confirm it matches.

   Per democracy-on-keri.md §4.5: this answers \"how do you authenticate
   live derived numbers?\" without re-signing them on every read. The
   inputs (work-event, audit-pass, …) keep their immutable signatures;
   the snapshot is a periodic crystallization with provenance edges."
  (let ((edges
         (let loop ((saids input-saids) (i 1) (acc '()))
           (cond
            ((null? saids) (reverse acc))
            (else
             (let ((label (string->symbol
                           (string-append "input-"
                                          (number->string i)))))
               (loop (cdr saids) (+ i 1)
                     (cons (cons label
                                 (make-edge (car saids)
                                            #:operator 'NI2I
                                            #:schema #f))
                           acc))))))))
    ;; UNTARGETED (ACDC §7.5): a published measurement of derived state, not an
    ;; authorization aimed at an issuee. Both the observer and the subject ride
    ;; in claims (auditor-aid / scope-aid), so no issuee is needed.
    (make-credential *schema-localchimera-derived-state-snapshot*
                     auditor-aid #f
                     (list (cons 'auditor-aid    auditor-aid)
                           (cons 'scope-aid      scope-aid)
                           (cons 'snapshot      snapshot-data)
                           (cons 'snapshot-at   (or snapshot-at
                                                     (iso-utc-now)))
                           (cons 'input-count   (length input-saids)))
                     edges
                     #:signing-keypair signing-keypair)))
