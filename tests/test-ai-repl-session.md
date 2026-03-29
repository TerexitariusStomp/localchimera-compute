# AI Integration Test Session

This document shows how to test the AI integration in playnet using the REPL.

## Prerequisites

1. Get an OpenRouter API key: https://openrouter.ai/
2. Set environment variable: `export OPENROUTER_API_KEY="sk-or-v1-..."`

## Test Session

```bash
# Start the REPL
make repl
```

Once in the REPL, run these commands:

```scheme
;; Load the AI module
playnet> (use-modules (playnet ai))

;; Create a test org
playnet> (make-org "ai-test")
;; => Created org: ai-test

;; Enter the org
playnet> (enter! "ai-test")
;; => Entering org 'ai-test'.

;; Check API key status
play[genesis]> (current-ai-api-key)
;; Should show your key or #f if not set

;; If not set, set it now:
play[genesis]> (set-ai-api-key! "sk-or-v1-YOUR-KEY-HERE")

;; Test 1: Simple AI query
play[genesis]> (ai "What is 2 + 2?")
;; Should return something like: "2 + 2 equals 4."

;; Test 2: AI-eval to create bindings
play[genesis]> (ai-eval "Create a greeting binding with the text hello world")
play[genesis]> greeting
;; => "hello world"

;; Test 3: AI-eval with math
play[genesis]> (define x 10)
play[genesis]> (ai-eval "Multiply x by 5 and store in result")
play[genesis]> result
;; => 50

;; Test 4: Create an expressor with AI
play[genesis]> (define alice (defexpressor 'alice "alice-key"))
play[genesis]> (as alice (modify! 'favorite-color "blue"))
play[genesis]> favorite-color
;; => "blue"

;; Test 5: Ask AI about the org state
play[genesis]> (ai "What bindings exist in this org?")
;; AI will describe the current bindings

;; Test 6: Ask AI to explain history
play[genesis]> (show-history)
play[genesis]> (ai "Summarize what has happened in this org")
;; AI will summarize the history

;; Test 7: AI-eval to create a function
play[genesis]> (ai-eval "Define a function called double that takes a number and returns it doubled")
play[genesis]> (double 21)
;; => 42

;; Test 8: Context awareness
play[genesis]> (define budget 100000)
play[genesis]> (ai-eval "Reduce the budget by 15%")
play[genesis]> budget
;; => 85000

;; Exit the org
play[genesis]> (exit!)
;; => Exiting org 'ai-test'.

;; Exit the REPL
playnet> ,quit
```

## Expected Results

All tests should pass if:

1. ✅ The AI module loads without errors
2. ✅ API key is set (from env or manually)
3. ✅ `(ai ...)` returns text responses
4. ✅ `(ai-eval ...)` creates/modifies bindings
5. ✅ AI has context awareness of the org state

## Troubleshooting

If something doesn't work:

1. **Module not found**: Make sure you're running from the playnet directory
2. **No API key**: Set `OPENROUTER_API_KEY` environment variable
3. **HTTP errors**: Check API key validity and OpenRouter credits
4. **Parse errors**: The AI might return invalid Scheme - try rephrasing

## What's Working

✅ AI module loads successfully
✅ Handlers are registered in gplay.scm
✅ `(ai prompt)` - text queries work
✅ `(ai-eval prompt)` - code generation and execution works
✅ Context formatting includes bindings, history, and expressors
✅ Markdown code fence stripping works
✅ Multiple AI models supported via OpenRouter

## Integration Points

The AI integrates with playnet at these points:

1. **gplay.scm**: Evaluator recognizes `(ai ...)` and `(ai-eval ...)` forms
2. **ai.scm**: Implements handlers and registers them
3. **org.scm**: Can load AI module in REPL sessions
4. **Context**: AI receives full org state (bindings, history, expressor)

## Next Steps

Once basic functionality is confirmed, you can:

1. Create organization-specific AI assistants
2. Use AI for natural language validators
3. Generate org templates with AI
4. Build conversational org interfaces
5. Create AI-powered REPL helpers
