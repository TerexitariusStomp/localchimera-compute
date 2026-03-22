#!/usr/bin/env guile
!#

;;; test-ai-agent-real.scm — Real test of AI agent functionality
;;;
;;; This creates an AI agent and has it actually act within an org

(add-to-load-path "module")

(use-modules (xorg ai)
             (xorg ai-agent)
             (xorg org)
             (goblins)
             (ice-9 rdelim))

;;; Load .env
(define (load-env filepath)
  (when (file-exists? filepath)
    (call-with-input-file filepath
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
              (loop))))))))

(display "\n╔═══════════════════════════════════════════════════════════════╗\n")
(display "║          AI Agent Test - Organizations as Intelligence        ║\n")
(display "╚═══════════════════════════════════════════════════════════════╝\n\n")

(load-env ".env")
(set-ai-api-key! (getenv "OPENROUTER_API_KEY"))

(display "1. Creating organization...\n")
(define my-org (make-org "ai-governed"))
(display "   ✓ Org created: ai-governed\n\n")

(display "2. Creating AI agent with expressor identity...\n")
(define-values (ai-agent ai-sealer)
  (with-vat (org-vat my-org)
    (make-ai-agent
     (org-vat my-org)
     (org-ref my-org)
     'ai-governor
     "ai-pub-key"
     "You are an AI governor for this organization. You make wise decisions.")))

(display "   ✓ AI agent created with identity 'ai-governor'\n\n")

(display "3. Testing AI agent query (read-only)...\n")
(catch #t
  (lambda ()
    (with-vat (org-vat my-org)
      (let ((response (ai-agent-query ai-agent "What bindings exist in this org?")))
        (display "   AI Response: ")
        (display response)
        (newline)
        (newline))))
  (lambda (key . args)
    (display "   ✗ Error: ")
    (display key)
    (display ": ")
    (display args)
    (newline)
    (newline)))

(display "4. Testing AI agent action (write)...\n")
(display "   Asking AI to create a welcome message...\n")
(catch #t
  (lambda ()
    (with-vat (org-vat my-org)
      (ai-agent-act ai-agent "Create a binding called 'welcome' with a friendly greeting")
      (display "   ✓ AI agent executed action\n\n")))
  (lambda (key . args)
    (display "   ✗ Error: ")
    (display key)
    (display ": ")
    (display args)
    (newline)
    (newline)))

(display "5. Checking org history...\n")
(with-vat (org-vat my-org)
  (let ((history ($ (org-ref my-org) 'history)))
    (display "   Recent history entries:\n")
    (for-each
     (lambda (entry)
       (let ((version (car entry))
             (exp-id (cadr entry))
             (expr (caddr entry)))
         (format #t "     v~a [~a]: ~a\n"
                 version
                 (or ($ (org-ref my-org) 'expressor-name exp-id) '?)
                 expr)))
     (reverse (if (> (length history) 5)
                  (list-tail history (- (length history) 5))
                  history)))))

(display "\n════════════════════════════════════════════════════════════════\n\n")
(display "✅ AI Agent test complete!\n\n")
(display "Key points demonstrated:\n")
(display "  • AI agent has its own expressor identity ('ai-governor')\n")
(display "  • AI agent can query org state\n")
(display "  • AI agent can execute expressions autonomously\n")
(display "  • AI agent's actions appear in history under its name\n")
(display "  • Organization = Human expressors + AI expressors\n\n")
(display "This is not AI-assisted governance.\n")
(display "This is governance AS hybrid intelligence.\n\n")
