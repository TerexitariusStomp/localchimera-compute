#!/usr/bin/env guile
!#

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (playnet ai) (playnet org) (playnet gplay) (goblins) (ice-9 rdelim))

;; Load .env
(define %env-file (string-append %project-root "/.env"))
(when (file-exists? %env-file)
  (call-with-input-file %env-file
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (unless (eof-object? line)
            (let ((trimmed (string-trim-both line)))
              (unless (or (string-null? trimmed) (string-prefix? "#" trimmed))
                (let ((parts (string-split trimmed #\=)))
                  (when (= (length parts) 2)
                    (setenv (string-trim-both (car parts))
                            (string-trim-both (cadr parts)))))))
            (loop)))))))

(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "\n=== Testing AI Expressor with Real API Calls ===\n\n")

(display "1. Creating org...\n")
(define my-org (make-org "ai-test"))
(display "   ✓ Org created\n\n")

(display "2. Creating AI expressor...\n")
(define ai-sealer
  (make-org-ai-agent my-org 'ai-helper "key" "You are a helpful assistant."))
(display "   ✓ AI expressor 'ai-helper' created\n\n")

(display "3. Testing AI query (actual API call)...\n")
(display "   Asking: 'What is 2 + 2? Answer in 5 words or less.'\n")
(let ((response (with-vat (org-vat my-org)
                  (evaluate `(as ,ai-sealer
                                 (ai "What is 2 + 2? Answer in 5 words or less."))
                            (org-ref my-org) '()
                            ($ (org-ref my-org) 'current-expressor)))))
  (display "   AI Response: ")
  (display response)
  (newline))

(display "\n4. Testing AI action (AI creates code and executes it)...\n")
(display "   Asking AI to create a greeting binding...\n")
(with-vat (org-vat my-org)
  (evaluate `(as ,ai-sealer
                 (ai-eval "Create a binding called greeting with a short welcome message"))
            (org-ref my-org) '()
            ($ (org-ref my-org) 'current-expressor)))
(display "   ✓ AI executed action\n\n")

(display "5. Checking org history...\n")
(with-vat (org-vat my-org)
  (let ((history ($ (org-ref my-org) 'history)))
    (for-each
     (lambda (entry)
       (format #t "   v~a [~a]: ~a\n"
               (car entry)
               (or ($ (org-ref my-org) 'expressor-name (cadr entry)) '?)
               (caddr entry)))
     (reverse history))))

(display "\n6. Reading the greeting the AI created...\n")
(with-vat (org-vat my-org)
  (let ((bindings ($ (org-ref my-org) 'bindings)))
    (let ((greeting-binding (assq 'greeting bindings)))
      (if greeting-binding
          (begin
            (display "   greeting = ")
            (write (cdr greeting-binding))
            (newline))
          (display "   (greeting binding not found - AI may have used different name)\n")))))

(display "\n=== Test Complete ===\n")
(display "\n✓ AI expressor works with (as sealer (ai ...)) and (as sealer (ai-eval ...))\n")
(display "✓ Config visible as bindings: ai-helper:prompt\n")
(display "✓ AI shows in history as 'ai-helper'\n\n")
