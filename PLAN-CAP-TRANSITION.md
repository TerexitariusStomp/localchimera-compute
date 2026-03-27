# Rigorous ACL → Cap Transition Plan

_Written 2026-03-26. Precise inventory of remaining ACL patterns and exact fixes._

---

## Status: ~30% complete

The primitives exist (`endorsement.scm`). Nothing enforces them yet.
This plan closes every remaining ACL pattern systematically.

---

## Remaining ACL patterns — exact inventory

### 1. `modify!` / `define` don't enforce endorsement structurally
**File:** `gplay.scm` lines ~537-549
**Problem:** Any value passes. The validator *can* check endorsements but callers aren't required to provide them. "Governed names require endorsement" is policy, not structure.
**Fix:** No change to the evaluator form. The fix is at the validator level — `make-faceted-validator` already blocks unendorsed values for governed names. Document that this IS the structural enforcement: governed names fail at the validator boundary. The evaluator is the enforcer; the validator is the policy. This is correct.
**Status:** ✓ Already correct. No change needed.

### 2. `defexpressor` calls validator with identity as check value
**File:** `gplay.scm` ~509-526
**Problem:** `(validator current-expressor eval-name id bindings bindings)` — passes identity `id` as value. If the validator governs the `eval-name` namespace, creating an expressor requires endorsement. This is actually fine — it's the validator's job to decide whether expressor creation is governed. The pattern is correct.
**Status:** ✓ Already correct.

### 3. `as` is already cap-based — sealer IS the capability
**File:** `gplay.scm` ~528-534
**Status:** ✓ Already cap. No change needed.

### 4. `lookup-expressor-config` uses expressor name (identity) as key
**File:** `ai.scm` lines 84-97
**Problem:** Builds config key as `name:suffix` using the expressor's *name*. ACL-flavored: identity determines config lookup.
**Fix:** Make AI config lookup cap-based — the AI capability actor already holds its own model/prompt config. The `lookup-expressor-config` pattern should be replaced by having each org expressor hold an `^ai-config` capability binding directly. Remove `lookup-expressor-config` and `expressor-config-key`. Expressors who want custom AI config `modify!` their own `ai-config` binding (an `^ai-capability` with their preferred settings).
**Impact:** `ai-query` and `ai-eval-query` in `ai.scm` simplified — no name lookup, just use the installed capability.

### 5. `^service-capability` whitelist is an ACL list
**File:** `services.scm` `^service-capability` + `^service-registry`
**Problem:** `^service-registry` maps names → capabilities. The `get` method looks up by name — effectively an access list. Any code holding the registry can access any service.
**Fix:** Don't use a registry as the access mechanism. Instead: each service gets its own pre-attenuated capability. You hand the capability directly to the org that should have it. No registry lookup — possession IS access. Remove `^service-registry` OR keep it as an admin-only internal tool, never exposed to org bindings directly.
**New pattern:**
```scheme
;; Admin creates attenuated capabilities and passes them to specific orgs
(define nginx-start-cap    (make-attenuated-service-cap nginx-cap '(start status)))
(define relay-full-cap     relay-cap)  ;; full control
;; Pass to org — org can only do what the cap allows
(install-capability! org 'nginx nginx-start-cap)
```

### 6. `^system-deployer` authorized-configs is an ACL list
**File:** `services.scm` `^system-deployer`
**Problem:** `authorized-configs` alist checked at deploy time. Also uses path identity not content hash.
**Fix A:** Replace alist check with pre-attenuated single-config deployers:
```scheme
(define deploy-machine-a (make-single-config-deployer "deploy/guix/machines.scm" deploy-proc))
;; Holding this cap = authorized to deploy exactly that config
;; No list. No identity check.
```
**Fix B:** Content hash instead of path — `file-sha256` the config at attenuation time, check at deploy time.

### 7. `display` / `format` / `write` / `newline` are ambient in base-bindings
**File:** `org.scm` `default-base-bindings` lines 127-130
**Problem:** Any expressor in any org can write to stdout with no governance.
**Fix:** Remove from `default-base-bindings`. Add `^output-port` capability actor to `capabilities.scm`. Orgs receive an output capability at spawn time. The REPL passes in a stdout-backed capability. Browser REPL passes a WebSocket-backed capability. Tests pass a string-port-backed capability.
**Backward compat:** `make-org` gains an optional `#:output output-cap` parameter. If not provided, install a default stdout cap (maintains current behavior for existing code).

### 8. Default validator accepts everything — no org actually uses cap governance
**Problem:** `make-faceted-validator` exists but no org setup uses it. Until someone instantiates an org with a faceted validator, the cap system is dormant.
**Fix:** Write `make-governed-org` in `org.scm` — an org factory that sets up a faceted validator with governance, infrastructure, and membership domains out of the box. Returns the org AND the authority triplets. This is the reference implementation of a cap-governed org.

---

## Implementation order

