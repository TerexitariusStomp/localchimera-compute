#!/bin/bash

# Quick AI Integration Test for playnet
# Manual smoke test for the gplay (ai …)/(ai-eval …) bridge against a REAL
# provider — not the mocked path tests/org/test-ai-async-evaluator.scm
# exercises. Prints the result and exits; no interactive REPL.

echo "=== playnet AI Integration Quick Test ==="
echo ""

# (playnet ai bridge) reads API_KEYS or OPENROUTER_KEYS — same names the
# gateway service and the box's mcron jobs use. Advisory only: the Guile
# process below still picks up whichever is actually set even if this
# check is wrong, but it shouldn't lie to you about it.
if [ -z "$API_KEYS" ] && [ -z "$OPENROUTER_KEYS" ]; then
    echo "note: neither API_KEYS nor OPENROUTER_KEYS is set."
    echo "      export API_KEYS='sk-...'   (comma-separated for multiple)"
    echo "      export API_PROVIDER=nano-gpt|openrouter|openai|generic  (default: nano-gpt)"
    echo ""
fi

cd "$(dirname "$0")/../.."

guile -L module -c '
(use-modules (playnet org factories) (playnet org gplay) (playnet ai bridge) (goblins))
(format #t "API key configured: ~a\n" (if (current-ai-api-key) "YES" "NO"))
(format #t "Current model: ~a\n\n" (current-ai-model))
(define o (make-org "ai-test"))
(display "Asking: (ai \"What is 2 + 2?\")\n")
(display
 (with-vat (org-vat o)
   (call-with-ai-prompt
    (lambda () (evaluate (quote (ai "What is 2 + 2?")) (org-ref o) (quote ()) (quote me))))))
(newline)
'

echo ""
echo "=== Test Complete ==="
