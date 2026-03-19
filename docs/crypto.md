# Identity, Capabilities & Cross-Org Communication

## Overview

xorg expressors carry public keys but have no authentication. This spec builds identity and cross-org communication on Goblins' capability primitives — facets, sealers, wards, OCapN — and reserves public key cryptography for where capabilities alone aren't sufficient.

**Design principle: capabilities first, crypto where needed.**

Goblins enforces object capability (OCap) security: you can only invoke references you possess. This eliminates most authentication concerns:

- **Within an org**, the evaluator is the trusted authority. Identity is attribution, not access control.
- **Across orgs**, CapTP provides secure pairwise channels. Identity comes from the connection.
- **Offline**, public key signatures provide non-repudiation — verifiable without a live connection.

See `docs/goblin-chat.scm` for a working Goblins application that uses all of these patterns — sealers for message authenticity, wards for access control, OCapN for networking, and sealed handshakes for authorization.

## Local Identity

### Current model (unchanged)

Within a single org, expressors are named identities in the binding environment:

```scheme
(defexpressor 'alice "alice-key")
(as alice (modify! 'proposal "yes"))
```

The validator governs what each expressor can do. There's no spoofing concern in a single-process evaluator — the evaluator itself enforces the protocol. `as` needs no authentication because the evaluator is the one executing it.

### Expressor creation with sealer triplet

Each expressor gets a sealer triplet at creation time. The sealer stays private (held by whoever created the expressor), while the unsealer and sealed-predicate go into the expressor-store for verification:

```scheme
;; Inside ^org, when defexpressor is evaluated:
(define-values (sealer unsealer sealed?)
  (spawn-sealer-triplet))

(define data
  `((id         . ,id)
    (name       . ,name)
    (public-key . ,public-key)
    (unsealer   . ,unsealer)      ; public — anyone can verify
    (sealed?    . ,sealed?)))     ; public — anyone can check

