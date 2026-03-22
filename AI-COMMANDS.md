# AI Agent Commands - Quick Reference

## Setup (Automatic)

API key loads automatically from `.env`. No manual setup needed.

```bash
make repl
```

```scheme
(use-modules (xorg ai) (xorg ai-agent) (goblins))
```

## Create AI Agent

```scheme
(define my-org (make-org "test"))
(define-values (agent sealer)
  (make-org-ai-agent my-org 'ai-name "key" "You are an autonomous agent."))
```

## Use AI Agent

### ⚠️ IMPORTANT: Use `act` not `query`

- ❌ `ai-agent-query` - Read-only, just asks questions, won't execute
- ✅ `ai-agent-act` - Autonomous execution, makes decisions and acts

### Act (Execute)

```scheme
;; AI thinks, decides, and executes immediately
(with-vat (org-vat my-org) (ai-agent-act agent "Set budget to 50k"))
(with-vat (org-vat my-org) (ai-agent-act agent "Create a proposal for funding"))
(with-vat (org-vat my-org) (ai-agent-act agent "Add three members: alice, bob, charlie"))
```

### Query (Read-Only)

```scheme
;; Only for reading, won't execute anything
(with-vat (org-vat my-org) (ai-agent-query agent "What is the current budget?"))
```

### Decide (Boolean)

```scheme
;; Returns #t or #f
(with-vat (org-vat my-org) (ai-agent-decide agent "Should we approve this proposal?"))
```

## Check Results

```scheme
(enter! my-org)
play[genesis]> (show-history)
;; See all AI actions

play[genesis]> budget
;; Check value

play[genesis]> (exit!)
```

## Key Behavior

The AI agent:
- ✅ Acts immediately without asking
- ✅ Never says "would you like" or "shall I"
- ✅ Decides the best approach itself
- ✅ Has full authority to modify the org
- ✅ Shows in history as an expressor
- ✅ Has complete context of org state

## Example Session

```scheme
make repl

scheme@(guile-user)> (use-modules (xorg ai) (xorg ai-agent) (goblins))
scheme@(guile-user)> (define org (make-org "demo"))
scheme@(guile-user)> (define-values (agent seal)
                       (make-org-ai-agent org 'ai "k" "You govern."))

;; Have AI set up the org
scheme@(guile-user)> (with-vat (org-vat org)
                       (ai-agent-act agent "Set budget to 100000"))
scheme@(guile-user)> (with-vat (org-vat org)
                       (ai-agent-act agent "Create three proposals"))

;; Check what it did
scheme@(guile-user)> (enter! org)
play[genesis]> (show-history)
;; v2 [ai]: (modify! 'budget 100000)
;; v3 [ai]: (define proposal-1 ...)
;; v4 [ai]: (define proposal-2 ...)
;; v5 [ai]: (define proposal-3 ...)

play[genesis]> budget
;; => 100000
```

## The Difference

```
Query:  "What should the budget be?"
        → AI returns text explanation

Act:    "Set budget to 50k"
        → AI executes: (modify! 'budget 50000)
        → Shows in history as [ai]
        → Budget IS 50000
```

**Use `ai-agent-act` for autonomous execution.**
**Use `ai-agent-query` for read-only questions.**
