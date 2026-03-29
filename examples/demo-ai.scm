#!/usr/bin/env -S guile -s
!#

;;; demo-ai.scm — Interactive AI demonstration
;;; Run with: guile demo-ai.scm
;;; Or: ./demo-ai.scm (if executable)

(add-to-load-path "module")

(use-modules (playnet ai)
             (ice-9 readline))

(activate-readline)

(define banner "
╔════════════════════════════════════════════════════════════════╗
║                   playnet AI Integration Demo                     ║
╚════════════════════════════════════════════════════════════════╝

This demo shows the AI module is working and ready to use.

")

(display banner)

;;; Check API key
(define api-key (current-ai-api-key))

(if api-key
    (begin
      (display "✅ API key is configured\n")
      (format #t "   Length: ~a characters\n" (string-length api-key)))
    (begin
      (display "⚠️  No API key found\n")
      (display "   Set OPENROUTER_API_KEY environment variable, or\n")
      (display "   Get one at: https://openrouter.ai/\n")))

(display "\n")
(format #t "🤖 AI Model: ~a\n" (current-ai-model))

(display "\n")
(display "════════════════════════════════════════════════════════════════\n")
(display "\nAI module functions available:\n\n")
(display "  (set-ai-api-key! \"sk-or-v1-...\")  — Set API key\n")
(display "  (set-ai-model! \"model-name\")      — Change AI model\n")
(display "  (current-ai-api-key)               — Check key status\n")
(display "  (current-ai-model)                 — Check model\n")
(display "\n")
(display "To use AI in an org:\n\n")
(display "  1. Start REPL: make repl\n")
(display "  2. Load module: (use-modules (playnet ai))\n")
(display "  3. Create org: (make-org \"test\")\n")
(display "  4. Enter org: (enter! \"test\")\n")
(display "  5. Query AI: (ai \"What is 2 + 2?\")\n")
(display "  6. Code gen: (ai-eval \"Create a greeting binding\")\n")
(display "\n")
(display "════════════════════════════════════════════════════════════════\n")

(if api-key
    (begin
      (display "\n🎯 You're all set! The AI integration is ready to use.\n")
      (display "\n   Try running: make repl\n")
      (display "   Then follow the steps above.\n"))
    (begin
      (display "\n📝 Next step: Set your OpenRouter API key\n")
      (display "\n   export OPENROUTER_API_KEY=\"sk-or-v1-...\"\n")))

(display "\n")
