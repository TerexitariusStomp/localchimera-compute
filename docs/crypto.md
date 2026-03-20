# Cryptographic Identity & Message Passing

## Overview

xorg expressors carry public keys but currently have no authentication. This spec adds cryptographic signatures and a cross-org message protocol, with one key design choice: **expressions target the game's rules, not its exact state.**

## Signing

### What gets signed

An expressor signs against the **constitution** (validator identity), not the full environment hash:

```scheme
(sign private-key
      (format #f "~a:~a:~a:~a"
              validator-hash    ; the rules of the game
              expressor-id      ; who is expressing
              expr              ; the expression
              nonce))           ; replay prevention
```

This means a signed expression is valid as long as the rules haven't changed. The expressor says: *"I intend this move under these rules."*

### Why not hash the full state?

Binding to the exact environment state (bindings + history + validator) creates tight temporal coupling. Two orgs trying to coordinate would chase each other's hashes — rollback, re-sign, retry — a distributed livelock. The retry dance described in earlier design notes is complexity arising from targeting the wrong thing.

Targeting the validator instead:

- **Decouples sender from receiver's timeline.** Your expression is valid whenever the receiver processes it, as long as the rules are the same.
- **Allows queuing moves in advance.** Like submitting proposals to an agenda — they wait until processed.
- **Keeps agency with the expressor.** Instead of the system rejecting stale hashes, the expressor decides whether to retract.

### Replay prevention

A per-expressor nonce (or sequence number) prevents replay without requiring full state hashes.

## Authentication

`authenticate?` currently returns `#t`. With signatures:

```scheme
(define (authenticate? expressor expr signature)
  (let* ((pubkey (expressor-key expressor))
         (validator-hash (hash-validator (env-validator env)))
         (message (format #f "~a:~a:~a:~a"
                         validator-hash expressor expr (message-nonce signature))))
    (verify-signature pubkey message signature)))
```

The `as` form becomes:

```scheme
(('as expressor-id expr signature)
 (let ((target (evaluate expressor-id env)))
   (if (authenticate? target expr signature)
       (evaluate expr (make-env ... target))
       (error "Authentication failed"))))
```

## The Inbox

Each org has an **inbox** — a queue of signed expressions from other orgs (or its own expressors):

```scheme
(define (make-env bindings validator history expressor inbox)
  (list bindings validator history expressor inbox))
```

An inbox entry:

```scheme
`((id        . ,msg-id)
  (sender    . ,expressor-id)
  (expr      . ,expr)
  (signature . ,sig)
  (validator-hash . ,target-validator-hash)
  (status    . pending))   ; pending | processed | retracted
```

### Receiving

Messages arrive and sit in the inbox. A message is **processable** if its `validator-hash` matches the current validator. If the org enacts a new validator, messages targeting the old rules become stale — they stay in the inbox but won't match until retracted or the rules change back.

### Processing order

Which message to process is itself an expression:

```scheme
(evaluate '(as alice
             (process-message msg-b)
             (defer-message msg-a))
          env)
```

The scheduling decision is attributed, validated, and recorded in history. Different orgs can implement different processing strategies — FIFO, priority, voting on which message to handle next. The game decides.

### Retraction

An expressor can retract any of their own unprocessed messages:

```scheme
(evaluate '(as alice (retract-message msg-id)) env)
```

This is the safety mechanism. Instead of the system silently rejecting stale-hash expressions, the expressor watches the game evolve and decides: *"I no longer want this move."*

Retraction is signed and recorded in history.

## Cross-Org Communication

### Sending

An org (or expressor acting as one) sends a signed expression to another org:

```scheme
(send-to-org target-org
  `((expr      . ,(modify! 'treaty "peace"))
    (sender    . ,our-org-id)
    (signature . ,(sign org-key validator-hash our-org-id expr nonce))
    (validator-hash . ,(hash-validator target-org-validator))))
```

The sender must know the target org's current validator hash — but not its full state. This is a much more stable target.

### Atomic cross-org transactions

Two orgs coordinate by exchanging signed expressions:

1. Org A sends a proposal to Org B, signed against B's validator.
2. Org B processes it (if the validator hash matches and its own validator allows it).
3. Org B sends a confirmation to Org A, signed against A's validator.
4. Org A processes the confirmation.

If Org B's rules change between steps 1 and 2, the message becomes stale. Org A can retract and re-send targeting the new rules, or decide the deal is off.

No rollback-retry loops. No hash-chasing. The expressors decide.

## Org-as-Expressor

The organization itself is just another expressor:

```scheme
(define org-expressor (make-expressor 'organization "org-public-key"))
```

Who can act as the org is governed by the validator — the living constitution. The validator might require unanimous consent, a vote, a designated role, or any other rule expressible as code. The org's identity is subject to the same system as everything else.

## Summary

| Concern | Mechanism |
|---------|-----------|
| **Identity** | Expressor + public key |
| **Authentication** | Signature over `validator-hash:expressor:expr:nonce` |
| **Replay prevention** | Per-expressor nonce/sequence number |
| **Message delivery** | Inbox queue per org |
| **Validity** | Expression targets the rules (validator hash), not the full state |
| **Safety** | Retraction by the expressor, not system rejection |
| **Processing order** | An expression itself — attributed, validated, recorded |
| **Cross-org** | Signed message exchange, no retry loops |
| **Org identity** | Just an expressor, access governed by the validator |
