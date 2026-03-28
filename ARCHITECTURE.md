# xorg Architecture

_What xorg is, what it isn't, and where the code actually lives._

---

## The realization

xorg is not a framework. It's a **pattern**: use Goblins correctly,
following the Heart of Spritely.

On native Guile + Goblins, every piece of "governance" maps 1:1 to
something that already exists:

| Need | Goblins provides | xorg code needed |
|---|---|---|
| Mutable state | `bcom` (become) | None |
| Accountability | `^logger` + proxy (Heart of Spritely §3.3.4) | None — it's a pattern |
| Attenuation | `^facet` (actor-lib) | None |
| Revocation | `^cell` flip (Heart of Spritely §3.3.4) | None — it's a pattern |
| Identity | Actor refs are unforgeable | None |
| Transactions | Vat turns — automatic rollback on error | None |
| Persistence | `define-actor` + persistence env | None |
| Eval | `(eval expr module)` with custom modules | None |
| REPL | `,enter-vat` in Guile's built-in REPL | None |
| IO | Capabilities passed in (ports, `^io`) | None |
| Networking | OCapN — actors across machines | None |

**On the server, xorg is Goblins.** There is no separate governance kernel
to import. You write Goblins actors following the patterns from Heart of
Spritely. The accountability, attenuation, and revocation patterns are
recipes — not code you depend on.

---

## When xorg code IS needed: Hoot/WASM (browser)

In the browser via Hoot, several Guile features aren't available:

| Missing in Hoot | xorg provides |
|---|---|
| `eval` | Metacircular evaluator (~180 lines) |
| Full module system | `default-base-bindings` — curated primitives |
| `,enter-vat` | Inner REPL (`enter!`) |
| Possibly limited actor-lib | Own `^logger`, proxy pair |

This is xorg's actual role: **a Hoot-compatible subset of Goblins
patterns with a metacircular evaluator for the browser.**

The files:
- `module/xorg/gplay.scm` — evaluator + Goblins actors (for Hoot)
- `module/xorg/org.scm` — factories + REPL (for Hoot)
- `module/xorg/kanren.scm` — miniKanren (standalone, Hoot-compatible)
- `module/xorg/hyperarc.scm` — metagraph data (standalone)
- `module/xorg/knowledge.scm` — relational queries (standalone)

---

## The server: live hacking with Goblins directly

On the Hetzner server (or any native Guile environment), you don't
import xorg. You just use Goblins:

```scheme
(use-modules (goblins)
             (goblins actor-lib cell)
             (goblins actor-lib facet)
             (goblins actor-lib methods))

;; State — just an actor with bcom
(define-actor (^org bcom bindings)
  (methods
   [(lookup name) (assq-ref bindings name)]
   [(bindings) bindings]
   [(modify! name value)
    (bcom (^org bcom (cons (cons name value) bindings)))]
   [(snapshot) bindings]
   [(restore! snapshot) (bcom (^org bcom snapshot))]))

;; Accountability — Heart of Spritely §3.3.4
(define (^logger bcom)
  (define log (spawn ^cell '()))
  (methods
   ((append-to-log username object args)
    ($ log (cons `(*entry* user ,username args ,args) ($ log))))
   ((get-log) ($ log))))

(define (spawn-logged-revocable-proxy-pair username object log)
  (define revoked? (spawn ^cell #f))
  (define (^proxy bcom)
    (lambda args
      (when ($ revoked?) (error "Access revoked for" username))
      ($ log 'append-to-log username object args)
      (apply $ object args)))
  (values (spawn ^proxy) revoked?))

;; Wire it up
(define vat (spawn-vat))
(with-vat vat
  (define org (spawn ^org '()))
  (define log (spawn ^logger))

  ;; Governed refs — the proxy IS the identity
  (define-values (gov-ref gov-revoked?)
    (spawn-logged-revocable-proxy-pair 'governance org log))
  (define-values (infra-ref infra-revoked?)
    (spawn-logged-revocable-proxy-pair 'infrastructure org log))

  ;; Read-only — ^facet blocks mutation
  (define read-ref (facet org 'lookup 'bindings 'snapshot))

  ;; Use it
  ($ infra-ref 'modify! 'deploy "my-deploy-cap")
  ($ gov-ref 'modify! 'policy "consensus")

  ;; Check the log
  ($ log 'get-log)
  ;; => ((*entry* user governance args (modify! policy "consensus"))
  ;;     (*entry* user infrastructure args (modify! deploy "my-deploy-cap")))

  ;; Revoke infrastructure
  ($ infra-revoked? #t)
  ;; ($ infra-ref 'modify! 'x 1) → ERROR: Access revoked

  ;; Read-only can't mutate
  ;; ($ read-ref 'modify! 'x 1) → ERROR: method denied
  )
```

That's it. No imports from `(xorg ...)`. No governance kernel. Just
Goblins actors composed following the Heart of Spritely patterns.

---

## The browser: xorg evaluator

In Hoot/WASM, the same patterns apply but we need the metacircular
evaluator because `eval` isn't available:

```scheme
;; Browser — uses xorg's evaluator
(use-modules (xorg gplay) (xorg org))
(define-values (vat proxy log) (make-open-org "my-org"))
(with-vat vat
  (evaluate '(define x 42) proxy '())
  (evaluate '(modify! 'policy "consensus") proxy '()))
```

Same governance. Same patterns. The evaluator is the bridge.

---

## Live hacking on the server

The Hetzner server runs Guile + Goblins natively. The live hacking
setup (Guile REPL server + Emacs/Geiser) gives direct access to the
Goblins vat:

```
You (or Claude Code)
  → SSH / emacsclient
  → Guile REPL on /var/run/xorg/dev.sock
  → Goblins vat with live actors
  → Create orgs, loggers, proxies
  → Test governance patterns interactively
  → Hot-reload modules
```

There is no compilation step, no deploy cycle, no restart. You
evaluate an S-expression and it's live in the vat. Actors persist
across calls. The REPL IS the development environment.

This is what Lisp was built for. Goblins makes it capability-secure.
Heart of Spritely makes it accountable. Guix makes it reproducible.

---

## Summary

```
Browser (Hoot/WASM)              Server (Native Guile)
─────────────────────            ────────────────────
xorg evaluator                   Guile's eval
xorg base-bindings               Guile's module system
xorg REPL                        Guile's REPL + ,enter-vat
xorg actors                      Same Goblins actors
                                 (no xorg import needed)
    ↕                                ↕
    └──── OCapN ──── same actors, same patterns ────┘
```

xorg exists for the browser. On the server, Goblins IS the governance
kernel.