### Phase A: Remove ambient IO (self-contained, no breaking changes)

**A1. `^output-port` in `capabilities.scm`**
```scheme
(define (^output-port bcom port)
  (methods
   [(display val)        (display val port) (if #f #f)]
   [(write val)          (write val port)   (if #f #f)]
   [(newline)            (newline port)      (if #f #f)]
   [(format fmt . args)  (apply format port fmt args) (if #f #f)]
   [(port)               port]))
```

**A2. Remove `display`/`format`/`write`/`newline` from `default-base-bindings` in `org.scm`**
Replace with `^output-port` capability wired in at org construction.
`make-org` gets `#:output` optional param. Default: spawn stdout `^output-port`.
Wire `display`/`format`/`write`/`newline` into base-bindings as closures delegating to the output cap.

### Phase B: Fix service and deployer ACL patterns

**B1. `make-attenuated-service-cap` in `services.scm`**
```scheme
(define (make-attenuated-service-cap service-cap allowed-actions)
  "Returns a new capability actor restricted to allowed-actions."
  (spawn ^attenuated-service service-cap allowed-actions))

(define (^attenuated-service bcom base-cap allowed-actions)
  (lambda (msg . args)
    (if (member msg allowed-actions)
        (apply $ base-cap msg args)
        (error "Action not permitted by this capability" msg))))
```

**B2. `make-single-config-deployer` in `services.scm`**
```scheme
(define (make-single-config-deployer config-path deploy-proc)
  "A deployer capability pre-bound to exactly one config file.
   No authorization list — possession IS authorization."
  (let ((expected-hash (file-sha256 config-path)))
    (spawn ^single-deployer config-path expected-hash deploy-proc)))

(define (^single-deployer bcom config-path expected-hash deploy-proc)
  (methods
   [(deploy)
    (let ((actual-hash (file-sha256 config-path)))
      (if (equal? actual-hash expected-hash)
          (deploy-proc config-path)
          (error "Config file has changed since authorization" config-path)))]
   [(config-path) config-path]))
```

**B3. Deprecate `^service-registry` public API**
Mark as internal admin tool. Not to be passed into org bindings directly.

### Phase C: Fix AI config lookup

**C1. Remove `lookup-expressor-config` and `expressor-config-key` from `ai.scm`**
**C2. Replace with direct capability binding lookup**
Each expressor who wants custom AI holds an `ai-config` capability binding.
`ai-query` uses the org's installed `^ai-capability` directly.
Custom per-expressor config: expressor creates their own `^ai-capability` with custom settings and binds it as `my-ai` or similar.

### Phase D: `make-governed-org` reference implementation

**D1. New function in `org.scm`**
```scheme
(define* (make-governed-org name #:key
                             (output #f)
                             (bindings default-base-bindings))
  "Create an org with a faceted validator governing three domains:
   - 'governance: changes to validator, rollback (requires governance-seal)
   - 'infrastructure: deploy, services (requires infra-seal)
   - 'membership: expressors, roles (requires membership-seal)
   
   Returns (values org governance-seal infra-seal membership-seal)
   
   The caller holds the authority triplets — they are the initial capability grants."
  (receive (seal-gov unseal-gov sealed-gov?)
    (make-endorsement-authority 'governance)
    (receive (seal-infra unseal-infra sealed-infra?)
      (make-endorsement-authority 'infrastructure)
      (receive (seal-member unseal-member sealed-member?)
        (make-endorsement-authority 'membership)
        (let* ((validator
                (make-faceted-validator
                 (list
                  (make-facet (name-set-predicate '(validator rollback))
                              sealed-gov?)
                  (make-facet (name-prefix-predicate 'infra-)
                              sealed-infra?)
                  (make-facet (name-prefix-predicate 'member-)
                              sealed-member?))))
               (org (make-org name bindings #:validator validator #:output output)))
          (values org seal-gov seal-infra seal-member))))))
```

**D2. `make-org` gains `#:validator` parameter**
Pass a custom initial validator. Currently `make-initial-org` always uses `default-validator`.

---

## Test coverage required

- `tests/test-output-port.scm` — output cap routing, ambient display removed
- `tests/test-services-cap.scm` — attenuated service caps, single-config deployer
- `tests/test-governed-org.scm` — full make-governed-org flow: governance blocks without endorsement, allows with it, infra/membership isolation

---

## What "transition complete" means

1. ✓ `endorsement.scm` — primitives exist
2. ☐ `display`/`format`/`write`/`newline` removed from ambient base-bindings
3. ☐ `^output-port` capability in `capabilities.scm`
4. ☐ `^attenuated-service-cap` and `^single-config-deployer` in `services.scm`
5. ☐ `lookup-expressor-config` removed from `ai.scm`
6. ☐ `make-governed-org` in `org.scm` — reference cap-governed org
7. ☐ `make-org` accepts `#:validator` and `#:output`
8. ☐ Tests for all of the above
9. ☐ README updated: document the cap security model
