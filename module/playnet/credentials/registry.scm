;;; credentials/registry.scm — the catalogue of playnet schemas, the claim-index and timestamp registries, the plan SAID, and a scope's signature over a credential.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6). A constructor returns the ACDC bundle as an alist — said, schema, issuer,
;;; holder, claims, edges, revoked? — with its SAID computed over the whole; the
;;; edge block follows ACDC §8 (`make-edge` in (playnet keri acdc)).

(define-module (playnet credentials registry)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri said-portable)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet utils clock)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri crypto-primitives)
  #:use-module (playnet keri citizen-sig)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module ((playnet credentials audit) #:select (*schema-playnet-audit-pass* *schema-playnet-derived-state-snapshot* *schema-playnet-incoherence-alert*))
  #:use-module ((playnet credentials commitments) #:select (*schema-playnet-agreement* *schema-playnet-commitment* *schema-playnet-commitment-fulfillment* *schema-playnet-intent* *schema-playnet-redistribution-mandate*))
  #:use-module ((playnet credentials custody) #:select (*schema-playnet-custody-attestation* *schema-playnet-custody-transfer-commitment* *schema-playnet-ownership-attestation* *schema-playnet-reversion-attestation*))
  #:use-module ((playnet credentials delegation) #:select (*schema-playnet-delegation*))
  #:use-module ((playnet credentials keys) #:select (*schema-playnet-bran-share* *schema-playnet-witness-assignment*))
  #:use-module ((playnet credentials membership) #:select (*schema-playnet-ccf-assessment* *schema-playnet-exclusion* *schema-playnet-federation-census* *schema-playnet-federation-membership* *schema-playnet-federation-sturdyref* *schema-playnet-membership*))
  #:use-module ((playnet credentials recomposition) #:select (*schema-playnet-conflict-resolution* *schema-playnet-scope-merger* *schema-playnet-scope-rejoin* *schema-playnet-scope-split*))
  #:use-module ((playnet credentials voting) #:select (*schema-playnet-ballot-snapshot* *schema-playnet-expression-stance* *schema-playnet-recomposition-ratification* *schema-playnet-stance* *schema-playnet-tally-result*))
  #:use-module ((playnet credentials work) #:select (*schema-playnet-claim* *schema-playnet-contrary-observation* *schema-playnet-external-index-observation* *schema-playnet-observation-event* *schema-playnet-skill* *schema-playnet-work-event*))
  #:export (*playnet-schemas* compute-plan-said cred-signed-by-scope))
(define *playnet-schemas*
  (list *schema-playnet-delegation*
        *schema-playnet-ccf-assessment*
        *schema-playnet-exclusion*
        *schema-playnet-federation-membership*
        *schema-playnet-membership*
        *schema-playnet-bran-share*
        *schema-playnet-federation-sturdyref*
        *schema-playnet-federation-census*
        *schema-playnet-stance*
        *schema-playnet-expression-stance*
        *schema-playnet-ballot-snapshot*
        *schema-playnet-tally-result*
        *schema-playnet-work-event*
        *schema-playnet-observation-event*
        *schema-playnet-commitment*
        *schema-playnet-scope-merger*
        *schema-playnet-scope-split*
        *schema-playnet-scope-rejoin*
        *schema-playnet-conflict-resolution*
        *schema-playnet-intent*
        *schema-playnet-agreement*
        *schema-playnet-external-index-observation*
        *schema-playnet-personhood*
        *schema-playnet-relationship*
        *schema-playnet-contact-point*
        *schema-playnet-authorized-issuer*
        *schema-playnet-device-authorization*
        *schema-playnet-custody-attestation*
        *schema-playnet-ownership-attestation*
        *schema-playnet-custody-transfer-commitment*
        *schema-playnet-audit-pass*
        *schema-playnet-incoherence-alert*
        *schema-playnet-reversion-attestation*
        *schema-playnet-derived-state-snapshot*
        *schema-playnet-commitment-fulfillment*
        *schema-playnet-redistribution-mandate*
        *schema-playnet-recomposition-ratification*
        *schema-playnet-witness-assignment*
        *schema-playnet-skill*
        *schema-playnet-claim*))



;; =========================================================================
;; Deterministic SAID — Blake3-256 of canonical content, CESR "E" code
;; =========================================================================
;;
;; KERI SAIDs are Blake3-256 digests CESR-encoded under code "E" (44
;; qb64 chars). `signify.scm` uses libblake3 for real KERI events; the
;; governance layer uses the same hash through `(playnet keri blake3)`
;; so that credentials issued by ^acdc-store and by a real KERIA
;; backend share a hash function — a foreign KERI verifier can check
;; either without knowing where it came from.
;;
;; libblake3.so is loaded lazily: `(playnet governance)` loads even
;; when the FFI library isn't present, but actually computing a SAID
;; requires the library. Tests run via `make test-governance`, which
;; enters a guix shell that includes the `blake3` package.

;; canonical-string / said-sort-pairs / compute-said now live in
;; (playnet keri said-portable) — imported by governance.scm and re-exported —
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
  (compute-said scope-aid scope-aid 'playnet-plan-v1
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
