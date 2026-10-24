;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; credentials/registry.scm — the catalogue of localchimera schemas, the claim-index and timestamp registries, the plan SAID, and a scope's signature over a credential.
;;;
;;; The localchimera credential catalogue stands in this directory by family
;;; (docs/planning/codebase-layout.md §6), and this module holds what every
;;; family shares. Each `make-*-credential` is a pure-data constructor returning
;;; the ACDC bundle as an alist:
;;;
;;;   ((said       . string)        ; deterministic blake3 SAID (CESR "E")
;;;    (schema     . string)        ; one of *localchimera-schemas*
;;;    (issuer     . string)        ; AID of issuer
;;;    (holder     . string)        ; AID of holder (subject)
;;;    (claims     . alist)         ; schema-specific (ACDC `a` block)
;;;    (edges      . alist)         ; ACDC `e` block — see `make-edge`
;;;    (revoked?   . boolean))      ; live-mutable in ^acdc-store
;;;
;;; Edges follow ACDC §8: a chained reference from this credential to another
;;; by SAID, with an optional operator constraining the chain, as an alist of
;;; (edge-name . edge-spec) where edge-spec is an alist with keys n (the target
;;; SAID, required), o (the operator: 'I2I, 'NI2I or #f) and s (the target
;;; schema, informational). The SAID folds the edge block in, so any edge change
;;; changes the SAID — ACDC's invariant that `e` is SAID-covered.
;;;
;;; A family registers what the store knows of its schemas at its own load
;;; (`register-schema-claims!` in (localchimera keri acdc)), so a module that imports
;;; one family finds its credentials indexed.

