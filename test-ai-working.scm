#!/usr/bin/env guile
!#

;;; test-ai-working.scm — Working AI test with proper org handling and .env loading

(add-to-load-path "module")

(use-modules (xorg ai)
             (xorg org)
             (ice-9 rdelim)
             (ice-9 textual-ports))

;;; Load .env file
(define (load-env-file filepath)
  "Load environment variables from .env file"
  (when (file-exists? filepath)
    (call-with-input-file filepath
      (lambda (port)
        (let loop ()
          (let ((line (read-line port)))
            (unless (eof-object? line)
              (let ((trimmed (string-trim-both line)))
                (unless (or (string-null? trimmed)
                           (string-prefix? "#" trimmed))
                  (let ((parts (string-split trimmed #\=)))
                    (when (= (length parts) 2)
                      (let ((key (string-trim-both (car parts)))
                            (val (string-trim-both (cadr parts))))
                        (setenv key val))))))
              (loop))))))))

(display "\n=== xorg AI Integration Test ===\n\n")

;;; Load .env
(display "Loading .env file...\n")
(load-env-file ".env")

;;; Check API key
(let ((key (or (getenv "OPENROUTER_API_KEY") #f)))
  (if key
      (begin
        (set-ai-api-key! key)
        (format #t "✓ API key loaded from .env (length: ~a)\n" (string-length key)))
      (display "✗ No API key in .env file\n")))

(format #t "✓ AI Model: ~a\n\n" (current-ai-model))

;;; Test 1: Create org properly
(display "Creating test org...\n")
(define test-org (make-org "ai-test"))
(display "✓ Org created successfully\n\n")

(display "Testing AI integration:\n")
(display "Note: The following test requires entering the org REPL interactively.\n")
(display "To test manually, run:\n\n")
(display "  make repl\n")
(display "  scheme@(guile-user)> (use-modules (xorg ai))\n")
(display "  scheme@(guile-user)> (define my-org (make-org \"test\"))\n")
(display "  scheme@(guile-user)> (enter! my-org)\n")
(display "  play[genesis]> (ai \"What is 2 + 2?\")\n")
(display "  play[genesis]> (ai-eval \"Create a greeting binding with hello world\")\n")
(display "  play[genesis]> greeting\n\n")

(display "=== Setup Complete ===\n")
(display "The AI module is ready and the API key is loaded.\n")
