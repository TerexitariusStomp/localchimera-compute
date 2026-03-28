# Persistence-Correct Capability Architecture

_Written 2026-03-26. Addresses three related problems:_
_1. Capability actors in org bindings get stripped by filter-serializable-bindings_
_2. The faceted validator is a closure — not serializable as an actor graph_
_3. io-bindings (display/write/etc.) are plain lambdas — not serializable_

---

## The Goblins Persistence Model (correctly understood)

Goblins persistence serializes **entire object graphs**. A self-portrait can include
references to other local actors — those actors are followed and serialized too.
Supported types include `local object refr` — capability actor references persist.

The problem is NOT that capabilities can't persist.
The problem is that:
1. **Plain lambdas/closures cannot persist** — they have no self-portrait
2. **The current `^org` portrait explicitly strips** procedure-valued bindings via `filter-serializable-bindings`
3. **The faceted validator is a closure** over sealer actors, not an actor itself

---

## Fix 1: `^org` bindings — stop stripping actor refs

`filter-serializable-bindings` removes anything that `procedure?` returns true for.
In Goblins, actor references are NOT procedures — they are opaque refr objects.
So capability actors stored in bindings (e.g. `deploy-cap`, `nginx-cap`) should
already survive the filter, since `(procedure? actor-ref)` = `#f`.

**Action:** Verify this empirically. If actor refs are not procedures, the filter
already works correctly for capability actors. The problem may be smaller than thought.

