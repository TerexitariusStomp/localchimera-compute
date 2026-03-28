#!/usr/bin/env guile
!#

;;; test-ai.scm — Quick test of AI integration in xorg

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (xorg ai)
             (xorg gplay)
             (goblins))

;;; Test 1: Check if API key is set
(display "=== Test 1: API Key Check ===\n")
(let ((key (current-ai-api-key)))
  (if key
      (format #t "✓ API key is set (length: ~a)\n" (string-length key))
      (format #t "✗ No API key found. Set OPENROUTER_API_KEY env var or use (set-ai-api-key! \"key\")\n")))

(display "\n=== Test 2: Model Check ===\n")
(format #t "Current model: ~a\n" (current-ai-model))

;;; Test 3: Create a simple org and test AI query
(display "\n=== Test 3: Create org and test AI functions ===\n")

(define vat (spawn-vat))
(define org-ref
  (vat-spawn vat ^org
             '((greeting . "hello"))  ; bindings
             default-validator         ; validator
             (make-genesis-history)    ; history
             (make-expressor-store)))  ; expressor store

(display "✓ Org created\n")

;;; Test formatting context
(display "\n=== Test 4: Format org context ===\n")
(let ((context (format-org-context org-ref)))
  (display context)
  (display "\n"))

;;; Test AI query (only if API key is set)
(when (current-ai-api-key)
  (display "\n=== Test 5: AI Query ===\n")
  (display "Asking AI: What is 2 + 2?\n")
  (catch #t
    (lambda ()
      (let ((response (ai-query "What is 2 + 2? Answer in one sentence." org-ref)))
        (format #t "AI Response: ~a\n" response)))
    (lambda (key . args)
      (format #t "✗ Error: ~a ~a\n" key args))))

(display "\n=== Tests Complete ===\n")
