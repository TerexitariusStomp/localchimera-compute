---
description: Spritely Goblins — distributed object-capability actors, vats, bcom, OCapN, Heart of Spritely patterns
---

Goblins IS the runtime. On native Guile, xorg is just Goblins used correctly following the Heart of Spritely. Every governance pattern — state, accountability, attenuation, revocation, identity, persistence — maps 1:1 to a Goblins primitive with zero additional code.

## Core primitives

| Primitive | What it does | xorg usage |
|-----------|-------------|------------|
| `spawn-vat` | Creates an isolated actor container (event loop + transaction boundary) | Each org lives in a vat |
| `spawn` | Creates an actor within a vat | `(spawn ^org initial-bindings)` |
| `bcom` | Actor becomes a new version of itself (state update) | `^org` uses bcom for all mutations |
| `$` | Synchronous local message send | `($ org 'lookup 'x)` |
| `<-` | Asynchronous remote message send (returns promise) | `(<- remote-actor 'method args)` |
| `on` | Attach handler to promise | `(on (<- actor 'method) handler)` |
| `with-vat` | Execute code within a vat's context | `(with-vat vat (spawn ^org '()))` |
| `define-actor` | Define an actor constructor with persistence support | All xorg actors use this |

## Actor-lib patterns (Heart of Spritely)

```scheme
(use-modules (goblins actor-lib cell)
             (goblins actor-lib facet)
             (goblins actor-lib methods))
```

| Pattern | Import | Usage |
|---------|--------|-------|
| `^cell` | `(goblins actor-lib cell)` | Mutable single-value container. Used for revocation (`($ cell #t)`) and logger state |
| `^facet` / `facet` | `(goblins actor-lib facet)` | Expose only certain methods. `(facet org 'lookup 'snapshot)` = read-only view |
| `methods` | `(goblins actor-lib methods)` | Dispatch on first argument. `(methods [(lookup name) ...] [(modify! name val) ...])` |

## Persistence (portrait/restore)

Actors survive restarts via `#:portrait` and `#:restore`:

```scheme
(define-actor (^my-actor bcom state)
  #:portrait
  (lambda () (list state))        ;; serialize to plain data

  #:version 1

  #:restore
  (lambda (version saved-state)   ;; reconstruct from serialized data
    (spawn ^my-actor saved-state))

  (methods
    [(get) state]
    [(set! new) (bcom (^my-actor bcom new))]))
```

The persistence environment registers actor constructors:

```scheme
(define my-env
  (make-persistence-env
    `((((my-module) ^my-actor) ,^my-actor))))
```

## OCapN — networking

```scheme
(use-modules (goblins ocapn captp)
             (goblins ocapn netlayer onion))  ;; or reticulum, tcp, etc.

(define vat (spawn-vat))
(with-vat vat
  (define netlayer (spawn ^onion-netlayer))
  (define mycapn (spawn-mycapn netlayer))

  ;; Register an actor — get a sturdyref
  (define sref ($ mycapn 'register my-actor 'onion))
  ;; => ocapn://onion/s/...

  ;; Connect to a remote actor by sturdyref
  (define remote ($ mycapn 'enliven remote-sref))
  (on (<- remote 'greet "Bob")
      (lambda (reply) (display reply))))
```

Transport is invisible — same API for TCP, Tor, Reticulum, WebSocket.

## Transactional model

Each vat turn is atomic. If an error occurs mid-turn, all state changes within that turn are rolled back automatically. This is why `bcom` is safe — you never get partial state updates.

```scheme
(with-vat vat
  ;; If this throws, the bcom from ($ org 'modify! ...) is rolled back
  ($ org 'modify! 'x 1)
  (error "oops")  ;; x is NOT modified — the turn failed
  )
```

## Typical session

```scheme
(use-modules (goblins)
             (goblins actor-lib cell)
             (goblins actor-lib facet)
             (goblins actor-lib methods))

(define vat (spawn-vat))
(with-vat vat
  ;; Pure state
  (define org (spawn ^org '()))
  ($ org 'modify! 'greeting "hello")
  ($ org 'lookup 'greeting)  ;; => "hello"

  ;; Accountability
  (define log (spawn ^logger))
  (define-values (proxy revoke-cell)
    (spawn-logged-revocable-proxy-pair 'alice org log))
  ($ proxy 'modify! 'x 42)     ;; logged
  ($ log 'get-log)              ;; => shows the entry

  ;; Revocation
  ($ revoke-cell #t)            ;; alice is cut off
  ($ proxy 'lookup 'x)          ;; ERROR — revoked

  ;; Attenuation
  (define read-only (facet org 'lookup 'snapshot))
  ($ read-only 'lookup 'x)     ;; works
  ($ read-only 'modify! 'x 0)  ;; ERROR — method not exposed
  )
```

## HAMT hashmap

```scheme
(use-modules (goblins utils hashmap))
(define hm (hashmap))
(define hm2 (hashmap-set hm "key" "value"))
(hashmap-ref hm2 "key" #f)  ;; => "value"
(hashmap-size hm2)           ;; => 1
(hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() hm2)
```

Used by `^signup-agent` for persistent member storage.

## Reference

- [Heart of Spritely](https://spritely.institute/static/papers/spritely-core.html) — the paper that defines the patterns
- [Goblins documentation](https://docs.spritely.institute/goblins/)
- [Spritely community](https://community.spritely.institute/)

## The user's request

$ARGUMENTS
