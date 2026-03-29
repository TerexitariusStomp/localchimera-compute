---
description: Guile Scheme — the language everything is written in, SRFI usage, module system, idioms
---

Every layer of xorg is Guile Scheme — from the browser evaluator to the operating system declaration. This skill covers Guile-specific idioms, the module system, SRFIs used in the codebase, and patterns that differ from other Scheme implementations.

## Module system

```scheme
;; Defining a module
(define-module (xorg actors)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^org ^logger spawn-logged-revocable-proxy-pair))

;; Using a module
(use-modules (xorg actors))

;; Load path: -L flag or GUILE_LOAD_PATH environment variable
;; This project: guile -L module server/relay.scm
```

## SRFIs used in this codebase

| SRFI | Name | Where used |
|------|------|------------|
| SRFI-1 | List library | `fold`, `any`, `filter`, `partition` — everywhere |
| SRFI-9 | Records | `key-pool.scm`, `planner/lib/schemas.scm` |
| SRFI-19 | Time | `key-pool.scm` (timestamps) |
| SRFI-43 | Vectors | `planner/` algorithms |
| SRFI-64 | Testing | `tests/` |

```scheme
(use-modules (srfi srfi-1))   ;; fold, any, filter, etc.
(use-modules (srfi srfi-9))   ;; define-record-type
```

## Common Guile idioms in this codebase

```scheme
;; Pattern matching (used extensively in relay.scm, evaluator.scm)
(use-modules (ice-9 match))
(match msg
  (('signup (? string? username) (? string? email) (? string? key))
   (handle-signup username email key))
  (('to target payload)
   (route target payload))
  (x (log! "unknown: ~a\n" x)))

;; Format strings
(use-modules (ice-9 format))
(format #t "~a items, ~,2f seconds\n" count elapsed)
;; ~a = display, ~s = write, ~% = newline, ~,2f = float with 2 decimals

;; Association lists (the primary data structure in xorg)
(define env '((x . 1) (y . 2)))
(assq-ref env 'x)         ;; => 1  (eq? comparison — symbols)
(assoc-ref env "key")      ;; => value (equal? comparison — strings)
(acons 'z 3 env)           ;; => ((z . 3) (x . 1) (y . 2))

;; Hash tables (used in relay.scm for sessions)
(use-modules (ice-9 hash-table))
(define ht (make-hash-table))
(hash-set! ht "key" "value")
(hash-ref ht "key" #f)     ;; #f is default

;; Threads (used in relay.scm)
(use-modules (ice-9 threads))
(call-with-new-thread (lambda () ...))
(define mtx (make-mutex))
(with-mutex mtx ...)

;; catch/throw (error handling)
(catch #t
  (lambda () (dangerous-operation))
  (lambda (key . args) (handle-error key args)))
```

## Hoot compatibility constraints

When writing code that must compile to WASM via Hoot (`browser/repl.scm`, `module/xorg/*.scm`):

- No `eval` — use the metacircular evaluator
- No `syntax-case` or `syntax-rules` macros in Hoot modules
- No mutable strings (`string-set!`)
- No vectors in miniKanren code (uses lists instead)
- No GOOPS / object system
- No keywords — use positional arguments or plain symbols as alist keys
- Missing string procedures — `%starts-with?`, `%ends-with?`, `%trim` are custom replacements
- Large quasiquote expressions hit Hoot expansion limits — split across multiple `append` calls

See `/hoot-docs` skill for the full reference.

## The REPL

```bash
make repl                    # starts Guile with Goblins on the load path
guile -L module              # manual equivalent

# Inside the REPL:
,use (goblins)               # import module
,describe spawn-vat          # show documentation
,trace (my-function args)    # trace execution
,time (expensive-operation)  # measure time
,expand (my-macro args)      # show macro expansion
```

## The user's request

$ARGUMENTS
