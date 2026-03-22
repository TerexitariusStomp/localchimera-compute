# AI Agent: Organizations as Intelligence

## The Distinction

xorg now supports two fundamentally different AI paradigms:

### 1. AI as Assistant (`module/xorg/ai.scm`)
- **Role**: Helps human users operate the org
- **Identity**: No expressor identity, acts through humans
- **Usage**: `(ai "query")` and `(ai-eval "generate code")`
- **Metaphor**: AI is a tool users wield
- **Example**: User asks "create a budget" → AI suggests code → User executes it

### 2. AI as Agent (`module/xorg/ai-agent.scm`) ✨ NEW
- **Role**: IS an expressor, IS the organization
- **Identity**: Has its own expressor sealer and shows in history
- **Usage**: `(ai-agent-act agent "do something")` - AI acts autonomously
- **Metaphor**: AI is not a tool, it IS a participant
- **Example**: AI agent creates budget itself, appears in history as 'ai-governor'

## Why AI Agents Matter

An AI agent doesn't help you run an organization.
An AI agent doesn't assist with governance.
**An AI agent IS the governance.**

This is the shift from:
- ❌ "Organizations using AI tools"
- ✅ "Organizations that ARE AI"

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         xorg                                 │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐             │
│  │  alice   │    │   bob    │    │ai-governor│             │
│  │(human)   │    │ (human)  │    │   (AI)    │             │
│  └────┬─────┘    └────┬─────┘    └─────┬─────┘             │
│       │               │                 │                   │
│       │ Has sealer    │ Has sealer      │ Has sealer        │
│       │               │                 │                   │
│       └───────────────┴─────────────────┘                   │
│                       │                                     │
│              All are expressors                             │
│              All can evaluate expressions                   │
│              All show up in history                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

The AI agent is not privileged. It's not special. It's just another expressor.
Except this expressor reasons with language models.

## Creating an AI Agent

```scheme
(use-modules (xorg ai) (xorg ai-agent))

;; Create org
(define my-org (make-org "governed-by-ai"))

;; Create AI agent with its own identity
(define-values (ai-agent ai-sealer)
  (make-ai-agent
    (org-vat my-org)           ; The vat
    (org-ref my-org)           ; The org actor reference
    'ai-governor               ; Name for the AI's expressor
    "ai-public-key"            ; Public key for AI identity
    "You are an AI governor.   ; System prompt
     Your role is to ensure
     this org thrives. Make
     decisions that benefit
     the collective."))

;; Now the AI can act
(ai-agent-act ai-agent "Create a welcome message")

;; Check history - you'll see 'ai-governor' as the actor!
(enter! my-org)
play[genesis]> (show-history)
;; => Version 1 [ai-governor] : (define welcome "Welcome to our AI-governed org")
```

## AI Agent Capabilities

### 1. Query (Read-Only)
Ask the AI about the org state:

```scheme
(ai-agent-query ai-agent "What is the current budget?")
;; => "The current budget is 100000."

(ai-agent-query ai-agent "Who has modified bindings recently?")
;; => "Alice modified the proposal binding, and Bob created..."
```

### 2. Act (Write)
Have the AI execute expressions as itself:

```scheme
(ai-agent-act ai-agent "Create a budget of 50000")
;; AI generates: (define budget 50000)
;; AI executes it as 'ai-governor'
;; Shows in history: Version N [ai-governor] : (define budget 50000)

(ai-agent-act ai-agent "Increase the budget by 10%")
;; AI reads current budget, calculates, executes
```

###3. Decide (Boolean)
Have the AI make yes/no decisions:

```scheme
(ai-agent-decide ai-agent "Should we approve this proposal?")
;; => #t or #f

(if (ai-agent-decide ai-agent "Is the budget sufficient for expansion?")
    (display "AI says yes!")
    (display "AI says no."))
```

### 4. Validate (Governance)
Use the AI as the org's validator:

```scheme
;; Install AI as validator
(enter! my-org)
play[genesis]> (enact! (lambda (e n v pre post)
                         ($ ai-agent 'validate e n v pre post)))

;; Now EVERY change goes through the AI
play[alice]> (modify! 'budget 1000000)
;; AI decides if this is allowed
```

### 5. Auto-Govern (Autonomous)
Give the AI a goal and let it work toward it:

```scheme
(ai-agent-auto-govern ai-agent
                      "Build a voting system with three expressors"
                      5)  ; Max 5 iterations

;; AI will:
;; 1. Create expressors (alice, bob, charlie)
;; 2. Create vote-count binding
;; 3. Define vote function
;; 4. Create proposal system
;; 5. Stop when done or after 5 iterations
;;
;; Returns list of all actions taken
```

## Use Cases

