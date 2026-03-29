# XAAS-AI-DEEP: How AI Agents Hold and Use Capabilities in playnet

Technical deep-dive into the AI expressor system, MCP integration, and
the gap between governed evaluation and external LLM access.

---

## 1. How does an AI agent "hold" a capability?

### Step by step: `make-ai-expressor!`

The entry point is `make-ai-expressor!` in `module/playnet/ai-expressor.scm:26`.
Here's what happens when you call it:

```scheme
(receive (ai-seal ai-pk)
  (make-ai-expressor! org #:name 'my-ai
                      #:extra-bindings `((my-deploy . ,deploy-cap)))
  ...)
```

**Step 1: Enter the vat.**
`make-ai-expressor!` wraps everything in `(with-vat (org-vat org) ...)`.
All Goblins actor operations require a vat context.

**Step 2: Generate a keypair.**
Unless one is provided, `(generate-key-pair)` creates an Ed25519 keypair.
This keypair will sign all history entries made by this AI expressor.

**Step 3: Create the expressor via `defexpressor`.**
This is the core step. `ai-expressor.scm:55-58`:

```scheme
(ai-seal (evaluate `(defexpressor ',name kp)
                   ref
                   `((kp . ,keypair))
                   gen))
```

The expression `(defexpressor 'my-ai kp)` is evaluated inside the org's
metacircular evaluator, with `kp` bound to the keypair in local-bindings
and `gen` (genesis expressor) as the acting identity.

### What `defexpressor` does inside `evaluate` (gplay.scm:613-637)

```scheme
(('defexpressor name-expr key-expr)
 (let* ((eval-name ...)  ;; => 'my-ai
        (eval-key ...)   ;; => the keypair object
        (id (make-id eval-name))  ;; => 'my-ai-7 (unique symbol)
        (is-keypair ...))  ;; #t — opaque crypto object, not string/pair
   (receive (sealer unsealer sealed?)
     (spawn-sealer-triplet)         ;; <<< THE KEY LINE
     ...
     ($ org 'register-expressor! id data entry)
     sealer)))                      ;; <<< RETURNS the sealer
```

`spawn-sealer-triplet` is a **Goblins primitive**. It creates three actor
refs that form a matched set:

| Actor      | What it does                                                 |
| ---------- | ------------------------------------------------------------ |
| `sealer`   | `($ sealer value)` → produces a sealed (opaque) box          |
| `unsealer` | `($ unsealer box)` → extracts the value from the box         |
| `sealed?`  | `($ sealed? box)` → `#t` iff box was sealed by _this_ sealer |

These are Goblins actors — they are **object references, not cryptographic
keys**. They cannot be forged, guessed, or synthesized. They exist only as
live references in the Goblins actor graph. Possession is the only proof
of identity.

The data stored in the expressor-store (`gplay.scm:624-627`):

```scheme
(data `((id . ,id)
        (name . ,eval-name)
        (public-key . ,(or extracted-pk eval-key))
        (keypair . ,(if is-keypair eval-key #f))
        (unsealer . ,unsealer)
        (sealed? . ,sealed?)))
```

Note: the `sealer` is NOT stored in the org. It is **returned to the caller**
as the only value. This is the capability: whoever holds the sealer can
prove they are this expressor.

**Step 4: Store extra-bindings as the AI expressor.**
`ai-expressor.scm:61-66`:

```scheme
(for-each (lambda (pair)
            (evaluate `(as seal (modify! ',(car pair) val))
                      ref
                      `((seal . ,ai-seal) (val . ,(cdr pair)))
                      gen))
          extra-bindings)
```

Each extra-binding is stored via `(as ai-seal (modify! ...))`. The `as` form
authenticates the seal and switches the acting expressor to the AI, so the
history entry for each binding is **attributed to the AI expressor**, not genesis.

**Step 5: Optionally install AI query capability.**
If `http-client` and `model` are provided, `make-ai-capability` spawns an
`^ai-capability` actor and installs it as the global AI handler.

**Return values:** `(values ai-seal ai-public-key)`

### How `authenticate-sealer` works (gplay.scm:311-319)

When code uses `(as ai-seal expr)`, the evaluator calls
`($ org 'authenticate-sealer sealer)`. Here's the mechanism:

```scheme
[(authenticate-sealer sealer)
 ;; Seal a nonce, then check each expressor's sealed? predicate.
 (let ((nonce ($ sealer 'test-nonce)))     ;; (1) seal the symbol 'test-nonce
   (let loop ((store expressor-store))
     (cond ((null? store) #f)
           (($ (assq-ref (cdar store) 'sealed?) nonce)  ;; (2) does this sealed? recognize it?
            (caar store))                                ;; (3) yes → return that expressor-id
           (else (loop (cdr store))))))]
```

Step (1): `($ sealer 'test-nonce)` calls the sealer with the symbol `'test-nonce`
as the value to seal. This produces a sealed box.

Step (2): For each registered expressor, it calls that expressor's `sealed?`
actor with the box. **Only the `sealed?` from the same `spawn-sealer-triplet`
call will return `#t`.** This is the Goblins sealer invariant: sealer/unsealer/sealed?
are a matched set.

Step (3): When a match is found, the expressor's ID (e.g. `'my-ai-7`) is returned.

This is why holding the sealer IS being the expressor. No other mechanism exists
to produce a box that the matching `sealed?` will recognize.

### `extra-bindings`: local scope vs shared bindings

There's a subtlety. `extra-bindings` are stored in the **org's shared bindings**
via `(modify! ...)`. This means they're visible to everyone via `($ org 'bindings)`.

The capability scoping comes from what the _value_ is, not where it's stored.
If you store an endorsed value `(endorse "nginx-deployer" infra-seal)` under the
name `'my-deploy`, anyone can look it up — but only the faceted validator knows
that this value was endorsed with the infra-seal. The AI can pass it to
`modify!` on an `infra-*` name because the validator checks `(facet-satisfied?
f value)`, not who is calling.

True local scope (bindings only visible to one agent) doesn't exist in the
current system. The org has one shared binding space. Scoping is achieved by:

- Giving the AI actor refs in its extra-bindings that others don't have
- The capability model: holding the ref is the authority; others can see the
  name but can't reconstruct the sealed value

### The `as` form in detail (gplay.scm:640-645)

```scheme
(('as sealer-expr body-expr)
 (let* ((sealer (evaluate sealer-expr org local-bindings current-expressor))
        (id ($ org 'authenticate-sealer sealer)))
   (unless id
     (error "Invalid expressor credential — must provide the sealer returned by defexpressor"))
   (evaluate body-expr org local-bindings id)))
```

1. Evaluate the sealer expression (looks up `seal` in local-bindings → gets the AI's sealer)
2. Authenticate it against the org's expressor-store (as described above)
3. Re-evaluate the body with `current-expressor` set to the authenticated ID
4. Any `modify!` inside the body will now be attributed to the AI expressor

---

## 2. How does the AI USE a capability?

### Concrete example: AI holds `^deploy-cap`

Setup:

```scheme
(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "prod-org")
  ;; Create an endorsed deployment capability
  (let ((endorsed-deploy (with-vat (org-vat org)
                           (endorse "nginx-deployer" infra-seal))))
    (receive (ai-seal ai-pk)
      (make-ai-expressor! org
                          #:name 'deploy-ai
                          #:extra-bindings `((my-deploy . ,endorsed-deploy)))
      ...)))
```

Now the AI wants to use it. The call:

```scheme
(evaluate '(as seal (modify! 'infra-deploy (lookup 'my-deploy)))
          ref
          `((seal . ,ai-seal))
          gen)
```

### Call chain through gplay.scm

**1.** `evaluate` matches `('as sealer-expr body-expr)` at line 640.

**2.** Evaluates `seal` → finds `ai-seal` in local-bindings.

**3.** `($ org 'authenticate-sealer ai-seal)` → seals `'test-nonce`,
iterates expressor-store, finds the matching `sealed?`, returns `'deploy-ai-N`.

**4.** Evaluates `(modify! 'infra-deploy (lookup 'my-deploy))` with
`current-expressor` = `'deploy-ai-N`.

**5.** `modify!` handler (line 648):

- Evaluates `'infra-deploy` → symbol `infra-deploy`
- Evaluates `(lookup 'my-deploy)` → ... wait, `lookup` isn't a special form.

Actually, the AI would use the binding directly:

```scheme
(evaluate '(as seal (modify! 'infra-deploy my-deploy))
          ref
          `((seal . ,ai-seal))
          gen)
```

or via `($ org 'lookup 'my-deploy)` from outside the evaluator. Inside the
evaluator, just referencing `my-deploy` as a symbol does the lookup:

**5.** `modify!` handler (line 648):

- `name` = `'infra-deploy`
- `value` = the endorsed value (the sealed box from `(endorse "nginx-deployer" infra-seal)`)
- `pre-bindings` = current org bindings
- `post-bindings` = bindings with new entry prepended
- Calls `(call-validator validator current-expressor name value pre post)`

**6.** The validator is a `^faceted-validator` (an actor ref). It:

- Finds the infra-facet matches `'infra-deploy` (prefix "infra-")
- Calls `(facet-satisfied? infra-facet value)` → `($ sealed-infra? value)`
- The value IS an endorsed box from `infra-seal` → `sealed-infra?` returns `#t`
- Validation passes

**7.** `($ org 'modify! name value entry)` — the org actor becomes a new state
with the binding added and the history entry recorded.

**8.** `compute-sig` signs the history entry with the AI's keypair (looked up
from expressor-store by the AI's expressor-id).

### `ai-eval-as` — the AI evaluates its own LLM output

```scheme
(evaluate '(ai-eval-as seal "deploy the nginx config")
          ref
          `((seal . ,ai-seal))
          gen)
```

`ai-eval-as` handler (gplay.scm:771-782):

```scheme
(('ai-eval-as sealer-expr prompt-expr)
 (let* ((sealer (evaluate sealer-expr ...))
        (ai-id  ($ org 'authenticate-sealer sealer))
        (prompt (evaluate prompt-expr ...))
        (handler *ai-eval-handler*))
   (unless ai-id (error "ai-eval-as: invalid sealer"))
   (unless handler (error "No AI eval handler installed"))
   (let ((result-expr (handler prompt org ai-id)))
     ;; Run the AI's expression AS the AI expressor
     (evaluate result-expr org local-bindings ai-id))))
```

Key difference from `ai-eval` (line 762):

- `ai-eval` evaluates the AI's output as `current-expressor` (whoever called it)
- `ai-eval-as` authenticates the seal first, then evaluates as the AI's own identity

The AI handler returns an S-expression (e.g., `(modify! 'infra-deploy val)`).
That expression is then evaluated with `current-expressor` = `ai-id`, so the
history entry is attributed to the AI, not to genesis or whoever initiated
the call.

### History entry structure

After the AI's expression executes, the history contains:

```scheme
(version          ;; e.g., 14
 expressor-id     ;; 'deploy-ai-3 (the AI's unique ID)
 expression       ;; (modify! 'infra-deploy ...)
 parent-version   ;; 13
 snapshot          ;; (bindings validator-expr validator-proc)
 signature)       ;; Ed25519 sig over (version expressor-id expression parent-version)
```

### Who can verify it and how

Anyone with the AI's public key:

```scheme
(verify-history-entry entry ai-pk)  ;; => #t or #f
```

`verify-history-entry` (gplay.scm:957-975):

1. Extracts `(version expressor-id expression parent-version)` from the entry
2. Serializes them to bytes via `entry->signing-bytes`
3. Calls `(%verify-sig sig bytes public-key-sexp)`
4. Returns `#t` if the signature matches

The public key is available via `($ org 'expressor-key expressor-id)` for any
registered expressor. So any participant can verify any history entry.

---

## 3. How does the MCP connection work?

### Path A: playnet-internal (Goblins layer)

The MCP server is a Goblins actor built in `module/playnet/mcp.scm`.

#### `^tool-cap` — a single tool as a capability actor

```scheme
(define-actor (^tool-cap bcom name description handler read-only?)
  (methods
   [(call args)   (handler args)]
   [(name)        name]
   [(description) description]
   [(read-only?)  read-only?]
   [(schema)      `((name . ,name) (description . ,description) (read-only . ,read-only?))]))
```

A tool is an actor with a `call` method. The handler is a plain lambda.
Possession of the actor ref IS permission to call the tool.

#### `^mcp-server` — tools collection

```scheme
(define-actor (^mcp-server bcom tools)
  ;; tools: alist of (name-string . ^tool-cap-ref)
  (methods
   [(list-tools)     (map (lambda (t) ($ (cdr t) 'schema)) tools)]
   [(call name args) (let ((tool (assoc name tools)))
                       (if tool ($ (cdr tool) 'call args)
                           (error "Unknown tool" name)))]
   [(get-tool name)  ...]
   [(tool-names)     (map car tools)]))
```

**No ACL.** No dynamic registration. The tools list is frozen at construction.
To restrict access, create a new `^mcp-server` with fewer tools (attenuation).

#### Call chain: AI calls a tool

If the AI has a `^mcp-server` ref in its bindings (e.g., bound as `'tools`):

```scheme
;; Inside the org evaluator:
($ (lookup 'tools) 'call "playnet-eval" '(("expression" . "(+ 1 2)")))
```

This translates to:

1. `(lookup 'tools)` → resolves to the `^mcp-server` actor ref
2. `($ server 'call "playnet-eval" args)` → `^mcp-server` looks up `"playnet-eval"` in its tools alist
3. Finds the `^tool-cap` ref, calls `($ tool 'call args)`
4. `^tool-cap` calls `(handler args)` — the lambda provided at construction
5. For `"playnet-eval"`, the handler (`mcp.scm:142-147`):
   ```scheme
   (lambda (args)
     (let* ((expr-str (assoc-ref args "expression"))
            (result (evaluate
                     (call-with-input-string expr-str read)
                     ref '()
                     ($ ref 'current-expressor))))
       (format #f "~s" result)))
   ```
6. It reads the expression string, parses it, evaluates it via the playnet
   `evaluate` function using the current-expressor as identity
7. Returns the result as a string

#### `make-playnet-mcp-server` — standard tool factory

`mcp.scm:97-164` builds an MCP server with gated tools:

```scheme
(make-playnet-mcp-server vat org
  #:allow-eval? #t       ;; playnet-eval tool (powerful! arbitrary evaluation)
  #:allow-modify? #t     ;; playnet-modify tool (set bindings)
  #:allow-history? #t    ;; playnet-history tool (read-only)
  #:allow-bindings? #t)  ;; playnet-bindings tool (read-only)
```

Each flag gates one tool. Tools not enabled are simply not in the server's
tools list — the AI never gets the actor ref, so it can never call the tool.

### Path B: External LLM via Emacs bridge (`emacs-mcp.el`)

#### Architecture

```
Claude Desktop ──MCP protocol──> Emacs (mcp-server-lib.el)
                                     │
                                     ▼
                                 emacs-mcp.el
                                     │
                                     ▼
                                 geiser-eval-string
                                     │
                                     ▼
                              Guile REPL (Goblins vat)
```

#### Registration

`emacs-mcp.el:38-64` registers four tools:

| Tool ID                  | Function                    | Description                          |
| ------------------------ | --------------------------- | ------------------------------------ |
| `playnet-eval`           | `playnet-tool-eval`         | Evaluate arbitrary Scheme in the vat |
| `playnet-bindings`       | `playnet-tool-bindings`     | List current bindings                |
| `playnet-history`        | `playnet-tool-history`      | Show recent history entries          |
| `playnet-verify-history` | `playnet-tool-verify-entry` | Verify history entry signature       |

#### Call chain: Claude calls "playnet-eval"

1. **Claude Desktop** sends an MCP `tools/call` request with
   `{ "name": "playnet-eval", "arguments": { "expression": "(+ 1 2)" } }`

2. **`mcp-server-lib.el`** receives the JSON-RPC request, dispatches to
   `playnet-tool-eval`.

3. **`playnet-tool-eval`** (`emacs-mcp.el:73-79`):

   ```elisp
   (defun playnet-tool-eval (expression)
     (mcp-server-lib-with-error-handling
       (playnet-mcp-geiser-eval expression)))
   ```

4. **`playnet-mcp-geiser-eval`** (`emacs-mcp.el:30-36`):

   ```elisp
   (defun playnet-mcp-geiser-eval (expression)
     (let ((result (geiser-eval-string expression)))
       (if result (format "%s" result) "void")))
   ```

5. **`geiser-eval-string`** sends the expression to the connected Guile
   process over the REPL socket (`/var/run/playnet-dev.sock`).

6. **Guile** evaluates the expression in the top-level environment of the
   REPL — full access to all loaded modules, the vat, everything.

7. **Result** flows back: Guile → Geiser → `playnet-mcp-geiser-eval` →
   `mcp-server-lib` → JSON-RPC response → Claude Desktop.

#### The security model: none

The Emacs bridge is **raw Geiser access**. The expression string is
evaluated directly in the Guile REPL. There is:

- No authentication (no sealer, no expressor identity)
- No validation (no validator checks the expression)
- No history attribution (no history entry is created)
- No signing (no keypair signs anything)
- Full access to `(system ...)`, file I/O, network, everything

This is intentional — it's dev tooling for a local Geiser session.
The comment in `emacs-mcp.el` says: "Setup: `herd start playnet-dev-repl`".
This is a development REPL, not a production API.

The `playnet-tool-bindings` and `playnet-tool-history` tools go through
slightly different paths — they reference `(car *orgs*)` which is the
first org in the global registry, and use `org-bindings`/`org-history`
accessors. But they're still running in the unprotected REPL.

---

## 4. The gap: connecting the two paths

### The problem

Path A (Goblins layer) provides:

- Identity (expressor with sealer)
- Validation (faceted validator)
- Attribution (history entries signed with the AI's keypair)
- Scoped authority (extra-bindings determine what the AI can do)

Path B (Emacs bridge) provides:

- Convenience (Claude Desktop can call tools)
- Full power (arbitrary Scheme evaluation)
- Zero governance (nothing goes through the org's evaluator properly)

Right now, when Claude calls `playnet-eval` via the Emacs bridge, it evaluates
the expression as a raw Guile expression, not as an playnet `evaluate` call
attributed to an AI expressor.

### What's missing

To close the gap, the Emacs bridge needs to:

**1. Have access to an AI seal.**

The Geiser session needs the `ai-seal` value to be available. This means
either:

- Creating the AI expressor at REPL startup and binding the seal to a
  known variable (e.g., `*claude-seal*`)
- Or having a bootstrap expression that creates it on first connection

**2. Route evaluation through `ai-eval-as` instead of raw eval.**

Instead of:

```elisp
(playnet-mcp-geiser-eval expression)
```

The bridge would need:

```elisp
(playnet-mcp-geiser-eval
 (format "(with-vat (org-vat (car *orgs*))
            (evaluate '(as *claude-seal* %s)
                      (org-ref (car *orgs*))
                      `((seal . ,*claude-seal*))
                      ($ (org-ref (car *orgs*)) 'current-expressor)))"
         expression))
```

Or more cleanly, a wrapper function in the Guile session:

```scheme
(define (claude-eval expr-string)
  (with-vat (org-vat (car *orgs*))
    (let* ((ref (org-ref (car *orgs*)))
           (gen ($ ref 'current-expressor)))
      (evaluate `(as seal ,(call-with-input-string expr-string read))
                ref
                `((seal . ,*claude-seal*))
                gen))))
```

**3. History entries would be attributed to the AI.**

Once evaluation goes through `(as *claude-seal* ...)`, the `modify!` and
other state-changing forms will automatically:

- Record the AI's expressor-id in the history entry
- Sign the entry with the AI's keypair
- Run through the validator

**4. The AI's authority would be exactly its extra-bindings.**

If the AI expressor was created with specific capabilities:

```scheme
(make-ai-expressor! org
  #:name 'claude
  #:extra-bindings `((deploy-cap . ,endorsed-deploy)))
```

Then Claude could use `deploy-cap` via the governed path but couldn't
bypass the validator on governed names it doesn't have endorsements for.

### Is this a design problem or an implementation gap?

**It's an implementation gap.** The design already supports this:

- `make-ai-expressor!` creates the identity and returns the seal
- `(as seal expr)` authenticates and switches identity
- The validator enforces scoped authority
- History entries are signed and attributed

The only missing pieces are:

1. **Bootstrap code**: create the AI expressor in the Geiser session and
   store the seal in a known variable
2. **Modified tool handler**: `playnet-tool-eval` calls `claude-eval` instead
   of raw `geiser-eval-string`
3. **Extra-bindings setup**: decide what capabilities Claude should have
   and pass them at expressor creation time

### Full wiring sketch

```scheme
;;; In the Guile REPL session (run once at startup):

(use-modules (playnet ai-expressor) (playnet org))

;; Create the AI expressor for Claude
(define-values (*claude-seal* *claude-pk*)
  (make-ai-expressor! (car *orgs*)
                      #:name 'claude-desktop
                      #:extra-bindings '()))

;; Wrapper for governed evaluation
(define (claude-eval expr-string)
  (with-vat (org-vat (car *orgs*))
    (let* ((ref (org-ref (car *orgs*)))
           (gen ($ ref 'current-expressor)))
      (evaluate `(as seal ,(call-with-input-string expr-string read))
                ref
                `((seal . ,*claude-seal*))
                gen))))
```

```elisp
;;; In emacs-mcp.el, replace playnet-tool-eval:

(defun playnet-tool-eval (expression)
  "Evaluate EXPRESSION through the governed AI expressor."
  (mcp-server-lib-with-error-handling
    (playnet-mcp-geiser-eval
     (format "(claude-eval %S)" expression))))
```

After this change:

- Every `playnet-eval` call from Claude goes through the org's validator
- History entries are signed with Claude's keypair and attributed to `'claude-desktop`
- Claude cannot modify governed names without the appropriate endorsed values
- The read-only tools (`playnet-bindings`, `playnet-history`) can remain as raw
  Geiser calls since they don't mutate state

---

## 5. The capability holding mechanism — a clear mental model

### "An agent holds a capability" means exactly:

**A Goblins actor reference that is only in that agent's scope.**

```scheme
;; After make-ai-expressor! returns:
;; ai-seal is a Goblins actor ref — the sealer from spawn-sealer-triplet

;; Only the code that received ai-seal can use it.
;; The org stores the matching sealed? and unsealer, but NOT the sealer.
```

### Cannot be synthesized — you must have been given it

Actor refs in Goblins are unforgeable. There is no `(make-actor-ref-from-id ...)`
function. You get refs by:

- Being the code that called `spawn` (creation)
- Receiving it as a message from another actor (delegation)
- Having it in your closure (lexical capture)

```scheme
;; This is the ONLY way the AI seal comes into existence:
(receive (sealer unsealer sealed?)
  (spawn-sealer-triplet)
  ;; sealer is returned to the caller of defexpressor
  ;; sealed? is stored in the expressor-store
  ;; unsealer is stored in the expressor-store
  ;; sealer is NOT stored anywhere in the org
  sealer)
```

### Calling it requires the `$` message-passing operator

All actor interaction in Goblins goes through `$` (synchronous send):

```scheme
($ ai-seal 'test-nonce)    ;; seal the symbol 'test-nonce
($ server 'call "tool" args)  ;; call a tool
($ org 'authenticate-sealer sealer)  ;; prove identity
```

`$` is the only way to interact with an actor. No direct field access,
no reflection, no `(actor-internals ref)`. The actor's behavior is defined
entirely by its message handler.

### Passing it to someone else gives them the same capability

```scheme
;; Human creates the AI and gets the seal
(receive (ai-seal ai-pk) (make-ai-expressor! org #:name 'my-ai)
  ;; Human can now give the seal to someone else:
  (evaluate `(modify! 'ai-seal-ref seal)
            ref `((seal . ,ai-seal)) gen)
  ;; Now anyone who reads 'ai-seal-ref has the AI's seal
  ;; They can (as ai-seal-ref ...) and act as the AI
  )
```

This is why capability security works: **authority flows with the reference**.
If you have the ref, you have the capability. If you don't, you don't.
There's no checking a permissions table — the ref IS the permission.

### Attenuation: wrapping it in a new actor that restricts what messages it forwards

The MCP server demonstrates this directly (from `test-mcp.scm:257-284`):

```scheme
;; Full server has all 3 tools
(let* ((full (spawn ^mcp-server
                    (list (cons "read" t1)
                          (cons "write" t2)
                          (cons "delete" t3))))
       ;; Attenuated: only read + write
       (restricted (spawn ^mcp-server
                          (list (cons "read" t1)
                                (cons "write" t2)))))
  ;; restricted can't call "delete" — it doesn't have the ref
  ;; But it uses the SAME tool actors for "read" and "write"
  (eq? ($ full 'get-tool "read") ($ restricted 'get-tool "read"))
  ;; => #t — same actor ref, just fewer of them exposed
  )
```

Attenuation for endorsement authorities works similarly
(`endorsement.scm:150-156`):

```scheme
(define (make-attenuated-authority parent-sealed?-actor sub-name-pred)
  "Create an attenuated sub-authority."
  (spawn-sealer-triplet))  ;; New triplet — doesn't inherit parent's sealed?
```

A sub-authority can endorse values, but the parent's `sealed?` won't recognize
them. The faceted validator must be configured to accept both. This is how you
can give an AI a narrow endorsement authority that only covers specific names.

### Summary table

| Concept                | Mechanism                              | Code location             |
| ---------------------- | -------------------------------------- | ------------------------- |
| Agent identity         | Sealer from `spawn-sealer-triplet`     | `gplay.scm:622`           |
| Proof of identity      | `authenticate-sealer` via seal/sealed? | `gplay.scm:311-319`       |
| Acting as an agent     | `(as seal expr)` form                  | `gplay.scm:640-645`       |
| AI-specific evaluation | `(ai-eval-as seal prompt)` form        | `gplay.scm:771-782`       |
| History attribution    | `current-expressor` in history entry   | `gplay.scm:655`           |
| History signing        | `compute-sig` with expressor's keypair | `gplay.scm:273-282`       |
| Capability scoping     | Extra-bindings + endorsed values       | `ai-expressor.scm:61-66`  |
| Validation             | Faceted validator checks endorsements  | `endorsement.scm:130-134` |
| Tool attenuation       | New `^mcp-server` with subset of tools | `mcp.scm:60-84`           |
| External bridge        | Emacs/Geiser raw eval (ungoverned)     | `emacs-mcp.el:30-36`      |
| Gap                    | Bridge doesn't use `as`/`ai-eval-as`   | (not yet implemented)     |
