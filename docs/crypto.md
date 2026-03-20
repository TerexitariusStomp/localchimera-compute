# Identity, Capabilities & Cross-Org Communication

## Overview

xorg expressors carry public keys but have no authentication. This spec builds identity and cross-org communication on Goblins' capability primitives — facets, sealers, OCapN — and reserves public key cryptography for where capabilities alone aren't sufficient.

**Design principle: capabilities first, crypto where needed.**

Goblins enforces object capability (OCap) security: you can only invoke references you possess. This eliminates most authentication concerns:

- **Within an org**, the evaluator is the trusted authority. Identity is attribution, not access control.
- **Across orgs**, CapTP provides secure pairwise channels. Identity comes from the connection.
- **Offline**, public key signatures provide non-repudiation — verifiable without a live connection.

## Local Identity

### Current model (unchanged)

Within a single org, expressors are named identities in the binding environment:

```scheme
(defexpressor 'alice "alice-key")
(as alice (modify! 'proposal "yes"))
```

The validator governs what each expressor can do. There's no spoofing concern in a single-process evaluator — the evaluator itself enforces the protocol. `as` needs no authentication because the evaluator is the one executing it.

### Faceted access for remote callers

When an org is accessed over the network (via OCapN), each expressor gets a **faceted reference** — a capability that binds operations to that identity:

```scheme
(define-actor (^expressor-facet bcom org-ref expressor-id)
  (methods
   [(evaluate expr)
    (evaluate expr org-ref '() expressor-id)]
   [(evaluate-with-locals expr locals)
    (evaluate expr org-ref locals expressor-id)]))
```

The org creates facets on demand:

```scheme
;; In ^org actor:
[(create-facet id)
 (unless (expressor-ref id) (error "Not an expressor:" id))
 (spawn ^expressor-facet self id)]
```

The facet IS the credential. Possession of `alice-facet` proves authorization to act as alice — Goblins' reference model makes forgery impossible. No signing, no challenge-response. The facet is created once and shared via sturdyref:

```scheme
(define alice-facet   (with-vat vat ($ org 'create-facet alice-id)))
(define alice-sref    ($ mycapn 'register alice-facet netlayer-id))
;; Share alice-sref out-of-band (URL, QR code, etc.)
```

Delegation is natural: alice shares her facet ref with a delegate. The validator can distinguish delegated actions if needed (the facet can tag them).

### Sealers for history non-repudiation

For audit within the Goblins runtime, an expressor can **seal** a token into each history entry using `spawn-sealer-triplet`:

```scheme
(define-values (alice-sealer alice-unsealer alice-sealed?)
  (spawn-sealer-triplet))

;; History entry includes a sealed proof of authorship
(list version alice-id expr parent-version
      ($ alice-sealer 'seal (list version expr)))
```

Anyone with `alice-unsealer` can verify alice authored the entry. Unlike public key signatures, this only works within the Goblins runtime — sealed values can't be verified by external systems. For offline verification, see Public Key Crypto below.

## Cross-Org Communication

### OCapN replaces custom messaging

The previous design proposed a custom inbox with signed messages targeting validator hashes. Goblins already provides the transport:

- **Sturdyrefs**: Persistent, serializable references to actors. An org publishes a sturdyref; other orgs enliven it to get a live reference.
- **CapTP**: Secure pairwise channels. Handles authentication, encryption, and reference integrity.
- **Promise pipelining**: Send messages to unresolved references, reducing round trips.
- **Netlayers**: Tor onion services, TCP+TLS, libp2p, WebSocket, Unix domain sockets — pluggable transport.

```scheme
;; Org B publishes its inbox
(define inbox-sref ($ mycapn 'register inbox-actor netlayer-id))

;; Org A enlivens it and sends a message
(define org-b-inbox-vow (<- mycapn 'enliven inbox-sref))
(<- org-b-inbox-vow 'submit proposal-expr org-a-facet)
```

CapTP authenticates the sender. Org B knows which peer sent a message because CapTP establishes pairwise secure channels at the netlayer level. No validator-hash signing needed for live connections.

### The inbox actor

The inbox is a separate actor, **outside** the org's versioned state. It is not subject to rollback — messages persist regardless of org history rewinding.

```scheme
(define-actor (^org-inbox bcom org-ref entries next-id)
  (methods
   [(submit expr sender-ref)
    (let ((id next-id))
      (bcom (^org-inbox bcom org-ref
              (cons `((id . ,id) (sender . ,sender-ref)
                      (expr . ,expr) (status . pending))
                    entries)
              (+ next-id 1)))
      id)]

   [(pending)
    (filter (lambda (e) (eq? (assq-ref e 'status) 'pending))
            entries)]

   [(process msg-id)
    ;; Returns the expr; caller evaluates it in the org
    (let ((entry (find-entry msg-id entries)))
      (bcom (^org-inbox bcom org-ref
              (update-status entries msg-id 'processed)
              next-id))
      (assq-ref entry 'expr))]

   [(retract msg-id sender-ref)
    ;; Only the original sender can retract
    (let ((entry (find-entry msg-id entries)))
      (unless (eq? (assq-ref entry 'sender) sender-ref)
        (error "Not your message"))
      (bcom (^org-inbox bcom org-ref
              (update-status entries msg-id 'retracted)
              next-id)))]))
```

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

3. **Coordinator actor**: A third actor manages the two-phase protocol. Both orgs grant it a faceted write reference. The coordinator is itself an expressor in both orgs, governed by both validators — fitting naturally into xorg's model.

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

Who can act as the org is governed by the validator — the living constitution. With OCapN, the org's expressor-facet can be shared with authorized external parties via sturdyrefs. The validator decides who gets that facet.

## Summary

| Concern | Mechanism | Layer |
|---------|-----------|-------|
| **Local identity** | Expressor name + `as` form | Evaluator |
| **Remote identity** | Faceted reference per expressor | Goblins OCap |
| **Transport** | CapTP via OCapN netlayers | Goblins |
| **Non-repudiation (live)** | Sealers (`spawn-sealer-triplet`) | Goblins OCap |
| **Non-repudiation (offline)** | Public key signatures | Crypto (optional) |
| **Cross-org messaging** | OCapN sturdyrefs + inbox actor | Goblins |
| **Message validity** | CapTP auth (live) or validator-hash signatures (offline) | Both |
| **Replay prevention** | Per-expressor monotonic sequence number | Inbox layer |
| **Processing order** | Governed expression — attributed, validated, recorded | Evaluator |
| **Retraction** | Sender retracts own messages; recorded in history | Inbox layer |
| **Cross-org atomicity** | Coordinator actor, saga pattern, or best-effort | Application |
| **Org identity** | Just an expressor, validator governs access | Evaluator |

## Implementation Order

1. **Expressor facets** — `^expressor-facet` actor, `create-facet` method on `^org`. Small, testable, no external deps.
2. **Inbox actor** — `^org-inbox` outside versioned state. `process-message` / `retract-message` as evaluator forms.
3. **OCapN wiring** — Publish org inbox via sturdyref. Enliven remote orgs. Test cross-vat messaging.
4. **Sealers** — Optional non-repudiation for history entries within the runtime.
5. **Public key signatures** — `guile-gcrypt` or `guile-gnutls` for offline verification. Wire into `as` form gated by validator policy.