;; The sealer is returned to the caller (private capability)
;; Only the holder can produce sealed proofs of authorship
```

This mirrors goblin-chat's pattern: each user gets sealer triplets for chat messages and subscriptions. The sealer is the private credential; the unsealer is freely shared.

### Sealed history entries

When an expressor acts, the history entry can include a sealed proof of authorship:

```scheme
(list version expressor-id expr parent-version
      ($ sealer 'seal (list version expr)))
```

Anyone can verify by fetching the unsealer from the expressor-store:

```scheme
(let ((unsealer (assq-ref (expressor-ref id) 'unsealer)))
  ($ unsealer (list-ref entry 4)))  ; → (version expr) or error
```

Unlike public key signatures, this only works within the Goblins runtime — sealed values can't be verified by external systems. For offline verification, see Public Key Crypto below.

### The identity/controller split

For remote access, each expressor yields two objects — a public identity and a private controller — following goblin-chat's `spawn-user-controller-pair` pattern:

```scheme
(define (^expressor-identity bcom name unsealer sealed?)
  "Public face of an expressor. Freely shareable."
  (methods
   [(name) name]
   [(unsealer) unsealer]
   [(sealed?) sealed?]))

(define (^expressor-controller bcom org-ref expressor-id sealer)
  "Private controller. Held only by the authorized party."
  (methods
   [(evaluate expr)
    (evaluate expr org-ref '() expressor-id)]
   [(evaluate-with-locals expr locals)
    (evaluate expr org-ref locals expressor-id)]
   [(seal content)
    ($ sealer 'seal content)]))
```

The identity is what other actors see — name, verification capability. The controller is the power to act — evaluate as this expressor, seal proofs. Possession of the controller IS the credential, enforced by Goblins' reference model.

The org creates these pairs:

```scheme
;; In ^org actor:
[(create-expressor-pair name public-key)
 (define-values (sealer unsealer sealed?)
   (spawn-sealer-triplet))
 (define id (make-id name))
 (define identity
   (spawn ^expressor-identity name unsealer sealed?))
 (define controller
   (spawn ^expressor-controller self id sealer))
 ;; Register in expressor-store with public parts
 (register-expressor! id
   `((name . ,name) (public-key . ,public-key)
     (unsealer . ,unsealer) (sealed? . ,sealed?)
     (identity . ,identity)))
 ;; Return both; caller keeps controller private
 (values identity controller)]
```

Delegation is natural: alice shares her controller ref with a delegate. The controller can be wrapped in a facet that restricts which operations the delegate can perform.

## Cross-Org Communication

### OCapN replaces custom messaging

Goblins already provides the transport:

- **Sturdyrefs**: Persistent, serializable references to actors. An org publishes a sturdyref; other orgs enliven it to get a live reference.
- **CapTP**: Secure pairwise channels. Handles authentication, encryption, and reference integrity.
- **Promise pipelining**: Send messages to unresolved references, reducing round trips.
- **Netlayers**: Tor onion services, TCP+TLS, libp2p, WebSocket, Unix domain sockets — pluggable transport.

CapTP authenticates the sender. Org B knows which peer sent a message because CapTP establishes pairwise secure channels at the netlayer level. No validator-hash signing needed for live connections.

### The inbox actor (warded)

The inbox is a separate actor, **outside** the org's versioned state. It is not subject to rollback — messages persist regardless of org history rewinding.

Following goblin-chat's `^user-inbox` pattern, the inbox uses **wards** to separate public methods (anyone can submit) from controller methods (only authorized expressors can process/retract):

```scheme
(define (^org-inbox bcom org-ref entries next-id
                    inbox-warden inbox-incanter)

  (define controller-methods
    (methods
     [(process msg-id)
      ;; Returns the expr; caller evaluates it in the org
      (let ((entry (find-entry msg-id entries)))
        (bcom (^org-inbox bcom org-ref
                (update-status entries msg-id 'processed)
                next-id inbox-warden inbox-incanter))
        (assq-ref entry 'expr))]

     [(retract msg-id sender-ref)
      (let ((entry (find-entry msg-id entries)))
        (unless (eq? (assq-ref entry 'sender) sender-ref)
          (error "Not your message"))
        (bcom (^org-inbox bcom org-ref
                (update-status entries msg-id 'retracted)
                next-id inbox-warden inbox-incanter)))]))

  (define public-methods
    (methods
     [(submit expr sender-identity)
      (let ((id next-id))
        (bcom (^org-inbox bcom org-ref
                (cons `((id . ,id) (sender . ,sender-identity)
                        (expr . ,expr) (status . pending))
                      entries)
                (+ next-id 1) inbox-warden inbox-incanter))
        id)]

     [(pending)
      (filter (lambda (e) (eq? (assq-ref e 'status) 'pending))
              entries)]))

  (ward inbox-warden controller-methods
        #:extends public-methods))
```

Anyone with a reference to the inbox can `submit` and view `pending`. Only the holder of `inbox-incanter` can `process` or `retract`. The org's evaluator holds the incanter and invokes it when an expressor evaluates `(process-message ...)` or `(retract-message ...)`.

Why outside versioned state: if the inbox were part of the org actor, `(rollback! 3)` would lose messages that arrived after version 3. The inbox is append-only infrastructure; the org's history records which messages were processed.

### Processing order is still governed

Which message to process is an expression attributed to an expressor and recorded in history:

```scheme
(as alice (process-message 42))
(as alice (defer-message 43))
```

The scheduling decision passes through the validator. Different orgs can implement different strategies — FIFO, priority, voting on which message to handle next. The game decides.

### Retraction

An expressor retracts their own unprocessed messages:

```scheme
(as alice (retract-message 42))
```

This is the safety mechanism. Instead of the system silently rejecting stale messages, the sender watches the game evolve and decides: *"I no longer want this move."* Retraction is recorded in history.

### Membership handshake (sealed subscription)

When a remote party wants to act as an expressor in an org, they go through a sealed capability exchange — the same pattern goblin-chat uses for room subscriptions:

```scheme
;; 1. Remote party requests membership
(<- org-inbox 'submit '(request-membership "alice" "alice-pubkey")
     alice-identity)

;; 2. Org processes the request (governed by validator).
;;    If approved, org asks for alice's subscription sealer:
(define sub-sealer-vow (<- alice-identity 'subscription-sealer))

;; 3. Org creates the controller, seals it with alice's sealer.
;;    Only alice can unseal it:
(on sub-sealer-vow
    (lambda (sub-sealer)
      (define-values (identity controller)
        ($ org 'create-expressor-pair 'alice "alice-pubkey"))
      (<- sub-sealer controller)))

;; 4. Alice unseals with her subscription-unsealer to get the controller:
(on sealed-controller-vow
    (lambda (sealed)
      (define controller (<- subscription-unsealer sealed))
      ;; Now alice has the controller — she can evaluate as this expressor
      controller))
```

This prevents man-in-the-middle attacks: even if someone intercepts the sealed controller, they can't unseal it without alice's private unsealer capability. The org never exposes the controller to anyone but the intended recipient.

### Publishing an org

An org publishes its inbox via sturdyref:

```scheme
(define inbox-sref ($ mycapn 'register inbox-actor netlayer-id))
;; Share inbox-sref out-of-band (URL, QR code, DNS record, etc.)

;; Remote org enlivens it:
(define org-b-inbox-vow (<- mycapn 'enliven inbox-sref))
(<- org-b-inbox-vow 'submit proposal-expr org-a-identity)
```

## Cross-Org Transactions

### With CapTP (preferred)

Two orgs coordinate through live references:

1. Org A calls Org B's faceted reference: `(<- org-b-facet 'propose expr)`
2. Org B's validator checks the proposal, processes it.
3. Org B responds: `(<- org-a-facet 'confirm result)`
4. Org A processes the confirmation.

If the connection severs mid-transaction, `on-sever` handlers on both sides can trigger cleanup.

### Atomicity

True atomic cross-org transactions are a distributed consensus problem. Goblins doesn't solve this. Three options, in order of complexity:

1. **Best-effort**: Orgs process independently and reconcile. Sufficient for most coordination (proposals, votes, announcements).

2. **Saga pattern**: Each org applies changes optimistically and compensates on failure. The compensation logic is an expression in the org, governed by the validator.

3. **Coordinator actor**: A third actor manages the two-phase protocol. Both orgs grant it a controller reference. The coordinator is itself an expressor in both orgs, governed by both validators — fitting naturally into xorg's model.

## Public Key Crypto (Optional Layer)

Capabilities handle live, connected scenarios. Public key crypto handles the rest.

### When needed

1. **Offline verification**: Prove an expressor authored a history entry without a live connection to the org. An external auditor can verify with the public key alone.
2. **Third-party relay**: Exchange signed messages through an untrusted intermediary when CapTP isn't available.
3. **Portable identity**: An expressor's public key is meaningful outside any single org. The same key can identify someone across orgs without sharing capability refs.

### What gets signed

Sign against the **validator expression** (stable — changes only on `enact!`):

```scheme
(sign private-key
      (format #f "~a:~a:~a:~a"
              validator-expr-hash   ; the rules (hash of the s-expression)
              expressor-id          ; who
              expr                  ; what
              nonce))               ; replay prevention
```

`validator-expr-hash` is the hash of the validator's source s-expression, already stored as `validator-expr` in the `^org` actor. This is the right target because:

- It changes only on `enact!`, not on every mutation.
- It captures the *rules of the game*, not the game state.
- A signed expression is valid as long as the rules haven't changed.

### Nonce management

Per-expressor monotonic sequence number:

- The org tracks `last-seen-nonce` per expressor in the expressor-store.
- Reject any nonce <= last-seen.
- The nonce counter lives **outside** versioned state (alongside the inbox). On rollback, nonce counters do not revert — this prevents replaying old signed messages against rolled-back state.

Sequence numbers over random nonces because: they're smaller, require no seen-set that grows forever, and the monotonic property makes reasoning about ordering straightforward.

### Integration with `as`

When the validator requires it, `as` accepts an optional signature:

```scheme
;; Unsigned (local, trusted evaluator)
(as alice (modify! 'x 42))

;; Signed (required by validator for certain operations)
(as alice (modify! 'x 42) sig)
```

Whether signatures are required is a policy decision in the validator, not a system-wide flag:

```scheme
(enact! (lambda (expressor name value pre post)
          (if (cross-org-action? name)
              (and (verify-signature expressor name value)
                   (value-allowed? name value))
              (value-allowed? name value))))
```

## Org-as-Expressor

The organization is just another expressor:

```scheme
(defexpressor 'organization "org-public-key")
```

Who can act as the org is governed by the validator — the living constitution. With OCapN, the org's controller can be shared with authorized external parties through the sealed membership handshake. The validator decides who gets approved.

## Summary

| Concern | Mechanism | Layer |
|---------|-----------|-------|
| **Local identity** | Expressor name + `as` form | Evaluator |
| **Remote identity** | Identity/controller pair per expressor | Goblins OCap |
| **Expressor auth** | Sealer triplet (sealer private, unsealer public) | Goblins OCap |
| **Access control** | Wards on inbox (public vs controller methods) | Goblins OCap |
| **Transport** | CapTP via OCapN netlayers | Goblins |
| **Membership** | Sealed handshake (sealed controller exchange) | Goblins OCap |
| **Non-repudiation (live)** | Sealed history entries | Goblins OCap |
| **Non-repudiation (offline)** | Public key signatures | Crypto (optional) |
| **Cross-org messaging** | OCapN sturdyrefs + warded inbox actor | Goblins |
| **Replay prevention** | Per-expressor monotonic sequence number | Inbox layer |
| **Processing order** | Governed expression — attributed, validated, recorded | Evaluator |
| **Retraction** | Sender retracts own messages; recorded in history | Inbox layer |
| **Cross-org atomicity** | Coordinator actor, saga pattern, or best-effort | Application |
| **Org identity** | Just an expressor, validator governs access | Evaluator |

## Implementation Order

1. **Sealer triplets on expressor creation** — Extend `defexpressor` / `^org` to create sealer triplet per expressor. Store unsealer+sealed? in expressor-store. Return sealer to caller.
2. **Identity/controller split** — `^expressor-identity` + `^expressor-controller` actors. `create-expressor-pair` method on `^org`.
3. **Warded inbox** — `^org-inbox` with wards separating public submit from controller process/retract. `process-message` / `retract-message` as evaluator forms.
4. **Sealed membership handshake** — Subscription flow for remote expressor onboarding. Test with two vats.
5. **OCapN wiring** — Publish org inbox via sturdyref. Enliven remote orgs. Test cross-vat messaging end-to-end.
6. **Public key signatures** — `guile-gcrypt` or `guile-gnutls` for offline verification. Wire into `as` form gated by validator policy.