The remaining issue: `io-bindings` wrap the output-cap in plain lambdas:
```scheme
`((display . ,(lambda (val) ($ output-cap 'display val))))
```
This lambda captures `output-cap` (an actor ref) in a closure — the closure is
not serializable even though the actor ref inside it is.

**Fix:** Remove io-bindings from the bindings alist entirely. Store `output-cap`
directly as a field in the `^org` actor. On restore, output-cap is restored as
part of the actor graph. Re-wire display/write/etc. to the restored output-cap.

```scheme
(define-actor (^org bcom bindings validator-expr validator-proc
                    history expressor-store current-expressor base-bindings
                    head-version org-public-key print-log
                    output-cap)    ;; NEW: stored as actor ref, not in bindings
  ...)

;; In the lookup path — when evaluating (display ...) inside org:
;; Look up 'display in bindings first; if not found, delegate to output-cap
;; OR: always inject io-bindings from output-cap at lookup time, not at spawn time
```

The cleanest approach: in `^org`'s `lookup` method, after checking bindings,
check if the name is an IO primitive (`display`, `write`, `newline`, `format`)
and if so, delegate to `output-cap`. This means io-bindings never live in the
bindings alist — they're handled structurally by the org actor.

---

## Fix 2: Faceted validator as an actor graph

The current faceted validator is:
```scheme
(make-faceted-validator (list (make-facet pred sealed?-proc)))
```
Both `make-faceted-validator` and `make-facet` return plain closures.
Closures cannot be persisted.

**Fix:** Convert them to `define-actor` forms. The key insight from the docs:
> *"The data can include references to other local objects."*

### `^name-predicate` — data-driven, no closures

Name predicates are simple enough to represent as data:

```scheme
(define-actor (^name-predicate bcom spec)
  "A name predicate represented as data, not a closure. Fully serializable."
  (lambda (name)
    (match spec
      (('prefix p)   (string-prefix? p (if (symbol? name)
                                           (symbol->string name) name)))
      (('suffix s)   (string-suffix? s (if (symbol? name)
                                           (symbol->string name) name)))
      (('set names)  (memv name names))
      (('any)        #t)
      (('none)       #f))))
```

### `^facet` — holds actor refs to name-pred and sealer

```scheme
(define-actor (^facet bcom name-pred-actor sealed?-actor)
  "A governance facet. Both components are actor refs — fully serializable."
  (methods
   [(matches? name)   ($ name-pred-actor name)]
   [(satisfied? value) ($ sealed?-actor 'sealed? value)]))
```

But wait — the sealer's `sealed?` is a plain procedure returned by
`spawn-sealer-triplet`, not an actor with a `sealed?` message. We need to
wrap it:

```scheme
(define-actor (^sealed?-actor bcom sealed?-proc)
  "Wraps a sealed? predicate procedure as an actor for persistence."
  (lambda (value) (sealed?-proc value)))
```

But `sealed?-proc` is itself a closure over the Goblins sealer internals —
not serializable.

**The real fix:** Use `spawn-sealer-triplet` but make the sealer itself a
`define-actor` type. Looking at the Goblins sealers source:

Actually, Goblins sealers (`spawn-sealer-triplet`) are already implemented
as actors internally — they're part of `(goblins actor-lib sealers)` which
uses `define-actor`. So sealer actors ARE serializable already.

The problem is the `(receive (seal unseal sealed?) (spawn-sealer-triplet) ...)`
pattern — `seal`, `unseal`, `sealed?` are actor references (refrs).
`(procedure? seal)` may return `#f` in Goblins — they're actors, not procedures.

**Action needed:** Test whether `seal`, `unseal`, `sealed?` from
`spawn-sealer-triplet` survive persistence. If they're actors, they will.

If they do, then `make-endorsement-authority` just needs to be changed to
store the sealer actors directly rather than wrapping them in lambdas.

### `^faceted-validator` — actor holding facet actor refs

```scheme
(define-actor (^faceted-validator bcom facets)
  "Faceted validator as an actor. facets is a list of ^facet actor refs.
   Fully serializable — all refs are local actor references."
  (lambda (expressor name value pre post)
    (let ((governing (filter (lambda (f) ($ f 'matches? name)) facets)))
      (if (null? governing)
          #t
          (any (lambda (f) ($ f 'satisfied? value)) governing)))))
```

Now `make-governed-org` spawns actors instead of building closures:

```scheme
(define (make-governed-org name)
  (let ((vat (spawn-vat)))
    (with-vat vat
      ;; Spawn sealer triplets (already actors in Goblins)
      (receive (seal-gov _u-gov sealed-gov?) (spawn-sealer-triplet)
      (receive (seal-infra _u-infra sealed-infra?) (spawn-sealer-triplet)
      (receive (seal-member _u-member sealed-member?) (spawn-sealer-triplet)
        ;; Wrap sealed? actors (if not already actor refs)
        (let* ((gov-pred    (spawn ^name-predicate '(set (validator rollback))))
               (infra-pred  (spawn ^name-predicate '(prefix "infra-")))
               (member-pred (spawn ^name-predicate '(prefix "member-")))
               (gov-facet    (spawn ^facet gov-pred    sealed-gov?))
               (infra-facet  (spawn ^facet infra-pred  sealed-infra?))
               (member-facet (spawn ^facet member-pred sealed-member?))
               (validator    (spawn ^faceted-validator
                                    (list gov-facet infra-facet member-facet)))
               (out (spawn ^output-port (current-output-port)))
               (org (make-org name vat out validator default-base-bindings)))
          (values org seal-gov seal-infra seal-member))))))))
```

---

## Fix 3: `validator-proc` in `^org`

Currently `^org` stores both `validator-expr` (S-expr for restore) and
`validator-proc` (live procedure). With a `^faceted-validator` actor,
`validator-proc` IS an actor reference — serializable.

But `validator-expr` was used to re-evaluate the validator on restore.
With an actor, this is no longer needed — the actor restores itself.

**Fix:** When `validator-proc` is an actor ref (not a plain procedure),
store it directly in the portrait as an actor ref. No need for `validator-expr`
re-evaluation. The portrait just includes the validator actor ref.

Detect at restore time: if `validator-proc` in the portrait is an actor ref,
use it directly; if it's an S-expression (old format), re-evaluate it (backward
compat for old stored orgs).

---

## Fix 4: output-cap in `^org` portrait

Currently output-cap is not stored in `^org` at all — it's pre-wrapped into
`io-bindings` as closures, then filtered out.

**Fix:** Add `output-cap` as a field to `^org`. Store it in the portrait.
Remove io-bindings from the bindings alist. Handle IO primitives in the
`lookup` method:

```scheme
;; In ^org lookup:
[(lookup name)
 (cond
  ((assq name bindings) => cdr)
  ;; IO primitives delegated to output-cap
  ((eq? name 'display) (lambda (v) ($ output-cap 'display v)))
  ((eq? name 'write)   (lambda (v) ($ output-cap 'write v)))
  ((eq? name 'newline) (lambda ()  ($ output-cap 'newline)))
  ((eq? name 'format)  (lambda (fmt . args) (apply $ output-cap 'format fmt args)))
  (else (error "Variable unbound:" name)))]
```

The lambdas here are created fresh at lookup time — they're not stored,
so they don't need to be serializable. The `output-cap` actor ref IS stored
and serializes cleanly.

---

## Fix 5: `make-endorsement-authority` returns actor refs, not lambda triplets

Currently:
```scheme
(define (make-endorsement-authority name)
  (receive (seal unseal sealed?)
    (spawn-sealer-triplet)
    (values
     (lambda (value) (seal (cons name value)))
     (lambda (bundle) (cdr (unseal bundle)))
     sealed?)))
```

The wrapper lambdas are not serializable. Change to return the raw
sealer actor refs directly (if they're actors), or wrap in minimal define-actor forms.

**First: test if seal/unseal/sealed? from spawn-sealer-triplet are actor refs**

```scheme
(use-modules (goblins) (goblins actor-lib sealers))
(define vat (spawn-vat))
(with-vat vat
  (receive (s u p) (spawn-sealer-triplet)
    (display (refr? s)) (newline)))   ;; Is it a refr?
```

If yes: just return the raw triplet from `make-endorsement-authority`.
The `endorse`, `endorsed-with?`, etc. functions become thin wrappers
that call `($ seal-actor value)` etc.

If no (they're closures): wrap each in a `define-actor` form.

---

## Fix 6: gplay.scm persistence environment

The `gplay-env` persistence environment needs to include all new actor types:
```scheme
(define gplay-env
  (make-persistence-env
   `(...)
   #:extends (list sealer-env ...)))
```

Add: `^name-predicate`, `^facet`, `^faceted-validator`, `^output-port`.

---

## Implementation order

1. **Test sealer serialization** — run a quick test: can seal/unseal/sealed?
   from spawn-sealer-triplet survive a persist/restore cycle in a vat?

2. **`^name-predicate`** — data-driven name predicate actor (30 min)

3. **`^facet`** and **`^faceted-validator`** — actors, not closures (1 hr)

4. **Update `make-endorsement-authority`** — return actor refs or minimal actors (30 min)

5. **Update `make-governed-org`** — use actor constructors (1 hr)

6. **Update `^org`** — add output-cap field, remove io-bindings from portrait,
   handle IO in lookup, remove filter-serializable-bindings (1 hr)

7. **Update `validator-proc` handling** — store actor ref directly when
   validator is an actor (30 min)

8. **Update `gplay-env`** — register new actor types (30 min)

9. **Tests** — persist/restore cycle for governed orgs, verify capability
   bindings survive, verify validator survives, verify output routing survives

---

## What we expect after this

```scheme
;; Create a governed org
(define-values (org gov-seal infra-seal member-seal)
  (make-governed-org "my-org"))

;; Install a service capability
(with-vat (org-vat org)
  (evaluate '(modify! 'infra-nginx (endorse nginx-cap infra-seal))
            (org-ref org) '() genesis-id))

;; Persist — everything survives:
;; - The org's bindings including infra-nginx (actor ref)
;; - The faceted validator (actor graph: ^faceted-validator → ^facet → ^name-predicate + sealer)
;; - The output-cap (actor ref in ^org)
;; - The endorsement authority sealers (actor refs returned to the admin)

;; Restore — org comes back with full capability graph intact
;; The admin's seal-infra etc. are restored too (they're in the same vat)
```

---

## Note on private keys

Private keys (for history signing) should NOT persist in the vat.
Store only public keys (in expressor-store, as now).
Private keys are loaded from an external keystore at startup.
History entries without a signature are valid — signature is optional.
