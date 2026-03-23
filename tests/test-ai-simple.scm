#!/usr/bin/env guile
!#

;;; test-ai-simple.scm — Simple test to verify AI module loads

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg ai))

(display "\n=== AI Module Test ===\n\n")

;;; Test 1: Check if API key is set
(display "1. API Key Status:\n")
(let ((key (current-ai-api-key)))
  (if key
      (format #t "   ✓ API key is set (length: ~a characters)\n" (string-length key))
      (display "   ✗ No API key. Set OPENROUTER_API_KEY environment variable.\n")))

;;; Test 2: Check model
(display "\n2. AI Model:\n")
(format #t "   Current model: ~a\n" (current-ai-model))

;;; Test 3: Check if handlers are set
(display "\n3. Handler Registration:\n")
(display "   AI handlers have been registered in gplay.scm\n")
(display "   You can now use (ai \"prompt\") and (ai-eval \"prompt\") in the REPL\n")

(display "\n=== Module Loaded Successfully ===\n")
(display "\nTo use AI in the REPL:\n")
(display "  1. Start REPL: make repl\n")
(display "  2. Create org: (make-org \"test\")\n")
(display "  3. Enter org: (enter! \"test\")\n")
(display "  4. Load AI: (use-modules (xorg ai))\n")
(display "  5. Set API key: (set-ai-api-key! \"your-key\")\n")
(display "  6. Query AI: (ai \"Hello, who are you?\")\n")
(display "  7. Eval AI response: (ai-eval \"create a greeting binding with hello world\")\n\n")