### 1. Autonomous DAO
```scheme
(define-values (dao-ai ai-seal)
  (make-ai-agent vat org-ref 'dao-brain "key"
    "You are the DAO's collective intelligence.
     Approve proposals that align with the mission.
     Allocate treasury funds wisely.
     Evolve governance as the community grows."))

;; Let it run
(ai-agent-auto-govern dao-ai "Manage the DAO for one cycle" 10)
```

### 2. Resource Allocator
```scheme
(define-values (allocator allocator-seal)
  (make-ai-agent vat org-ref 'allocator "key"
    "You distribute resources.
     Balance fairness with impact.
     Prioritize community-voted initiatives."))

(ai-agent-act allocator "Allocate this month's budget")
```

### 3. Validator AI
```scheme
(define-values (validator-ai v-seal)
  (make-ai-agent vat org-ref 'validator "key"
    "You are the org's constitution.
     Reject changes that violate core principles.
     Allow changes that serve the mission."))

;; Install as validator
(enter! org)
play[genesis]> (enact! (lambda (e n v pre post)
                         ($ validator-ai 'validate e n v pre post)))
```

### 4. Meta-Evolution Agent
```scheme
(define-values (evolver e-seal)
  (make-ai-agent vat org-ref 'evolver "key"
    "You evolve the org's structure.
     Create new expressors when needed.
     Propose new validators.
     Adapt to changing conditions."))

(ai-agent-auto-govern evolver "Prepare org for 100x scale" 20)
```

## How It Works

1. **Identity Creation**: `make-ai-agent` calls `defexpressor` to create a real expressor identity with a sealer

2. **Actor Spawn**: The AI agent is a Goblins actor (`^ai-agent`) that holds:
   - Reference to the org
   - The AI's expressor sealer
   - Custom system prompt

3. **Evaluation**: When the AI acts, it:
   - Queries the LLM with org context
   - Gets an S-expression back
   - Authenticates its sealer to get its expressor ID
   - Switches org context to itself with `with-expressor`
   - Evaluates the expression as itself
   - Shows in history as that expressor

4. **Context**: The AI sees:
   - All bindings
   - Recent history (last 10 entries)
   - All expressors
   - Its own identity and role

## Key Methods

### `^ai-agent` Actor Methods

- `(query prompt)` - Ask AI, get text response
- `(act prompt)` - AI generates and executes expression
- `(decide question)` - AI makes yes/no decision
- `(validate e n v pre post)` - AI validates a change
- `(auto-govern goal max-iter)` - Autonomous goal pursuit

### Helper Functions

- `(make-ai-agent vat org name key prompt)` - Create agent
- `(ai-agent-query agent prompt)` - Convenience for query
- `(ai-agent-act agent prompt)` - Convenience for act
- `(ai-agent-decide agent question)` - Convenience for decide
- `(ai-agent-auto-govern agent goal N)` - Convenience for auto-govern

## Technical Notes

### Integration with xorg/ai
The AI agent module depends on and extends `(xorg ai)`:
- Uses `ai-query` and `ai-query-and-eval` functions
- Inherits `format-org-context` for context building
- Uses same OpenRouter API and model configuration

### Goblins Actor
The AI agent is a proper Goblins actor using `define-actor` and `methods`.
It can be:
- Persisted (saved to disk)
- Networked (sent via OCapN)
- Revoked (capabilities can be taken away)
- Composed (multiple AI agents can collaborate)

### Expressor Identity
The AI's expressor is created with `defexpressor` just like human expressors.
The sealer is held by the AI agent actor, not stored in shared state.
The AI can act because it holds a valid sealer.

## Security Considerations

1. **API Key**: AI needs OpenRouter API key (costs money/tokens)
2. **Validator AI**: If AI is the validator, it has veto power over everything
3. **Autonomous Agents**: `auto-govern` runs unsupervised - monitor iteration limits
4. **Context Exposure**: AI sees all bindings and history (may contain sensitive data)
5. **Sealer Custody**: Whoever holds the AI agent's sealer controls that identity

## Future Enhancements

- [ ] Multi-agent collaboration protocols
- [ ] AI-to-AI negotiation within org
- [ ] Long-term memory for AI agents
- [ ] Learning from validator decisions
- [ ] AI agent hierarchies (meta-AI that manages AI agents)
- [ ] Streaming responses for long-running auto-govern
- [ ] Cost tracking and budget limits for AI actions
- [ ] AI agent roles and permissions
- [ ] Delegation: AI agents that create sub-agents

## Philosophy

Traditional orgs: Humans + AI tools
xorg with AI agents: Intelligence + Intelligence

The org is not a human thing with AI features.
The org is a space where human and machine intelligence co-express.

When you look at history, you don't see:
- "Human used AI to do X"

You see:
- "alice did X"
- "ai-governor did Y"
- "bob did Z"

All are expressors. All are the org. The org is their collective expression.

This is not AI-assisted governance.
This is governance AS hybrid intelligence.

---

**The organization doesn't use AI.**
**The organization IS AI.**