(define-module (localchimera credentials registry)
  #:use-module (localchimera keri acdc)
  #:use-module (localchimera keri first-person credentials)
  #:use-module (localchimera keri said-portable)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera keri citizen-sig)
  #:use-module (goblins)
  #:use-module ((localchimera credentials audit) #:select (*schema-localchimera-audit-pass* *schema-localchimera-derived-state-snapshot* *schema-localchimera-incoherence-alert*))
  #:use-module ((localchimera credentials commitments) #:select (*schema-localchimera-agreement* *schema-localchimera-commitment* *schema-localchimera-commitment-fulfillment* *schema-localchimera-intent* *schema-localchimera-redistribution-mandate*))
  #:use-module ((localchimera credentials custody) #:select (*schema-localchimera-custody-attestation* *schema-localchimera-custody-transfer-commitment* *schema-localchimera-ownership-attestation* *schema-localchimera-reversion-attestation*))
  #:use-module ((localchimera credentials delegation) #:select (*schema-localchimera-delegation*))
  #:use-module ((localchimera credentials keys) #:select (*schema-localchimera-bran-share* *schema-localchimera-witness-assignment*))
  #:use-module ((localchimera credentials membership) #:select (*schema-localchimera-ccf-assessment* *schema-localchimera-exclusion* *schema-localchimera-federation-census* *schema-localchimera-federation-membership* *schema-localchimera-federation-sturdyref* *schema-localchimera-membership*))
  #:use-module ((localchimera credentials recomposition) #:select (*schema-localchimera-conflict-resolution* *schema-localchimera-scope-merger* *schema-localchimera-scope-rejoin* *schema-localchimera-scope-split*))
  #:use-module ((localchimera credentials voting) #:select (*schema-localchimera-ballot-snapshot* *schema-localchimera-expression-stance* *schema-localchimera-recomposition-ratification* *schema-localchimera-stance* *schema-localchimera-tally-result*))
  #:use-module ((localchimera credentials work) #:select (*schema-localchimera-claim* *schema-localchimera-contrary-observation* *schema-localchimera-external-index-observation* *schema-localchimera-observation-event* *schema-localchimera-skill* *schema-localchimera-work-event*))
  #:export (*localchimera-schemas* compute-plan-said cred-signed-by-scope))
(define *localchimera-schemas*
  (list *schema-localchimera-delegation*
        *schema-localchimera-ccf-assessment*
        *schema-localchimera-exclusion*
        *schema-localchimera-federation-membership*
        *schema-localchimera-membership*
        *schema-localchimera-bran-share*
        *schema-localchimera-federation-sturdyref*
        *schema-localchimera-federation-census*
        *schema-localchimera-stance*
        *schema-localchimera-expression-stance*
        *schema-localchimera-ballot-snapshot*
        *schema-localchimera-tally-result*
        *schema-localchimera-work-event*
        *schema-localchimera-observation-event*
        *schema-localchimera-commitment*
        *schema-localchimera-scope-merger*
        *schema-localchimera-scope-split*
        *schema-localchimera-scope-rejoin*
        *schema-localchimera-conflict-resolution*
        *schema-localchimera-intent*
        *schema-localchimera-agreement*
        *schema-localchimera-external-index-observation*
        *schema-localchimera-personhood*
        *schema-localchimera-relationship*
        *schema-localchimera-contact-point*
        *schema-localchimera-authorized-issuer*
        *schema-localchimera-device-authorization*
        *schema-localchimera-custody-attestation*
        *schema-localchimera-ownership-attestation*
        *schema-localchimera-custody-transfer-commitment*
        *schema-localchimera-audit-pass*
        *schema-localchimera-incoherence-alert*
        *schema-localchimera-reversion-attestation*
        *schema-localchimera-derived-state-snapshot*
        *schema-localchimera-commitment-fulfillment*
        *schema-localchimera-redistribution-mandate*
        *schema-localchimera-recomposition-ratification*
        *schema-localchimera-witness-assignment*
        *schema-localchimera-skill*
        *schema-localchimera-claim*))



;; =========================================================================
;; Deterministic SAID — Blake3-256 of canonical content, CESR "E" code
;; =========================================================================
;;
;; KERI SAIDs are Blake3-256 digests CESR-encoded under code "E" (44
;; qb64 chars). `signify.scm` uses libblake3 for real KERI events; the
;; governance layer uses the same hash through `(localchimera keri blake3)`
;; so that credentials issued by ^acdc-store and by a real KERIA
;; backend share a hash function — a foreign KERI verifier can check
;; either without knowing where it came from.
;;
;; libblake3.so is loaded lazily: the credential layer loads even
;; when the FFI library isn't present, but actually computing a SAID
;; requires the library. Tests run via `make test-governance`, which
;; enters a guix shell that includes the `blake3` package.

;; canonical-string / said-sort-pairs / compute-said now live in
;; (localchimera keri said-portable) — imported by governance.scm and re-exported —
;; so the BROWSER derives byte-identical SAIDs. A citizen's KERI key is
;; client-side, so a citizen-issued ACDC can only be a conformant ACDC if the
;; citizen's own controller signs it; to sign without blind-signing, the client
;; must re-derive the SAID from the claims itself. Behaviour here is unchanged
;; (same canonicalization, same lazy-FFI blake3 default).

(define* (compute-plan-said scope-aid intent-ids #:optional (extra-claims '()))
  "Content-addressed plan-id: SAID over the scope-aid + the sorted
   intent set. Same intent set under the same scope produces the same
   SAID (convergence); any change to the intent membership produces
   a different SAID (no silent amendment of confirmed plans).

   EXTRA-CLAIMS lets callers fold in additional content (plan name,
   horizon, etc.) — anything in EXTRA-CLAIMS becomes part of the
   identity. Pass '() for the canonical \"plan = its intents\" form.

   Intent ordering is normalized via string<? sort so the same set
   produces the same SAID regardless of insertion order. The result
   is a CESR qb64 SAID (44 chars, prefix 'E'), drop-in usable
   anywhere a plan-id string is expected."
  (compute-said scope-aid scope-aid 'localchimera-plan-v1
                `((intents . ,(sort intent-ids string<?))
                  ,@extra-claims)))



(define (cred-signed-by-scope cred scope-ref)
  "Provenance-sign CRED via SCOPE-REF's own `sign-said`. THE one primitive for
   'a credential signed by a scope you hold a reference to' — as opposed to the
   raw-keypair `#:signing-keypair` path, which is for signing INSIDE a scope
   actor where the keypair is in closure (you can't re-entrantly call your own
   sign-said in Goblins). Absorbs the guard: no-op when SCOPE-REF is #f or has
   no keypair (synthetic / test / degraded mode), so no call site repeats the
   check. Keypair never leaves the actor."
  (if (and scope-ref ($ scope-ref 'has-keypair?))
      (cred-with-signature cred ($ scope-ref 'sign-said (cred-said cred)))
      cred))
