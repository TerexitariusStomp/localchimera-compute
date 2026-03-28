# Validator Transformation: ACL → Capability-Governed Metaprogramming

_Written 2026-03-26. Continuation of PLAN.md._

---

## The Problem with the Current Validator

The current validator signature is:

```scheme
(lambda (expressor name value pre-bindings post-bindings) → bool)
```

It receives `expressor` (an identity) and makes decisions based on who is calling.
This is ACL-shaped: "is this expressor on the list of people allowed to change this name?"

Every interesting validator ends up doing identity checks. Metaprogramming via `enact!`
swaps one identity-checking function for another. The metacircular constraint
("the new validator must accept its own installation") is elegant but the underlying
model is still ACL.

**The gap:** an expressor can be on the list without deserving it. Identity is mutable
(keys can be compromised). The list is centralized (whoever controls it controls everything).

---

## The Target Model

**Capability-governed validation:** sensitive actions require the caller to *present*
a capability endorsement alongside the value. The validator checks possession, not identity.

```scheme
;; Instead of:
(modify! 'deploy some-function)           ;; validator checks: who is calling?

;; Cap-correct:
(modify! 'deploy (endorse some-function deploy-cap))  ;; validator checks: what do they hold?
```

Holding the endorsement IS the authorization. You can't forge it.
You can delegate it (give it to someone else). But you can never escalate beyond
what you were given.

---

## Core Primitives

### `endorse` — wraps a value with a capability endorsement

```scheme
;; (xorg endorsement)
(define (endorse value cap)
  "Bundle a value with an endorsement capability.
   The bundle is opaque — only valid-endorsement? can verify it."
  (cons 'endorsed (cons cap value)))

(define (extract-endorsement bundle)
  "Extract the capability from an endorsed bundle. Returns #f if not endorsed."
  (and (pair? bundle)
       (eq? (car bundle) 'endorsed)
       (cadr bundle)))

(define (endorsed-value bundle)
  "Extract the value from an endorsed bundle."
  (cddr bundle))

(define (valid-endorsement? bundle required-cap)
  "Check that bundle carries required-cap (or a sub-capability of it)."
  (let ((cap (extract-endorsement bundle)))
    (and cap (cap-subsumes? required-cap cap))))
```

### `cap-subsumes?` — capability hierarchy check

```scheme
(define (cap-subsumes? required held)
  "Does held capability satisfy required?
   In the simple case: identity (eq?).
   In the attenuated case: held was derived from required via attenuation."
  ;; For now: exact match or held is in required's delegation chain
  ;; The sealer/unsealer pair from Goblins handles this naturally:
  ;; (sealed? required-sealer held) → #t if held was sealed with required-sealer
  ((cap-validator required) held))
```

Use Goblins' existing `goblins/actor-lib/sealers` — the sealer IS the capability.
`(seal sealer value)` produces an endorsed bundle.
`(unseal unsealer bundle)` extracts the value — only works if sealed with the matching sealer.
`(sealed? sealer? bundle)` tests without extracting.

So `endorse` = `(seal cap-sealer value)` and `valid-endorsement?` = `(sealed? cap-sealer? bundle)`.
These are already in the Goblins API. No new primitives needed.

---

## The Faceted Validator

Instead of one monolithic validator function, compose independent facets.
Each facet governs a class of names and requires a specific endorsement.

```scheme
;; (xorg facets)

(define (make-facet name-predicate required-sealer?)
  "A facet: governs names matching name-predicate,
   requires values endorsed with required-sealer?."
  (cons name-predicate required-sealer?))

(define (facet-matches? facet name)
  ((car facet) name))

(define (facet-satisfied? facet value)
  ;; value must be (seal required-sealer payload)
  ((cdr facet) value))

(define (make-faceted-validator facets)
  "Compose a validator from a list of facets.
   Unprotected names (no matching facet) are always allowed.
   Protected names must carry an endorsement satisfying their facet."
  (lambda (expressor name value pre post)
    (let ((matching (filter (lambda (f) (facet-matches? f name)) facets)))
      (if (null? matching)
          #t  ;; no facet governs this name — free to modify
          (any facet-satisfied? matching value)))))
          ;; any one matching facet satisfied → allow
```

---

## `enact!` in the New Model

`enact!` now takes a new validator AND an endorsement capability:

