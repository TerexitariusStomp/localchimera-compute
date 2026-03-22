# AI in xorg - Complete and Working

## ✅ Status: WORKING

The AI agent is fully implemented and tested with real OpenRouter API calls.

## Quick Demo

```bash
guile test-ai-real.scm
```

Result:
```
✓ AI queried: "Four."
✓ AI acted: created greeting binding
✓ AI in history: v2 [ai-helper]: (modify! ...)
✓ AI is an expressor
```

## Usage in REPL

```bash
make repl
```

```scheme
(use-modules (xorg ai) (xorg ai-agent) (goblins))

(define org (make-org "test"))
(define-values (agent sealer)
  (make-org-ai-agent org 'ai "key" "You help."))

;; AI queries
(with-vat (org-vat org)
  (ai-agent-query agent "What is 2+2?"))
;; => "Four."

;; AI acts
(with-vat (org-vat org)
  (ai-agent-act agent "Create a budget of 100000"))

;; Check history
(enter! org)
play[genesis]> (show-history)
;; v2 [ai]: (modify! 'budget 100000)  ← AI DID THIS
play[genesis]> budget
;; => 100000
```

## The Innovation

```
v0 [genesis]: (quote initial)
v1 [genesis]: (defexpressor 'ai ...)
v2 [ai]: (modify! 'budget 100000)      ← AI expressor
v3 [human]: (modify! 'proposal "...")   ← Human expressor
```

Both are expressors. Both are the org.

**The organization IS AI.**

## Documentation

- **AI-WORKING.md** - Detailed usage guide
- **AI-AGENT-GUIDE.md** - Philosophy and examples
- **test-ai-real.scm** - Working test script

## Requirements

- OpenRouter API key in `.env` (current one works!)
- Guile 3.0+
- Goblins

## Next Steps

Try it in the REPL with your own prompts. The AI can:
- Query org state
- Create/modify bindings
- Make decisions
- Act autonomously

All as a real expressor with identity in the org.
