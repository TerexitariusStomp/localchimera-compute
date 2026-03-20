# meta-org

_An organization is a program that writes itself._

---

**meta-org** is a metacircular substrate for programmable organizations, written in Guile Scheme. It asks a simple question: what if an organization were a Lisp environment — and the people in it were expressions that could rewrite the interpreter?

The system is deliberately minimal. It provides identity, memory, and a mechanism for self-modification. What it _becomes_ is not prescribed. A meta-org could evolve into a democracy, a marketplace, a neural network of agents, a single autocratic expressor, or something with no existing name. The structure doesn't impose direction — it makes direction _expressible_.

## Metacircularity

The deepest idea here is borrowed from the metacircular evaluator tradition: a Lisp that interprets Lisp, defined in terms of itself.

meta-org extends this reflexivity to organizations:

- **The evaluator is written in Scheme, and evaluates Scheme.** The language that defines the organization is the same language the organization operates in.
- **Validators validate themselves.** When you `enact!` a new validator, it must accept its own installation. The rules for changing the rules are subject to the current rules.
- **Expressors can create expressors.** Identities within the system can bring new identities into being.
- **History records the expressions that produced it.** The system's past is stored as evaluable code — the organization can replay, inspect, and reason about its own evolution.

This means there is no privileged outside. The system is defined from within, modified from within, and understood from within. Like a metacircular evaluator, the boundary between the thing and its description dissolves.

## Core Concepts

### Expressors

An expressor is an identity — a _who_ attached to every action. It carries a name, a public key, and a unique symbol. There is no anonymous mutation; every change to the environment names the expressor that caused it.

```scheme
(defexpressor 'alice "alice-public-key")
```

An expressor is not necessarily a person. It could be a process, an external system, a role, or another meta-org. The system does not distinguish — it only requires that expression has a source.

### Environments

An environment is an immutable snapshot:

|

| Component     | Role                                              |
| ------------- | ------------------------------------------------- |
| **Bindings**  | The current namespace — what the org _knows_      |
| **Validator** | A function gating every change — how it _decides_ |
| **History**   | A versioned ledger — what it _remembers_          |
| **Expressor** | The identity currently acting — who _speaks_      |

Each operation returns a new environment. The previous state is not destroyed — it becomes history.

### Validators

A validator is an ordinary function: `(expressor name value old-env new-env) -> bool`. It validates both past (old-env) and post-validation (new-env) states, allowing it to inspect the full timeline before and after the change. It returns true or false.

The default validator accepts everything. You replace it with `enact!`. The metacircular constraint: **a new validator must accept itself** before it takes effect. This means the mechanism for changing the rules is always subject to the current rules — but _what_ those rules are is entirely open.

### History

Every change produces a history entry: a version number, the expressor, the expression evaluated, and a pointer to its parent. The ledger is append-only. Because entries store the original expressions as data, the organization's past is not merely recorded — it is **replayable**.

## Usage

### Initialize

```scheme
(use-modules (metaorg play))

(define env (make-initial-env '((x . 0) (y . 1))))
```

### Modify

```scheme
;; Bind a value — attributed, validated, versioned
(evaluate '(modify! 'x 42) env)
```

### Act as another expressor

```scheme
(evaluate '(as alice (modify! 'x 99)) env)
```

### Change the rules

```scheme
;; Install a validator — it must accept itself to take effect
(evaluate '(enact! (lambda (expressor name value old-env new-env)
                     (number? value)))
          env)
```

### Inspect

```scheme
(evaluate '(show-history) env)
(evaluate '(show-expressors) env)
```

### Rollback

```scheme
;; Revert to version 2 — replays history with original expressors
(evaluate '(rollback! 2) env)
```

Rollback does not erase — it replays. Each step is re-evaluated under the identity that originally performed it, so attribution survives time travel.

## REPL Tutorial

The REPL (`play-repl.scm`) lets you express a meta-org interactively — creating identities, mutating state, enacting rules, and inspecting history one step at a time. This walkthrough builds a small organization from scratch.

Launch the REPL:

```
rlwrap guile -L . play-repl.scm
```

```
play.scm REPL  —  Ctrl-D or (quit) to exit

play[genesis]>
```

The prompt shows `play[genesis]>` — the current identity is `genesis`, the bootstrapping expressor created when the environment initializes.

**Two things to know about REPL output:**

- When an expression mutates state (returns a new environment), the REPL silently updates and shows nothing — the prompt may change identity.
- When it returns a value, the REPL prints `=> value`.