```scheme
;; Inside gplay.scm evaluate:
(('enact! new-validator endorsement)
 ;; 1. Check the endorsement satisfies the governance facet
 ;; 2. Check the new-validator accepts its own installation (metacircular)
 ;; 3. If both pass, install new-validator
 ...)
```

The metacircular constraint is now: the new validator must accept
`(seal governance-sealer new-validator)` for the `enact!` call.

This means you cannot install a validator that would refuse its own installation,
AND you cannot install a validator without the governance endorsement.
Both constraints are enforced structurally.

---

## Graduated Delegation

The real payoff: different aspects of the org are governed by different capabilities,
which can be independently delegated and attenuated.

```scheme
;; Three sealers — three governance domains
(define-values (seal-econ unsealer-econ sealed-econ?)
  (make-sealer-triplet 'economic-policy))

(define-values (seal-member unsealer-member sealed-member?)
  (make-sealer-triplet 'membership))

(define-values (seal-infra unsealer-infra sealed-infra?)
  (make-sealer-triplet 'infrastructure))

;; Faceted validator — each domain independently governed
(define org-validator
  (make-faceted-validator
   (list
    ;; Economic names: treasury-*, budget-*, allocation-*
    (make-facet (lambda (n) (name-in-domain? n 'economic)) sealed-econ?)
    ;; Membership names: members, roles, admissions
    (make-facet (lambda (n) (name-in-domain? n 'membership)) sealed-member?)
    ;; Infrastructure names: deploy, services, servers
    (make-facet (lambda (n) (name-in-domain? n 'infrastructure)) sealed-infra?))))

;; Alice gets economic governance
;; (give alice (seal econ-grant-sealer seal-econ))
;; Alice can now: (modify! 'treasury-balance (seal-econ new-value))
;; Alice cannot touch membership or infrastructure — she doesn't hold those sealers
```

---

## Attenuated Capabilities

An expressor with a capability can delegate a weaker version:

```scheme
;; Alice holds seal-econ (full economic governance)
;; Alice creates an attenuated version: only covers 'treasury-balance
(define alice-treasury-cap
  (make-attenuated-sealer seal-econ
    (lambda (name) (eq? name 'treasury-balance))))

;; Alice gives this to Bob
;; Bob can now modify treasury-balance but nothing else in the economic domain
;; Bob cannot escalate to full seal-econ (he was never given it)
```

---

## What Changes in gplay.scm

The validator signature stays the same: `(expressor name value pre post) → bool`.
Nothing else in the org needs to know about endorsements.

The *meaning* of `value` changes for protected names:
- Before: value is the new binding directly
- After: value is `(seal required-sealer actual-value)` — the endorsed bundle

The evaluator needs `endorsed-value` to unwrap: when a binding is retrieved,
return `(endorsed-value stored-value)` if it's endorsed, else the value as-is.

One new special form: `(as-endorsed cap expr)` — evaluates expr and wraps the
result with `(seal cap result)`. Needed so expressors can produce endorsed values.

Or more simply: `(endorse value cap)` is added to base-bindings — but only as
a function that seals with caps the expressor was explicitly given.
This is the key: you can only endorse with caps in your own bindings.

---

## New Files

- `module/xorg/endorsement.scm` — `endorse`, `endorsed-value`, `valid-endorsement?`
- `module/xorg/facets.scm` — `make-facet`, `make-faceted-validator`, `make-attenuated-sealer`

## Modified Files

- `module/xorg/gplay.scm` — `evaluate` handles endorsed values transparently;
  `enact!` requires endorsement; `endorse` added to base-bindings conditionally
- `module/xorg/org.scm` — `make-org` optionally takes a validator + sealer set
- `README.md` — document the new security model

---

## Migration Path

This is a breaking change to the validator interface but NOT to the org API.
Existing orgs with `default-validator` (accepts everything) are unaffected.
The endorsement system is opt-in: if no facets govern a name, any modification is allowed.

Migration:
1. Implement `endorsement.scm` and `facets.scm` (pure library, no changes to gplay)
2. Add `endorsed-value` unwrapping to `evaluate` (backward compatible — non-endorsed values pass through)
3. Add `endorse` to base-bindings as a conditional capability
4. Change `enact!` to accept an optional endorsement parameter (backward compatible with existing tests)
5. Write faceted validator constructors
6. Update README and examples

All existing tests should pass throughout.
