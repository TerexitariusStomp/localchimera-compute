#!/bin/bash

# Quick AI Integration Test for xorg
# This script tests the AI module in the REPL

echo "=== xorg AI Integration Quick Test ==="
echo ""

# Check if API key is set
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "⚠️  OPENROUTER_API_KEY not set."
    echo "   Set it with: export OPENROUTER_API_KEY='sk-or-v1-...'"
    echo "   Or you can set it in the REPL with: (set-ai-api-key! \"key\")"
    echo ""
fi

echo "Starting REPL with AI test commands..."
echo "Commands that will be executed:"
echo "  1. Load AI module"
echo "  2. Create test org"
echo "  3. Test AI query"
echo ""
echo "Press Ctrl-D when done to exit"
echo ""

# Create a test script that will be piped into the REPL
cat <<'EOF' | guile xorg-repl.scm
(use-modules (xorg ai))
(display "\n=== AI Module Loaded ===\n")
(format #t "API Key set: ~a\n" (if (current-ai-api-key) "YES" "NO"))
(format #t "Current model: ~a\n\n" (current-ai-model))

(make-org "ai-test")
(enter! "ai-test")

(display "=== Inside org 'ai-test' ===\n")
(display "You can now test AI commands manually:\n")
(display "  (ai \"What is 2 + 2?\")\n")
(display "  (ai-eval \"Create a greeting binding with hello world\")\n")
(display "  greeting\n")
(display "\nType (exit!) to exit the org, then ,quit to exit REPL\n\n")
EOF

echo ""
echo "=== Test Complete ==="