### Create identities

```
play[genesis]> (defexpressor 'alice "alice-key")
play[genesis]> (defexpressor 'bob "bob-key")
```

No output — both calls returned environments. Two identities now exist in the org.

### Act as an identity

```
play[genesis]> (as alice (modify! 'proposal "fund the commons"))
play[alice]>
```

Alice proposed. The prompt changed to `play[alice]>` — the returned environment carries alice's identity. Every subsequent action will be attributed to alice until another `as` switches identity.

```
play[alice]> proposal
=> "fund the commons"
```

You can look up any binding by name.

### Another identity responds

```
play[alice]> (as bob (modify! 'seconded #t))
play[bob]>
```

Bob seconded the proposal. The prompt now shows `play[bob]>`.

### Enact a rule

```
play[bob]> (enact! (lambda (expressor name value old-env new-env)
                     (not (equal? value #f))))
play[bob]>
```

A validator is now in place: no one can store `#f`. The validator had to accept its own installation — if it had rejected itself, `enact!` would have failed.

### See a rule rejection

```
play[bob]> (as alice (modify! 'bad-idea #f))
error: misc-error
  Validation failed: ...
play[bob]>
```

Alice tried to store `#f`, the validator rejected it, and the environment was unchanged. The prompt stays `play[bob]>`.

### Inspect the history

```
play[bob]> (show-history)
Version 0 [#f] : (quote initial) (parent: 0)
Version 1 [genesis] : (defexpressor (quote alice) alice-key) (parent: 0)
Version 2 [genesis] : (defexpressor (quote bob) bob-key) (parent: 1)
Version 3 [alice] : (modify! (quote proposal) fund the commons) (parent: 2)
Version 4 [bob] : (modify! (quote seconded) #t) (parent: 3)
Version 5 [bob] : (enact! (lambda (expressor name value old-env new-env) (not (equal? value #f)))) (parent: 4)
play[bob]>
```

Every action is attributed: version 3 was alice, versions 4–5 were bob. The rejected `modify!` left no trace — it never happened. The history is the organization's memory; because each entry stores the original expression, the entire org can be replayed from scratch.

### What just happened

You expressed a meta-org. Two identities acted, a rule was enacted that constrained future behavior (and had to survive its own installation), a violation was rejected, and every step was remembered and attributed. The shape of this organization — who can act, what rules apply, how decisions are made — was not prescribed. It emerged from the expressions.

## The Evaluator

`evaluate` is a small Lisp interpreter. It understands:

| Form                         | Effect                                   |
| ---------------------------- | ---------------------------------------- |
| `#t`, `#f`, numbers, strings | Self-evaluating literals                 |
| `(quote x)`                  | Returns `x` unevaluated                  |
| `(if test then else)`        | Conditional                              |
| `(lambda (args ...) body)`   | Closure — captures the current expressor |
| `(defexpressor name key)`    | Bring a new identity into being          |
| `(as expressor expr)`        | Evaluate under a different identity      |
| `(modify! name value)`       | Bind a value in the environment          |
| `(enact! validator-expr)`    | Replace the validator                    |
| `(rollback! version)`        | Replay to a prior state                  |
| `(show-history)`             | Print the versioned history              |
| `(show-expressors)`          | Print all known identities               |
| `(f args ...)`               | Function application                     |

Lambdas capture the environment at creation time (bindings, validator, history), but adopt the identity of their caller at invocation time.

![alt text](image.png)

## What this is not

This is not a governance framework. It does not encode voting, consensus, hierarchy, or any particular organizational form. It is the layer _beneath_ those — a substrate in which any such form could be expressed, enacted, and later replaced by something else entirely.

The only invariants are: every action has an identity, every change is remembered, and the rules for changing the rules are themselves subject to the rules.

What emerges from that is up to the expressors.

## How to run the demo

This is a bleeding edge demo that requires a lot of very fresh software. GNU Guile built from the main branch, Guile Hoot 0.5.0 or later, and a recent browser such as Chrome 119+ or Firefox 121+.

You need to get the browser on your own, but for getting a working Guile and Hoot we have provided a Guix manifest file that can be used to setup the environment. Once Guix is installed, just run:

guix shell -m manifest.scm

Once your environment is up, the examples can be built like so:
make

Then launch a simple web server:

make serve
Once the web server is up, visit http://localhost:8088 and click on a link to the demo you'd like to check out.
